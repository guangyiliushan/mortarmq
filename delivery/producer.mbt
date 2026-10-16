/// The publish admission face for producer idempotence (the malformed
/// combination rule and the sequence window).
///
/// The field-semantics rule for the PUB idempotence pair: `producer_id`
/// zero with `producer_seq` zero is allowed as non-idempotent production
/// (counted, not deduplicated); `producer_id` zero with a positive
/// sequence is refused with `PRODUCER_SEQ_INVALID` -- the client must fix
/// itself, the connection stays open. Everything else belongs to the
/// sequence window keyed by `(topic_id, partition, producer_id)`.
///
/// This is the admission face, not the decode guard: the code table
/// classes the two outcomes apart -- a malformed payload closes the
/// connection while a producer-sequence invalidation is a non-fatal,
/// actionable ERR -- so the semantic check lives here and the codec
/// stays shape-only.

///|
/// The registered refusal family for the producer sequence world:
/// 0x0013 for the malformed combination, and the neighbouring sequence
/// codes the window answers with.
pub(all) suberror ProducerError {
  /// `producer_id` zero with a positive `producer_seq`.
  SeqInvalid
  /// A gap too large or a gap left unfilled past its window.
  SeqGap
  /// A sequence behind the retained window.
  SeqExpired
  /// A producer request from an epoch older than the registered one.
  EpochStale
} derive(Eq, Debug)

///|
pub extend ProducerError with Eq::{not_equal, equal}

///|
pub extend ProducerError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Translate one producer refusal into the registered wire code.
///
/// `SeqInvalid` becomes 0x0013 (fix the client), `SeqGap` 0x0010 (fill
/// the gap or reset the producer), `SeqExpired` 0x0011 (re-register the
/// producer), and `EpochStale` 0x0012 (rediscover the leader or epoch).
/// Zero new codes.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(
///     @delivery.ProducerError::SeqInvalid.to_err_code(),
///     @protocol.ProducerSeqInvalid,
///   )
/// }
/// ```
pub fn ProducerError::to_err_code(self : ProducerError) -> @protocol.ErrCode {
  match self {
    SeqInvalid => @protocol.ProducerSeqInvalid
    SeqGap => @protocol.SeqGap
    SeqExpired => @protocol.SeqExpired
    EpochStale => @protocol.ProducerEpochStale
  }
}

///|
/// The malformed-combination check every publish passes first.
///
/// The zero/zero pair is allowed (non-idempotent production); a zero
/// producer id with a positive sequence is refused. A positive producer
/// id passes through to the sequence window whatever the sequence is.
pub fn validate_producer_fields(
  producer_id : UInt64,
  producer_seq : UInt64,
) -> Result[Unit, ProducerError] {
  if producer_id == 0UL && producer_seq > 0UL {
    return Err(SeqInvalid)
  }
  Ok(())
}

///|
/// The outcome of one non-idempotent production, counted so the metrics
/// can see it: the zero/zero pair writes without any deduplication.
pub fn is_non_idempotent(producer_id : UInt64, producer_seq : UInt64) -> Bool {
  producer_id == 0UL && producer_seq == 0UL
}

///|
/// The frozen window size: the accepted set is a 1024-bit sliding
/// bitmap (128 bytes) per `(topic_id, partition, producer_id)`, with the
/// high watermark deciding old versus new.
pub const PRODUCER_WINDOW : UInt64 = 1024

///|
/// The frozen gap budget: a gap-pending sequence is dropped back to its
/// caller as `SeqGap` if the hole ahead of it is not filled within five
/// seconds.
pub const PRODUCER_GAP_TIMEOUT_MS : UInt64 = 5000

///|
/// What the publish path does next with one sequence.
pub(all) enum ProducerOutcome {
  /// The sequence joined the contiguous frontier: write its record now.
  Accepted
  /// Already accepted earlier: write nothing; the caller answers the PUB
  /// with the original broker sequence from the record index (the data
  /// log is the truth source) and the deduplicated result flag.
  Duplicate
  /// Parked behind a gap: resolve later through `drain_flushed` (the gap
  /// filled) or `sweep_gaps` (it timed out).
  Pending
} derive(Eq, Debug)

///|
pub extend ProducerOutcome with Eq::{not_equal, equal}

///|
pub extend ProducerOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A gap that timed out: the caller answers its PUB with `SeqGap`.
pub(all) struct GapTimeout {
  topic_id : UInt16
  partition : UInt16
  producer_id : UInt64
  producer_seq : UInt64
} derive(Eq, Debug)

///|
pub extend GapTimeout with Eq::{not_equal, equal}

///|
pub extend GapTimeout with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One producer window state: the contiguous frontier, the sliding
/// accepted bitmap, the gap-pending queue, and the flushed-but-unclaimed
/// backlog.
priv struct ProducerState {
  epoch : UInt64
  mut high_watermark : UInt64
  accepted : Array[Byte]
  mut gap_seqs : Array[UInt64]
  mut gap_times : Array[UInt64]
  mut flushed : Array[UInt64]
}

///|
fn producer_key(
  topic_id : UInt16,
  partition : UInt16,
  producer_id : UInt64,
) -> Bytes {
  let buf = Buffer()
  buf.write_uint16_be(topic_id)
  buf.write_uint16_be(partition)
  buf.write_uint64_be(producer_id)
  buf.contents()
}

///|
fn bitmap_test(accepted : Array[Byte], bit : Int32) -> Bool {
  let byte = accepted[bit / 8].to_uint()
  ((byte >> (bit % 8)) & 1U) != 0U
}

///|
fn bitmap_set(accepted : Array[Byte], bit : Int32) -> Unit {
  let byte = accepted[bit / 8].to_uint()
  accepted[bit / 8] = ((byte | (1U << (bit % 8))) & 0xFFU).to_byte()
}

///|
fn bitmap_clear(accepted : Array[Byte], bit : Int32) -> Unit {
  let byte = accepted[bit / 8].to_uint()
  accepted[bit / 8] = (byte & (0xFFU ^ (1U << (bit % 8))) & 0xFFU).to_byte()
}

///|
fn fresh_bitmap() -> Array[Byte] {
  let accepted : Array[Byte] = []
  let mut index = 0
  while index < 128 {
    accepted.push(0U.to_byte())
    index = index + 1
  }
  accepted
}

///|
fn fresh_state(epoch : UInt64) -> ProducerState {
  {
    epoch,
    high_watermark: 0UL,
    accepted: fresh_bitmap(),
    gap_seqs: [],
    gap_times: [],
    flushed: [],
  }
}

///|
/// The publish admission face over every producer window.
pub(all) struct ProducerRegistry {
  priv windows : Map[Bytes, ProducerState]
  priv mut non_idempotent : UInt64
}

///|
pub fn ProducerRegistry::new() -> ProducerRegistry {
  { windows: Map([]), non_idempotent: 0, }
}

///|
/// How many zero-pair (non-idempotent) productions were admitted.
pub fn ProducerRegistry::non_idempotent_count(
  self : ProducerRegistry,
) -> UInt64 {
  self.non_idempotent
}

///|
/// Admit one PUB's producer fields through the frozen rule table.
///
/// The zero pair is admitted as non-idempotent production and counted; a
/// zero producer id with a positive sequence is refused. A positive
/// producer id runs the window rules: the next contiguous sequence is
/// accepted and the contiguous queued ones flush behind it; a sequence
/// inside the retained window that is already accepted is a duplicate; a
/// sequence ahead of the gap is parked until the hole fills or its
/// budget expires; a sequence behind the window is expired; a sequence
/// past the window is a gap. A request from an epoch older than the
/// registered one is refused; a newer epoch re-registers the producer
/// with a fresh window.
pub fn ProducerRegistry::admit(
  self : ProducerRegistry,
  topic_id : UInt16,
  partition : UInt16,
  producer_id : UInt64,
  producer_seq : UInt64,
  epoch : UInt64,
  now_ms : UInt64,
) -> Result[ProducerOutcome, ProducerError] {
  match validate_producer_fields(producer_id, producer_seq) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  if is_non_idempotent(producer_id, producer_seq) {
    self.non_idempotent = self.non_idempotent + 1UL
    return Ok(Accepted)
  }
  let key = producer_key(topic_id, partition, producer_id)
  let prior = self.windows.get(key)
  let state = match prior {
    None => fresh_state(epoch)
    Some(state) =>
      if state.epoch > epoch {
        return Err(EpochStale)
      } else if state.epoch < epoch {
        fresh_state(epoch)
      } else {
        state
      }
  }
  let high = state.high_watermark
  let outcome = if producer_seq == high + 1UL {
    bitmap_set(state.accepted, (producer_seq & 1023UL).to_int())
    state.high_watermark = producer_seq
    // Flush the contiguous queued sequences behind the new frontier.
    let mut progressed = true
    while progressed {
      progressed = false
      let mut index = 0
      while index < state.gap_seqs.length() {
        if state.gap_seqs[index] == state.high_watermark + 1UL {
          let flushed_seq = state.gap_seqs[index]
          let last = state.gap_seqs.length() - 1
          state.gap_seqs[index] = state.gap_seqs[last]
          let _dropped_seq = state.gap_seqs.pop()
          state.gap_times[index] = state.gap_times[last]
          let _dropped_time = state.gap_times.pop()
          bitmap_set(state.accepted, (flushed_seq & 1023UL).to_int())
          if flushed_seq > PRODUCER_WINDOW {
            bitmap_clear(
              state.accepted,
              ((flushed_seq - PRODUCER_WINDOW) & 1023UL).to_int(),
            )
          }
          state.high_watermark = flushed_seq
          state.flushed.push(flushed_seq)
          progressed = true
          break
        }
        index = index + 1
      }
    }
    Ok(Accepted)
  } else if producer_seq <= high {
    if producer_seq + PRODUCER_WINDOW - 1UL < high {
      Err(SeqExpired)
    } else if bitmap_test(state.accepted, (producer_seq & 1023UL).to_int()) {
      Ok(Duplicate)
    } else {
      Err(SeqExpired)
    }
  } else if producer_seq > high + PRODUCER_WINDOW {
    Err(SeqGap)
  } else {
    // Gap-pending: park it unless the same sequence is already parked.
    let mut seen = false
    let mut index = 0
    while index < state.gap_seqs.length() {
      if state.gap_seqs[index] == producer_seq {
        seen = true
      }
      index = index + 1
    }
    if !seen {
      state.gap_seqs.push(producer_seq)
      state.gap_times.push(now_ms)
    }
    Ok(Pending)
  }
  self.windows[key] = state
  outcome
}

///|
/// Hand over the sequences that became contiguous since the last drain,
/// in frontier order. The caller writes their records and answers their
/// parked PUBs.
pub fn ProducerRegistry::drain_flushed(
  self : ProducerRegistry,
  topic_id : UInt16,
  partition : UInt16,
  producer_id : UInt64,
) -> Array[UInt64] {
  let key = producer_key(topic_id, partition, producer_id)
  let state = match self.windows.get(key) {
    None => return []
    Some(state) => state
  }
  let drained = state.flushed
  state.flushed = []
  drained
}

///|
/// Drop the gap-pending sequences whose budget expired and report them:
/// the caller answers each parked PUB with `SeqGap`.
pub fn ProducerRegistry::sweep_gaps(
  self : ProducerRegistry,
  now_ms : UInt64,
) -> Array[GapTimeout] {
  let expired : Array[GapTimeout] = []
  for key, state in self.windows {
    let kept_seqs : Array[UInt64] = []
    let kept_times : Array[UInt64] = []
    let mut index = 0
    while index < state.gap_seqs.length() {
      let born = state.gap_times[index]
      if now_ms >= born && now_ms - born > PRODUCER_GAP_TIMEOUT_MS {
        let seq = state.gap_seqs[index]
        let topic_id = ((key[0].to_uint() << 8) | key[1].to_uint()).to_uint16()
        let partition = ((key[2].to_uint() << 8) | key[3].to_uint()).to_uint16()
        let mut producer_id = 0UL
        let mut byte = 0
        while byte < 8 {
          producer_id = (producer_id << 8) | key[4 + byte].to_uint64()
          byte = byte + 1
        }
        expired.push({ topic_id, partition, producer_id, producer_seq: seq, })
      } else {
        kept_seqs.push(state.gap_seqs[index])
        kept_times.push(state.gap_times[index])
      }
      index = index + 1
    }
    state.gap_seqs = kept_seqs
    state.gap_times = kept_times
  }
  expired
}

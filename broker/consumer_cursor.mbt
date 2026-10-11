/// Derive one partition consumer cursor from its delivery ledger.
///
/// The cursor is a materialized view of the ACK ledger: it
/// is never a truth source of its own. The delivery log (MMLQ) is truth;
/// the cursor checkpoint (MMCU) is a derived cache that may lag the log
/// and must never lead it; on any disagreement the log wins ("truth
/// hierarchy, conflicts resolve to the log", L4).
///
/// # What counts as consumed
///
/// A sequence enters the cursor when its ledger shows a durable
/// completion: an `Ack`, or a `DlqWritten` (the dead-letter record is the
/// completion of a message that will never redeliver). A `NackTerminal`
/// alone is only the intent to dead-letter -- until the DLQ record is
/// durable the floor stays behind it, so the cursor can never lead the
/// durable prefix. In-flight, retrying, fenced and quarantined sequences
/// are not consumed: they redeliver or stall honestly.
///
/// # Stability
///
/// * `ack_floor` is the longest consumed prefix: it advances over gaps
///   only when the gap itself is consumed, and never regresses.
/// * The out-of-order set is the shared 1024-bit sliding bitmap; the
///   system keeps at most `max_in_flight` = 1000 unacked
///   sequences inside the window.
/// * Recovery replays the log. A checkpoint is classified against the
///   derived result -- adopted when it agrees, lagging when behind,
///   leading when it claims past the durable prefix,
///   divergent when its window disagrees -- and never changes the result.
/// * The MMCU codec carries no CRC: a corrupt hint decodes to nothing and
///   a wrong-looking hint is rejected by the comparison against the log
///   derivation, which is the integrity check that matters.

///|
/// The MMCU checkpoint file magic (glossary MMCU).
const MMCU_MAGIC : Bytes = b"MMCU"

///|
/// The MMCU checkpoint format version.
const MMCU_FORMAT_VER : Byte = 0x01

///|
/// The MMCU checkpoint size: magic, version, two counters, 1024 window bits.
const MMCU_BYTES : Int = 149

///|
/// How a persisted checkpoint compares with the log-derived cursor.
pub(all) enum HintStatus {
  /// The checkpoint agrees with the derivation; safe to keep as cache.
  Adopted
  /// The checkpoint is behind the log; the log wins and the cache is stale.
  Lagging
  /// The checkpoint claims past the durable prefix (it led the log):
  /// discarded, the log decides.
  Leading
  /// The floor agrees but the out-of-order window disagrees.
  /// Discarded, the log decides.
  Divergent
} derive(Eq, Debug)

///|
pub extend HintStatus with Eq::{not_equal, equal}

///|
pub extend HintStatus with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The derived cache of one cursor: what MMCU persists.
///
/// Exactly the three derived parts of the design: `ack_floor` (the
/// consumed prefix), `window` (the 1024-bit out-of-order set, 16 words),
/// and `scanned` (the next scan position in the ledger stream). No
/// identity -- the file path and the group own that -- and no truth: the
/// record may lag and must never lead the log.
pub(all) struct CursorCheckpoint {
  ack_floor : UInt64
  scanned : UInt64
  window : Array[UInt64]
} derive(Eq, Debug)

///|
pub extend CursorCheckpoint with Eq::{not_equal, equal}

///|
pub extend CursorCheckpoint with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn read_uint64_be(data : BytesView, offset : Int) -> UInt64 {
  let mut value = 0UL
  for i in 0..<8 {
    value = (value << 8) | data[offset + i].to_uint64()
  }
  value
}

///|
/// Encode one checkpoint: `MMCU || ver || ack_floor u64be || scanned
/// u64be || window 16x u64be` (149 bytes).
///
/// Example:
///
/// ```mbt check
/// test {
///   let checkpoint : @broker.CursorCheckpoint = {
///     ack_floor: 0UL,
///     scanned: 0UL,
///     window: Array::make(@broker.BITMAP_WORDS, 0UL),
///   }
///   assert_eq(@broker.CursorCheckpoint::encode(checkpoint).length(), 149)
/// }
/// ```
pub fn CursorCheckpoint::encode(self : CursorCheckpoint) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(MMCU_MAGIC)
  buf.write_byte(MMCU_FORMAT_VER)
  buf.write_uint64_be(self.ack_floor)
  buf.write_uint64_be(self.scanned)
  for word in self.window {
    buf.write_uint64_be(word)
  }
  buf.contents()
}

///|
/// Decode one checkpoint; any short, foreign, or misversioned view is
/// simply not a checkpoint (the caller then trusts the log alone).
///
/// Example:
///
/// ```mbt check
/// test {
///   let checkpoint : @broker.CursorCheckpoint = {
///     ack_floor: 3UL,
///     scanned: 5UL,
///     window: Array::make(@broker.BITMAP_WORDS, 0UL),
///   }
///   let roundtrip = @broker.CursorCheckpoint::decode(
///     @broker.CursorCheckpoint::encode(checkpoint)[:],
///   )
///   assert_eq(roundtrip, Some(checkpoint))
/// }
/// ```
pub fn CursorCheckpoint::decode(data : BytesView) -> CursorCheckpoint? {
  if data.length() != MMCU_BYTES {
    return None
  }
  for index in 0..<4 {
    if data[index] != MMCU_MAGIC[index] {
      return None
    }
  }
  if data[4] != MMCU_FORMAT_VER {
    return None
  }
  let ack_floor = read_uint64_be(data, 5)
  let scanned = read_uint64_be(data, 13)
  let window : Array[UInt64] = []
  for i in 0..<BITMAP_WORDS {
    window.push(read_uint64_be(data, 21 + i * 8))
  }
  Some({ ack_floor, scanned, window, })
}

///|
/// Hold the derived cursor of one group on one (topic, partition) ledger.
///
/// Construct through `ConsumerCursor::replay` (recovery, the log is truth)
/// or `new` + `observe` (live folding); the state only ever grows out of
/// ledger events.
pub struct ConsumerCursor {
  priv group_id : UInt16
  priv bitmap : SlidingBitmap
  priv mut scanned : UInt64
}

///|
/// Start an empty cursor whose floor is `start_floor`.
///
/// `start_floor` is the first sequence the partition still owes (zero on
/// a fresh partition; the retention boundary after `delete_before`).
pub fn ConsumerCursor::new(
  group_id : UInt16,
  start_floor : UInt64,
) -> ConsumerCursor {
  { group_id, bitmap: SlidingBitmap::new(start_floor), scanned: 0UL, }
}

///|
/// Fold one ledger event into the cursor (the restart-recovery fold).
///
/// Every event advances `scanned` (the next scan position counts the
/// whole ledger stream); only events of this cursor's group move the
/// bitmap, and only a durable completion moves it: `Ack` and `DlqWritten`
/// mark the sequence consumed. Everything else -- delivery, retry,
/// fencing, terminal intent, quarantine -- leaves the floor where it is.
///
/// Example:
///
/// ```mbt check
/// test {
///   let cursor = @broker.ConsumerCursor::new(1, 0UL)
///   let event = @delivery.LedgerEvent::new(
///     group_id=1,
///     event=@delivery.LedgerEventKind::Ack,
///     sequence=0UL,
///     delivery_id=1UL,
///     owner_conn=1UL,
///     attempt=1U.to_uint16(),
///     delay_ms=0U,
///     reason=@delivery.NackReason::Retry,
///     timestamp=0UL,
///   )
///   @broker.ConsumerCursor::observe(cursor, event)
///   assert_eq(@broker.ConsumerCursor::ack_floor(cursor), 1UL)
/// }
/// ```
pub fn ConsumerCursor::observe(
  self : ConsumerCursor,
  event : @delivery.LedgerEvent,
) -> Unit {
  self.scanned = self.scanned + 1UL
  if event.group_id != self.group_id {
    return
  }
  match event.event {
    Ack | DlqWritten => ignore(SlidingBitmap::mark(self.bitmap, event.sequence))
    _ => ()
  }
}

///|
/// Read the derived cursor (O(1)): the longest consumed prefix.
///
/// This is `ack_floor`: it advances only over the
/// contiguous consumed prefix and never regresses.
pub fn ConsumerCursor::ack_floor(self : ConsumerCursor) -> UInt64 {
  SlidingBitmap::watermark(self.bitmap)
}

///|
/// Read the next scan position: ledger events folded so far.
pub fn ConsumerCursor::scanned(self : ConsumerCursor) -> UInt64 {
  self.scanned
}

///|
/// Export the derived cache (the MMCU checkpoint record).
///
/// The export may lag the log and must never lead it; persist it with
/// `encode` and treat it as a hint on the way back in.
pub fn ConsumerCursor::checkpoint(self : ConsumerCursor) -> CursorCheckpoint {
  {
    ack_floor: SlidingBitmap::watermark(self.bitmap),
    scanned: self.scanned,
    window: SlidingBitmap::snapshot(self.bitmap),
  }
}

///|
/// Classify a persisted checkpoint against the log-derived cursor.
///
/// The hint never changes the cursor; this only names the relationship:
/// `Adopted` (floor and window agree), `Lagging` (the hint is behind the
/// log), `Leading` (the hint claims past the durable prefix -- the L4
/// conflict), `Divergent` (floors agree, windows do not). `scanned` is a
/// resume hint and takes no part in the identity.
pub fn ConsumerCursor::classify_hint(
  self : ConsumerCursor,
  hint : CursorCheckpoint,
) -> HintStatus {
  let floor = SlidingBitmap::watermark(self.bitmap)
  if hint.ack_floor > floor {
    return Leading
  }
  if hint.ack_floor < floor {
    return Lagging
  }
  if hint.window != SlidingBitmap::snapshot(self.bitmap) {
    return Divergent
  }
  Adopted
}

///|
/// Recover one cursor from its ledger stream: the log is truth.
///
/// Replays every event through `observe` and returns the derived cursor;
/// an optional checkpoint is only classified (see `classify_hint`) and
/// never trusted with the result -- conflicts always resolve to the log.
///
/// Example:
///
/// ```mbt check
/// test {
///   let cursor = @broker.ConsumerCursor::replay(1, 0UL, [])
///   assert_eq(@broker.ConsumerCursor::ack_floor(cursor), 0UL)
/// }
/// ```
pub fn ConsumerCursor::replay(
  group_id : UInt16,
  start_floor : UInt64,
  events : Array[@delivery.LedgerEvent],
) -> ConsumerCursor {
  let cursor = ConsumerCursor::new(group_id, start_floor)
  for event in events {
    ConsumerCursor::observe(cursor, event)
  }
  cursor
}

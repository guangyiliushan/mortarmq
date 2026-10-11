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

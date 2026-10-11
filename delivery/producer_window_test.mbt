/// Pin the producer window rule table row by row, plus the idempotence
/// property: a retry of any sequence is never accepted twice.

///|
fn pw_registry() -> @delivery.ProducerRegistry {
  @delivery.ProducerRegistry::new()
}

///|
fn pw_admit(
  registry : @delivery.ProducerRegistry,
  seq : UInt64,
) -> Result[@delivery.ProducerOutcome, @delivery.ProducerError] {
  registry.admit(1, 0, 7, seq, 1UL, 0UL)
}

///|
async test "the next contiguous sequence is accepted and advances the frontier" {
  let registry = pw_registry()
  assert_eq(pw_admit(registry, 1UL), Ok(@delivery.Accepted))
  assert_eq(pw_admit(registry, 2UL), Ok(@delivery.Accepted))
  assert_eq(registry.drain_flushed(1, 0, 7).length(), 0)
}

///|
async test "a retry of an accepted sequence is a duplicate and writes nothing new" {
  let registry = pw_registry()
  assert_eq(pw_admit(registry, 1UL), Ok(@delivery.Accepted))
  assert_eq(pw_admit(registry, 1UL), Ok(@delivery.Duplicate))
  assert_eq(pw_admit(registry, 1UL), Ok(@delivery.Duplicate))
  assert_eq(registry.drain_flushed(1, 0, 7).length(), 0)
}

///|
async test "a sequence ahead of the gap parks and flushes when the hole fills" {
  let registry = pw_registry()
  assert_eq(pw_admit(registry, 1UL), Ok(@delivery.Accepted))
  assert_eq(pw_admit(registry, 3UL), Ok(@delivery.Pending))
  // A retry of the parked sequence parks idempotently.
  assert_eq(pw_admit(registry, 3UL), Ok(@delivery.Pending))
  assert_eq(registry.drain_flushed(1, 0, 7).length(), 0)
  assert_eq(pw_admit(registry, 2UL), Ok(@delivery.Accepted))
  let flushed = registry.drain_flushed(1, 0, 7)
  assert_eq(flushed.length(), 1)
  assert_eq(flushed[0], 3UL)
  // The flushed sequence is now a duplicate on retry.
  assert_eq(pw_admit(registry, 3UL), Ok(@delivery.Duplicate))
}

///|
async test "a gap past its budget answers the registered gap code" {
  let registry = pw_registry()
  assert_eq(pw_admit(registry, 1UL), Ok(@delivery.Accepted))
  assert_eq(registry.admit(1, 0, 7, 3UL, 1UL, 0UL), Ok(@delivery.Pending))
  // Within the budget nothing expires; past it the parked PUB is
  // reported back for a SEQ_GAP answer.
  assert_eq(registry.sweep_gaps(4000UL).length(), 0)
  let expired = registry.sweep_gaps(5001UL)
  assert_eq(expired.length(), 1)
  assert_eq(expired[0].producer_seq, 3UL)
  assert_eq(expired[0].producer_id, 7UL)
  // The retry after the timeout parks again from scratch.
  assert_eq(registry.admit(1, 0, 7, 3UL, 1UL, 6000UL), Ok(@delivery.Pending))
}

///|
async test "a sequence behind the retained window is expired" {
  let registry = pw_registry()
  let mut seq = 1UL
  while seq <= 1100UL {
    assert_eq(pw_admit(registry, seq), Ok(@delivery.Accepted))
    seq = seq + 1UL
  }
  // Inside the retained window the bit decides: accepted is duplicate.
  assert_eq(pw_admit(registry, 900UL), Ok(@delivery.Duplicate))
  // Behind the retained window nothing is retained: expired.
  assert_eq(pw_admit(registry, 1UL), Err(@delivery.ProducerError::SeqExpired))
}

///|
async test "a sequence past the window is a gap" {
  let registry = pw_registry()
  assert_eq(pw_admit(registry, 1UL), Ok(@delivery.Accepted))
  assert_eq(pw_admit(registry, 1026UL), Err(@delivery.ProducerError::SeqGap))
}

///|
async test "a request from an older epoch is refused and a newer one re-registers" {
  let registry = pw_registry()
  assert_eq(registry.admit(1, 0, 7, 1UL, 5UL, 0UL), Ok(@delivery.Accepted))
  assert_eq(
    registry.admit(1, 0, 7, 2UL, 4UL, 0UL),
    Err(@delivery.ProducerError::EpochStale),
  )
  // A newer epoch re-registers: the sequence space starts over.
  assert_eq(registry.admit(1, 0, 7, 1UL, 6UL, 0UL), Ok(@delivery.Accepted))
  assert_eq(registry.admit(1, 0, 7, 2UL, 6UL, 0UL), Ok(@delivery.Accepted))
}

///|
async test "the zero pair is counted as non-idempotent production" {
  let registry = pw_registry()
  assert_eq(registry.admit(1, 0, 0, 0UL, 1UL, 0UL), Ok(@delivery.Accepted))
  assert_eq(registry.admit(1, 0, 0, 0UL, 1UL, 0UL), Ok(@delivery.Accepted))
  assert_eq(registry.non_idempotent_count(), 2UL)
  // A positive producer id with sequence zero is behind the frontier.
  assert_eq(
    registry.admit(1, 0, 7, 0UL, 1UL, 0UL),
    Err(@delivery.ProducerError::SeqExpired),
  )
}

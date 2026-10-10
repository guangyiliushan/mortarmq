/// Exercise the four-trigger credit return policy from REQ-DEL-005:
/// 32 pending messages, 1 MiB pending bytes, the low-water marks of the
/// granted budget, and the 20 ms deadline since the first pending
/// return -- any one flushing the accumulated return.

///|
fn default_tracker() -> @broker.CreditReturnTracker {
  // A07 defaults: flush 32 / 1 MiB, low water 25% of 256 msgs / 2 MiB,
  // deadline 20 ms.
  @broker.CreditReturnTracker::with_window_defaults(256U.to_uint16(), 2097152U)
}

///|
fn above_low_water_count() -> UInt16 {
  256U.to_uint16()
}

///|
fn above_low_water_bytes() -> UInt {
  2097152U
}

///|
test "nothing pending never flushes" {
  let tracker = default_tracker()
  assert_eq(
    @broker.CreditReturnTracker::should_flush(
      tracker,
      1000UL,
      above_low_water_count(),
      above_low_water_bytes(),
    ),
    false,
  )
  assert_eq(@broker.CreditReturnTracker::take(tracker), None)
}

///|
test "returns flush at thirty-two pending messages" {
  let tracker = default_tracker()
  for _ in 0..<31 {
    @broker.CreditReturnTracker::record_ack(tracker, 0UL, 8U)
  }
  assert_eq(
    @broker.CreditReturnTracker::should_flush(
      tracker,
      0UL,
      above_low_water_count(),
      above_low_water_bytes(),
    ),
    false,
  )
  @broker.CreditReturnTracker::record_ack(tracker, 0UL, 8U)
  assert_eq(
    @broker.CreditReturnTracker::should_flush(
      tracker,
      0UL,
      above_low_water_count(),
      above_low_water_bytes(),
    ),
    true,
  )
}

///|
test "returns flush at one pending mebibyte" {
  let tracker = default_tracker()
  @broker.CreditReturnTracker::record_ack(tracker, 0UL, 524288U)
  assert_eq(
    @broker.CreditReturnTracker::should_flush(
      tracker,
      0UL,
      above_low_water_count(),
      above_low_water_bytes(),
    ),
    false,
  )
  @broker.CreditReturnTracker::record_ack(tracker, 0UL, 524288U)
  assert_eq(
    @broker.CreditReturnTracker::should_flush(
      tracker,
      0UL,
      above_low_water_count(),
      above_low_water_bytes(),
    ),
    true,
  )
}

///|
test "returns flush when the granted budget drops under the low-water mark" {
  let tracker = default_tracker()
  @broker.CreditReturnTracker::record_ack(tracker, 100UL, 8U)
  // 25% of 256 is 64 and of 2 MiB is 512 KiB: strictly under flushes.
  assert_eq(
    @broker.CreditReturnTracker::should_flush(
      tracker,
      100UL,
      63U.to_uint16(),
      2097152U,
    ),
    true,
  )
  assert_eq(
    @broker.CreditReturnTracker::should_flush(
      tracker,
      100UL,
      256U.to_uint16(),
      524287U,
    ),
    true,
  )
  assert_eq(
    @broker.CreditReturnTracker::should_flush(
      tracker,
      100UL,
      64U.to_uint16(),
      524288U,
    ),
    false,
  )
}

///|
test "returns wait for the deadline when no other trigger fired" {
  let tracker = default_tracker()
  @broker.CreditReturnTracker::record_ack(tracker, 1000UL, 8U)
  assert_eq(
    @broker.CreditReturnTracker::should_flush(
      tracker,
      1019UL,
      above_low_water_count(),
      above_low_water_bytes(),
    ),
    false,
  )
  assert_eq(
    @broker.CreditReturnTracker::should_flush(
      tracker,
      1020UL,
      above_low_water_count(),
      above_low_water_bytes(),
    ),
    true,
  )
}

///|
test "take drains the accumulator and restarts the deadline" {
  let tracker = default_tracker()
  @broker.CreditReturnTracker::record_ack(tracker, 0UL, 100U)
  assert_eq(
    @broker.CreditReturnTracker::take(tracker),
    Some({ count: 1U.to_uint16(), bytes: 100U, }),
  )
  assert_eq(@broker.CreditReturnTracker::take(tracker), None)
  // The next return counts 20 ms from its own first pending tick.
  @broker.CreditReturnTracker::record_ack(tracker, 100UL, 50U)
  assert_eq(
    @broker.CreditReturnTracker::should_flush(
      tracker,
      119UL,
      above_low_water_count(),
      above_low_water_bytes(),
    ),
    false,
  )
  assert_eq(
    @broker.CreditReturnTracker::should_flush(
      tracker,
      120UL,
      above_low_water_count(),
      above_low_water_bytes(),
    ),
    true,
  )
}

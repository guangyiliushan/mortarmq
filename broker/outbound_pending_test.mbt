/// Exercise the outbound pending approximation: the
/// queued-minus-written accounting, its saturation, and the soft/hard
/// classification whose thresholds keep their designed semantics.

///|
fn gauge(soft : Int, hard : Int) -> @broker.OutboundPending {
  @broker.OutboundPending::new(
    soft.reinterpret_as_uint(),
    hard.reinterpret_as_uint(),
  )
}

///|
test "pending tracks queued minus written" {
  let pending = gauge(750, 1000)
  assert_eq(@broker.OutboundPending::queued(pending, 1000U), @broker.SoftSlow)
  assert_eq(@broker.OutboundPending::pending_bytes(pending), 1000U)
  @broker.OutboundPending::written(pending, 400U)
  assert_eq(@broker.OutboundPending::pending_bytes(pending), 600U)
  assert_eq(@broker.OutboundPending::level(pending), @broker.Normal)
}

///|
test "levels follow the soft threshold inclusive and the hard threshold exclusive" {
  let pending = gauge(750, 1000)
  assert_eq(@broker.OutboundPending::queued(pending, 749U), @broker.Normal)
  assert_eq(@broker.OutboundPending::queued(pending, 1U), @broker.SoftSlow)
  // Exactly at the hard limit is still soft slow; the state machine
  // escalates strictly above it.
  assert_eq(@broker.OutboundPending::queued(pending, 250U), @broker.SoftSlow)
  assert_eq(@broker.OutboundPending::queued(pending, 1U), @broker.HardSlow)
}

///|
test "written saturates the gauge at zero instead of wrapping" {
  let pending = gauge(750, 1000)
  ignore(@broker.OutboundPending::queued(pending, 100U))
  @broker.OutboundPending::written(pending, 500U)
  assert_eq(@broker.OutboundPending::pending_bytes(pending), 0U)
  assert_eq(@broker.OutboundPending::level(pending), @broker.Normal)
}

///|
test "the defaults classify at 48 MiB soft and 64 MiB hard" {
  let pending = @broker.OutboundPending::with_defaults()
  assert_eq(@broker.OutboundPending::queued(pending, 50331647U), @broker.Normal)
  let gauge2 = @broker.OutboundPending::with_defaults()
  assert_eq(
    @broker.OutboundPending::queued(gauge2, 50331648U),
    @broker.SoftSlow,
  )
  let gauge3 = @broker.OutboundPending::with_defaults()
  assert_eq(
    @broker.OutboundPending::queued(gauge3, 67108864U),
    @broker.SoftSlow,
  )
  let gauge4 = @broker.OutboundPending::with_defaults()
  assert_eq(
    @broker.OutboundPending::queued(gauge4, 67108865U),
    @broker.HardSlow,
  )
}

///|
test "flushing below the soft threshold classifies normal again" {
  let pending = gauge(750, 1000)
  ignore(@broker.OutboundPending::queued(pending, 900U))
  assert_eq(@broker.OutboundPending::level(pending), @broker.SoftSlow)
  @broker.OutboundPending::written(pending, 200U)
  assert_eq(@broker.OutboundPending::level(pending), @broker.Normal)
}

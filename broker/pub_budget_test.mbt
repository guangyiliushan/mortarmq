/// Exercise the connection PUB budget:
/// exact count and byte caps, explicit actionable refusals that land on
/// the registered 0x4001/0x4002 codes, saturating completions, and the
/// slow-PUB acceptance case -- freeze completions, flood publishes, and
/// prove the budget never lets the outstanding volume leave its cap.

///|
fn small_budget(max_count : Int32, max_bytes : Int32) -> @broker.PubBudget {
  @broker.PubBudget::new(max_count.to_uint16(), max_bytes.reinterpret_as_uint())
}

///|
/// Whether both gauges of one budget stay inside their caps.
fn budget_bounded(
  report : @broker.PubReport,
  max_count : Int32,
  max_bytes : Int32,
) -> Bool {
  report.outstanding_count <= max_count.to_uint16() &&
  report.outstanding_bytes <= max_bytes.reinterpret_as_uint()
}

///|
test "a frozen producer stops at the count budget with explicit rejections" {
  let budget = small_budget(256, 8388608)
  let mut admitted = 0
  for _ in 0..<1000 {
    match @broker.PubBudget::admit(budget, 4096U) {
      Ok(_) => admitted = admitted + 1
      Err(err) => assert_eq(err, @broker.OverBudgetCount)
    }
  }
  assert_eq(admitted, 256)
  let report = @broker.PubBudget::report(budget)
  assert_eq(report.outstanding_count, 256U.to_uint16())
  assert_eq(report.outstanding_bytes, 1048576U)
  assert_eq(budget_bounded(report, 256, 8388608), true)
}

///|
test "slow completions reopen the budget without ever exceeding it" {
  let budget = small_budget(8, 8192)
  // Freeze completions and fill the budget.
  for _ in 0..<8 {
    assert_eq(@broker.PubBudget::admit(budget, 1024U) is Ok(_), true)
  }
  assert_eq(
    @broker.PubBudget::admit(budget, 1024U),
    Err(@broker.OverBudgetCount),
  )
  // Completions trickle in one at a time; each one frees exactly one
  // slot and the bounds hold after every step.
  for _ in 0..<40 {
    @broker.PubBudget::complete(budget, 1024U)
    assert_eq(budget_bounded(@broker.PubBudget::report(budget), 8, 8192), true)
    match @broker.PubBudget::admit(budget, 1024U) {
      Ok(_) => ()
      Err(err) => assert_eq(err, @broker.OverBudgetCount)
    }
    assert_eq(budget_bounded(@broker.PubBudget::report(budget), 8, 8192), true)
  }
  assert_eq(budget_bounded(@broker.PubBudget::report(budget), 8, 8192), true)
}

///|
test "the byte budget rejects exactly the payload that would overflow it" {
  let budget = small_budget(10, 1000)
  assert_eq(@broker.PubBudget::admit(budget, 600U) is Ok(_), true)
  // 400 lands exactly on the cap and is accepted; one byte more is not.
  assert_eq(@broker.PubBudget::admit(budget, 400U) is Ok(_), true)
  assert_eq(@broker.PubBudget::admit(budget, 1U), Err(@broker.OverBudgetBytes))
  assert_eq(@broker.PubBudget::report(budget).outstanding_bytes, 1000U)
  // The count cap is reached first here only after completions; the
  // byte cap keeps its own answer while count still has room.
  assert_eq(@broker.PubBudget::report(budget).outstanding_count, 2U.to_uint16())
}

///|
test "completions saturate the gauges instead of wrapping" {
  let budget = small_budget(2, 1000)
  @broker.PubBudget::complete(budget, 5000U)
  @broker.PubBudget::complete(budget, 1U)
  assert_eq(@broker.PubBudget::report(budget).outstanding_count, 0U.to_uint16())
  assert_eq(@broker.PubBudget::report(budget).outstanding_bytes, 0U)
}

///|
test "over-budget refusals map to the registered 0x4001 and 0x4002 codes" {
  assert_eq(
    @broker.PubError::OverBudgetCount.to_err_code().to_uint16(),
    0x4001U,
  )
  assert_eq(
    @broker.PubError::OverBudgetBytes.to_err_code().to_uint16(),
    0x4002U,
  )
  assert_eq(
    @protocol.ErrCode::from_uint16(
      @broker.PubError::OverBudgetCount.to_err_code().to_uint16(),
    ),
    Some(@protocol.Backpressure),
  )
  assert_eq(
    @protocol.ErrCode::from_uint16(
      @broker.PubError::OverBudgetBytes.to_err_code().to_uint16(),
    ),
    Some(@protocol.QuotaExceeded),
  )
}

///|
test "the defaults match the documented parameter set" {
  let budget = @broker.PubBudget::with_defaults()
  assert_eq(@broker.PubBudget::admit(budget, 8388608U) is Ok(_), true)
  assert_eq(@broker.PubBudget::report(budget).outstanding_count, 1U.to_uint16())
  // 256 outstanding PUBs is the count cap at the defaults.
  let count_cap = @broker.PubBudget::with_defaults()
  for _ in 0..<256 {
    assert_eq(@broker.PubBudget::admit(count_cap, 0U) is Ok(_), true)
  }
  assert_eq(
    @broker.PubBudget::admit(count_cap, 0U),
    Err(@broker.OverBudgetCount),
  )
}

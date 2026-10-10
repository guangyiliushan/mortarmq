/// Prove the T053 mapping surface lands every credit refusal in the
/// registered code table (L1: the refusal codes are registry members),
/// that the pairing is total and injective, and that the one documented
/// stretch -- unknown subscription -- names the registered re-SUB
/// action code rather than inventing one.

///|
/// Membership in the registry is a round trip: the code's wire value
/// decodes back to the same constructor.
fn registered(code : @protocol.ErrCode) -> Bool {
  match @protocol.ErrCode::from_uint16(code.to_uint16()) {
    None => false
    Some(decoded) => decoded == code
  }
}

///|
test "every credit refusal maps to a registered wire code" {
  let mapped = [
    @broker.CreditError::Backpressure.to_err_code(),
    @broker.CreditError::NoCredit.to_err_code(),
    @broker.CreditError::MessageExceedsCredit.to_err_code(),
    @broker.CreditError::StaleGeneration.to_err_code(),
    @broker.CreditError::UnknownSubscription.to_err_code(),
  ]
  for code in mapped {
    assert_eq(registered(code), true)
  }
}

///|
test "the overload refusals map to the registered 0x4xxx backpressure family" {
  // Decision 5 and REQ-DEL-007: explicit refusal, actionable code, no
  // new codes -- the 0x4xxx range is exactly what the registry holds.
  assert_eq(
    @broker.CreditError::Backpressure.to_err_code().to_uint16(),
    0x4001U,
  )
  assert_eq(
    @broker.CreditError::MessageExceedsCredit.to_err_code().to_uint16(),
    0x4005U,
  )
  assert_eq(@broker.CreditError::NoCredit.to_err_code().to_uint16(), 0x4006U)
  assert_eq(
    @protocol.ErrCode::from_uint16(0x4001U),
    Some(@protocol.Backpressure),
  )
  assert_eq(
    @protocol.ErrCode::from_uint16(0x4005U),
    Some(@protocol.MessageExceedsCredit),
  )
  assert_eq(@protocol.ErrCode::from_uint16(0x4006U), Some(@protocol.NoCredit))
}

///|
test "the mapping is injective: no two refusals share a code" {
  let codes = [
    @broker.CreditError::Backpressure.to_err_code().to_uint16(),
    @broker.CreditError::NoCredit.to_err_code().to_uint16(),
    @broker.CreditError::MessageExceedsCredit.to_err_code().to_uint16(),
    @broker.CreditError::StaleGeneration.to_err_code().to_uint16(),
    @broker.CreditError::UnknownSubscription.to_err_code().to_uint16(),
  ]
  for i in 0..<codes.length() {
    for j in 0..<codes.length() {
      if j > i {
        assert_eq(codes[i] == codes[j], false)
      }
    }
  }
}

///|
test "an unknown subscription maps to the registered re-SUB action code" {
  // The documented stretch: no 0x4xxx successor for the retired
  // SUBSCRIPTION_CREDIT_UNKNOWN, so the mapping names StaleOwner whose
  // registered client action is re-SUB / re-PULL -- how a client
  // rebuilds a discarded credit window.
  assert_eq(
    @broker.CreditError::UnknownSubscription.to_err_code(),
    @protocol.StaleOwner,
  )
  assert_eq(
    @broker.CreditError::UnknownSubscription.to_err_code().to_uint16(),
    0x0022U,
  )
}

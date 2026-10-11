/// Prove the delivery mapping surface lands every refusal in the
/// registered code table, unlocks the two previously stranded codes
/// (0x4004 STORAGE_HIGH_WATERMARK, 0x0031 DLQ_UNAVAILABLE), and keeps
/// the documented shared targets in their families.

///|
/// Membership in the registry is a round trip: the code's wire value
/// decodes back to the same constructor.
fn delivery_registered(code : @protocol.ErrCode) -> Bool {
  match @protocol.ErrCode::from_uint16(code.to_uint16()) {
    None => false
    Some(decoded) => decoded == code
  }
}

///|
test "every delivery refusal maps to a registered wire code" {
  let mapped = [
    @delivery.DeliveryError::UnknownDelivery.to_err_code(),
    @delivery.DeliveryError::StaleOwner.to_err_code(),
    @delivery.DeliveryError::AlreadyAcked.to_err_code(),
    @delivery.DeliveryError::AlreadyDeadLettered.to_err_code(),
    @delivery.DeliveryError::InvalidTransition.to_err_code(),
    @delivery.DeliveryError::DlqPathOverflow.to_err_code(),
    @delivery.DeliveryError::DlqUnavailable.to_err_code(),
    @delivery.DeliveryError::Capacity.to_err_code(),
    @delivery.DeliveryError::Malformed.to_err_code(),
    @delivery.DeliveryError::DiskFault(@harness.DiskFull).to_err_code(),
  ]
  for code in mapped {
    assert_eq(delivery_registered(code), true)
  }
}

///|
test "the capacity refusal unlocks the registered 0x4004 code" {
  assert_eq(
    @delivery.DeliveryError::Capacity.to_err_code().to_uint16(),
    0x4004U,
  )
}

///|
test "the DLQ unavailability unlocks the registered 0x0031 code" {
  assert_eq(
    @delivery.DeliveryError::DlqUnavailable.to_err_code().to_uint16(),
    0x0031U,
  )
}

///|
test "the fence and no-op families land on their registered codes" {
  assert_eq(
    @delivery.DeliveryError::StaleOwner.to_err_code().to_uint16(),
    0x0022U,
  )
  assert_eq(
    @delivery.DeliveryError::UnknownDelivery.to_err_code().to_uint16(),
    0x0023U,
  )
  // The shared no-op family: nothing left to do, carry on.
  assert_eq(
    @delivery.DeliveryError::AlreadyAcked.to_err_code(),
    @delivery.DeliveryError::UnknownDelivery.to_err_code(),
  )
  assert_eq(
    @delivery.DeliveryError::AlreadyDeadLettered.to_err_code(),
    @delivery.DeliveryError::UnknownDelivery.to_err_code(),
  )
  // The loop-guard overflow keeps its registered quarantine code.
  assert_eq(
    @delivery.DeliveryError::DlqPathOverflow.to_err_code().to_uint16(),
    0x0030U,
  )
}

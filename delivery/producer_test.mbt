/// Pin the publish admission combination rule and its registered codes.

///|
fn producer_registered(code : @protocol.ErrCode) -> Bool {
  match @protocol.ErrCode::from_uint16(code.to_uint16()) {
    None => false
    Some(decoded) => decoded == code
  }
}

///|
test "the zero pair is allowed as non-idempotent production" {
  assert_eq(@delivery.validate_producer_fields(0UL, 0UL), Ok(()))
  assert_eq(@delivery.is_non_idempotent(0UL, 0UL), true)
  assert_eq(@delivery.is_non_idempotent(1UL, 0UL), false)
}

///|
test "a zero producer id with a positive sequence is refused" {
  assert_eq(
    @delivery.validate_producer_fields(0UL, 1UL),
    Err(@delivery.ProducerError::SeqInvalid),
  )
  assert_eq(
    @delivery.validate_producer_fields(0UL, 9UL),
    Err(@delivery.ProducerError::SeqInvalid),
  )
}

///|
test "a positive producer id passes through to the window" {
  assert_eq(@delivery.validate_producer_fields(1UL, 0UL), Ok(()))
  assert_eq(@delivery.validate_producer_fields(7UL, 42UL), Ok(()))
}

///|
test "every producer refusal maps to a registered wire code" {
  let mapped = [
    @delivery.ProducerError::SeqInvalid.to_err_code(),
    @delivery.ProducerError::SeqGap.to_err_code(),
    @delivery.ProducerError::SeqExpired.to_err_code(),
    @delivery.ProducerError::EpochStale.to_err_code(),
  ]
  for code in mapped {
    assert_eq(producer_registered(code), true)
  }
  assert_eq(
    @delivery.ProducerError::SeqInvalid.to_err_code().to_uint16(),
    0x0013U,
  )
  assert_eq(@delivery.ProducerError::SeqGap.to_err_code().to_uint16(), 0x0010U)
  assert_eq(
    @delivery.ProducerError::SeqExpired.to_err_code().to_uint16(),
    0x0011U,
  )
  assert_eq(
    @delivery.ProducerError::EpochStale.to_err_code().to_uint16(),
    0x0012U,
  )
}

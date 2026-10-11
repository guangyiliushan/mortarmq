/// Prove the metadata mapping surface lands every refusal in the
/// registered code table (REQ-PRO-004), that the pairing is total and
/// injective, and that no module emits a raw numeric code.

///|
/// Membership in the registry is a round trip: the code's wire value
/// decodes back to the same constructor.
fn md_registered(code : @protocol.ErrCode) -> Bool {
  match @protocol.ErrCode::from_uint16(code.to_uint16()) {
    None => false
    Some(decoded) => decoded == code
  }
}

///|
test "every metadata fault maps to a registered wire code" {
  let mapped = [
    @metadata.Malformed.to_err_code(),
    @metadata.Corruption(64U).to_err_code(),
    @metadata.DiskFault(@harness.DiskFull).to_err_code(),
  ]
  for code in mapped {
    assert_eq(md_registered(code), true)
  }
}

///|
test "metadata faults land in the registered 0x0xxx and 0x2xxx families" {
  // REQ-PRO-004 segments: 0x0xxx protocol/session, 0x2xxx metadata.
  assert_eq(@metadata.Malformed.to_err_code(), @protocol.MalformedPayload)
  assert_eq(@metadata.Malformed.to_err_code().to_uint16(), 0x0003U)
  assert_eq(@metadata.Corruption(0U).to_err_code(), @protocol.MetadataReadOnly)
  assert_eq(@metadata.Corruption(0U).to_err_code().to_uint16(), 0x2003U)
  assert_eq(
    @metadata.DiskFault(@harness.Killed).to_err_code(),
    @protocol.Internal,
  )
  assert_eq(
    @metadata.DiskFault(@harness.Killed).to_err_code().to_uint16(),
    0x000AU,
  )
  assert_eq(
    @protocol.ErrCode::from_uint16(0x2003U),
    Some(@protocol.MetadataReadOnly),
  )
}

///|
test "the metadata fault mapping is injective" {
  let codes = [
    @metadata.Malformed.to_err_code(),
    @metadata.Corruption(0U).to_err_code(),
    @metadata.DiskFault(@harness.DiskFull).to_err_code(),
  ]
  for i in 0..<codes.length() {
    for j in 0..<codes.length() {
      if i != j {
        assert_eq(codes[i] == codes[j], false)
      }
    }
  }
}

///|
test "the guard emits only registered constructors, never raw codes" {
  let gate = @metadata.MetadataGuard::new()
  assert_eq(gate.write_refusal(), None)
  gate.note_log_corruption(64U, 40U)
  match gate.write_refusal() {
    None => fail("a degraded guard must refuse")
    Some(code) => {
      assert_eq(md_registered(code), true)
      assert_eq(code, @protocol.MetadataReadOnly)
    }
  }
  gate.escalate_to_quarantine()
  match gate.write_refusal() {
    None => fail("a quarantined guard must refuse")
    Some(code) => {
      assert_eq(md_registered(code), true)
      assert_eq(code, @protocol.MetadataQuarantined)
    }
  }
}

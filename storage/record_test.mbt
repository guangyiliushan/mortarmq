/// Exercise the frozen 56-byte v0 storage record header.

///|
fn valid_header() -> @storage.RecordHeader {
  @storage.RecordHeader::new(
    flags=1,
    key_length=3,
    value_length=5,
    sequence=100UL,
    producer_id=3UL,
    producer_seq=4UL,
    timestamp_unix_ms=200UL,
    leader_epoch=0,
    replication_flags=0,
  )
}

///|
fn valid_bytes() -> Bytes raise {
  match @storage.encode_record_header(valid_header(), b"key", b"value") {
    Ok(bytes) => bytes
    Err(_) => fail("header encoding failed")
  }
}

///|
test "record header round-trips all frozen fields" {
  let bytes = valid_bytes()
  assert_eq(bytes.length(), 4 + 60)
  match @storage.decode_record_header(bytes[:]) {
    Ok(decoded) => assert_eq(decoded, valid_header())
    Err(_) => fail("header decoding failed")
  }
}

///|
test "record header rejects CRC corruption" {
  let bytes = valid_bytes()
  let corrupted = bytes[:8].to_owned() + b"\xff" + bytes[9:].to_owned()
  match @storage.decode_record_header(corrupted[:]) {
    Err(@storage.Malformed) => assert_eq(true, true)
    _ => fail("expected CRC corruption rejection")
  }
}

///|
test "record header rejects inconsistent and oversized lengths" {
  let bytes = valid_bytes()
  let bad_record_length = b"\x00\x00\x00\x1e" + bytes[4:].to_owned()
  match @storage.decode_record_header(bad_record_length[:]) {
    Err(@storage.Malformed) => assert_eq(true, true)
    _ => fail("expected record-length mismatch rejection")
  }
  let bad_value_length = bytes[:12].to_owned() +
    b"\xff\xff\xfc\x01" +
    bytes[16:].to_owned()
  match @storage.decode_record_header(bad_value_length[:]) {
    Err(@storage.Malformed) => assert_eq(true, true)
    _ => fail("expected oversized value rejection")
  }
}

///|
test "record header rejects reserved flag and replication bits" {
  let bytes = valid_bytes()
  let bad_flags = bytes[:8].to_owned() + b"\x00\x04" + bytes[10:].to_owned()
  match @storage.decode_record_header(bad_flags[:]) {
    Err(@storage.Malformed) => assert_eq(true, true)
    _ => fail("expected reserved flag rejection")
  }
  let bad_replication = bytes[:52].to_owned() + b"\x04" + bytes[53:].to_owned()
  match @storage.decode_record_header(bad_replication[:]) {
    Err(@storage.Malformed) => assert_eq(true, true)
    _ => fail("expected reserved replication-kind rejection")
  }
}

///|
test "record header rejects nonzero reserved bytes" {
  let bytes = valid_bytes()
  let reserved = bytes[:53].to_owned() + b"\x01\x00\x00"
  match @storage.decode_record_header(reserved[:]) {
    Err(@storage.Malformed) => assert_eq(true, true)
    _ => fail("expected reserved-byte rejection")
  }
}

///|
test "record header rejects key-presence mismatch" {
  let bytes = valid_bytes()
  let missing_key_flag = bytes[:8].to_owned() +
    b"\x00\x00" +
    bytes[10:].to_owned()
  match @storage.decode_record_header(missing_key_flag[:]) {
    Err(@storage.Malformed) => assert_eq(true, true)
    _ => fail("expected missing key-flag rejection")
  }
}

///|
test "segment identity validates MMS and format/header versions" {
  let bytes : Bytes = b"MMQS\x01\x01\x00\x00"
  assert_eq(@storage.validate_segment_identity(bytes[:]), Ok(()))
  let bad_magic : Bytes = b"MMQT\x01\x01\x00\x00"
  assert_eq(
    @storage.validate_segment_identity(bad_magic[:]),
    Err(@storage.Malformed),
  )
  let bad_version : Bytes = b"MMQS\x01\x02\x00\x00"
  assert_eq(
    @storage.validate_segment_identity(bad_version[:]),
    Err(@storage.Malformed),
  )
}

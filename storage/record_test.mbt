/// Exercise the frozen 56-byte v0 storage record header.

///|
fn valid_header() -> @storage.RecordHeader {
  @storage.RecordHeader::new(
    flags=0,
    key_length=3,
    value_length=5,
    sequence=100UL,
    producer_id=3UL,
    producer_seq=4UL,
    timestamp_unix_ms=200UL,
    leader_epoch=0,
    replication_flags=0,
    record_crc32c=6,
  )
}

///|
fn valid_bytes() -> Bytes {
  @storage.encode_record_header(valid_header(), b"key", b"value")
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
test "record header rejects inconsistent and oversized lengths" {
  let header = valid_header()
  let bytes = @storage.encode_record_header(header, b"key", b"value")
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
/// Decode a hand-built v0 record to pin every field and byte order.

///|
test "record header decodes a hand-built frozen-layout vector" {
  let header = valid_header()
  let bytes : Bytes = b"\x00\x00\x00\x3c\x00\x00\x00\x06\x00\x00\x00\x03\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x64\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\xc8\x00\x00\x00\x00\x00\x00\x00\x00keyvalue"
  assert_eq(bytes, @storage.encode_record_header(header, b"key", b"value"))
  match @storage.decode_record_header(bytes[:]) {
    Ok(decoded) => assert_eq(decoded, header)
    Err(_) => fail("expected hand-built record to decode")
  }
}

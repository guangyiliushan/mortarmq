///|
test "CRC32C known answer" {
  assert_eq(crc32c(b"123456789"), 0xE3069283U)
}

///|
test "record encoder matches the hand-built frozen-layout vector" {
  let expected : Bytes = b"\x00\x00\x00\x3c\x25\x27\x66\x56\x00\x01\x00\x03\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x64\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\xc8\x00\x00\x00\x00\x00\x00\x00\x00keyvalue"
  let header : RecordHeader = {
    flags: 1,
    key_length: 3,
    value_length: 5,
    sequence: 100UL,
    producer_id: 3UL,
    producer_seq: 4UL,
    timestamp_unix_ms: 200UL,
    leader_epoch: 0,
    replication_flags: 0,
  }
  assert_eq(encode_record_header(header, b"key", b"value"), Ok(expected))
  match decode_record_header(expected[:]) {
    Ok(decoded) => assert_eq(decoded, header)
    Err(_) => fail("expected golden vector to decode")
  }
}

/// Pin CRC32C behavior and the byte-exact frozen v0 record encoder contract.

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

///|
fn crc_repaired(bytes : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(bytes[:4].to_owned())
  buf.write_uint_be(crc32c(bytes[8:]))
  buf.write_bytes(bytes[8:].to_owned())
  buf.contents()
}

///|
test "decoder rejects CRC-valid key-presence mismatches" {
  let keyed = encode_record_header(
    {
      flags: 1,
      key_length: 3,
      value_length: 5,
      sequence: 100UL,
      producer_id: 3UL,
      producer_seq: 4UL,
      timestamp_unix_ms: 200UL,
      leader_epoch: 0,
      replication_flags: 0,
    },
    b"key",
    b"value",
  )
  let keyed_result = match keyed {
    Ok(bytes) => bytes
    Err(_) => fail("keyed fixture encoding failed")
  }
  let missing_flag = crc_repaired(
    keyed_result[:8].to_owned() + b"\x00\x00" + keyed_result[10:].to_owned(),
  )
  assert_eq(decode_record_header(missing_flag[:]), Err(Malformed))

  let unkeyed = encode_record_header(
    {
      flags: 0,
      key_length: 0,
      value_length: 5,
      sequence: 100UL,
      producer_id: 3UL,
      producer_seq: 4UL,
      timestamp_unix_ms: 200UL,
      leader_epoch: 0,
      replication_flags: 0,
    },
    b"",
    b"value",
  )
  let unkeyed_result = match unkeyed {
    Ok(bytes) => bytes
    Err(_) => fail("unkeyed fixture encoding failed")
  }
  let extra_flag = crc_repaired(
    unkeyed_result[:8].to_owned() + b"\x00\x01" + unkeyed_result[10:].to_owned(),
  )
  assert_eq(decode_record_header(extra_flag[:]), Err(Malformed))
}

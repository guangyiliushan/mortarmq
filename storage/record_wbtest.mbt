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

///|
/// RFC 7143 A.4 known-answer vectors (iSCSI CRC32C). The RFC prints each
/// CRC as four little-endian bytes; both the numeric value and the printed
/// little-endian byte order are pinned. The "123456789" check value above
/// (0xE3069283) is the auxiliary anchor for the same convention.

///|
fn kat_le4(value : UInt32) -> Bytes {
  let buf = Buffer()
  buf.write_uint_le(value)
  buf.contents()
}

///|
fn kat_32_uniform(fill : Byte) -> Bytes {
  Bytes::make(32, fill)
}

///|
fn kat_32_incrementing() -> Bytes {
  let buf = Buffer()
  let mut i = 0
  while i < 32 {
    buf.write_byte(i.to_byte())
    i = i + 1
  }
  buf.contents()
}

///|
fn kat_32_decrementing() -> Bytes {
  let buf = Buffer()
  let mut i = 31
  while i >= 0 {
    buf.write_byte(i.to_byte())
    i = i - 1
  }
  buf.contents()
}

///|
fn kat_read10_pdu() -> Bytes {
  b"\x01\xc0\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x14\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x14\x00\x00\x00\x18\x28\x00\x00\x00\x00\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00"
}

///|
test "CRC32C matches the five RFC 7143 A.4 vectors" {
  // 32 bytes of zeroes.
  assert_eq(crc32c(kat_32_uniform(b'\x00')), 0x8a9136aaU)
  assert_eq(kat_le4(0x8a9136aaU), b"\xaa\x36\x91\x8a")
  // 32 bytes of ones.
  assert_eq(crc32c(kat_32_uniform(b'\xff')), 0x62a8ab43U)
  assert_eq(kat_le4(0x62a8ab43U), b"\x43\xab\xa8\x62")
  // 32 bytes incrementing 0x00..0x1f.
  assert_eq(crc32c(kat_32_incrementing()), 0x46dd794eU)
  assert_eq(kat_le4(0x46dd794eU), b"\x4e\x79\xdd\x46")
  // 32 bytes decrementing 0x1f..0x00.
  assert_eq(crc32c(kat_32_decrementing()), 0x113fdb5cU)
  assert_eq(kat_le4(0x113fdb5cU), b"\x5c\xdb\x3f\x11")
  // An iSCSI SCSI Read(10) Command PDU.
  assert_eq(crc32c(kat_read10_pdu()), 0xd9963a56U)
  assert_eq(kat_le4(0xd9963a56U), b"\x56\x3a\x96\xd9")
}

///|
test "CRC32C residue is constant under little-endian CRC append" {
  // Receiver-side check: CRC32C over message || LE32(CRC32C(message))
  // equals a constant residue regardless of the message.
  let messages : Array[Bytes] = [
    b"",
    b"a",
    b"123456789",
    kat_32_uniform(b'\x00'),
    kat_32_incrementing(),
    kat_read10_pdu(),
    b"mortarmq storage seal",
  ]
  for message in messages {
    let buf = Buffer()
    buf.write_bytes(message)
    buf.write_uint_le(crc32c(message))
    assert_eq(crc32c(buf.contents()), 0x48674bc7U)
  }
}

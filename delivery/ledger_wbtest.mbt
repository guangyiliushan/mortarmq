/// Pin the CRC32C behavior and the byte-exact frozen v0 ledger-event layout.

///|
test "CRC32C known answer" {
  assert_eq(crc32c(b"123456789"), 0xE3069283U)
}

///|
test "ledger event encoder matches the hand-built frozen-layout vector" {
  let expected : Bytes = b"\x4d\x4d\x4c\x51\x01\x01\x00\x01\x02\x00\x00\x00\x00\x00\x00\x00\x64\x00\x00\x00\x00\x00\x00\x00\x07\x00\x00\x00\x00\x00\x00\x00\x03\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xc8\x1f\x0e\x18\xb1"
  let event = LedgerEvent::new(
    group_id=1,
    event=Ack,
    sequence=100UL,
    delivery_id=7UL,
    owner_conn=3UL,
    attempt=2,
    delay_ms=0U,
    reason=Retry,
    timestamp=200UL,
  )
  assert_eq(encode_ledger_event(event), expected)
  match decode_ledger_event(expected[:]) {
    Ok(decoded) => assert_eq(decoded, event)
    Err(_) => fail("expected golden vector to decode")
  }
}

///|
test "ledger path predicate anchors on the frozen file name" {
  assert_eq(is_ledger_path(b"delivery.mql"), true)
  assert_eq(is_ledger_path(b"data/partitions/0001/0000/delivery.mql"), true)
  assert_eq(
    is_ledger_path(b"data/partitions/0001/0000/segment-0000.bin"),
    false,
  )
  assert_eq(is_ledger_path(b"delivery.mql.bak"), false)
  assert_eq(is_ledger_path(b""), false)
}

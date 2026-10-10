/// Exercise the frozen 52-byte v0 delivery-ledger event log and its write
/// path, including the L1 property that ledger streams and message-record
/// streams never mix.

///|
fn no_gate(_bytes : Int) -> Result[Unit, @delivery.LedgerFault] {
  Ok(())
}

///|
fn sample_event(event : @delivery.LedgerEventKind) -> @delivery.LedgerEvent {
  @delivery.LedgerEvent::new(
    group_id=1,
    event~,
    sequence=100UL,
    delivery_id=7UL,
    owner_conn=3UL,
    attempt=2,
    delay_ms=0U,
    reason=@delivery.Retry,
    timestamp=200UL,
  )
}

///|
test "ledger event round-trips all frozen fields" {
  let event = @delivery.LedgerEvent::new(
    group_id=513,
    event=@delivery.DlqWritten,
    sequence=0xFFFFFFFFFFFFFFF6UL,
    delivery_id=0xFFFFFFFFFFFFFFF7UL,
    owner_conn=0xFFFFFFFFFFFFFFF8UL,
    attempt=0xFFFF,
    delay_ms=0xFFFFFFF9U,
    reason=@delivery.Poison,
    timestamp=0xFFFFFFFFFFFFFFFAUL,
  )
  let bytes = @delivery.encode_ledger_event(event)
  assert_eq(bytes.length(), @delivery.LEDGER_EVENT_BYTES)
  match @delivery.decode_ledger_event(bytes[:]) {
    Ok(decoded) => assert_eq(decoded, event)
    Err(_) => fail("event decoding failed")
  }
}

///|
test "ledger event rejects CRC corruption and truncation" {
  let bytes = @delivery.encode_ledger_event(sample_event(@delivery.Ack))
  let corrupted = bytes[:10].to_owned() + b"\xff" + bytes[11:].to_owned()
  match @delivery.decode_ledger_event(corrupted[:]) {
    Err(@delivery.Malformed) => assert_eq(true, true)
    _ => fail("expected CRC corruption rejection")
  }
  match @delivery.decode_ledger_event(bytes[:51]) {
    Err(@delivery.Malformed) => assert_eq(true, true)
    _ => fail("expected short-view rejection")
  }
}

///|
test "ledger event rejects foreign magic, versions, and codes" {
  let bytes = @delivery.encode_ledger_event(sample_event(@delivery.Ack))
  let bad_magic = b"MMQS" + bytes[4:].to_owned()
  match @delivery.decode_ledger_event(bad_magic[:]) {
    Err(@delivery.Malformed) => assert_eq(true, true)
    _ => fail("expected foreign-magic rejection")
  }
  let bad_format_ver = bytes[:4].to_owned() + b"\x02" + bytes[5:].to_owned()
  match @delivery.decode_ledger_event(bad_format_ver[:]) {
    Err(@delivery.Malformed) => assert_eq(true, true)
    _ => fail("expected format-version rejection")
  }
  let bad_event_code = bytes[:8].to_owned() + b"\x0a" + bytes[9:].to_owned()
  match @delivery.decode_ledger_event(bad_event_code[:]) {
    Err(@delivery.Malformed) => assert_eq(true, true)
    _ => fail("expected unknown-event-code rejection")
  }
  let bad_reason_code = bytes[:39].to_owned() + b"\x04" + bytes[40:].to_owned()
  match @delivery.decode_ledger_event(bad_reason_code[:]) {
    Err(@delivery.Malformed) => assert_eq(true, true)
    _ => fail("expected unknown-reason-code rejection")
  }
}

///|
test "ledger writer refuses non-ledger paths" {
  match
    @delivery.LedgerWriter::new(b"data/partitions/0001/0000/segment-0000.bin") {
    Err(@delivery.Malformed) => assert_eq(true, true)
    _ => fail("expected non-ledger path rejection")
  }
  match @delivery.LedgerWriter::new(b"data/partitions/0001/0000/delivery.mql") {
    Ok(writer) => assert_eq(writer.unflushed_events(), 0)
    Err(_) => fail("expected ledger path acceptance")
  }
}

///|
async test "capacity gate rejection writes nothing" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let rejecting = (_bytes : Int) => Err(@delivery.Capacity)
  match writer.append(disk, sample_event(@delivery.Deliver), rejecting) {
    Err(@delivery.Capacity) => assert_eq(true, true)
    _ => fail("expected capacity rejection")
  }
  match disk.read(path) {
    Err(@harness.PathMissing) => assert_eq(true, true)
    _ => fail("expected no bytes on disk after gate rejection")
  }
}

///|
async test "ledger writer group-syncs every 128 events" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  for index in 0..<127 {
    match writer.append(disk, sample_event(@delivery.Deliver), no_gate) {
      Ok(_) => ()
      Err(_) => fail("append failed")
    }
    assert_eq(writer.unflushed_events(), index + 1)
  }
  match writer.append(disk, sample_event(@delivery.Deliver), no_gate) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  assert_eq(writer.unflushed_events(), 0)
}

///|
async test "ledger and record streams never mix (L1)" {
  let disk = @harness.FakeDisk::new()
  let ledger_path = b"data/partitions/0001/0000/delivery.mql"
  let segment_path = b"data/partitions/0001/0000/segment-0000.bin"
  let writer = match @delivery.LedgerWriter::new(ledger_path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let first = sample_event(@delivery.Deliver)
  let second = sample_event(@delivery.Ack)
  match writer.append(disk, first, no_gate) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  match writer.append(disk, second, no_gate) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  match writer.sync(disk) {
    Ok(_) => ()
    Err(_) => fail("sync failed")
  }
  // Record side: a real MMQS identity header plus a real storage record.
  let header = @storage.RecordHeader::new(
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
  let record = match @storage.encode_record_header(header, b"key", b"value") {
    Ok(bytes) => bytes
    Err(_) => fail("record encoding failed")
  }
  let segment = b"MMQS\x01\x01" + record
  match disk.write(segment_path, segment) {
    Ok(_) => ()
    Err(_) => fail("segment write failed")
  }
  // The ledger scan only accepts ledger events, exactly the two appended.
  match @delivery.read_ledger_events(disk, ledger_path) {
    Ok(events) => {
      assert_eq(events.length(), 2)
      assert_eq(events[0], first)
      assert_eq(events[1], second)
    }
    Err(_) => fail("ledger scan failed")
  }
  // A record stream yields no ledger events.
  match @delivery.read_ledger_events(disk, segment_path) {
    Ok(events) => assert_eq(events.length(), 0)
    Err(_) => fail("record stream must scan as an empty ledger")
  }
  // The record side rejects the ledger stream at both of its trust boundaries.
  let ledger_bytes = match disk.read(ledger_path) {
    Ok(data) => data
    Err(_) => fail("ledger read failed")
  }
  match @storage.validate_segment_identity(ledger_bytes[:]) {
    Err(@storage.Malformed) => assert_eq(true, true)
    _ => fail("expected ledger stream to fail segment identity")
  }
  match @storage.decode_record_header(ledger_bytes[:]) {
    Err(@storage.Malformed) => assert_eq(true, true)
    _ => fail("expected ledger stream to fail record decoding")
  }
}

///|
async test "ledger scan stops at a torn tail" {
  let disk = @harness.FakeDisk::new()
  let ledger_path = b"data/partitions/0001/0000/delivery.mql"
  let writer = match @delivery.LedgerWriter::new(ledger_path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let first = sample_event(@delivery.Deliver)
  match writer.append(disk, first, no_gate) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  let torn = @delivery.encode_ledger_event(sample_event(@delivery.Ack))
  let existing = match disk.read(ledger_path) {
    Ok(data) => data
    Err(_) => fail("ledger read failed")
  }
  match disk.write(ledger_path, existing + torn[:20].to_owned()) {
    Ok(_) => ()
    Err(_) => fail("torn tail write failed")
  }
  match @delivery.read_ledger_events(disk, ledger_path) {
    Ok(events) => {
      assert_eq(events.length(), 1)
      assert_eq(events[0], first)
    }
    Err(_) => fail("ledger scan failed")
  }
}

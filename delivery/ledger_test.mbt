/// Exercise the frozen 52-byte v0 delivery-ledger event log and its write
/// path, including the property that ledger streams and message-record
/// streams never mix.

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
    reason=@delivery.NackReason::Retry,
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
    reason=@delivery.NackReason::Poison,
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
    Err(@delivery.LedgerFault::Malformed) => assert_eq(true, true)
    _ => fail("expected CRC corruption rejection")
  }
  match @delivery.decode_ledger_event(bytes[:51]) {
    Err(@delivery.LedgerFault::Malformed) => assert_eq(true, true)
    _ => fail("expected short-view rejection")
  }
}

///|
test "ledger event rejects foreign magic, versions, and codes" {
  let bytes = @delivery.encode_ledger_event(sample_event(@delivery.Ack))
  let bad_magic = b"MMQS" + bytes[4:].to_owned()
  match @delivery.decode_ledger_event(bad_magic[:]) {
    Err(@delivery.LedgerFault::Malformed) => assert_eq(true, true)
    _ => fail("expected foreign-magic rejection")
  }
  let bad_format_ver = bytes[:4].to_owned() + b"\x02" + bytes[5:].to_owned()
  match @delivery.decode_ledger_event(bad_format_ver[:]) {
    Err(@delivery.LedgerFault::Malformed) => assert_eq(true, true)
    _ => fail("expected format-version rejection")
  }
  let bad_event_code = bytes[:8].to_owned() + b"\x0a" + bytes[9:].to_owned()
  match @delivery.decode_ledger_event(bad_event_code[:]) {
    Err(@delivery.LedgerFault::Malformed) => assert_eq(true, true)
    _ => fail("expected unknown-event-code rejection")
  }
  let bad_reason_code = bytes[:39].to_owned() + b"\x04" + bytes[40:].to_owned()
  match @delivery.decode_ledger_event(bad_reason_code[:]) {
    Err(@delivery.LedgerFault::Malformed) => assert_eq(true, true)
    _ => fail("expected unknown-reason-code rejection")
  }
}

///|
test "ledger writer refuses non-ledger paths" {
  match
    @delivery.LedgerWriter::new(b"data/partitions/0001/0000/segment-0000.bin") {
    Err(@delivery.LedgerFault::Malformed) => assert_eq(true, true)
    _ => fail("expected non-ledger path rejection")
  }
  match @delivery.LedgerWriter::new(b"data/partitions/0001/0000/delivery.mql") {
    Ok(writer) => assert_eq(writer.unflushed_events(), 0)
    Err(_) => fail("expected ledger path acceptance")
  }
}

///|
async test "the watermark gate refuses the append that projects past the high line" {
  let disk = @harness.FakeDisk::new()
  disk.set_capacity(1000)
  let gate = @storage.Watermark::new(disk)
  let path = b"data/partitions/0001/0000/delivery.mql"
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let event = sample_event(@delivery.Deliver)
  // Each event is 52 bytes: 16 land (832 bytes, warning band) and the
  // 17th projects 884 of 1000 -- past the 85% line -- and is refused.
  for _ in 0..<16 {
    match writer.append(disk, event, Some(gate)) {
      Ok(_) => ()
      Err(_) => fail("append under the line failed")
    }
  }
  assert_eq(gate.used_percent(), 83UL)
  match writer.append(disk, event, Some(gate)) {
    Err(@delivery.LedgerFault::Capacity) => assert_eq(true, true)
    _ => fail("expected the projected-usage refusal")
  }
  // The refusal ran no disk operation: exactly 16 events are durable.
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => assert_eq(scan.events.length(), 16)
    Err(_) => fail("ledger scan failed")
  }
  // The projection is the contract: current usage is still 83%, so the
  // same append ungated lands -- the refusal was the projection, not now.
  match writer.append(disk, event, None) {
    Ok(_) => ()
    Err(_) => fail("ungated append failed")
  }
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => assert_eq(scan.events.length(), 17)
    Err(_) => fail("ledger scan failed")
  }
}

///|
async test "a hard disk failure is not a capacity refusal" {
  let disk = @harness.FakeDisk::new()
  disk.set_disk_full(true)
  let gate = @storage.Watermark::new(disk)
  let path = b"data/partitions/0001/0000/delivery.mql"
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  match writer.append(disk, sample_event(@delivery.Deliver), Some(gate)) {
    Err(@delivery.LedgerFault::DiskFault(@harness.DiskFull)) =>
      assert_eq(true, true)
    _ => fail("expected a disk fault distinct from Capacity")
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
    match writer.append(disk, sample_event(@delivery.Deliver), None) {
      Ok(_) => ()
      Err(_) => fail("append failed")
    }
    assert_eq(writer.unflushed_events(), index + 1)
  }
  match writer.append(disk, sample_event(@delivery.Deliver), None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  assert_eq(writer.unflushed_events(), 0)
}

///|
async test "ledger and record streams never mix" {
  let disk = @harness.FakeDisk::new()
  let ledger_path = b"data/partitions/0001/0000/delivery.mql"
  let segment_path = b"data/partitions/0001/0000/segment-0000.bin"
  let writer = match @delivery.LedgerWriter::new(ledger_path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let first = sample_event(@delivery.Deliver)
  let second = sample_event(@delivery.Ack)
  match writer.append(disk, first, None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  match writer.append(disk, second, None) {
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
  match @delivery.scan_ledger(disk, ledger_path) {
    Ok(scan) => {
      let events = scan.events
      assert_eq(events.length(), 2)
      assert_eq(events[0], first)
      assert_eq(events[1], second)
    }
    Err(_) => fail("ledger scan failed")
  }
  // A record stream yields no ledger events.
  match @delivery.scan_ledger(disk, segment_path) {
    Ok(scan) => assert_eq(scan.events.length(), 0)
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
  match writer.append(disk, first, None) {
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
  match @delivery.scan_ledger(disk, ledger_path) {
    Ok(scan) => {
      let events = scan.events
      assert_eq(events.length(), 1)
      assert_eq(events[0], first)
    }
    Err(_) => fail("ledger scan failed")
  }
}

///|
async test "a mid-stream bit-flip is reported and later events survive" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let first = sample_event(@delivery.Deliver)
  let second = sample_event(@delivery.Ack)
  let third = sample_event(@delivery.Fenced)
  let fourth = sample_event(@delivery.DlqWritten)
  match writer.append(disk, first, None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  match writer.append(disk, second, None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  match writer.append(disk, third, None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  match writer.append(disk, fourth, None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  // Flip a byte inside the second event's payload.
  let raw = match disk.read(path) {
    Ok(data) => data
    Err(_) => fail("ledger read failed")
  }
  let flipped = raw[:60].to_owned() + b"\xff" + raw[61:].to_owned()
  match disk.write(path, flipped) {
    Ok(_) => ()
    Err(_) => fail("corruption write failed")
  }
  // The damage is reported at its offset and the events after it survive:
  // no more silent prefix-only scans that lose the loop-protection and
  // fence history behind the damage.
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => {
      assert_eq(scan.first_invalid, Some(52))
      assert_eq(scan.events.length(), 3)
      assert_eq(scan.events[0], first)
      assert_eq(scan.events[1], third)
      assert_eq(scan.events[2], fourth)
    }
    Err(_) => fail("ledger scan failed")
  }
  // The machine folds the surviving events and keeps the damage visible.
  let writer2 = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  match @delivery.DeliveryMachine::recover(disk, 1, 0, writer2) {
    Ok(machine) => {
      assert_eq(machine.log_first_invalid(), Some(52))
      // The post-gap FENCED and DLQ_WRITTEN history folded: the entry is
      // dead-lettered and the fence memory survived the gap.
      assert_eq(
        machine.state_of(
          @delivery.DeliveryKey::new(
            group_id=1,
            topic_id=1,
            partition=0,
            sequence=100UL,
          ),
        ),
        Some(@delivery.DeadLetterQueued(2)),
      )
      match
        machine.ack(
          disk,
          @delivery.DeliveryKey::new(
            group_id=1,
            topic_id=1,
            partition=0,
            sequence=100UL,
          ),
          7UL,
          2000,
          None,
        ) {
        Err(@delivery.StaleOwner) => assert_eq(true, true)
        _ => fail("expected the surviving fence to answer STALE_OWNER")
      }
    }
    Err(_) => fail("recover failed")
  }
}

///|
async test "a torn tail is reported and the valid prefix survives" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let first = sample_event(@delivery.Deliver)
  match writer.append(disk, first, None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  let torn = @delivery.encode_ledger_event(sample_event(@delivery.Ack))
  let raw = match disk.read(path) {
    Ok(data) => data
    Err(_) => fail("ledger read failed")
  }
  match disk.write(path, raw + torn[:20].to_owned()) {
    Ok(_) => ()
    Err(_) => fail("torn tail write failed")
  }
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => {
      assert_eq(scan.first_invalid, Some(52))
      assert_eq(scan.events.length(), 1)
      assert_eq(scan.events[0], first)
    }
    Err(_) => fail("ledger scan failed")
  }
}

///|
async test "a clean ledger scan reports no gap" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  match writer.append(disk, sample_event(@delivery.Deliver), None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => {
      assert_eq(scan.first_invalid, None)
      assert_eq(scan.events.length(), 1)
    }
    Err(_) => fail("ledger scan failed")
  }
}

///|
async test "a torn tail heals at recovery and stays queryable" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let first = sample_event(@delivery.Deliver)
  let second = sample_event(@delivery.Ack)
  match writer.append(disk, first, None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  match writer.append(disk, second, None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  let third = sample_event(@delivery.Fenced)
  let torn = @delivery.encode_ledger_event(third)
  let raw = match disk.read(path) {
    Ok(data) => data
    Err(_) => fail("ledger read failed")
  }
  match disk.write(path, raw + torn[:20].to_owned()) {
    Ok(_) => ()
    Err(_) => fail("torn tail write failed")
  }
  // Recovery heals the tail instead of bricking: the tear is a storage
  // fact, not an executor bug. The truncation is one recovery-time write,
  // and the writer records where the boundary ran.
  match @delivery.DeliveryMachine::recover(disk, 1, 0, writer) {
    Ok(_) => assert_eq(writer.torn_at(), Some(104))
    Err(_) => fail("recover should heal the torn tail")
  }
  let third = sample_event(@delivery.Fenced)
  match writer.append(disk, third, None) {
    Ok(_) => ()
    Err(_) => fail("append after the heal should proceed")
  }
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => {
      assert_eq(scan.first_invalid, None)
      assert_eq(scan.events.length(), 3)
      assert_eq(scan.events[0], first)
      assert_eq(scan.events[1], second)
      assert_eq(scan.events[2], third)
    }
    Err(_) => fail("ledger scan failed")
  }
}

///|
async test "mid-stream damage refuses the append until recovery repairs it" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let first = sample_event(@delivery.Deliver)
  let second = sample_event(@delivery.Ack)
  let third = sample_event(@delivery.Fenced)
  match writer.append(disk, first, None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  match writer.append(disk, second, None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  match writer.append(disk, third, None) {
    Ok(_) => ()
    Err(_) => fail("append failed")
  }
  let raw = match disk.read(path) {
    Ok(data) => data
    Err(_) => fail("ledger read failed")
  }
  let flipped = raw[:60].to_owned() + b"\xff" + raw[61:].to_owned()
  match disk.write(path, flipped) {
    Ok(_) => ()
    Err(_) => fail("corruption write failed")
  }
  // A hole with good events behind it is real corruption: recovery folds
  // the survivors, flags the writer, and the append refuses rather than
  // silently cut live history away.
  match @delivery.DeliveryMachine::recover(disk, 1, 0, writer) {
    Ok(_) => assert_eq(true, true)
    Err(_) => fail("recover folds the surviving events")
  }
  match writer.append(disk, sample_event(@delivery.Deliver), None) {
    Err(@delivery.LedgerFault::Malformed) => assert_eq(true, true)
    _ => fail("expected the mid-stream refusal")
  }
  assert_eq(writer.torn_at(), None)
}

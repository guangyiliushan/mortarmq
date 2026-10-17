/// Exercise series recovery under the quarantine policy: sealed damage is
/// moved aside with a locatable sidecar note, the active tail truncates to
/// its last valid record, sequence holes stay visible, and a kill at any
/// step leaves a series that re-converges without silent loss and with the
/// write path unaffected.

///|
const SR_BASE : Bytes = b"sr-part.segment"

///|
fn sr_len(value : Bytes) -> Int32 {
  @storage.RECORD_HEADER_BYTES + value.length()
}

///|
fn sr_header(sequence : UInt64, value : Bytes) -> @storage.RecordHeader {
  @storage.RecordHeader::new(
    flags=0,
    key_length=0,
    value_length=value.length().reinterpret_as_uint(),
    sequence~,
    producer_id=0UL,
    producer_seq=0UL,
    timestamp_unix_ms=0UL,
    leader_epoch=0,
    replication_flags=0,
  )
}

///|
fn sr_record_bytes(sequence : UInt64, value : Bytes) -> Bytes raise {
  match @storage.encode_record_header(sr_header(sequence, value), b"", value) {
    Ok(bytes) => bytes
    Err(_) => fail("test record encoding failed")
  }
}

///|
fn sr_recovered(sequence : UInt64, value : Bytes) -> @storage.RecoveredRecord {
  { header: sr_header(sequence, value), key: b"", value, }
}

///|
fn sr_join(parts : Array[Bytes]) -> Bytes {
  let buf = Buffer()
  for part in parts {
    buf.write_bytes(part)
  }
  buf.contents()
}

///|
fn sr_flip(bytes : Bytes, index : Int32) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(bytes[:index])
  buf.write_byte(bytes[index] ^ b'\xff')
  buf.write_bytes(bytes[index + 1:])
  buf.contents()
}

///|
fn sr_values() -> Array[Bytes] {
  [b"v0", b"v1", b"v2", b"v3", b"v4", b"v5"]
}

///|
async fn sr_build_series(disk : &@ports.Disk) -> @storage.SegmentWriter {
  // 58-byte records under a 120-byte cap: two records per segment, so six
  // appends fill segments 0, 1 and leave 2 active.
  let writer = @storage.SegmentWriter::new(SR_BASE, segment_max_bytes=120)
  let mut n = 0
  let values = sr_values()
  while n < values.length() {
    if @storage.SegmentWriter::append(writer, disk, b"", values[n]) is Err(_) {
      fail("series build append failed")
    }
    n = n + 1
  }
  writer
}

///|
fn sr_note(offset : Int32, reason_text : Bytes) -> Bytes {
  b"first_bad_offset=" +
  @utf8.encode(offset.to_string()) +
  b"\nreason=" +
  reason_text +
  b"\n"
}

///|
async test "quarantine moves a sealed segment aside and records the first bad offset" {
  let disk = @harness.FakeDisk::new()
  let path = b"sr-quarantine.0"
  let body = sr_join([sr_record_bytes(0UL, b"v0"), sr_record_bytes(1UL, b"v1")])
  if @ports.Disk::write(disk, path, body) is Err(_) {
    fail("setup write failed")
  }
  let quarantine_result = @storage.quarantine_segment(
    disk,
    path,
    42,
    @storage.CorruptRecord,
  )
  let entry = match quarantine_result {
    Ok(entry) => entry
    Err(_) => fail("quarantine failed")
  }
  assert_eq(entry.segment_path, path)
  assert_eq(entry.quarantined_path, b"sr-quarantine.0.quarantined")
  assert_eq(entry.sidecar_path, b"sr-quarantine.0.quarantine")
  assert_eq(entry.first_bad_offset, 42)
  assert_eq(entry.reason, @storage.CorruptRecord)
  assert_eq(@ports.Disk::read(disk, path), Err(@ports.PathMissing))
  assert_eq(@ports.Disk::read(disk, entry.quarantined_path), Ok(body))
  assert_eq(
    @ports.Disk::read(disk, entry.sidecar_path),
    Ok(sr_note(42, b"corrupt_record")),
  )
}

///|
async test "quarantine re-entry completes the missing sidecar" {
  let disk = @harness.FakeDisk::new()
  let path = b"sr-reentry.0"
  let body = sr_join([sr_record_bytes(0UL, b"v0")])
  if @ports.Disk::write(disk, path, body) is Err(_) {
    fail("setup write failed")
  }
  // Simulate a crash between rename and sidecar write.
  if @ports.Disk::rename(disk, path, b"sr-reentry.0.quarantined") is Err(_) {
    fail("setup rename failed")
  }
  let reentry_result = @storage.quarantine_segment(
    disk,
    path,
    0,
    @storage.CorruptRecord,
  )
  let entry = match reentry_result {
    Ok(entry) => entry
    Err(_) => fail("re-entry quarantine failed")
  }
  assert_eq(
    @ports.Disk::read(disk, entry.sidecar_path),
    Ok(sr_note(0, b"corrupt_record")),
  )
  assert_eq(@ports.Disk::read(disk, b"sr-reentry.0.quarantined"), Ok(body))
}

///|
async test "quarantine fails closed when neither the segment nor its twin exists" {
  let disk = @harness.FakeDisk::new()
  assert_eq(
    @storage.quarantine_segment(disk, b"sr-absent.0", 0, @storage.CorruptRecord),
    Err(@storage.DiskFault(@ports.PathMissing)),
  )
}

///|
async test "a corrupt sealed segment is quarantined while the rest of the series recovers" {
  let disk = @harness.FakeDisk::new()
  let writer = sr_build_series(disk)
  // Corrupt the CRC of the second record in sealed segment 1.
  let damaged = match @ports.Disk::read(disk, b"sr-part.segment.1") {
    Ok(bytes) => bytes
    Err(_) => fail("sealed segment unreadable")
  }
  let op_result1 = @ports.Disk::write(
    disk,
    b"sr-part.segment.1",
    sr_flip(damaged, 63),
  )
  if op_result1 is Err(_) {
    fail("corruption write failed")
  }
  let recovery_result = @storage.recover_series(disk, SR_BASE, 3)
  let recovery = match recovery_result {
    Ok(recovery) => recovery
    Err(_) => fail("series recovery failed")
  }
  assert_eq(recovery.records, [
    sr_recovered(0UL, b"v0"),
    sr_recovered(1UL, b"v1"),
    sr_recovered(4UL, b"v4"),
    sr_recovered(5UL, b"v5"),
  ])
  assert_eq(recovery.quarantined, [
    {
      segment_path: b"sr-part.segment.1",
      quarantined_path: b"sr-part.segment.1.quarantined",
      sidecar_path: b"sr-part.segment.1.quarantine",
      first_bad_offset: sr_len(b"v2"),
      reason: @storage.CorruptRecord,
    },
  ])
  assert_eq(recovery.gaps, [
    {
      segment_index: 2,
      file_offset: 0,
      expected_sequence: 3UL,
      found_sequence: 4UL,
      segment_missing: false,
    },
  ])
  assert_eq(recovery.active_truncated_at, None)
  assert_eq(recovery.next_sequence, 6UL)
  assert_eq(
    @ports.Disk::read(disk, b"sr-part.segment.1.quarantine"),
    Ok(sr_note(sr_len(b"v2"), b"corrupt_record")),
  )
  // The write path is unaffected by the quarantine.
  if @storage.SegmentWriter::append(writer, disk, b"", b"v6") is Err(_) {
    fail("append after quarantine failed")
  }
  assert_eq(writer.active_path(), b"sr-part.segment.3")
}

///|
async test "an in-segment sequence jump quarantines the sealed segment as a gap" {
  let disk = @harness.FakeDisk::new()
  let body = sr_join([
    sr_record_bytes(0UL, b"v0"),
    sr_record_bytes(1UL, b"v1"),
    sr_record_bytes(5UL, b"v5"),
  ])
  if @ports.Disk::write(disk, b"sr-part.segment.0", body) is Err(_) {
    fail("setup write failed")
  }
  let op_result2 = @ports.Disk::write(
    disk,
    b"sr-part.segment.1",
    sr_record_bytes(6UL, b"v6"),
  )
  if op_result2 is Err(_) {
    fail("setup write failed")
  }
  let recovery_result = @storage.recover_series(disk, SR_BASE, 2)
  let recovery = match recovery_result {
    Ok(recovery) => recovery
    Err(_) => fail("series recovery failed")
  }
  assert_eq(recovery.quarantined, [
    {
      segment_path: b"sr-part.segment.0",
      quarantined_path: b"sr-part.segment.0.quarantined",
      sidecar_path: b"sr-part.segment.0.quarantine",
      first_bad_offset: sr_len(b"v0") * 2,
      reason: @storage.SequenceGap,
    },
  ])
  assert_eq(recovery.records, [sr_recovered(6UL, b"v6")])
  assert_eq(recovery.gaps, [
    {
      segment_index: 1,
      file_offset: 0,
      expected_sequence: 2UL,
      found_sequence: 6UL,
      segment_missing: false,
    },
  ])
  assert_eq(
    @ports.Disk::read(disk, b"sr-part.segment.0.quarantine"),
    Ok(sr_note(sr_len(b"v0") * 2, b"sequence_gap")),
  )
}

///|
async test "the active segment truncates to the last valid record instead of quarantining" {
  let disk = @harness.FakeDisk::new()
  let writer = sr_build_series(disk)
  let damaged = match @ports.Disk::read(disk, b"sr-part.segment.2") {
    Ok(bytes) => bytes
    Err(_) => fail("active segment unreadable")
  }
  let op_result3 = @ports.Disk::write(
    disk,
    b"sr-part.segment.2",
    sr_flip(damaged, 63),
  )
  if op_result3 is Err(_) {
    fail("corruption write failed")
  }
  let recovery_result = @storage.recover_series(disk, SR_BASE, 3)
  let recovery = match recovery_result {
    Ok(recovery) => recovery
    Err(_) => fail("series recovery failed")
  }
  assert_eq(recovery.records, [
    sr_recovered(0UL, b"v0"),
    sr_recovered(1UL, b"v1"),
    sr_recovered(2UL, b"v2"),
    sr_recovered(3UL, b"v3"),
    sr_recovered(4UL, b"v4"),
  ])
  assert_eq(recovery.quarantined, [])
  assert_eq(recovery.gaps, [])
  assert_eq(recovery.active_truncated_at, Some(sr_len(b"v4")))
  assert_eq(recovery.next_sequence, 5UL)
  let _ = writer
}

///|
async test "a missing sealed segment surfaces as a visible hole" {
  let disk = @harness.FakeDisk::new()
  let writer = sr_build_series(disk)
  let op_result4 = @ports.Disk::rename(
    disk, b"sr-part.segment.1", b"sr-moved-away",
  )
  if op_result4 is Err(_) {
    fail("setup rename failed")
  }
  let recovery_result = @storage.recover_series(disk, SR_BASE, 3)
  let recovery = match recovery_result {
    Ok(recovery) => recovery
    Err(_) => fail("series recovery failed")
  }
  assert_eq(recovery.records, [
    sr_recovered(0UL, b"v0"),
    sr_recovered(1UL, b"v1"),
    sr_recovered(4UL, b"v4"),
    sr_recovered(5UL, b"v5"),
  ])
  assert_eq(recovery.quarantined, [])
  assert_eq(recovery.gaps, [
    {
      segment_index: 1,
      file_offset: 0,
      expected_sequence: 2UL,
      found_sequence: 2UL,
      segment_missing: true,
    },
    {
      segment_index: 2,
      file_offset: 0,
      expected_sequence: 2UL,
      found_sequence: 4UL,
      segment_missing: false,
    },
  ])
  let _ = writer
}

///|
async test "series recovery re-converges after a crash between rename and sidecar" {
  let disk = @harness.FakeDisk::new()
  let writer = sr_build_series(disk)
  let damaged = match @ports.Disk::read(disk, b"sr-part.segment.1") {
    Ok(bytes) => bytes
    Err(_) => fail("sealed segment unreadable")
  }
  let op_result5 = @ports.Disk::write(
    disk,
    b"sr-part.segment.1",
    sr_flip(damaged, 63),
  )
  if op_result5 is Err(_) {
    fail("corruption write failed")
  }
  let op_result6 = @ports.Disk::rename(
    disk, b"sr-part.segment.1", b"sr-part.segment.1.quarantined",
  )
  if op_result6 is Err(_) {
    fail("interrupted quarantine rename failed")
  }
  let recovery_result = @storage.recover_series(disk, SR_BASE, 3)
  let recovery = match recovery_result {
    Ok(recovery) => recovery
    Err(_) => fail("series recovery failed")
  }
  assert_eq(recovery.quarantined.length(), 1)
  assert_eq(recovery.quarantined[0].first_bad_offset, sr_len(b"v2"))
  assert_eq(recovery.quarantined[0].reason, @storage.CorruptRecord)
  assert_eq(
    @ports.Disk::read(disk, b"sr-part.segment.1.quarantine"),
    Ok(sr_note(sr_len(b"v2"), b"corrupt_record")),
  )
  let _ = writer
}

///|
async test "every kill point leaves a recoverable series and the writer keeps writing" {
  // Process-death sweep: arm the kill point across the quarantine and
  // follow-up append phase. Whatever the armed op is, after process death
  // (disarm) the series re-converges without silently losing a good record,
  // the damaged segment ends up quarantined, and appends keep working.
  let mut arm = 1
  while arm <= 5 {
    let disk = @harness.FakeDisk::new()
    let writer = sr_build_series(disk)
    let damaged = match @ports.Disk::read(disk, b"sr-part.segment.1") {
      Ok(bytes) => bytes
      Err(_) => fail("sealed segment unreadable")
    }
    let op_result7 = @ports.Disk::write(
      disk,
      b"sr-part.segment.1",
      sr_flip(damaged, 63),
    )
    if op_result7 is Err(_) {
      fail("corruption write failed")
    }
    // Setup used 12 append ops plus the corruption write; arm absolute.
    disk.set_kill_at(13 + arm)
    let _ = @storage.recover_series(disk, SR_BASE, 3)
    let append_result = @storage.SegmentWriter::append(writer, disk, b"", b"v6")
    disk.set_kill_at(0)
    let landed = match append_result {
      Ok(_) => true
      Err(_) => false
    }
    let recovery_result = @storage.recover_series(
      disk,
      SR_BASE,
      writer.segment_count(),
    )
    let recovery = match recovery_result {
      Ok(recovery) => recovery
      Err(_) => fail("post-restart series recovery failed")
    }
    let expected : Array[@storage.RecoveredRecord] = [
      sr_recovered(0UL, b"v0"),
      sr_recovered(1UL, b"v1"),
      sr_recovered(4UL, b"v4"),
      sr_recovered(5UL, b"v5"),
    ]
    if landed {
      expected.push(sr_recovered(6UL, b"v6"))
      // A killed append must not corrupt the writer state: either the
      // record is fully in the recovered series or fully absent from it.
    } else if writer.next_sequence() == 7UL {
      // The write landed before the fsync kill: the record is durable.
      expected.push(sr_recovered(6UL, b"v6"))
    }
    assert_eq(recovery.records, expected)
    assert_eq(recovery.quarantined.length(), 1)
    assert_eq(recovery.quarantined[0].first_bad_offset, sr_len(b"v2"))
    assert_eq(recovery.gaps, [
      {
        segment_index: 2,
        file_offset: 0,
        expected_sequence: 3UL,
        found_sequence: 4UL,
        segment_missing: false,
      },
    ])
    // The write path is unaffected after restart.
    if @storage.SegmentWriter::append(writer, disk, b"", b"v7") is Err(_) {
      fail("append after restart failed")
    }
    arm = arm + 1
  }
}

///|
fn sr_flip_bit(bytes : Bytes, byte_index : Int32, bit : Int32) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(bytes[:byte_index])
  buf.write_byte((bytes[byte_index].to_uint() ^ (1U << bit)).to_byte())
  buf.write_bytes(bytes[byte_index + 1:])
  buf.contents()
}

///|
async test "bit-flip sweep quarantines every flip at the record that holds it" {
  // Bit-flip injection sweep: every single-bit flip anywhere in a sealed
  // segment is caught and quarantined, and the sidecar note points at the
  // record that holds the flipped bit.
  let record_size = sr_len(b"v2")
  let sealed_size = record_size * 2
  let mut byte_index = 0
  while byte_index < sealed_size {
    let mut bit = 0
    while bit < 8 {
      let disk = @harness.FakeDisk::new()
      let _ = sr_build_series(disk)
      let original = match @ports.Disk::read(disk, b"sr-part.segment.1") {
        Ok(bytes) => bytes
        Err(_) => fail("sealed segment unreadable")
      }
      let flipped = sr_flip_bit(original, byte_index, bit)
      let op_result = @ports.Disk::write(disk, b"sr-part.segment.1", flipped)
      if op_result is Err(_) {
        fail("flip write failed")
      }
      let recovery_result = @storage.recover_series(disk, SR_BASE, 3)
      let recovery = match recovery_result {
        Ok(recovery) => recovery
        Err(_) => fail("series recovery failed")
      }
      let expected_offset = byte_index / record_size * record_size
      assert_eq(recovery.quarantined.length(), 1)
      assert_eq(recovery.quarantined[0].first_bad_offset, expected_offset)
      assert_eq(recovery.quarantined[0].reason, @storage.CorruptRecord)
      assert_eq(recovery.records, [
        sr_recovered(0UL, b"v0"),
        sr_recovered(1UL, b"v1"),
        sr_recovered(4UL, b"v4"),
        sr_recovered(5UL, b"v5"),
      ])
      bit = bit + 1
    }
    byte_index = byte_index + 1
  }
}

///|
async test "a torn tail in a sealed segment is quarantined and localized" {
  let disk = @harness.FakeDisk::new()
  let writer = sr_build_series(disk)
  let damaged = match @ports.Disk::read(disk, b"sr-part.segment.1") {
    Ok(bytes) => bytes
    Err(_) => fail("sealed segment unreadable")
  }
  // Keep the first record complete and tear the second one.
  let torn = damaged[:sr_len(b"v2") + 30].to_owned()
  let op_result = @ports.Disk::write(disk, b"sr-part.segment.1", torn)
  if op_result is Err(_) {
    fail("tear write failed")
  }
  let recovery_result = @storage.recover_series(disk, SR_BASE, 3)
  let recovery = match recovery_result {
    Ok(recovery) => recovery
    Err(_) => fail("series recovery failed")
  }
  // A sealed segment is complete by construction: the torn tail is damage,
  // localized at the first missing byte.
  assert_eq(recovery.quarantined, [
    {
      segment_path: b"sr-part.segment.1",
      quarantined_path: b"sr-part.segment.1.quarantined",
      sidecar_path: b"sr-part.segment.1.quarantine",
      first_bad_offset: sr_len(b"v2"),
      reason: @storage.CorruptRecord,
    },
  ])
  assert_eq(recovery.records, [
    sr_recovered(0UL, b"v0"),
    sr_recovered(1UL, b"v1"),
    sr_recovered(4UL, b"v4"),
    sr_recovered(5UL, b"v5"),
  ])
  assert_eq(recovery.gaps, [
    {
      segment_index: 2,
      file_offset: 0,
      expected_sequence: 3UL,
      found_sequence: 4UL,
      segment_missing: false,
    },
  ])
  let _ = writer
}

///|
async test "a torn tail on the active segment is a normal crash boundary" {
  let disk = @harness.FakeDisk::new()
  let writer = sr_build_series(disk)
  let damaged = match @ports.Disk::read(disk, b"sr-part.segment.2") {
    Ok(bytes) => bytes
    Err(_) => fail("active segment unreadable")
  }
  let torn = damaged[:sr_len(b"v4") + 30].to_owned()
  let op_result = @ports.Disk::write(disk, b"sr-part.segment.2", torn)
  if op_result is Err(_) {
    fail("tear write failed")
  }
  let recovery_result = @storage.recover_series(disk, SR_BASE, 3)
  let recovery = match recovery_result {
    Ok(recovery) => recovery
    Err(_) => fail("series recovery failed")
  }
  assert_eq(recovery.quarantined, [])
  assert_eq(recovery.active_truncated_at, None)
  assert_eq(recovery.records, [
    sr_recovered(0UL, b"v0"),
    sr_recovered(1UL, b"v1"),
    sr_recovered(2UL, b"v2"),
    sr_recovered(3UL, b"v3"),
    sr_recovered(4UL, b"v4"),
  ])
  assert_eq(recovery.next_sequence, 5UL)
  let _ = writer
}

/// Exercise the size-bounded segment writer: rotation at the threshold,
/// sealed-segment immutability and readability at the original path, and the
/// failure semantics of a refused record, a refused write, and a refused
/// fsync.

///|
const SEG_BASE_PATH : Bytes = b"part-0.segment"

///|
const SEG_CHECKPOINT : Bytes = b"part-0.checkpoint"

///|
fn writer_header(
  sequence : UInt64,
  key : Bytes,
  value : Bytes,
  producer_id~ : UInt64 = 0UL,
  producer_seq~ : UInt64 = 0UL,
  timestamp_unix_ms~ : UInt64 = 0UL,
) -> @storage.RecordHeader {
  let flags : UInt16 = if key.length() > 0 { 1 } else { 0 }
  @storage.RecordHeader::new(
    flags~,
    key_length=key.length().to_uint16(),
    value_length=value.length().reinterpret_as_uint(),
    sequence~,
    producer_id~,
    producer_seq~,
    timestamp_unix_ms~,
    leader_epoch=0,
    replication_flags=0,
  )
}

///|
fn writer_record(
  sequence : UInt64,
  key : Bytes,
  value : Bytes,
  producer_id~ : UInt64 = 0UL,
  producer_seq~ : UInt64 = 0UL,
  timestamp_unix_ms~ : UInt64 = 0UL,
) -> @storage.RecoveredRecord {
  {
    header: writer_header(
      sequence,
      key,
      value,
      producer_id~,
      producer_seq~,
      timestamp_unix_ms~,
    ),
    key,
    value,
  }
}

///|
fn record_len(key : Bytes, value : Bytes) -> Int32 {
  @storage.RECORD_HEADER_BYTES + key.length() + value.length()
}

///|
fn writer_recovery(
  next_sequence : UInt64,
  durable_offset : UInt32,
  records : Array[@storage.RecoveredRecord],
) -> @storage.SegmentRecovery {
  { checkpoint: { next_sequence, durable_offset, }, records, }
}

///|
async test "append assigns sequences from the start and reports its extent" {
  let disk : &@ports.Disk = @harness.FakeDisk::new()
  let writer = @storage.SegmentWriter::new(
    SEG_BASE_PATH,
    segment_max_bytes=1000,
    start_sequence=100UL,
  )
  let first_result = @storage.SegmentWriter::append(
    writer,
    disk,
    b"k",
    b"v",
    timestamp_unix_ms=7UL,
  )
  let first = match first_result {
    Ok(record) => record
    Err(_) => fail("first append failed")
  }
  assert_eq(first, {
    sequence: 100UL,
    segment_index: 0,
    segment_path: b"part-0.segment.0",
    file_offset: 0,
    record_len: record_len(b"k", b"v"),
  })
  let second_result = @storage.SegmentWriter::append(writer, disk, b"", b"abc")
  let second = match second_result {
    Ok(record) => record
    Err(_) => fail("second append failed")
  }
  assert_eq(second, {
    sequence: 101UL,
    segment_index: 0,
    segment_path: b"part-0.segment.0",
    file_offset: record_len(b"k", b"v"),
    record_len: record_len(b"", b"abc"),
  })
  assert_eq(writer.next_sequence(), 102UL)
  assert_eq(
    writer.active_bytes(),
    record_len(b"k", b"v") + record_len(b"", b"abc"),
  )
  assert_eq(writer.segment_count(), 1)
  assert_eq(writer.active_path(), b"part-0.segment.0")
}

///|
async test "the threshold rolls a fresh segment and carries sequences across" {
  let disk : &@ports.Disk = @harness.FakeDisk::new()
  let writer = @storage.SegmentWriter::new(SEG_BASE_PATH, segment_max_bytes=100)
  let r1 = match @storage.SegmentWriter::append(writer, disk, b"", b"abc") {
    Ok(record) => record
    Err(_) => fail("first append failed")
  }
  let r2 = match @storage.SegmentWriter::append(writer, disk, b"", b"def") {
    Ok(record) => record
    Err(_) => fail("second append failed")
  }
  let r3 = match @storage.SegmentWriter::append(writer, disk, b"", b"ghi") {
    Ok(record) => record
    Err(_) => fail("third append failed")
  }
  assert_eq(r1.segment_index, 0)
  assert_eq(r2.segment_index, 1)
  assert_eq(r3.segment_index, 2)
  assert_eq(r3.file_offset, 0)
  assert_eq(r1.sequence, 0UL)
  assert_eq(r2.sequence, 1UL)
  assert_eq(r3.sequence, 2UL)
  assert_eq(writer.segment_count(), 3)
  assert_eq(writer.segment_path(0), b"part-0.segment.0")
  assert_eq(writer.segment_path(2), b"part-0.segment.2")
  assert_eq(writer.active_path(), b"part-0.segment.2")
}

///|
async test "a sealed segment stays readable at its original path after rotation" {
  let disk = @harness.FakeDisk::new()
  let writer = @storage.SegmentWriter::new(SEG_BASE_PATH, segment_max_bytes=120)
  let mut n = 0
  while n < 4 {
    let value = match n {
      0 => b"abc"
      1 => b"def"
      2 => b"ghi"
      _ => b"jkl"
    }
    if @storage.SegmentWriter::append(writer, disk, b"", value) is Err(_) {
      fail("append failed")
    }
    n = n + 1
  }
  // With 59-byte records under a 120-byte cap: segment 0 holds abc+def and
  // segment 1 holds ghi+jkl.
  let sealed_bytes = match @ports.Disk::read(disk, b"part-0.segment.0") {
    Ok(bytes) => bytes
    Err(_) => fail("sealed segment unreadable")
  }
  // The startup replay path reads the sealed segment at its
  // original path and recovers every record it holds.
  assert_eq(
    @storage.recover_segment(disk, b"part-0.segment.0", SEG_CHECKPOINT),
    Ok(
      writer_recovery(
        2UL,
        (record_len(b"", b"abc") * 2).reinterpret_as_uint(),
        [writer_record(0UL, b"", b"abc"), writer_record(1UL, b"", b"def")],
      ),
    ),
  )
  // Sealed means immutable: later appends never touch the old file.
  if @storage.SegmentWriter::append(writer, disk, b"", b"mno") is Err(_) {
    fail("append after rotation failed")
  }
  if @storage.SegmentWriter::append(writer, disk, b"", b"pqr") is Err(_) {
    fail("append after rotation failed")
  }
  assert_eq(@ports.Disk::read(disk, b"part-0.segment.0"), Ok(sealed_bytes))
  assert_eq(
    @storage.recover_segment(disk, b"part-0.segment.0", SEG_CHECKPOINT),
    Ok(
      writer_recovery(
        2UL,
        (record_len(b"", b"abc") * 2).reinterpret_as_uint(),
        [writer_record(0UL, b"", b"abc"), writer_record(1UL, b"", b"def")],
      ),
    ),
  )
  // The sealed successor also stays intact while the active segment grows.
  assert_eq(
    @storage.recover_segment(disk, b"part-0.segment.1", SEG_CHECKPOINT),
    Ok(
      writer_recovery(
        4UL,
        (record_len(b"", b"abc") * 2).reinterpret_as_uint(),
        [writer_record(2UL, b"", b"ghi"), writer_record(3UL, b"", b"jkl")],
      ),
    ),
  )
}

///|
async test "an oversize record starts its own segment instead of being refused" {
  let disk = @harness.FakeDisk::new()
  let writer = @storage.SegmentWriter::new(SEG_BASE_PATH, segment_max_bytes=10)
  let big_result = @storage.SegmentWriter::append(
    writer, disk, b"", b"0123456789abcdef",
  )
  let big = match big_result {
    Ok(record) => record
    Err(_) => fail("oversize record was refused")
  }
  assert_eq(big.segment_index, 0)
  assert_eq(big.file_offset, 0)
  let next = match @storage.SegmentWriter::append(writer, disk, b"", b"x") {
    Ok(record) => record
    Err(_) => fail("append after oversize record failed")
  }
  assert_eq(next.segment_index, 1)
  assert_eq(writer.segment_count(), 2)
}

///|
async test "records exactly at the threshold share the segment" {
  let disk : &@ports.Disk = @harness.FakeDisk::new()
  let size = record_len(b"", b"abc")
  let writer = @storage.SegmentWriter::new(
    SEG_BASE_PATH,
    segment_max_bytes=size * 2,
  )
  let r1 = match @storage.SegmentWriter::append(writer, disk, b"", b"abc") {
    Ok(record) => record
    Err(_) => fail("first append failed")
  }
  let r2 = match @storage.SegmentWriter::append(writer, disk, b"", b"abc") {
    Ok(record) => record
    Err(_) => fail("second append failed")
  }
  assert_eq(r1.segment_index, 0)
  assert_eq(r2.segment_index, 0)
  assert_eq(writer.active_bytes(), size * 2)
  if @storage.SegmentWriter::append(writer, disk, b"", b"abc") is Err(_) {
    fail("third append failed")
  }
  assert_eq(writer.segment_count(), 2)
}

///|
async test "a non-positive threshold gives every record its own segment" {
  let disk : &@ports.Disk = @harness.FakeDisk::new()
  let writer = @storage.SegmentWriter::new(SEG_BASE_PATH, segment_max_bytes=0)
  let mut n = 0
  while n < 3 {
    if @storage.SegmentWriter::append(writer, disk, b"", b"abc") is Err(_) {
      fail("append failed")
    }
    n = n + 1
  }
  assert_eq(writer.segment_count(), 3)
  assert_eq(writer.active_bytes(), record_len(b"", b"abc"))
}

///|
async test "a refused write leaves the writer state unchanged" {
  let disk = @harness.FakeDisk::new()
  let writer = @storage.SegmentWriter::new(SEG_BASE_PATH, segment_max_bytes=100)
  disk.set_disk_full(true)
  assert_eq(
    @storage.SegmentWriter::append(writer, disk, b"", b"abc"),
    Err(@storage.Disk(@ports.DiskFull)),
  )
  assert_eq(writer.next_sequence(), 0UL)
  assert_eq(writer.active_bytes(), 0)
  assert_eq(writer.segment_count(), 1)
  assert_eq(
    @ports.Disk::read(disk, b"part-0.segment.0"),
    Err(@ports.PathMissing),
  )
  disk.set_disk_full(false)
  if @storage.SegmentWriter::append(writer, disk, b"", b"abc") is Err(_) {
    fail("append after clearing the fault failed")
  }
  assert_eq(writer.next_sequence(), 1UL)
}

///|
async test "a refused roll write leaves the series exactly as it was" {
  let disk = @harness.FakeDisk::new()
  let writer = @storage.SegmentWriter::new(SEG_BASE_PATH, segment_max_bytes=100)
  if @storage.SegmentWriter::append(writer, disk, b"", b"abc") is Err(_) {
    fail("first append failed")
  }
  disk.set_disk_full(true)
  assert_eq(
    @storage.SegmentWriter::append(writer, disk, b"", b"def"),
    Err(@storage.Disk(@ports.DiskFull)),
  )
  assert_eq(writer.segment_count(), 1)
  assert_eq(writer.active_path(), b"part-0.segment.0")
  assert_eq(writer.next_sequence(), 1UL)
  assert_eq(writer.active_bytes(), record_len(b"", b"abc"))
  disk.set_disk_full(false)
  let rolled = match @storage.SegmentWriter::append(writer, disk, b"", b"def") {
    Ok(record) => record
    Err(_) => fail("retry after cleared fault failed")
  }
  assert_eq(rolled.segment_index, 1)
  assert_eq(rolled.sequence, 1UL)
}

///|
async test "a refused fsync keeps the published record and the next append builds on it" {
  let disk = @harness.FakeDisk::new()
  let writer = @storage.SegmentWriter::new(SEG_BASE_PATH, segment_max_bytes=200)
  // Op 1 is the first append write and op 2 its fsync: the kill fires there.
  disk.set_kill_at(2)
  assert_eq(
    @storage.SegmentWriter::append(writer, disk, b"", b"abc"),
    Err(@storage.Disk(@ports.Killed)),
  )
  // The record is in the file and in the writer state despite the failed
  // fsync; only the durability signal is missing.
  assert_eq(writer.next_sequence(), 1UL)
  assert_eq(writer.active_bytes(), record_len(b"", b"abc"))
  disk.set_kill_at(0)
  if @storage.SegmentWriter::append(writer, disk, b"", b"def") is Err(_) {
    fail("append after the failed fsync must build on the durable record")
  }
  assert_eq(
    @storage.recover_segment(disk, b"part-0.segment.0", SEG_CHECKPOINT),
    Ok(
      writer_recovery(
        2UL,
        (record_len(b"", b"abc") * 2).reinterpret_as_uint(),
        [writer_record(0UL, b"", b"abc"), writer_record(1UL, b"", b"def")],
      ),
    ),
  )
}

///|
async test "a rejected record leaves the writer unchanged and writes nothing" {
  let disk = @harness.FakeDisk::new()
  let writer = @storage.SegmentWriter::new(SEG_BASE_PATH, segment_max_bytes=100)
  assert_eq(
    @storage.SegmentWriter::append(
      writer,
      disk,
      b"",
      b"abc",
      replication_flags=4,
    ),
    Err(@storage.Record(@storage.Malformed)),
  )
  assert_eq(writer.next_sequence(), 0UL)
  assert_eq(writer.active_bytes(), 0)
  assert_eq(writer.segment_count(), 1)
  assert_eq(
    @ports.Disk::read(disk, b"part-0.segment.0"),
    Err(@ports.PathMissing),
  )
}

///|
async test "caller header fields land in the recovered record" {
  let disk = @harness.FakeDisk::new()
  let writer = @storage.SegmentWriter::new(SEG_BASE_PATH, start_sequence=5UL)
  let appended = @storage.SegmentWriter::append(
    writer,
    disk,
    b"key",
    b"value",
    producer_id=9UL,
    producer_seq=3UL,
    timestamp_unix_ms=1234UL,
  )
  if appended is Err(_) {
    fail("append failed")
  }
  assert_eq(
    @storage.recover_segment(disk, b"part-0.segment.0", SEG_CHECKPOINT),
    Ok(
      writer_recovery(6UL, record_len(b"key", b"value").reinterpret_as_uint(), [
        writer_record(
          5UL,
          b"key",
          b"value",
          producer_id=9UL,
          producer_seq=3UL,
          timestamp_unix_ms=1234UL,
        ),
      ]),
    ),
  )
}

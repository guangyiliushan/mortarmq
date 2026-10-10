/// Exercise delete_before: the mechanism-only retention relief of
/// REQ-STO-009 (gap B-1: mechanism in, policy out). Sealed segments
/// entirely below a sequence watermark are reclaimed with their quarantine
/// twins and sidecar notes, the active segment is never deleted, and the
/// freed bytes reopen the storage watermark.

///|
const RT_BASE : Bytes = b"rt-part.segment"

///|
fn rt_value(i : Int) -> Bytes {
  @utf8.encode(i.to_string())
}

///|
async fn rt_build_series(disk : &@harness.Disk) -> @storage.SegmentWriter {
  // 58-byte records under a 120-byte cap: two per segment, so ten appends
  // fill segments 0..4 with segment 4 active ([0,1][2,3][4,5][6,7][8,9]).
  let writer = @storage.SegmentWriter::new(RT_BASE, segment_max_bytes=120)
  let mut n = 0
  while n < 10 {
    let result = @storage.SegmentWriter::append(writer, disk, b"", rt_value(n))
    if result is Err(_) {
      fail("series build append failed")
    }
    n = n + 1
  }
  writer
}

///|
async test "golden: delete_before removes exactly the sealed segments entirely below the watermark" {
  let disk = @harness.FakeDisk::new()
  let writer = rt_build_series(disk)
  let removed = match @storage.delete_before(disk, RT_BASE, 5, 4UL) {
    Ok(removed) => removed
    Err(_) => fail("delete_before failed")
  }
  // Segments 0 (last sequence 1) and 1 (last sequence 3) lie below 4.
  assert_eq(removed, 2)
  assert_eq(
    @harness.Disk::read(disk, b"rt-part.segment.0"),
    Err(@harness.PathMissing),
  )
  assert_eq(
    @harness.Disk::read(disk, b"rt-part.segment.1"),
    Err(@harness.PathMissing),
  )
  // Segment 2 (last sequence 5) crosses the watermark and stays.
  if @harness.Disk::read(disk, b"rt-part.segment.2") is Err(_) {
    fail("segment 2 must survive")
  }
  if @harness.Disk::read(disk, b"rt-part.segment.4") is Err(_) {
    fail("the active segment must survive")
  }
  // The write path is unaffected and the holes stay visible.
  let result = @storage.SegmentWriter::append(writer, disk, b"", b"v10")
  if result is Err(_) {
    fail("append after deletion failed")
  }
  let recovery_result = @storage.recover_series(disk, RT_BASE, 5)
  let recovery = match recovery_result {
    Ok(recovery) => recovery
    Err(_) => fail("series recovery failed")
  }
  assert_eq(recovery.gaps.length(), 2)
  assert_eq(recovery.gaps[0].segment_missing, true)
  assert_eq(recovery.gaps[1].segment_missing, true)
}

///|
async test "a segment whose last sequence equals the watermark stays" {
  let disk = @harness.FakeDisk::new()
  let writer = rt_build_series(disk)
  let removed = match @storage.delete_before(disk, RT_BASE, 5, 5UL) {
    Ok(removed) => removed
    Err(_) => fail("delete_before failed")
  }
  // Segment 2 holds sequence 5: entirely below 5 is false at the boundary.
  assert_eq(removed, 2)
  if @harness.Disk::read(disk, b"rt-part.segment.2") is Err(_) {
    fail("boundary segment must survive")
  }
  let _ = writer
}

///|
async test "the active segment is never deleted however high the watermark" {
  let disk = @harness.FakeDisk::new()
  let writer = rt_build_series(disk)
  let removed = match @storage.delete_before(disk, RT_BASE, 5, 1000UL) {
    Ok(removed) => removed
    Err(_) => fail("delete_before failed")
  }
  assert_eq(removed, 4)
  if @harness.Disk::read(disk, b"rt-part.segment.4") is Err(_) {
    fail("the active segment must survive")
  }
  let _ = writer
}

///|
async test "quarantine twins and sidecar notes are reclaimed with their segment" {
  let disk = @harness.FakeDisk::new()
  let writer = rt_build_series(disk)
  let damaged = match @harness.Disk::read(disk, b"rt-part.segment.1") {
    Ok(bytes) => bytes
    Err(_) => fail("sealed segment unreadable")
  }
  let buf = Buffer()
  buf.write_bytes(damaged[:63])
  buf.write_byte(damaged[63] ^ b'\xff')
  buf.write_bytes(damaged[64:])
  let op_result = @harness.Disk::write(
    disk,
    b"rt-part.segment.1",
    buf.contents(),
  )
  if op_result is Err(_) {
    fail("corruption write failed")
  }
  let recovery_result = @storage.recover_series(disk, RT_BASE, 5)
  if recovery_result is Err(_) {
    fail("series recovery failed")
  }
  if @harness.Disk::read(disk, b"rt-part.segment.1.quarantined") is Err(_) {
    fail("quarantine twin missing")
  }
  if @harness.Disk::read(disk, b"rt-part.segment.1.quarantine") is Err(_) {
    fail("quarantine sidecar missing")
  }
  let removed = match @storage.delete_before(disk, RT_BASE, 5, 3UL) {
    Ok(removed) => removed
    Err(_) => fail("delete_before failed")
  }
  // Segment 0 (last sequence 1) and the quarantined segment 1 (readable
  // prefix ends at sequence 2) both lie below 3.
  assert_eq(removed, 2)
  assert_eq(
    @harness.Disk::read(disk, b"rt-part.segment.1.quarantined"),
    Err(@harness.PathMissing),
  )
  assert_eq(
    @harness.Disk::read(disk, b"rt-part.segment.1.quarantine"),
    Err(@harness.PathMissing),
  )
  let _ = writer
}

///|
async test "an orphan sidecar note is cleaned up" {
  let disk = @harness.FakeDisk::new()
  let note_result = @harness.Disk::write(
    disk, b"rt-part.segment.0.quarantine", b"first_bad_offset=0\n",
  )
  if note_result is Err(_) {
    fail("setup write failed")
  }
  let removed = match @storage.delete_before(disk, RT_BASE, 2, 5UL) {
    Ok(removed) => removed
    Err(_) => fail("delete_before failed")
  }
  assert_eq(removed, 0)
  assert_eq(
    @harness.Disk::read(disk, b"rt-part.segment.0.quarantine"),
    Err(@harness.PathMissing),
  )
}

///|
async test "deletion frees bytes and reopens the storage watermark" {
  let disk = @harness.FakeDisk::new()
  let writer = rt_build_series(disk)
  disk.set_capacity(700UL)
  let gate = @storage.Watermark::new(disk)
  // Five segments of 116 bytes fill most of a 700-byte volume: appends
  // are refused at the high watermark.
  let refused = @storage.SegmentWriter::append(
    writer,
    disk,
    b"key",
    b"value-to-push-over",
    watermark=gate,
  )
  if refused is Ok(_) {
    fail("the watermark must refuse before deletion")
  }
  let used_before = disk.used_bytes()
  let removed = match @storage.delete_before(disk, RT_BASE, 5, 7UL) {
    Ok(removed) => removed
    Err(_) => fail("delete_before failed")
  }
  assert_eq(removed, 3)
  assert_eq(disk.used_bytes() < used_before, true)
  // The relief valve reopens the gate and the writer continues.
  let result = @storage.SegmentWriter::append(
    writer,
    disk,
    b"",
    b"v10",
    watermark=gate,
  )
  if result is Err(_) {
    fail("append after relief failed")
  }
}

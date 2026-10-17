/// Exercise the storage high watermark: the 70/85/95 tier table, the
/// pre-write capacity gate shared by segment and ledger writers, and the
/// explicit-refusal contract behind a disk-full injection (never an
/// OOM, never a silent drop).

///|
async fn wm_disk(used : Int32, total : UInt64) -> @harness.FakeDisk {
  let disk = @harness.FakeDisk::new()
  disk.set_capacity(total)
  if used > 0 {
    let filler = Bytes::make(used, b'\x00')
    if @ports.Disk::write(disk, b"volume-fill", filler) is Err(_) {
      fail("filler write failed")
    }
  }
  disk
}

///|
fn wm_value(i : Int32) -> Bytes {
  @utf8.encode(i.to_string())
}

///|
async test "tier boundaries follow the 70/85/95 policy" {
  let cases : Array[Int32] = [699, 700, 849, 850, 949, 950, 1000]
  for used in cases {
    let disk = wm_disk(used, 1000UL)
    let gate = @storage.Watermark::new(disk)
    let expected = match used {
      699 => @storage.Normal
      700 => @storage.Warn
      849 => @storage.Warn
      850 => @storage.High
      949 => @storage.High
      950 => @storage.Full
      _ => @storage.Full
    }
    assert_eq(gate.tier(), expected)
    assert_eq(gate.used_percent(), (used / 10).to_uint64())
  }
}

///|
async test "check_append refuses only when the append would reach the high watermark" {
  let disk = wm_disk(800, 1000UL)
  let gate = @storage.Watermark::new(disk)
  // Warning band: a small append still lands below the 85% line.
  assert_eq(gate.check_append(49), Ok(()))
  // Exactly reaching 85% is already in the rejection band.
  assert_eq(gate.check_append(50), Err(@storage.Capacity))
  assert_eq(gate.check_append(500), Err(@storage.Capacity))
  // Already past the line: every append is refused.
  let full_disk = wm_disk(850, 1000UL)
  let full_gate = @storage.Watermark::new(full_disk)
  assert_eq(full_gate.check_append(0), Err(@storage.Capacity))
  assert_eq(full_gate.check_append(1), Err(@storage.Capacity))
}

///|
async test "a zero capacity is treated as unlimited" {
  let disk = @harness.FakeDisk::new()
  disk.set_capacity(0UL)
  let gate = @storage.Watermark::new(disk)
  assert_eq(gate.used_percent(), 0UL)
  assert_eq(gate.tier(), @storage.Normal)
  assert_eq(gate.check_append(1000000), Ok(()))
}

///|
async test "capacity refusal is distinct from the hard disk-full fault" {
  let disk = wm_disk(900, 1000UL)
  let gate = @storage.Watermark::new(disk)
  assert_eq(gate.check_append(100), Err(@storage.Capacity))
  disk.set_disk_full(true)
  let writer = @storage.SegmentWriter::new(b"wm-distinct.segment")
  assert_eq(
    @storage.SegmentWriter::append(writer, disk, b"", b"abc"),
    Err(@storage.Disk(@ports.DiskFull)),
  )
}

///|
async test "gated segment appends stop at the watermark and resume when capacity frees" {
  let disk = @harness.FakeDisk::new()
  disk.set_capacity(400UL)
  let gate = @storage.Watermark::new(disk)
  let writer = @storage.SegmentWriter::new(b"wm-gated.segment")
  let mut accepted = 0
  let mut refused = false
  while accepted < 20 {
    let result = @storage.SegmentWriter::append(
      writer,
      disk,
      b"",
      wm_value(accepted),
      watermark=gate,
    )
    match result {
      Ok(_) => accepted = accepted + 1
      Err(@storage.Capacity) => {
        refused = true
        break
      }
      Err(_) => fail("append failed for a reason other than capacity")
    }
  }
  assert_eq(refused, true)
  assert_eq(accepted > 0, true)
  // The refusal is explicit and leaves the writer state untouched.
  assert_eq(writer.next_sequence(), accepted.to_uint64())
  // Capacity frees up (operator delete_before / larger volume): appends
  // resume at the same sequence with nothing silently dropped.
  disk.set_capacity(100000UL)
  let op_result1 = @storage.SegmentWriter::append(
    writer,
    disk,
    b"",
    wm_value(accepted),
    watermark=gate,
  )
  if op_result1 is Err(_) {
    fail("append after capacity relief failed")
  }
  assert_eq(writer.next_sequence(), (accepted + 1).to_uint64())
}

///|
async test "disk-full injection rejects explicitly without OOM or silent loss" {
  // The ledger-style flow the delivery writer uses: gate, write, fsync --
  // every attempt ends in an explicit outcome, accepted bytes are durable
  // and readable, and refusals never accumulate hidden state.
  let disk = @harness.FakeDisk::new()
  disk.set_capacity(300UL)
  let gate = @storage.Watermark::new(disk)
  let accepted : Array[Bytes] = []
  let mut explicit_rejects = 0
  let mut attempts = 0
  while attempts < 30 {
    attempts = attempts + 1
    let payload = Bytes::make(50, b'\x01')
    match gate.check_append(payload.length()) {
      Ok(_) => ()
      Err(@storage.Capacity) => {
        explicit_rejects = explicit_rejects + 1
        continue
      }
      Err(_) => fail("gate returned a non-capacity fault")
    }
    let path = b"ledger-" + wm_value(attempts)
    if @ports.Disk::write(disk, path, payload) is Err(_) {
      fail("accepted write must not fail")
    }
    accepted.push(path)
  }
  // Non-silent: every attempt is either durably written or explicitly
  // rejected, and the counts add up.
  assert_eq(attempts, accepted.length() + explicit_rejects)
  assert_eq(explicit_rejects > 0, true)
  // Non-OOM: accepted bytes stay bounded by the capacity accounting.
  assert_eq(disk.used_bytes() <= 300UL, true)
  for path in accepted {
    if @ports.Disk::read(disk, path) is Err(_) {
      fail("accepted write must be readable")
    }
  }
  // The hard disk-full fault is a separate, equally explicit outcome.
  disk.set_disk_full(true)
  let overflow = @ports.Disk::write(disk, b"overflow", Bytes::make(1, b'\x01'))
  assert_eq(overflow, Err(@ports.DiskFull))
}

///|
async test "long-run append pressure hits the watermark backstop without loss" {
  // Long-run pressure: a writer meets the unbounded growth of v0 head-on --
  // every append is either accepted or explicitly refused, every accepted
  // record survives recovery in order with no sequence gap, memory stays
  // bounded by one active segment, and the delete_before relief reopens the
  // gate for the run to continue.
  let disk = @harness.FakeDisk::new()
  disk.set_capacity(20000UL)
  let gate = @storage.Watermark::new(disk)
  let writer = @storage.SegmentWriter::new(
    b"wm-longrun.segment",
    segment_max_bytes=120,
  )
  let mut accepted = 0
  let mut refused = false
  while accepted < 500 {
    let result = @storage.SegmentWriter::append(
      writer,
      disk,
      b"",
      wm_value(accepted),
      watermark=gate,
    )
    match result {
      Ok(_) => accepted = accepted + 1
      Err(@storage.Capacity) => {
        refused = true
        break
      }
      Err(_) => fail("long-run append failed for a reason other than capacity")
    }
  }
  assert_eq(refused, true)
  assert_eq(accepted > 100, true)
  // Memory stays bounded by the active segment, not by the run length.
  assert_eq(writer.active_bytes() <= 120, true)
  // Recovery sees every accepted record, in order, with no hole.
  let recovery_result = @storage.recover_series(
    disk,
    b"wm-longrun.segment",
    writer.segment_count(),
  )
  let recovery = match recovery_result {
    Ok(recovery) => recovery
    Err(_) => fail("long-run series recovery failed")
  }
  assert_eq(recovery.records.length(), accepted)
  assert_eq(recovery.gaps, [])
  assert_eq(recovery.quarantined, [])
  assert_eq(recovery.next_sequence, accepted.to_uint64())
  let first = recovery.records[0]
  let last = recovery.records[recovery.records.length() - 1]
  assert_eq(first.header.sequence, 0UL)
  assert_eq(last.header.sequence, (accepted - 1).to_uint64())
  // The relief valve reopens the gate and the run continues.
  let relief_result = @storage.delete_before(
    disk,
    b"wm-longrun.segment",
    writer.segment_count(),
    100000UL,
  )
  let removed = match relief_result {
    Ok(removed) => removed
    Err(_) => fail("delete_before relief failed")
  }
  assert_eq(removed, writer.segment_count() - 1)
  let resumed = @storage.SegmentWriter::append(
    writer,
    disk,
    b"",
    wm_value(accepted),
    watermark=gate,
  )
  if resumed is Err(_) {
    fail("append after relief failed")
  }
}

/// Exercise deterministic fakes at the CL1/CL2 and fault-seam boundaries.

///|
async test "CL1 does not fire timers early and preserves monotonic time" {
  let clock = @harness.FakeClock::new()
  assert_eq(@harness.Clock::now_ms(clock), 0UL)
  assert_eq(@harness.Clock::sleep_until(clock, 20), false)
  assert_eq(@harness.Clock::sleep_until(clock, 10), false)
  assert_eq(clock.pending_count(), 2)
  clock.advance_to(9)
  assert_eq(@harness.Clock::now_ms(clock), 9UL)
  assert_eq(clock.fired_deadlines().length(), 0)
  clock.advance_to(8)
  assert_eq(@harness.Clock::now_ms(clock), 9UL)
  clock.advance_to(10)
  assert_eq(clock.fired_deadlines(), [10UL])
  clock.advance_to(20)
  assert_eq(clock.fired_deadlines(), [10UL, 20UL])
  assert_eq(clock.pending_count(), 0)
}

///|
async test "CL2 fires matured timers without wall-clock spinning" {
  let clock = @harness.FakeClock::new()
  assert_eq(@harness.Clock::sleep_until(clock, 10), false)
  clock.advance_to(20)
  assert_eq(clock.fired_deadlines(), [10UL])
  assert_eq(@harness.Clock::now_ms(clock), 20UL)
  assert_eq(clock.pending_count(), 0)
}

///|
async test "fake net consumes FIFO delivery and rejects partitioned peers" {
  let net = @harness.FakeNet::new()
  ignore(@harness.Net::send(net, 1, b"one"))
  ignore(@harness.Net::send(net, 2, b"two"))
  ignore(@harness.Net::send(net, 1, b"three"))
  assert_eq(net.sent_messages(), [(1, b"one"), (2, b"two"), (1, b"three")])
  net.partition(3)
  assert_eq(
    @harness.Net::send(net, 3, b"blocked"),
    Err(@harness.PeerPartitioned),
  )
  assert_eq(@harness.Net::receive(net, 1), Some(b"one"))
  assert_eq(@harness.Net::receive(net, 1), Some(b"three"))
  assert_eq(@harness.Net::receive(net, 1), None)
  assert_eq(@harness.Net::receive(net, 2), Some(b"two"))
  assert_eq(net.sent_messages().length(), 3)
}

///|
async test "fake disk persists, syncs, renames, and reports Windows limits" {
  let disk = @harness.FakeDisk::new()
  let capabilities = @harness.Disk::capabilities(disk)
  assert_eq(capabilities.file_fsync, true)
  assert_eq(capabilities.atomic_rename, true)
  assert_eq(capabilities.dir_fsync, false)
  ignore(@harness.Disk::write(disk, b"checkpoint.tmp", b"state"))
  ignore(@harness.Disk::fsync(disk, b"checkpoint.tmp"))
  ignore(@harness.Disk::rename(disk, b"checkpoint.tmp", b"checkpoint"))
  assert_eq(@harness.Disk::read(disk, b"checkpoint"), Ok(b"state"))
  assert_eq(@harness.Disk::read(disk, b"missing"), Err(@harness.PathMissing))
  assert_eq(@harness.Disk::fsync(disk, b"missing"), Err(@harness.PathMissing))
  assert_eq(
    @harness.Disk::rename(disk, b"missing", b"next"),
    Err(@harness.PathMissing),
  )
  disk.set_disk_full(true)
  assert_eq(
    @harness.Disk::write(disk, b"blocked", b"data"),
    Err(@harness.DiskFull),
  )
  assert_eq(@harness.Disk::fsync(disk, b"checkpoint"), Err(@harness.DiskFull))
}

///|
async test "fake disk supports overwrite, replacement, and same-path rename" {
  let disk = @harness.FakeDisk::new()
  ignore(@harness.Disk::write(disk, b"data", b"first"))
  ignore(@harness.Disk::write(disk, b"data", b"second"))
  assert_eq(@harness.Disk::read(disk, b"data"), Ok(b"second"))
  ignore(@harness.Disk::write(disk, b"temp", b"next"))
  ignore(@harness.Disk::rename(disk, b"temp", b"data"))
  assert_eq(@harness.Disk::read(disk, b"data"), Ok(b"next"))
  assert_eq(@harness.Disk::read(disk, b"temp"), Err(@harness.PathMissing))
  ignore(@harness.Disk::rename(disk, b"data", b"data"))
  assert_eq(@harness.Disk::read(disk, b"data"), Ok(b"next"))
}

///|
test "splitmix64 produces the same sequence for the same seed" {
  let first = @harness.SplitMix64::new(20261003UL)
  let second = @harness.SplitMix64::new(20261003UL)
  for _index in 0..<8 {
    assert_eq(@harness.Rng::next_u64(first), @harness.Rng::next_u64(second))
  }
}

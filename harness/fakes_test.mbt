/// Exercise deterministic fakes at their time, network, disk, and RNG seams.

///|
async test "timers do not fire early and preserve monotonic time" {
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
async test "matured timers fire without wall-clock spinning" {
  let clock = @harness.FakeClock::new()
  assert_eq(@harness.Clock::sleep_until(clock, 10), false)
  clock.advance_to(20)
  assert_eq(clock.fired_deadlines(), [10UL])
  assert_eq(@harness.Clock::now_ms(clock), 20UL)
  assert_eq(clock.pending_count(), 0)
}

///|
async test "fake net consumes FIFO delivery and partitions without side effects" {
  let net = @harness.FakeNet::new()
  assert_eq(@harness.Net::send(net, 1, b"one"), Ok(()))
  assert_eq(@harness.Net::send(net, 2, b"two"), Ok(()))
  assert_eq(@harness.Net::send(net, 1, b"three"), Ok(()))
  net.partition(3)
  assert_eq(
    @harness.Net::send(net, 3, b"blocked"),
    Err(@harness.PeerPartitioned),
  )
  assert_eq(@harness.Net::receive(net, 3), None)
  assert_eq(net.sent_messages(), [(1, b"one"), (2, b"two"), (1, b"three")])
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
  assert_eq(@harness.Disk::write(disk, b"checkpoint.tmp", b"state"), Ok(()))
  assert_eq(@harness.Disk::fsync(disk, b"checkpoint.tmp"), Ok(()))
  assert_eq(
    @harness.Disk::rename(disk, b"checkpoint.tmp", b"checkpoint"),
    Ok(()),
  )
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
  assert_eq(@harness.Disk::write(disk, b"data", b"first"), Ok(()))
  assert_eq(@harness.Disk::write(disk, b"data", b"second"), Ok(()))
  assert_eq(@harness.Disk::read(disk, b"data"), Ok(b"second"))
  assert_eq(@harness.Disk::write(disk, b"temp", b"next"), Ok(()))
  assert_eq(@harness.Disk::rename(disk, b"temp", b"data"), Ok(()))
  assert_eq(@harness.Disk::read(disk, b"data"), Ok(b"next"))
  assert_eq(@harness.Disk::read(disk, b"temp"), Err(@harness.PathMissing))
  assert_eq(@harness.Disk::rename(disk, b"data", b"data"), Ok(()))
  assert_eq(@harness.Disk::read(disk, b"data"), Ok(b"next"))
}

///|
async test "fake disk kill point fails the armed and every later mutation" {
  let disk = @harness.FakeDisk::new()
  disk.set_kill_at(2)
  assert_eq(@harness.Disk::write(disk, b"a", b"1"), Ok(()))
  assert_eq(@harness.Disk::fsync(disk, b"a"), Err(@harness.Killed))
  assert_eq(@harness.Disk::rename(disk, b"a", b"b"), Err(@harness.Killed))
  assert_eq(@harness.Disk::write(disk, b"b", b"2"), Err(@harness.Killed))
  assert_eq(@harness.Disk::read(disk, b"a"), Ok(b"1"))
  assert_eq(@harness.Disk::read(disk, b"b"), Err(@harness.PathMissing))
  disk.set_kill_at(0)
  assert_eq(@harness.Disk::rename(disk, b"a", b"b"), Ok(()))
  disk.set_kill_at(1)
  assert_eq(@harness.Disk::fsync(disk, b"b"), Err(@harness.Killed))
  disk.set_disk_full(true)
  assert_eq(@harness.Disk::write(disk, b"c", b"3"), Err(@harness.Killed))
  assert_eq(@harness.Disk::read(disk, b"c"), Err(@harness.PathMissing))
}

///|
test "splitmix64 matches its algorithm known answers" {
  let rng = @harness.SplitMix64::new(20261003UL)
  assert_eq(@harness.Rng::next_uint64(rng), 0x656EA6977F37C42DUL)
  assert_eq(@harness.Rng::next_uint64(rng), 0x8ECCE72B4E28C62AUL)
  assert_eq(@harness.Rng::next_uint64(rng), 0x3725375D1F884F82UL)
  let other = @harness.SplitMix64::new(20261004UL)
  let differing = @harness.Rng::next_uint64(rng) !=
    @harness.Rng::next_uint64(other)
  assert_eq(differing, true)
}

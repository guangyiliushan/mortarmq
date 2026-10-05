/// Exercise the atomic segment checkpoint: codec boundaries, the interruption
/// matrix over its write, fsync, rename sequence, and the two-state
/// invariant under injected disk-op kills.

///|
fn state(
  next_sequence : UInt64,
  durable_offset : UInt,
) -> @storage.SegmentCheckpoint {
  { next_sequence, durable_offset, }
}

///|
fn frozen() -> Bytes {
  b"MMQC\x01\x8f\xea\x2c\x67\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x3e"
}

///|
async fn seed(disk : &@harness.Disk, path : Bytes, data : Bytes) -> Unit {
  assert_eq(@harness.Disk::write(disk, path, data), Ok(()))
}

///|
async fn stored(disk : &@harness.Disk, path : Bytes) -> Bytes {
  match @harness.Disk::read(disk, path) {
    Ok(bytes) => bytes
    Err(_) => fail("checkpoint file read failed")
  }
}

///|
test "checkpoint codec round-trips empty, typical, and maximal states" {
  let states = [
    state(0UL, 0U),
    state(1UL, 62U),
    state(0xFFFFFFFFFFFFFFFFUL, 0xFFFFFFFFU),
  ]
  for value in states {
    let bytes = @storage.encode_checkpoint(value)
    assert_eq(bytes.length(), @storage.CHECKPOINT_BYTES)
    assert_eq(@storage.decode_checkpoint(bytes[:]), Ok(value))
  }
}

///|
test "checkpoint encoding matches the hand-built frozen byte vector" {
  assert_eq(@storage.encode_checkpoint(state(1UL, 62U)), frozen())
  assert_eq(@storage.decode_checkpoint(frozen()[:]), Ok(state(1UL, 62U)))
}

///|
test "checkpoint decoder rejects foreign magic, versions, and wrong lengths" {
  assert_eq(@storage.decode_checkpoint(b""[:]), Err(@storage.Malformed))
  assert_eq(@storage.decode_checkpoint(frozen()[:20]), Err(@storage.Malformed))
  let extended = frozen()[:].to_owned() + b"\x00"
  assert_eq(@storage.decode_checkpoint(extended[:]), Err(@storage.Malformed))
  let foreign : Bytes = b"MMQD\x01\x8f\xea\x2c\x67\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x3e"
  assert_eq(@storage.decode_checkpoint(foreign[:]), Err(@storage.Malformed))
  let future_version : Bytes = b"MMQC\x02\x8f\xea\x2c\x67\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x3e"
  assert_eq(
    @storage.decode_checkpoint(future_version[:]),
    Err(@storage.Malformed),
  )
}

///|
test "checkpoint decoder rejects corrupted payload and checksum bytes" {
  let bytes = @storage.encode_checkpoint(state(1UL, 62U))
  let corrupt_payload = bytes[:12].to_owned() + b"\x01" + bytes[13:].to_owned()
  assert_eq(
    @storage.decode_checkpoint(corrupt_payload[:]),
    Err(@storage.Malformed),
  )
  let corrupt_crc = bytes[:5].to_owned() + b"\x87" + bytes[6:].to_owned()
  assert_eq(@storage.decode_checkpoint(corrupt_crc[:]), Err(@storage.Malformed))
}

///|
async test "atomic checkpoint publish replaces the state and consumes its tmp" {
  let disk : &@harness.Disk = @harness.FakeDisk::new()
  let old = state(10UL, 620U)
  let new = state(11UL, 682U)
  seed(disk, b"segment.checkpoint", @storage.encode_checkpoint(old))
  assert_eq(@storage.write_checkpoint(disk, b"segment.checkpoint", new), Ok(()))
  assert_eq(
    stored(disk, b"segment.checkpoint"),
    @storage.encode_checkpoint(new),
  )
  assert_eq(
    @harness.Disk::read(disk, b"segment.checkpoint.tmp"),
    Err(@harness.PathMissing),
  )
  assert_eq(
    @storage.decode_checkpoint(stored(disk, b"segment.checkpoint")[:]),
    Ok(new),
  )
}

///|
async test "interrupted checkpoints leave exactly the old or the new state" {
  let old_bytes = @storage.encode_checkpoint(state(10UL, 620U))
  let new_bytes = @storage.encode_checkpoint(state(11UL, 682U))
  let new = state(11UL, 682U)
  // The seeding write is disk op 1; the publish sequence is ops 2, 3, 4.
  // Die on the tmp write (op 2), the fsync (op 3), and the rename (op 4).
  for armed in [2, 3, 4] {
    let disk = @harness.FakeDisk::new()
    seed(disk, b"segment.checkpoint", old_bytes)
    disk.set_kill_at(armed)
    assert_eq(
      @storage.write_checkpoint(disk, b"segment.checkpoint", new),
      Err(@harness.Killed),
    )
    assert_eq(stored(disk, b"segment.checkpoint"), old_bytes)
    if armed == 2 {
      assert_eq(
        @harness.Disk::read(disk, b"segment.checkpoint.tmp"),
        Err(@harness.PathMissing),
      )
    } else {
      assert_eq(
        @harness.Disk::read(disk, b"segment.checkpoint.tmp"),
        Ok(new_bytes),
      )
    }
  }
  // A kill during the tmp write itself: the tmp holds a torn prefix of the
  // new bytes and recovery must refuse it instead of decoding a mixture.
  let torn_disk = @harness.FakeDisk::new()
  seed(torn_disk, b"segment.checkpoint", old_bytes)
  seed(torn_disk, b"segment.checkpoint.tmp", new_bytes[:5].to_owned())
  torn_disk.set_kill_at(3)
  assert_eq(
    @storage.write_checkpoint(torn_disk, b"segment.checkpoint", new),
    Err(@harness.Killed),
  )
  assert_eq(stored(torn_disk, b"segment.checkpoint"), old_bytes)
  assert_eq(
    @storage.decode_checkpoint(stored(torn_disk, b"segment.checkpoint.tmp")[:]),
    Err(@storage.Malformed),
  )
}

///|
async test "every armed kill point preserves the two-state invariant" {
  let rng = @harness.SplitMix64::new(20261004UL)
  for _iteration in 0..<100 {
    let old = state(
      @harness.Rng::next_uint64(rng),
      @harness.Rng::next_uint64(rng).to_uint(),
    )
    let new = state(
      @harness.Rng::next_uint64(rng),
      @harness.Rng::next_uint64(rng).to_uint(),
    )
    let old_bytes = @storage.encode_checkpoint(old)
    let new_bytes = @storage.encode_checkpoint(new)
    // Armed ops 2..5: die on the write, the fsync, the rename, or complete.
    let armed = (@harness.Rng::next_uint64(rng) % 4UL).to_int() + 2
    let disk = @harness.FakeDisk::new()
    seed(disk, b"segment.checkpoint", old_bytes)
    disk.set_kill_at(armed)
    let attempt = @storage.write_checkpoint(disk, b"segment.checkpoint", new)
    if armed == 5 {
      assert_eq(attempt, Ok(()))
    } else {
      assert_eq(attempt, Err(@harness.Killed))
    }
    if armed == 5 {
      assert_eq(stored(disk, b"segment.checkpoint"), new_bytes)
    } else {
      assert_eq(stored(disk, b"segment.checkpoint"), old_bytes)
    }
    if armed == 3 || armed == 4 {
      assert_eq(
        @harness.Disk::read(disk, b"segment.checkpoint.tmp"),
        Ok(new_bytes),
      )
    } else {
      assert_eq(
        @harness.Disk::read(disk, b"segment.checkpoint.tmp"),
        Err(@harness.PathMissing),
      )
    }
  }
}

///|
async test "rewriting an unchanged checkpoint is idempotent" {
  let disk : &@harness.Disk = @harness.FakeDisk::new()
  let value = state(10UL, 620U)
  seed(disk, b"segment.checkpoint", @storage.encode_checkpoint(value))
  assert_eq(
    @storage.write_checkpoint(disk, b"segment.checkpoint", value),
    Ok(()),
  )
  let once = stored(disk, b"segment.checkpoint")
  assert_eq(
    @storage.write_checkpoint(disk, b"segment.checkpoint", value),
    Ok(()),
  )
  assert_eq(stored(disk, b"segment.checkpoint"), once)
  assert_eq(@storage.decode_checkpoint(once[:]), Ok(value))
  assert_eq(
    @harness.Disk::read(disk, b"segment.checkpoint.tmp"),
    Err(@harness.PathMissing),
  )
}

///|
async test "recovery reads ignore a stale tmp left by an interrupted attempt" {
  let disk : &@harness.Disk = @harness.FakeDisk::new()
  let old = state(10UL, 620U)
  let new = state(11UL, 682U)
  seed(disk, b"segment.checkpoint", @storage.encode_checkpoint(old))
  seed(disk, b"segment.checkpoint.tmp", b"abandoned half-written bytes")
  assert_eq(
    @storage.decode_checkpoint(stored(disk, b"segment.checkpoint")[:]),
    Ok(old),
  )
  assert_eq(
    @storage.decode_checkpoint(stored(disk, b"segment.checkpoint.tmp")[:]),
    Err(@storage.Malformed),
  )
  assert_eq(@storage.write_checkpoint(disk, b"segment.checkpoint", new), Ok(()))
  assert_eq(
    stored(disk, b"segment.checkpoint"),
    @storage.encode_checkpoint(new),
  )
  assert_eq(
    @harness.Disk::read(disk, b"segment.checkpoint.tmp"),
    Err(@harness.PathMissing),
  )
}

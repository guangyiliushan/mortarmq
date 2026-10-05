/// Exercise startup recovery: the from-zero and fail-closed edge policies,
/// the stop-at-boundary rule for truncated tails, and bit-exact recovered
/// state across injected kill points and independent replays.

///|
const SEGMENT_PATH : Bytes = b"partition-0.segment"

///|
const CHECKPOINT_PATH : Bytes = b"partition-0.checkpoint"

///|
const ALPHABET : Bytes = b"abcdefghijklmnopqrstuvwxyz"

///|
fn test_header(
  sequence : UInt64,
  key : Bytes,
  value : Bytes,
) -> @storage.RecordHeader {
  let flags : UInt16 = if key.length() > 0 { 1 } else { 0 }
  @storage.RecordHeader::new(
    flags~,
    key_length=key.length().to_uint16(),
    value_length=value.length().reinterpret_as_uint(),
    sequence~,
    producer_id=7UL,
    producer_seq=sequence,
    timestamp_unix_ms=1000UL + sequence,
    leader_epoch=0,
    replication_flags=0,
  )
}

///|
fn test_record(sequence : UInt64, key : Bytes, value : Bytes) -> Bytes raise {
  match
    @storage.encode_record_header(test_header(sequence, key, value), key, value) {
    Ok(bytes) => bytes
    Err(_) => fail("test record encoding failed")
  }
}

///|
fn expected_record(
  sequence : UInt64,
  key : Bytes,
  value : Bytes,
) -> @storage.RecoveredRecord {
  { header: test_header(sequence, key, value), key, value, }
}

///|
fn recovery_of(
  next_sequence : UInt64,
  durable_offset : UInt,
  records : Array[@storage.RecoveredRecord],
) -> @storage.SegmentRecovery {
  { checkpoint: { next_sequence, durable_offset, }, records, }
}

///|
fn join_records(records : Array[Bytes]) -> Bytes {
  let buf = Buffer()
  for bytes in records {
    buf.write_bytes(bytes)
  }
  buf.contents()
}

///|
fn reserialize(records : Array[@storage.RecoveredRecord]) -> Bytes raise {
  let buf = Buffer()
  for record in records {
    match
      @storage.encode_record_header(record.header, record.key, record.value) {
      Ok(bytes) => buf.write_bytes(bytes)
      Err(_) => fail("re-encoding a recovered record failed")
    }
  }
  buf.contents()
}

///|
/// Run one scheduled disk step; false means the kill fired and death follows.
fn survive(step : Result[Unit, @harness.HarnessFault]) -> Bool raise {
  match step {
    Ok(_) => true
    Err(@harness.Killed) => false
    Err(_) => fail("schedule hit an unexpected fault")
  }
}

///|
async fn stored_segment(disk : &@harness.Disk) -> Bytes {
  match @harness.Disk::read(disk, SEGMENT_PATH) {
    Ok(bytes) => bytes
    Err(_) => b""
  }
}

///|
async test "a fresh disk recovers an empty partition from zero" {
  let disk : &@harness.Disk = @harness.FakeDisk::new()
  assert_eq(
    @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
    Ok(recovery_of(0UL, 0U, [])),
  )
}

///|
async test "a missing checkpoint replays the whole segment from zero" {
  let disk = @harness.FakeDisk::new()
  let segment = join_records([
    test_record(1UL, b"k1", b"v1"),
    test_record(2UL, b"k2", b"v2"),
  ])
  assert_eq(@harness.Disk::write(disk, SEGMENT_PATH, segment), Ok(()))
  let expected = Ok(
    recovery_of(3UL, segment.length().reinterpret_as_uint(), [
      expected_record(1UL, b"k1", b"v1"),
      expected_record(2UL, b"k2", b"v2"),
    ]),
  )
  assert_eq(
    @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
    expected,
  )
  // A torn tmp sibling is never checkpoint state; recovery still starts
  // from zero and ignores it.
  assert_eq(
    @harness.Disk::write(
      disk,
      CHECKPOINT_PATH + b".tmp",
      b"torn checkpoint bytes",
    ),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
    expected,
  )
}

///|
async test "an unreadable checkpoint fails recovery closed" {
  let segment = test_record(1UL, b"k1", b"v1")
  let corrupt = @harness.FakeDisk::new()
  assert_eq(@harness.Disk::write(corrupt, SEGMENT_PATH, segment), Ok(()))
  assert_eq(
    @harness.Disk::write(
      corrupt,
      CHECKPOINT_PATH,
      b"MMQC foreign bytes that never decode",
    ),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(corrupt, SEGMENT_PATH, CHECKPOINT_PATH),
    Err(@storage.Malformed),
  )
  // A flipped payload byte behind a stale checksum reports the same fault.
  let flipped = @harness.FakeDisk::new()
  let valid = @storage.encode_checkpoint({
    next_sequence: 2UL,
    durable_offset: segment.length().reinterpret_as_uint(),
  })
  assert_eq(@harness.Disk::write(flipped, SEGMENT_PATH, segment), Ok(()))
  assert_eq(
    @harness.Disk::write(
      flipped,
      CHECKPOINT_PATH,
      valid[:9].to_owned() + b"\xff" + valid[10:].to_owned(),
    ),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(flipped, SEGMENT_PATH, CHECKPOINT_PATH),
    Err(@storage.Malformed),
  )
}

///|
async test "a checkpoint at offset zero replays every record" {
  let disk = @harness.FakeDisk::new()
  let segment = join_records([
    test_record(1UL, b"k1", b"v1"),
    test_record(2UL, b"k2", b"v2"),
  ])
  assert_eq(@harness.Disk::write(disk, SEGMENT_PATH, segment), Ok(()))
  assert_eq(
    @storage.write_checkpoint(disk, CHECKPOINT_PATH, {
      next_sequence: 1UL,
      durable_offset: 0U,
    }),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
    Ok(
      recovery_of(3UL, segment.length().reinterpret_as_uint(), [
        expected_record(1UL, b"k1", b"v1"),
        expected_record(2UL, b"k2", b"v2"),
      ]),
    ),
  )
}

///|
async test "a checkpoint covering the segment leaves nothing to replay" {
  let disk = @harness.FakeDisk::new()
  let segment = test_record(1UL, b"k1", b"v1")
  assert_eq(@harness.Disk::write(disk, SEGMENT_PATH, segment), Ok(()))
  assert_eq(
    @storage.write_checkpoint(disk, CHECKPOINT_PATH, {
      next_sequence: 2UL,
      durable_offset: segment.length().reinterpret_as_uint(),
    }),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
    Ok(recovery_of(2UL, segment.length().reinterpret_as_uint(), [])),
  )
}

///|
async test "recovered next_sequence continues the replayed sequences" {
  let disk = @harness.FakeDisk::new()
  let first = test_record(1UL, b"k1", b"v1")
  let rest = join_records([
    test_record(2UL, b"k2", b"v2"),
    test_record(3UL, b"k3", b"v3"),
  ])
  assert_eq(@harness.Disk::write(disk, SEGMENT_PATH, first + rest), Ok(()))
  assert_eq(
    @storage.write_checkpoint(disk, CHECKPOINT_PATH, {
      next_sequence: 2UL,
      durable_offset: first.length().reinterpret_as_uint(),
    }),
    Ok(()),
  )
  // The fold carries the last replayed sequence: 3 on disk, so 4 recovers.
  assert_eq(
    @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
    Ok(
      recovery_of(4UL, (first + rest).length().reinterpret_as_uint(), [
        expected_record(2UL, b"k2", b"v2"),
        expected_record(3UL, b"k3", b"v3"),
      ]),
    ),
  )
  // Nothing replayed: the checkpoint's own sequence stands.
  let quiet = @harness.FakeDisk::new()
  assert_eq(
    @storage.write_checkpoint(quiet, CHECKPOINT_PATH, {
      next_sequence: 42UL,
      durable_offset: 0U,
    }),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(quiet, SEGMENT_PATH, CHECKPOINT_PATH),
    Ok(recovery_of(42UL, 0U, [])),
  )
}

///|
async test "a stale checkpoint sequence yields to the replayed records" {
  let disk = @harness.FakeDisk::new()
  let segment = join_records([
    test_record(1UL, b"k1", b"v1"),
    test_record(2UL, b"k2", b"v2"),
  ])
  assert_eq(@harness.Disk::write(disk, SEGMENT_PATH, segment), Ok(()))
  assert_eq(
    @storage.write_checkpoint(disk, CHECKPOINT_PATH, {
      next_sequence: 9UL,
      durable_offset: 0U,
    }),
    Ok(()),
  )
  // The checkpoint sequence is stale, so the replayed records win: the fold
  // carries the last replayed sequence, never the contradictory checkpoint's.
  assert_eq(
    @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
    Ok(
      recovery_of(3UL, segment.length().reinterpret_as_uint(), [
        expected_record(1UL, b"k1", b"v1"),
        expected_record(2UL, b"k2", b"v2"),
      ]),
    ),
  )
}

///|
async test "truncated tails stop replay at the last complete record" {
  let first = test_record(1UL, b"k1", b"v1")
  let second = test_record(2UL, b"k2", b"v2")
  let complete = first + second
  let expected = Ok(
    recovery_of(3UL, complete.length().reinterpret_as_uint(), [
      expected_record(1UL, b"k1", b"v1"),
      expected_record(2UL, b"k2", b"v2"),
    ]),
  )
  // Fewer than four trailing bytes cannot hold a length prefix.
  let short = @harness.FakeDisk::new()
  assert_eq(
    @harness.Disk::write(short, SEGMENT_PATH, complete + b"\x01\x02"),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(short, SEGMENT_PATH, CHECKPOINT_PATH),
    expected,
  )
  // A valid length prefix whose record body extends past the segment end.
  let torn_body = @harness.FakeDisk::new()
  assert_eq(
    @harness.Disk::write(
      torn_body,
      SEGMENT_PATH,
      complete + second[:20].to_owned(),
    ),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(torn_body, SEGMENT_PATH, CHECKPOINT_PATH),
    expected,
  )
  // Trailing garbage is never rescanned: recovery reports the boundary and
  // not the bytes past it.
  let garbage = @harness.FakeDisk::new()
  assert_eq(
    @harness.Disk::write(
      garbage,
      SEGMENT_PATH,
      complete + b"\x00\x00\x00\x3a\x00garbage",
    ),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(garbage, SEGMENT_PATH, CHECKPOINT_PATH),
    expected,
  )
  // The recovered prefix re-serializes to the exact complete bytes.
  let recovered = match
    @storage.recover_segment(short, SEGMENT_PATH, CHECKPOINT_PATH) {
    Ok(recovery) => recovery
    Err(_) => fail("boundary recovery must succeed")
  }
  assert_eq(reserialize(recovered.records), complete)
}

///|
async test "records with empty key and value replay bit-exact" {
  let disk = @harness.FakeDisk::new()
  let record = test_record(1UL, b"", b"")
  assert_eq(record.length(), @storage.RECORD_HEADER_BYTES)
  assert_eq(@harness.Disk::write(disk, SEGMENT_PATH, record), Ok(()))
  assert_eq(
    @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
    Ok(
      recovery_of(2UL, record.length().reinterpret_as_uint(), [
        expected_record(1UL, b"", b""),
      ]),
    ),
  )
}

///|
async test "a complete but corrupt record fails recovery closed" {
  let disk = @harness.FakeDisk::new()
  let good = test_record(1UL, b"k1", b"v1")
  let bad = test_record(2UL, b"k2", b"v2")
  assert_eq(
    @harness.Disk::write(
      disk,
      SEGMENT_PATH,
      good + bad[:30].to_owned() + b"\xff" + bad[31:].to_owned(),
    ),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
    Err(@storage.Malformed),
  )
}

///|
async test "a checkpoint past the segment end fails recovery closed" {
  let disk = @harness.FakeDisk::new()
  assert_eq(
    @harness.Disk::write(disk, SEGMENT_PATH, test_record(1UL, b"k1", b"v1")),
    Ok(()),
  )
  assert_eq(
    @harness.Disk::write(
      disk,
      CHECKPOINT_PATH,
      @storage.encode_checkpoint({ next_sequence: 9UL, durable_offset: 4096U, }),
    ),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
    Err(@storage.Malformed),
  )
}

///|
async test "a missing segment under a nonzero durable prefix fails closed" {
  let disk = @harness.FakeDisk::new()
  assert_eq(
    @storage.write_checkpoint(disk, CHECKPOINT_PATH, {
      next_sequence: 4UL,
      durable_offset: 620U,
    }),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
    Err(@storage.DiskFault(@harness.PathMissing)),
  )
  // A zero offset covers no bytes, so a missing segment is an empty replay.
  let fresh = @harness.FakeDisk::new()
  assert_eq(
    @storage.write_checkpoint(fresh, CHECKPOINT_PATH, {
      next_sequence: 4UL,
      durable_offset: 0U,
    }),
    Ok(()),
  )
  assert_eq(
    @storage.recover_segment(fresh, SEGMENT_PATH, CHECKPOINT_PATH),
    Ok(recovery_of(4UL, 0U, [])),
  )
}

///|
async test "replay re-serializes the recovered prefix byte-identically" {
  let disk = @harness.FakeDisk::new()
  let durable = join_records([
    test_record(1UL, b"k1", b"v1"),
    test_record(2UL, b"k2", b"v2"),
  ])
  let appended = test_record(3UL, b"k3", b"v3")
  assert_eq(@harness.Disk::write(disk, SEGMENT_PATH, durable), Ok(()))
  assert_eq(
    @storage.write_checkpoint(disk, CHECKPOINT_PATH, {
      next_sequence: 3UL,
      durable_offset: durable.length().reinterpret_as_uint(),
    }),
    Ok(()),
  )
  // The append lands as disk op 5; the kill then stops the next publish, so
  // the restart finds one uncovered record behind a stale checkpoint.
  assert_eq(
    @harness.Disk::write(disk, SEGMENT_PATH, durable + appended),
    Ok(()),
  )
  disk.set_kill_at(6)
  assert_eq(
    @storage.write_checkpoint(disk, CHECKPOINT_PATH, {
      next_sequence: 4UL,
      durable_offset: (durable + appended).length().reinterpret_as_uint(),
    }),
    Err(@harness.Killed),
  )
  let recovered = match
    @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH) {
    Ok(recovery) => recovery
    Err(_) => fail("recovery after the kill must succeed")
  }
  assert_eq(recovered.checkpoint.next_sequence, 4UL)
  assert_eq(
    recovered.checkpoint.durable_offset,
    (durable + appended).length().reinterpret_as_uint(),
  )
  assert_eq(recovered.records.length(), 1)
  // The replayed record re-encodes to the exact appended bytes, and the
  // replayed region matches the pre-kill segment bytes byte for byte.
  assert_eq(reserialize(recovered.records), appended)
  let replayed_region = stored_segment(disk)[durable.length():recovered.checkpoint.durable_offset.reinterpret_as_int()].to_owned()
  assert_eq(reserialize(recovered.records), replayed_region)
}

///|
async test "restart after any kill seam recovers exactly one state" {
  let prefix = [
    test_record(1UL, b"k1", b"v1"),
    test_record(2UL, b"", b"v2-longer"),
    test_record(3UL, b"k3-wide", b""),
  ]
  let suffix = [
    test_record(4UL, b"k4", b"v4"),
    test_record(5UL, b"", b""),
    test_record(6UL, b"k6-wide", b"v6"),
  ]
  let prefix_bytes = join_records(prefix)
  let full_bytes = prefix_bytes + join_records(suffix)
  let prefix_expected = [
    expected_record(1UL, b"k1", b"v1"),
    expected_record(2UL, b"", b"v2-longer"),
    expected_record(3UL, b"k3-wide", b""),
  ]
  let suffix_expected = [
    expected_record(4UL, b"k4", b"v4"),
    expected_record(5UL, b"", b""),
    expected_record(6UL, b"k6-wide", b"v6"),
  ]
  let prefix_len = prefix_bytes.length().reinterpret_as_uint()
  let record4_len = suffix[0].length().reinterpret_as_uint()
  let record5_len = suffix[1].length().reinterpret_as_uint()
  let full_len = full_bytes.length().reinterpret_as_uint()
  let prefix_state : @storage.SegmentCheckpoint = {
    next_sequence: 4UL,
    durable_offset: prefix_len,
  }
  // Disk ops: seed is op 1, the prefix publish is ops 2-4, each append is
  // one op (5-7), and the final publish is ops 8-10. Every armed position
  // is a distinct crash seam.
  for armed in 1..<=10 {
    let disk = @harness.FakeDisk::new()
    disk.set_kill_at(armed)
    let mut alive = survive(
      @harness.Disk::write(disk, SEGMENT_PATH, prefix_bytes),
    )
    if alive {
      alive = survive(
        @storage.write_checkpoint(disk, CHECKPOINT_PATH, prefix_state),
      )
    }
    let mut current = prefix_bytes
    if alive {
      for record in suffix {
        current = current + record
        alive = survive(@harness.Disk::write(disk, SEGMENT_PATH, current))
        if !alive {
          break
        }
      }
    }
    if alive {
      match
        @storage.write_checkpoint(disk, CHECKPOINT_PATH, {
          next_sequence: 7UL,
          durable_offset: full_len,
        }) {
        Ok(_) => ()
        Err(@harness.Killed) => ()
        Err(_) => fail("final publish hit an unexpected fault")
      }
    }
    let first = match
      @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH) {
      Ok(recovery) => recovery
      Err(_) => fail("recovery after a kill must succeed")
    }
    // Repro 100%: the same surviving bytes recover the same state again.
    assert_eq(
      @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
      Ok(first),
    )
    let expected = match armed {
      1 => recovery_of(0UL, 0U, [])
      2 | 3 | 4 => recovery_of(4UL, prefix_len, prefix_expected)
      5 => recovery_of(4UL, prefix_len, [])
      6 => recovery_of(5UL, prefix_len + record4_len, [suffix_expected[0]])
      7 =>
        recovery_of(6UL, prefix_len + record4_len + record5_len, [
          suffix_expected[0],
          suffix_expected[1],
        ])
      _ => recovery_of(7UL, full_len, suffix_expected)
    }
    assert_eq(first, expected)
  }
}

///|
async test "seeded kill points recover one state across independent replays" {
  let rng = @harness.SplitMix64::new(20261005UL)
  for _iteration in 0..<100 {
    let durable = join_records([
      test_record(1UL, b"k1", b"v1"),
      test_record(2UL, b"k2", b"v2"),
    ])
    let durable_len = durable.length().reinterpret_as_uint()
    let prefix_expected = [
      expected_record(1UL, b"k1", b"v1"),
      expected_record(2UL, b"k2", b"v2"),
    ]
    let suffix_count = (@harness.Rng::next_uint64(rng) % 5UL).to_int()
    let appended_bytes = []
    let specs = []
    for index in 0..<suffix_count {
      let sequence = (3 + index).to_uint64()
      let key = random_payload(rng, 3)
      let value = random_payload(rng, 5)
      appended_bytes.push(test_record(sequence, key, value))
      specs.push(expected_record(sequence, key, value))
    }
    // Ops: seed is 1, the prefix publish is 2-4, appends are 5.., the final
    // publish is three ops; one past them completes without a kill.
    let total_ops = 8 + suffix_count
    let armed = (@harness.Rng::next_uint64(rng) % total_ops.to_uint64()).to_int() +
      1
    let disk = @harness.FakeDisk::new()
    disk.set_kill_at(armed)
    let mut alive = survive(@harness.Disk::write(disk, SEGMENT_PATH, durable))
    if alive {
      alive = survive(
        @storage.write_checkpoint(disk, CHECKPOINT_PATH, {
          next_sequence: 3UL,
          durable_offset: durable_len,
        }),
      )
    }
    let mut current = durable
    if alive {
      for record in appended_bytes {
        current = current + record
        alive = survive(@harness.Disk::write(disk, SEGMENT_PATH, current))
        if !alive {
          break
        }
      }
    }
    if alive {
      match
        @storage.write_checkpoint(disk, CHECKPOINT_PATH, {
          next_sequence: (3 + suffix_count).to_uint64(),
          durable_offset: current.length().reinterpret_as_uint(),
        }) {
        Ok(_) => ()
        Err(@harness.Killed) => ()
        Err(_) => fail("sweep publish hit an unexpected fault")
      }
    }
    let landed = if armed <= 4 {
      0
    } else if armed - 5 < suffix_count {
      armed - 5
    } else {
      suffix_count
    }
    let mut all_bytes = 0
    for record in appended_bytes {
      all_bytes = all_bytes + record.length()
    }
    let mut landed_bytes = 0
    let landed_expected : Array[@storage.RecoveredRecord] = []
    for index in 0..<landed {
      landed_bytes = landed_bytes + appended_bytes[index].length()
      landed_expected.push(specs[index])
    }
    let expected = if armed == 1 {
      recovery_of(0UL, 0U, [])
    } else if armed <= 4 {
      recovery_of(3UL, durable_len, prefix_expected)
    } else if armed == total_ops {
      // The final publish completed, so the checkpoint covers every record
      // and replay has nothing left to fold.
      recovery_of(
        (3 + suffix_count).to_uint64(),
        durable_len + all_bytes.reinterpret_as_uint(),
        [],
      )
    } else {
      recovery_of(
        (3 + landed).to_uint64(),
        durable_len + landed_bytes.reinterpret_as_uint(),
        landed_expected,
      )
    }
    let first = match
      @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH) {
      Ok(recovery) => recovery
      Err(_) => fail("sweep recovery must succeed")
    }
    // Repro 100%: two replays on the dead disk and one on a rebuilt disk
    // holding the same bytes all recover the identical state.
    assert_eq(
      @storage.recover_segment(disk, SEGMENT_PATH, CHECKPOINT_PATH),
      Ok(first),
    )
    let mirror = @harness.FakeDisk::new()
    for (path, bytes) in disk.snapshot() {
      ignore(@harness.Disk::write(mirror, path, bytes))
    }
    assert_eq(
      @storage.recover_segment(mirror, SEGMENT_PATH, CHECKPOINT_PATH),
      Ok(first),
    )
    assert_eq(first, expected)
    // The replayed region re-serializes byte-identically to the disk bytes.
    // Replay starts at the live checkpoint's coverage: zero when the prefix
    // publish died, the full offset when it completed, the durable prefix
    // otherwise.
    let replay_start = if armed == total_ops {
      (durable_len + all_bytes.reinterpret_as_uint()).reinterpret_as_int()
    } else if armed <= 4 {
      0
    } else {
      durable_len.reinterpret_as_int()
    }
    let region = stored_segment(disk)[replay_start:first.checkpoint.durable_offset.reinterpret_as_int()].to_owned()
    assert_eq(reserialize(first.records), region)
  }
}

///|
fn random_payload(rng : &@harness.Rng, max_length : Int) -> Bytes {
  let length = (@harness.Rng::next_uint64(rng) % (max_length + 1).to_uint64()).to_int()
  ALPHABET[:length].to_owned()
}

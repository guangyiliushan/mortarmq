/// Exercise metadata snapshot publication and recovery (T057).

///|
fn mutationRecord(
  mutationId : UInt64,
  epoch : UInt64,
  body : @metadata.DeclareBody,
) -> Bytes raise {
  match
    @metadata.encodeMmmlRecord(
      @metadata.MmmlHeader::new(
        formatVersion=1,
        headerVersion=1,
        flags=0,
        recordType=body.toRecordType(),
        leaderEpoch=epoch,
        mutationId~,
      ),
      body.toPayload()[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("mutation encoding failed")
  }
}

///|
fn hintRecord(epoch : UInt64) -> Bytes raise {
  match
    @metadata.encodeMmmlRecord(
      @metadata.MmmlHeader::new(
        formatVersion=1,
        headerVersion=1,
        flags=0,
        recordType=@metadata.MmmlRecordType::SnapshotHint,
        leaderEpoch=epoch,
        mutationId=0,
      ),
      b"hint"[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("hint encoding failed")
  }
}

///|
fn join(parts : Array[Bytes]) -> Bytes {
  let buf = Buffer()
  for part in parts {
    buf.write_bytes(part)
  }
  buf.contents()
}

///|
fn machineWith(
  submits : Array[(UInt64, @metadata.DeclareBody)],
) -> @metadata.DeclareMachine {
  let machine = @metadata.DeclareMachine::new()
  for (mutationId, body) in submits {
    ignore(machine.submit(mutationId, 0UL, body))
  }
  machine
}

///|
fn fingerprint(machine : @metadata.DeclareMachine) -> Array[String] {
  let out : Array[String] = []
  for (name, count) in machine.topics.to_array() {
    out.push("t:" + name + ":" + count.to_string())
  }
  for (key, table) in machine.accepted.to_array() {
    for (mutationId, body) in table.to_array() {
      out.push(
        "a:" +
        key +
        ":" +
        mutationId.to_string() +
        ":" +
        body.to_repr().to_string(),
      )
    }
  }
  out.sort()
  out
}

///|
fn encodedSnapshot(
  machine : @metadata.DeclareMachine,
  epoch : UInt64,
  endOffset : UInt64,
) -> Bytes raise {
  match @metadata.encodeSnapshot({ machine, epoch, endOffset, }) {
    Ok(bytes) => bytes
    Err(_) => fail("snapshot encoding failed")
  }
}

///|
test "snapshot round-trips machine state and position" {
  let machine = machineWith([
    (1UL, @metadata.DeclareBody::Create("orders", 3)),
    (2UL, @metadata.DeclareBody::Delete("orders")),
    (3UL, @metadata.DeclareBody::Create("orders", 5)),
    (4UL, @metadata.DeclareBody::Create("payments", 1)),
  ])
  let bytes = encodedSnapshot(machine, 7UL, 4096UL)
  match @metadata.decodeSnapshot(bytes[:]) {
    Ok(decoded) => {
      assert_eq(decoded.epoch, 7UL)
      assert_eq(decoded.endOffset, 4096UL)
      assert_eq(fingerprint(decoded.machine), fingerprint(machine))
    }
    Err(_) => fail("snapshot decoding failed")
  }
}

///|
test "snapshot rejects a flipped byte in any of its records" {
  let machine = machineWith([
    (1UL, @metadata.DeclareBody::Create("orders", 3)),
    (2UL, @metadata.DeclareBody::Create("payments", 1)),
  ])
  let bytes = encodedSnapshot(machine, 1UL, 64UL)
  assert_eq(@metadata.decodeSnapshot(flipByte(bytes, 30)[:]) is Err(_), true)
  assert_eq(@metadata.decodeSnapshot(flipByte(bytes, 60)[:]) is Err(_), true)
  assert_eq(
    @metadata.decodeSnapshot(flipByte(bytes, bytes.length() - 5)[:]) is Err(_),
    true,
  )
}

///|
test "snapshot refuses a file whose footer is missing" {
  let machine = machineWith([(1UL, @metadata.DeclareBody::Create("orders", 3))])
  let bytes = encodedSnapshot(machine, 1UL, 64UL)
  let footerLen = @metadata.MMML_HEADER_BYTES + 2
  assert_eq(
    @metadata.decodeSnapshot(bytes[:bytes.length() - footerLen]) is Err(_),
    true,
  )
  assert_eq(@metadata.decodeSnapshot(bytes[:35]) is Err(_), true)
}

///|
test "snapshot refuses a wrong format version" {
  let header = Buffer()
  header.write_uint16_be(2)
  header.write_uint64_be(0UL)
  let headerRecord = match
    @metadata.encodeMmmlRecord(
      @metadata.MmmlHeader::new(
        formatVersion=1,
        headerVersion=1,
        flags=0,
        recordType=@metadata.MmmlRecordType::SnapshotHint,
        leaderEpoch=1,
        mutationId=0,
      ),
      header.contents()[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("header encoding failed")
  }
  let footer = Buffer()
  footer.write_uint16_be(1)
  let footerRecord = match
    @metadata.encodeMmmlRecord(
      @metadata.MmmlHeader::new(
        formatVersion=1,
        headerVersion=1,
        flags=0,
        recordType=@metadata.MmmlRecordType::SnapshotHint,
        leaderEpoch=1,
        mutationId=0,
      ),
      footer.contents()[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("footer encoding failed")
  }
  assert_eq(
    @metadata.decodeSnapshot(join([headerRecord, footerRecord])[:]) is Err(_),
    true,
  )
}

///|
test "snapshot refuses records carrying a mutation id" {
  let buf = Buffer()
  buf.write_uint16_be(1)
  buf.write_uint64_be(64UL)
  let headerRecord = match
    @metadata.encodeMmmlRecord(
      @metadata.MmmlHeader::new(
        formatVersion=1,
        headerVersion=1,
        flags=0,
        recordType=@metadata.MmmlRecordType::SnapshotHint,
        leaderEpoch=1,
        mutationId=1,
      ),
      buf.contents()[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("header encoding failed")
  }
  let footer = Buffer()
  footer.write_uint16_be(1)
  let footerRecord = match
    @metadata.encodeMmmlRecord(
      @metadata.MmmlHeader::new(
        formatVersion=1,
        headerVersion=1,
        flags=0,
        recordType=@metadata.MmmlRecordType::SnapshotHint,
        leaderEpoch=1,
        mutationId=0,
      ),
      footer.contents()[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("footer encoding failed")
  }
  assert_eq(
    @metadata.decodeSnapshot(join([headerRecord, footerRecord])[:]) is Err(_),
    true,
  )
}

///|
async test "save publishes via part rename and keeps two generations" {
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  let dir = b"meta"
  let m = @metadata.DeclareMachine::new()
  assert_eq(
    @metadata.saveSnapshot(disk, dir, {
      machine: m,
      epoch: 1UL,
      endOffset: 10UL,
    }),
    Ok(()),
  )
  assert_eq(
    @metadata.saveSnapshot(disk, dir, {
      machine: m,
      epoch: 2UL,
      endOffset: 20UL,
    }),
    Ok(()),
  )
  assert_eq(
    @metadata.saveSnapshot(disk, dir, {
      machine: m,
      epoch: 3UL,
      endOffset: 30UL,
    }),
    Ok(()),
  )
  match @metadata.loadSnapshot(disk, dir, @metadata.SNAPSHOT_SLOT_A) {
    Ok(state) => assert_eq(state.endOffset, 30UL)
    Err(_) => fail("slot A did not load")
  }
  match @metadata.loadSnapshot(disk, dir, @metadata.SNAPSHOT_SLOT_B) {
    Ok(state) => assert_eq(state.endOffset, 20UL)
    Err(_) => fail("slot B did not load")
  }
  assert_eq(fake.snapshot().length(), 2)
}

///|
async test "a killed save leaves the previous generation intact" {
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  let dir = b"meta"
  let log = join([
    mutationRecord(1UL, 1UL, @metadata.DeclareBody::Create("orders", 3)),
  ])
  let machine = machineWith([(1UL, @metadata.DeclareBody::Create("orders", 3))])
  assert_eq(
    @metadata.saveSnapshot(disk, dir, {
      machine,
      epoch: 1UL,
      endOffset: log.length().to_uint64(),
    }),
    Ok(()),
  )
  fake.set_kill_at(1)
  assert_eq(
    @metadata.saveSnapshot(disk, dir, { machine, epoch: 2UL, endOffset: 99UL, }),
    Err(@metadata.DiskFault(@harness.Killed)),
  )
  match @metadata.recoverSnapshot(disk, dir, log) {
    Ok(state) => {
      assert_eq(state.endOffset, log.length().to_uint64())
      assert_eq(fingerprint(state.machine), fingerprint(machine))
    }
    Err(_) => fail("recovery after the killed save failed")
  }
}

///|
async test "recover falls back to the previous generation when the newest is corrupt" {
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  let dir = b"meta"
  let m1 = mutationRecord(1UL, 1UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutationRecord(
    2UL,
    1UL,
    @metadata.DeclareBody::Create("payments", 1),
  )
  let m3 = mutationRecord(3UL, 2UL, @metadata.DeclareBody::Delete("orders"))
  let m4 = mutationRecord(4UL, 2UL, @metadata.DeclareBody::Create("audit", 2))
  let log = join([m1, m2, m3, m4])
  let afterTwo = machineWith([
    (1UL, @metadata.DeclareBody::Create("orders", 3)),
    (2UL, @metadata.DeclareBody::Create("payments", 1)),
  ])
  let full = machineWith([
    (1UL, @metadata.DeclareBody::Create("orders", 3)),
    (2UL, @metadata.DeclareBody::Create("payments", 1)),
    (3UL, @metadata.DeclareBody::Delete("orders")),
    (4UL, @metadata.DeclareBody::Create("audit", 2)),
  ])
  assert_eq(
    @metadata.saveSnapshot(disk, dir, {
      machine: afterTwo,
      epoch: 1UL,
      endOffset: (m1.length() + m2.length()).to_uint64(),
    }),
    Ok(()),
  )
  assert_eq(
    @metadata.saveSnapshot(disk, dir, {
      machine: machineWith([
        (1UL, @metadata.DeclareBody::Create("orders", 3)),
        (2UL, @metadata.DeclareBody::Create("payments", 1)),
        (3UL, @metadata.DeclareBody::Delete("orders")),
      ]),
      epoch: 2UL,
      endOffset: (m1.length() + m2.length() + m3.length()).to_uint64(),
    }),
    Ok(()),
  )
  assert_eq(
    @harness.Disk::write(disk, b"meta/mmml-snapshot-b.checkpoint", b"garbage"),
    Ok(()),
  )
  match @metadata.recoverSnapshot(disk, dir, log) {
    Ok(state) => {
      assert_eq(state.endOffset, log.length().to_uint64())
      assert_eq(state.epoch, 2UL)
      assert_eq(fingerprint(state.machine), fingerprint(full))
    }
    Err(_) => fail("fallback recovery failed")
  }
  assert_eq(
    @harness.Disk::write(disk, b"meta/mmml-snapshot-a.checkpoint", b"garbage"),
    Ok(()),
  )
  match @metadata.recoverSnapshot(disk, dir, log) {
    Ok(state) => {
      assert_eq(state.endOffset, log.length().to_uint64())
      assert_eq(fingerprint(state.machine), fingerprint(full))
    }
    Err(_) => fail("full replay recovery failed")
  }
}

///|
async test "recover skips snapshot hints and other non-mutation records" {
  let m1 = mutationRecord(1UL, 5UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutationRecord(2UL, 7UL, @metadata.DeclareBody::Delete("orders"))
  let log = join([m1, hintRecord(6UL), m2])
  let machine = machineWith([
    (1UL, @metadata.DeclareBody::Create("orders", 3)),
    (2UL, @metadata.DeclareBody::Delete("orders")),
  ])
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  match @metadata.recoverSnapshot(disk, b"meta", log) {
    Ok(state) => {
      assert_eq(state.endOffset, log.length().to_uint64())
      assert_eq(state.epoch, 7UL)
      assert_eq(fingerprint(state.machine), fingerprint(machine))
    }
    Err(_) => fail("recovery over hinted log failed")
  }
}

///|
async test "recover reports the offset of a corrupt log record" {
  let m1 = mutationRecord(1UL, 1UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutationRecord(
    2UL,
    1UL,
    @metadata.DeclareBody::Create("payments", 1),
  )
  let m3 = mutationRecord(3UL, 1UL, @metadata.DeclareBody::Create("audit", 2))
  let log = join([m1, flipByte(m2, 20), m3])
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  match @metadata.recoverSnapshot(disk, b"meta", log) {
    Err(@metadata.Corruption(offset)) =>
      assert_eq(offset, m1.length().reinterpret_as_uint())
    _ => fail("expected a corruption abort")
  }
}

///|
async test "recovery degradation drives the gate without skipping damage" {
  let m1 = mutationRecord(1UL, 1UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutationRecord(
    2UL,
    1UL,
    @metadata.DeclareBody::Create("payments", 1),
  )
  let log = join([m1, flipByte(m2, 20)])
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  let gate = @metadata.MetadataGuard::new()
  match @metadata.recoverSnapshot(disk, b"meta", log) {
    Err(@metadata.Corruption(offset)) => {
      gate.noteLogCorruption(offset, m2.length().reinterpret_as_uint())
      assert_eq(offset, m1.length().reinterpret_as_uint())
    }
    _ => fail("expected a corruption abort")
  }
  assert_eq(gate.mode(), @metadata.MetadataMode::ReadOnly)
  assert_eq(gate.writeRefusalCode(), Some(@metadata.METADATA_READ_ONLY_CODE))
  gate.escalateToQuarantine()
  assert_eq(gate.writeRefusalCode(), Some(@metadata.METADATA_QUARANTINED_CODE))
}

///|
async test "a truncated log tail is corruption at the gap offset" {
  let m1 = mutationRecord(1UL, 1UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutationRecord(
    2UL,
    1UL,
    @metadata.DeclareBody::Create("payments", 1),
  )
  let log = join([m1, m2[:20].to_owned()])
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  match @metadata.recoverSnapshot(disk, b"meta", log) {
    Err(@metadata.Corruption(offset)) =>
      assert_eq(offset, m1.length().reinterpret_as_uint())
    _ => fail("expected a gap abort")
  }
}

///|
async test "a decreasing leader epoch is corruption at its record" {
  let m1 = mutationRecord(1UL, 7UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutationRecord(
    2UL,
    5UL,
    @metadata.DeclareBody::Create("payments", 1),
  )
  let log = join([m1, m2])
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  match @metadata.recoverSnapshot(disk, b"meta", log) {
    Err(@metadata.Corruption(offset)) =>
      assert_eq(offset, m1.length().reinterpret_as_uint())
    _ => fail("expected an epoch-chain abort")
  }
}

///|
async test "a snapshot past the log end falls back to full replay" {
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  let dir = b"meta"
  let log = join([
    mutationRecord(1UL, 1UL, @metadata.DeclareBody::Create("orders", 3)),
  ])
  let machine = machineWith([(1UL, @metadata.DeclareBody::Create("orders", 3))])
  assert_eq(
    @metadata.saveSnapshot(disk, dir, {
      machine,
      epoch: 1UL,
      endOffset: 9999UL,
    }),
    Ok(()),
  )
  match @metadata.recoverSnapshot(disk, dir, log) {
    Ok(state) => {
      assert_eq(state.endOffset, log.length().to_uint64())
      assert_eq(fingerprint(state.machine), fingerprint(machine))
    }
    Err(_) => fail("fallback over an over-reaching snapshot failed")
  }
}

///|
async test "concurrent serializations recover to one identical state" {
  let m1 = mutationRecord(1UL, 7UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutationRecord(2UL, 7UL, @metadata.DeclareBody::Create("orders", 3))
  let machine = machineWith([
    (1UL, @metadata.DeclareBody::Create("orders", 3)),
    (2UL, @metadata.DeclareBody::Create("orders", 3)),
  ])
  for log in [join([m1, m2]), join([m2, m1])] {
    let fake = @harness.FakeDisk::new()
    let disk : &@harness.Disk = fake
    match @metadata.recoverSnapshot(disk, b"meta", log) {
      Ok(state) => {
        assert_eq(state.endOffset, log.length().to_uint64())
        assert_eq(state.epoch, 7UL)
        assert_eq(fingerprint(state.machine), fingerprint(machine))
      }
      Err(_) => fail("concurrent serialization recovery failed")
    }
  }
}

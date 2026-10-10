/// Exercise metadata snapshot publication and recovery (T057).

///|
fn mutation_record(
  mutation_id : UInt64,
  epoch : UInt64,
  body : @metadata.DeclareBody,
) -> Bytes raise {
  match
    @metadata.encode_mmml_record(
      @metadata.MmmlHeader::new(
        format_version=1,
        header_version=1,
        flags=0,
        record_type=body.to_record_type(),
        leader_epoch=epoch,
        mutation_id~,
      ),
      body.to_payload()[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("mutation encoding failed")
  }
}

///|
fn hint_record(epoch : UInt64) -> Bytes raise {
  match
    @metadata.encode_mmml_record(
      @metadata.MmmlHeader::new(
        format_version=1,
        header_version=1,
        flags=0,
        record_type=@metadata.MmmlRecordType::SnapshotHint,
        leader_epoch=epoch,
        mutation_id=0,
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
fn machine_with(
  submits : Array[(UInt64, @metadata.DeclareBody)],
) -> @metadata.DeclareMachine {
  let machine = @metadata.DeclareMachine::new()
  for (mutation_id, body) in submits {
    ignore(machine.submit(mutation_id, 0UL, body))
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
    for (mutation_id, body) in table.to_array() {
      out.push(
        "a:" +
        key +
        ":" +
        mutation_id.to_string() +
        ":" +
        body.to_repr().to_string(),
      )
    }
  }
  out.sort()
  out
}

///|
fn encoded_snapshot(
  machine : @metadata.DeclareMachine,
  epoch : UInt64,
  end_offset : UInt64,
) -> Bytes raise {
  match @metadata.encode_snapshot({ machine, epoch, end_offset, }) {
    Ok(bytes) => bytes
    Err(_) => fail("snapshot encoding failed")
  }
}

///|
test "snapshot round-trips machine state and position" {
  let machine = machine_with([
    (1UL, @metadata.DeclareBody::Create("orders", 3)),
    (2UL, @metadata.DeclareBody::Delete("orders")),
    (3UL, @metadata.DeclareBody::Create("orders", 5)),
    (4UL, @metadata.DeclareBody::Create("payments", 1)),
  ])
  let bytes = encoded_snapshot(machine, 7UL, 4096UL)
  match @metadata.decode_snapshot(bytes[:]) {
    Ok(decoded) => {
      assert_eq(decoded.epoch, 7UL)
      assert_eq(decoded.end_offset, 4096UL)
      assert_eq(fingerprint(decoded.machine), fingerprint(machine))
    }
    Err(_) => fail("snapshot decoding failed")
  }
}

///|
test "snapshot rejects a flipped byte in any of its records" {
  let machine = machine_with([
    (1UL, @metadata.DeclareBody::Create("orders", 3)),
    (2UL, @metadata.DeclareBody::Create("payments", 1)),
  ])
  let bytes = encoded_snapshot(machine, 1UL, 64UL)
  assert_eq(@metadata.decode_snapshot(flip_byte(bytes, 30)[:]) is Err(_), true)
  assert_eq(@metadata.decode_snapshot(flip_byte(bytes, 60)[:]) is Err(_), true)
  assert_eq(
    @metadata.decode_snapshot(flip_byte(bytes, bytes.length() - 5)[:]) is Err(_),
    true,
  )
}

///|
test "snapshot refuses a file whose footer is missing" {
  let machine = machine_with([(1UL, @metadata.DeclareBody::Create("orders", 3))])
  let bytes = encoded_snapshot(machine, 1UL, 64UL)
  let footer_len = @metadata.MMML_HEADER_BYTES + 2
  assert_eq(
    @metadata.decode_snapshot(bytes[:bytes.length() - footer_len]) is Err(_),
    true,
  )
  assert_eq(@metadata.decode_snapshot(bytes[:35]) is Err(_), true)
}

///|
test "snapshot refuses a wrong format version" {
  let header = Buffer()
  header.write_uint16_be(2)
  header.write_uint64_be(0UL)
  let header_record = match
    @metadata.encode_mmml_record(
      @metadata.MmmlHeader::new(
        format_version=1,
        header_version=1,
        flags=0,
        record_type=@metadata.MmmlRecordType::SnapshotHint,
        leader_epoch=1,
        mutation_id=0,
      ),
      header.contents()[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("header encoding failed")
  }
  let footer = Buffer()
  footer.write_uint16_be(1)
  let footer_record = match
    @metadata.encode_mmml_record(
      @metadata.MmmlHeader::new(
        format_version=1,
        header_version=1,
        flags=0,
        record_type=@metadata.MmmlRecordType::SnapshotHint,
        leader_epoch=1,
        mutation_id=0,
      ),
      footer.contents()[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("footer encoding failed")
  }
  assert_eq(
    @metadata.decode_snapshot(join([header_record, footer_record])[:]) is Err(_),
    true,
  )
}

///|
test "snapshot refuses records carrying a mutation id" {
  let buf = Buffer()
  buf.write_uint16_be(1)
  buf.write_uint64_be(64UL)
  let header_record = match
    @metadata.encode_mmml_record(
      @metadata.MmmlHeader::new(
        format_version=1,
        header_version=1,
        flags=0,
        record_type=@metadata.MmmlRecordType::SnapshotHint,
        leader_epoch=1,
        mutation_id=1,
      ),
      buf.contents()[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("header encoding failed")
  }
  let footer = Buffer()
  footer.write_uint16_be(1)
  let footer_record = match
    @metadata.encode_mmml_record(
      @metadata.MmmlHeader::new(
        format_version=1,
        header_version=1,
        flags=0,
        record_type=@metadata.MmmlRecordType::SnapshotHint,
        leader_epoch=1,
        mutation_id=0,
      ),
      footer.contents()[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("footer encoding failed")
  }
  assert_eq(
    @metadata.decode_snapshot(join([header_record, footer_record])[:]) is Err(_),
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
    @metadata.save_snapshot(disk, dir, {
      machine: m,
      epoch: 1UL,
      end_offset: 10UL,
    }),
    Ok(()),
  )
  assert_eq(
    @metadata.save_snapshot(disk, dir, {
      machine: m,
      epoch: 2UL,
      end_offset: 20UL,
    }),
    Ok(()),
  )
  assert_eq(
    @metadata.save_snapshot(disk, dir, {
      machine: m,
      epoch: 3UL,
      end_offset: 30UL,
    }),
    Ok(()),
  )
  match @metadata.load_snapshot(disk, dir, @metadata.SNAPSHOT_SLOT_A) {
    Ok(state) => assert_eq(state.end_offset, 30UL)
    Err(_) => fail("slot A did not load")
  }
  match @metadata.load_snapshot(disk, dir, @metadata.SNAPSHOT_SLOT_B) {
    Ok(state) => assert_eq(state.end_offset, 20UL)
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
    mutation_record(1UL, 1UL, @metadata.DeclareBody::Create("orders", 3)),
  ])
  let machine = machine_with([(1UL, @metadata.DeclareBody::Create("orders", 3))])
  assert_eq(
    @metadata.save_snapshot(disk, dir, {
      machine,
      epoch: 1UL,
      end_offset: log.length().to_uint64(),
    }),
    Ok(()),
  )
  fake.set_kill_at(1)
  assert_eq(
    @metadata.save_snapshot(disk, dir, {
      machine,
      epoch: 2UL,
      end_offset: 99UL,
    }),
    Err(@metadata.DiskFault(@harness.Killed)),
  )
  match @metadata.recover_snapshot(disk, dir, log) {
    Ok(state) => {
      assert_eq(state.end_offset, log.length().to_uint64())
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
  let m1 = mutation_record(1UL, 1UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutation_record(
    2UL,
    1UL,
    @metadata.DeclareBody::Create("payments", 1),
  )
  let m3 = mutation_record(3UL, 2UL, @metadata.DeclareBody::Delete("orders"))
  let m4 = mutation_record(4UL, 2UL, @metadata.DeclareBody::Create("audit", 2))
  let log = join([m1, m2, m3, m4])
  let after_two = machine_with([
    (1UL, @metadata.DeclareBody::Create("orders", 3)),
    (2UL, @metadata.DeclareBody::Create("payments", 1)),
  ])
  let full = machine_with([
    (1UL, @metadata.DeclareBody::Create("orders", 3)),
    (2UL, @metadata.DeclareBody::Create("payments", 1)),
    (3UL, @metadata.DeclareBody::Delete("orders")),
    (4UL, @metadata.DeclareBody::Create("audit", 2)),
  ])
  assert_eq(
    @metadata.save_snapshot(disk, dir, {
      machine: after_two,
      epoch: 1UL,
      end_offset: (m1.length() + m2.length()).to_uint64(),
    }),
    Ok(()),
  )
  assert_eq(
    @metadata.save_snapshot(disk, dir, {
      machine: machine_with([
        (1UL, @metadata.DeclareBody::Create("orders", 3)),
        (2UL, @metadata.DeclareBody::Create("payments", 1)),
        (3UL, @metadata.DeclareBody::Delete("orders")),
      ]),
      epoch: 2UL,
      end_offset: (m1.length() + m2.length() + m3.length()).to_uint64(),
    }),
    Ok(()),
  )
  assert_eq(
    @harness.Disk::write(disk, b"meta/mmml-snapshot-b.checkpoint", b"garbage"),
    Ok(()),
  )
  match @metadata.recover_snapshot(disk, dir, log) {
    Ok(state) => {
      assert_eq(state.end_offset, log.length().to_uint64())
      assert_eq(state.epoch, 2UL)
      assert_eq(fingerprint(state.machine), fingerprint(full))
    }
    Err(_) => fail("fallback recovery failed")
  }
  assert_eq(
    @harness.Disk::write(disk, b"meta/mmml-snapshot-a.checkpoint", b"garbage"),
    Ok(()),
  )
  match @metadata.recover_snapshot(disk, dir, log) {
    Ok(state) => {
      assert_eq(state.end_offset, log.length().to_uint64())
      assert_eq(fingerprint(state.machine), fingerprint(full))
    }
    Err(_) => fail("full replay recovery failed")
  }
}

///|
async test "recover skips snapshot hints and other non-mutation records" {
  let m1 = mutation_record(1UL, 5UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutation_record(2UL, 7UL, @metadata.DeclareBody::Delete("orders"))
  let log = join([m1, hint_record(6UL), m2])
  let machine = machine_with([
    (1UL, @metadata.DeclareBody::Create("orders", 3)),
    (2UL, @metadata.DeclareBody::Delete("orders")),
  ])
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  match @metadata.recover_snapshot(disk, b"meta", log) {
    Ok(state) => {
      assert_eq(state.end_offset, log.length().to_uint64())
      assert_eq(state.epoch, 7UL)
      assert_eq(fingerprint(state.machine), fingerprint(machine))
    }
    Err(_) => fail("recovery over hinted log failed")
  }
}

///|
async test "recover reports the offset of a corrupt log record" {
  let m1 = mutation_record(1UL, 1UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutation_record(
    2UL,
    1UL,
    @metadata.DeclareBody::Create("payments", 1),
  )
  let m3 = mutation_record(3UL, 1UL, @metadata.DeclareBody::Create("audit", 2))
  let log = join([m1, flip_byte(m2, 20), m3])
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  match @metadata.recover_snapshot(disk, b"meta", log) {
    Err(@metadata.Corruption(offset)) =>
      assert_eq(offset, m1.length().reinterpret_as_uint())
    _ => fail("expected a corruption abort")
  }
}

///|
async test "recovery degradation drives the gate without skipping damage" {
  let m1 = mutation_record(1UL, 1UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutation_record(
    2UL,
    1UL,
    @metadata.DeclareBody::Create("payments", 1),
  )
  let log = join([m1, flip_byte(m2, 20)])
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  let gate = @metadata.MetadataGuard::new()
  match @metadata.recover_snapshot(disk, b"meta", log) {
    Err(@metadata.Corruption(offset)) => {
      gate.note_log_corruption(offset, m2.length().reinterpret_as_uint())
      assert_eq(offset, m1.length().reinterpret_as_uint())
    }
    _ => fail("expected a corruption abort")
  }
  assert_eq(gate.mode(), @metadata.MetadataMode::ReadOnly)
  assert_eq(gate.write_refusal_code(), Some(@metadata.METADATA_READ_ONLY_CODE))
  gate.escalate_to_quarantine()
  assert_eq(
    gate.write_refusal_code(),
    Some(@metadata.METADATA_QUARANTINED_CODE),
  )
}

///|
async test "a torn log tail is discarded as an unfinished append" {
  let m1 = mutation_record(1UL, 1UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutation_record(
    2UL,
    1UL,
    @metadata.DeclareBody::Create("payments", 1),
  )
  let log = join([m1, m2[:20].to_owned()])
  let machine = machine_with([(1UL, @metadata.DeclareBody::Create("orders", 3))])
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  match @metadata.recover_snapshot(disk, b"meta", log) {
    Ok(state) => {
      assert_eq(state.end_offset, m1.length().to_uint64())
      assert_eq(fingerprint(state.machine), fingerprint(machine))
    }
    Err(_) => fail("expected prefix recovery over a torn tail")
  }
}

///|
async test "a decreasing leader epoch is corruption at its record" {
  let m1 = mutation_record(1UL, 7UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutation_record(
    2UL,
    5UL,
    @metadata.DeclareBody::Create("payments", 1),
  )
  let log = join([m1, m2])
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  match @metadata.recover_snapshot(disk, b"meta", log) {
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
    mutation_record(1UL, 1UL, @metadata.DeclareBody::Create("orders", 3)),
  ])
  let machine = machine_with([(1UL, @metadata.DeclareBody::Create("orders", 3))])
  assert_eq(
    @metadata.save_snapshot(disk, dir, {
      machine,
      epoch: 1UL,
      end_offset: 9999UL,
    }),
    Ok(()),
  )
  match @metadata.recover_snapshot(disk, dir, log) {
    Ok(state) => {
      assert_eq(state.end_offset, log.length().to_uint64())
      assert_eq(fingerprint(state.machine), fingerprint(machine))
    }
    Err(_) => fail("fallback over an over-reaching snapshot failed")
  }
}

///|
async test "concurrent serializations recover to one identical state" {
  let m1 = mutation_record(1UL, 7UL, @metadata.DeclareBody::Create("orders", 3))
  let m2 = mutation_record(2UL, 7UL, @metadata.DeclareBody::Create("orders", 3))
  let machine = machine_with([
    (1UL, @metadata.DeclareBody::Create("orders", 3)),
    (2UL, @metadata.DeclareBody::Create("orders", 3)),
  ])
  for log in [join([m1, m2]), join([m2, m1])] {
    let fake = @harness.FakeDisk::new()
    let disk : &@harness.Disk = fake
    match @metadata.recover_snapshot(disk, b"meta", log) {
      Ok(state) => {
        assert_eq(state.end_offset, log.length().to_uint64())
        assert_eq(state.epoch, 7UL)
        assert_eq(fingerprint(state.machine), fingerprint(machine))
      }
      Err(_) => fail("concurrent serialization recovery failed")
    }
  }
}

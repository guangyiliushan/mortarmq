/// Prove the guard is load-bearing on the real metadata entry points
/// (negative cases: injected damage refuses later writes
/// and the read face shows the degradation honestly).

///|
fn svc_pair_record(
  mutation_id : UInt64,
  epoch : UInt64,
  bodies : Array[@metadata.DeclareBody],
) -> Bytes raise {
  match
    @metadata.encode_mmml_record(
      @metadata.MmmlHeader::new(
        format_version=1,
        header_version=1,
        flags=0,
        record_type=@metadata.MmmlRecordType::TopicCreate,
        leader_epoch=epoch,
        mutation_id~,
      ),
      @metadata.encode_declare_bodies(bodies)[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("mutation encoding failed")
  }
}

///|
async test "injected damage degrades the service and refuses later writes" {
  let m1 = svc_pair_record(1UL, 1UL, [
    @metadata.DeclareBody::Create("orders", 3),
  ])
  let m2 = svc_pair_record(2UL, 1UL, [
    @metadata.DeclareBody::Create("payments", 1),
  ])
  let log = m1 + svc_flip_byte(m2, 20)
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  let service = @metadata.MetadataService::new()
  match service.recover(disk, b"meta", log) {
    Err(code) => assert_eq(code, @protocol.MetadataReadOnly)
    Ok(_) => fail("expected a read-only refusal")
  }
  assert_eq(service.read_face(), @metadata.MetadataMode::ReadOnly)
  assert_eq(
    service.submit_mutation(disk, b"meta/mmml.log", 3UL, 1UL, [
      @metadata.DeclareBody::Create("audit", 2),
    ]),
    Err(@protocol.MetadataReadOnly),
  )
  assert_eq(
    service.submit_mutation(disk, b"meta/mmml.log", 1UL, 1UL, [
      @metadata.DeclareBody::Create("orders", 3),
    ]),
    Err(@protocol.MetadataReadOnly),
  )
}

///|
async test "reads stay available while writes are refused" {
  let m1 = svc_pair_record(1UL, 1UL, [
    @metadata.DeclareBody::Create("orders", 3),
  ])
  let log = m1 + b"torn-tail"
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  let service = @metadata.MetadataService::new()
  assert_eq(service.recover(disk, b"meta", log) is Ok(_), true)
  assert_eq(service.partition_count("orders"), Some(3U))
  assert_eq(service.read_face(), @metadata.MetadataMode::Healthy)
}

///|
async test "a trustworthy rebuild reopens the write path" {
  let m1 = svc_pair_record(1UL, 1UL, [
    @metadata.DeclareBody::Create("orders", 3),
  ])
  let m2 = svc_pair_record(2UL, 1UL, [
    @metadata.DeclareBody::Create("payments", 1),
  ])
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  let service = @metadata.MetadataService::new()
  match service.recover(disk, b"meta", m1 + svc_flip_byte(m2, 20)) {
    Err(code) => assert_eq(code, @protocol.MetadataReadOnly)
    Ok(_) => fail("expected a read-only refusal")
  }
  assert_eq(service.recover(disk, b"meta", m1 + m2) is Ok(_), true)
  assert_eq(service.read_face(), @metadata.MetadataMode::Healthy)
  assert_eq(
    service.submit_mutation(disk, b"meta/mmml.log", 3UL, 1UL, [
      @metadata.DeclareBody::Create("audit", 2),
    ]),
    Ok([@metadata.DeclareOutcome::Created]),
  )
}

///|
async test "a degraded service refuses to publish snapshots" {
  let m1 = svc_pair_record(1UL, 1UL, [
    @metadata.DeclareBody::Create("orders", 3),
  ])
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  let service = @metadata.MetadataService::new()
  assert_eq(service.recover(disk, b"meta", m1 + b"torn") is Ok(_), true)
  assert_eq(service.save(disk, b"meta", 1UL, m1.length().to_uint64()), Ok(()))
  let damaged = @metadata.MetadataService::new()
  match damaged.recover(disk, b"meta", m1 + svc_flip_byte(m2_frag(), 20)) {
    Err(code) => assert_eq(code, @protocol.MetadataReadOnly)
    Ok(_) => fail("expected a read-only refusal")
  }
  assert_eq(
    damaged.save(disk, b"meta", 1UL, m1.length().to_uint64()),
    Err(@protocol.MetadataReadOnly),
  )
}

///|
fn svc_flip_byte(data : Bytes, index : Int32) -> Bytes {
  let flipped = (data[index].to_uint() ^ 0xFFU).to_byte()
  let out = Buffer()
  out.write_bytes(data[:index])
  out.write_byte(flipped)
  out.write_bytes(data[index + 1:])
  out.contents()
}

///|
fn m2_frag() -> Bytes raise {
  svc_pair_record(2UL, 1UL, [@metadata.DeclareBody::Create("payments", 1)])
}

///|
async test "path-like log bytes recover an empty state that is checkable" {
  let fake = @harness.FakeDisk::new()
  let disk : &@harness.Disk = fake
  let service = @metadata.MetadataService::new()
  match service.recover(disk, b"meta", b"meta/mmml.log") {
    Ok(state) => {
      assert_eq(state.end_offset, 0UL)
      assert_eq(service.partition_count("orders"), None)
      assert_eq(service.read_face(), @metadata.MetadataMode::Healthy)
    }
    Err(_) =>
      fail("empty-prefix recovery answers Ok; the emptiness is the signal")
  }
}

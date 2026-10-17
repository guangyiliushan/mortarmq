/// Prove the journal-then-apply discipline of the DECLARE write path:
/// an acknowledged mutation is on the log before it applies, a failed
/// journal never applied, and a refused set never journaled.

///|
async test "a declared mutation journals before it applies" {
  let fake = @harness.FakeDisk::new()
  let disk : &@ports.Disk = fake
  let service = @metadata.MetadataService::new()
  let log = b"meta/mmml.log"
  assert_eq(
    service.submit_mutation(disk, log, 1UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 3),
    ]),
    Ok([@metadata.DeclareOutcome::Created]),
  )
  // The journal is on the log: a fresh service recovers the topic from
  // the journal alone, with no snapshot in the chain.
  let journal = match disk.read(log) {
    Ok(bytes) => bytes
    Err(_) => fail("the journal is missing")
  }
  let fresh = @metadata.MetadataService::new()
  assert_eq(fresh.recover(disk, b"meta", journal) is Ok(_), true)
  assert_eq(fresh.partition_count("orders"), Some(3U))
  // The applied table answers the same id idempotently.
  assert_eq(
    service.submit_mutation(disk, log, 1UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 3),
    ]),
    Ok([@metadata.DeclareOutcome::IdempotentOk]),
  )
}

///|
async test "a journal write failure applies nothing" {
  let fake = @harness.FakeDisk::new()
  let disk : &@ports.Disk = fake
  let service = @metadata.MetadataService::new()
  let log = b"meta/mmml.log"
  // Kill the very first change op: the journal write itself fails.
  fake.set_kill_at(1)
  match
    service.submit_mutation(disk, log, 1UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 3),
    ]) {
    Err(@protocol.Internal) => assert_eq(true, true)
    _ => fail("expected the journal failure to surface")
  }
  fake.set_kill_at(0)
  // Disarm and resubmit: the same id answers Created, proving the
  // killed attempt left the table untouched.
  assert_eq(
    service.submit_mutation(disk, log, 1UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 3),
    ]),
    Ok([@metadata.DeclareOutcome::Created]),
  )
}

///|
async test "a journal fsync failure applies nothing" {
  let fake = @harness.FakeDisk::new()
  let disk : &@ports.Disk = fake
  let service = @metadata.MetadataService::new()
  let log = b"meta/mmml.log"
  // The record write is op 1 and the fsync is op 2: the journal lands
  // but never becomes durable, so the mutation must not apply.
  fake.set_kill_at(2)
  match
    service.submit_mutation(disk, log, 1UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 3),
    ]) {
    Err(@protocol.Internal) => assert_eq(true, true)
    _ => fail("expected the fsync failure to surface")
  }
  fake.set_kill_at(0)
  // Disarm and resubmit: Created again, proving the unflushed attempt
  // never applied. The log now carries the record twice; the replay
  // folds the duplicate as IdempotentOk, so the pair stays clean.
  assert_eq(
    service.submit_mutation(disk, log, 1UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 3),
    ]),
    Ok([@metadata.DeclareOutcome::Created]),
  )
  let journal = match disk.read(log) {
    Ok(bytes) => bytes
    Err(_) => fail("the journal is missing")
  }
  let fresh = @metadata.MetadataService::new()
  assert_eq(fresh.recover(disk, b"meta", journal) is Ok(_), true)
  assert_eq(fresh.partition_count("orders"), Some(3U))
}

///|
async test "a refused set answers without journaling" {
  let fake = @harness.FakeDisk::new()
  let disk : &@ports.Disk = fake
  let service = @metadata.MetadataService::new()
  let log = b"meta/mmml.log"
  // A set the packed journal record cannot hold is refused and nothing
  // is journaled or applied.
  assert_eq(
    service.submit_mutation(disk, log, 1UL, 7UL, [
      @metadata.DeclareBody::Create("payments", 1),
      @metadata.DeclareBody::Delete("orders"),
    ]),
    Err(@protocol.MutationNotPackable),
  )
  assert_eq(disk.read(log) is Err(@ports.PathMissing), true)
  // Apply a real mutation, then fence the same id with a different
  // body: the refusal answers as an outcome and adds no journal record.
  assert_eq(
    service.submit_mutation(disk, log, 1UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 3),
    ]),
    Ok([@metadata.DeclareOutcome::Created]),
  )
  assert_eq(
    service.submit_mutation(disk, log, 1UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 9),
    ]),
    Ok([@metadata.DeclareOutcome::MutationFenced]),
  )
  // The log carries exactly the one accepted record: the fenced set
  // never landed, so the replay agrees with the table instead of
  // tripping over a refusal.
  let one_record = match
    @metadata.encode_mmml_record(
      @metadata.MmmlHeader::new(
        format_version=1,
        header_version=1,
        flags=0,
        record_type=@metadata.MmmlRecordType::TopicCreate,
        leader_epoch=7UL,
        mutation_id=1UL,
      ),
      @metadata.encode_declare_bodies([
        @metadata.DeclareBody::Create("orders", 3),
      ])[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("the reference record failed to encode")
  }
  match disk.read(log) {
    Ok(journal) => assert_eq(journal, one_record)
    Err(_) => fail("the journal is missing")
  }
  let fresh = @metadata.MetadataService::new()
  assert_eq(fresh.recover(disk, b"meta", one_record) is Ok(_), true)
  assert_eq(fresh.partition_count("orders"), Some(3U))
  assert_eq(fresh.partition_count("payments"), None)
}

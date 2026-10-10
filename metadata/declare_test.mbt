/// Exercise the idempotent DECLARE state machine (REQ-STO-007, R5):
/// per-key accepted-mutation table, rejected mutations never recorded.

///|
test "declare applies a topic create exactly once" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(1UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(machine.partition_count("orders"), Some(3U))
}

///|
test "declare replays the same mutation_id as idempotent" {
  let machine = @metadata.DeclareMachine::new()
  let body = @metadata.DeclareBody::Create("orders", 3)
  assert_eq(machine.submit(1UL, body), @metadata.DeclareOutcome::Created)
  assert_eq(machine.submit(1UL, body), @metadata.DeclareOutcome::IdempotentOk)
  assert_eq(machine.partition_count("orders"), Some(3U))
}

///|
test "declare collapses same-name submissions as idempotent" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(1UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(
    machine.submit(2UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::IdempotentOk,
  )
  assert_eq(machine.partition_count("orders"), Some(3U))
}

///|
test "declare fences a mutation_id reused with a different body" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(1UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(
    machine.submit(1UL, @metadata.DeclareBody::Create("orders", 9)),
    @metadata.DeclareOutcome::MutationFenced,
  )
  assert_eq(
    machine.submit(1UL, @metadata.DeclareBody::Delete("orders")),
    @metadata.DeclareOutcome::MutationFenced,
  )
  assert_eq(machine.partition_count("orders"), Some(3U))
}

///|
test "declare rejects a mismatched count without recording the mutation" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(1UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(
    machine.submit(2UL, @metadata.DeclareBody::Create("orders", 9)),
    @metadata.DeclareOutcome::NameCountMismatch,
  )
  assert_eq(
    machine.submit(2UL, @metadata.DeclareBody::Create("orders", 9)),
    @metadata.DeclareOutcome::NameCountMismatch,
  )
  assert_eq(machine.partition_count("orders"), Some(3U))
}

///|
test "declare fences a reused mutation_id before any count check" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(1UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(
    machine.submit(1UL, @metadata.DeclareBody::Create("orders", 33)),
    @metadata.DeclareOutcome::MutationFenced,
  )
}

///|
test "declare delete keeps accepted history so replays never resurrect" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(1UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(
    machine.submit(3UL, @metadata.DeclareBody::Delete("orders")),
    @metadata.DeclareOutcome::Deleted,
  )
  assert_eq(machine.partition_count("orders"), None)
  assert_eq(
    machine.submit(1UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::IdempotentOk,
  )
  assert_eq(machine.partition_count("orders"), None)
  assert_eq(
    machine.submit(4UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(machine.partition_count("orders"), Some(3U))
}

///|
test "declare delete replays and collapses idempotently" {
  let machine = @metadata.DeclareMachine::new()
  let body = @metadata.DeclareBody::Delete("ghost")
  assert_eq(machine.submit(3UL, body), @metadata.DeclareOutcome::IdempotentOk)
  assert_eq(machine.submit(3UL, body), @metadata.DeclareOutcome::IdempotentOk)
  assert_eq(
    machine.submit(5UL, @metadata.DeclareBody::Delete("ghost")),
    @metadata.DeclareOutcome::IdempotentOk,
  )
}

///|
test "declare payload round-trips create and delete bodies" {
  let bodies = [
    @metadata.DeclareBody::Create("orders", 3),
    @metadata.DeclareBody::Delete("orders"),
  ]
  for body in bodies {
    match
      @metadata.decode_declare_body(body.to_record_type(), body.to_payload()[:]) {
      Some(decoded) => assert_eq(decoded, body)
      None => fail("payload round-trip failed")
    }
  }
}

///|
test "declare payload rejects truncated and foreign bytes" {
  let body = @metadata.DeclareBody::Create("orders", 3)
  let payload = body.to_payload()
  assert_eq(
    @metadata.decode_declare_body(
      @metadata.MmmlRecordType::TopicCreate,
      payload[:payload.length() - 1],
    ),
    None,
  )
  assert_eq(
    @metadata.decode_declare_body(
      @metadata.MmmlRecordType::ConfigUpdate,
      payload[:],
    ),
    None,
  )
  assert_eq(
    @metadata.decode_declare_body(
      @metadata.MmmlRecordType::TopicCreate,
      b"zz"[:],
    ),
    None,
  )
}

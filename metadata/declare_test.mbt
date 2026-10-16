/// Exercise the idempotent DECLARE state machine:
/// per-key accepted-mutation table, rejected mutations never recorded.

///|
test "declare applies a topic create exactly once" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(1UL, 0UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(machine.partition_count("orders"), Some(3U))
}

///|
test "declare replays the same mutation_id as idempotent" {
  let machine = @metadata.DeclareMachine::new()
  let body = @metadata.DeclareBody::Create("orders", 3)
  assert_eq(machine.submit(1UL, 0UL, body), @metadata.DeclareOutcome::Created)
  assert_eq(
    machine.submit(1UL, 0UL, body),
    @metadata.DeclareOutcome::IdempotentOk,
  )
  assert_eq(machine.partition_count("orders"), Some(3U))
}

///|
test "declare collapses same-name submissions as idempotent" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(1UL, 0UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(
    machine.submit(2UL, 0UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::IdempotentOk,
  )
  assert_eq(machine.partition_count("orders"), Some(3U))
}

///|
test "declare fences a mutation_id reused with a different body" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(1UL, 0UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(
    machine.submit(1UL, 0UL, @metadata.DeclareBody::Create("orders", 9)),
    @metadata.DeclareOutcome::MutationFenced,
  )
  assert_eq(
    machine.submit(1UL, 0UL, @metadata.DeclareBody::Delete("orders")),
    @metadata.DeclareOutcome::MutationFenced,
  )
  assert_eq(machine.partition_count("orders"), Some(3U))
}

///|
test "declare rejects a mismatched count without recording the mutation" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(1UL, 0UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(
    machine.submit(2UL, 0UL, @metadata.DeclareBody::Create("orders", 9)),
    @metadata.DeclareOutcome::NameCountMismatch,
  )
  assert_eq(
    machine.submit(2UL, 0UL, @metadata.DeclareBody::Create("orders", 9)),
    @metadata.DeclareOutcome::NameCountMismatch,
  )
  assert_eq(machine.partition_count("orders"), Some(3U))
}

///|
test "declare fences a reused mutation_id before any count check" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(1UL, 0UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(
    machine.submit(1UL, 0UL, @metadata.DeclareBody::Create("orders", 33)),
    @metadata.DeclareOutcome::MutationFenced,
  )
}

///|
test "declare delete keeps accepted history so replays never resurrect" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(1UL, 0UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(
    machine.submit(3UL, 0UL, @metadata.DeclareBody::Delete("orders")),
    @metadata.DeclareOutcome::Deleted,
  )
  assert_eq(machine.partition_count("orders"), None)
  assert_eq(
    machine.submit(1UL, 0UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::IdempotentOk,
  )
  assert_eq(machine.partition_count("orders"), None)
  assert_eq(
    machine.submit(4UL, 0UL, @metadata.DeclareBody::Create("orders", 3)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(machine.partition_count("orders"), Some(3U))
}

///|
test "declare delete replays and collapses idempotently" {
  let machine = @metadata.DeclareMachine::new()
  let body = @metadata.DeclareBody::Delete("ghost")
  assert_eq(
    machine.submit(3UL, 0UL, body),
    @metadata.DeclareOutcome::IdempotentOk,
  )
  assert_eq(
    machine.submit(3UL, 0UL, body),
    @metadata.DeclareOutcome::IdempotentOk,
  )
  assert_eq(
    machine.submit(5UL, 0UL, @metadata.DeclareBody::Delete("ghost")),
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

///|
fn run_order(
  order : Array[(UInt64, @metadata.DeclareBody)],
) -> Array[@metadata.DeclareOutcome] {
  let machine = @metadata.DeclareMachine::new()
  let out : Array[@metadata.DeclareOutcome] = []
  for (mutation_id, body) in order {
    out.push(machine.submit(mutation_id, 7UL, body))
  }
  out
}

///|
fn count_created(outcomes : Array[@metadata.DeclareOutcome]) -> Int32 {
  let mut n = 0
  for outcome in outcomes {
    match outcome {
      @metadata.DeclareOutcome::Created => n = n + 1
      _ => ()
    }
  }
  n
}

///|
fn count_idempotent(outcomes : Array[@metadata.DeclareOutcome]) -> Int32 {
  let mut n = 0
  for outcome in outcomes {
    match outcome {
      @metadata.DeclareOutcome::IdempotentOk => n = n + 1
      _ => ()
    }
  }
  n
}

///|
test "concurrent identical declares are exactly once in every order" {
  let a = (1UL, @metadata.DeclareBody::Create("orders", 3))
  let b = (2UL, @metadata.DeclareBody::Create("orders", 3))
  let c = (3UL, @metadata.DeclareBody::Create("orders", 3))
  let orders = [
    [a, b],
    [b, a],
    [a, b, c],
    [a, c, b],
    [b, a, c],
    [b, c, a],
    [c, a, b],
    [c, b, a],
  ]
  for order in orders {
    let outcomes = run_order(order)
    assert_eq(count_created(outcomes), 1)
    assert_eq(count_idempotent(outcomes), order.length() - 1)
  }
}

///|
test "concurrent distinct declares create each topic exactly once" {
  let a = (1UL, @metadata.DeclareBody::Create("orders", 3))
  let b = (2UL, @metadata.DeclareBody::Create("payments", 1))
  for order in [[a, b], [b, a]] {
    let outcomes = run_order(order)
    assert_eq(count_created(outcomes), 2)
    assert_eq(count_idempotent(outcomes), 0)
  }
}

///|
test "stale leader epoch mutations are fenced but replay is unconditional" {
  let machine = @metadata.DeclareMachine::new()
  let body = @metadata.DeclareBody::Create("orders", 3)
  assert_eq(machine.submit(1UL, 7UL, body), @metadata.DeclareOutcome::Created)
  assert_eq(machine.leader_epoch(), 7UL)
  assert_eq(
    machine.submit(2UL, 5UL, body),
    @metadata.DeclareOutcome::MutationFenced,
  )
  assert_eq(
    machine.submit(1UL, 5UL, body),
    @metadata.DeclareOutcome::IdempotentOk,
  )
  assert_eq(machine.leader_epoch(), 7UL)
  assert_eq(
    machine.submit(3UL, 9UL, @metadata.DeclareBody::Create("payments", 1)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(machine.leader_epoch(), 9UL)
  assert_eq(
    machine.submit(4UL, 9UL, @metadata.DeclareBody::Create("audit", 2)),
    @metadata.DeclareOutcome::Created,
  )
}

///|
test "a fenced mutation leaves no trace in the accepted table" {
  let machine = @metadata.DeclareMachine::new()
  let body = @metadata.DeclareBody::Create("orders", 3)
  assert_eq(machine.submit(1UL, 7UL, body), @metadata.DeclareOutcome::Created)
  assert_eq(
    machine.submit(2UL, 5UL, body),
    @metadata.DeclareOutcome::MutationFenced,
  )
  assert_eq(
    machine.submit(2UL, 9UL, body),
    @metadata.DeclareOutcome::IdempotentOk,
  )
}

///|
test "a packed pair applies as one mutation" {
  let machine = @metadata.DeclareMachine::new()
  let outcomes = machine.submit_set(1UL, 7UL, [
    @metadata.DeclareBody::Create("orders", 3),
    @metadata.DeclareBody::Create("orders.dlq", 3),
  ])
  assert_eq(outcomes, [
    @metadata.DeclareOutcome::Created,
    @metadata.DeclareOutcome::Created,
  ])
  assert_eq(machine.partition_count("orders"), Some(3U))
  assert_eq(machine.partition_count("orders.dlq"), Some(3U))
}

///|
test "packed pair replay returns double idempotent ok" {
  let machine = @metadata.DeclareMachine::new()
  let ops = [
    @metadata.DeclareBody::Create("orders", 3),
    @metadata.DeclareBody::Create("orders.dlq", 3),
  ]
  ignore(machine.submit_set(1UL, 7UL, ops))
  assert_eq(machine.submit_set(1UL, 3UL, ops), [
    @metadata.DeclareOutcome::IdempotentOk,
    @metadata.DeclareOutcome::IdempotentOk,
  ])
  assert_eq(machine.partition_count("orders"), Some(3U))
  assert_eq(machine.partition_count("orders.dlq"), Some(3U))
  assert_eq(machine.leader_epoch(), 7UL)
}

///|
test "op-set fence rejects narrower wider and different sets" {
  let machine = @metadata.DeclareMachine::new()
  ignore(
    machine.submit_set(1UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 3),
      @metadata.DeclareBody::Create("orders.dlq", 3),
    ]),
  )
  assert_eq(
    machine.submit_set(1UL, 9UL, [@metadata.DeclareBody::Create("orders", 3)]),
    [@metadata.DeclareOutcome::MutationFenced],
  )
  assert_eq(
    machine.submit_set(1UL, 9UL, [
      @metadata.DeclareBody::Create("orders", 3),
      @metadata.DeclareBody::Create("orders.dlq", 5),
    ]),
    [
      @metadata.DeclareOutcome::MutationFenced,
      @metadata.DeclareOutcome::MutationFenced,
    ],
  )
  assert_eq(
    machine.submit_set(1UL, 9UL, [
      @metadata.DeclareBody::Create("orders", 3),
      @metadata.DeclareBody::Create("other", 1),
    ]),
    [
      @metadata.DeclareOutcome::MutationFenced,
      @metadata.DeclareOutcome::MutationFenced,
    ],
  )
  assert_eq(machine.partition_count("orders.dlq"), Some(3U))
}

///|
test "packed pair rejects a mismatched name atomically" {
  let machine = @metadata.DeclareMachine::new()
  ignore(machine.submit(1UL, 7UL, @metadata.DeclareBody::Create("orders", 3)))
  let ops = [
    @metadata.DeclareBody::Create("fresh", 1),
    @metadata.DeclareBody::Create("orders", 9),
  ]
  assert_eq(machine.submit_set(2UL, 7UL, ops), [
    @metadata.DeclareOutcome::NameCountMismatch,
    @metadata.DeclareOutcome::NameCountMismatch,
  ])
  assert_eq(machine.partition_count("fresh"), None)
  assert_eq(machine.submit_set(2UL, 7UL, ops), [
    @metadata.DeclareOutcome::NameCountMismatch,
    @metadata.DeclareOutcome::NameCountMismatch,
  ])
}

///|
test "per-key id independence spans packed and single mutations" {
  let machine = @metadata.DeclareMachine::new()
  assert_eq(
    machine.submit(5UL, 7UL, @metadata.DeclareBody::Create("a", 1)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(
    machine.submit(5UL, 7UL, @metadata.DeclareBody::Create("b", 1)),
    @metadata.DeclareOutcome::Created,
  )
  assert_eq(
    machine.submit(5UL, 7UL, @metadata.DeclareBody::Create("a", 1)),
    @metadata.DeclareOutcome::IdempotentOk,
  )
}

///|
test "declare payload keeps the single form and adds the packed form" {
  let source = @metadata.DeclareBody::Create("orders", 3)
  let twin = @metadata.DeclareBody::Create("orders.dlq", 3)
  let expected_single = Buffer()
  expected_single.write_uint16_be(6)
  expected_single.write_bytes(b"orders")
  expected_single.write_uint_be(3)
  assert_eq(source.to_payload(), expected_single.contents())
  assert_eq(
    @metadata.encode_declare_bodies([source]),
    expected_single.contents(),
  )
  let expected_pair = expected_single.contents() + twin.to_payload()
  assert_eq(@metadata.encode_declare_bodies([source, twin]), expected_pair)
  assert_eq(
    @metadata.decode_declare_bodies(
      @metadata.MmmlRecordType::TopicCreate,
      expected_pair[:],
    ),
    Some([source, twin]),
  )
  let three = @metadata.encode_declare_bodies([source, twin, source])
  assert_eq(
    @metadata.decode_declare_bodies(
      @metadata.MmmlRecordType::TopicCreate,
      three[:],
    ),
    None,
  )
  assert_eq(
    @metadata.decode_declare_bodies(
      @metadata.MmmlRecordType::TopicCreate,
      b""[:],
    ),
    None,
  )
}

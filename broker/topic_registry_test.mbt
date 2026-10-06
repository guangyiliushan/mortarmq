/// Exercise the in-memory topic registry behind DECLARE: idempotent
/// replay, mismatch refusal, identifier assignment and its exhaustion at
/// the maximum, and the refusal paths that create nothing.

///|
fn indexed_topic(index : Int) -> Bytes {
  let buf = Buffer()
  buf.write_uint16_be(index.to_uint16())
  buf.contents()
}

///|
fn outcome(
  topic_id : Int,
  partition_count : Int,
  created : Bool,
) -> @broker.DeclareOutcome {
  {
    topic_id: topic_id.to_uint16(),
    partition_count: partition_count.to_uint16(),
    created,
  }
}

///|
test "first declare creates a topic and assigns identifier one" {
  let registry = @broker.TopicRegistry::new()
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 3),
    Ok(outcome(1, 3, true)),
  )
}

///|
test "an identical re-declare replays the existing entry idempotently" {
  let registry = @broker.TopicRegistry::new()
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 3),
    Ok(outcome(1, 3, true)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 3),
    Ok(outcome(1, 3, false)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 3),
    Ok(outcome(1, 3, false)),
  )
}

///|
test "a re-declare with more partitions is refused and stores nothing new" {
  let registry = @broker.TopicRegistry::new()
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 2),
    Ok(outcome(1, 2, true)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 5),
    Err(@protocol.TopicExistsMismatch),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 2),
    Ok(outcome(1, 2, false)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"other", 1),
    Ok(outcome(2, 1, true)),
  )
}

///|
test "a re-declare with fewer partitions is refused and stores nothing new" {
  let registry = @broker.TopicRegistry::new()
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 5),
    Ok(outcome(1, 5, true)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 2),
    Err(@protocol.TopicExistsMismatch),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 5),
    Ok(outcome(1, 5, false)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"other", 1),
    Ok(outcome(2, 1, true)),
  )
}

///|
test "distinct topics receive distinct sequential identifiers" {
  let registry = @broker.TopicRegistry::new()
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 1),
    Ok(outcome(1, 1, true)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"payments", 1),
    Ok(outcome(2, 1, true)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"shipments", 1),
    Ok(outcome(3, 1, true)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 1),
    Ok(outcome(1, 1, false)),
  )
}

///|
test "an empty topic name is refused and creates nothing" {
  let registry = @broker.TopicRegistry::new()
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"", 1),
    Err(@protocol.InvalidTopic),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 1),
    Ok(outcome(1, 1, true)),
  )
}

///|
test "a zero partition count is refused and creates nothing" {
  let registry = @broker.TopicRegistry::new()
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 0),
    Err(@protocol.InvalidTopic),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 1),
    Ok(outcome(1, 1, true)),
  )
}

///|
test "the maximum partition count is accepted and replays identically" {
  let registry = @broker.TopicRegistry::new()
  assert_eq(
    @broker.TopicRegistry::declare_topic(
      registry,
      b"orders",
      0xFFFFU.to_uint16(),
    ),
    Ok(outcome(1, 0xFFFF, true)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(
      registry,
      b"orders",
      0xFFFFU.to_uint16(),
    ),
    Ok(outcome(1, 0xFFFF, false)),
  )
}

///|
test "identifiers exhaust at the maximum and replays still succeed" {
  let registry = @broker.TopicRegistry::new()
  for index in 0..<65535 {
    assert_eq(
      @broker.TopicRegistry::declare_topic(registry, indexed_topic(index), 1),
      Ok(outcome(index + 1, 1, true)),
    )
  }
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"overflow", 1),
    Err(@protocol.Internal),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, indexed_topic(0), 1),
    Ok(outcome(1, 1, false)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"overflow", 1),
    Err(@protocol.Internal),
  )
}

///|
test "separate registries assign identifiers independently" {
  let first = @broker.TopicRegistry::new()
  let second = @broker.TopicRegistry::new()
  assert_eq(
    @broker.TopicRegistry::declare_topic(first, b"orders", 4),
    Ok(outcome(1, 4, true)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(second, b"orders", 9),
    Ok(outcome(1, 9, true)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(first, b"orders", 4),
    Ok(outcome(1, 4, false)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(second, b"orders", 9),
    Ok(outcome(1, 9, false)),
  )
}

///|
test "refused declares never create a topic or consume an identifier" {
  let registry = @broker.TopicRegistry::new()
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"seed", 1),
    Ok(outcome(1, 1, true)),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"", 1),
    Err(@protocol.InvalidTopic),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 0),
    Err(@protocol.InvalidTopic),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"seed", 7),
    Err(@protocol.TopicExistsMismatch),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"next", 1),
    Ok(outcome(2, 1, true)),
  )
}

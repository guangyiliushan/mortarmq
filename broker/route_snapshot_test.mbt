/// Exercise the frozen routing snapshot: construction copies, publishes
/// swap generations without editing published views, and the declare-path
/// observables that idempotent replay and the count-change refusal depend
/// on.

///|
fn routed_via(
  snapshot : @broker.RoutingSnapshot,
  topic : Bytes,
  keys : Array[Bytes],
) -> Array[Result[UInt16, @protocol.ErrCode]] {
  let partitions : Array[Result[UInt16, @protocol.ErrCode]] = Array(
    capacity=keys.length(),
  )
  for i in 0..<keys.length() {
    partitions.push(@broker.RoutingSnapshot::route(snapshot, topic, keys[i]))
  }
  partitions
}

///|
test "an empty snapshot sits at position zero and knows no topics" {
  let snapshot = @broker.RoutingSnapshot::empty()
  assert_eq(@broker.RoutingSnapshot::applied(snapshot), 0UL)
  assert_eq(@broker.RoutingSnapshot::lookup(snapshot, b"orders"), None)
  assert_eq(@broker.RoutingSnapshot::lookup(snapshot, b""), None)
  assert_eq(
    @broker.RoutingSnapshot::route(snapshot, b"orders", b"a"),
    Err(@protocol.UnknownTopic),
  )
}

///|
test "from_registry freezes the registry as it stood" {
  let registry = @broker.TopicRegistry::new()
  let _ = @broker.TopicRegistry::declare_topic(registry, b"orders", 3)
  let _ = @broker.TopicRegistry::declare_topic(registry, b"payments", 1)
  let snapshot = @broker.RoutingSnapshot::from_registry(registry, 5UL)
  // later registry movement must not leak into the frozen view
  let _ = @broker.TopicRegistry::declare_topic(registry, b"users", 7)
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 4),
    Err(@protocol.TopicExistsMismatch),
  )
  assert_eq(@broker.RoutingSnapshot::applied(snapshot), 5UL)
  assert_eq(
    @broker.RoutingSnapshot::lookup(snapshot, b"orders"),
    Some({ topic_id: 1U.to_uint16(), partition_count: 3U.to_uint16(), }),
  )
  assert_eq(
    @broker.RoutingSnapshot::lookup(snapshot, b"payments"),
    Some({ topic_id: 2U.to_uint16(), partition_count: 1U.to_uint16(), }),
  )
  assert_eq(@broker.RoutingSnapshot::lookup(snapshot, b"users"), None)
}

///|
test "publishing swaps the current view and leaves the previous view alone" {
  let table = @broker.RoutingTable::new()
  let registry = @broker.TopicRegistry::new()
  let _ = @broker.TopicRegistry::declare_topic(registry, b"orders", 3)
  let first = @broker.RoutingSnapshot::from_registry(registry, 1UL)
  @broker.RoutingTable::publish(table, first)
  let seen = @broker.RoutingTable::current(table)
  let keys : Array[Bytes] = [b"a", b"user-42", b""]
  let seen_indexes = routed_via(seen, b"orders", keys)
  let _ = @broker.TopicRegistry::declare_topic(registry, b"users", 7)
  @broker.RoutingTable::publish(
    table,
    @broker.RoutingSnapshot::from_registry(registry, 2UL),
  )
  // the held view keeps its generation; the table has moved on
  assert_eq(@broker.RoutingSnapshot::applied(seen), 1UL)
  assert_eq(@broker.RoutingSnapshot::lookup(seen, b"users"), None)
  assert_eq(routed_via(seen, b"orders", keys), seen_indexes)
  assert_eq(@broker.RoutingTable::current(table).applied(), 2UL)
  assert_eq(
    @broker.RoutingTable::current(table).lookup(b"users"),
    Some({ topic_id: 2U.to_uint16(), partition_count: 7U.to_uint16(), }),
  )
}

///|
test "hot-path reads observe the generation published at that moment" {
  let table = @broker.RoutingTable::new()
  let registry = @broker.TopicRegistry::new()
  assert_eq(@broker.RoutingTable::current(table).applied(), 0UL)
  let _ = @broker.TopicRegistry::declare_topic(registry, b"orders", 3)
  @broker.RoutingTable::publish(
    table,
    @broker.RoutingSnapshot::from_registry(registry, 10UL),
  )
  assert_eq(@broker.RoutingTable::current(table).applied(), 10UL)
  // a recovery replay may install a lower position than before
  @broker.RoutingTable::publish(
    table,
    @broker.RoutingSnapshot::from_registry(registry, 4UL),
  )
  assert_eq(@broker.RoutingTable::current(table).applied(), 4UL)
  assert_eq(
    @broker.RoutingTable::current(table).route(b"orders", b"user-42"),
    Ok(0U.to_uint16()),
  )
}

///|
test "an idempotent re-declare leaves the published view and every index unchanged" {
  let registry = @broker.TopicRegistry::new()
  let keys : Array[Bytes] = [b"a", b"user-42", b"", b"MortarMQ"]
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 3),
    Ok({
      topic_id: 1U.to_uint16(),
      partition_count: 3U.to_uint16(),
      created: true,
    }),
  )
  let table = @broker.RoutingTable::new()
  @broker.RoutingTable::publish(
    table,
    @broker.RoutingSnapshot::from_registry(registry, 8UL),
  )
  let before = routed_via(@broker.RoutingTable::current(table), b"orders", keys)
  // the replay reports the existing entry and commits nothing new
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 3),
    Ok({
      topic_id: 1U.to_uint16(),
      partition_count: 3U.to_uint16(),
      created: false,
    }),
  )
  @broker.RoutingTable::publish(
    table,
    @broker.RoutingSnapshot::from_registry(registry, 8UL),
  )
  assert_eq(@broker.RoutingTable::current(table).applied(), 8UL)
  assert_eq(
    @broker.RoutingTable::current(table).lookup(b"orders"),
    Some({ topic_id: 1U.to_uint16(), partition_count: 3U.to_uint16(), }),
  )
  assert_eq(
    routed_via(@broker.RoutingTable::current(table), b"orders", keys),
    before,
  )
}

///|
test "a refused count change cannot move a published view" {
  let registry = @broker.TopicRegistry::new()
  let keys : Array[Bytes] = [b"a", b"user-42", b"", b"MortarMQ"]
  let _ = @broker.TopicRegistry::declare_topic(registry, b"orders", 4)
  let table = @broker.RoutingTable::new()
  @broker.RoutingTable::publish(
    table,
    @broker.RoutingSnapshot::from_registry(registry, 3UL),
  )
  let before = routed_via(@broker.RoutingTable::current(table), b"orders", keys)
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 9),
    Err(@protocol.TopicExistsMismatch),
  )
  // the refusal commits nothing: the view and every index stand still
  @broker.RoutingTable::publish(
    table,
    @broker.RoutingSnapshot::from_registry(registry, 3UL),
  )
  assert_eq(
    @broker.RoutingTable::current(table).lookup(b"orders"),
    Some({ topic_id: 1U.to_uint16(), partition_count: 4U.to_uint16(), }),
  )
  assert_eq(
    routed_via(@broker.RoutingTable::current(table), b"orders", keys),
    before,
  )
}

///|
test "replaying the same declarations rebuilds an equal view" {
  let keys : Array[Bytes] = [b"a", b"user-42", b"", b"MortarMQ"]
  let names : Array[Bytes] = [b"orders", b"payments", b"users"]
  let original = @broker.TopicRegistry::new()
  let _ = @broker.TopicRegistry::declare_topic(original, b"orders", 3)
  let _ = @broker.TopicRegistry::declare_topic(original, b"payments", 1)
  let _ = @broker.TopicRegistry::declare_topic(original, b"users", 7)
  let rebuilt = @broker.TopicRegistry::new()
  let _ = @broker.TopicRegistry::declare_topic(rebuilt, b"orders", 3)
  let _ = @broker.TopicRegistry::declare_topic(rebuilt, b"payments", 1)
  let _ = @broker.TopicRegistry::declare_topic(rebuilt, b"users", 7)
  // a recovery that re-applies the same mutations reproduces the view
  let first = @broker.RoutingSnapshot::from_registry(original, 12UL)
  let second = @broker.RoutingSnapshot::from_registry(rebuilt, 12UL)
  assert_eq(
    @broker.RoutingSnapshot::applied(first),
    @broker.RoutingSnapshot::applied(second),
  )
  for i in 0..<names.length() {
    assert_eq(
      @broker.RoutingSnapshot::lookup(first, names[i]),
      @broker.RoutingSnapshot::lookup(second, names[i]),
    )
    assert_eq(
      routed_via(first, names[i], keys),
      routed_via(second, names[i], keys),
    )
  }
}

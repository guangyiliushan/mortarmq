/// Exercise the reserved dollar namespace at the user entrances: user
/// DECLARE refuses the prefix, user PUB refuses a system entry, and the
/// entry itself still stores and routes for internal writers. This is a
/// whitebox test because the fixture stands in for the internal creator
/// that has not landed yet, which needs the registry internals.

///|
test "user declare refuses the reserved dollar prefix" {
  let registry = TopicRegistry::new()
  // the internal namespace is not client-encroachable, however it is spelled
  assert_eq(
    TopicRegistry::declare_topic(registry, b"$metrics", 1),
    Err(@protocol.InvalidTopic),
  )
  assert_eq(
    TopicRegistry::declare_topic(registry, b"$", 1),
    Err(@protocol.InvalidTopic),
  )
  // the refusal carries the registered wire code
  assert_eq(@protocol.InvalidTopic.to_uint16(), 0x000BU)
  // and the same gate still passes ordinary topics
  assert_eq(
    TopicRegistry::declare_topic(registry, b"orders", 3),
    Ok({
      topic_id: 1U.to_uint16(),
      partition_count: 3U.to_uint16(),
      created: true,
    }),
  )
}

///|
test "user publish refuses targets in the reserved dollar namespace" {
  let registry = TopicRegistry::new()
  let _ = TopicRegistry::declare_topic(registry, b"orders", 3)
  // stand in for the internal creator that has not landed yet: the
  // reservation governs who may enter, not whether the entry exists
  registry.entries[b"$metrics"] = {
    partition_count: 2U.to_uint16(),
    topic_id: 9U.to_uint16(),
    is_dlq: false,
  }
  // the user publish entrance refuses the system namespace
  assert_eq(
    TopicRegistry::validate_publish(registry, 9),
    Err(@protocol.InvalidTopic),
  )
  assert_eq(@protocol.InvalidTopic.to_uint16(), 0x000BU)
  // even a user re-declare cannot walk through the existing entry
  assert_eq(
    TopicRegistry::declare_topic(registry, b"$metrics", 2),
    Err(@protocol.InvalidTopic),
  )
  // while ordinary targets pass, and the system entry still routes
  assert_eq(TopicRegistry::validate_publish(registry, 1), Ok(()))
  let snapshot = RoutingSnapshot::from_registry(registry, 1UL)
  assert_eq(
    RoutingSnapshot::route(snapshot, b"$metrics", b"user-42"),
    Ok(route_partition(b"user-42", 2U.to_uint16())),
  )
}

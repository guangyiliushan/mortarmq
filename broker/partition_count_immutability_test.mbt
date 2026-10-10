/// Exercise that a declared topic's partition count is immutable: a
/// re-declare that tries to move the count is refused with the
/// registered mismatch code, and the stored count plus every partition
/// index computed from it stay at the declared value.

///|
fn partitions_for(
  outcome : Result[@broker.DeclareOutcome, @protocol.ErrCode],
  keys : Array[Bytes],
) -> Array[UInt16] {
  guard outcome is Ok(declared) else {
    abort("partitions_for: the declaration must be readable")
  }
  let partitions : Array[UInt16] = Array(capacity=keys.length())
  for i in 0..<keys.length() {
    partitions.push(@broker.route_partition(keys[i], declared.partition_count))
  }
  partitions
}

///|
test "changing a declared partition count is refused with the registered code" {
  let registry = @broker.TopicRegistry::new()
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 4),
    Ok({
      topic_id: 1U.to_uint16(),
      partition_count: 4U.to_uint16(),
      created: true,
    }),
  )
  // a count change is refused in both directions
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 8),
    Err(@protocol.TopicExistsMismatch),
  )
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 2),
    Err(@protocol.TopicExistsMismatch),
  )
  // the refusal carries the registered wire code, not an invented one
  assert_eq(@protocol.TopicExistsMismatch.to_uint16(), 0x2001U)
  assert_eq(
    @protocol.ErrCode::from_uint16(0x2001U),
    Some(@protocol.TopicExistsMismatch),
  )
}

///|
test "a refused count change leaves the declared count and routing intact" {
  let registry = @broker.TopicRegistry::new()
  let keys : Array[Bytes] = [b"a", b"orders", b"user-42", b""]
  let first = @broker.TopicRegistry::declare_topic(registry, b"orders", 4)
  assert_eq(
    first,
    Ok({
      topic_id: 1U.to_uint16(),
      partition_count: 4U.to_uint16(),
      created: true,
    }),
  )
  let before = partitions_for(first, keys)
  // the count-change attempt is refused and mutates nothing
  assert_eq(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 9),
    Err(@protocol.TopicExistsMismatch),
  )
  let after = partitions_for(
    @broker.TopicRegistry::declare_topic(registry, b"orders", 4),
    keys,
  )
  assert_eq(after, before)
}

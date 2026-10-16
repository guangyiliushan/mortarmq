/// Route message keys onto partition indexes with the frozen v0 hash.
///
/// Partition selection is `fnv1a32(key) % partition_count`: the 32-bit
/// FNV-1a hash of the raw key bytes reduced modulo the topic's partition
/// count. The hash walks the bytes in order and per byte xors the byte
/// into the running hash before multiplying by the 32-bit prime
/// `0x01000193` with wrapping multiplication; the offset basis is
/// `0x811C9DC5`, and an empty key hashes to that basis unchanged.
///
/// Both functions are pure. The same (key, partition count) pair always
/// yields the same partition index, so replaying a published key reaches
/// the same partition with no shared state to align and no coordination
/// between publishers.
///
/// # Stability
///
/// The algorithm, the constants and the reduction are part of the v0
/// routing contract and never change in place: changing any of them
/// re-shuffles every key across partitions and breaks the per-key
/// ordering the partition assignment exists to provide. A topic's
/// partition count never changes after declaration, so an index computed
/// before a refused re-declare still names the same partition after it.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@broker.fnv1a32(b"a"), 0xE40C292CU)
///   assert_eq(@broker.route_partition(b"orders", 3), 2)
/// }
/// ```

///|
/// Hash a byte string with the 32-bit FNV-1a algorithm.
///
/// The result depends only on the input bytes: an empty input yields the
/// offset basis `0x811C9DC5`, and every byte value participates, so keys
/// that differ in any byte hash independently.
///
/// Parameters:
///
/// * `bytes` : The raw bytes to hash; a message key, in routing use.
///
/// Returns the hash as an unsigned 32-bit value.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@broker.fnv1a32(b""), 0x811C9DC5U)
///   assert_eq(@broker.fnv1a32(b"foobar"), 0xBF9CF968U)
/// }
/// ```
pub fn fnv1a32(bytes : Bytes) -> UInt32 {
  let mut hash = 0x811C9DC5U
  for byte in bytes {
    hash = (hash ^ byte.to_uint()) * 0x01000193U
  }
  hash
}

///|
/// Route a key to one partition index of a topic with the given count.
///
/// The index is `fnv1a32(key) % partition_count`, a value in
/// `0..=partition_count - 1`. An empty key routes like any other key.
/// Every replay of the same key under the same count yields the same
/// index.
///
/// Parameters:
///
/// * `key` : The message key whose per-key ordering matters.
/// * `partition_count` : The topic's declared partition count; never
///   zero, because a topic with zero partitions cannot be declared.
///
/// Returns the partition index for the key.
///
/// # Panics
///
/// Aborts when `partition_count` is zero. No index exists in an empty
/// window, and the count reaches this function only from declared topic
/// metadata, which never holds a zero; a zero here is an internal
/// invariant breach rather than a client mistake.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@broker.route_partition(b"orders", 3), 2)
///   assert_eq(@broker.route_partition(b"orders", 16), 12)
/// }
/// ```
pub fn route_partition(key : Bytes, partition_count : UInt16) -> UInt16 {
  guard partition_count.to_uint() != 0U else {
    abort("route_partition: partition count must be positive")
  }
  (fnv1a32(key) % partition_count.to_uint()).to_uint16()
}

/// Freeze topic routing metadata into immutable snapshots and swap the
/// current generation for the publish hot path.
///
/// A snapshot is the topic name to (topic identifier, partition count) view
/// at one metadata log position. The hot path reads the current generation
/// through `RoutingTable::current` and computes partition indexes from it
/// without locks: a snapshot is never edited after it is built, so a reader
/// that obtained one keeps a stable view while the table publishes later
/// generations.
///
/// # Stability
///
/// * Construction copies. Every snapshot builds its own map, reachable only
///   through the read methods here, so later declarations never leak into a
///   view that was already published.
/// * The position is the metadata log's applied offset handed in by the
///   caller, never a counter this type maintains. Recovery that replays from
///   an earlier checkpoint may publish a lower position than before; the
///   number follows the log and is not a monotonic generation this type
///   enforces.
/// * Only committed mutations rebuild a snapshot. A metadata snapshot hint
///   is a cache-maintenance record rather than a mutation, and it must not
///   trigger a rebuild.
/// * Publishing replaces the table's current snapshot; the previous one
///   keeps its contents unchanged.
///
/// Example:
///
/// ```mbt check
/// test {
///   let registry = @broker.TopicRegistry::new()
///   assert_eq(
///     @broker.TopicRegistry::declare_topic(registry, b"orders", 3),
///     Ok({
///       topic_id: 1U.to_uint16(),
///       partition_count: 3U.to_uint16(),
///       created: true,
///     }),
///   )
///   let table = @broker.RoutingTable::new()
///   @broker.RoutingTable::publish(
///     table,
///     @broker.RoutingSnapshot::from_registry(registry, 42UL),
///   )
///   assert_eq(@broker.RoutingTable::current(table).applied(), 42UL)
///   assert_eq(
///     @broker.RoutingTable::current(table).route(b"orders", b"user-42"),
///     Ok(0U.to_uint16()),
///   )
/// }
/// ```

///|
/// Carry the frozen routing metadata of one live topic: the identifier the
/// wire carries for it and the partition window every key routes into.
pub(all) struct RouteEntry {
  topic_id : UInt16
  partition_count : UInt16
} derive(Eq, Debug)

///|
pub extend RouteEntry with Eq::{not_equal, equal}

///|
pub extend RouteEntry with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Hold one immutable generation of the topic routing table.
///
/// The entry map is private and no method mutates it: a snapshot is frozen
/// at construction. Identical registry state rebuilt at the same position
/// yields the same lookups and the same routed indexes, so the view is a
/// pure function of the committed declarations it was built from.
pub struct RoutingSnapshot {
  priv entries : Map[Bytes, RouteEntry]
  priv applied : UInt64
}

///|
/// Build an empty snapshot at position zero, before any mutation applies.
///
/// Returns the view a reader sees before the first declaration reaches the
/// table: no topics, and an applied position of zero.
///
/// Example:
///
/// ```mbt check
/// test {
///   let snapshot = @broker.RoutingSnapshot::empty()
///   assert_eq(@broker.RoutingSnapshot::applied(snapshot), 0UL)
///   assert_eq(@broker.RoutingSnapshot::lookup(snapshot, b"orders"), None)
/// }
/// ```
pub fn RoutingSnapshot::empty() -> RoutingSnapshot {
  { entries: Map([]), applied: 0UL, }
}

///|
/// Freeze the registry's current topic map at one metadata log position.
///
/// The entries are copied into a map of their own, so declarations that
/// land after this call leave the returned snapshot untouched. The caller
/// passes the applied position of the last committed mutation behind the
/// registry state; this function records the number without inspecting it.
/// Replaying an accepted declaration and refusing a partition count change
/// both leave the registry unchanged, so rebuilding after either yields an
/// equal view.
///
/// Parameters:
///
/// * `registry` : The declare-side registry whose live topics to freeze.
/// * `applied` : The metadata log position of the last committed mutation
///   applied to `registry`; zero marks "nothing applied yet".
///
/// Returns the frozen view at `applied`.
///
/// Example:
///
/// ```mbt check
/// test {
///   let registry = @broker.TopicRegistry::new()
///   let _ = @broker.TopicRegistry::declare_topic(registry, b"orders", 3)
///   let snapshot = @broker.RoutingSnapshot::from_registry(registry, 7UL)
///   assert_eq(
///     @broker.RoutingSnapshot::lookup(snapshot, b"orders"),
///     Some({ topic_id: 1U.to_uint16(), partition_count: 3U.to_uint16(), }),
///   )
///   assert_eq(@broker.RoutingSnapshot::lookup(snapshot, b"payments"), None)
/// }
/// ```
pub fn RoutingSnapshot::from_registry(
  registry : TopicRegistry,
  applied : UInt64,
) -> RoutingSnapshot {
  {
    entries: registry.entries.map(fn(_name, entry) {
      { topic_id: entry.topic_id, partition_count: entry.partition_count, }
    }),
    applied,
  }
}

///|
/// Return the metadata log position this view freezes.
///
/// The value is whatever the builder passed in; it moves with the log and
/// may read lower after a recovery replay than before one.
///
/// Returns the applied position recorded at construction.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(
///     @broker.RoutingSnapshot::applied(@broker.RoutingSnapshot::empty()),
///     0UL,
///   )
/// }
/// ```
pub fn RoutingSnapshot::applied(self : RoutingSnapshot) -> UInt64 {
  self.applied
}

///|
/// Look up one topic's frozen routing metadata.
///
/// Matching is exact on the topic name, the same rule the declare path
/// applies; an empty name matches nothing. The returned entry is a value
/// copy, so holding it cannot observe any later state either.
///
/// Parameters:
///
/// * `topic` : The topic name as the wire carries it.
///
/// Returns the entry, or `None` when this generation knows no such topic.
///
/// Example:
///
/// ```mbt check
/// test {
///   let registry = @broker.TopicRegistry::new()
///   let _ = @broker.TopicRegistry::declare_topic(registry, b"orders", 3)
///   let snapshot = @broker.RoutingSnapshot::from_registry(registry, 1UL)
///   assert_eq(
///     @broker.RoutingSnapshot::lookup(snapshot, b"orders"),
///     Some({ topic_id: 1U.to_uint16(), partition_count: 3U.to_uint16(), }),
///   )
///   assert_eq(@broker.RoutingSnapshot::lookup(snapshot, b"missing"), None)
/// }
/// ```
pub fn RoutingSnapshot::lookup(
  self : RoutingSnapshot,
  topic : Bytes,
) -> RouteEntry? {
  self.entries.get(topic)
}

///|
/// Route a message key to a partition of the named topic through this view.
///
/// The partition is `fnv1a32(key) % partition_count` with the count frozen
/// in this snapshot, so the same key under the same view always lands on the
/// same partition and per-key ordering holds. A name this generation does
/// not know is an error, never an implicit declaration.
///
/// Parameters:
///
/// * `topic` : The topic name; matching is exact.
/// * `key` : The message key whose per-key ordering matters; an empty key
///   routes like any other key.
///
/// Returns the partition index, in `0..=partition_count - 1`.
///
/// # Errors
///
/// * `UnknownTopic` -- no declared entry exists under this name in the view.
///
/// Example:
///
/// ```mbt check
/// test {
///   let registry = @broker.TopicRegistry::new()
///   let _ = @broker.TopicRegistry::declare_topic(registry, b"orders", 3)
///   let snapshot = @broker.RoutingSnapshot::from_registry(registry, 1UL)
///   assert_eq(
///     @broker.RoutingSnapshot::route(snapshot, b"orders", b"user-42"),
///     Ok(0U.to_uint16()),
///   )
///   assert_eq(
///     @broker.RoutingSnapshot::route(snapshot, b"missing", b"user-42"),
///     Err(@protocol.UnknownTopic),
///   )
/// }
/// ```
pub fn RoutingSnapshot::route(
  self : RoutingSnapshot,
  topic : Bytes,
  key : Bytes,
) -> Result[UInt16, @protocol.ErrCode] {
  match self.entries.get(topic) {
    None => Err(@protocol.UnknownTopic)
    Some(entry) => Ok(route_partition(key, entry.partition_count))
  }
}

///|
/// Hold the current routing snapshot for lock-free hot-path reads.
///
/// `current` takes the installed generation in one step and never blocks a
/// publish; a reader keeps whatever generation it obtained, so the hot path
/// needs no lock and no retry. The table is the only mutable owner: the
/// snapshots it installs stay frozen.
pub struct RoutingTable {
  priv mut current : RoutingSnapshot
}

///|
/// Create a table holding the empty snapshot.
///
/// Returns the table a broker starts with: no topics, applied position zero,
/// until the declare path publishes the first generation.
///
/// Example:
///
/// ```mbt check
/// test {
///   let table = @broker.RoutingTable::new()
///   assert_eq(@broker.RoutingTable::current(table).applied(), 0UL)
///   assert_eq(@broker.RoutingTable::current(table).lookup(b"orders"), None)
/// }
/// ```
pub fn RoutingTable::new() -> RoutingTable {
  { current: RoutingSnapshot::empty(), }
}

///|
/// Return the generation installed at this moment.
///
/// The returned value is frozen: later publishes change what the next
/// `current` call returns, never what this call already handed out.
///
/// Returns the current snapshot.
///
/// Example:
///
/// ```mbt check
/// test {
///   let table = @broker.RoutingTable::new()
///   let seen = @broker.RoutingTable::current(table)
///   @broker.RoutingTable::publish(table, @broker.RoutingSnapshot::empty())
///   assert_eq(@broker.RoutingSnapshot::applied(seen), 0UL)
/// }
/// ```
pub fn RoutingTable::current(self : RoutingTable) -> RoutingSnapshot {
  self.current
}

///|
/// Install `next` as the new current generation.
///
/// The install is a single field rebind of a fully built snapshot, so a
/// reader observes either the previous generation or the new one and never
/// a half-built map. The previous snapshot is not edited and keeps serving
/// readers that obtained it earlier.
///
/// Parameters:
///
/// * `next` : The frozen view to install; its applied position rides along
///   and is never compared against the previous one.
///
/// Example:
///
/// ```mbt check
/// test {
///   let table = @broker.RoutingTable::new()
///   let registry = @broker.TopicRegistry::new()
///   let _ = @broker.TopicRegistry::declare_topic(registry, b"orders", 3)
///   @broker.RoutingTable::publish(
///     table,
///     @broker.RoutingSnapshot::from_registry(registry, 11UL),
///   )
///   assert_eq(@broker.RoutingTable::current(table).applied(), 11UL)
///   assert_eq(
///     @broker.RoutingTable::current(table).lookup(b"orders"),
///     Some({ topic_id: 1U.to_uint16(), partition_count: 3U.to_uint16(), }),
///   )
/// }
/// ```
pub fn RoutingTable::publish(
  self : RoutingTable,
  next : RoutingSnapshot,
) -> Unit {
  self.current = next
}

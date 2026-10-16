/// Maintain the in-memory topic metadata registry behind DECLARE.
///
/// `declare_topic` is the single entry point that inserts topics. A first call
/// with a non-empty name and a positive partition count creates the entry
/// and assigns the next identifier; a repeat call with the same name and
/// the same partition count returns the existing entry with `created =
/// false`, which is the idempotent replay a re-sent DECLARE must observe;
/// the same name with a different partition count is refused with
/// `TopicExistsMismatch` and the stored entry keeps its identifier and
/// count. The wire result carrying this outcome is a 2-byte big-endian
/// identifier, a 2-byte big-endian partition count, and a 1-byte created
/// flag where 0 means created now and 1 means idempotent replay.
///
/// # Stability
///
/// * No operation other than `declare_topic` ever creates a topic. A later
///   operation naming an unknown topic must fail with `UnknownTopic`
///   rather than bring one into existence; because the map is reachable
///   only through `new` and `declare_topic`, an implicit creation path cannot
///   exist here.
/// * Identifiers run 1..=0xFFFF. Identifier 0 is never assigned, so an
///   unset identifier cannot alias a live topic. Identifiers are never
///   reused: entries are never removed and the next identifier is always
///   one past the number of live entries. A new name arriving when all
///   65535 identifiers are live fails with `Internal`; replays of
///   existing names still succeed.
/// * The registry holds memory state only. It persists nothing and
///   performs no producer-level deduplication; a restart starts from an
///   empty map, and durable metadata plus mutation-level deduplication
///   are later subsystems that will wrap, not silently replace, this
///   behavior.
/// * Validation stops at four checks -- an empty name, a zero partition
///   count, the reserved `.dlq` suffix, and the reserved `$` prefix, all
///   refused with `InvalidTopic`. The wire decoder already owns length
///   bounds; richer name syntax (wildcards) belongs to later subsystems
///   and is not invented here.
/// * The `.dlq` namespace is reserved: a new topic's
///   DECLARE atomically creates its `<name>.dlq` twin from the same
///   identifier sequence and with the same partition count, in the same
///   call -- a refused declare can never leave a half-created pair. The
///   twin is a system resource: client DECLARE against the `.dlq` suffix
///   is refused with `InvalidTopic`, and client PUB resolves through
///   `validate_publish`, which refuses twin identifiers with the same
///   code. Replays create nothing new.
/// * The `$` prefix is reserved for the internal namespace: a user
///   DECLARE of a `$` name is refused with `InvalidTopic`, and a user
///   PUB resolving to a `$` entry is refused with the same code at
///   `validate_publish`. The reservation is enforced at the user
///   entrances; internal writers enter beside these gates, never
///   through them, so a system entry still stores, routes and replays
///   like any other.

///|
/// Carry the DECLARE result: the assigned or existing identifier, the
/// partition count stored for the topic, and whether this call created it.
///
/// `created` is false exactly when the call replayed an existing
/// (name, partition count) pair; the wire encodes the flag as a 1-byte
/// value where 0 means created now and 1 means idempotent replay.
pub(all) struct DeclareOutcome {
  topic_id : UInt16
  partition_count : UInt16
  created : Bool
} derive(Eq, Debug)

///|
pub extend DeclareOutcome with Eq::{not_equal, equal}

///|
pub extend DeclareOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Store the immutable metadata of one live topic.
priv struct TopicEntry {
  partition_count : UInt16
  topic_id : UInt16
  is_dlq : Bool
}

///|
/// A user-supplied topic name is at most 255 bytes of UTF-8 -- the value
/// the naming rules promise -- before the reserved-suffix and prefix
/// checks run. The internally generated `.dlq` twin is exempt: it is
/// system-produced, not user naming.
const MAX_TOPIC_NAME_BYTES : Int = 255

///|
const DLQ_SUFFIX : Bytes = b".dlq"

///|
fn has_dlq_suffix(name : Bytes) -> Bool {
  let suffix_len = DLQ_SUFFIX.length()
  if name.length() < suffix_len {
    return false
  }
  let start = name.length() - suffix_len
  for index in 0..<suffix_len {
    if name[start + index] != DLQ_SUFFIX[index] {
      return false
    }
  }
  true
}

///|
fn dlq_name(name : Bytes) -> Bytes {
  name + DLQ_SUFFIX
}

///|
const RESERVED_PREFIX : Bytes = b"$"

///|
fn has_reserved_prefix(name : Bytes) -> Bool {
  if name.length() == 0 {
    return false
  }
  name[0] == RESERVED_PREFIX[0]
}

///|
/// Hold the name-to-metadata map for one broker's topics.
///
/// Construct through `TopicRegistry::new`; because the map is reachable
/// only through `new` and `declare_topic`, the only way an entry enters
/// the map is a successful `declare_topic`, which keeps the
/// no-implicit-creation rule
/// structural rather than a convention.
pub struct TopicRegistry {
  priv entries : Map[Bytes, TopicEntry]
}

///|
/// Create an empty registry whose first created topic receives
/// identifier 1.
///
/// Identifier assignment is per registry; two registries never share
/// entries or sequences.
///
/// Example:
///
/// ```mbt check
/// test {
///   let registry = @broker.TopicRegistry::new()
///   assert_eq(
///     @broker.TopicRegistry::declare_topic(registry, b"orders", 1),
///     Ok({
///       topic_id: 1U.to_uint16(),
///       partition_count: 1U.to_uint16(),
///       created: true,
///     }),
///   )
/// }
/// ```
pub fn TopicRegistry::new() -> TopicRegistry {
  { entries: Map([]), }
}

///|
/// Declare a topic by name and partition count, creating or replaying.
///
/// A name not yet present is created with the next identifier in
/// 1..=0xFFFF and `created = true`. The same name with the same partition
/// count replays the stored entry with `created = false`. The same name
/// with a different partition count is refused, and the stored entry
/// keeps its identifier and count. A refused call never inserts an entry
/// and never consumes an identifier.
///
/// Parameters:
///
/// * `topic` : The topic name; an empty name is refused, and no other
///   syntax rule is applied here.
/// * `partition_count` : The partition count to store; zero is refused
///   because a topic with zero partitions cannot exist.
///
/// Returns the outcome for the topic: created by this call, or the
/// existing entry on an idempotent replay.
///
/// # Errors
///
/// * `InvalidTopic` -- the name is empty or the partition count is zero.
///   Both are recoverable client mistakes, so the registered
///   client-fixable code fits; `Internal` would send a fixable request to
///   issue-filing instead. The name case is exactly the registered
///   meaning; the count case stretches it -- the registry states the
///   stretch here rather than inventing an unregistered code.
/// * `TopicExistsMismatch` -- the name exists with a different partition
///   count; the stored entry is left untouched.
/// * `Internal` -- every identifier in 1..=0xFFFF is live, so a new name
///   has no identifier left. No registered code covers metadata
///   identifier capacity; `Internal` marks a server-side limit the client
///   cannot fix by retrying or backing off. Replays of existing names
///   still succeed.
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
///   assert_eq(
///     @broker.TopicRegistry::declare_topic(registry, b"orders", 3),
///     Ok({
///       topic_id: 1U.to_uint16(),
///       partition_count: 3U.to_uint16(),
///       created: false,
///     }),
///   )
///   assert_eq(
///     @broker.TopicRegistry::declare_topic(registry, b"orders", 4),
///     Err(@protocol.TopicExistsMismatch),
///   )
/// }
/// ```
pub fn TopicRegistry::declare_topic(
  self : TopicRegistry,
  topic : Bytes,
  partition_count : UInt16,
) -> Result[DeclareOutcome, @protocol.ErrCode] {
  if topic.length() == 0 {
    return Err(@protocol.InvalidTopic)
  }
  if topic.length() > MAX_TOPIC_NAME_BYTES {
    return Err(@protocol.InvalidTopic)
  }
  if has_dlq_suffix(topic) {
    return Err(@protocol.InvalidTopic)
  }
  if has_reserved_prefix(topic) {
    return Err(@protocol.InvalidTopic)
  }
  if partition_count.to_uint() == 0U {
    return Err(@protocol.InvalidTopic)
  }
  match self.entries.get(topic) {
    Some(entry) =>
      if entry.partition_count == partition_count {
        Ok({
          topic_id: entry.topic_id,
          partition_count: entry.partition_count,
          created: false,
        })
      } else {
        Err(@protocol.TopicExistsMismatch)
      }
    None => {
      // Source and `.dlq` twin land in one step from one identifier
      // sequence, so the pair is atomic and replays skip the twin.
      if self.entries.length() + 2 > 0xFFFF {
        return Err(@protocol.Internal)
      }
      let topic_id = (self.entries.length() + 1).to_uint16()
      let dlq_topic_id = (self.entries.length() + 2).to_uint16()
      self.entries[topic] = { partition_count, topic_id, is_dlq: false, }
      self.entries[dlq_name(topic)] = {
        partition_count,
        topic_id: dlq_topic_id,
        is_dlq: true,
      }
      Ok({ topic_id, partition_count, created: true, })
    }
  }
}

///|
/// The PUB-side gate: every publish resolves its target through
/// here. A `.dlq` twin is a system resource -- present for the source, but
/// never client-publishable -- and answers `InvalidTopic` (0x000B); the
/// same code refuses any entry in the reserved `$` namespace. An
/// identifier no declare ever assigned answers `UnknownTopic`.
pub fn TopicRegistry::validate_publish(
  self : TopicRegistry,
  topic_id : UInt16,
) -> Result[Unit, @protocol.ErrCode] {
  for name, entry in self.entries {
    if entry.topic_id == topic_id {
      if entry.is_dlq || has_reserved_prefix(name) {
        return Err(@protocol.InvalidTopic)
      }
      return Ok(())
    }
  }
  Err(@protocol.UnknownTopic)
}

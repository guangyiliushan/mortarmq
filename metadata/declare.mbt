/// Idempotent DECLARE state machine over the per-key accepted-mutation
/// table (REQ-STO-007, ruling Q11-A).
///
/// A mutation is identified by the client-supplied 8-byte `mutation_id`
/// scoped to its topic name (per-key). The accepted table maps each key to
/// the body every accepted mutation id was applied with, which is what the
/// REQ scenario "same mutation_id replay returns IDEMPOTENT_OK and never
/// produces a second topic" demands without qualification: a replay is
/// recognized by its id under its own key even after later mutations
/// changed the topic set (create -> delete -> replay must not resurrect).
/// Rejected mutations never enter the table, so a rejection replays as the
/// same rejection instead of drifting into a fence.
///
/// Outcome order is part of the contract (ruling: 0x2006 before 0x2001):
/// a known mutation_id with a different body is `MutationFenced` (maps to
/// 0x2006 MUTATION_FENCED, re-initiate) before any name/count check runs;
/// only a new mutation_id can reach `NameCountMismatch` (maps to 0x2001
/// TopicExistsMismatch, owned by the S1 registry layer). The machine owns
/// the durable idempotency decision table only; partition-count immutability
/// enforcement and routing stay outside this module.

///|
pub(all) enum DeclareBody {
  Create(String, UInt)
  Delete(String)
} derive(Eq, Debug)

///|
pub extend DeclareBody with Eq::{not_equal, equal}

///|
pub extend DeclareBody with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub(all) enum DeclareOutcome {
  /// The mutation applied exactly once (the CREATED outcome for creates).
  Created
  /// The delete applied exactly once.
  Deleted
  /// Replay of an accepted mutation, or a same-name same-count collapse.
  IdempotentOk
  /// Known mutation_id carried a different body (0x2006, re-initiate).
  MutationFenced
  /// New mutation_id for a name already committed with another count
  /// (0x2001 candidate, decided by the S1 registry layer).
  NameCountMismatch
} derive(Eq, Debug)

///|
pub extend DeclareOutcome with Eq::{not_equal, equal}

///|
pub extend DeclareOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Durable-idempotency state: active topics, the per-key accepted table,
/// and the highest leader_epoch applied. All three are carried verbatim
/// by the metadata snapshot; nothing here may be rebuilt from anything
/// but the MMML log and its snapshots.
pub(all) struct DeclareMachine {
  topics : Map[String, UInt]
  accepted : Map[String, Map[UInt64, DeclareBody]]
  mut max_epoch : UInt64
}

///|
fn DeclareBody::key(self : DeclareBody) -> String {
  match self {
    Create(name, _) => name
    Delete(name) => name
  }
}

///|
pub fn DeclareMachine::new() -> DeclareMachine {
  { topics: Map([]), accepted: Map([]), max_epoch: 0UL, }
}

///|
/// The highest leader_epoch this machine has accepted; also the epoch a
/// new snapshot header must carry.
pub fn DeclareMachine::leader_epoch(self : DeclareMachine) -> UInt64 {
  self.max_epoch
}

///|
/// Submit one DECLARE mutation and return its observable outcome.
///
/// Outcome order is the contract (ruling: 0x2006 before 0x2001): a known
/// mutation_id with the same body replays as `IdempotentOk` unconditionally
/// (REQ-STO-007 is epoch-independent); a known mutation_id with a
/// different body is `MutationFenced` (0x2006, re-initiate); a new
/// mutation_id from a stale leader_epoch is `MutationFenced` the same way
/// (0x2006 covers "mutation_id/epoch 过期"); only then does the
/// name/count check run, where `NameCountMismatch` (0x2001) stays the
/// S1 registry layer verdict. Rejected mutations never enter the table
/// and never advance `max_epoch`.
///
/// # Errors
///
/// None; refusals are outcomes (`MutationFenced`, `NameCountMismatch`),
/// and only accepted mutations advance state.
pub fn DeclareMachine::submit(
  self : DeclareMachine,
  mutation_id : UInt64,
  leader_epoch : UInt64,
  body : DeclareBody,
) -> DeclareOutcome {
  let table = self.accepted.get_or_init(body.key(), () => Map([]))
  match table.get(mutation_id) {
    Some(accepted) =>
      if accepted == body {
        IdempotentOk
      } else {
        MutationFenced
      }
    None =>
      if leader_epoch < self.max_epoch {
        MutationFenced
      } else {
        match body {
          Create(name, partition_count) =>
            match self.topics.get(name) {
              Some(committed) =>
                if committed == partition_count {
                  table.set(mutation_id, body)
                  if leader_epoch > self.max_epoch {
                    self.max_epoch = leader_epoch
                  }
                  IdempotentOk
                } else {
                  NameCountMismatch
                }
              None => {
                self.topics.set(name, partition_count)
                table.set(mutation_id, body)
                if leader_epoch > self.max_epoch {
                  self.max_epoch = leader_epoch
                }
                Created
              }
            }
          Delete(name) =>
            match self.topics.get(name) {
              Some(_) => {
                self.topics.remove(name)
                table.set(mutation_id, body)
                if leader_epoch > self.max_epoch {
                  self.max_epoch = leader_epoch
                }
                Deleted
              }
              None => {
                table.set(mutation_id, body)
                if leader_epoch > self.max_epoch {
                  self.max_epoch = leader_epoch
                }
                IdempotentOk
              }
            }
        }
      }
  }
}

///|
pub fn DeclareMachine::partition_count(
  self : DeclareMachine,
  name : String,
) -> UInt? {
  self.topics.get(name)
}

///|
/// Record type a DECLARE body occupies in the MMML log.
pub fn DeclareBody::to_record_type(self : DeclareBody) -> MmmlRecordType {
  match self {
    Create(_, _) => TopicCreate
    Delete(_) => TopicDelete
  }
}

///|
/// v0 mutation payload layout, frozen alongside the 34-byte envelope:
/// a u16 big-endian byte length of the UTF-8 name, the name bytes, and
/// for creates a u32 big-endian partition count. Decoding is the exact
/// inverse or rejects the bytes as malformed.
pub fn DeclareBody::to_payload(self : DeclareBody) -> Bytes {
  let name_bytes = match self {
    Create(name, _) => @utf8.encode(name)
    Delete(name) => @utf8.encode(name)
  }
  let buf = Buffer()
  buf.write_uint16_be(name_bytes.length().to_uint16())
  buf.write_bytes(name_bytes)
  match self {
    Create(_, partition_count) => buf.write_uint_be(partition_count)
    Delete(_) => ()
  }
  buf.contents()
}

///|
/// Decode one mutation payload for a DECLARE-capable record type.
///
/// Returns `None` for record types that are not DECLARE mutations, for
/// truncated or overlong payloads, and for names that are not valid
/// UTF-8; the caller refuses those bytes at the trust boundary.
pub fn decode_declare_body(
  record_type : MmmlRecordType,
  payload : BytesView,
) -> DeclareBody? {
  let is_create = match record_type {
    TopicCreate => true
    TopicDelete => false
    _ => return None
  }
  let name_len = match read_uint16_be(payload, 0) {
    Ok(value) => value.to_int()
    Err(_) => return None
  }
  let tail = if is_create { 4 } else { 0 }
  if payload.length() != 2 + name_len + tail {
    return None
  }
  let name = @utf8.decode(payload[2:2 + name_len]) catch {
    Malformed(_) => return None
  }
  if is_create {
    match read_uint_be(payload, 2 + name_len) {
      Ok(partition_count) => Some(Create(name, partition_count))
      Err(_) => None
    }
  } else {
    Some(Delete(name))
  }
}

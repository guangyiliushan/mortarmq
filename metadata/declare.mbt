/// Idempotent DECLARE state machine over the per-key accepted-mutation
/// table.
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
/// Outcome order is part of the contract (0x2006 precedes 0x2001):
/// a known mutation_id with a different body is `MutationFenced` (maps to
/// 0x2006 MUTATION_FENCED, re-initiate) before any name/count check runs;
/// only a new mutation_id can reach `NameCountMismatch` (maps to 0x2001
/// TopicExistsMismatch, owned by the S1 registry layer). The machine owns
/// the durable idempotency decision table only; partition-count immutability
/// enforcement and routing stay outside this module.

///|
pub(all) enum DeclareBody {
  Create(String, UInt32)
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
///
/// The accepted table maps each topic-name key to the op-set every
/// accepted mutation id was applied with (a packed mutation spans two
/// keys with one shared mutation_id). Storing the whole set is what
/// makes the fence total: a resubmission of the same id with a narrower,
/// wider, or different body-set is `MutationFenced` under every key it
/// touches, and a single-op mutation is the one-element set.
pub(all) struct DeclareMachine {
  topics : Map[String, UInt32]
  accepted : Map[String, Map[UInt64, Array[DeclareBody]]]
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
/// Multiset equality of two op-sets (order-insensitive; v0 sets hold one
/// or two ops).
fn body_sets_equal(a : Array[DeclareBody], b : Array[DeclareBody]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for op in a {
    let mut in_a = 0
    let mut in_b = 0
    for candidate in a {
      if candidate == op {
        in_a = in_a + 1
      }
    }
    for candidate in b {
      if candidate == op {
        in_b = in_b + 1
      }
    }
    if in_a != in_b {
      return false
    }
  }
  true
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
/// Submit one single-op DECLARE mutation; the one-element set case of
/// `submit_set`.
pub fn DeclareMachine::submit(
  self : DeclareMachine,
  mutation_id : UInt64,
  leader_epoch : UInt64,
  body : DeclareBody,
) -> DeclareOutcome {
  let outcomes = self.submit_set(mutation_id, leader_epoch, [body])
  outcomes[0]
}

///|
/// Submit one DECLARE mutation carrying one or two ops and return one
/// outcome per op, in op order.
///
/// Outcome order is the contract (0x2006 precedes 0x2001): a known
/// mutation_id whose recorded op-set equals the incoming set replays as
/// `IdempotentOk` per op unconditionally (the replay contract is
/// epoch-independent); a known mutation_id with a different op-set is
/// `MutationFenced` per op (0x2006, re-initiate); a new mutation_id from
/// a stale leader_epoch is `MutationFenced` the same way (0x2006 also
/// fences an expired mutation_id or epoch); only then does the name/count
/// check run,
/// where `NameCountMismatch` (0x2001) stays the S1 registry layer
/// verdict. Refusals are whole-set: a mismatched name/count rejects the
/// packed mutation atomically (never half a pair). Rejected
/// mutations never enter the table and never advance `max_epoch`.
///
/// # Errors
///
/// None; refusals are outcomes (`MutationFenced`, `NameCountMismatch`
/// repeated per op), and only accepted mutations advance state.
pub fn DeclareMachine::submit_set(
  self : DeclareMachine,
  mutation_id : UInt64,
  leader_epoch : UInt64,
  ops : Array[DeclareBody],
) -> Array[DeclareOutcome] {
  match self.decide_set(mutation_id, leader_epoch, ops) {
    Some(refused) => return refused
    None => ()
  }
  let outcomes : Array[DeclareOutcome] = []
  for op in ops {
    let table = self.accepted.get_or_init(op.key(), () => Map([]))
    table.set(mutation_id, ops)
    match op {
      Create(name, partition_count) =>
        match self.topics.get(name) {
          Some(_) => outcomes.push(IdempotentOk)
          None => {
            self.topics.set(name, partition_count)
            outcomes.push(Created)
          }
        }
      Delete(name) =>
        match self.topics.get(name) {
          Some(_) => {
            self.topics.remove(name)
            outcomes.push(Deleted)
          }
          None => outcomes.push(IdempotentOk)
        }
    }
  }
  if leader_epoch > self.max_epoch {
    self.max_epoch = leader_epoch
  }
  outcomes
}

///|
/// The read-only refusal check one mutation set faces: `Some(outcomes)`
/// when the set is refused as-is (fenced or mismatched; the outcomes
/// repeat uniformly per op and no state advances) or already applied
/// (uniform `IdempotentOk`), `None` when the set would apply fresh. The
/// journal-then-apply write path runs this before it journals, so a
/// refusal never lands on the log for the replay to trip over -- and an
/// idempotent replay answers without journaling a duplicate record.
fn DeclareMachine::decide_set(
  self : DeclareMachine,
  mutation_id : UInt64,
  leader_epoch : UInt64,
  ops : Array[DeclareBody],
) -> Array[DeclareOutcome]? {
  let mut any_present = false
  let mut all_present = true
  for op in ops {
    let table = self.accepted.get_or_init(op.key(), () => Map([]))
    match table.get(mutation_id) {
      Some(recorded) => {
        any_present = true
        if !body_sets_equal(recorded, ops) {
          return Some(uniform_outcomes(MutationFenced, ops.length()))
        }
      }
      None => all_present = false
    }
  }
  if any_present {
    if all_present {
      return Some(uniform_outcomes(IdempotentOk, ops.length()))
    }
    return Some(uniform_outcomes(MutationFenced, ops.length()))
  }
  if leader_epoch < self.max_epoch {
    return Some(uniform_outcomes(MutationFenced, ops.length()))
  }
  for op in ops {
    match op {
      Create(name, partition_count) =>
        match self.topics.get(name) {
          Some(committed) =>
            if committed != partition_count {
              return Some(uniform_outcomes(NameCountMismatch, ops.length()))
            }
          None => ()
        }
      Delete(_) => ()
    }
  }
  None
}

///|
fn uniform_outcomes(
  outcome : DeclareOutcome,
  count : Int32,
) -> Array[DeclareOutcome] {
  let out : Array[DeclareOutcome] = []
  for _ in 0..<count {
    out.push(outcome)
  }
  out
}

///|
pub fn DeclareMachine::partition_count(
  self : DeclareMachine,
  name : String,
) -> UInt32? {
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
/// a 2-byte big-endian byte length of the UTF-8 name, the name bytes,
/// and for creates a 4-byte big-endian partition count. Decoding is the
/// exact inverse or rejects the bytes as malformed.
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

///|
/// Encode the payload of a one-or-two-op mutation. The single-op bytes
/// are exactly the v0 form (self-delimiting name length, name, and for
/// creates a 4-byte partition count); the two-op packed form (source
/// plus `.dlq` twin) is the two single-op payloads concatenated, so a
/// decoder reads ops until the bytes are exhausted and refuses anything
/// past the second.
pub fn encode_declare_bodies(bodies : Array[DeclareBody]) -> Bytes {
  let buf = Buffer()
  for body in bodies {
    buf.write_bytes(body.to_payload())
  }
  buf.contents()
}

///|
/// Decode one self-delimiting op at `start`; returns the body and the
/// offset past it, or `None` when the bytes do not parse.
fn decode_body_at(
  record_type : MmmlRecordType,
  payload : BytesView,
  start : Int32,
) -> (DeclareBody, Int32)? {
  let is_create = match record_type {
    TopicCreate => true
    TopicDelete => false
    _ => return None
  }
  let name_len = match read_uint16_be(payload, start) {
    Ok(value) => value.to_int()
    Err(_) => return None
  }
  let tail = if is_create { 4 } else { 0 }
  let end = start + 2 + name_len + tail
  if end > payload.length() {
    return None
  }
  let name = @utf8.decode(payload[start + 2:start + 2 + name_len]) catch {
    Malformed(_) => return None
  }
  if is_create {
    match read_uint_be(payload, start + 2 + name_len) {
      Ok(partition_count) => Some((Create(name, partition_count), end))
      Err(_) => None
    }
  } else {
    Some((Delete(name), end))
  }
}

///|
/// Decode the one-or-two-op mutation payload.
///
/// Returns `None` for record types that are not DECLARE mutations, for
/// zero or more than two ops, for truncated or overlong payloads, and
/// for names that are not valid UTF-8; the caller refuses those bytes at
/// the trust boundary.
pub fn decode_declare_bodies(
  record_type : MmmlRecordType,
  payload : BytesView,
) -> Array[DeclareBody]? {
  let first = match decode_body_at(record_type, payload, 0) {
    Some(value) => value
    None => return None
  }
  let (body1, next) = first
  if next == payload.length() {
    return Some([body1])
  }
  let second = match decode_body_at(record_type, payload, next) {
    Some(value) => value
    None => return None
  }
  let (body2, end) = second
  if end != payload.length() {
    return None
  }
  Some([body1, body2])
}

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
/// Durable-idempotency state: active topics and the per-key accepted table.
/// Both maps are carried verbatim by the metadata snapshot (T057); nothing
/// here may be rebuilt from anything but the MMML log and its snapshots.
pub(all) struct DeclareMachine {
  topics : Map[String, UInt]
  accepted : Map[String, Map[UInt64, DeclareBody]]
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
  { topics: Map([]), accepted: Map([]), }
}

///|
/// Submit one DECLARE mutation and return its observable outcome.
///
/// # Errors
///
/// None; refusals are outcomes (`MutationFenced`, `NameCountMismatch`),
/// and only accepted mutations advance state.
pub fn DeclareMachine::submit(
  self : DeclareMachine,
  mutation_id : UInt64,
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
      match body {
        Create(name, partition_count) =>
          match self.topics.get(name) {
            Some(committed) =>
              if committed == partition_count {
                table.set(mutation_id, body)
                IdempotentOk
              } else {
                NameCountMismatch
              }
            None => {
              self.topics.set(name, partition_count)
              table.set(mutation_id, body)
              Created
            }
          }
        Delete(name) =>
          match self.topics.get(name) {
            Some(_) => {
              self.topics.remove(name)
              table.set(mutation_id, body)
              Deleted
            }
            None => {
              table.set(mutation_id, body)
              IdempotentOk
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

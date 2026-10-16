/// Thin mediation between the metadata domain and the protocol face
/// (CONTRIBUTING section 5: "Module dependencies are
/// architecture: protocol <- storage / broker / cluster / client, one
/// direction only; cross-cutting abstractions go through traits").
///
/// The internal `DeclareOutcome` enum names machine states
/// (`MutationFenced`, `NameCountMismatch`) that are not wire concepts.
/// Letting S1's declare layer match on that enum would couple the
/// protocol-facing layer to metadata internals and collide with the
/// protocol-face `DeclareOutcome` the broker already owns. This module
/// is the single seam the mediation goes through: callers on the S1
/// side see only `DeclareAck` and registered `ErrCode` values -- the
/// internal enum never crosses the boundary.

///|
/// The protocol face of one completed mutation op: whether this call
/// created the resource now (`created`) or answered an idempotent
/// replay. The wire encodes the flag as one byte where 0 means created
/// now and 1 means idempotent replay; refusals never arrive as an ack,
/// only as a registered `ErrCode`.
pub(all) struct DeclareAck {
  created : Bool
} derive(Eq, Debug)

///|
pub extend DeclareAck with Eq::{not_equal, equal}

///|
pub extend DeclareAck with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Mediate one internal outcome into the protocol face.
///
/// * `Created` -> ack with `created = true`.
/// * `IdempotentOk` and `Deleted` -> ack with `created = false`.
/// * `MutationFenced` -> registered 0x2006 (start the mutation over).
/// * `NameCountMismatch` -> registered 0x2001 (fix the parameters or
///   pick another name).
pub fn DeclareOutcome::to_protocol(
  self : DeclareOutcome,
) -> Result[DeclareAck, @protocol.ErrCode] {
  match self {
    Created => Ok({ created: true, })
    IdempotentOk => Ok({ created: false, })
    Deleted => Ok({ created: false, })
    MutationFenced => Err(@protocol.MutationFenced)
    NameCountMismatch => Err(@protocol.TopicExistsMismatch)
  }
}

///|
/// Mediate one whole mutation: run the guarded write path and map
/// every op outcome to the protocol face, in op order. A refusal of
/// the mutation (guard write-refusal or a whole-set fence) surfaces
/// as its registered code and no acks at all.
pub async fn[D : @harness.Disk] MetadataService::mediate_mutation(
  self : MetadataService,
  disk : D,
  log : Bytes,
  mutation_id : UInt64,
  leader_epoch : UInt64,
  ops : Array[DeclareBody],
) -> Result[Array[DeclareAck], @protocol.ErrCode] {
  let outcomes = match
    self.submit_mutation(disk, log, mutation_id, leader_epoch, ops) {
    Ok(values) => values
    Err(code) => return Err(code)
  }
  let acks : Array[DeclareAck] = []
  for outcome in outcomes {
    match outcome.to_protocol() {
      Ok(ack) => acks.push(ack)
      Err(code) => return Err(code)
    }
  }
  Ok(acks)
}

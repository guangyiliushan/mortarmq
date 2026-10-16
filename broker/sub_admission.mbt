/// The SUB admission face: a subscription is admitted only to a declared
/// topic, and a SUB never creates one.
///
/// The wire tables pin the rule: a SUB does not implicitly DECLARE, a
/// missing topic answers `UnknownTopic` with its actionable text
/// ("DECLARE first or fix the name"), and the partition field is fixed at
/// 0xFFFF in v0 because the coordinator assigns ownership. This face is
/// the decision: the caller resolves the declared set and the topic
/// partition count from the topic registry (the same shape the routing
/// face takes its count in), and the face either subscribes on presence
/// or answers 0x0008 on absence -- the registry is never written here,
/// so absence can never materialize a topic.
///
/// # Stability
///
/// * Admission is atomic in its refusal: an undeclared topic changes
///   neither the registry, the coordinator, nor the epochs.
/// * A present topic goes through the coordinator join, so the group
///   caps apply unchanged and the outcome is exactly the SUB OK result
///   fields.
/// * Re-admitting an existing (connection, topic) pair is the join's
///   idempotent path: the same subscription id comes back and nothing
///   moves.

///|
/// The success face of one admitted SUB: the OK result fields.
pub(all) struct SubOutcome {
  subscription_id : UInt16
  member_id : UInt64
  membership_epoch : UInt32
  assignment_epoch : UInt32
} derive(Eq, Debug)

///|
pub extend SubOutcome with Eq::{not_equal, equal}

///|
pub extend SubOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Admit one SUB request.
///
/// Parameters:
///
/// * `connection_id` : The requesting connection; one member per
///   connection, created on its first admitted SUB.
/// * `topic_id` : The topic being subscribed.
/// * `declared` : The caller's registry answer for the topic. False means
///   the topic is absent and the request is refused.
/// * `partition_count` : The topic partition count the caller resolved
///   from the registry.
///
/// # Errors
///
/// * `UnknownTopic` -- the topic is not declared; a SUB never creates
///   one.
/// * The join refusals (`GroupMemberLimit`, `GroupAssignmentLimit`).
///
/// Example:
///
/// ```mbt check
/// test {
///   let coordinator = @broker.GroupCoordinator::new(1)
///   assert_eq(
///     @broker.admit_sub(coordinator, 100UL, 1, false, 4),
///     Err(@protocol.UnknownTopic),
///   )
/// }
/// ```
pub fn admit_sub(
  coordinator : GroupCoordinator,
  connection_id : UInt64,
  topic_id : UInt16,
  declared : Bool,
  partition_count : UInt16,
) -> Result[SubOutcome, @protocol.ErrCode] {
  if !declared {
    return Err(@protocol.UnknownTopic)
  }
  match
    GroupCoordinator::join(
      coordinator, connection_id, topic_id, partition_count,
    ) {
    Ok(joined) =>
      Ok({
        subscription_id: joined.subscription_id,
        member_id: joined.member_id,
        membership_epoch: joined.membership_epoch,
        assignment_epoch: joined.assignment_epoch,
      })
    Err(code) => Err(code)
  }
}

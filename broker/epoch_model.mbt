/// The four-epoch model of one consumer group, named from the glossary.
///
/// Every version counter answers one question, and `fence_operation`
/// asks them in order so a stale request is refused with the code that
/// names its staleness (REQ-CON-003):
///
/// | epoch | type | who advances it | question it answers |
/// |---|---|---|---|
/// | `membership_epoch` | u32 | coordinator | which member/subscription set is live |
/// | `assignment_epoch` | u32 | coordinator | which target assignment is installed |
/// | `installed_assignment_epoch` | u32 | member installs | which assignment this member has loaded |
/// | `ownership_epoch` | u64 | coordinator | who owns this partition right now |
///
/// # Naming (R12a)
///
/// `installed_assignment_epoch` is the glossary name (glossary 2; renamed
/// 2026-10-01 from `member_epoch`, which sat four characters from
/// `membership_epoch` and meant something orthogonal). The wire field name
/// stays `assignment_epoch`: frames carry a member's installed assignment
/// under that historical name, and this model never renames the wire.
/// `wholesale_ownership_epoch` is the wholesale generation of one
/// subscription (the value `CREDIT.ownership_epoch` carries): it advances
/// only when a subscription's ownership set is replaced whole -- leave,
/// loss, rejoin -- and never on a partial partition migration.
///
/// # Fencing order
///
/// Generation first (0x0020 StaleGeneration: the member is behind or
/// ahead of the installed assignment), then ownership (0x0021 NotOwner:
/// the partition is not this member's), then recency (0x0022 StaleOwner:
/// the owner is right but the epoch is old). A request that fails several
/// fences reports the earliest: the first repair the client must make.

///|
/// Refuse an operation from a member whose assignment is not current.
///
/// Returns `StaleGeneration` when `installed` differs from the coordinator
/// `assignment_epoch`; the member must wait for the next NOTICE and must
/// not act in the meantime.
pub fn fence_installed(
  installed : UInt,
  assignment_epoch : UInt,
) -> Result[Unit, @protocol.ErrCode] {
  if installed != assignment_epoch {
    return Err(@protocol.StaleGeneration)
  }
  Ok(())
}

///|
/// Refuse an operation on a partition the member does not own.
///
/// Returns `NotOwner`; the member must stop acting on the partition and
/// wait for its next assignment.
pub fn fence_owner(
  claiming : UInt64,
  owner : UInt64,
) -> Result[Unit, @protocol.ErrCode] {
  if claiming != owner {
    return Err(@protocol.NotOwner)
  }
  Ok(())
}

///|
/// Refuse an operation carried under a superseded ownership epoch.
///
/// Returns `StaleOwner`; the ownership moved on and the request is not
/// applied. For an ACK this is the fence that keeps a superseded owner
/// from writing the cursor.
pub fn fence_ownership_epoch(
  claimed : UInt64,
  ownership_epoch : UInt64,
) -> Result[Unit, @protocol.ErrCode] {
  if claimed != ownership_epoch {
    return Err(@protocol.StaleOwner)
  }
  Ok(())
}

///|
/// Fence one member operation against the four-epoch model.
///
/// Asks generation, ownership and recency in that order and stops at the
/// first failure, so the reported code names the earliest repair.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(
///     @broker.fence_operation(1U, 2U, 5UL, 5UL, 3UL, 3UL),
///     Err(@protocol.StaleGeneration),
///   )
///   assert_eq(
///     @broker.fence_operation(2U, 2U, 5UL, 6UL, 3UL, 3UL),
///     Err(@protocol.NotOwner),
///   )
///   assert_eq(
///     @broker.fence_operation(2U, 2U, 5UL, 5UL, 3UL, 4UL),
///     Err(@protocol.StaleOwner),
///   )
///   assert_eq(@broker.fence_operation(2U, 2U, 5UL, 5UL, 4UL, 4UL), Ok(()))
/// }
/// ```
pub fn fence_operation(
  installed : UInt,
  assignment_epoch : UInt,
  claiming : UInt64,
  owner : UInt64,
  claimed_ownership : UInt64,
  ownership_epoch : UInt64,
) -> Result[Unit, @protocol.ErrCode] {
  match fence_installed(installed, assignment_epoch) {
    Err(err) => return Err(err)
    Ok(_) => ()
  }
  match fence_owner(claiming, owner) {
    Err(err) => return Err(err)
    Ok(_) => ()
  }
  fence_ownership_epoch(claimed_ownership, ownership_epoch)
}

///|
/// The one-partition ownership change callback, eight flat parameters.
///
/// Parameters in order: group_id, topic id, partition, the subscription id
/// of the member losing the partition, the owner losing it, the owner
/// gaining it, the superseded ownership epoch, the new ownership epoch.
/// The parameter list is the event shape (R12a style: semantics pinned,
/// no shared record type). The identity is the `group_id` of
/// NOTICE/CONTROL_ACK; a consumer that needs the group name resolves it
/// through the coordinator -- names never enter the event.
pub type OwnershipChangedHandler = (
  UInt16,
  UInt16,
  UInt16,
  UInt16,
  UInt64,
  UInt64,
  UInt64,
  UInt64,
) -> Unit

///|
/// The handler a coordinator starts with: nothing is subscribed.
fn ownership_changed_noop(
  _group_id : UInt16,
  _topic : UInt16,
  _partition : UInt16,
  _subscription : UInt16,
  _old_owner : UInt64,
  _new_owner : UInt64,
  _old_epoch : UInt64,
  _new_epoch : UInt64,
) -> Unit {
  ()
}

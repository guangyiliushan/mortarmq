/// The CONTROL_ACK face: one notice is confirmed once, the echo must
/// match the notice as issued, and a second confirmation is a no-op.
///
/// Every notice the coordinator issues is remembered with the fields it
/// was issued under. A confirmation echoes those fields back unchanged,
/// so out-of-order confirmations stay attributable: the face checks the
/// echo, applies the result code, and makes the second ack of one notice
/// a no-op. A late confirmation of an old notice is still recorded --
/// only the install it confirms stays monotone, so an out-of-order ack
/// can never roll a member's installed assignment backwards.

///|
/// NOTICE kind is ASSIGN (the member is assigned the partition).
/// (The constant lives with the coordinator; kept here for the docs.)
/// The CONTROL_ACK result codes: 0 confirmed, 1 stale, 2 failed.
pub const NOTICE_RESULT_OK : Byte = 0x00

///|
/// The member reports the notice was stale at its side.
pub const NOTICE_RESULT_STALE : Byte = 0x01

///|
/// The member reports it could not apply the notice.
pub const NOTICE_RESULT_ERROR : Byte = 0x02

///|
/// The two idempotent answers to a notice confirmation.
pub(all) enum NoticeAckResult {
  /// The confirmation closed the notice (first time).
  Applied
  /// The notice was already confirmed; nothing changed.
  Duplicate
} derive(Eq, Debug)

///|
pub extend NoticeAckResult with Eq::{not_equal, equal}

///|
pub extend NoticeAckResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Confirm one issued notice.
///
/// Parameters:
///
/// * `member_id` : The confirming member; must be the notice target.
/// * `ack` : The decoded CONTROL_ACK payload carrying the echo and the
///   result code.
///
/// # Errors
///
/// * `StaleGeneration` -- the notice id is unknown, the echo does not
///   match the notice as issued, or a member other than the target
///   confirms it.
///
/// Example:
///
/// ```mbt check
/// test {
///   let coordinator = @broker.GroupCoordinator::new(1)
///   assert_eq(
///     @broker.GroupCoordinator::ack_notice(coordinator, 1UL, {
///       notice_id: 9UL,
///       notice_kind: @broker.NOTICE_KIND_ASSIGN,
///       group_id: 1,
///       membership_epoch: 0U,
///       assignment_epoch: 0U,
///       ownership_epoch: 0UL,
///       result: @broker.NOTICE_RESULT_OK,
///     }),
///     Err(@protocol.StaleGeneration),
///   )
/// }
/// ```
pub fn GroupCoordinator::ack_notice(
  self : GroupCoordinator,
  member_id : UInt64,
  ack : @protocol.ControlAckPayload,
) -> Result[NoticeAckResult, @protocol.ErrCode] {
  let record = match self.notices.get(ack.notice_id) {
    Some(record) => record
    None => return Err(@protocol.StaleGeneration)
  }
  if record.acked {
    return Ok(Duplicate)
  }
  if ack.notice_kind != record.kind ||
    ack.group_id != record.group_id ||
    ack.membership_epoch != record.membership_epoch ||
    ack.assignment_epoch != record.assignment_epoch ||
    ack.ownership_epoch != record.ownership_epoch {
    return Err(@protocol.StaleGeneration)
  }
  if record.target_member != member_id {
    return Err(@protocol.StaleGeneration)
  }
  // Record the confirmation first: the echo already matched the notice
  // as issued. Then apply the result code.
  self.notices.set(ack.notice_id, {
    notice_id: record.notice_id,
    target_member: record.target_member,
    kind: record.kind,
    group_id: record.group_id,
    membership_epoch: record.membership_epoch,
    assignment_epoch: record.assignment_epoch,
    ownership_epoch: record.ownership_epoch,
    acked: true,
  })
  // An OK confirm of an ASSIGN is the member installing that assignment
  // epoch. A late confirm stays monotone: an older epoch is recorded but
  // never rolls the install backwards.
  if record.kind == NOTICE_KIND_ASSIGN && ack.result == NOTICE_RESULT_OK {
    ignore(
      GroupCoordinator::mark_installed(
        self,
        record.target_member,
        record.assignment_epoch,
      ),
    )
  }
  Ok(Applied)
}

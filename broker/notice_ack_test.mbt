/// Exercise the CONTROL_ACK face: a notice is confirmed once, the echo
/// must match the notice as issued, and a second confirmation is a no-op.

///|
fn ack_echo(
  notice : @protocol.NoticePayload,
  result : Byte,
) -> @protocol.ControlAckPayload {
  {
    notice_id: notice.notice_id,
    notice_kind: notice.kind,
    group_id: notice.group_id,
    membership_epoch: notice.membership_epoch,
    assignment_epoch: notice.assignment_epoch,
    ownership_epoch: notice.ownership_epoch,
    result,
  }
}

///|
fn first_notice(
  coordinator : @broker.GroupCoordinator,
) -> @protocol.NoticePayload {
  match @broker.GroupCoordinator::join(coordinator, 100UL, 1, 4) {
    Ok(joined) => joined.notices[0]
    Err(_) => abort("expected the join to issue notices")
  }
}

///|
test "a confirmation closes the notice and advances the install" {
  let coordinator = @broker.GroupCoordinator::new(1)
  let notice = first_notice(coordinator)
  assert_eq(
    @broker.GroupCoordinator::ack_notice(
      coordinator,
      1UL,
      ack_echo(notice, @broker.NOTICE_RESULT_OK),
    ),
    Ok(@broker.NoticeAckResult::Applied),
  )
  // An OK confirm of an assign is the member installing that epoch.
  assert_eq(
    @broker.GroupCoordinator::installed_assignment_epoch_of(coordinator, 1UL),
    Some(1U),
  )
  // A stale confirmation is still recorded but never rolls the install
  // backwards.
  assert_eq(
    @broker.GroupCoordinator::ack_notice(
      coordinator,
      1UL,
      ack_echo(notice, @broker.NOTICE_RESULT_STALE),
    ),
    Ok(@broker.NoticeAckResult::Duplicate),
  )
}

///|
test "an ack whose echo does not match the notice is refused" {
  let coordinator = @broker.GroupCoordinator::new(1)
  let notice = first_notice(coordinator)
  // The notice id is unknown.
  assert_eq(
    @broker.GroupCoordinator::ack_notice(coordinator, 1UL, {
      notice_id: 99UL,
      notice_kind: notice.kind,
      group_id: notice.group_id,
      membership_epoch: notice.membership_epoch,
      assignment_epoch: notice.assignment_epoch,
      ownership_epoch: notice.ownership_epoch,
      result: @broker.NOTICE_RESULT_OK,
    }),
    Err(@protocol.StaleGeneration),
  )
  // The echoed epoch differs from the notice as issued.
  assert_eq(
    @broker.GroupCoordinator::ack_notice(coordinator, 1UL, {
      notice_id: notice.notice_id,
      notice_kind: notice.kind,
      group_id: notice.group_id,
      membership_epoch: notice.membership_epoch,
      assignment_epoch: notice.assignment_epoch,
      ownership_epoch: 99UL,
      result: @broker.NOTICE_RESULT_OK,
    }),
    Err(@protocol.StaleGeneration),
  )
  // A member other than the target cannot confirm.
  assert_eq(
    @broker.GroupCoordinator::ack_notice(
      coordinator,
      2UL,
      ack_echo(notice, @broker.NOTICE_RESULT_OK),
    ),
    Err(@protocol.StaleGeneration),
  )
  // Nothing was applied: the install did not advance.
  assert_eq(
    @broker.GroupCoordinator::installed_assignment_epoch_of(coordinator, 1UL),
    Some(0U),
  )
}

///|
test "a second confirmation of one notice is a no-op" {
  let coordinator = @broker.GroupCoordinator::new(1)
  let notice = first_notice(coordinator)
  ignore(
    match
      @broker.GroupCoordinator::ack_notice(
        coordinator,
        1UL,
        ack_echo(notice, @broker.NOTICE_RESULT_OK),
      ) {
      Ok(result) => result
      Err(_) => abort("expected the first confirmation to apply")
    },
  )
  let before = @broker.GroupCoordinator::encode_state(coordinator)
  assert_eq(
    @broker.GroupCoordinator::ack_notice(
      coordinator,
      1UL,
      ack_echo(notice, @broker.NOTICE_RESULT_OK),
    ),
    Ok(@broker.NoticeAckResult::Duplicate),
  )
  // The duplicate changed nothing at all.
  assert_eq(@broker.GroupCoordinator::encode_state(coordinator) == before, true)
}

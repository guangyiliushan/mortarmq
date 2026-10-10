/// Exercise the group coordinator assignment engine: deterministic
/// results, sticky retention with minimum-mecessary moves, the explicit
/// group size caps (REQ-CON-006), and the NOTICE diff each join and leave
/// produces (REQ-CON-001).

///|
fn expect_joined(
  result : Result[@broker.JoinResult, @protocol.ErrCode],
) -> @broker.JoinResult {
  match result {
    Ok(joined) => joined
    Err(_) => abort("expected the join to succeed")
  }
}

///|
fn expect_left(
  result : Result[@broker.LeaveResult, @protocol.ErrCode],
) -> @broker.LeaveResult {
  match result {
    Ok(left) => left
    Err(_) => abort("expected the leave to succeed")
  }
}

///|
fn notice_at(
  notices : Array[@protocol.NoticePayload],
  index : Int,
) -> @protocol.NoticePayload {
  notices[index]
}

///|
test "a lone member owns every partition of its topic" {
  let coordinator = @broker.GroupCoordinator::new(1)
  let joined = expect_joined(
    @broker.GroupCoordinator::join(coordinator, 100UL, 1, 4),
  )
  assert_eq(joined.member_id, 1UL)
  assert_eq(joined.membership_epoch, 1U)
  assert_eq(joined.assignment_epoch, 1U)
  assert_eq(joined.notices.length(), 4)
  for p in 0..<4 {
    let notice = notice_at(joined.notices, p)
    assert_eq(notice.kind, @broker.NOTICE_KIND_ASSIGN)
    assert_eq(notice.notice_id, (p + 1).to_uint64())
    assert_eq(notice.group_id, 1)
    assert_eq(notice.membership_epoch, 1U)
    assert_eq(notice.assignment_epoch, 1U)
    assert_eq(notice.ownership_epoch, 1UL)
    assert_eq(notice.partition, p.to_uint16())
    assert_eq(notice.member_id, 1UL)
    assert_eq(
      @broker.GroupCoordinator::owner_of(coordinator, 1, p.to_uint16()),
      Some(1UL),
    )
  }
}

///|
test "a second join of the same connection adds its topic" {
  let coordinator = @broker.GroupCoordinator::new(1)
  let first = expect_joined(
    @broker.GroupCoordinator::join(coordinator, 100UL, 1, 2),
  )
  let second = expect_joined(
    @broker.GroupCoordinator::join(coordinator, 100UL, 2, 2),
  )
  assert_eq(second.member_id, first.member_id)
  assert_eq(second.membership_epoch, 2U)
  assert_eq(second.assignment_epoch, 2U)
  assert_eq(second.notices.length(), 2)
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 2, 0), Some(1UL))
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 2, 1), Some(1UL))
  // Re-joining a subscribed topic is idempotent: no notices, epochs hold.
  let replay = expect_joined(
    @broker.GroupCoordinator::join(coordinator, 100UL, 1, 2),
  )
  assert_eq(replay.notices, [])
  assert_eq(replay.membership_epoch, 2U)
  assert_eq(replay.assignment_epoch, 2U)
}

///|
test "a second member splits the topic and only the excess moves" {
  let coordinator = @broker.GroupCoordinator::new(1)
  let first = expect_joined(
    @broker.GroupCoordinator::join(coordinator, 100UL, 1, 12),
  )
  assert_eq(first.notices.length(), 12)
  let second = expect_joined(
    @broker.GroupCoordinator::join(coordinator, 101UL, 1, 12),
  )
  assert_eq(second.member_id, 2UL)
  assert_eq(second.membership_epoch, 2U)
  assert_eq(second.assignment_epoch, 2U)
  // The six largest partitions move; each carries REVOKE then ASSIGN.
  assert_eq(second.notices.length(), 12)
  let revoke = notice_at(second.notices, 0)
  assert_eq(revoke.kind, @broker.NOTICE_KIND_REVOKE)
  assert_eq(revoke.partition, 6)
  assert_eq(revoke.member_id, 1UL)
  assert_eq(revoke.ownership_epoch, 1UL)
  let assign = notice_at(second.notices, 1)
  assert_eq(assign.kind, @broker.NOTICE_KIND_ASSIGN)
  assert_eq(assign.partition, 6)
  assert_eq(assign.member_id, 2UL)
  assert_eq(assign.ownership_epoch, 2UL)
  for p in 0..<6 {
    assert_eq(
      @broker.GroupCoordinator::owner_of(coordinator, 1, p.to_uint16()),
      Some(1UL),
    )
    assert_eq(
      @broker.GroupCoordinator::ownership_epoch_of(
        coordinator,
        1,
        p.to_uint16(),
      ),
      Some(1UL),
    )
  }
  for p in 6..<12 {
    assert_eq(
      @broker.GroupCoordinator::owner_of(coordinator, 1, p.to_uint16()),
      Some(2UL),
    )
    assert_eq(
      @broker.GroupCoordinator::ownership_epoch_of(
        coordinator,
        1,
        p.to_uint16(),
      ),
      Some(2UL),
    )
  }
}

///|
test "the same join and leave sequence replays the same assignment" {
  let scenario = fn() -> Array[Int] {
    let coordinator = @broker.GroupCoordinator::new(1)
    let a = expect_joined(
      @broker.GroupCoordinator::join(coordinator, 100UL, 1, 12),
    )
    let b = expect_joined(
      @broker.GroupCoordinator::join(coordinator, 101UL, 1, 12),
    )
    let c = expect_joined(
      @broker.GroupCoordinator::join(coordinator, 102UL, 1, 12),
    )
    let left = expect_left(@broker.GroupCoordinator::leave(coordinator, 1UL))
    let seen : Array[Int] = []
    for notice in a.notices {
      seen.push(notice.notice_id.to_int())
      seen.push(notice.partition.to_int())
      seen.push(notice.member_id.to_int())
    }
    for notice in b.notices {
      seen.push(notice.notice_id.to_int())
      seen.push(notice.partition.to_int())
      seen.push(notice.member_id.to_int())
    }
    for notice in c.notices {
      seen.push(notice.notice_id.to_int())
      seen.push(notice.partition.to_int())
      seen.push(notice.member_id.to_int())
    }
    for notice in left.notices {
      seen.push(notice.notice_id.to_int())
      seen.push(notice.partition.to_int())
      seen.push(notice.member_id.to_int())
    }
    seen
  }
  assert_eq(scenario() == scenario(), true)
}

///|
test "the eleventh member is refused with the member limit" {
  let coordinator = @broker.GroupCoordinator::new(1)
  for i in 0..<@broker.MAX_GROUP_MEMBERS {
    ignore(
      expect_joined(
        @broker.GroupCoordinator::join(
          coordinator,
          (100 + i).to_uint64(),
          1,
          10,
        ),
      ),
    )
  }
  assert_eq(
    @broker.GroupCoordinator::join(coordinator, 200UL, 1, 10),
    Err(@protocol.GroupMemberLimit),
  )
}

///|
test "a subscription past the assignment cap is refused and changes nothing" {
  let coordinator = @broker.GroupCoordinator::new(1)
  assert_eq(
    @broker.GroupCoordinator::join(coordinator, 100UL, 1, 4097),
    Err(@protocol.GroupAssignmentLimit),
  )
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 0), None)
  // Exactly at the cap is admitted.
  assert_eq(
    @broker.GroupCoordinator::join(coordinator, 100UL, 1, 4096) is Ok(_),
    true,
  )
}

///|
test "a leave by an unknown member is refused" {
  let coordinator = @broker.GroupCoordinator::new(1)
  ignore(
    expect_joined(@broker.GroupCoordinator::join(coordinator, 100UL, 1, 4)),
  )
  assert_eq(
    @broker.GroupCoordinator::leave(coordinator, 999UL),
    Err(@protocol.UnknownMember),
  )
}

///|
test "a leave releases only the leaver partitions and revokes nothing" {
  let coordinator = @broker.GroupCoordinator::new(1)
  ignore(
    expect_joined(@broker.GroupCoordinator::join(coordinator, 100UL, 1, 12)),
  )
  ignore(
    expect_joined(@broker.GroupCoordinator::join(coordinator, 101UL, 1, 12)),
  )
  // Third member takes the four highest free/released partitions: 4, 5, 10, 11.
  let third = expect_joined(
    @broker.GroupCoordinator::join(coordinator, 102UL, 1, 12),
  )
  assert_eq(third.notices.length(), 8)
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 4), Some(3UL))
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 5), Some(3UL))
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 10), Some(3UL))
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 11), Some(3UL))
  // Leave member 1: only its four partitions move, ASSIGN only (the leaver
  // is gone), and the other members keep theirs.
  let left = expect_left(@broker.GroupCoordinator::leave(coordinator, 1UL))
  assert_eq(left.membership_epoch, 4U)
  assert_eq(left.assignment_epoch, 4U)
  assert_eq(left.notices.length(), 4)
  for notice in left.notices {
    assert_eq(notice.kind, @broker.NOTICE_KIND_ASSIGN)
  }
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 0), Some(2UL))
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 1), Some(3UL))
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 2), Some(2UL))
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 3), Some(3UL))
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 4), Some(3UL))
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 6), Some(2UL))
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 11), Some(3UL))
  // The untouched partitions kept their ownership epoch (CB3 shape).
  assert_eq(
    @broker.GroupCoordinator::ownership_epoch_of(coordinator, 1, 6),
    Some(2UL),
  )
}

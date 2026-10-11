/// Exercise the four-epoch model: its generation, ownership and recency
/// fences, the installed-assignment naming, persist-then-increment epoch
/// discipline, the wholesale generation rules, and the
/// ownership-change fan-out order.

///|
fn joined(
  coordinator : @broker.GroupCoordinator,
  connection_id : UInt64,
  topic_id : UInt16,
  partition_count : UInt16,
) -> @broker.JoinResult {
  match
    @broker.GroupCoordinator::join(
      coordinator, connection_id, topic_id, partition_count,
    ) {
    Ok(result) => result
    Err(_) => abort("expected the join to succeed")
  }
}

///|
test "generation, owner and recency fences report the earliest repair" {
  assert_eq(@broker.fence_installed(1U, 2U), Err(@protocol.StaleGeneration))
  assert_eq(@broker.fence_installed(2U, 2U), Ok(()))
  assert_eq(@broker.fence_owner(5UL, 6UL), Err(@protocol.NotOwner))
  assert_eq(@broker.fence_owner(6UL, 6UL), Ok(()))
  assert_eq(@broker.fence_ownership_epoch(3UL, 4UL), Err(@protocol.StaleOwner))
  assert_eq(@broker.fence_ownership_epoch(4UL, 4UL), Ok(()))
  // A request failing several fences reports the generation first.
  assert_eq(
    @broker.fence_operation(1U, 2U, 5UL, 6UL, 3UL, 4UL),
    Err(@protocol.StaleGeneration),
  )
  assert_eq(
    @broker.fence_operation(2U, 2U, 5UL, 6UL, 3UL, 4UL),
    Err(@protocol.NotOwner),
  )
  assert_eq(
    @broker.fence_operation(2U, 2U, 5UL, 5UL, 3UL, 4UL),
    Err(@protocol.StaleOwner),
  )
  assert_eq(@broker.fence_operation(2U, 2U, 5UL, 5UL, 4UL, 4UL), Ok(()))
}

///|
test "mark_installed records the epoch and refuses futures and replays" {
  let coordinator = @broker.GroupCoordinator::new(1)
  ignore(joined(coordinator, 100UL, 1, 2))
  assert_eq(
    @broker.GroupCoordinator::mark_installed(coordinator, 1UL, 1U),
    Ok(()),
  )
  assert_eq(
    @broker.GroupCoordinator::installed_assignment_epoch_of(coordinator, 1UL),
    Some(1U),
  )
  // A replay of an older epoch is stale; so is an epoch never produced.
  assert_eq(
    @broker.GroupCoordinator::mark_installed(coordinator, 1UL, 0U),
    Err(@protocol.StaleGeneration),
  )
  assert_eq(
    @broker.GroupCoordinator::mark_installed(coordinator, 1UL, 9U),
    Err(@protocol.StaleGeneration),
  )
  ignore(joined(coordinator, 100UL, 2, 2))
  assert_eq(
    @broker.GroupCoordinator::mark_installed(coordinator, 1UL, 2U),
    Ok(()),
  )
  assert_eq(
    @broker.GroupCoordinator::installed_assignment_epoch_of(coordinator, 1UL),
    Some(2U),
  )
  assert_eq(
    @broker.GroupCoordinator::mark_installed(coordinator, 999UL, 1U),
    Err(@protocol.UnknownMember),
  )
}

///|
test "epochs advance exactly with installs and refused calls are atomic" {
  let coordinator = @broker.GroupCoordinator::new(1)
  let first = joined(coordinator, 100UL, 1, 4)
  assert_eq(first.membership_epoch, 1U)
  assert_eq(first.assignment_epoch, 1U)
  for notice in first.notices {
    // Every notice carries the epochs of the install it came from: the
    // epoch is never ahead of the state it names.
    assert_eq(notice.membership_epoch, first.membership_epoch)
    assert_eq(notice.assignment_epoch, first.assignment_epoch)
  }
  let second = joined(coordinator, 101UL, 1, 4)
  assert_eq(second.membership_epoch, 2U)
  assert_eq(second.assignment_epoch, 2U)
  for notice in second.notices {
    assert_eq(notice.membership_epoch, second.membership_epoch)
    assert_eq(notice.assignment_epoch, second.assignment_epoch)
  }
  // A refused join changes nothing: no persist, no increment.
  for i in 2..<10 {
    ignore(joined(coordinator, (100 + i).to_uint64(), 1, 4))
  }
  let before_membership = 10U
  let before_assignment = 10U
  assert_eq(
    @broker.GroupCoordinator::join(coordinator, 200UL, 1, 4),
    Err(@protocol.GroupMemberLimit),
  )
  assert_eq(
    @broker.GroupCoordinator::join(coordinator, 100UL, 2, 4097),
    Err(@protocol.GroupAssignmentLimit),
  )
  let replay = joined(coordinator, 100UL, 1, 4)
  assert_eq(replay.membership_epoch, before_membership)
  assert_eq(replay.assignment_epoch, before_assignment)
}

///|
test "wholesale generations move only on the wholesale path" {
  let coordinator = @broker.GroupCoordinator::new(1)
  let first = joined(coordinator, 100UL, 1, 12)
  ignore(first)
  // A partial migration (second member takes six partitions) must not
  // touch the wholesale generation of any subscription.
  ignore(joined(coordinator, 101UL, 1, 12))
  assert_eq(
    @broker.GroupCoordinator::wholesale_epoch_of(coordinator, 1UL, 1),
    None,
  )
  assert_eq(
    @broker.GroupCoordinator::wholesale_epoch_of(coordinator, 2UL, 1),
    None,
  )
  // The leave is wholesale for the leaver subscriptions: generation bumps
  // and outlives the member as a tombstone.
  ignore(
    match @broker.GroupCoordinator::leave(coordinator, 1UL) {
      Ok(left) => left
      Err(_) => abort("expected the leave to succeed")
    },
  )
  assert_eq(
    @broker.GroupCoordinator::wholesale_epoch_of(coordinator, 1UL, 1),
    Some(1UL),
  )
  // The manual wholesale path (loss, rejoin) bumps the same counter.
  @broker.GroupCoordinator::bump_wholesale(coordinator, 2UL, 1)
  @broker.GroupCoordinator::bump_wholesale(coordinator, 2UL, 1)
  assert_eq(
    @broker.GroupCoordinator::wholesale_epoch_of(coordinator, 2UL, 1),
    Some(2UL),
  )
}

///|
test "live moves fan out to the three ports in fence release waiter order" {
  let coordinator = @broker.GroupCoordinator::new(1)
  let order : Array[Int] = []
  let seen_subscription : Array[Int] = []
  let seen_new_epoch : Array[UInt64] = []
  @broker.GroupCoordinator::on_fence_port(coordinator, fn(
    group,
    topic,
    partition,
    subscription,
    old_owner,
    new_owner,
    old_epoch,
    new_epoch,
  ) {
    ignore(group)
    ignore(topic)
    ignore(old_owner)
    ignore(old_epoch)
    order.push(partition.to_int())
    seen_subscription.push(subscription.to_int())
    seen_new_epoch.push(new_epoch)
    ignore(new_owner)
  })
  @broker.GroupCoordinator::on_release_port(coordinator, fn(
    _group,
    _topic,
    partition,
    _subscription,
    _old_owner,
    _new_owner,
    _old_epoch,
    _new_epoch,
  ) {
    order.push(100 + partition.to_int())
  })
  @broker.GroupCoordinator::on_waiter_sink(coordinator, fn(
    _group,
    _topic,
    partition,
    _subscription,
    _old_owner,
    _new_owner,
    _old_epoch,
    _new_epoch,
  ) {
    order.push(200 + partition.to_int())
  })
  let first = joined(coordinator, 100UL, 1, 12)
  // The lone join is all fresh assignments: no live move, no events.
  assert_eq(order, [])
  ignore(first)
  let second = joined(coordinator, 101UL, 1, 12)
  ignore(second)
  // Six live moves (partitions 6..11), three ports each, fixed order.
  assert_eq(order.length(), 18)
  for i in 0..<6 {
    let partition = 6 + i
    assert_eq(order[i * 3], partition)
    assert_eq(order[i * 3 + 1], 100 + partition)
    assert_eq(order[i * 3 + 2], 200 + partition)
    // The event carries the losing member's subscription and the new epoch.
    assert_eq(seen_subscription[i], 1)
    assert_eq(seen_new_epoch[i], 2UL)
  }
  // A leave is wholesale: no per-partition events fire.
  let before = order.length()
  ignore(
    match @broker.GroupCoordinator::leave(coordinator, 1UL) {
      Ok(left) => left
      Err(_) => abort("expected the leave to succeed")
    },
  )
  assert_eq(order.length(), before)
}

///|
test "unchanged owners keep their epoch while moved ones advance" {
  let coordinator = @broker.GroupCoordinator::new(1)
  ignore(joined(coordinator, 100UL, 1, 12))
  ignore(joined(coordinator, 101UL, 1, 12))
  // Partitions 0..5 never moved: epoch 1. Partitions 6..11 moved once: 2.
  for p in 0..<6 {
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
      @broker.GroupCoordinator::ownership_epoch_of(
        coordinator,
        1,
        p.to_uint16(),
      ),
      Some(2UL),
    )
  }
}

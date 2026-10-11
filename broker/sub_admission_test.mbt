/// Exercise the SUB admission face: a declared topic admits its
/// subscription, an undeclared one answers the actionable code and
/// creates nothing anywhere.

///|
fn admission_registry() -> @broker.TopicRegistry {
  let registry = @broker.TopicRegistry::new()
  match @broker.TopicRegistry::declare_topic(registry, b"orders", 4) {
    Ok(_) => registry
    Err(_) => abort("expected the topic to declare")
  }
}

///|
test "a SUB to a declared topic is admitted with the ok result fields" {
  let registry = admission_registry()
  let coordinator = @broker.GroupCoordinator::new(1)
  // The caller's registry answers: present, with the declared count.
  assert_eq(@broker.TopicRegistry::validate_publish(registry, 1), Ok(()))
  assert_eq(
    @broker.admit_sub(coordinator, 100UL, 1, true, 4),
    Ok({
      subscription_id: 1,
      member_id: 1UL,
      membership_epoch: 1U,
      assignment_epoch: 1U,
    }),
  )
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 0), Some(1UL))
}

///|
test "a SUB to an undeclared topic is refused and creates nothing" {
  let registry = admission_registry()
  let coordinator = @broker.GroupCoordinator::new(1)
  assert_eq(
    @broker.admit_sub(coordinator, 100UL, 3, false, 4),
    Err(@protocol.UnknownTopic),
  )
  // The refusal is atomic: no topic appears, no member appears, and the
  // epochs do not move. A SUB never implicitly DECLAREs.
  assert_eq(
    @broker.TopicRegistry::validate_publish(registry, 3),
    Err(@protocol.UnknownTopic),
  )
  assert_eq(@broker.GroupCoordinator::assignment_epoch(coordinator), 0U)
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 3, 0), None)
}

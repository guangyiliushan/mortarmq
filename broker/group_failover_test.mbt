/// Exercise coordinator failover reload: the group state
/// lands in the metadata log before the kill, and a restarted coordinator
/// reloads it with the assignment and the epochs continuous -- no client
/// rebuilds its subscription, no id is reused, and requests from before
/// the failover are fenced exactly as before it.

///|
fn fail_record(payload : Bytes) -> Bytes {
  let header = @metadata.MmmlHeader::new(
    format_version=1,
    header_version=1,
    flags=0,
    record_type=@metadata.MmmlRecordType::GroupUpdate,
    leader_epoch=0UL,
    mutation_id=0UL,
  )
  match @metadata.encode_mmml_record(header, payload[:]) {
    Ok(bytes) => bytes
    Err(_) => abort("expected the record to encode")
  }
}

///|
/// The durable round trip: encode the state into its log record, then
/// read the payload back the way recovery does.
fn fail_durable(payload : Bytes) -> Bytes {
  let encoded = fail_record(payload)
  match @metadata.decode_mmml_record(encoded[:]) {
    Ok(record) => record.payload
    Err(_) => abort("expected the record to decode")
  }
}

///|
fn fail_owner(
  coordinator : @broker.GroupCoordinator,
  partition : Int,
) -> UInt64? {
  @broker.GroupCoordinator::owner_of(coordinator, 1, partition.to_uint16())
}

///|
test "a coordinator killed after its state landed reloads the same assignment and epochs" {
  let coordinator = @broker.GroupCoordinator::new(1)
  ignore(
    match @broker.GroupCoordinator::join(coordinator, 100UL, 1, 12) {
      Ok(joined) => joined
      Err(_) => abort("expected the first join to succeed")
    },
  )
  ignore(
    match @broker.GroupCoordinator::join(coordinator, 101UL, 1, 12) {
      Ok(joined) => joined
      Err(_) => abort("expected the second join to succeed")
    },
  )
  ignore(
    match @broker.GroupCoordinator::leave(coordinator, 1UL) {
      Ok(left) => left
      Err(_) => abort("expected the leave to succeed")
    },
  )
  assert_eq(
    @broker.GroupCoordinator::mark_installed(coordinator, 2UL, 2U),
    Ok(()),
  )
  // The state lands durably; then the coordinator is killed.
  let durable = fail_durable(
    @broker.GroupCoordinator::encode_state(coordinator),
  )
  // Restart: the log is the only survivor.
  let restarted = match @broker.GroupCoordinator::restore_latest([durable[:]]) {
    Some(coordinator) => coordinator
    None => abort("expected the durable state to restore")
  }
  // The assignment and every ownership epoch carry over unchanged.
  for p in 0..<12 {
    assert_eq(fail_owner(restarted, p), fail_owner(coordinator, p))
    assert_eq(
      @broker.GroupCoordinator::ownership_epoch_of(restarted, 1, p.to_uint16()),
      @broker.GroupCoordinator::ownership_epoch_of(
        coordinator,
        1,
        p.to_uint16(),
      ),
    )
  }
  // The epochs are continuous, not a new generation.
  assert_eq(
    @broker.GroupCoordinator::assignment_epoch(restarted),
    @broker.GroupCoordinator::assignment_epoch(coordinator),
  )
  // Membership survives without the client re-subscribing.
  assert_eq(
    @broker.GroupCoordinator::subscription_id_of(restarted, 2UL, 1),
    Some(2),
  )
  assert_eq(
    @broker.GroupCoordinator::installed_assignment_epoch_of(restarted, 2UL),
    Some(2U),
  )
}

///|
test "the reload resumes the id allocators and fences pre-failover requests" {
  let coordinator = @broker.GroupCoordinator::new(1)
  ignore(
    match @broker.GroupCoordinator::join(coordinator, 100UL, 1, 4) {
      Ok(joined) => joined
      Err(_) => abort("expected the join to succeed")
    },
  )
  let durable = fail_durable(
    @broker.GroupCoordinator::encode_state(coordinator),
  )
  let restarted = match @broker.GroupCoordinator::restore_latest([durable[:]]) {
    Some(coordinator) => coordinator
    None => abort("expected the durable state to restore")
  }
  // The allocators resume: no member id or notice id is ever reused.
  let probe = match @broker.GroupCoordinator::join(restarted, 101UL, 2, 2) {
    Ok(joined) => joined
    Err(_) => abort("expected the post-reload join to succeed")
  }
  assert_eq(probe.member_id, 2UL)
  assert_eq(probe.notices[0].notice_id, 5UL)
  // A request from before the failover is fenced exactly as before it.
  assert_eq(
    @broker.fence_operation(1U, 2U, 1UL, 1UL, 1UL, 1UL),
    Err(@protocol.StaleGeneration),
  )
  assert_eq(
    @broker.fence_operation(2U, 2U, 1UL, 1UL, 1UL, 2UL),
    Err(@protocol.StaleOwner),
  )
  assert_eq(
    @broker.GroupCoordinator::mark_installed(restarted, 2UL, 9U),
    Err(@protocol.StaleGeneration),
  )
}

///|
test "a kill between state records recovers the last durable one" {
  let first = @broker.GroupCoordinator::new(1)
  ignore(
    match @broker.GroupCoordinator::join(first, 100UL, 1, 4) {
      Ok(joined) => joined
      Err(_) => abort("expected the first join to succeed")
    },
  )
  let state_a = fail_durable(@broker.GroupCoordinator::encode_state(first))
  ignore(
    match @broker.GroupCoordinator::join(first, 101UL, 1, 4) {
      Ok(joined) => joined
      Err(_) => abort("expected the second join to succeed")
    },
  )
  let state_b = fail_durable(@broker.GroupCoordinator::encode_state(first))
  // Both records landed: the newer state wins.
  match @broker.GroupCoordinator::restore_latest([state_a[:], state_b[:]]) {
    None => abort("expected the durable pair to restore")
    Some(restarted) =>
      assert_eq(@broker.GroupCoordinator::assignment_epoch(restarted), 2U)
  }
  // The kill lost the second record: the last durable state stands, and
  // a torn tail is stepped over rather than trusted.
  match @broker.GroupCoordinator::restore_latest([state_a[:], b"torn"[:]]) {
    None => abort("expected the last durable record to restore")
    Some(restarted) =>
      assert_eq(@broker.GroupCoordinator::assignment_epoch(restarted), 1U)
  }
}

///|
/// The drawn event sequence over one topic, joining fresh connections and
/// leaving live members.
fn fail_run(
  coordinator : @broker.GroupCoordinator,
  draw : UInt,
  partitions : Int,
) -> Bool {
  let steps = ((draw >> 4) % 5U).reinterpret_as_int() + 2
  let members : Array[UInt64] = []
  let mut connection = 100UL
  for step in 0..<steps {
    let choice = (draw >> (step * 3 + 6)) & 7U
    if choice < 5U || members.length() == 0 {
      match
        @broker.GroupCoordinator::join(
          coordinator,
          connection,
          1,
          partitions.to_uint16(),
        ) {
        Ok(joined) => members.push(joined.member_id)
        Err(_) => ()
      }
      connection = connection + 1UL
    } else {
      let index = (choice % members.length().reinterpret_as_uint()).reinterpret_as_int()
      match @broker.GroupCoordinator::leave(coordinator, members[index]) {
        Ok(_) => ignore(members.remove(index))
        Err(_) => return false
      }
    }
  }
  true
}

///|
test "reload after a kill restores exactly (quickcheck seed=20261024 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let coordinator = @broker.GroupCoordinator::new(1)
      let partitions = (draw % 8U).reinterpret_as_int() + 1
      if !fail_run(coordinator, draw, partitions) {
        return false
      }
      let durable = fail_durable(
        @broker.GroupCoordinator::encode_state(coordinator),
      )
      let restarted = match
        @broker.GroupCoordinator::restore_latest([durable[:]]) {
        Some(restarted) => restarted
        None => return false
      }
      // One encoding has exactly one meaning: equal bytes mean the whole
      // state -- members, ownership, epochs, bindings, allocators -- is
      // the same state.
      if @broker.GroupCoordinator::encode_state(restarted) !=
        @broker.GroupCoordinator::encode_state(coordinator) {
        return false
      }
      // And the continuation behaves identically from both copies.
      let a = @broker.GroupCoordinator::join(coordinator, 200UL, 2, 2)
      let b = @broker.GroupCoordinator::join(restarted, 200UL, 2, 2)
      match (a, b) {
        (Ok(from_original), Ok(from_restarted)) =>
          from_original == from_restarted
        _ => false
      }
    },
    count=200,
    max_shrinks=20,
    seed=20261024,
  )
}

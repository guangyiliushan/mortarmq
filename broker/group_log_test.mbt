/// Exercise the production persistence path of the consumer group: the
/// event loop's join and leave land their complete state in the metadata
/// log, a killed coordinator reloads from that log with the assignment and
/// the epochs continuous, a failed append surfaces its code and heals on
/// the next one, and group records ride the shared log without disturbing
/// the metadata replay.

///|
fn log_path() -> Bytes {
  b"data/metadata.log"
}

///|
fn log_owner(
  coordinator : @broker.GroupCoordinator,
  partition : Int,
) -> UInt64? {
  @broker.GroupCoordinator::owner_of(coordinator, 1, partition.to_uint16())
}

///|
async test "a join persists and a killed coordinator reloads from the log" {
  let disk = @harness.FakeDisk::new()
  let coordinator = @broker.GroupCoordinator::new(1)
  ignore(
    match
      @broker.GroupCoordinator::join_persisted(
        coordinator,
        disk,
        log_path(),
        100UL,
        1,
        8,
        3UL,
      ) {
      Ok(joined) => joined
      Err(_) => abort("expected the first persisted join to succeed")
    },
  )
  ignore(
    match
      @broker.GroupCoordinator::join_persisted(
        coordinator,
        disk,
        log_path(),
        101UL,
        1,
        8,
        3UL,
      ) {
      Ok(joined) => joined
      Err(_) => abort("expected the second persisted join to succeed")
    },
  )
  ignore(
    match
      @broker.GroupCoordinator::leave_persisted(
        coordinator,
        disk,
        log_path(),
        1UL,
        3UL,
      ) {
      Ok(left) => left
      Err(_) => abort("expected the persisted leave to succeed")
    },
  )
  // The coordinator is killed; the log is the only survivor.
  let restarted = match @broker.load_group_state(disk, log_path()) {
    Ok(Some(coordinator)) => coordinator
    Ok(None) => abort("expected the log to carry the group state")
    Err(_) => abort("expected the log to read back")
  }
  for p in 0..<8 {
    assert_eq(log_owner(restarted, p), log_owner(coordinator, p))
    assert_eq(
      @broker.GroupCoordinator::ownership_epoch_of(restarted, 1, p.to_uint16()),
      @broker.GroupCoordinator::ownership_epoch_of(
        coordinator,
        1,
        p.to_uint16(),
      ),
    )
  }
  assert_eq(
    @broker.GroupCoordinator::assignment_epoch(restarted),
    @broker.GroupCoordinator::assignment_epoch(coordinator),
  )
  assert_eq(
    @broker.GroupCoordinator::subscription_id_of(restarted, 2UL, 1),
    Some(2),
  )
}

///|
async test "every state change lands in the log as it happens" {
  let disk = @harness.FakeDisk::new()
  let coordinator = @broker.GroupCoordinator::new(1)
  ignore(
    match
      @broker.GroupCoordinator::join_persisted(
        coordinator,
        disk,
        log_path(),
        100UL,
        1,
        4,
        3UL,
      ) {
      Ok(joined) => joined
      Err(_) => abort("expected the persisted join to succeed")
    },
  )
  // The first change is durable before the second happens.
  match @broker.load_group_state(disk, log_path()) {
    Ok(Some(loaded)) =>
      assert_eq(@broker.GroupCoordinator::assignment_epoch(loaded), 1U)
    _ => abort("expected the first change to be durable")
  }
  ignore(
    match
      @broker.GroupCoordinator::join_persisted(
        coordinator,
        disk,
        log_path(),
        101UL,
        1,
        4,
        3UL,
      ) {
      Ok(joined) => joined
      Err(_) => abort("expected the second persisted join to succeed")
    },
  )
  match @broker.load_group_state(disk, log_path()) {
    Ok(Some(loaded)) =>
      assert_eq(@broker.GroupCoordinator::assignment_epoch(loaded), 2U)
    _ => abort("expected the second change to be durable")
  }
}

///|
async test "a failed append surfaces its code and the next one heals the log" {
  let disk = @harness.FakeDisk::new()
  let coordinator = @broker.GroupCoordinator::new(1)
  ignore(
    match
      @broker.GroupCoordinator::join_persisted(
        coordinator,
        disk,
        log_path(),
        100UL,
        1,
        4,
        3UL,
      ) {
      Ok(joined) => joined
      Err(_) => abort("expected the first persisted join to succeed")
    },
  )
  // The disk goes full: the append fails with its registered code while
  // the mutation stands in memory.
  disk.set_disk_full(true)
  assert_eq(
    @broker.GroupCoordinator::join_persisted(
      coordinator,
      disk,
      log_path(),
      101UL,
      1,
      4,
      3UL,
    ),
    Err(@protocol.Internal),
  )
  assert_eq(@broker.GroupCoordinator::owner_of(coordinator, 1, 1), Some(1UL))
  // The disk recovers: the next append lands the complete state, so the
  // log heals past the failed one.
  disk.set_disk_full(false)
  ignore(
    match
      @broker.GroupCoordinator::join_persisted(
        coordinator,
        disk,
        log_path(),
        102UL,
        1,
        4,
        3UL,
      ) {
      Ok(joined) => joined
      Err(_) => abort("expected the healing join to succeed")
    },
  )
  match @broker.load_group_state(disk, log_path()) {
    Ok(Some(loaded)) =>
      for p in 0..<4 {
        assert_eq(log_owner(loaded, p), log_owner(coordinator, p))
      }
    _ => abort("expected the healed log to carry the state")
  }
}

///|
async test "group records ride the shared log without disturbing the metadata replay" {
  let disk = @harness.FakeDisk::new()
  let coordinator = @broker.GroupCoordinator::new(1)
  // Two changes land at the running leader epoch, then one below it: the
  // shared-log discipline is why the append carries the running epoch.
  ignore(
    match
      @broker.GroupCoordinator::join_persisted(
        coordinator,
        disk,
        log_path(),
        100UL,
        1,
        4,
        5UL,
      ) {
      Ok(joined) => joined
      Err(_) => abort("expected the first persisted join to succeed")
    },
  )
  ignore(
    match
      @broker.GroupCoordinator::join_persisted(
        coordinator,
        disk,
        log_path(),
        101UL,
        1,
        4,
        6UL,
      ) {
      Ok(joined) => joined
      Err(_) => abort("expected the second persisted join to succeed")
    },
  )
  // The metadata replay walks past both group records untouched.
  assert_eq(@broker.load_group_state(disk, log_path()) is Ok(Some(_)), true)
  // The replay own recovery also succeeds over the shared stream. Its
  // log parameter is the stream content, so the caller reads the file.
  let content = match disk.read(log_path()) {
    Ok(data) => data
    Err(_) => abort("expected the log to read back")
  }
  let service = @metadata.MetadataService::new()
  assert_eq(
    @metadata.MetadataService::recover(service, disk, b"data", content) is Ok(_),
    true,
  )
  // A record appended below the running epoch reads as corruption to the
  // metadata replay -- the trap the running-epoch parameter exists for.
  ignore(
    match @broker.persist_group_state(disk, log_path(), coordinator, 4UL) {
      Ok(_) => ()
      Err(_) => abort("expected the stale-epoch append to land")
    },
  )
  let poisoned_content = match disk.read(log_path()) {
    Ok(data) => data
    Err(_) => abort("expected the poisoned log to read back")
  }
  let poisoned = @metadata.MetadataService::new()
  assert_eq(
    @metadata.MetadataService::recover(
      poisoned, disk, b"data", poisoned_content,
    )
    is Err(_),
    true,
  )
}

///|
test "the production path restores exactly (quickcheck seed=20261025 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let coordinator = @broker.GroupCoordinator::new(1)
      let partitions = (draw % 8U).reinterpret_as_int() + 1
      if !fail_run(coordinator, draw, partitions) {
        return false
      }
      let log = fail_record(@broker.GroupCoordinator::encode_state(coordinator))
      if log.length() == 0 {
        return false
      }
      let restarted = match @broker.scan_group_state(log[:]) {
        Some(restarted) => restarted
        None => return false
      }
      if @broker.GroupCoordinator::encode_state(restarted) !=
        @broker.GroupCoordinator::encode_state(coordinator) {
        return false
      }
      let a = @broker.GroupCoordinator::join(coordinator, 200UL, 2, 2)
      let b = @broker.GroupCoordinator::join(restarted, 200UL, 2, 2)
      match (a, b) {
        (Ok(from_original), Ok(from_restarted)) =>
          from_original == from_restarted
        _ => false
      }
    },
    count=200,
    seed=20261025,
  )
}

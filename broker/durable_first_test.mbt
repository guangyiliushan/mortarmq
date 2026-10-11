/// Exercise the durable-first consumption order of the ownership-change
/// fan-out (ruling v1.1 #1): S4 FENCED lands on the ledger first, then the
/// credit window releases, then the long-poll waiters wake. The stages
/// below are the shape the executor must reproduce -- the fence write is
/// fsync'd before any memory effect -- so a kill between the fence and
/// the wake can only lose memory state: recovery folds the log to
/// RetryScheduled with the fence remembered, and the contradiction "the
/// window is open while the ledger shows the old owner Delivering" can
/// never appear.

///|
fn durable_path() -> Bytes {
  b"data/partitions/0001/0000/delivery.mql"
}

///|
fn durable_key(sequence : UInt64) -> @delivery.DeliveryKey {
  @delivery.DeliveryKey::new(group_id=1, topic_id=1, partition=0, sequence~)
}

///|
fn open_durable_window() -> @broker.CreditRegistry {
  let registry = @broker.CreditRegistry::new()
  let window = @broker.CreditWindow::new(
    1,
    1U,
    1UL,
    16U.to_uint16(),
    8192U,
    16U.to_uint16(),
    8192U,
    8U.to_uint16(),
  )
  @broker.CreditRegistry::register(registry, window)
  registry
}

///|
async fn durable_events(
  disk : @harness.FakeDisk,
) -> Array[@delivery.LedgerEvent] {
  match @delivery.read_ledger_events(disk, durable_path()) {
    Ok(events) => events
    Err(_) => abort("expected the ledger to read back")
  }
}

///|
fn outstanding(registry : @broker.CreditRegistry) -> UInt16 {
  match @broker.CreditRegistry::report(registry, 1) {
    Ok(report) => report.outstanding_count
    Err(_) => abort("expected the window to report")
  }
}

///|
async test "the fence is durable before the window releases and the waiters wake" {
  let disk = @harness.FakeDisk::new()
  let writer = match @delivery.LedgerWriter::new(durable_path()) {
    Ok(writer) => writer
    Err(_) => abort("expected a valid ledger path")
  }
  let machine = @delivery.DeliveryMachine::new(1, 0, writer)
  ignore(
    match machine.begin_delivery(disk, durable_key(0UL), 7, 100UL, None) {
      Ok(attempt) => attempt
      Err(_) => abort("expected the first delivery to begin")
    },
  )
  ignore(
    match machine.begin_delivery(disk, durable_key(1UL), 7, 100UL, None) {
      Ok(attempt) => attempt
      Err(_) => abort("expected the second delivery to begin")
    },
  )
  let registry = open_durable_window()
  ignore(
    match @broker.CreditRegistry::admit(registry, 1, 0, 5UL, 1UL, 128U) {
      Ok(_) => 0
      Err(_) => abort("expected the first tranche to book")
    },
  )
  ignore(
    match @broker.CreditRegistry::admit(registry, 1, 0, 5UL, 1UL, 128U) {
      Ok(_) => 0
      Err(_) => abort("expected the second tranche to book")
    },
  )
  assert_eq(outstanding(registry), 2U.to_uint16())
  // Stage 1: the fence write (S4 port), then the durable barrier.
  ignore(
    match
      machine.on_ownership_changed(disk, 1, 1, 0, 1, 7, 8, 5, 6, 100UL, None) {
      Ok(_) => ()
      Err(_) => abort("expected the fence write to apply")
    },
  )
  ignore(
    match writer.sync(disk) {
      Ok(_) => ()
      Err(_) => abort("expected the fence write to sync")
    },
  )
  // The fence is on disk BEFORE any memory effect runs.
  let fenced = durable_events(disk)
  assert_eq(fenced.length(), 4)
  assert_eq(fenced[2].event, @delivery.LedgerEventKind::Fenced)
  assert_eq(fenced[3].event, @delivery.LedgerEventKind::Fenced)
  assert_eq(
    machine.state_of(durable_key(0UL))
    is Some(@delivery.DeliveryState::RetryScheduled(_)),
    true,
  )
  // The window has NOT released yet: the fence led the release.
  assert_eq(outstanding(registry), 2U.to_uint16())
  // Stage 2: the credit release (S6 port).
  @broker.CreditRegistry::on_ownership_changed(registry, 1, 1, 0, 1, 7, 8, 5, 6)
  assert_eq(outstanding(registry), 0U.to_uint16())
  // Stage 3: the waiter wake (S7 sink) runs last.
  let woken : Array[Int] = []
  let wake = fn() { woken.push(1) }
  wake()
  assert_eq(woken.length(), 1)
}

///|
async test "a kill between fence and wake recovers with the fence intact" {
  let disk = @harness.FakeDisk::new()
  let writer = match @delivery.LedgerWriter::new(durable_path()) {
    Ok(writer) => writer
    Err(_) => abort("expected a valid ledger path")
  }
  let machine = @delivery.DeliveryMachine::new(1, 0, writer)
  ignore(
    match machine.begin_delivery(disk, durable_key(0UL), 7, 100UL, None) {
      Ok(attempt) => attempt
      Err(_) => abort("expected the first delivery to begin")
    },
  )
  ignore(
    match machine.begin_delivery(disk, durable_key(1UL), 7, 100UL, None) {
      Ok(attempt) => attempt
      Err(_) => abort("expected the second delivery to begin")
    },
  )
  // Stage 1 only: the fence lands durably, then the process dies before
  // the release and the wake ever run.
  ignore(
    match
      machine.on_ownership_changed(disk, 1, 1, 0, 1, 7, 8, 5, 6, 100UL, None) {
      Ok(_) => ()
      Err(_) => abort("expected the fence write to apply")
    },
  )
  ignore(
    match writer.sync(disk) {
      Ok(_) => ()
      Err(_) => abort("expected the fence write to sync")
    },
  )
  // Restart: a fresh machine folds the same log (the restart policy
  // redelivers in-flight entries; the fence memory survives the crash).
  let writer2 = match @delivery.LedgerWriter::new(durable_path()) {
    Ok(writer) => writer
    Err(_) => abort("expected a valid ledger path")
  }
  let recovered = match
    @delivery.DeliveryMachine::recover(disk, 1, 0, writer2) {
    Ok(machine) => machine
    Err(_) => abort("expected the ledger to recover")
  }
  // The contradiction side can never appear: the ledger does not show
  // the old owner Delivering any fenced sequence after recovery.
  assert_eq(
    recovered.state_of(durable_key(0UL))
    is Some(@delivery.DeliveryState::RetryScheduled(_)),
    true,
  )
  assert_eq(
    recovered.state_of(durable_key(1UL))
    is Some(@delivery.DeliveryState::RetryScheduled(_)),
    true,
  )
  // A late ACK from the fenced delivery is refused: the fence outlived
  // the crash because it was durable before any memory effect.
  assert_eq(
    recovered.ack(disk, durable_key(0UL), 1UL, 200UL, None),
    Err(@delivery.DeliveryError::StaleOwner),
  )
}

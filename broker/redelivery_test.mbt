/// Exercise the redelivery credit gate (Q16: redelivery counts credit):
/// the matured-timer hop re-checks state, bills the gate like a first
/// delivery, and only then charges the ledger; refusals bill nothing.

///|
fn ledger_path() -> Bytes {
  b"data/partitions/0001/0000/delivery.mql"
}

///|
fn redelivery_key() -> @delivery.DeliveryKey {
  @delivery.DeliveryKey::new(group_id=1, topic_id=1, partition=0, sequence=0UL)
}

///|
fn open_window(
  initial_count : UInt16,
  generation : UInt64,
) -> @broker.CreditRegistry {
  let registry = @broker.CreditRegistry::new()
  let window = @broker.CreditWindow::new(
    1,
    1U,
    generation,
    initial_count,
    4096U,
    16U.to_uint16(),
    8192U,
    8U.to_uint16(),
  )
  @broker.CreditRegistry::register(registry, window)
  registry
}

///|
async fn deliver_events(
  disk : @harness.FakeDisk,
) -> Array[@delivery.LedgerEvent] {
  match @delivery.read_ledger_events(disk, ledger_path()) {
    Ok(events) => events
    Err(_) => abort("expected the ledger to read back")
  }
}

///|
async test "a matured retry passes the gate and bills the attempt" {
  let disk = @harness.FakeDisk::new()
  let writer = match @delivery.LedgerWriter::new(ledger_path()) {
    Ok(writer) => writer
    Err(_) => abort("expected a valid ledger path")
  }
  let machine = @delivery.DeliveryMachine::new(1, 0, writer)
  let key = redelivery_key()
  // First delivery, then a retry outcome parks the entry for redelivery.
  ignore(
    match
      @delivery.DeliveryMachine::begin_delivery(
        machine,
        disk,
        key,
        7UL,
        0UL,
        None,
      ) {
      Ok(attempt) => attempt
      Err(_) => abort("expected the first delivery to begin")
    },
  )
  let rng = @harness.SplitMix64::new(1UL)
  ignore(
    match
      @delivery.DeliveryMachine::nack(
        machine,
        disk,
        rng,
        key,
        1UL,
        @delivery.DeliveryOutcome::Retry,
        1000UL,
        None,
      ) {
      Ok(plan) => plan
      Err(_) => abort("expected the retry nack to apply")
    },
  )
  let registry = open_window(10U.to_uint16(), 1UL)
  let booked = match
    @broker.redeliver_one(
      machine,
      registry,
      disk,
      key,
      1,
      8UL,
      5UL,
      1UL,
      32U,
      2000UL,
      None,
    ) {
    Ok(attempt) => attempt
    Err(_) => abort("expected the gated redelivery to bill")
  }
  assert_eq(booked.attempt, 2U.to_uint16())
  assert_eq(booked.owner_conn, 8UL)
  // The gate booked the attempt before the ledger charged it.
  match @broker.CreditRegistry::report(registry, 1) {
    Ok(report) => assert_eq(report.outstanding_count, 1U.to_uint16())
    Err(_) => abort("expected the window to report")
  }
  let events = deliver_events(disk)
  assert_eq(events.length(), 3)
  assert_eq(events[2].event, @delivery.LedgerEventKind::Deliver)
  assert_eq(events[2].attempt, 2U.to_uint16())
}

///|
async test "a refused gate bills nothing and sends nothing" {
  let disk = @harness.FakeDisk::new()
  let writer = match @delivery.LedgerWriter::new(ledger_path()) {
    Ok(writer) => writer
    Err(_) => abort("expected a valid ledger path")
  }
  let machine = @delivery.DeliveryMachine::new(1, 0, writer)
  let key = redelivery_key()
  ignore(
    match
      @delivery.DeliveryMachine::begin_delivery(
        machine,
        disk,
        key,
        7UL,
        0UL,
        None,
      ) {
      Ok(attempt) => attempt
      Err(_) => abort("expected the first delivery to begin")
    },
  )
  let rng = @harness.SplitMix64::new(1UL)
  ignore(
    match
      @delivery.DeliveryMachine::nack(
        machine,
        disk,
        rng,
        key,
        1UL,
        @delivery.DeliveryOutcome::Retry,
        1000UL,
        None,
      ) {
      Ok(plan) => plan
      Err(_) => abort("expected the retry nack to apply")
    },
  )
  // An empty window refuses the retry: REQ-DEL-005 "信用耗尽时 MSG 停发".
  let registry = open_window(0U.to_uint16(), 1UL)
  assert_eq(
    @broker.redeliver_one(
      machine,
      registry,
      disk,
      key,
      1,
      8UL,
      5UL,
      1UL,
      32U,
      2000UL,
      None,
    ),
    Err(@broker.RedeliverError::CreditRefused(@broker.CreditError::NoCredit)),
  )
  // Nothing billed, nothing written: the entry stays RetryScheduled.
  assert_eq(deliver_events(disk).length(), 2)
  assert_eq(
    @delivery.DeliveryMachine::state_of(machine, key)
    is Some(@delivery.DeliveryState::RetryScheduled(_)),
    true,
  )
}

///|
async test "a stale wholesale generation refuses the retry" {
  let disk = @harness.FakeDisk::new()
  let writer = match @delivery.LedgerWriter::new(ledger_path()) {
    Ok(writer) => writer
    Err(_) => abort("expected a valid ledger path")
  }
  let machine = @delivery.DeliveryMachine::new(1, 0, writer)
  let key = redelivery_key()
  ignore(
    match
      @delivery.DeliveryMachine::begin_delivery(
        machine,
        disk,
        key,
        7UL,
        0UL,
        None,
      ) {
      Ok(attempt) => attempt
      Err(_) => abort("expected the first delivery to begin")
    },
  )
  let rng = @harness.SplitMix64::new(1UL)
  ignore(
    match
      @delivery.DeliveryMachine::nack(
        machine,
        disk,
        rng,
        key,
        1UL,
        @delivery.DeliveryOutcome::Retry,
        1000UL,
        None,
      ) {
      Ok(plan) => plan
      Err(_) => abort("expected the retry nack to apply")
    },
  )
  // The window validates the coordinator's wholesale generation (Q28).
  let registry = open_window(10U.to_uint16(), 1UL)
  assert_eq(
    @broker.redeliver_one(
      machine,
      registry,
      disk,
      key,
      1,
      8UL,
      5UL,
      2UL,
      32U,
      2000UL,
      None,
    ),
    Err(
      @broker.RedeliverError::CreditRefused(
        @broker.CreditError::StaleGeneration,
      ),
    ),
  )
  assert_eq(deliver_events(disk).length(), 2)
}

///|
async test "a key that is not a matured retry is refused before the gate" {
  let disk = @harness.FakeDisk::new()
  let writer = match @delivery.LedgerWriter::new(ledger_path()) {
    Ok(writer) => writer
    Err(_) => abort("expected a valid ledger path")
  }
  let machine = @delivery.DeliveryMachine::new(1, 0, writer)
  let registry = open_window(10U.to_uint16(), 1UL)
  // A key the machine has never seen: the state re-check refuses it and
  // the gate is never consulted -- no credit is booked for a non-send.
  assert_eq(
    @broker.redeliver_one(
      machine,
      registry,
      disk,
      redelivery_key(),
      1,
      8UL,
      5UL,
      1UL,
      32U,
      2000UL,
      None,
    ),
    Err(
      @broker.RedeliverError::DeliveryFailed(
        @delivery.DeliveryError::InvalidTransition,
      ),
    ),
  )
  match @broker.CreditRegistry::report(registry, 1) {
    Ok(report) => assert_eq(report.outstanding_count, 0U.to_uint16())
    Err(_) => abort("expected the window to report")
  }
}

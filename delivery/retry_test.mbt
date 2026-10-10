/// Exercise the frozen retry policy (WP-04.03, REQ-DEL-002): 1s/2s/4s/8s
/// backoff with bounded jitter, and the attempt budget that makes the 6th
/// delivery impossible.

///|
fn retry_gate(_bytes : Int) -> Result[Unit, @delivery.DeliveryError] {
  Ok(())
}

///|
fn retry_key(sequence : UInt64) -> @delivery.DeliveryKey {
  @delivery.DeliveryKey::new(group_id=1, topic_id=1, partition=0, sequence~)
}

///|
fn retry_machine(path : Bytes) -> @delivery.DeliveryMachine raise {
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  @delivery.DeliveryMachine::new(1, 0, writer)
}

///|
/// Fail one delivery with the given outcome and return the retry plan.
async fn fail_once(
  machine : @delivery.DeliveryMachine,
  disk : @harness.FakeDisk,
  rng : @harness.SplitMix64,
  delivery_id : UInt64,
  outcome : @delivery.DeliveryOutcome,
  now_unix_ms : UInt64,
) -> @delivery.RetryPlan {
  match
    machine.nack(
      disk,
      rng,
      retry_key(1),
      delivery_id,
      outcome,
      now_unix_ms,
      retry_gate,
    ) {
    Ok(plan) => plan
    Err(_) => fail("nack failed")
  }
}

///|
async test "retry backoff is 1s/2s/4s/8s with the frozen jitter bound" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = retry_machine(path)
  let rng = @harness.SplitMix64::new(42UL)
  let base : Array[UInt] = [1000, 2000, 4000, 8000]
  for round in 0..<4 {
    let bundle = match
      machine.begin_delivery(disk, retry_key(1), 7, 1000, retry_gate) {
      Ok(bundle) => bundle
      Err(_) => fail("begin_delivery failed")
    }
    assert_eq(bundle.attempt.to_int(), round + 1)
    let plan = fail_once(
      machine,
      disk,
      rng,
      bundle.delivery_id,
      @delivery.Retry,
      2000,
    )
    match plan {
      @delivery.Scheduled(attempt, delay_ms) => {
        assert_eq(attempt.to_int(), round + 1)
        let delay_n = base[round]
        // delay_n <= delay <= delay_n + delay_n/4
        assert_eq(delay_ms >= delay_n, true)
        assert_eq(delay_ms <= delay_n + delay_n / 4, true)
      }
      _ => fail("expected a retry schedule")
    }
  }
}

///|
async test "the same seed reproduces the same backoff draw" {
  let outcomes : Array[UInt] = []
  for _run in 0..<2 {
    let disk = @harness.FakeDisk::new()
    let path = b"data/partitions/0001/0000/delivery.mql"
    let machine = retry_machine(path)
    let rng = @harness.SplitMix64::new(7UL)
    let bundle = match
      machine.begin_delivery(disk, retry_key(1), 7, 1000, retry_gate) {
      Ok(bundle) => bundle
      Err(_) => fail("begin_delivery failed")
    }
    let plan = fail_once(
      machine,
      disk,
      rng,
      bundle.delivery_id,
      @delivery.Retry,
      2000,
    )
    match plan {
      @delivery.Scheduled(_, delay_ms) => outcomes.push(delay_ms)
      _ => fail("expected a retry schedule")
    }
  }
  assert_eq(outcomes[0], outcomes[1])
}

///|
async test "the 6th delivery is never enqueued after max attempts (L1)" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = retry_machine(path)
  let rng = @harness.SplitMix64::new(1UL)
  let mut round = 0
  while round < 5 {
    let bundle = match
      machine.begin_delivery(disk, retry_key(1), 7, 1000, retry_gate) {
      Ok(bundle) => bundle
      Err(_) => fail("begin_delivery failed")
    }
    assert_eq(bundle.attempt.to_int(), round + 1)
    let plan = fail_once(
      machine,
      disk,
      rng,
      bundle.delivery_id,
      @delivery.Retry,
      2000,
    )
    round = round + 1
    if round < 5 {
      match plan {
        @delivery.Scheduled(_, _) => ()
        _ => fail("expected a retry schedule before the budget is spent")
      }
    } else {
      match plan {
        @delivery.DeadLettered(attempt) => assert_eq(attempt, 5)
        _ => fail("expected the fifth failure to exhaust the budget")
      }
    }
  }
  assert_eq(machine.state_of(retry_key(1)), Some(@delivery.DeadLetterQueued))
  // The L1 rule: attempt 6 is refused and nothing is billed for it.
  match machine.begin_delivery(disk, retry_key(1), 7, 1000, retry_gate) {
    Err(@delivery.AlreadyDeadLettered) => assert_eq(true, true)
    _ => fail("expected attempt 6 to be refused")
  }
  match machine.ack(disk, retry_key(1), 99UL, 1000, retry_gate) {
    Err(@delivery.AlreadyDeadLettered) => assert_eq(true, true)
    _ => fail("expected ACK on a dead-lettered entry to be refused")
  }
  match @delivery.read_ledger_events(disk, path) {
    Ok(events) => {
      // D,N,D,N,D,N,D,N,D,NT: five deliveries, four retries, one terminal.
      assert_eq(events.length(), 10)
      let mut delivers = 0
      let mut retries = 0
      let mut terminals = 0
      for event in events {
        match event.event {
          @delivery.Deliver => delivers = delivers + 1
          @delivery.NackRetry => retries = retries + 1
          @delivery.NackTerminal => terminals = terminals + 1
          _ => fail("unexpected event kind")
        }
      }
      assert_eq(delivers, 5)
      assert_eq(retries, 4)
      assert_eq(terminals, 1)
    }
    Err(_) => fail("ledger scan failed")
  }
}

///|
async test "timeout reschedules with the same backoff and cap" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = retry_machine(path)
  let rng = @harness.SplitMix64::new(3UL)
  let base : Array[UInt] = [1000, 2000, 4000, 8000]
  let mut round = 0
  while round < 5 {
    let bundle = match
      machine.begin_delivery(disk, retry_key(1), 7, 1000, retry_gate) {
      Ok(bundle) => bundle
      Err(_) => fail("begin_delivery failed")
    }
    let plan = match
      machine.timeout(
        disk,
        rng,
        retry_key(1),
        bundle.delivery_id,
        2000,
        retry_gate,
      ) {
      Ok(plan) => plan
      Err(_) => fail("timeout failed")
    }
    round = round + 1
    if round < 5 {
      match plan {
        @delivery.Scheduled(_, delay_ms) => {
          let delay_n = base[round - 1]
          assert_eq(delay_ms >= delay_n, true)
          assert_eq(delay_ms <= delay_n + delay_n / 4, true)
        }
        _ => fail("expected a retry schedule")
      }
    } else {
      match plan {
        @delivery.DeadLettered(_) => ()
        _ => fail("expected the fifth timeout to exhaust the budget")
      }
    }
  }
  match machine.timeout(disk, rng, retry_key(1), 5UL, 3000, retry_gate) {
    Err(@delivery.AlreadyDeadLettered) => assert_eq(true, true)
    _ => fail("expected timeout on a dead-lettered entry to be refused")
  }
}

///|
async test "failure paths on resolved entries are idempotent no-ops" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = retry_machine(path)
  let rng = @harness.SplitMix64::new(5UL)
  match machine.begin_delivery(disk, retry_key(1), 7, 1000, retry_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match machine.ack(disk, retry_key(1), 1UL, 1500, retry_gate) {
    Ok(_) => ()
    Err(_) => fail("ack failed")
  }
  // Fault 12: the NACK half of an ACK/NACK race is a no-op.
  match
    machine.nack(
      disk,
      rng,
      retry_key(1),
      1UL,
      @delivery.Retry,
      2000,
      retry_gate,
    ) {
    Err(@delivery.AlreadyAcked) => assert_eq(true, true)
    _ => fail("expected AlreadyAcked")
  }
  match machine.timeout(disk, rng, retry_key(1), 1UL, 2000, retry_gate) {
    Err(@delivery.AlreadyAcked) => assert_eq(true, true)
    _ => fail("expected AlreadyAcked from a late timeout")
  }
  // WP-04.04 wires Terminal/Poison to the DLQ write; until then they are
  // refused instead of half-implemented.
  match machine.begin_delivery(disk, retry_key(2), 7, 1000, retry_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      retry_key(2),
      2UL,
      @delivery.Terminal,
      2000,
      retry_gate,
    ) {
    Err(@delivery.InvalidTransition) => assert_eq(true, true)
    _ => fail("expected Terminal to be refused until WP-04.04")
  }
  // The fenced delivery's NACK is STALE_OWNER, its sibling rule to ACK.
  match
    machine.on_ownership_changed(disk, 1, 1, 0, 55, 7, 9, 3, 4, 2500, gate) {
    Ok(_) => ()
    Err(_) => fail("on_ownership_changed failed")
  }
  match
    machine.nack(
      disk,
      rng,
      retry_key(2),
      2UL,
      @delivery.Retry,
      3000,
      retry_gate,
    ) {
    Err(@delivery.StaleOwner) => assert_eq(true, true)
    _ => fail("expected StaleOwner for the fenced delivery's NACK")
  }
}

///|
async test "recover restores a pending retry from the durable event" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = retry_machine(path)
  let rng = @harness.SplitMix64::new(9UL)
  let bundle = match
    machine.begin_delivery(disk, retry_key(1), 7, 1000, retry_gate) {
    Ok(bundle) => bundle
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      retry_key(1),
      bundle.delivery_id,
      @delivery.Retry,
      2000,
      retry_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let recovered = match @delivery.DeliveryMachine::recover(disk, 1, 0, writer) {
    Ok(machine) => machine
    Err(_) => fail("recover failed")
  }
  assert_eq(recovered.state_of(retry_key(1)), Some(@delivery.RetryScheduled(1)))
  match recovered.begin_delivery(disk, retry_key(1), 9, 3000, retry_gate) {
    Ok(next) => {
      assert_eq(next.delivery_id, 2UL)
      assert_eq(next.attempt, 2)
    }
    Err(_) => fail("redelivery after recover failed")
  }
}

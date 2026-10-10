/// Exercise the frozen retry timer queue and the L4 restart consistency
/// rule (WP-04.06): timers are rebuilt from the ledger, nothing ghost or
/// half-state survives a restart.

///|
fn t_gate(_bytes : Int) -> Result[Unit, @delivery.DeliveryError] {
  Ok(())
}

///|
fn t_key(sequence : UInt64) -> @delivery.DeliveryKey {
  @delivery.DeliveryKey::new(group_id=1, topic_id=1, partition=0, sequence~)
}

///|
fn t_machine(path : Bytes) -> @delivery.DeliveryMachine raise {
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  @delivery.DeliveryMachine::new(1, 0, writer)
}

///|
async fn t_recover(
  disk : @harness.FakeDisk,
  path : Bytes,
) -> @delivery.DeliveryMachine {
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  match @delivery.DeliveryMachine::recover(disk, 1, 0, writer) {
    Ok(machine) => machine
    Err(_) => fail("recover failed")
  }
}

///|
fn sorted_keys(keys : Array[@delivery.DeliveryKey]) -> Array[UInt64] {
  let sequences : Array[UInt64] = []
  for key in keys {
    sequences.push(key.sequence)
  }
  sequences
}

///|
test "timers pop in the frozen composite order" {
  let timers = @delivery.RetryTimers::new()
  // Same due tick: order falls through to topic, partition, group, seq.
  let a = @delivery.DeliveryKey::new(
    group_id=1,
    topic_id=1,
    partition=0,
    sequence=5,
  )
  let b = @delivery.DeliveryKey::new(
    group_id=1,
    topic_id=1,
    partition=0,
    sequence=2,
  )
  let c = @delivery.DeliveryKey::new(
    group_id=2,
    topic_id=1,
    partition=0,
    sequence=9,
  )
  let d = @delivery.DeliveryKey::new(
    group_id=1,
    topic_id=1,
    partition=1,
    sequence=1,
  )
  timers.schedule(100UL, a)
  timers.schedule(100UL, b)
  timers.schedule(100UL, c)
  timers.schedule(100UL, d)
  // A later tick sorts last regardless of its key.
  timers.schedule(50UL, c)
  assert_eq(timers.pending_count(), 5)
  assert_eq(timers.next_due_tick(), Some(50UL))
  let popped = timers.due(200UL)
  assert_eq(popped.length(), 5)
  // (50, t1,p0,g2,s9) then the four (100, ...) in composite order.
  assert_eq(popped[0].sequence, 9UL)
  assert_eq(popped[1].sequence, 2UL)
  assert_eq(popped[2].sequence, 5UL)
  assert_eq(popped[3].sequence, 9UL)
  assert_eq(popped[3].group_id, 2)
  assert_eq(popped[4].sequence, 1UL)
  assert_eq(popped[4].partition, 1)
  assert_eq(timers.pending_count(), 0)
  assert_eq(timers.next_due_tick(), None)
}

///|
test "due pops only matured timers and honours the tick boundary" {
  let timers = @delivery.RetryTimers::new()
  timers.schedule(100UL, t_key(1))
  timers.schedule(200UL, t_key(2))
  assert_eq(sorted_keys(timers.due(99UL)).length(), 0)
  // The boundary is inclusive: due_tick == now pops.
  assert_eq(sorted_keys(timers.due(100UL)), [1UL])
  assert_eq(timers.pending_count(), 1)
  assert_eq(sorted_keys(timers.due(200UL)), [2UL])
}

///|
async test "a pending backoff keeps its remainder across a restart" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = t_machine(path)
  let rng = @harness.SplitMix64::new(7UL)
  let bundle = match machine.begin_delivery(disk, t_key(1), 7, 1000, t_gate) {
    Ok(bundle) => bundle
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      t_key(1),
      bundle.delivery_id,
      @delivery.DeliveryOutcome::Retry,
      1000,
      t_gate,
    ) {
    Ok(@delivery.Scheduled(_, delay_ms)) =>
      assert_eq(delay_ms >= 1000 && delay_ms <= 1250, true)
    _ => fail("expected a retry schedule")
  }
  let recovered = t_recover(disk, path)
  assert_eq(recovered.state_of(t_key(1)), Some(@delivery.RetryScheduled(1)))
  // Restart at wall 1500 (mid-backoff): the journaled due was
  // 1000 + delay_ms in [2000, 2250], so the rebuilt remainder is
  // [500, 750] on top of the restart tick.
  let timers = recovered.rebuild_timers(
    5000UL,
    1500UL,
    @harness.SplitMix64::new(1UL),
  )
  assert_eq(timers.pending_count(), 1)
  match timers.next_due_tick() {
    Some(due) => {
      assert_eq(due >= 5500UL, true)
      assert_eq(due <= 5750UL, true)
    }
    None => fail("expected one rebuilt timer")
  }
}

///|
async test "restart rebuilds pending retries and keeps the ledger consistent (L4)" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = t_machine(path)
  let rng = @harness.SplitMix64::new(3UL)
  // Sequence 1: acked (must never ghost).
  match machine.begin_delivery(disk, t_key(1), 7, 1000, t_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match machine.ack(disk, t_key(1), 1UL, 1500, t_gate) {
    Ok(_) => ()
    Err(_) => fail("ack failed")
  }
  // Sequence 2: in flight at the crash (restart policy applies).
  match machine.begin_delivery(disk, t_key(2), 7, 1000, t_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  // Sequence 3: waiting out its backoff.
  match machine.begin_delivery(disk, t_key(3), 7, 1000, t_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      t_key(3),
      3UL,
      @delivery.DeliveryOutcome::Retry,
      1000,
      t_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  // Sequence 4: fenced away from its owner.
  match machine.begin_delivery(disk, t_key(4), 7, 1000, t_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.on_ownership_changed(disk, 1, 1, 0, 55, 7, 9, 3, 4, 1500, t_gate) {
    Ok(_) => ()
    Err(_) => fail("on_ownership_changed failed")
  }
  // Sequence 5: budget spent.
  let mut round = 0
  while round < 5 {
    let bundle = match machine.begin_delivery(disk, t_key(5), 7, 1000, t_gate) {
      Ok(bundle) => bundle
      Err(_) => fail("begin_delivery failed")
    }
    match
      machine.nack(
        disk,
        rng,
        t_key(5),
        bundle.delivery_id,
        @delivery.DeliveryOutcome::Retry,
        1000,
        t_gate,
      ) {
      Ok(_) => ()
      Err(_) => fail("nack failed")
    }
    round = round + 1
  }
  // Crash and rebuild.
  let recovered = t_recover(disk, path)
  assert_eq(recovered.state_of(t_key(1)), Some(@delivery.Acked))
  assert_eq(recovered.state_of(t_key(2)), Some(@delivery.RetryScheduled(1)))
  assert_eq(recovered.state_of(t_key(3)), Some(@delivery.RetryScheduled(1)))
  assert_eq(recovered.state_of(t_key(4)), Some(@delivery.RetryScheduled(1)))
  assert_eq(recovered.state_of(t_key(5)), Some(@delivery.DeadLetterQueued))
  let timers = recovered.rebuild_timers(
    5000UL,
    1500UL,
    @harness.SplitMix64::new(11UL),
  )
  // Exactly one timer per redeliverable entry; never for acked or
  // dead-lettered ones (the no-ghost rule is structural).
  assert_eq(timers.pending_count(), 3)
  assert_eq(sorted_keys(timers.due(4999UL)).length(), 0)
  let popped = timers.due(7000UL)
  // Exactly the redeliverable set {2, 3, 4} in some tick order (their
  // jittered dues overlap); composite pop order is pinned in test one.
  assert_eq(popped.length(), 3)
  let mut total = 0UL
  for key in popped {
    assert_eq(key.sequence >= 2UL && key.sequence <= 4UL, true)
    total = total + key.sequence
  }
  assert_eq(total, 9UL)
  assert_eq(timers.pending_count(), 0)
  // Re-recovery is a fixed point: the same states fold again.
  let again = t_recover(disk, path)
  assert_eq(again.state_of(t_key(1)), Some(@delivery.Acked))
  assert_eq(again.state_of(t_key(2)), Some(@delivery.RetryScheduled(1)))
  assert_eq(again.state_of(t_key(5)), Some(@delivery.DeadLetterQueued))
}

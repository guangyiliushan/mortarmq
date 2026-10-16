/// Exercise the per-partition delivery state machine: DELIVER/ACK semantics,
/// owner fencing, and the kill-injection idempotency around the ACK
/// flush boundary.

///|
fn key(sequence : UInt64) -> @delivery.DeliveryKey {
  @delivery.DeliveryKey::new(group_id=1, topic_id=1, partition=0, sequence~)
}

///|
fn open_machine(path : Bytes) -> @delivery.DeliveryMachine raise {
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  @delivery.DeliveryMachine::new(1, 0, writer)
}

///|
async test "DELIVER/ACK lands once and reports the wire bundle" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = open_machine(path)
  match machine.begin_delivery(disk, key(1), 7, 1000, None) {
    Ok(bundle) => {
      assert_eq(bundle.delivery_id, 1UL)
      assert_eq(bundle.attempt, 1)
      assert_eq(bundle.owner_conn, 7UL)
    }
    Err(_) => fail("begin_delivery failed")
  }
  assert_eq(machine.state_of(key(1)), Some(@delivery.Delivering(1UL, 7UL, 1)))
  match machine.ack(disk, key(1), 1UL, 2000, None) {
    Ok(result) => assert_eq(result, @delivery.Applied)
    Err(_) => fail("ack failed")
  }
  assert_eq(machine.state_of(key(1)), Some(@delivery.Acked))
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => {
      let events = scan.events
      assert_eq(events.length(), 2)
      assert_eq(events[0].event, @delivery.Deliver)
      assert_eq(events[0].delivery_id, 1UL)
      assert_eq(events[0].attempt, 1)
      assert_eq(events[1].event, @delivery.Ack)
      assert_eq(events[1].delivery_id, 1UL)
    }
    Err(_) => fail("ledger scan failed")
  }
  // A key for another partition is a programming error.
  let foreign = @delivery.DeliveryKey::new(
    group_id=1,
    topic_id=1,
    partition=1,
    sequence=1,
  )
  match machine.begin_delivery(disk, foreign, 7, 3000, None) {
    Err(@delivery.InvalidTransition) => assert_eq(true, true)
    _ => fail("expected foreign-partition key rejection")
  }
}

///|
async test "duplicate ACK is idempotent and acked entries never redeliver" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = open_machine(path)
  match machine.begin_delivery(disk, key(1), 7, 1000, None) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match machine.ack(disk, key(1), 1UL, 2000, None) {
    Ok(_) => ()
    Err(_) => fail("ack failed")
  }
  // The no-ghost rule: an acked message must never deliver again.
  match machine.begin_delivery(disk, key(1), 9, 3000, None) {
    Err(@delivery.InvalidTransition) => assert_eq(true, true)
    _ => fail("expected ghost-delivery refusal")
  }
  // Fault 7: a client retry of a durable ACK answers Duplicate.
  match machine.ack(disk, key(1), 1UL, 4000, None) {
    Ok(@delivery.Duplicate) => assert_eq(true, true)
    _ => fail("expected duplicate ACK")
  }
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => assert_eq(scan.events.length(), 2)
    Err(_) => fail("ledger scan failed")
  }
}

///|
async test "ACK with a stale delivery_id is UNKNOWN_DELIVERY and writes nothing" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = open_machine(path)
  match machine.begin_delivery(disk, key(1), 7, 1000, None) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match machine.ack(disk, key(1), 99UL, 2000, None) {
    Err(@delivery.UnknownDelivery) => assert_eq(true, true)
    _ => fail("expected UNKNOWN_DELIVERY")
  }
  assert_eq(machine.state_of(key(1)), Some(@delivery.Delivering(1UL, 7UL, 1)))
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => assert_eq(scan.events.length(), 1)
    Err(_) => fail("ledger scan failed")
  }
}

///|
async test "ownership change fences in-flight deliveries and remembers the id" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = open_machine(path)
  match machine.begin_delivery(disk, key(1), 7, 1000, None) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match machine.begin_delivery(disk, key(2), 9, 1500, None) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match machine.ack(disk, key(2), 2UL, 1800, None) {
    Ok(_) => ()
    Err(_) => fail("ack failed")
  }
  // Fence owner 7 away: sequence 1 in flight, sequence 2 already acked.
  match
    machine.on_ownership_changed(disk, 1, 1, 0, 55, 7, 9, 3, 4, 2000, None) {
    Ok(_) => ()
    Err(_) => fail("on_ownership_changed failed")
  }
  assert_eq(machine.state_of(key(1)), Some(@delivery.RetryScheduled(1)))
  assert_eq(machine.state_of(key(2)), Some(@delivery.Acked))
  // The fenced delivery's late ACK is STALE_OWNER, and the id is
  // remembered even across redelivery.
  match machine.ack(disk, key(1), 1UL, 3000, None) {
    Err(@delivery.StaleOwner) => assert_eq(true, true)
    _ => fail("expected STALE_OWNER")
  }
  match machine.begin_delivery(disk, key(1), 9, 4000, None) {
    Ok(bundle) => {
      assert_eq(bundle.delivery_id, 3UL)
      assert_eq(bundle.attempt, 2)
      assert_eq(bundle.owner_conn, 9UL)
    }
    Err(_) => fail("redelivery to the new owner failed")
  }
  match machine.ack(disk, key(1), 1UL, 5000, None) {
    Err(@delivery.StaleOwner) => assert_eq(true, true)
    _ => fail("expected the fenced id to stay STALE_OWNER after redelivery")
  }
  match machine.ack(disk, key(1), 3UL, 6000, None) {
    Ok(@delivery.Applied) => assert_eq(true, true)
    _ => fail("expected the new owner's ACK to apply")
  }
  // The fence wrote one durable FENCED event before any in-memory effect.
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => {
      let events = scan.events
      // The fence event is journaled before the redelivery that follows
      // it.
      assert_eq(events.length(), 6)
      assert_eq(events[3].event, @delivery.Fenced)
      assert_eq(events[3].sequence, 1UL)
      assert_eq(events[3].delivery_id, 1UL)
      assert_eq(events[3].owner_conn, 7UL)
    }
    Err(_) => fail("ledger scan failed")
  }
}

///|
/// Run the crash-injection scenario around the ACK flush boundary and return the final
/// durable events. The client retried each op after a kill; when the ACK
/// retry answered `UnknownDelivery` (the ACK never became durable and the
/// restart policy made the entry redeliverable) the client redelivered.
async fn run_l4_case(kill_at : Int) -> Array[@delivery.LedgerEvent] {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  if kill_at > 0 {
    disk.set_kill_at(kill_at)
  }
  let mut machine = open_machine(path)
  // op 1: begin_delivery.
  let mut delivered = match
    machine.begin_delivery(disk, key(1), 7, 1000, None) {
    Ok(bundle) => bundle
    Err(@delivery.DeliveryError::DiskFault(@harness.Killed)) => {
      disk.set_kill_at(0)
      machine = match
        @delivery.DeliveryMachine::recover(
          disk,
          1,
          0,
          match @delivery.LedgerWriter::new(path) {
            Ok(writer) => writer
            Err(_) => fail("writer construction failed")
          },
        ) {
        Ok(machine) => machine
        Err(_) => fail("recover failed")
      }
      match machine.begin_delivery(disk, key(1), 7, 1000, None) {
        Ok(bundle) => bundle
        Err(_) => fail("begin_delivery retry failed")
      }
    }
    Err(_) => fail("begin_delivery failed")
  }
  // op 2: ack -- on kill the retry may be a no-op and the client redelivers.
  let acked = match
    machine.ack(disk, key(1), delivered.delivery_id, 2000, None) {
    Ok(_) => true
    Err(@delivery.DeliveryError::DiskFault(@harness.Killed)) => {
      disk.set_kill_at(0)
      machine = match
        @delivery.DeliveryMachine::recover(
          disk,
          1,
          0,
          match @delivery.LedgerWriter::new(path) {
            Ok(writer) => writer
            Err(_) => fail("writer construction failed")
          },
        ) {
        Ok(machine) => machine
        Err(_) => fail("recover failed")
      }
      match machine.ack(disk, key(1), delivered.delivery_id, 2000, None) {
        Ok(_) => true
        Err(@delivery.UnknownDelivery) => {
          delivered = match
            machine.begin_delivery(disk, key(1), 9, 3000, None) {
            Ok(bundle) => bundle
            Err(_) => fail("redelivery failed")
          }
          match machine.ack(disk, key(1), delivered.delivery_id, 4000, None) {
            Ok(_) => true
            Err(_) => fail("redelivery ACK failed")
          }
        }
        Err(_) => fail("ACK retry failed")
      }
    }
    Err(_) => fail("ack failed")
  }
  if !acked {
    fail("scenario ended without a durable ACK")
  }
  // op 3: the flush itself.
  match machine.sync(disk) {
    Ok(_) => ()
    Err(@delivery.DeliveryError::DiskFault(@harness.Killed)) => {
      disk.set_kill_at(0)
      machine = match
        @delivery.DeliveryMachine::recover(
          disk,
          1,
          0,
          match @delivery.LedgerWriter::new(path) {
            Ok(writer) => writer
            Err(_) => fail("writer construction failed")
          },
        ) {
        Ok(machine) => machine
        Err(_) => fail("recover failed")
      }
      match machine.sync(disk) {
        Ok(_) => ()
        Err(_) => fail("sync retry failed")
      }
    }
    Err(_) => fail("sync failed")
  }
  // Every case must show the no-ghost rule.
  match machine.begin_delivery(disk, key(1), 11, 5000, None) {
    Err(@delivery.InvalidTransition) => ()
    _ => fail("expected ghost-delivery refusal after recovery")
  }
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => scan.events
    Err(_) => fail("ledger scan failed")
  }
}

///|
async test "kill injection before and after the ACK flush is idempotent" {
  // No kill and kills at the two writes and at the flush: the write-kill
  // cases retry cleanly and converge on the identical durable history.
  let baseline = run_l4_case(0)
  assert_eq(baseline.length(), 2)
  assert_eq(baseline[0].event, @delivery.Deliver)
  assert_eq(baseline[0].delivery_id, 1UL)
  assert_eq(baseline[0].attempt, 1)
  assert_eq(baseline[1].event, @delivery.Ack)
  assert_eq(baseline[1].delivery_id, 1UL)
  let kill_begin = run_l4_case(1)
  assert_eq(kill_begin.length(), 2)
  assert_eq(kill_begin[0], baseline[0])
  assert_eq(kill_begin[1], baseline[1])
  // The flush kill lands after the ACK write, so the durable history is the
  // baseline as well: "ACK durable, OK lost" answers the retry Duplicate.
  let kill_flush = run_l4_case(3)
  assert_eq(kill_flush.length(), 2)
  assert_eq(kill_flush[0], baseline[0])
  assert_eq(kill_flush[1], baseline[1])
  // The ACK-write kill is the "flush before" side: the ACK never became
  // durable, so the retry no-ops and the message redelivers with one extra
  // attempt -- exactly one ACK ever lands and billing is attempt-only.
  let kill_ack = run_l4_case(2)
  assert_eq(kill_ack.length(), 3)
  assert_eq(kill_ack[0], baseline[0])
  assert_eq(kill_ack[1].event, @delivery.Deliver)
  assert_eq(kill_ack[1].delivery_id, 2UL)
  assert_eq(kill_ack[1].attempt, 2)
  assert_eq(kill_ack[2].event, @delivery.Ack)
  assert_eq(kill_ack[2].delivery_id, 2UL)
}

///|
async test "recover folds the log and applies the restart policy" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = open_machine(path)
  match machine.begin_delivery(disk, key(1), 7, 1000, None) {
    Ok(bundle) => assert_eq(bundle.delivery_id, 1UL)
    Err(_) => fail("begin_delivery failed")
  }
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let recovered = match @delivery.DeliveryMachine::recover(disk, 1, 0, writer) {
    Ok(machine) => machine
    Err(_) => fail("recover failed")
  }
  // Frozen restart policy: Delivering becomes redeliverable; its late ACK
  // is a no-op and the redelivery bills exactly one more attempt.
  assert_eq(recovered.state_of(key(1)), Some(@delivery.RetryScheduled(1)))
  match recovered.ack(disk, key(1), 1UL, 2000, None) {
    Err(@delivery.UnknownDelivery) => assert_eq(true, true)
    _ => fail("expected UNKNOWN_DELIVERY after restart")
  }
  match recovered.begin_delivery(disk, key(1), 9, 3000, None) {
    Ok(bundle) => {
      assert_eq(bundle.delivery_id, 2UL)
      assert_eq(bundle.attempt, 2)
    }
    Err(_) => fail("redelivery after restart failed")
  }
}

///|
/// Durable-first by construction: the wire bundle exists only after the
/// DELIVER event is on disk, so an emit-after-return executor cannot
/// send what the ledger has not recorded.
async test "the delivery bundle is returned only after the durable write" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  disk.set_kill_at(1)
  let machine = open_machine(path)
  // Kill at the DELIVER write: no bundle exists, so nothing can be
  // emitted before it is durable.
  match machine.begin_delivery(disk, key(1), 7, 1000, None) {
    Err(@delivery.DeliveryError::DiskFault(@harness.Killed)) =>
      assert_eq(true, true)
    _ => fail("expected the kill at the DELIVER write")
  }
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => assert_eq(scan.events.length(), 0)
    Err(@delivery.LedgerFault::DiskFault(@harness.PathMissing)) =>
      assert_eq(true, true)
    Err(_) => fail("unexpected ledger scan outcome")
  }
  // The retried bundle implies the event: the log already holds it.
  disk.set_kill_at(0)
  match machine.begin_delivery(disk, key(1), 7, 1000, None) {
    Ok(bundle) => assert_eq(bundle.delivery_id, 1UL)
    Err(_) => fail("begin_delivery retry failed")
  }
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) => {
      assert_eq(scan.events.length(), 1)
      assert_eq(scan.events[0].event, @delivery.Deliver)
    }
    Err(_) => fail("ledger scan failed")
  }
}

///|
/// Drive one delivery to the final attempt, fence it through an
/// ownership change, and answer the fenced owner's late ACK and NACK:
/// both must name StaleOwner (0x0022) -- the parked entry remembers the
/// fenced delivery id, which is what routes the old owner to re-SUB
/// instead of into the dead-letter refusal.
async test "a fenced final attempt answers late ack and nack with StaleOwner" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = open_machine(path)
  let rng = @harness.SplitMix64::new(4UL)
  let mut round = 0
  let mut last_id = 0UL
  while round < 5 {
    let bundle = match machine.begin_delivery(disk, key(1), 7, 1000, None) {
      Ok(bundle) => bundle
      Err(_) => fail("begin_delivery failed")
    }
    last_id = bundle.delivery_id
    if round < 4 {
      match
        machine.nack(
          disk,
          rng,
          key(1),
          bundle.delivery_id,
          @delivery.DeliveryOutcome::Retry,
          1000,
          None,
        ) {
        Ok(_) => ()
        Err(_) => fail("nack failed")
      }
    }
    round = round + 1
  }
  match
    machine.on_ownership_changed(disk, 1, 1, 0, 55, 7, 9, 3, 4, 2000, None) {
    Ok(_) => ()
    Err(_) => fail("on_ownership_changed failed")
  }
  match machine.ack(disk, key(1), last_id, 3000, None) {
    Err(@delivery.StaleOwner) => assert_eq(true, true)
    _ => fail("expected StaleOwner for the late ack")
  }
  match
    machine.nack(
      disk,
      rng,
      key(1),
      last_id,
      @delivery.DeliveryOutcome::Retry,
      3000,
      None,
    ) {
    Err(@delivery.StaleOwner) => assert_eq(true, true)
    _ => fail("expected StaleOwner for the late nack")
  }
}

///|
/// The fenced terminal journaling fails mid-flow (kill injection on the
/// NACK_TERMINAL write): the FENCED event is durable, so the in-memory
/// entry already carries the fence and the old owner's late ACK answers
/// StaleOwner instead of landing as Applied behind the fence.
async test "a late ack during the fenced terminal journaling answers StaleOwner" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = open_machine(path)
  let rng = @harness.SplitMix64::new(4UL)
  let mut round = 0
  let mut last_id = 0UL
  while round < 5 {
    let bundle = match machine.begin_delivery(disk, key(1), 7, 1000, None) {
      Ok(bundle) => bundle
      Err(_) => fail("begin_delivery failed")
    }
    last_id = bundle.delivery_id
    if round < 4 {
      match
        machine.nack(
          disk,
          rng,
          key(1),
          bundle.delivery_id,
          @delivery.DeliveryOutcome::Retry,
          1000,
          None,
        ) {
        Ok(_) => ()
        Err(_) => fail("nack failed")
      }
    }
    round = round + 1
  }
  // Nine journal writes so far; the FENCED write is op 10 and the
  // NACK_TERMINAL write is op 11, so the kill lands exactly between
  // them.
  disk.set_kill_at(11)
  match
    machine.on_ownership_changed(disk, 1, 1, 0, 55, 7, 9, 3, 4, 2000, None) {
    Err(@delivery.DiskFault(_)) => assert_eq(true, true)
    _ => fail("expected the injected terminal-write failure")
  }
  match machine.ack(disk, key(1), last_id, 3000, None) {
    Err(@delivery.StaleOwner) => assert_eq(true, true)
    _ => fail("expected StaleOwner in the fenced mid-window")
  }
}

///|
/// The waterline is a conclusion of the log: recovery rebuilds it from
/// the folded entries and prunes the acked prefix, so a fenced late ACK
/// answered Duplicate before the restart stays Duplicate after it.
async test "recovery rebuilds the acked prefix and its answers" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = open_machine(path)
  for sequence in [0UL, 1UL, 2UL] {
    match machine.begin_delivery(disk, key(sequence), 7, 1000, None) {
      Ok(_) => ()
      Err(_) => fail("begin_delivery failed")
    }
  }
  match machine.ack(disk, key(0), 1UL, 1500, None) {
    Ok(@delivery.Applied) => assert_eq(true, true)
    _ => fail("the seq-0 ack failed")
  }
  match machine.ack(disk, key(1), 2UL, 1500, None) {
    Ok(@delivery.Applied) => assert_eq(true, true)
    _ => fail("the seq-1 ack failed")
  }
  assert_eq(machine.acked_watermark(1), 2UL)
  // Restart: the fold rebuilds the prefix from the journal and prunes it.
  let writer2 = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let restarted = match
    @delivery.DeliveryMachine::recover(disk, 1, 0, writer2) {
    Ok(machine) => machine
    Err(_) => fail("recover failed")
  }
  assert_eq(restarted.acked_watermark(1), 2UL)
  assert_eq(restarted.state_of(key(0)), Some(@delivery.Acked))
  assert_eq(restarted.state_of(key(1)), Some(@delivery.Acked))
  assert_eq(restarted.state_of(key(2)), Some(@delivery.RetryScheduled(1)))
  // The pruned prefix answers the same after the restart as before it.
  match restarted.ack(disk, key(0), 1UL, 2000, None) {
    Ok(@delivery.Duplicate) => assert_eq(true, true)
    _ => fail("the pruned prefix must answer Duplicate after a restart")
  }
  match restarted.begin_delivery(disk, key(0), 9, 2000, None) {
    Err(@delivery.InvalidTransition) => assert_eq(true, true)
    _ => fail("the pruned prefix must refuse a begin after a restart")
  }
}

///|
/// The acked prefix prunes contiguous history from sequence zero: the
/// pruned prefix still answers (duplicate ACK, acked state, refused
/// begin), while an out-of-order ack holds the bound back instead of
/// pruning past a live sequence.
async test "the acked prefix prunes history and keeps answering" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = open_machine(path)
  for sequence in [0UL, 1UL, 2UL, 3UL] {
    match machine.begin_delivery(disk, key(sequence), 7, 1000, None) {
      Ok(_) => ()
      Err(_) => fail("begin_delivery failed")
    }
  }
  // Out of order: seq 1 acks first, but seq 0 is still in flight, so the
  // prefix bound holds and the entry stays. Delivery ids bill in begin
  // order: seq 0 -> 1, seq 1 -> 2, seq 2 -> 3, seq 3 -> 4.
  match machine.ack(disk, key(1), 2UL, 1500, None) {
    Ok(@delivery.Applied) => assert_eq(true, true)
    _ => fail("the out-of-order ack failed")
  }
  assert_eq(machine.acked_watermark(1), 0UL)
  assert_eq(machine.state_of(key(1)), Some(@delivery.Acked))
  // Seq 0 closes the gap: the bound advances across 0 and 1 and the
  // pruned prefix keeps answering.
  match machine.ack(disk, key(0), 1UL, 1600, None) {
    Ok(@delivery.Applied) => assert_eq(true, true)
    _ => fail("the gap-closing ack failed")
  }
  assert_eq(machine.acked_watermark(1), 2UL)
  assert_eq(machine.state_of(key(0)), Some(@delivery.Acked))
  assert_eq(machine.state_of(key(1)), Some(@delivery.Acked))
  match machine.ack(disk, key(0), 1UL, 1700, None) {
    Ok(@delivery.Duplicate) => assert_eq(true, true)
    _ => fail("a pruned prefix must answer Duplicate")
  }
  match machine.begin_delivery(disk, key(0), 7, 1700, None) {
    Err(@delivery.InvalidTransition) => assert_eq(true, true)
    _ => fail("a pruned prefix must refuse a begin")
  }
  // Seq 2 acks: the bound advances to 3, seq 3 stays live.
  match machine.ack(disk, key(2), 3UL, 1800, None) {
    Ok(@delivery.Applied) => assert_eq(true, true)
    _ => fail("the seq-2 ack failed")
  }
  assert_eq(machine.acked_watermark(1), 3UL)
  assert_eq(machine.state_of(key(3)), Some(@delivery.Delivering(4UL, 7UL, 1)))
  let rng = @harness.SplitMix64::new(4UL)
  match
    machine.nack(
      disk,
      rng,
      key(2),
      3UL,
      @delivery.DeliveryOutcome::Retry,
      1800,
      None,
    ) {
    Err(@delivery.AlreadyAcked) => assert_eq(true, true)
    _ => fail("a pruned prefix must answer the already-acked refusal")
  }
}

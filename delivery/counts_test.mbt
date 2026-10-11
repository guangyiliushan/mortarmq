/// Pin the delivery counter surface against real machine state: the
/// conservation identity, the bucket mapping, and the pure-fold oracle
/// the properties drive.

///|
fn cm_key(sequence : UInt64) -> @delivery.DeliveryKey {
  @delivery.DeliveryKey::new(group_id=1, topic_id=1, partition=0, sequence~)
}

///|
fn cm_machine(path : Bytes) -> @delivery.DeliveryMachine raise {
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  @delivery.DeliveryMachine::new(1, 0, writer)
}

///|
fn cm_request(from_dlq_topic : Bool) -> @delivery.DeadLetterRequest {
  {
    from_dlq_topic,
    reason: @delivery.NackReason::Retry,
    source: { producer_id: 3UL, producer_seq: 4UL, key: b"k", value: b"v", },
  }
}

///|
async test "the empty machine reports zeroed counters" {
  let machine = cm_machine(b"data/partitions/0001/0000/delivery.mql")
  assert_eq(machine.counts(1), @delivery.DeliveryCounts::zero())
  assert_eq(machine.counts(1).conserved(), true)
}

///|
async test "the counters partition one group's real states" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = cm_machine(path)
  let rng = @harness.SplitMix64::new(1UL)
  let port = (_bytes : Bytes) => Ok(42UL)
  // Sequence 1: delivered.
  match machine.begin_delivery(disk, cm_key(1), 7, 1000, None) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match machine.ack(disk, cm_key(1), 1UL, 1500, None) {
    Ok(_) => ()
    Err(_) => fail("ack failed")
  }
  // Sequence 2: retained (waiting out a retry).
  match machine.begin_delivery(disk, cm_key(2), 7, 1000, None) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      cm_key(2),
      2UL,
      @delivery.DeliveryOutcome::Retry,
      2000,
      None,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  // Sequence 3: dead-lettered.
  match machine.begin_delivery(disk, cm_key(3), 7, 1000, None) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      cm_key(3),
      3UL,
      @delivery.DeliveryOutcome::Terminal,
      2000,
      None,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  match
    machine.complete_dead_letter(
      disk,
      cm_key(3),
      cm_request(false),
      port,
      2500,
      None,
    ) {
    Ok(_) => ()
    Err(_) => fail("completion failed")
  }
  // Sequence 4: dropped by the loop guard.
  match machine.begin_delivery(disk, cm_key(4), 7, 1000, None) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      cm_key(4),
      4UL,
      @delivery.DeliveryOutcome::Terminal,
      2000,
      None,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  match
    machine.complete_dead_letter(
      disk,
      cm_key(4),
      cm_request(true),
      port,
      2500,
      None,
    ) {
    Ok(_) => ()
    Err(_) => fail("completion failed")
  }
  let counts = machine.counts(1)
  assert_eq(counts.published, 4UL)
  assert_eq(counts.delivered, 1UL)
  assert_eq(counts.retained, 1UL)
  assert_eq(counts.dlq, 1UL)
  assert_eq(counts.dropped, 1UL)
  // Sequence 1 is delivered; sequence 2 is retained, so the floor stops
  // at 1.
  assert_eq(counts.ack_floor, 1UL)
  assert_eq(counts.max_sequence, 4UL)
  assert_eq(counts.lag, 3UL)
  assert_eq(counts.conserved(), true)
  // With a drop in the picture the delivery-side specialization does not
  // claim to hold.
  assert_eq(counts.conserved_without_drop(), false)
  // The pure fold agrees with the machine oracle byte for byte.
  match @delivery.scan_ledger(disk, path) {
    Ok(scan) =>
      assert_eq(
        @delivery.counts_of_events(scan.events, 1, scan.events.length()),
        counts,
      )
    Err(_) => fail("ledger scan failed")
  }
}

///|
async test "the floor only names delivered work" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = cm_machine(path)
  // Sequence 1 retained, sequence 2 delivered: the floor cannot pass 1.
  match machine.begin_delivery(disk, cm_key(1), 7, 1000, None) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match machine.begin_delivery(disk, cm_key(2), 7, 1000, None) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match machine.ack(disk, cm_key(2), 2UL, 1500, None) {
    Ok(_) => ()
    Err(_) => fail("ack failed")
  }
  let counts = machine.counts(1)
  assert_eq(counts.ack_floor, 0UL)
  assert_eq(counts.delivered, 1UL)
  assert_eq(counts.retained, 1UL)
  assert_eq(counts.conserved(), true)
  assert_eq(counts.floor_lag_consistent(), true)
}

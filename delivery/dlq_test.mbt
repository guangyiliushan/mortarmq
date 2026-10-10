/// Exercise the frozen MMDL envelope and the DLQ flow (WP-04.04,
/// REQ-DEL-002): the three loop guards, the durable write order, envelope
/// flattening, and the documented replay blind spot (L1).

///|
fn dlq_gate(_bytes : Int) -> Result[Unit, @delivery.DeliveryError] {
  Ok(())
}

///|
fn dlq_key(sequence : UInt64) -> @delivery.DeliveryKey {
  @delivery.DeliveryKey::new(group_id=1, topic_id=1, partition=0, sequence~)
}

///|
fn dlq_machine(path : Bytes) -> @delivery.DeliveryMachine raise {
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  @delivery.DeliveryMachine::new(1, 0, writer)
}

///|
fn hop(
  topic_id : UInt16,
  partition : UInt16,
  group_id : UInt16,
) -> @delivery.DlqHop {
  @delivery.DlqHop::new(topic_id~, partition~, group_id~)
}

///|
fn source_of(value : Bytes) -> @delivery.DeadLetterSource {
  { producer_id: 3UL, producer_seq: 4UL, key: b"k", value, }
}

///|
fn request_of(
  from_dlq_topic : Bool,
  reason : @delivery.NackReason,
  value : Bytes,
) -> @delivery.DeadLetterRequest {
  { from_dlq_topic, reason, source: source_of(value), }
}

///|
test "MMDL envelope matches the frozen layout vector and round-trips" {
  let envelope = @delivery.MmdlEnvelope::new(
    reason=@delivery.NackReason::Terminal,
    source_topic_id=1,
    source_partition=0,
    source_sequence=100UL,
    source_producer_id=3UL,
    source_producer_seq=4UL,
    consumer_group_id=1,
    attempt=5,
    failed_unix_ms=200UL,
    death_path=[hop(1, 0, 1)],
    original_key=b"k",
    original_value=b"v",
  )
  let expected : Bytes = b"\x4d\x4d\x44\x4c\x01\x01\x01\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x64\x00\x00\x00\x00\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x04\x00\x01\x00\x05\x00\x00\x00\x00\x00\x00\x00\xc8\x01\x00\x01\x00\x00\x00\x01\x00\x01\x6b\x00\x00\x00\x01\x76\x00\xf4\x48\xfb"
  let bytes = match @delivery.encode_mmdl(envelope) {
    Ok(bytes) => bytes
    Err(_) => fail("envelope encoding failed")
  }
  assert_eq(bytes, expected)
  assert_eq(@delivery.is_mmdl(bytes[:]), true)
  assert_eq(@delivery.is_mmdl(b"v"), false)
  match @delivery.decode_mmdl(bytes[:]) {
    Ok(decoded) => {
      assert_eq(decoded.reason, @delivery.NackReason::Terminal)
      assert_eq(decoded.source_topic_id, 1)
      assert_eq(decoded.source_partition, 0)
      assert_eq(decoded.source_sequence, 100UL)
      assert_eq(decoded.source_producer_id, 3UL)
      assert_eq(decoded.source_producer_seq, 4UL)
      assert_eq(decoded.consumer_group_id, 1)
      assert_eq(decoded.attempt, 5)
      assert_eq(decoded.failed_unix_ms, 200UL)
      assert_eq(decoded.death_path.length(), 1)
      assert_eq(decoded.death_path[0], hop(1, 0, 1))
      assert_eq(decoded.original_key, b"k")
      assert_eq(decoded.original_value, b"v")
    }
    Err(_) => fail("envelope decoding failed")
  }
  // CRC corruption and foreign magic are rejected at the trust boundary.
  let corrupted = bytes[:10].to_owned() + b"\xff" + bytes[11:].to_owned()
  match @delivery.decode_mmdl(corrupted[:]) {
    Err(@delivery.DeliveryError::Malformed) => assert_eq(true, true)
    _ => fail("expected CRC corruption rejection")
  }
  match @delivery.decode_mmdl(b"MMQS\x01\x01\x00\x00") {
    Err(@delivery.DeliveryError::Malformed) => assert_eq(true, true)
    _ => fail("expected foreign-magic rejection")
  }
}

///|
async test "dead-letter writes the envelope then terminates the source" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = dlq_machine(path)
  let rng = @harness.SplitMix64::new(1UL)
  match machine.begin_delivery(disk, dlq_key(1), 7, 1000, dlq_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      dlq_key(1),
      1UL,
      @delivery.DeliveryOutcome::Terminal,
      2000,
      dlq_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  assert_eq(machine.state_of(dlq_key(1)), Some(@delivery.DeadLetterQueued(1)))
  let captured = Ref::Ref(b"")
  let port = (bytes : Bytes) => {
    captured.val = bytes
    Ok(42UL)
  }
  match
    machine.complete_dead_letter(
      disk,
      dlq_key(1),
      request_of(false, @delivery.NackReason::Terminal, b"v"),
      port,
      3000,
      dlq_gate,
    ) {
    Ok(@delivery.Enqueued(sequence)) => assert_eq(sequence, 42UL)
    _ => fail("expected the DLQ enqueue")
  }
  // The envelope carries the frozen triple hop and the original payload.
  match @delivery.decode_mmdl(captured.val[:]) {
    Ok(decoded) => {
      assert_eq(decoded.death_path.length(), 1)
      assert_eq(decoded.death_path[0], hop(1, 0, 1))
      assert_eq(decoded.original_key, b"k")
      assert_eq(decoded.original_value, b"v")
      assert_eq(decoded.reason, @delivery.NackReason::Terminal)
    }
    Err(_) => fail("captured envelope decoding failed")
  }
  // Frozen order: NACK_TERMINAL, DLQ_WRITTEN (dlq sequence), SOURCE_TERMINATED.
  match @delivery.read_ledger_events(disk, path) {
    Ok(events) => {
      assert_eq(events.length(), 4)
      assert_eq(events[1].event, @delivery.NackTerminal)
      assert_eq(events[2].event, @delivery.DlqWritten)
      assert_eq(events[2].delivery_id, 42UL)
      assert_eq(events[3].event, @delivery.SourceTerminated)
    }
    Err(_) => fail("ledger scan failed")
  }
  // Completion is idempotent and recover keeps the enqueued state.
  match
    machine.complete_dead_letter(
      disk,
      dlq_key(1),
      request_of(false, @delivery.NackReason::Terminal, b"v"),
      port,
      4000,
      dlq_gate,
    ) {
    Ok(@delivery.Enqueued(sequence)) => assert_eq(sequence, 42UL)
    _ => fail("expected idempotent completion")
  }
  match @delivery.read_ledger_events(disk, path) {
    Ok(events) => assert_eq(events.length(), 4)
    Err(_) => fail("ledger scan failed")
  }
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  match @delivery.DeliveryMachine::recover(disk, 1, 0, writer) {
    Ok(recovered) =>
      assert_eq(
        recovered.state_of(dlq_key(1)),
        Some(@delivery.DeadLetterQueued(1)),
      )
    Err(_) => fail("recover failed")
  }
}

///|
/// A `.dlq` topic is terminal: the loop guard refuses to build `.dlq.dlq`
/// and quarantines instead (defense layer 1).
async test "a .dlq topic never produces a second DLQ (L1 layer 1)" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = dlq_machine(path)
  let rng = @harness.SplitMix64::new(1UL)
  match machine.begin_delivery(disk, dlq_key(1), 7, 1000, dlq_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      dlq_key(1),
      1UL,
      @delivery.DeliveryOutcome::Terminal,
      2000,
      dlq_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  let calls = Ref::Ref(0)
  let port = (_bytes : Bytes) => {
    calls.val = calls.val + 1
    Ok(42UL)
  }
  match
    machine.complete_dead_letter(
      disk,
      dlq_key(1),
      request_of(true, @delivery.NackReason::Terminal, b"v"),
      port,
      3000,
      dlq_gate,
    ) {
    Ok(@delivery.Quarantined) => assert_eq(true, true)
    _ => fail("expected quarantine")
  }
  assert_eq(calls.val, 0)
  assert_eq(machine.state_of(dlq_key(1)), Some(@delivery.Quarantined))
  match @delivery.read_ledger_events(disk, path) {
    Ok(events) => {
      assert_eq(events.length(), 3)
      assert_eq(events[2].event, @delivery.SourceTerminated)
    }
    Err(_) => fail("ledger scan failed")
  }
  match
    machine.complete_dead_letter(
      disk,
      dlq_key(1),
      request_of(true, @delivery.NackReason::Terminal, b"v"),
      port,
      4000,
      dlq_gate,
    ) {
    Err(@delivery.InvalidTransition) => assert_eq(true, true)
    _ => fail("expected completion on a quarantined entry to be refused")
  }
}

///|
/// A replayed envelope whose death path already lists this hop refuses
/// re-entry (defense layer 2): no DLQ record, no loop.
async test "a death path that already lists the hop refuses re-entry (L1 layer 2)" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = dlq_machine(path)
  let rng = @harness.SplitMix64::new(1UL)
  match machine.begin_delivery(disk, dlq_key(1), 7, 1000, dlq_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      dlq_key(1),
      1UL,
      @delivery.DeliveryOutcome::Terminal,
      2000,
      dlq_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  let inner = @delivery.MmdlEnvelope::new(
    reason=@delivery.NackReason::Retry,
    source_topic_id=1,
    source_partition=0,
    source_sequence=1UL,
    source_producer_id=3UL,
    source_producer_seq=4UL,
    consumer_group_id=1,
    attempt=5,
    failed_unix_ms=200UL,
    death_path=[hop(1, 0, 1)],
    original_key=b"ik",
    original_value=b"iv",
  )
  let replayed = match @delivery.encode_mmdl(inner) {
    Ok(bytes) => bytes
    Err(_) => fail("envelope encoding failed")
  }
  let calls = Ref::Ref(0)
  let port = (_bytes : Bytes) => {
    calls.val = calls.val + 1
    Ok(42UL)
  }
  match
    machine.complete_dead_letter(
      disk,
      dlq_key(1),
      request_of(false, @delivery.NackReason::Terminal, replayed),
      port,
      3000,
      dlq_gate,
    ) {
    Ok(@delivery.Quarantined) => assert_eq(true, true)
    _ => fail("expected quarantine")
  }
  assert_eq(calls.val, 0)
  assert_eq(machine.state_of(dlq_key(1)), Some(@delivery.Quarantined))
}

///|
/// A death path at the frozen bound of 8 hops reports DLQ_PATH_OVERFLOW
/// (0x0030) after quarantining (defense layer 3).
async test "an eight-hop death path reports DLQ_PATH_OVERFLOW (L1 layer 3)" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = dlq_machine(path)
  let rng = @harness.SplitMix64::new(1UL)
  match machine.begin_delivery(disk, dlq_key(1), 7, 1000, dlq_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      dlq_key(1),
      1UL,
      @delivery.DeliveryOutcome::Terminal,
      2000,
      dlq_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  let hops = [
    hop(2, 0, 1),
    hop(3, 0, 1),
    hop(4, 0, 1),
    hop(5, 0, 1),
    hop(6, 0, 1),
    hop(7, 0, 1),
    hop(8, 0, 1),
    hop(9, 0, 1),
  ]
  let inner = @delivery.MmdlEnvelope::new(
    reason=@delivery.NackReason::Retry,
    source_topic_id=1,
    source_partition=0,
    source_sequence=1UL,
    source_producer_id=3UL,
    source_producer_seq=4UL,
    consumer_group_id=1,
    attempt=5,
    failed_unix_ms=200UL,
    death_path=hops,
    original_key=b"ik",
    original_value=b"iv",
  )
  let replayed = match @delivery.encode_mmdl(inner) {
    Ok(bytes) => bytes
    Err(_) => fail("envelope encoding failed")
  }
  let calls = Ref::Ref(0)
  let port = (_bytes : Bytes) => {
    calls.val = calls.val + 1
    Ok(42UL)
  }
  match
    machine.complete_dead_letter(
      disk,
      dlq_key(1),
      request_of(false, @delivery.NackReason::Terminal, replayed),
      port,
      3000,
      dlq_gate,
    ) {
    Err(@delivery.DeliveryError::DlqPathOverflow) => assert_eq(true, true)
    _ => fail("expected DLQ_PATH_OVERFLOW")
  }
  assert_eq(calls.val, 0)
  assert_eq(machine.state_of(dlq_key(1)), Some(@delivery.Quarantined))
}

///|
/// Envelopes never nest: a replayed envelope is flattened into the new
/// one's original payload and extended death path. A raw replayed payload
/// is the documented blind spot and restarts the path at hop one.
async test "replayed envelopes flatten and raw replays restart the path" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = dlq_machine(path)
  let rng = @harness.SplitMix64::new(1UL)
  // Flattened case: one foreign hop inside the replayed envelope.
  match machine.begin_delivery(disk, dlq_key(1), 7, 1000, dlq_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      dlq_key(1),
      1UL,
      @delivery.DeliveryOutcome::Terminal,
      2000,
      dlq_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  let inner = @delivery.MmdlEnvelope::new(
    reason=@delivery.NackReason::Retry,
    source_topic_id=2,
    source_partition=3,
    source_sequence=9UL,
    source_producer_id=3UL,
    source_producer_seq=4UL,
    consumer_group_id=1,
    attempt=2,
    failed_unix_ms=200UL,
    death_path=[hop(2, 3, 1)],
    original_key=b"ik",
    original_value=b"iv",
  )
  let replayed = match @delivery.encode_mmdl(inner) {
    Ok(bytes) => bytes
    Err(_) => fail("envelope encoding failed")
  }
  let captured = Ref::Ref(b"")
  let port = (bytes : Bytes) => {
    captured.val = bytes
    Ok(42UL)
  }
  match
    machine.complete_dead_letter(
      disk,
      dlq_key(1),
      request_of(false, @delivery.NackReason::Terminal, replayed),
      port,
      3000,
      dlq_gate,
    ) {
    Ok(@delivery.Enqueued(_)) => ()
    _ => fail("expected the DLQ enqueue")
  }
  match @delivery.decode_mmdl(captured.val[:]) {
    Ok(decoded) => {
      assert_eq(decoded.death_path.length(), 2)
      assert_eq(decoded.death_path[0], hop(2, 3, 1))
      assert_eq(decoded.death_path[1], hop(1, 0, 1))
      assert_eq(decoded.original_key, b"ik")
      assert_eq(decoded.original_value, b"iv")
    }
    Err(_) => fail("captured envelope decoding failed")
  }
  // Blind spot (honest boundary, REQ-DEL-002): a raw payload replay is a
  // fresh message to the broker and restarts the death path.
  match machine.begin_delivery(disk, dlq_key(2), 7, 1000, dlq_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      dlq_key(2),
      2UL,
      @delivery.DeliveryOutcome::Terminal,
      2000,
      dlq_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  match
    machine.complete_dead_letter(
      disk,
      dlq_key(2),
      request_of(false, @delivery.NackReason::Terminal, b"v"),
      port,
      4000,
      dlq_gate,
    ) {
    Ok(@delivery.Enqueued(_)) => ()
    _ => fail("expected the DLQ enqueue")
  }
  match @delivery.decode_mmdl(captured.val[:]) {
    Ok(decoded) => {
      assert_eq(decoded.death_path.length(), 1)
      assert_eq(decoded.death_path[0], hop(1, 0, 1))
      assert_eq(decoded.original_value, b"v")
    }
    Err(_) => fail("captured envelope decoding failed")
  }
}

///|
/// The three dead-letter outcomes fold apart: a pending completion is
/// re-run, an enqueued one is remembered (idempotent), a quarantined one is
/// terminal.
async test "recover folds pending, enqueued, and quarantined dead-letters" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = dlq_machine(path)
  let rng = @harness.SplitMix64::new(1UL)
  let captured = Ref::Ref(b"")
  let port = (bytes : Bytes) => {
    captured.val = bytes
    Ok(42UL)
  }
  // Sequence 1: pending (NACK_TERMINAL only).
  match machine.begin_delivery(disk, dlq_key(1), 7, 1000, dlq_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      dlq_key(1),
      1UL,
      @delivery.DeliveryOutcome::Terminal,
      2000,
      dlq_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  // Sequence 2: fully enqueued.
  match machine.begin_delivery(disk, dlq_key(2), 7, 1000, dlq_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      dlq_key(2),
      2UL,
      @delivery.DeliveryOutcome::Terminal,
      2000,
      dlq_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  match
    machine.complete_dead_letter(
      disk,
      dlq_key(2),
      request_of(false, @delivery.NackReason::Terminal, b"v"),
      port,
      2500,
      dlq_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("completion failed")
  }
  // Sequence 3: quarantined by layer 1.
  match machine.begin_delivery(disk, dlq_key(3), 7, 1000, dlq_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      dlq_key(3),
      3UL,
      @delivery.DeliveryOutcome::Terminal,
      2000,
      dlq_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  match
    machine.complete_dead_letter(
      disk,
      dlq_key(3),
      request_of(true, @delivery.NackReason::Terminal, b"v"),
      port,
      2500,
      dlq_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("completion failed")
  }
  let writer = match @delivery.LedgerWriter::new(path) {
    Ok(writer) => writer
    Err(_) => fail("writer construction failed")
  }
  let recovered = match @delivery.DeliveryMachine::recover(disk, 1, 0, writer) {
    Ok(machine) => machine
    Err(_) => fail("recover failed")
  }
  assert_eq(recovered.state_of(dlq_key(1)), Some(@delivery.DeadLetterQueued(1)))
  assert_eq(recovered.state_of(dlq_key(2)), Some(@delivery.DeadLetterQueued(1)))
  assert_eq(recovered.state_of(dlq_key(3)), Some(@delivery.Quarantined))
  // The remembered DLQ sequence makes the enqueued completion idempotent.
  match
    recovered.complete_dead_letter(
      disk,
      dlq_key(2),
      request_of(false, @delivery.NackReason::Terminal, b"v"),
      port,
      3000,
      dlq_gate,
    ) {
    Ok(@delivery.Enqueued(sequence)) => assert_eq(sequence, 42UL)
    _ => fail("expected the remembered DLQ sequence")
  }
  // The pending one re-runs its completion after recovery (fault 11).
  match
    recovered.complete_dead_letter(
      disk,
      dlq_key(1),
      request_of(false, @delivery.NackReason::Terminal, b"v"),
      port,
      3000,
      dlq_gate,
    ) {
    Ok(@delivery.Enqueued(sequence)) => assert_eq(sequence, 42UL)
    _ => fail("expected the pending completion to re-run")
  }
  // The quarantined one is terminal.
  match
    recovered.complete_dead_letter(
      disk,
      dlq_key(3),
      request_of(true, @delivery.NackReason::Terminal, b"v"),
      port,
      3000,
      dlq_gate,
    ) {
    Err(@delivery.InvalidTransition) => assert_eq(true, true)
    _ => fail("expected quarantined completion to be refused")
  }
}

///|
/// Wire hints are hints: the ledger adjudicates the attempt (the request
/// carries none) and the source coordinates (from the machine's own key),
/// so forged envelope claims cannot move the recorded facts.
async test "forged wire hints are adjudicated by the ledger" {
  let disk = @harness.FakeDisk::new()
  let path = b"data/partitions/0001/0000/delivery.mql"
  let machine = dlq_machine(path)
  let rng = @harness.SplitMix64::new(1UL)
  match machine.begin_delivery(disk, dlq_key(1), 7, 1000, dlq_gate) {
    Ok(_) => ()
    Err(_) => fail("begin_delivery failed")
  }
  match
    machine.nack(
      disk,
      rng,
      dlq_key(1),
      1UL,
      @delivery.DeliveryOutcome::Terminal,
      2000,
      dlq_gate,
    ) {
    Ok(_) => ()
    Err(_) => fail("nack failed")
  }
  // A replayed envelope forged with foreign source coordinates and a
  // foreign death path.
  let forged = @delivery.MmdlEnvelope::new(
    reason=@delivery.NackReason::Poison,
    source_topic_id=99,
    source_partition=9,
    source_sequence=777UL,
    source_producer_id=42UL,
    source_producer_seq=43UL,
    consumer_group_id=9,
    attempt=15,
    failed_unix_ms=999UL,
    death_path=[hop(9, 9, 9)],
    original_key=b"ik",
    original_value=b"iv",
  )
  let replayed = match @delivery.encode_mmdl(forged) {
    Ok(bytes) => bytes
    Err(_) => fail("envelope encoding failed")
  }
  let captured = Ref::Ref(b"")
  let port = (bytes : Bytes) => {
    captured.val = bytes
    Ok(42UL)
  }
  match
    machine.complete_dead_letter(
      disk,
      dlq_key(1),
      request_of(false, @delivery.NackReason::Terminal, replayed),
      port,
      3000,
      dlq_gate,
    ) {
    Ok(@delivery.Enqueued(_)) => ()
    _ => fail("expected the DLQ enqueue")
  }
  match @delivery.decode_mmdl(captured.val[:]) {
    Ok(decoded) => {
      // The ledger's own attempt (1) and source coordinates win over the
      // forged envelope claims (15 / 99 / 9 / 777).
      assert_eq(decoded.attempt, 1)
      assert_eq(decoded.source_topic_id, 1)
      assert_eq(decoded.source_partition, 0)
      assert_eq(decoded.source_sequence, 1UL)
      assert_eq(decoded.consumer_group_id, 1)
      // The forged hop rides along as data; the appended hop is the
      // machine's true triple.
      assert_eq(decoded.death_path.length(), 2)
      assert_eq(decoded.death_path[1], hop(1, 0, 1))
    }
    Err(_) => fail("captured envelope decoding failed")
  }
  // The durable events carry the same ledger-adjudicated attempt.
  match @delivery.read_ledger_events(disk, path) {
    Ok(events) => {
      assert_eq(events.length(), 4)
      assert_eq(events[1].event, @delivery.NackTerminal)
      assert_eq(events[1].attempt, 1)
      assert_eq(events[2].attempt, 1)
      assert_eq(events[3].attempt, 1)
    }
    Err(_) => fail("ledger scan failed")
  }
}

/// The per-partition delivery state machine over the frozen MMLQ event log.
///
/// One `DeliveryMachine` owns exactly one `(topic_id, partition)` ledger and
/// serves every consumer group on it; entries are keyed by `(group_id,
/// sequence)` and every transition appends one durable event before it is
/// visible (WP-04.02, REQ-DEL-001 / REQ-DEL-004). `delivery_id` and `attempt`
/// are assigned here, not by the caller: the checkpoint owns
/// `next_delivery_id`, so the returned `DeliveryAttempt` bundle is exactly
/// what the executor puts on the wire.
///
/// # Stability
///
/// * at-least-once: an in-flight entry refuses a second `begin_delivery`
///   (`InvalidTransition`) until the current delivery resolves; a resolved
///   entry redelivers with a fresh `delivery_id` and `attempt + 1`.
/// * no ghost ACK: an `Acked` entry refuses redelivery forever
///   (`InvalidTransition`) and answers every ACK with `Duplicate`.
/// * kill idempotency: each transition writes its event before mutating
///   memory, so a kill anywhere leaves the on-disk log a well-formed prefix
///   of the operation history. `recover` folds that prefix and then applies
///   the frozen restart policy (`Delivering` becomes redeliverable), so a
///   client retry after a crash is always a harmless no-op or a clean
///   redelivery -- never a half-applied ACK.
/// * owner fencing (Q27/Q29): `on_ownership_changed` is the port method the
///   coordinator calls with eight flat parameters (no shared event record).
///   It durably writes one `FENCED` event per in-flight entry of the old
///   owner (sequences ascending) before any in-memory effect; the fenced
///   delivery id is remembered forever and every late ACK carrying it
///   answers `StaleOwner`, while other stale ids answer `UnknownDelivery`
///   (0x0023). The two-layer fence story: the S7 epoch layer rejects old
///   ownership epochs with 0x0022 before this layer sees the frame; this
///   layer attributes by `delivery_id` alone because the ACK frame carries
///   no owner. The port runs before credit release and waiter wake-up by the
///   frozen consumption order; `subscription_id`, `old_epoch` and
///   `new_epoch` are part of the pinned signature and are intentionally not
///   stored (MMLQ carries no epoch fields).

///|
/// What the executor must send for one delivery instance.
pub(all) struct DeliveryAttempt {
  delivery_id : UInt64
  attempt : UInt16
  owner_conn : UInt64
} derive(Eq, Debug)

///|
pub extend DeliveryAttempt with Eq::{not_equal, equal}

///|
pub extend DeliveryAttempt with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The delivery identity: `(group_id, topic_id, partition, sequence)`. The
/// ledger file lives at the `(topic_id, partition)` path, so a key naming a
/// different partition than the machine is a programming error.
pub(all) struct DeliveryKey {
  group_id : UInt16
  topic_id : UInt16
  partition : UInt16
  sequence : UInt64
} derive(Eq, Debug)

///|
pub extend DeliveryKey with Eq::{not_equal, equal}

///|
pub extend DeliveryKey with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DeliveryKey::new(
  group_id~ : UInt16,
  topic_id~ : UInt16,
  partition~ : UInt16,
  sequence~ : UInt64,
) -> DeliveryKey {
  { group_id, topic_id, partition, sequence, }
}

///|
/// The observable lifecycle of one `(group, sequence)` entry. `Delivering`
/// carries `(delivery_id, owner_conn, attempt)`; `RetryScheduled` carries the
/// attempt count and is created by the restart policy and by retry paths;
/// `DeadLetterQueued` is terminal once the retry budget is spent (the
/// durable DLQ record lands with WP-04.04).
pub(all) enum DeliveryState {
  Delivering(UInt64, UInt64, UInt16)
  Acked
  RetryScheduled(UInt16)
  DeadLetterQueued
  Quarantined
} derive(Eq, Debug)

///|
pub extend DeliveryState with Eq::{not_equal, equal}

///|
pub extend DeliveryState with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The two idempotent answers to `ack`.
pub(all) enum AckResult {
  Applied
  Duplicate
} derive(Eq, Debug)

///|
pub extend AckResult with Eq::{not_equal, equal}

///|
pub extend AckResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The frozen NACK outcome codes (reason 0..3 on the wire). `Slow` is a
/// v0.1 extension kept in the format range. WP-04.02 answers every outcome
/// with `InvalidTransition`; WP-04.04 wires `Terminal`/`Poison` to the DLQ
/// write.
pub(all) enum DeliveryOutcome {
  Retry
  Terminal
  Poison
  Slow
} derive(Eq, Debug)

///|
pub extend DeliveryOutcome with Eq::{not_equal, equal}

///|
pub extend DeliveryOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// What the executor must schedule after a failed delivery. `Scheduled`
/// carries `(attempt, delay_ms)` with the jittered backoff already applied
/// (due times are monotonic ticks owned by the executor); `DeadLettered`
/// carries the final attempt and schedules nothing (WP-04.04 writes the DLQ
/// record on this path).
pub(all) enum RetryPlan {
  Scheduled(UInt16, UInt)
  DeadLettered(UInt16)
} derive(Eq, Debug)

///|
pub extend RetryPlan with Eq::{not_equal, equal}

///|
pub extend RetryPlan with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The frozen retry budget: 1 first delivery + at most 4 redeliveries.
pub const MAX_ATTEMPTS : UInt16 = 5

///|
/// The frozen backoff base (review R5): delay_n = min(30s, 1s * 2^(n-1)).
pub const RETRY_BACKOFF_BASE_MS : UInt = 1000

///|
/// The frozen backoff ceiling, guarding retry storms.
pub const MAX_BACKOFF_MS : UInt = 30000

///|
/// Report delivery-machine failures. `UnknownDelivery` and `StaleOwner` map
/// to 0x0023 and 0x0022 upstream; `InvalidTransition` is an executor logic
/// violation that never reaches the wire as its own code.
pub(all) suberror DeliveryError {
  UnknownDelivery
  StaleOwner
  AlreadyAcked
  AlreadyDeadLettered
  InvalidTransition
  DlqPathOverflow
  Capacity
  Malformed
  DiskFault(@harness.HarnessFault)
} derive(Eq, Debug)

///|
pub extend DeliveryError with Eq::{not_equal, equal}

///|
pub extend DeliveryError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One entry's full record. The state enum is the public projection;
/// `fenced_delivery_id` remembers the fenced delivery instance (0 = never
/// fenced) so its late ACK answers `StaleOwner` for as long as the entry
/// lives. Delivery ids are never reused, so at most the latest fenced id is
/// kept; older fenced ids fall through to the `UnknownDelivery` no-op.
priv struct Entry {
  state : DeliveryState
  fenced_delivery_id : UInt64
  dlq_sequence : UInt64
}

///|
priv struct GroupState {
  entries : Map[UInt64, Entry]
  next_delivery_id : UInt64
}

///|
/// The per-partition delivery machine.
pub(all) struct DeliveryMachine {
  priv topic_id : UInt16
  priv partition : UInt16
  priv writer : LedgerWriter
  priv groups : Map[UInt16, GroupState]
}

///|
pub fn DeliveryMachine::new(
  topic_id : UInt16,
  partition : UInt16,
  writer : LedgerWriter,
) -> DeliveryMachine {
  { topic_id, partition, writer, groups: Map([]), }
}

///|
fn DeliveryMachine::check_key(
  self : DeliveryMachine,
  key : DeliveryKey,
) -> Result[Unit, DeliveryError] {
  if key.topic_id != self.topic_id || key.partition != self.partition {
    return Err(InvalidTransition)
  }
  Ok(())
}

///|
fn DeliveryMachine::group_state(
  self : DeliveryMachine,
  group_id : UInt16,
) -> GroupState {
  match self.groups.get(group_id) {
    Some(state) => state
    None => { entries: Map([]), next_delivery_id: 1UL, }
  }
}

///|
fn ledger_to_delivery_error(code : LedgerFault) -> DeliveryError {
  match code {
    Malformed => Malformed
    Capacity => Capacity
    DiskFault(fault) => DiskFault(fault)
  }
}

///|
/// Adapt the machine-level gate to the writer's gate: a Q18 capacity check
/// is the only rejection either side can produce.
fn adapt_gate(
  precheck : (Int) -> Result[Unit, DeliveryError],
) -> (Int) -> Result[Unit, LedgerFault] {
  bytes => {
    match precheck(bytes) {
      Ok(_) => Ok(())
      Err(_) => Err(Capacity)
    }
  }
}

///|
/// Start one delivery of `key` to `owner_conn` and return the wire bundle.
///
/// A first call bills `attempt = 1`; a redelivery (after the restart policy
/// or a retry path made the entry redeliverable) bills `attempt + 1` with a
/// fresh `delivery_id`. An entry already in flight, and an already-acked
/// entry (the no-ghost rule), are both refused with `InvalidTransition`.
pub async fn[D : @harness.Disk] DeliveryMachine::begin_delivery(
  self : DeliveryMachine,
  disk : D,
  key : DeliveryKey,
  owner_conn : UInt64,
  now_unix_ms : UInt64,
  precheck : (Int) -> Result[Unit, DeliveryError],
) -> Result[DeliveryAttempt, DeliveryError] {
  match self.check_key(key) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  let group = self.group_state(key.group_id)
  let prior_entry = group.entries.get(key.sequence)
  let attempt : UInt16 = match prior_entry {
    None => 1
    Some(entry) =>
      match entry.state {
        Delivering(_, _, _) | Acked => return Err(InvalidTransition)
        DeadLetterQueued | Quarantined => return Err(AlreadyDeadLettered)
        RetryScheduled(count) => count + 1
      }
  }
  // Defense in depth for the L1 rule "attempt 6 is never enqueued": the
  // budget-exhausted entry already sits in `DeadLetterQueued`, and this
  // guard keeps a stray caller from billing past `MAX_ATTEMPTS` anyway.
  if attempt > MAX_ATTEMPTS {
    return Err(AlreadyDeadLettered)
  }
  let fenced_delivery_id = match prior_entry {
    Some(entry) => entry.fenced_delivery_id
    None => 0UL
  }
  let delivery_id = group.next_delivery_id
  let event = LedgerEvent::new(
    group_id=key.group_id,
    event=Deliver,
    sequence=key.sequence,
    delivery_id~,
    owner_conn~,
    attempt~,
    delay_ms=0U,
    reason=NackReason::Retry,
    timestamp=now_unix_ms,
  )
  match self.writer.append(disk, event, adapt_gate(precheck)) {
    Ok(_) => ()
    Err(code) => return Err(ledger_to_delivery_error(code))
  }
  group.entries[key.sequence] = {
    state: Delivering(delivery_id, owner_conn, attempt),
    fenced_delivery_id,
    dlq_sequence: 0UL,
  }
  self.groups[key.group_id] = {
    entries: group.entries,
    next_delivery_id: delivery_id + 1UL,
  }
  Ok({ delivery_id, attempt, owner_conn, })
}

///|
/// Acknowledge one delivery.
///
/// The decision order is the two-layer fence story reduced to one layer's
/// share: the fenced delivery instance answers `StaleOwner` forever (fault
/// 9, "old owner ACK/NACK is fenced"); the matching in-flight ACK appends
/// its event and becomes `Acked`; every ACK against an `Acked` entry answers
/// `Duplicate` (fault 7); anything else answers `UnknownDelivery` (0x0023,
/// the client no-ops), which also covers a late ACK after timeout or after
/// the restart policy (fault 2/13: the message redelivers instead).
pub async fn[D : @harness.Disk] DeliveryMachine::ack(
  self : DeliveryMachine,
  disk : D,
  key : DeliveryKey,
  delivery_id : UInt64,
  now_unix_ms : UInt64,
  precheck : (Int) -> Result[Unit, DeliveryError],
) -> Result[AckResult, DeliveryError] {
  match self.check_key(key) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  let group = self.group_state(key.group_id)
  let entry = match group.entries.get(key.sequence) {
    Some(entry) => entry
    None => return Err(UnknownDelivery)
  }
  if entry.fenced_delivery_id != 0UL && entry.fenced_delivery_id == delivery_id {
    return Err(StaleOwner)
  }
  match entry.state {
    Acked => return Ok(Duplicate)
    RetryScheduled(_) => return Err(UnknownDelivery)
    DeadLetterQueued | Quarantined => return Err(AlreadyDeadLettered)
    Delivering(current_id, owner_conn, attempt) =>
      if current_id != delivery_id {
        return Err(UnknownDelivery)
      } else {
        let event = LedgerEvent::new(
          group_id=key.group_id,
          event=Ack,
          sequence=key.sequence,
          delivery_id=current_id,
          owner_conn~,
          attempt~,
          delay_ms=0U,
          reason=NackReason::Retry,
          timestamp=now_unix_ms,
        )
        match self.writer.append(disk, event, adapt_gate(precheck)) {
          Ok(_) => ()
          Err(code) => return Err(ledger_to_delivery_error(code))
        }
        group.entries[key.sequence] = {
          state: Acked,
          fenced_delivery_id: entry.fenced_delivery_id,
          dlq_sequence: 0UL,
        }
        self.groups[key.group_id] = group
        return Ok(Applied)
      }
  }
}

///|
/// The Q29 port: one ownership change, eight flat parameters, no shared
/// event record. Called by the coordinator at the Revoking->Released point,
/// before credit release and waiter wake-up (frozen consumption order).
///
/// Every in-flight entry of `group_id` still owned by `old_owner` first gets
/// its durable `FENCED` event (sequences ascending), then all of them become
/// redeliverable; the fenced delivery id is remembered and its late ACKs
/// answer `StaleOwner`. Entries already `Acked` or not owned by `old_owner`
/// are untouched.
pub async fn[D : @harness.Disk] DeliveryMachine::on_ownership_changed(
  self : DeliveryMachine,
  disk : D,
  group_id : UInt16,
  topic_id : UInt16,
  partition : UInt16,
  _subscription_id : UInt16,
  old_owner : UInt64,
  _new_owner : UInt64,
  _old_epoch : UInt64,
  _new_epoch : UInt64,
  now_unix_ms : UInt64,
  precheck : (Int) -> Result[Unit, DeliveryError],
) -> Result[Unit, DeliveryError] {
  if topic_id != self.topic_id || partition != self.partition {
    return Err(InvalidTransition)
  }
  let group = self.group_state(group_id)
  let sequences : Array[UInt64] = []
  for sequence, entry in group.entries {
    match entry.state {
      Delivering(_, owner_conn, _) =>
        if owner_conn == old_owner {
          sequences.push(sequence)
        }
      _ => ()
    }
  }
  sequences.sort()
  for sequence in sequences {
    let entry = match group.entries.get(sequence) {
      Some(entry) => entry
      None => continue
    }
    match entry.state {
      Delivering(delivery_id, owner_conn, attempt) => {
        let event = LedgerEvent::new(
          group_id~,
          event=Fenced,
          sequence~,
          delivery_id~,
          owner_conn~,
          attempt~,
          delay_ms=0U,
          reason=NackReason::Retry,
          timestamp=now_unix_ms,
        )
        match self.writer.append(disk, event, adapt_gate(precheck)) {
          Ok(_) => ()
          Err(code) => return Err(ledger_to_delivery_error(code))
        }
        group.entries[sequence] = {
          state: RetryScheduled(attempt),
          fenced_delivery_id: delivery_id,
          dlq_sequence: 0UL,
        }
      }
      _ => ()
    }
  }
  self.groups[group_id] = group
  Ok(())
}

///|
/// The frozen backoff: delay_n = min(30s, 1s * 2^(n-1)), then jitter drawn
/// from 0..=delay_n/4 (design "Backoff"; monotonic scheduling is the
/// executor's timer).
fn[R : @harness.Rng] backoff_delay(attempt : UInt16, rng : R) -> UInt {
  let mut delay_n = RETRY_BACKOFF_BASE_MS
  let steps = attempt.to_int() - 1
  for _ in 0..<steps {
    if delay_n >= MAX_BACKOFF_MS {
      break
    }
    delay_n = delay_n * 2
    if delay_n > MAX_BACKOFF_MS {
      delay_n = MAX_BACKOFF_MS
    }
  }
  let jitter_span = delay_n / 4
  let jitter = (rng.next_uint64() % (jitter_span + 1).to_uint64()).to_uint()
  delay_n + jitter
}

///|
/// Fail one in-flight delivery with a NACK outcome and schedule the retry.
///
/// `Retry` writes `NACK_RETRY` and returns the jittered backoff plan
/// (frozen 1s/2s/4s/8s, `MAX_ATTEMPTS` inclusive). A failure at the final
/// attempt writes `NACK_TERMINAL` and moves the entry to `DeadLetterQueued`
/// -- the durable DLQ record for this path lands with WP-04.04, and no
/// sixth delivery is ever billed (L1). `Terminal`/`Poison`/`Slow` are
/// refused with `InvalidTransition` until that WP wires their DLQ flow.
/// The fenced delivery's NACK answers `StaleOwner` (fault 9); a NACK for a
/// resolved or non-current delivery is the same idempotent no-op as its
/// ACK twin (fault 12).
pub async fn[D : @harness.Disk, R : @harness.Rng] DeliveryMachine::nack(
  self : DeliveryMachine,
  disk : D,
  rng : R,
  key : DeliveryKey,
  delivery_id : UInt64,
  outcome : DeliveryOutcome,
  now_unix_ms : UInt64,
  precheck : (Int) -> Result[Unit, DeliveryError],
) -> Result[RetryPlan, DeliveryError] {
  match self.check_key(key) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  let group = self.group_state(key.group_id)
  let entry = match group.entries.get(key.sequence) {
    Some(entry) => entry
    None => return Err(UnknownDelivery)
  }
  if entry.fenced_delivery_id != 0UL && entry.fenced_delivery_id == delivery_id {
    return Err(StaleOwner)
  }
  match entry.state {
    Acked => return Err(AlreadyAcked)
    DeadLetterQueued | Quarantined => return Err(AlreadyDeadLettered)
    RetryScheduled(_) => return Err(UnknownDelivery)
    Delivering(current_id, owner_conn, attempt) => {
      if current_id != delivery_id {
        return Err(UnknownDelivery)
      }
      match outcome {
        Slow => return Err(InvalidTransition)
        Terminal | Poison =>
          return self.mark_dead_letter_pending(
            disk,
            key,
            current_id,
            owner_conn,
            attempt,
            if outcome == DeliveryOutcome::Terminal {
              NackReason::Terminal
            } else {
              NackReason::Poison
            },
            now_unix_ms,
            precheck,
          )
        Retry => ()
      }
      self.resolve_failure(
        disk,
        rng,
        key,
        current_id,
        owner_conn,
        attempt,
        NackRetry,
        now_unix_ms,
        precheck,
      )
    }
  }
}

///|
/// Fail one in-flight delivery by ACK timeout and schedule the retry.
///
/// Same backoff, cap, and idempotent no-op rules as `nack`; the durable
/// event is `TIMEOUT` and the attempt still counts (design: "ack timeout
/// ... attempt 不减少").
pub async fn[D : @harness.Disk, R : @harness.Rng] DeliveryMachine::timeout(
  self : DeliveryMachine,
  disk : D,
  rng : R,
  key : DeliveryKey,
  delivery_id : UInt64,
  now_unix_ms : UInt64,
  precheck : (Int) -> Result[Unit, DeliveryError],
) -> Result[RetryPlan, DeliveryError] {
  match self.check_key(key) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  let group = self.group_state(key.group_id)
  let entry = match group.entries.get(key.sequence) {
    Some(entry) => entry
    None => return Err(UnknownDelivery)
  }
  if entry.fenced_delivery_id != 0UL && entry.fenced_delivery_id == delivery_id {
    return Err(StaleOwner)
  }
  match entry.state {
    Acked => return Err(AlreadyAcked)
    DeadLetterQueued | Quarantined => return Err(AlreadyDeadLettered)
    RetryScheduled(_) => return Err(UnknownDelivery)
    Delivering(current_id, owner_conn, attempt) =>
      if current_id != delivery_id {
        return Err(UnknownDelivery)
      } else {
        self.resolve_failure(
          disk,
          rng,
          key,
          current_id,
          owner_conn,
          attempt,
          Timeout,
          now_unix_ms,
          precheck,
        )
      }
  }
}

///|
/// Everything the DLQ flow needs to know about the failed delivery: the
/// dead-letter reason, the final attempt, whether the delivery came from a
/// `.dlq` topic (layer 1 of the loop guard), and the record as delivered.
pub(all) struct DeadLetterRequest {
  from_dlq_topic : Bool
  reason : NackReason
  attempt : UInt16
  source : DeadLetterSource
} derive(Eq, Debug)

///|
pub extend DeadLetterRequest with Eq::{not_equal, equal}

///|
pub extend DeadLetterRequest with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The two terminal outcomes of the DLQ flow. `Enqueued` carries the DLQ
/// record's broker sequence (its partition is the source partition, the
/// frozen mapping); `Quarantined` is the loop-guard outcome with no DLQ
/// record at all.
pub(all) enum DeadLetterResult {
  Enqueued(UInt64)
  Quarantined
} derive(Eq, Debug)

///|
pub extend DeadLetterResult with Eq::{not_equal, equal}

///|
pub extend DeadLetterResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The shared failure transition: journal the failure, then either
/// schedule the next attempt or exhaust the budget into `DeadLetterQueued`.
async fn[D : @harness.Disk, R : @harness.Rng] DeliveryMachine::resolve_failure(
  self : DeliveryMachine,
  disk : D,
  rng : R,
  key : DeliveryKey,
  delivery_id : UInt64,
  owner_conn : UInt64,
  attempt : UInt16,
  kind : LedgerEventKind,
  now_unix_ms : UInt64,
  precheck : (Int) -> Result[Unit, DeliveryError],
) -> Result[RetryPlan, DeliveryError] {
  if attempt >= MAX_ATTEMPTS {
    return self.mark_dead_letter_pending(
      disk,
      key,
      delivery_id,
      owner_conn,
      attempt,
      NackReason::Retry,
      now_unix_ms,
      precheck,
    )
  }
  let event_kind = if kind == Timeout { Timeout } else { NackRetry }
  let delay_ms = backoff_delay(attempt, rng)
  let event = LedgerEvent::new(
    group_id=key.group_id,
    event=event_kind,
    sequence=key.sequence,
    delivery_id~,
    owner_conn~,
    attempt~,
    delay_ms~,
    reason=NackReason::Retry,
    timestamp=now_unix_ms,
  )
  match self.writer.append(disk, event, adapt_gate(precheck)) {
    Ok(_) => ()
    Err(code) => return Err(ledger_to_delivery_error(code))
  }
  let group = self.group_state(key.group_id)
  group.entries[key.sequence] = {
    state: RetryScheduled(attempt),
    fenced_delivery_id: entry_fence(group, key.sequence),
    dlq_sequence: 0UL,
  }
  self.groups[key.group_id] = group
  Ok(Scheduled(attempt, delay_ms))
}

///|
/// Journal the terminal failure (`NACK_TERMINAL`) and park the entry in
/// `DeadLetterQueued` awaiting its DLQ record. The caller completes the flow
/// with `complete_dead_letter`; a crash between the two steps recovers as a
/// pending dead-letter and the completion is re-run (design fault 11).
async fn[D : @harness.Disk] DeliveryMachine::mark_dead_letter_pending(
  self : DeliveryMachine,
  disk : D,
  key : DeliveryKey,
  delivery_id : UInt64,
  owner_conn : UInt64,
  attempt : UInt16,
  reason : NackReason,
  now_unix_ms : UInt64,
  precheck : (Int) -> Result[Unit, DeliveryError],
) -> Result[RetryPlan, DeliveryError] {
  let event = LedgerEvent::new(
    group_id=key.group_id,
    event=NackTerminal,
    sequence=key.sequence,
    delivery_id~,
    owner_conn~,
    attempt~,
    delay_ms=0U,
    reason~,
    timestamp=now_unix_ms,
  )
  match self.writer.append(disk, event, adapt_gate(precheck)) {
    Ok(_) => ()
    Err(code) => return Err(ledger_to_delivery_error(code))
  }
  let group = self.group_state(key.group_id)
  group.entries[key.sequence] = {
    state: DeadLetterQueued,
    fenced_delivery_id: entry_fence(group, key.sequence),
    dlq_sequence: 0UL,
  }
  self.groups[key.group_id] = group
  Ok(DeadLettered(attempt))
}

///|
/// Journal `SOURCE_TERMINATED` without a DLQ record and park the entry in
/// `Quarantined`: the loop guards refused re-entry and the message awaits
/// human intervention (0x0030 semantics).
async fn[D : @harness.Disk] DeliveryMachine::journal_quarantine(
  self : DeliveryMachine,
  disk : D,
  key : DeliveryKey,
  request : DeadLetterRequest,
  now_unix_ms : UInt64,
  precheck : (Int) -> Result[Unit, DeliveryError],
) -> Result[Unit, DeliveryError] {
  let event = LedgerEvent::new(
    group_id=key.group_id,
    event=SourceTerminated,
    sequence=key.sequence,
    delivery_id=0UL,
    owner_conn=0UL,
    attempt=request.attempt,
    delay_ms=0U,
    reason=request.reason,
    timestamp=now_unix_ms,
  )
  match self.writer.append(disk, event, adapt_gate(precheck)) {
    Ok(_) => ()
    Err(code) => return Err(ledger_to_delivery_error(code))
  }
  let group = self.group_state(key.group_id)
  group.entries[key.sequence] = {
    state: Quarantined,
    fenced_delivery_id: entry_fence(group, key.sequence),
    dlq_sequence: 0UL,
  }
  self.groups[key.group_id] = group
  Ok(())
}

///|
/// Complete the DLQ flow for an entry parked in `DeadLetterQueued`: run the
/// three loop guards, write the MMDL record into the source's `.dlq`
/// partition stream through `dlq_write`, then journal `DLQ_WRITTEN` and
/// `SOURCE_TERMINATED` (the frozen order: the DLQ record is durable before
/// the source is terminated, design faults 10/11).
///
/// Loop guards, in order: a `.dlq` topic is terminal (no `.dlq.dlq`); a
/// death path that already lists this `(topic, partition, group)` refuses
/// re-entry; a death path at the frozen bound of 8 reports
/// `DlqPathOverflow` (0x0030) after quarantining. Guard hits quarantine the
/// message with no DLQ record. A value that is itself an envelope (a
/// manually replayed DLQ message) is flattened into the new envelope's
/// original payload and death path, so envelopes never nest.
///
/// The honest blind spot (REQ-DEL-002 boundary): a client that replays a
/// message through ordinary PUB with the raw original payload loses the
/// death path, and the broker -- which never parses user payloads -- starts
/// the path over. Only envelope-carrying replays are loop-proofed.
///
/// Completion is idempotent: a second call reports the stored DLQ sequence
/// without writing again.
pub async fn[D : @harness.Disk] DeliveryMachine::complete_dead_letter(
  self : DeliveryMachine,
  disk : D,
  key : DeliveryKey,
  request : DeadLetterRequest,
  dlq_write : (Bytes) -> Result[UInt64, DeliveryError],
  now_unix_ms : UInt64,
  precheck : (Int) -> Result[Unit, DeliveryError],
) -> Result[DeadLetterResult, DeliveryError] {
  match self.check_key(key) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  let group = self.group_state(key.group_id)
  let entry = match group.entries.get(key.sequence) {
    Some(entry) => entry
    None => return Err(UnknownDelivery)
  }
  match entry.state {
    DeadLetterQueued => ()
    _ => return Err(InvalidTransition)
  }
  if entry.dlq_sequence != 0UL {
    return Ok(Enqueued(entry.dlq_sequence))
  }
  let mut death_path : Array[DlqHop] = []
  let mut original_key = request.source.key
  let mut original_value = request.source.value
  if is_mmdl(request.source.value[:]) {
    match decode_mmdl(request.source.value[:]) {
      Ok(inner) => {
        death_path = inner.death_path
        original_key = inner.original_key
        original_value = inner.original_value
      }
      Err(_) => ()
    }
  }
  let triple = DlqHop::new(
    topic_id=self.topic_id,
    partition=self.partition,
    group_id=key.group_id,
  )
  if request.from_dlq_topic {
    match self.journal_quarantine(disk, key, request, now_unix_ms, precheck) {
      Ok(_) => ()
      Err(code) => return Err(code)
    }
    return Ok(Quarantined)
  }
  for hop in death_path {
    if hop == triple {
      match self.journal_quarantine(disk, key, request, now_unix_ms, precheck) {
        Ok(_) => ()
        Err(code) => return Err(code)
      }
      return Ok(Quarantined)
    }
  }
  if death_path.length() >= 8 {
    match self.journal_quarantine(disk, key, request, now_unix_ms, precheck) {
      Ok(_) => ()
      Err(code) => return Err(code)
    }
    return Err(DlqPathOverflow)
  }
  death_path.push(triple)
  let envelope = MmdlEnvelope::new(
    reason=request.reason,
    source_topic_id=self.topic_id,
    source_partition=self.partition,
    source_sequence=key.sequence,
    source_producer_id=request.source.producer_id,
    source_producer_seq=request.source.producer_seq,
    consumer_group_id=key.group_id,
    attempt=request.attempt,
    failed_unix_ms=now_unix_ms,
    death_path~,
    original_key~,
    original_value~,
  )
  let bytes = match encode_mmdl(envelope) {
    Ok(bytes) => bytes
    Err(code) => return Err(code)
  }
  let dlq_sequence = match dlq_write(bytes) {
    Ok(sequence) => sequence
    Err(code) => return Err(code)
  }
  let written = LedgerEvent::new(
    group_id=key.group_id,
    event=DlqWritten,
    sequence=key.sequence,
    delivery_id=dlq_sequence,
    owner_conn=0UL,
    attempt=request.attempt,
    delay_ms=0U,
    reason=request.reason,
    timestamp=now_unix_ms,
  )
  match self.writer.append(disk, written, adapt_gate(precheck)) {
    Ok(_) => ()
    Err(code) => return Err(ledger_to_delivery_error(code))
  }
  let terminated = LedgerEvent::new(
    group_id=key.group_id,
    event=SourceTerminated,
    sequence=key.sequence,
    delivery_id=0UL,
    owner_conn=0UL,
    attempt=request.attempt,
    delay_ms=0U,
    reason=request.reason,
    timestamp=now_unix_ms,
  )
  match self.writer.append(disk, terminated, adapt_gate(precheck)) {
    Ok(_) => ()
    Err(code) => return Err(ledger_to_delivery_error(code))
  }
  group.entries[key.sequence] = {
    state: DeadLetterQueued,
    fenced_delivery_id: entry_fence(group, key.sequence),
    dlq_sequence,
  }
  self.groups[key.group_id] = group
  Ok(Enqueued(dlq_sequence))
}

///|
fn entry_fence(group : GroupState, sequence : UInt64) -> UInt64 {
  match group.entries.get(sequence) {
    Some(entry) => entry.fenced_delivery_id
    None => 0UL
  }
}

///|
/// Fold the durable event log into a fresh machine and apply the frozen
/// restart policy: entries still in flight become redeliverable
/// (`RetryScheduled`) so a crashed owner can never hold a delivery open;
/// their ACKs after restart are plain `UnknownDelivery` no-ops and the
/// message redelivers (at-least-once, design fault 2). The fenced delivery
/// id survives redeliveries. Timer rebuild for due retries lands with T032.
pub async fn[D : @harness.Disk] DeliveryMachine::recover(
  disk : D,
  topic_id : UInt16,
  partition : UInt16,
  writer : LedgerWriter,
) -> Result[DeliveryMachine, DeliveryError] {
  let events = match read_ledger_events(disk, writer.path()) {
    Ok(events) => events
    Err(DiskFault(@harness.PathMissing)) => []
    Err(code) => return Err(ledger_to_delivery_error(code))
  }
  let machine = DeliveryMachine::new(topic_id, partition, writer)
  for event in events {
    let group = machine.group_state(event.group_id)
    let prior_fenced = match group.entries.get(event.sequence) {
      Some(entry) => entry.fenced_delivery_id
      None => 0UL
    }
    let prior_dlq = match group.entries.get(event.sequence) {
      Some(entry) => entry.dlq_sequence
      None => 0UL
    }
    match event.event {
      Deliver =>
        group.entries[event.sequence] = {
          state: Delivering(event.delivery_id, event.owner_conn, event.attempt),
          fenced_delivery_id: prior_fenced,
          dlq_sequence: prior_dlq,
        }
      Ack =>
        group.entries[event.sequence] = {
          state: Acked,
          fenced_delivery_id: prior_fenced,
          dlq_sequence: 0UL,
        }
      Fenced =>
        group.entries[event.sequence] = {
          state: RetryScheduled(event.attempt),
          fenced_delivery_id: event.delivery_id,
          dlq_sequence: prior_dlq,
        }
      NackRetry | Timeout =>
        group.entries[event.sequence] = {
          state: RetryScheduled(event.attempt),
          fenced_delivery_id: prior_fenced,
          dlq_sequence: prior_dlq,
        }
      NackTerminal =>
        group.entries[event.sequence] = {
          state: DeadLetterQueued,
          fenced_delivery_id: prior_fenced,
          dlq_sequence: prior_dlq,
        }
      DlqWritten =>
        group.entries[event.sequence] = {
          state: DeadLetterQueued,
          fenced_delivery_id: prior_fenced,
          dlq_sequence: event.delivery_id,
        }
      SourceTerminated =>
        group.entries[event.sequence] = {
          state: if prior_dlq != 0UL {
            DeadLetterQueued
          } else {
            Quarantined
          },
          fenced_delivery_id: prior_fenced,
          dlq_sequence: prior_dlq,
        }
      _ => return Err(Malformed)
    }
    let next = event.delivery_id + 1UL
    let next_delivery_id = if next > group.next_delivery_id {
      next
    } else {
      group.next_delivery_id
    }
    machine.groups[event.group_id] = {
      entries: group.entries,
      next_delivery_id,
    }
  }
  // Restart policy: Delivering entries become redeliverable.
  for _group_id, group in machine.groups {
    let sequences : Array[UInt64] = []
    for sequence, entry in group.entries {
      match entry.state {
        Delivering(_, _, _) => sequences.push(sequence)
        _ => ()
      }
    }
    for sequence in sequences {
      let entry = match group.entries.get(sequence) {
        Some(entry) => entry
        None => continue
      }
      match entry.state {
        Delivering(_, _, attempt) =>
          group.entries[sequence] = {
            state: RetryScheduled(attempt),
            fenced_delivery_id: entry.fenced_delivery_id,
            dlq_sequence: entry.dlq_sequence,
          }
        _ => ()
      }
    }
  }
  Ok(machine)
}

///|
/// Force the pending group commit (the Q18 flush step).
pub async fn[D : @harness.Disk] DeliveryMachine::sync(
  self : DeliveryMachine,
  disk : D,
) -> Result[Unit, DeliveryError] {
  match self.writer.sync(disk) {
    Ok(_) => Ok(())
    Err(code) => Err(ledger_to_delivery_error(code))
  }
}

///|
/// Report one entry's public state, or `None` when the machine has never
/// seen the sequence.
pub fn DeliveryMachine::state_of(
  self : DeliveryMachine,
  key : DeliveryKey,
) -> DeliveryState? {
  match self.groups.get(key.group_id) {
    None => None
    Some(group) =>
      match group.entries.get(key.sequence) {
        None => None
        Some(entry) => Some(entry.state)
      }
  }
}

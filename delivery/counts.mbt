/// The real counter surface behind the metrics conservation suite.
///
/// The three conservation properties read these counters: the quiet-window
/// identity (produced = delivered + dropped + dlq + change in depth, whose
/// delivery-side form is `published = delivered + retained + dlq` when
/// nothing is dropped), the monotonicity of the cumulative totals, and the
/// floor/lag consistency (lag = max_sequence - ack_floor, floor never
/// invents an undelivered message below it). Every field is derived from
/// real state -- the entry set of one group -- so a metric can never
/// disagree with the ledger it reports on.
///
/// Bucket mapping: `delivered` counts acked entries; `retained` is the
/// depth gauge (in flight, scheduled for retry, or parked awaiting its
/// dead-letter record); `dlq` counts entries whose dead-letter record is
/// durable; `dropped` counts the loop-guard quarantine. The cumulative
/// totals (delivered, dlq, dropped) only ever grow -- a parked entry
/// moves into exactly one of the terminal buckets -- which is the
/// counter-monotonicity property. `published` counts the distinct
/// sequences the group's delivery pipeline has admitted, one per entry.

///|
/// One group's delivery counters at a point in time.
pub(all) struct DeliveryCounts {
  published : UInt64
  delivered : UInt64
  retained : UInt64
  dlq : UInt64
  dropped : UInt64
  ack_floor : UInt64
  max_sequence : UInt64
  lag : UInt64
} derive(Eq, Debug)

///|
pub extend DeliveryCounts with Eq::{not_equal, equal}

///|
pub extend DeliveryCounts with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The empty counters: the identity holds and the floor sits at zero.
pub fn DeliveryCounts::zero() -> DeliveryCounts {
  {
    published: 0UL,
    delivered: 0UL,
    retained: 0UL,
    dlq: 0UL,
    dropped: 0UL,
    ack_floor: 0UL,
    max_sequence: 0UL,
    lag: 0UL,
  }
}

///|
/// True when the quiet-window identity holds: every published sequence
/// sits in exactly one bucket, and the delivery-side specialization
/// `published = delivered + retained + dlq` additionally requires that
/// nothing was dropped.
pub fn DeliveryCounts::conserved(self : DeliveryCounts) -> Bool {
  self.published == self.delivered + self.retained + self.dlq + self.dropped
}

///|
/// The delivery-side specialization of the identity: nothing dropped.
pub fn DeliveryCounts::conserved_without_drop(self : DeliveryCounts) -> Bool {
  self.conserved() &&
  self.dropped == 0UL &&
  self.published == self.delivered + self.retained + self.dlq
}

///|
/// True when the cumulative totals are non-decreasing from `earlier` and
/// the depth gauge moved consistently with them (monotone totals, the
/// counter-monotonicity property).
pub fn DeliveryCounts::totals_monotone_from(
  self : DeliveryCounts,
  earlier : DeliveryCounts,
) -> Bool {
  self.published >= earlier.published &&
  self.delivered >= earlier.delivered &&
  self.dlq >= earlier.dlq &&
  self.dropped >= earlier.dropped &&
  self.ack_floor >= earlier.ack_floor
}

///|
/// True when the lag is the exact span from the floor to the max
/// sequence: the floor never passes the max, and the lag never invents
/// work.
pub fn DeliveryCounts::floor_lag_consistent(self : DeliveryCounts) -> Bool {
  self.ack_floor <= self.max_sequence &&
  self.lag == self.max_sequence - self.ack_floor
}

///|
/// Count one group's entries exactly as they stand. This is the oracle
/// the metrics layer reads; it scans real state and cannot drift from it.
pub fn DeliveryMachine::counts(
  self : DeliveryMachine,
  group_id : UInt16,
) -> DeliveryCounts {
  let group = match self.groups.get(group_id) {
    None => return DeliveryCounts::zero()
    Some(group) => group
  }
  let mut published = 0UL
  let mut delivered = 0UL
  let mut retained = 0UL
  let mut dlq = 0UL
  let mut dropped = 0UL
  let mut max_sequence = 0UL
  let sequences : Array[UInt64] = []
  for sequence, entry in group.entries {
    published = published + 1UL
    sequences.push(sequence)
    if sequence > max_sequence {
      max_sequence = sequence
    }
    match entry.state {
      Delivering(_, _, _) => retained = retained + 1UL
      RetryScheduled(_) => retained = retained + 1UL
      Acked => delivered = delivered + 1UL
      DeadLetterQueued(_) =>
        if entry.dlq_sequence != 0UL {
          dlq = dlq + 1UL
        } else {
          retained = retained + 1UL
        }
      Quarantined => dropped = dropped + 1UL
    }
  }
  // The floor names delivered work only: walk the sequence order and
  // stop at the first entry that is not acked.
  sequences.sort()
  let mut ack_floor = 0UL
  for sequence in sequences {
    let entry = match group.entries.get(sequence) {
      Some(entry) => entry
      None => continue
    }
    match entry.state {
      Acked => ack_floor = sequence
      _ => break
    }
  }
  {
    published,
    delivered,
    retained,
    dlq,
    dropped,
    ack_floor,
    max_sequence,
    lag: max_sequence - ack_floor,
  }
}

///|
/// Count one group's event history the way the recovery fold reads it.
/// This pure oracle is what the conservation properties drive; the
/// deterministic tests pin it equal to `DeliveryMachine::counts` so the
/// two can never disagree. Each sequence ends in exactly one bucket:
/// acked delivers, a NACK_TERMINAL or DLQ_WRITTEN parks in the dead-letter
/// flow, a source termination without a DLQ record drops into quarantine,
/// and everything else is still retained for delivery.
pub fn counts_of_events(
  events : Array[LedgerEvent],
  group_id : UInt16,
  first_n : Int32,
) -> DeliveryCounts {
  // Per sequence: (bucket, dlq_seen) with bucket 0 retained, 1 delivered,
  // 2 dead-lettered, 3 dropped.
  let seen : Map[UInt64, (UInt64, UInt64)] = Map([])
  let mut n = first_n
  if n > events.length() {
    n = events.length()
  }
  for index in 0..<n {
    let event = events[index]
    if event.group_id != group_id {
      continue
    }
    let prior = match seen.get(event.sequence) {
      Some(value) => value
      None => (0UL, 0UL)
    }
    let bucket = match event.event {
      Deliver | NackRetry | Timeout | Fenced | SendFailed | NackTerminal => 0UL
      Ack => 1UL
      DlqWritten => 2UL
      SourceTerminated => if prior.1 != 0UL { 2UL } else { 3UL }
    }
    let dlq_seen = match event.event {
      DlqWritten => 1UL
      _ => prior.1
    }
    seen[event.sequence] = (bucket, dlq_seen)
  }
  let mut published = 0UL
  let mut delivered = 0UL
  let mut retained = 0UL
  let mut dlq = 0UL
  let mut dropped = 0UL
  let mut max_sequence = 0UL
  let sequences : Array[UInt64] = []
  for sequence, state in seen {
    published = published + 1UL
    sequences.push(sequence)
    if sequence > max_sequence {
      max_sequence = sequence
    }
    match state.0 {
      0UL => retained = retained + 1UL
      1UL => delivered = delivered + 1UL
      2UL => dlq = dlq + 1UL
      _ => dropped = dropped + 1UL
    }
  }
  sequences.sort()
  let mut ack_floor = 0UL
  for sequence in sequences {
    let state = match seen.get(sequence) {
      Some(state) => state
      None => continue
    }
    if state.0 == 1UL {
      ack_floor = sequence
    } else {
      break
    }
  }
  {
    published,
    delivered,
    retained,
    dlq,
    dropped,
    ack_floor,
    max_sequence,
    lag: max_sequence - ack_floor,
  }
}

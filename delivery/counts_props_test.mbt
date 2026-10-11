/// Conservation properties over generated delivery histories (the
/// metrics suite: quiet-window identity, monotone totals, floor/lag
/// consistency). Each property pins its seed so a failure reproduces
/// exactly; the pure fold they drive is pinned equal to the machine's
/// counters by the deterministic tests.

///|
/// Build one group's valid event history from the draw: each sequence
/// walks one of eight legal paths from first delivery to its terminal or
/// waiting state, and returns the per-sequence buckets (1 delivered, 2
/// dead-lettered, 3 dropped, 0 retained) for the floor truth check.
fn cm_history(draw : UInt) -> (Array[@delivery.LedgerEvent], Array[UInt64]) {
  let events : Array[@delivery.LedgerEvent] = []
  let buckets : Array[UInt64] = []
  let n = (draw % 4U).reinterpret_as_int() + 2
  let mut bits = draw >> 3
  let mut delivery_id = 1UL
  for index in 0..<n {
    let path = (bits % 8U).reinterpret_as_int()
    bits = bits >> 3
    let sequence = (index + 1).to_uint64()
    events.push(cm_event(@delivery.Deliver, sequence, delivery_id, 1))
    match path {
      0 => {
        events.push(cm_event(@delivery.Ack, sequence, delivery_id, 1))
        buckets.push(1UL)
      }
      1 => {
        events.push(cm_event(@delivery.NackRetry, sequence, delivery_id, 1))
        delivery_id = delivery_id + 1UL
        events.push(cm_event(@delivery.Deliver, sequence, delivery_id, 2))
        events.push(cm_event(@delivery.Ack, sequence, delivery_id, 2))
        buckets.push(1UL)
      }
      2 => {
        events.push(cm_event(@delivery.NackRetry, sequence, delivery_id, 1))
        buckets.push(0UL)
      }
      3 => {
        events.push(cm_event(@delivery.Fenced, sequence, delivery_id, 1))
        buckets.push(0UL)
      }
      4 => {
        // Parked awaiting its record: still retained until the write
        // lands (and forever, if the guard quarantines it instead).
        events.push(cm_event(@delivery.NackTerminal, sequence, delivery_id, 1))
        buckets.push(0UL)
      }
      5 => {
        events.push(cm_event(@delivery.NackTerminal, sequence, delivery_id, 1))
        events.push(cm_event(@delivery.DlqWritten, sequence, delivery_id, 1))
        events.push(
          cm_event(@delivery.SourceTerminated, sequence, delivery_id, 1),
        )
        buckets.push(2UL)
      }
      6 => {
        events.push(cm_event(@delivery.NackTerminal, sequence, delivery_id, 1))
        events.push(
          cm_event(@delivery.SourceTerminated, sequence, delivery_id, 1),
        )
        buckets.push(3UL)
      }
      _ => {
        events.push(cm_event(@delivery.NackTerminal, sequence, delivery_id, 1))
        events.push(cm_event(@delivery.DlqWritten, sequence, delivery_id, 1))
        buckets.push(2UL)
      }
    }
    delivery_id = delivery_id + 1UL
  }
  (events, buckets)
}

///|
fn cm_event(
  kind : @delivery.LedgerEventKind,
  sequence : UInt64,
  delivery_id : UInt64,
  attempt : UInt16,
) -> @delivery.LedgerEvent {
  @delivery.LedgerEvent::new(
    group_id=1,
    event=kind,
    sequence~,
    delivery_id~,
    owner_conn=7,
    attempt~,
    delay_ms=0U,
    reason=@delivery.NackReason::Retry,
    timestamp=0UL,
  )
}

///|
test "CM1 quiet-window conservation: published = delivered + retained + dlq (quickcheck seed=20261011 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let (events, buckets) = cm_history(draw)
      let mut ok = true
      let mut n = 0
      while n <= events.length() {
        let counts = @delivery.counts_of_events(events, 1, n)
        // The full identity always; the delivery-side specialization
        // exactly when nothing was dropped.
        if !counts.conserved() {
          ok = false
        }
        if counts.dropped == 0UL && !counts.conserved_without_drop() {
          ok = false
        }
        n = n + 1
      }
      // The floor truth: it only names delivered sequences.
      let counts = @delivery.counts_of_events(events, 1, events.length())
      if counts.ack_floor != 0UL {
        let index = counts.ack_floor.to_int() - 1
        if index >= buckets.length() || buckets[index] != 1UL {
          ok = false
        }
      }
      ok
    },
    count=200,
    seed=20261011,
  )
}

///|
test "CM2 the cumulative totals never regress (quickcheck seed=20261012 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let (events, _buckets) = cm_history(draw)
      let mut ok = true
      let mut previous = @delivery.DeliveryCounts::zero()
      let mut n = 0
      while n <= events.length() {
        let counts = @delivery.counts_of_events(events, 1, n)
        if !counts.totals_monotone_from(previous) {
          ok = false
        }
        previous = counts
        n = n + 1
      }
      ok
    },
    count=200,
    seed=20261012,
  )
}

///|
test "CM3 the floor and lag stay consistent (quickcheck seed=20261013 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let (events, _buckets) = cm_history(draw)
      let mut ok = true
      let mut n = 0
      while n <= events.length() {
        let counts = @delivery.counts_of_events(events, 1, n)
        if !counts.floor_lag_consistent() {
          ok = false
        }
        n = n + 1
      }
      ok
    },
    count=200,
    seed=20261013,
  )
}

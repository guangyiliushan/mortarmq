/// Conservation properties in the metrics vocabulary: the quiet-window
/// identity, monotone cumulative totals, floor/lag consistency, and the
/// quorum faces staying aligned -- each driven over generated histories
/// or classifications through the real counter faces.
///
/// Every property pins its seed so a failure reproduces exactly, and
/// every property has an anti-vacuous companion that feeds a mutated
/// subject into the same predicate and must get a counterexample: a
/// property that cannot fail is not a property. The quantile
/// properties -- ordering of p50/p90/p99, convergence on a constant
/// stream, and boundedness of merged windows -- wait for the estimator's
/// insert/query/merge contract and are reported with that gap rather
/// than tested against a stand-in.
///
/// Vocabulary note: the registry's produced/delivered/dropped/dlq
/// totals and the depth gauge are the counter face's published,
/// delivered, dropped, dlq and retained; the identity below is the
/// registry's conservation form read through that mapping.

///|
/// Build one group's legal event history from the draw: each sequence
/// walks one path from first delivery to its terminal or waiting state.
/// Only legal walks are generated -- an acked entry never moves on, a
/// parked entry reaches its dead-letter record or the quarantine and
/// nothing else -- because the cumulative-total properties are about
/// the states a real ledger can actually reach.
fn prop_history(draw : UInt) -> Array[@delivery.LedgerEvent] {
  let events : Array[@delivery.LedgerEvent] = []
  let n_seqs = (draw % 4U).reinterpret_as_int() + 2
  let mut bits = draw >> 3
  let mut delivery_id = 1UL
  for index in 0..<n_seqs {
    let sequence = (index + 1).to_uint64()
    let path = (bits % 10U).reinterpret_as_int()
    bits = bits >> 4
    events.push(prop_event(@delivery.Deliver, sequence, delivery_id))
    if path == 0 {
      events.push(prop_event(@delivery.Ack, sequence, delivery_id))
    } else if path == 1 {
      events.push(prop_event(@delivery.NackRetry, sequence, delivery_id))
      delivery_id = delivery_id + 1UL
      events.push(prop_event(@delivery.Deliver, sequence, delivery_id))
      events.push(prop_event(@delivery.Ack, sequence, delivery_id))
    } else if path == 2 {
      events.push(prop_event(@delivery.NackRetry, sequence, delivery_id))
    } else if path == 3 {
      events.push(prop_event(@delivery.Timeout, sequence, delivery_id))
    } else if path == 4 {
      events.push(prop_event(@delivery.SendFailed, sequence, delivery_id))
    } else if path == 5 {
      events.push(prop_event(@delivery.Fenced, sequence, delivery_id))
    } else if path == 6 {
      events.push(prop_event(@delivery.NackTerminal, sequence, delivery_id))
    } else if path == 7 {
      events.push(prop_event(@delivery.NackTerminal, sequence, delivery_id))
      events.push(prop_event(@delivery.DlqWritten, sequence, delivery_id))
    } else if path == 8 {
      events.push(prop_event(@delivery.NackTerminal, sequence, delivery_id))
      events.push(prop_event(@delivery.DlqWritten, sequence, delivery_id))
      events.push(prop_event(@delivery.SourceTerminated, sequence, delivery_id))
    } else {
      events.push(prop_event(@delivery.NackTerminal, sequence, delivery_id))
      events.push(prop_event(@delivery.SourceTerminated, sequence, delivery_id))
    }
    delivery_id = delivery_id + 1UL
  }
  events
}

///|
/// One ledger event with the fields one kind carries.
fn prop_event(
  kind : @delivery.LedgerEventKind,
  sequence : UInt64,
  delivery_id : UInt64,
) -> @delivery.LedgerEvent {
  @delivery.LedgerEvent::new(
    group_id=1,
    event=kind,
    sequence~,
    delivery_id~,
    owner_conn=7,
    attempt=1,
    delay_ms=0U,
    reason=@delivery.NackReason::Retry,
    timestamp=0UL,
  )
}

///|
/// Build one counter snapshot field by field, for the mutation
/// fixtures.
fn prop_counts(
  published : UInt64,
  delivered : UInt64,
  retained : UInt64,
  dlq : UInt64,
  dropped : UInt64,
  ack_floor : UInt64,
  max_sequence : UInt64,
  lag : UInt64,
) -> @delivery.DeliveryCounts {
  {
    published,
    delivered,
    retained,
    dlq,
    dropped,
    ack_floor,
    max_sequence,
    lag,
  }
}

///|
/// Whether the five observable quorum faces agree with the one frozen
/// pairing: the tier name, the gauge code, the write answer, the
/// refusal and the warning must all describe the same tier.
fn quorum_faces_align(
  code : UInt16,
  name : String,
  may_write : Bool,
  refusal : @protocol.ErrCode?,
  warning : @protocol.ErrCode?,
) -> Bool {
  if name == "healthy" {
    code == 0U.to_uint16() && may_write && refusal == None && warning == None
  } else if name == "soft" {
    code == 1U.to_uint16() &&
    may_write &&
    refusal == None &&
    warning == Some(@protocol.FollowerLag)
  } else if name == "read_only" {
    code == 2U.to_uint16() &&
    !may_write &&
    refusal == Some(@protocol.ReadOnlyDegraded) &&
    warning == None
  } else {
    false
  }
}

///|
/// The five observed faces of one state, read through the real
/// functions.
fn observed_faces(
  state : @cluster.QuorumState,
) -> (UInt16, String, Bool, @protocol.ErrCode?, @protocol.ErrCode?) {
  (
    state.code(),
    @cluster.QuorumState::tier_name(state),
    state.may_write(),
    state.write_refusal(),
    state.warning(),
  )
}

///|
test "property: the quiet-window identity holds over any history (pin seed=20261031; daily mode logs the run seed)" {
  @quickcheck.check(
    (draw : UInt) => {
      let events = prop_history(draw)
      let counts = @delivery.counts_of_events(events, 1, events.length())
      // produced = delivered + dropped + dlq + depth, the registry's
      // conservation form over the counter face.
      counts.conserved() && counts.floor_lag_consistent()
    },
    count=200,
    seed=20261031,
  )
}

///|
test "a mutated counter breaks the quiet-window identity" {
  // Anti-vacuous: one delivered message invented must break the
  // identity, or the property proves nothing.
  let honest = prop_counts(3UL, 1UL, 1UL, 1UL, 0UL, 1UL, 3UL, 2UL)
  assert_eq(honest.conserved(), true)
  let invented = prop_counts(3UL, 2UL, 1UL, 1UL, 0UL, 1UL, 3UL, 2UL)
  assert_eq(invented.conserved(), false)
  let vanished = prop_counts(3UL, 1UL, 0UL, 1UL, 0UL, 1UL, 3UL, 2UL)
  assert_eq(vanished.conserved(), false)
}

///|
test "property: cumulative totals never regress across recovery prefixes (pin seed=20261032; daily mode logs the run seed)" {
  @quickcheck.check(
    (draw : UInt) => {
      let events = prop_history(draw)
      let half = events.length() / 2
      let earlier = @delivery.counts_of_events(events, 1, half)
      let later = @delivery.counts_of_events(events, 1, events.length())
      later.totals_monotone_from(earlier) &&
      earlier.conserved() &&
      later.conserved()
    },
    count=200,
    seed=20261032,
  )
}

///|
test "a regressing total is rejected by the monotone check" {
  // Anti-vacuous: a cumulative total that goes backwards must be
  // caught, or the monotone property proves nothing.
  let earlier = prop_counts(3UL, 1UL, 2UL, 0UL, 0UL, 1UL, 3UL, 2UL)
  let later = prop_counts(3UL, 2UL, 1UL, 0UL, 0UL, 2UL, 3UL, 1UL)
  assert_eq(later.totals_monotone_from(earlier), true)
  let regressed = prop_counts(2UL, 2UL, 1UL, 0UL, 0UL, 2UL, 3UL, 1UL)
  assert_eq(regressed.totals_monotone_from(earlier), false)
}

///|
test "property: the floor and lag stay consistent over any history (pin seed=20261033; daily mode logs the run seed)" {
  @quickcheck.check(
    (draw : UInt) => {
      let events = prop_history(draw)
      let counts = @delivery.counts_of_events(events, 1, events.length())
      counts.floor_lag_consistent()
    },
    count=200,
    seed=20261033,
  )
}

///|
test "an invented lag or a floor past the max is rejected" {
  // Anti-vacuous: the consistency check must bite on both of its
  // clauses.
  let honest = prop_counts(3UL, 1UL, 2UL, 0UL, 0UL, 1UL, 3UL, 2UL)
  assert_eq(honest.floor_lag_consistent(), true)
  let invented_lag = prop_counts(3UL, 1UL, 2UL, 0UL, 0UL, 1UL, 3UL, 3UL)
  assert_eq(invented_lag.floor_lag_consistent(), false)
  let passed_max = prop_counts(3UL, 3UL, 0UL, 0UL, 0UL, 4UL, 3UL, 0UL)
  assert_eq(passed_max.floor_lag_consistent(), false)
}

///|
test "property: the quorum faces stay aligned over any classification (pin seed=20261034; daily mode logs the run seed)" {
  @quickcheck.check(
    (draw : UInt) => {
      let bits = draw
      let in_sync = (bits % 4U).reinterpret_as_int()
      let quorum = ((bits >> 3) % 3U).reinterpret_as_int() + 2
      let trailing = ((bits >> 6) & 1U) == 1U
      let ack_timeout = ((bits >> 8) & 1U) == 1U
      let state = @cluster.classify_quorum(
        in_sync, quorum, trailing, ack_timeout,
      )
      let (code, name, may_write, refusal, warning) = observed_faces(state)
      quorum_faces_align(code, name, may_write, refusal, warning)
    },
    count=200,
    seed=20261034,
  )
}

///|
test "a mismatched quorum face pair is rejected" {
  // Anti-vacuous: the alignment table must reject every cross-face
  // mismatch a drifting edit could produce.
  assert_eq(
    quorum_faces_align(0U.to_uint16(), "healthy", true, None, None),
    true,
  )
  assert_eq(
    quorum_faces_align(2U.to_uint16(), "healthy", true, None, None),
    false,
  )
  assert_eq(quorum_faces_align(0U.to_uint16(), "soft", true, None, None), false)
  assert_eq(
    quorum_faces_align(
      1U.to_uint16(),
      "soft",
      true,
      None,
      Some(@protocol.FollowerLag),
    ),
    true,
  )
  assert_eq(
    quorum_faces_align(
      1U.to_uint16(),
      "soft",
      true,
      Some(@protocol.ReadOnlyDegraded),
      None,
    ),
    false,
  )
  assert_eq(
    quorum_faces_align(
      2U.to_uint16(),
      "read_only",
      false,
      Some(@protocol.ReadOnlyDegraded),
      None,
    ),
    true,
  )
  assert_eq(
    quorum_faces_align(
      2U.to_uint16(),
      "read_only",
      true,
      Some(@protocol.ReadOnlyDegraded),
      None,
    ),
    false,
  )
  assert_eq(
    quorum_faces_align(
      2U.to_uint16(),
      "read_only",
      false,
      None,
      Some(@protocol.FollowerLag),
    ),
    false,
  )
}

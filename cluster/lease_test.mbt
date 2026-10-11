/// The lease and the static preference behind a timeout-driven election.
///
/// Timing here is injected, never read: every case hands the lease a
/// tick it chose, which is both how a deterministic test is possible and
/// the same discipline that keeps wall-clock steps out of the
/// production path.

///|
/// The fixture table rebuilt with `priority` as its leader preference.
///
/// The preference is the only thing that changes, which is the point of
/// the last case: if the exclusion held only because of where the failed
/// member happened to sit in one particular ordering, it would not be a
/// rule.
fn leader_preference(priority : Array[UInt16]) -> @cluster.ClusterConfig raise {
  match fixture_config() {
    Err(_) => fail("the fixture table must be valid")
    Ok(config) =>
      match
        @cluster.ClusterConfig::new(
          config.node_id(),
          config.peers(),
          priority,
          config.listen_host(),
          config.listen_port(),
          config.secret(),
        ) {
        Ok(rebuilt) => rebuilt
        Err(_) => fail("a permutation of the same table must be accepted")
      }
  }
}

///|
test "a lease expires at its deadline and not an instant before" {
  let lease = @cluster.Lease::new(0UL, 2000UL)
  assert_eq(lease.expired(1999UL), false)
  // Inclusive: at the deadline the lease is gone, so a follower does not
  // hold on through the exact instant it was promised until.
  assert_eq(lease.expired(2000UL), true)
  assert_eq(lease.expired(9999UL), true)
}

///|
test "a refresh anchors on arrival, not on the old deadline" {
  let lease = @cluster.Lease::new(0UL, 2000UL)
  // A heartbeat lands at 1500, five hundred before the lease would go.
  lease.refresh(1500UL)
  // Anchoring on arrival gives it the full window: not 2000, which is
  // what the old deadline would have produced, but 3500 -- because what
  // the lease measures is how long since a heartbeat was seen, and one
  // that arrives at 1500 was seen at 1500.
  assert_eq(lease.deadline_ms, 3500UL)
  assert_eq(lease.expired(3499UL), false)
  assert_eq(lease.expired(3500UL), true)
}

///|
test "remaining time floors at zero instead of going negative" {
  let lease = @cluster.Lease::new(0UL, 2000UL)
  assert_eq(lease.remaining_ms(0UL), 2000UL)
  assert_eq(lease.remaining_ms(1999UL), 1UL)
  assert_eq(lease.remaining_ms(2000UL), 0UL)
  // Long after expiry the answer is still zero: a lease either has time
  // on it or it does not, and a caller warning about a leader needs a
  // one-sided number rather than a countdown into the past.
  assert_eq(lease.remaining_ms(100000UL), 0UL)
}

///|
test "a follower that keeps up never expires" {
  let lease = @cluster.Lease::new(0UL, @cluster.FOLLOWER_LEASE_MS)
  // Heartbeats at the leader's own cadence, each one landing well
  // inside the window the last one opened.
  let mut tick = 0UL
  for step in 0..<10 {
    let _step = step
    lease.refresh(tick)
    assert_eq(lease.expired(tick), false)
    tick = tick + @cluster.LEADER_HEARTBEAT_MS
  }
  // With no heartbeat for a full lease, it goes -- and the gap that
  // triggers it is several missed beats, not one.
  assert_eq(lease.expired(tick + @cluster.FOLLOWER_LEASE_MS), true)
}

///|
test "the static preference names the same successor from either side" {
  let config = leader_preference([1U, 2U, 3U].map(id => id.to_uint16()))
  // The order was fixed before anything failed, so two followers that
  // lose the same leader name the same candidate without first having
  // to agree on anything.
  assert_eq(config.candidate_after(1U.to_uint16()), Some(2U.to_uint16()))
  assert_eq(config.candidate_after(2U.to_uint16()), Some(1U.to_uint16()))
  assert_eq(config.candidate_after(3U.to_uint16()), Some(1U.to_uint16()))
}

///|
test "the failed leader is never its own successor" {
  // Reorder the preference so the failed member ranks first: the
  // exclusion is the rule, not an accident of where it sat.
  let reordered = leader_preference([3U, 1U, 2U].map(id => id.to_uint16()))
  assert_eq(reordered.candidate_after(3U.to_uint16()), Some(1U.to_uint16()))
}

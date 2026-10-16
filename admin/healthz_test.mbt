/// Pin the health report to the one quorum-state face: the /healthz
/// body, the gauge sample and the tier name the CLI column prints all
/// come from the same functions, verbatim, and the status code and
/// reason agree with the refusal and warning a producer sees.

///|
/// The four states under test with every surface's expected output as
/// literals: the tier name, the gauge code, and the reason JSON
/// fragment the body must carry.
fn states() -> Array[(@cluster.QuorumState, String, UInt32, String)] {
  [
    (@cluster.QuorumState::Healthy, "healthy", 0U, "null"),
    (@cluster.QuorumState::Soft, "soft", 1U, "null"),
    (
      @cluster.QuorumState::ReadOnly(@cluster.ReadOnlyReason::AckTimeout),
      "read_only",
      2U,
      "\"ack_timeout\"",
    ),
    (
      @cluster.QuorumState::ReadOnly(@cluster.ReadOnlyReason::NoFollower),
      "read_only",
      2U,
      "\"no_follower\"",
    ),
  ]
}

///|
test "the healthz body carries the tier name and code verbatim" {
  // Three surfaces, one source: the body's state word, the gauge's
  // code and the name a CLI column prints all read the same functions,
  // so a hand mapping in any one of them cannot appear.
  for (state, name, code, reason_json) in states() {
    let res = @admin.healthz_response(state, 7UL)
    assert_eq(
      res.body,
      "{\"state\":\"" +
      name +
      "\",\"leader_epoch\":7,\"reason\":" +
      reason_json +
      "}",
    )
    let sample = @admin.quorum_state_sample(state)
    assert_eq(sample.value, code.to_uint64())
    assert_eq(@cluster.QuorumState::tier_name(state), name)
  }
}

///|
test "the status code follows the degradation matrix" {
  // 200 for the writable tiers, 503 for the refusing tier -- the same
  // line a producer's refusal draws.
  for (state, _, _, _) in states() {
    let res = @admin.healthz_response(state, 0UL)
    let expected = if @cluster.QuorumState::may_write(state) {
      200U
    } else {
      503U
    }
    assert_eq(res.status_code, expected)
  }
}

///|
test "the health report agrees with the protocol error semantics" {
  // The refusal and warning a producer sees and the health report come
  // from one state value; a read-only body always pairs with a write
  // refusal, a soft body with the lag warning and no refusal.
  for (state, name, _, _) in states() {
    if name == "read_only" {
      assert_eq(
        @cluster.QuorumState::write_refusal(state),
        Some(@protocol.ReadOnlyDegraded),
      )
    } else {
      assert_eq(@cluster.QuorumState::write_refusal(state), None)
    }
    if name == "soft" {
      assert_eq(
        @cluster.QuorumState::warning(state),
        Some(@protocol.FollowerLag),
      )
    }
  }
}

///|
test "the reason names stay distinguishable for the operator" {
  // Both rows refuse writes, but the runbook sends one to the network
  // and the other to the follower -- the body must keep them apart.
  assert_eq(@cluster.ReadOnlyReason::AckTimeout.reason_name(), "ack_timeout")
  assert_eq(@cluster.ReadOnlyReason::NoFollower.reason_name(), "no_follower")
}

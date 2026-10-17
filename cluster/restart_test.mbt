/// A restarted replica remembers which term it was in.
///
/// `LeaderEpoch` opens at zero, and zero is the right value for a node
/// that has never held a term -- but only for that node. Opened at zero
/// after a restart, the fence in `serve_append` compares every incoming
/// term against nothing and rejects nothing, so a leader that still
/// calls itself the term it lost walks straight back in. That is the
/// common case rather than an exotic one: a returning leader usually
/// arrives after its own process came back.
///
/// The term comes from the metadata snapshot the node already recovers
/// on startup, so this is wiring rather than new state.

///|
async fn recovered_term() -> UInt64 {
  let disk : &@ports.Disk = @harness.FakeDisk::new()
  let snapshot : @metadata.SnapshotState = {
    machine: @metadata.DeclareMachine::new(),
    tracker: @metadata.ChangeTracker::new(),
    epoch: 5UL,
    end_offset: 0UL,
  }
  match @metadata.save_snapshot(disk, @metadata.SNAPSHOT_SLOT_A, snapshot) {
    Err(_) => fail("the snapshot must write")
    Ok(_) => ()
  }
  match @metadata.save_snapshot(disk, @metadata.SNAPSHOT_SLOT_B, snapshot) {
    Err(_) => fail("the redundant slot must write too")
    Ok(_) => ()
  }
  match
    @metadata.recover_snapshot(
      disk,
      @metadata.SNAPSHOT_SLOT_A,
      @metadata.SNAPSHOT_SLOT_B,
    ) {
    Err(_) => fail("a written snapshot must recover")
    Ok(recovered) => recovered.epoch
  }
}

///|
async test "a restored replica refuses a term from before the restart" {
  let term = recovered_term()
  assert_eq(term, 5UL)

  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let restored = epoch_sink_for(term)

  // The leader that was in power at term three comes back still calling
  // itself that. A fence opened at zero would let it in; the restored
  // one does not.
  let (outcome, reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    restored,
    claim(2U.to_uint16(), 3UL, 1UL),
  )
  assert_eq(outcome, Err(@protocol.StaleLeaderEpoch))
  match reply {
    Some(@cluster.PeerMsg::Reject(code)) => assert_eq(code, 0x6005U.to_uint16())
    _ => fail("the restored replica must refuse with a Reject frame")
  }
  // Refused before storage append, so the returning leader's write left
  // nothing behind.
  assert_eq(follower_log.held(), [])
  assert_eq(trace.val, [])
  // The restored value itself did not move: a refusal is not a reason
  // to forget the term this replica is protecting.
  assert_eq(restored.current(), 5UL)
}

///|
async test "a term at or above the restored one is still accepted" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let restored = epoch_sink_for(5UL)

  let (outcome, _reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    restored,
    claim(2U.to_uint16(), 5UL, 1UL),
  )
  match outcome {
    Err(_) => fail("the current term must be accepted, not refused")
    Ok(ack) => assert_eq(ack.flushed_seq, 1UL)
  }
  assert_eq(follower_log.held(), [1UL])
  assert_eq(restored.current(), 5UL)

  // A newer term is adopted the same way it would be on a fresh node:
  // restoring changes the floor, not how the epoch behaves afterwards.
  let (newer, _reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    restored,
    claim(2U.to_uint16(), 6UL, 2UL),
  )
  match newer {
    Err(_) => fail("a newer term must be accepted, not refused")
    Ok(ack) => assert_eq(ack.flushed_seq, 2UL)
  }
  assert_eq(restored.current(), 6UL)
}

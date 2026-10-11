/// One matrix, three tiers, and a write that is refused
/// rather than faked when the majority is gone.
///
/// Two halves. The first walks the frozen degradation matrix row by row
/// and checks that tier, gauge code, write verdict and warning all come
/// out of the same functions -- if `/healthz`, the gauge and the write
/// path ever disagree, it is because someone stopped reading this table.
/// The second runs the loss live: a follower that is slow enough to
/// miss the ack deadline turns the cluster read-only mid-round, and the
/// next round that completes with a majority brings it back.

///|
/// One row of the matrix as a test would read it: what the cluster
/// observed, and what every surface must then say.
struct MatrixRow {
  in_sync_count : Int
  trailing : Bool
  ack_timeout : Bool
  expected : @cluster.QuorumState
  gauge : UInt16
  may_write : Bool
  refusal : @protocol.ErrCode?
  warning : @protocol.ErrCode?
}

///|
fn matrix_rows() -> Array[MatrixRow] {
  let silent : @cluster.QuorumState = @cluster.QuorumState::ReadOnly(
    @cluster.ReadOnlyReason::NoFollower,
  )
  let timed_out : @cluster.QuorumState = @cluster.QuorumState::ReadOnly(
    @cluster.ReadOnlyReason::AckTimeout,
  )
  [
    {
      in_sync_count: 3,
      trailing: false,
      ack_timeout: false,
      expected: @cluster.QuorumState::Healthy,
      gauge: 0U.to_uint16(),
      may_write: true,
      refusal: None,
      warning: None,
    },
    {
      in_sync_count: 2,
      trailing: true,
      ack_timeout: false,
      expected: @cluster.QuorumState::Soft,
      gauge: 1U.to_uint16(),
      may_write: true,
      refusal: None,
      warning: Some(@protocol.FollowerLag),
    },
    {
      in_sync_count: 2,
      trailing: true,
      ack_timeout: true,
      expected: timed_out,
      gauge: 2U.to_uint16(),
      may_write: false,
      refusal: Some(@protocol.ReadOnlyDegraded),
      warning: None,
    },
    {
      in_sync_count: 1,
      trailing: true,
      ack_timeout: true,
      expected: silent,
      gauge: 2U.to_uint16(),
      may_write: false,
      refusal: Some(@protocol.InSyncReplicasNotEnough),
      warning: None,
    },
  ]
}

///|
test "every row of the degradation matrix reports the same tier everywhere" {
  let rows = matrix_rows()
  assert_eq(rows.length(), 4)
  let mut seen_gauge = 0
  for row in rows {
    let state = @cluster.classify_quorum(
      row.in_sync_count,
      2,
      row.trailing,
      row.ack_timeout,
    )
    assert_eq(state, row.expected)
    // The number the gauge, /healthz and the CLI print.
    assert_eq(state.code(), row.gauge)
    // Whether a producer may be answered at all.
    assert_eq(state.may_write(), row.may_write)
    // What that producer gets instead of a success.
    assert_eq(state.write_refusal(), row.refusal)
    // The advisory warning that rides alongside a success.
    assert_eq(state.warning(), row.warning)
    // Read-only rows share gauge 2 no matter which row caused them,
    // because the operator's alert asks whether writes are accepted --
    // not which of the two reasons said no.
    if !state.may_write() {
      assert_eq(state.code(), 2U.to_uint16())
      assert_eq(state.warning(), None)
    }
    seen_gauge = seen_gauge + 1
  }
  assert_eq(seen_gauge, 4)
}

///|
test "the three tiers are exactly three, and read-only collapses to one gauge" {
  // Healthy and soft are distinct numbers and both writable; the two
  // read-only rows are distinct reasons and one number. Four rows in,
  // three tiers out -- the shape the metric and the alert are built on.
  let codes = [
    @cluster.QuorumState::Healthy.code(),
    @cluster.QuorumState::Soft.code(),
    @cluster.QuorumState::ReadOnly(@cluster.ReadOnlyReason::AckTimeout).code(),
    @cluster.QuorumState::ReadOnly(@cluster.ReadOnlyReason::NoFollower).code(),
  ]
  assert_eq(codes, [
    0U.to_uint16(),
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
  ])
  // A refusal is a refusal whatever caused it: no read-only tier ever
  // reports a warning, because the refusal already carries the message
  // and a warning on top of an error would read as success-with-caveat.
  assert_eq(
    @cluster.QuorumState::ReadOnly(@cluster.ReadOnlyReason::AckTimeout).write_refusal(),
    Some(@protocol.ReadOnlyDegraded),
  )
  assert_eq(
    @cluster.QuorumState::ReadOnly(@cluster.ReadOnlyReason::NoFollower).write_refusal(),
    Some(@protocol.InSyncReplicasNotEnough),
  )
}

///|
async test "a missed quorum acknowledgement refuses the write and the next round recovers" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let leader_log = traced_log("leader", trace)
  let follower_log = traced_log("follower", trace)
  let secret = fixture_secret()
  let server = bind_loopback()
  let port = server.addr.port()
  // Short enough that the first round misses it, long enough that a
  // loopback round trip never does by accident.
  let missed_deadline_ms = 100
  // Longer than the deadline, so the follower genuinely applies the
  // first batch -- just not in time to answer for it.
  let follower_delay_ms = 400

  let follower_config = handshake_config(
    1U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  let leader_config = handshake_config(
    2U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  let follower = @cluster.ClusterNode::new(follower_config)
  let leader = @cluster.ClusterNode::new(leader_config)
  let follower_epoch = fresh_epoch()

  // A node that has completed no round has seen nothing go wrong.
  assert_eq(leader.quorum_state(), @cluster.QuorumState::Healthy)
  assert_eq(leader.quorum_state().code(), 0U.to_uint16())

  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      for round in 0..<2 {
        match
          @async.with_timeout_opt(handshake_budget_ms(), () => server.accept()) {
          None => ()
          Some(accepted) => {
            let concrete : LoopConn = { tcp: accepted.0, }
            let conn : &@net.Conn = concrete
            match @cluster.ClusterNode::serve_peer(follower, conn) {
              Err(_) => ()
              Ok(_) => {
                if round == 0 {
                  // The write lands, the reply does not come back inside
                  // the deadline. Delaying before the round rather than
                  // skipping it keeps the follower's log in step with the
                  // leader's, so the second round is a genuine recovery
                  // and not a catch-up this code does not have yet.
                  @async.sleep(follower_delay_ms)
                }
                match
                  @cluster.ClusterNode::serve_append(
                    follower, conn, follower_log, follower_epoch,
                  ) {
                  Err(_) => ()
                  Ok(_) => ()
                }
              }
            }
            @net.Conn::close(conn)
          }
        }
      }
    }

    // ---- round one: the majority never answers -------------------
    match dial_loopback(port) {
      Err(_) => fail("the listener is bound, so the dial must connect")
      Ok(conn) => {
        let expected = match leader_config.peer_entry(1U.to_uint16()) {
          None => fail("node 1 must be in the static table")
          Some(entry) => entry
        }
        match @cluster.ClusterNode::dial_peer(leader, conn, expected) {
          Err(_) =>
            fail("both sides hold the same secret, so the handshake must pass")
          Ok(_) => {
            let outcome = @cluster.ClusterNode::send_append(
              leader,
              conn,
              leader_log,
              1UL,
              [b"one"],
              true,
              missed_deadline_ms,
            )
            // The point of the whole requirement: a write the cluster
            // could not put on a majority of disks is refused, never
            // acknowledged on the leader's word alone.
            assert_eq(outcome, Err(@protocol.ReadOnlyDegraded))
            assert_eq(
              leader.quorum_state(),
              @cluster.QuorumState::ReadOnly(
                @cluster.ReadOnlyReason::AckTimeout,
              ),
            )
            assert_eq(leader.quorum_state().code(), 2U.to_uint16())
            assert_eq(leader.quorum_state().may_write(), false)
            assert_eq(
              leader.quorum_state().write_refusal(),
              Some(@protocol.ReadOnlyDegraded),
            )
            // The leader is durable at one and that still commits
            // nothing: its own fsync is one copy, not a quorum.
            assert_eq(leader_log.last_flushed_seq(), 1UL)
            assert_eq(leader.commit_horizon(leader_log.last_flushed_seq()), 0UL)
          }
        }
        @net.Conn::close(conn)
      }
    }

    // ---- round two: a majority answers, the cluster comes back ----
    match dial_loopback(port) {
      Err(_) => fail("the listener is bound, so the dial must connect")
      Ok(conn) => {
        let expected = match leader_config.peer_entry(1U.to_uint16()) {
          None => fail("node 1 must be in the static table")
          Some(entry) => entry
        }
        match @cluster.ClusterNode::dial_peer(leader, conn, expected) {
          Err(_) =>
            fail("both sides hold the same secret, so the handshake must pass")
          Ok(_) => {
            let outcome = @cluster.ClusterNode::send_append(
              leader,
              conn,
              leader_log,
              1UL,
              [b"two"],
              true,
              handshake_budget_ms(),
            )
            match outcome {
              Err(_) =>
                fail("the second round must be acknowledged, not refused")
              Ok(ack) => assert_eq(ack.flushed_seq, 2UL)
            }
            // Read-only clears itself: the same classification that
            // declared the loss declares the return, so recovery needs
            // no separate trigger.
            assert_eq(leader.quorum_state(), @cluster.QuorumState::Soft)
            assert_eq(leader.quorum_state().code(), 1U.to_uint16())
            assert_eq(leader.quorum_state().may_write(), true)
            assert_eq(leader.quorum_state().write_refusal(), None)
            // The ceiling advanced and never retreated: it went from
            // zero to two across a read-only stretch in between.
            assert_eq(leader.commit_horizon(leader_log.last_flushed_seq()), 2UL)
          }
        }
        @net.Conn::close(conn)
      }
    }
  }
  // The follower really did apply both batches -- it was slow, not
  // absent -- which is what makes the second round a recovery rather
  // than a replay of a write that never landed.
  assert_eq(follower_log.last_appended_seq(), 2UL)
  assert_eq(follower_log.last_flushed_seq(), 2UL)
}

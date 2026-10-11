/// One matrix, three tiers, and a write that is refused
/// rather than faked when the majority is gone.
///
/// Two halves. The first walks the frozen degradation matrix row by row
/// and checks that tier, gauge code, write verdict and warning all come
/// out of the same functions -- if `/healthz`, the gauge and the write
/// path ever disagree, it is because someone stopped reading this table.
/// The second runs the loss live: a follower that never answers inside
/// the deadline turns the cluster read-only mid-round, a write offered
/// while it is read-only is refused before it reaches the log, and a
/// catch-up that finally closes the gap brings it back. A third case
/// covers a peer that is simply gone, and a fourth runs all three nodes
/// so that the row where a majority is durable and one ack runs out the
/// clock -- which one follower cannot reach -- is exercised too.

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
      refusal: Some(@protocol.ReadOnlyDegraded),
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
  // A refusal is a refusal whatever caused it: both read-only rows
  // owe a producer the same registered code and neither reports a
  // warning, because a warning on top of an error would read as
  // success-with-caveat. The reason survives in the type for whoever
  // is reading the state, not on the wire for whoever is being told no.
  assert_eq(
    @cluster.QuorumState::ReadOnly(@cluster.ReadOnlyReason::AckTimeout).write_refusal(),
    Some(@protocol.ReadOnlyDegraded),
  )
  assert_eq(
    @cluster.QuorumState::ReadOnly(@cluster.ReadOnlyReason::NoFollower).write_refusal(),
    Some(@protocol.ReadOnlyDegraded),
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
  let leader_epoch = fresh_epoch()

  // A node that has completed no round has seen nothing go wrong, and
  // has nothing to report about it either.
  assert_eq(leader.quorum_state(), @cluster.QuorumState::Healthy)
  assert_eq(leader.quorum_state().code(), 0U.to_uint16())
  assert_eq(leader.take_quorum_event(), None)

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
              Ok(link) =>
                if round == 0 {
                  // The reply the leader is waiting for never comes: the
                  // connection is held open without an answer, so the
                  // deadline is what ends the round rather than a reset.
                  // The batch is deliberately never applied either, so
                  // round two has a real gap to close rather than a
                  // follower that was always in step.
                  @async.sleep(follower_delay_ms)
                } else {
                  match
                    @cluster.ClusterNode::serve_append(
                      follower, link, follower_log, follower_epoch,
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
          Ok(link) => {
            let outcome = @cluster.ClusterNode::send_append(
              leader,
              link,
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
            // Which read-only row this is belongs to the table, not to
            // this call: nothing has been acknowledged yet, so there is
            // no follower in sync and that row is read before the
            // timeout row. A producer is told the same code either way.
            assert_eq(
              leader.quorum_state(),
              @cluster.QuorumState::ReadOnly(
                @cluster.ReadOnlyReason::NoFollower,
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
            // Entering read-only is an edge and is reported once; a
            // cluster that stays there does not keep saying so.
            assert_eq(leader.take_quorum_event(), Some(@protocol.QuorumLost))
            assert_eq(leader.take_quorum_event(), None)

            // A cluster already refusing writes does not start another
            // round: the payload never reaches its own disk, and that
            // is the assertion to read first, because without the
            // refusal the log below would read two -- the batch is
            // written locally before anything is shipped, so the only
            // thing that keeps it off the disk is being told no
            // before it starts.
            let refused = @cluster.ClusterNode::send_append(
              leader,
              link,
              leader_log,
              1UL,
              [b"two"],
              true,
              handshake_budget_ms(),
            )
            assert_eq(leader_log.last_flushed_seq(), 1UL)
            assert_eq(refused, Err(@protocol.ReadOnlyDegraded))
            // Refusing a write is not a new event: the cluster was
            // already reported lost, so nothing is owed a second time.
            assert_eq(leader.take_quorum_event(), None)
          }
        }
        @net.Conn::close(conn)
      }
    }

    // ---- round two: catch-up closes the gap, the cluster comes back --
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
          Ok(link) => {
            // Re-sending what is already written is the one round a
            // read-only cluster still runs: a new payload is refused
            // above, but bringing a follower up to date is how the
            // majority comes back at all.
            assert_eq(leader_epoch.elect(1UL), Ok(1UL))
            let healed = @cluster.ClusterNode::catch_up(
              leader,
              link,
              leader_log,
              leader_epoch,
              4,
              handshake_budget_ms(),
            )
            match healed {
              Err(_) =>
                fail("catch-up must finish against a listening follower")
              Ok(target) => assert_eq(target, 1UL)
            }
            // Read-only clears itself: the same classification that
            // declared the loss declares the return, so recovery needs
            // no separate trigger -- and the tier it lands on is the
            // table's, which here has a majority durable and one member
            // still behind.
            assert_eq(leader.quorum_state(), @cluster.QuorumState::Soft)
            assert_eq(leader.quorum_state().code(), 1U.to_uint16())
            assert_eq(leader.quorum_state().may_write(), true)
            assert_eq(leader.quorum_state().write_refusal(), None)
            // Getting the majority back is the other edge, reported
            // once as well.
            assert_eq(
              leader.take_quorum_event(),
              Some(@protocol.QuorumRecovered),
            )
            assert_eq(leader.take_quorum_event(), None)
            // The ceiling advanced and never retreated: it went from
            // zero to one across a read-only stretch in between.
            assert_eq(leader.commit_horizon(leader_log.last_flushed_seq()), 1UL)
          }
        }
        @net.Conn::close(conn)
      }
    }
  }
  // The follower had nothing and now holds the one entry the leader
  // wrote while the cluster was read-only: it was caught up, not
  // present all along, which is what made the return a recovery.
  assert_eq(follower_log.last_appended_seq(), 1UL)
  assert_eq(follower_log.last_flushed_seq(), 1UL)
}

///|
/// A round whose peer is gone still leaves the tier, because every exit
/// is classified -- not only the ones that reached an answer.
///
/// The failure here happens with no deadline and no reply: the far end
/// handshakes and then disappears. A path that re-evaluated the quorum
/// only after a completed round would leave this cluster reporting a
/// health nobody tested, and the alarm that follows a lost majority
/// would never fire.
async test "a round to a peer that has gone leaves the tier, not the health it started with" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let leader_log = traced_log("leader", trace)
  let secret = fixture_secret()
  let server = bind_loopback()
  let port = server.addr.port()
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

  assert_eq(leader.quorum_state(), @cluster.QuorumState::Healthy)

  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      // Handshake, then gone: what a restart or a dropped link looks
      // like from the other side.
      defer server.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => server.accept()) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          match @cluster.ClusterNode::serve_peer(follower, conn) {
            Err(_) => ()
            Ok(_) => ()
          }
          @net.Conn::close(conn)
        }
      }
    }

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
          Ok(link) => {
            // The far end is gone by now. However this round fails --
            // a write the transport refuses, or a reply that never
            // arrives -- it ends, and the tier is re-read on that exit
            // just as it is on one that completed.
            let outcome = @cluster.ClusterNode::send_append(
              leader,
              link,
              leader_log,
              1UL,
              [b"one"],
              true,
              300,
            )
            match outcome {
              Err(_) => ()
              Ok(_) => fail("there is nobody left on the far end to answer")
            }
            assert_eq(
              leader.quorum_state(),
              @cluster.QuorumState::ReadOnly(
                @cluster.ReadOnlyReason::NoFollower,
              ),
            )
            assert_eq(leader.quorum_state().code(), 2U.to_uint16())
            assert_eq(leader.quorum_state().may_write(), false)
            assert_eq(leader.take_quorum_event(), Some(@protocol.QuorumLost))
            assert_eq(leader.take_quorum_event(), None)
            // The connection behind the link is gone, so the link goes
            // with it rather than staying in the table as a member the
            // node still claims it can reach.
            assert_eq(leader.link_count(), 0)
            // Nothing was answered, so nothing about durability
            // changed: the leader's own fsync is still one copy.
            assert_eq(leader_log.last_flushed_seq(), 1UL)
            assert_eq(leader.commit_horizon(leader_log.last_flushed_seq()), 0UL)
          }
        }
        @net.Conn::close(conn)
      }
    }
  }
}

///|
/// A configuration whose whole static table points at listeners that
/// actually exist.
///
/// The handshake fixture puts only one peer on a bound port, which is
/// enough for a leader and a follower but cannot put a second member in
/// sync -- and without a second member the majority row of the
/// degradation matrix is unreachable. This takes the three ports
/// separately so a test can run every node it names.
fn three_node_config(
  node_id : UInt16,
  own_port : Int,
  first_port : Int,
  second_port : Int,
  third_port : Int,
  secret : @cluster.PeerSecret,
) -> @cluster.ClusterConfig raise {
  let peers : Array[@cluster.PeerEntry] = [
    { node_id: 1U.to_uint16(), host: "127.0.0.1", port: first_port, },
    { node_id: 2U.to_uint16(), host: "127.0.0.1", port: second_port, },
    { node_id: 3U.to_uint16(), host: "127.0.0.1", port: third_port, },
  ]
  let priority = peers.map(row => row.node_id)
  match
    @cluster.ClusterConfig::new(
      node_id, peers, priority, "127.0.0.1", own_port, secret,
    ) {
    Ok(config) => config
    Err(_) => fail("three distinct loopback ports make a valid static table")
  }
}

///|
/// A majority that is already durable, and one ack that never arrives.
///
/// This is the row one follower cannot reach. A round that times out
/// has, with a single member, nobody in sync -- so it can only ever be
/// read as "no follower", and the soft-timeout row stays unreachable no
/// matter how the classification is wired. Here all three nodes run:
/// one keeps up, one never answers, and the majority that forms is what
/// makes the distinction matter at all. Both rows refuse the write, so
/// a producer notices nothing; what differs is the *next* write. With
/// the deadline ignored this reads `Soft`, a tier that keeps accepting
/// writes it cannot put on a majority of disks.
async test "a missed ack with a durable majority is a timeout, not a lost follower" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let leader_log = traced_log("leader", trace)
  let keeper_log = traced_log("keeper", trace)
  let silent_log = traced_log("silent", trace)
  let secret = fixture_secret()
  let keeper_server = bind_loopback()
  let silent_server = bind_loopback()
  let spare_server = bind_loopback()
  let first_port = keeper_server.addr.port()
  let third_port = silent_server.addr.port()
  let second_port = spare_server.addr.port()

  let keeper_config = three_node_config(
    1U.to_uint16(),
    first_port,
    first_port,
    second_port,
    third_port,
    secret,
  )
  let leader_config = three_node_config(
    2U.to_uint16(),
    second_port,
    first_port,
    second_port,
    third_port,
    secret,
  )
  let silent_config = three_node_config(
    3U.to_uint16(),
    third_port,
    first_port,
    second_port,
    third_port,
    secret,
  )
  let keeper = @cluster.ClusterNode::new(keeper_config)
  let silent = @cluster.ClusterNode::new(silent_config)
  let leader = @cluster.ClusterNode::new(leader_config)
  let keeper_epoch = fresh_epoch()
  let leader_epoch = fresh_epoch()
  assert_eq(leader_epoch.elect(1UL), Ok(1UL))

  assert_eq(leader.quorum_state(), @cluster.QuorumState::Healthy)

  @async.with_task_group() <| group => {
    // The member that keeps up: it answers the first round and is done
    // afterwards, having already put itself on the leader's position.
    group.spawn_bg() <| () => {
      defer keeper_server.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => {
          keeper_server.accept()
        }) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          match @cluster.ClusterNode::serve_peer(keeper, conn) {
            Err(_) => ()
            Ok(link) =>
              match
                @cluster.ClusterNode::serve_append(
                  keeper, link, keeper_log, keeper_epoch,
                ) {
                Err(_) => ()
                Ok(_) => ()
              }
          }
          @net.Conn::close(conn)
        }
      }
    }
    // The member that never answers: it completes the handshake and
    // then holds the connection open, which is what makes the round run
    // out its clock rather than fail on a reset.
    group.spawn_bg() <| () => {
      defer silent_server.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => {
          silent_server.accept()
        }) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          match @cluster.ClusterNode::serve_peer(silent, conn) {
            Err(_) => ()
            Ok(_) => ()
          }
          @async.sleep(600)
          @net.Conn::close(conn)
        }
      }
    }

    // ---- round one: the majority forms --------------------------------
    match dial_loopback(first_port) {
      Err(_) => fail("the keeper's listener is bound, so the dial must connect")
      Ok(conn) => {
        let expected = match leader_config.peer_entry(1U.to_uint16()) {
          None => fail("node 1 must be in the static table")
          Some(entry) => entry
        }
        match @cluster.ClusterNode::dial_peer(leader, conn, expected) {
          Err(_) =>
            fail("both sides hold the same secret, so the handshake must pass")
          Ok(link) => {
            let outcome = @cluster.ClusterNode::send_append(
              leader,
              link,
              leader_log,
              1UL,
              [b"one"],
              true,
              handshake_budget_ms(),
            )
            match outcome {
              Err(_) =>
                fail("the keeper answers, so this round must be acknowledged")
              Ok(ack) => assert_eq(ack.flushed_seq, 1UL)
            }
            // A majority is durable and the third member has not spoken:
            // that is the tier that still accepts writes.
            assert_eq(leader.quorum_state(), @cluster.QuorumState::Soft)
            assert_eq(leader.quorum_state().code(), 1U.to_uint16())
            assert_eq(leader.quorum_state().may_write(), true)
            assert_eq(leader.take_quorum_event(), None)
          }
        }
        @net.Conn::close(conn)
      }
    }

    // ---- round two: the straggler is asked, and never answers ---------
    match dial_loopback(third_port) {
      Err(_) => fail("the silent listener is bound, so the dial must connect")
      Ok(conn) => {
        let expected = match leader_config.peer_entry(3U.to_uint16()) {
          None => fail("node 3 must be in the static table")
          Some(entry) => entry
        }
        match @cluster.ClusterNode::dial_peer(leader, conn, expected) {
          Err(_) =>
            fail("both sides hold the same secret, so the handshake must pass")
          Ok(link) => {
            let healed = @cluster.ClusterNode::catch_up(
              leader, link, leader_log, leader_epoch, 4, 200,
            )
            match healed {
              Err(_) => ()
              Ok(_) =>
                fail("nobody answers on this link, so catch-up cannot finish")
            }
            // The keeper never went away, so a majority is still
            // durable: this round ran out the clock, it did not lose
            // the cluster. Reading it as `Soft` would wave through the
            // next write.
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
            assert_eq(leader.take_quorum_event(), Some(@protocol.QuorumLost))
            assert_eq(leader.take_quorum_event(), None)
          }
        }
        @net.Conn::close(conn)
      }
    }
  }
  spare_server.close()
  // The keeper did its job and still holds what the leader wrote.
  assert_eq(keeper_log.last_flushed_seq(), 1UL)
  // The silent member was asked and got nothing down: one copy, not a
  // majority, which is why the round above is refused.
  assert_eq(silent_log.last_appended_seq(), 0UL)
}

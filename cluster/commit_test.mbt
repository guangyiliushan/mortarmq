/// `PUB_OK` waits for a majority to fsync.
///
/// The unit cases fix the arithmetic against each way it could be wrong
/// -- leader-only, dirty-only, a laggard, a follower reporting past the
/// leader -- and the integration case runs the whole gate over three
/// real loopback nodes so the determination rests on a live cluster
/// rather than on a table of numbers.

///|
/// A three-member node whose peers have reported the given positions.
///
/// `flushed` and `dirty` are separate per peer so a case can say "wrote
/// it, did not fsync it" without needing a live follower.
fn quorum_node(
  reports : Array[(UInt16, UInt64, UInt64)],
) -> @cluster.ClusterNode raise {
  let node = tracked_node()
  for report in reports {
    let ack : @cluster.AppendAck = {
      follower_id: report.0,
      leader_epoch: 1UL,
      flushed_seq: report.1,
      dirty_seq: report.2,
    }
    match @cluster.ClusterNode::record_append_ack(node, ack, report.0) {
      Err(_) =>
        fail(
          "the fixture peer is in the static table, so this must be accepted",
        )
      Ok(_) => ()
    }
  }
  node
}

///|
test "a leader that has fsynced on its own has committed nothing" {
  let alone = quorum_node([])
  // The leader holds the write on disk and no follower has reported
  // anything: one durable copy out of three is not a quorum, so the
  // horizon stays at zero and every write waits.
  assert_eq(alone.commit_horizon(5UL), 0UL)
  assert_eq(alone.may_publish(1UL, 5UL), false)
  assert_eq(alone.may_publish(5UL, 5UL), false)
  assert_eq(alone.commit_horizon(0UL), 0UL)
}

///|
test "one follower fsyncing with the leader reaches the quorum" {
  let node = quorum_node([(2U.to_uint16(), 3UL, 3UL)])
  assert_eq(node.commit_horizon(3UL), 3UL)
  assert_eq(node.may_publish(3UL, 3UL), true)
  // The next write is not durable on two nodes yet, so it waits.
  assert_eq(node.may_publish(4UL, 3UL), false)
}

///|
test "a member that never acknowledged does not hold the write back" {
  // Three members, two durable, one silent: the majority is already
  // there and the third node's absence is exactly what a quorum is
  // designed to tolerate.
  let node = quorum_node([(2U.to_uint16(), 3UL, 3UL)])
  assert_eq(node.commit_horizon(3UL), 3UL)
  assert_eq(node.may_publish(3UL, 3UL), true)
}

///|
test "a follower that only wrote, and did not fsync, does not count" {
  // The follower is at five locally but has made nothing durable, so
  // counting it would commit a write a crash could take away.
  let written = quorum_node([(2U.to_uint16(), 0UL, 5UL)])
  assert_eq(written.commit_horizon(5UL), 0UL)
  assert_eq(written.may_publish(5UL, 5UL), false)
  // Once it fsyncs, the same write commits.
  let flushed = quorum_node([(2U.to_uint16(), 5UL, 5UL)])
  assert_eq(flushed.commit_horizon(5UL), 5UL)
  assert_eq(flushed.may_publish(5UL, 5UL), true)
}

///|
test "the horizon never runs past the leader own durability" {
  // Both followers report ten while the leader has only three. A
  // majority of three would say ten, which is why the cap exists:
  // `commit_seq <= leader.last_flushed_seq` has to hold even when the
  // inputs do not arrange themselves that way.
  let ahead = quorum_node([
    (2U.to_uint16(), 10UL, 10UL),
    (3U.to_uint16(), 10UL, 10UL),
  ])
  assert_eq(ahead.commit_horizon(3UL), 3UL)
  assert_eq(ahead.may_publish(4UL, 3UL), false)
}

///|
test "sequence zero is never publishable" {
  let node = quorum_node([
    (2U.to_uint16(), 3UL, 3UL),
    (3U.to_uint16(), 3UL, 3UL),
  ])
  assert_eq(node.commit_horizon(3UL), 3UL)
  // Every real write has a sequence of at least one; zero names nothing.
  assert_eq(node.may_publish(0UL, 3UL), false)
}

///|
async test "a live three-node cluster commits only what a majority has fsynced" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let leader_log = traced_log("leader", trace)
  let follower_log = traced_log("follower", trace)
  let secret = fixture_secret()
  let server_one = bind_loopback()
  let server_two = bind_loopback()
  let server_three = bind_loopback()
  let ports = [
    server_one.addr.port(),
    server_two.addr.port(),
    server_three.addr.port(),
  ]
  let leader = cluster_node(1U.to_uint16(), ports[0], ports, secret)
  let follower = cluster_node(2U.to_uint16(), ports[1], ports, secret)
  // Node 3 is bound and in the table but takes no part in either round:
  // the majority the gate needs is the leader plus one follower.
  let _laggard = cluster_node(3U.to_uint16(), ports[2], ports, secret)
  let follower_epoch = fresh_epoch()
  defer server_one.close()
  defer server_three.close()

  let gate : Ref[Array[Bool]] = Ref::Ref([])
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server_two.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => server_two.accept()) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          match @cluster.ClusterNode::serve_peer(follower, conn) {
            Err(_) => ()
            Ok(link) =>
              // Two rounds on one link: the first asks for an fsync,
              // the second deliberately does not.
              for _ in 0..<2 {
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
    match dial_loopback(ports[1]) {
      Err(_) => fail("node 2 is listening, so the dial must connect")
      Ok(conn) => {
        let expected = match leader.config().peer_entry(2U.to_uint16()) {
          None => fail("node 2 must be in the static table")
          Some(entry) => entry
        }
        match @cluster.ClusterNode::dial_peer(leader, conn, expected) {
          Err(_) =>
            fail("both sides hold the same secret, so the handshake must pass")
          Ok(link) => {
            // Nothing is durable anywhere yet, so nothing may be
            // acknowledged.
            gate.val.push(
              leader.may_publish(1UL, leader_log.last_flushed_seq()),
            )
            let first = @cluster.ClusterNode::send_append(
              leader,
              link,
              leader_log,
              1UL,
              [b"one"],
              true,
              handshake_budget_ms(),
            )
            match first {
              Err(_) => fail("the first round must complete")
              Ok(ack) => assert_eq(ack.flushed_seq, 1UL)
            }
            // Leader and follower both fsynced entry 1: a majority, so
            // it may be acknowledged.
            gate.val.push(
              leader.may_publish(1UL, leader_log.last_flushed_seq()),
            )
            let second = @cluster.ClusterNode::send_append(
              leader,
              link,
              leader_log,
              1UL,
              [b"two"],
              false,
              handshake_budget_ms(),
            )
            match second {
              Err(_) => fail("the second round must complete")
              Ok(ack) => {
                // The follower wrote it and said so through dirty_seq,
                // but did not fsync it.
                assert_eq(ack.dirty_seq, 2UL)
                assert_eq(ack.flushed_seq, 1UL)
              }
            }
            // The leader has fsynced two entries and only one of them
            // is on a majority of disks -- the second waits.
            assert_eq(leader_log.last_flushed_seq(), 2UL)
            gate.val.push(
              leader.may_publish(2UL, leader_log.last_flushed_seq()),
            )
            gate.val.push(
              leader.may_publish(1UL, leader_log.last_flushed_seq()),
            )
            assert_eq(leader.commit_horizon(leader_log.last_flushed_seq()), 1UL)
          }
        }
        @net.Conn::close(conn)
      }
    }
  }
  // Nothing, then one entry, then still only one: the gate opened
  // exactly when the majority fsynced and did not open a step earlier
  // just because the leader was durable.
  assert_eq(gate.val, [false, true, false, true])
  assert_eq(follower_log.last_appended_seq(), 2UL)
  assert_eq(follower_log.last_flushed_seq(), 1UL)
}

///|
/// A committed prefix is capped at what this replica actually holds.
///
/// The number that travels with an install is a promise about what a
/// majority has, not a position this replica is in. Taking it as written
/// would let one member hand over a committed prefix naming entries that
/// are not here, and the horizon read off it would call a write durable
/// that no majority can recover.
async test "a committed prefix past the end of one's own log is capped" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let log = traced_log("replica", trace)
  let node = tracked_node()
  // Nothing written here: nothing can be committed here either.
  node.note_committed(5UL, log)
  assert_eq(node.commit_seq(), 0UL)

  match log.append([b"a", b"b"], true) {
    Err(_) => fail("the fixture log must accept its seed")
    Ok(_) => ()
  }
  // Past the end, so what is held is what is taken.
  node.note_committed(5UL, log)
  assert_eq(node.commit_seq(), 2UL)
  // Within the log it is taken as written, and never walks backwards.
  node.note_committed(1UL, log)
  assert_eq(node.commit_seq(), 2UL)
}

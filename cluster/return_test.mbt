/// A leader that was killed comes back: fenced on the term it lost, and
/// caught up on the entries it missed while it was away.
///
/// Two directions, and the fixture supports both -- the served node and
/// the returning one swap between the cases because they are different
/// events. Being fenced is something that happens *to* the returning
/// node when it still believes it leads; being caught up is something
/// the new leader does *to* it once it has stopped believing that.

///|
/// An `APPEND` claiming `leader_id` is in force at `epoch`.
fn claim(
  leader_id : UInt16,
  epoch : UInt64,
  base : UInt64,
) -> @cluster.AppendBatch {
  {
    leader_id,
    leader_epoch: epoch,
    base_seq: base,
    flush_after_append: true,
    entries: [b"payload"],
  }
}

///|
/// Bring a returning replica up to the new leader's log over a fresh
/// loopback link, reporting what it ended up holding.
///
/// Returns the sequence the leader's log ends at, the sequences the
/// returning node holds afterwards, and the term it now recognises.
async fn catch_up_round(
  leader : @cluster.ClusterNode,
  leader_log : TracedLog,
  leader_term : @cluster.LeaderEpoch,
  returning_log : TracedLog,
  returning_term : @cluster.LeaderEpoch,
) -> (Result[UInt64, @protocol.ErrCode], Array[UInt64], UInt64) {
  let secret = fixture_secret()
  let server = bind_loopback()
  let port = server.addr.port()
  let returning_config = handshake_config(
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

  let outcome : Ref[Result[UInt64, @protocol.ErrCode]] = Ref::Ref(
    Err(@protocol.Internal),
  )
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => server.accept()) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          let node = @cluster.ClusterNode::new(returning_config)
          match @cluster.ClusterNode::serve_peer(node, conn) {
            Err(_) => ()
            Ok(link) =>
              match
                @cluster.ClusterNode::serve_append(
                  node, link, returning_log, returning_term,
                ) {
                Err(_) => ()
                Ok(_) => ()
              }
          }
          @net.Conn::close(conn)
        }
      }
    }
    match dial_loopback(port) {
      Err(_) => fail("the listener is bound, so the dial must connect")
      Ok(conn) => {
        let expected = match leader_config.peer_entry(1U.to_uint16()) {
          None => fail("the returning node must be in the static table")
          Some(entry) => entry
        }
        match @cluster.ClusterNode::dial_peer(leader, conn, expected) {
          Err(_) =>
            fail("both sides hold the same secret, so the handshake must pass")
          Ok(link) =>
            outcome.val = @cluster.ClusterNode::catch_up(
              leader,
              link,
              leader_log,
              leader_term,
              4,
              handshake_budget_ms(),
            )
        }
        @net.Conn::close(conn)
      }
    }
  }
  (outcome.val, returning_log.held(), returning_term.current())
}

///|
async test "a returning leader is fenced on the term it lost" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let new_leader_log = traced_log("leader", trace)
  let new_leader_term = fresh_epoch()
  // The election already happened: this replica has taken up term two
  // and written it durably.
  assert_eq(new_leader_term.elect(2UL), Ok(2UL))

  // The leader that was killed comes back still claiming term one and
  // still writing as though it held it.
  let (outcome, reply) = handwritten_append(
    2U.to_uint16(),
    1U.to_uint16(),
    2U.to_uint16(),
    new_leader_log,
    new_leader_term,
    claim(1U.to_uint16(), 1UL, 1UL),
  )
  assert_eq(outcome, Err(@protocol.StaleLeaderEpoch))
  match reply {
    Some(@cluster.PeerMsg::Reject(code)) => assert_eq(code, 0x6005U.to_uint16())
    _ => fail("the new leader must refuse with a Reject frame")
  }
  // Refused before storage append: the returning leader's write left
  // nothing behind, so there is no split to reconcile afterwards.
  assert_eq(new_leader_log.held(), [])
  assert_eq(trace.val, [])
}

///|
async test "a returning leader is caught up on the entries it missed" {
  let leader_trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let returning_trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let leader_log = traced_log("leader", leader_trace)
  let returning_log = traced_log("returning", returning_trace)
  let leader_term = fresh_epoch()
  let returning_term = fresh_epoch()

  // The cluster is three entries in; the returning node went away after
  // two of them and has not seen the third.
  match leader_log.append([b"a", b"b", b"c"], true) {
    Err(_) => fail("the fixture log must accept its seed")
    Ok(_) => ()
  }
  match returning_log.append([b"a", b"b"], true) {
    Err(_) => fail("the fixture log must accept its seed")
    Ok(_) => ()
  }
  assert_eq(leader_log.held(), [1UL, 2UL, 3UL])
  assert_eq(returning_log.held(), [1UL, 2UL])

  // The new leader won term two; the returning node is still on one.
  assert_eq(leader_term.elect(2UL), Ok(2UL))
  assert_eq(returning_term.elect(1UL), Ok(1UL))

  // The leader already knows where that node stood when it went away,
  // from the acknowledgement it last received -- which is what lets
  // catch-up resume instead of restarting from the beginning.
  let known : @cluster.AppendAck = {
    follower_id: 1U.to_uint16(),
    leader_epoch: 1UL,
    flushed_seq: 2UL,
    dirty_seq: 2UL,
  }
  let leader = @cluster.ClusterNode::new(
    handshake_config(2U.to_uint16(), 7191, 2U.to_uint16(), fixture_secret()),
  )
  match @cluster.ClusterNode::record_append_ack(leader, known) {
    Err(_) => fail("a reported position from a peer must be accepted")
    Ok(_) => ()
  }

  let (outcome, held, term) = catch_up_round(
    leader, leader_log, leader_term, returning_log, returning_term,
  )
  assert_eq(outcome, Ok(3UL))
  // Parity: the same three sequences the rest of the cluster has, and
  // no ghost of the two it already held.
  assert_eq(held, [1UL, 2UL, 3UL])
  assert_eq(returning_log.last_flushed_seq(), 3UL)
  // Its old term is gone: it now recognises the one that replaced it.
  assert_eq(term, 2UL)
  // The first two events are the seed this fixture wrote. After them,
  // exactly one batch went out and it carried the one entry the node was
  // missing: resending the prefix it already held would have shown up
  // here as another append at 1 or 2.
  assert_eq(returning_trace.val, [
    ("returning.append", 1UL),
    ("returning.flush", 2UL),
    ("returning.append", 3UL),
    ("returning.flush", 3UL),
  ])
}

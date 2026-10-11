/// The proved identity of a link is the only identity a message on it
/// may claim.
///
/// Both cases below name a node that *is* in the static table -- the
/// check that used to run was membership, and membership passes for any
/// of the three. What makes them refusals now is that neither node is
/// the one that completed the handshake on this particular connection.
/// The first would have let a reachable member write into another
/// member's log; the second would have let an answer from nobody move
/// the commit horizon.

///|
async test "a batch naming a member other than the one on this link is refused" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let follower_epoch = fresh_epoch()

  // The connection proves node 2; the batch claims node 3, which is a
  // member of the table and therefore passes any membership test.
  let (outcome, _reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    follower_epoch,
    claim(3U.to_uint16(), 1UL, 1UL),
  )
  assert_eq(outcome, Err(@protocol.AuthFailed))
  // Refused before storage append: the log is untouched, so there is
  // nothing to reconcile afterwards.
  assert_eq(follower_log.held(), [])
  assert_eq(trace.val, [])
}

///|
async test "an acknowledgement naming a node other than the one asked is refused" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let leader_log = traced_log("leader", trace)
  let secret = fixture_secret()
  let server = bind_loopback()
  let port = server.addr.port()
  let leader_config = handshake_config(
    2U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  let far_config = handshake_config(
    1U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  let leader = @cluster.ClusterNode::new(leader_config)

  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => server.accept()) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          match
            @cluster.ClusterNode::serve_peer(
              @cluster.ClusterNode::new(far_config),
              conn,
            ) {
            Err(_) => ()
            Ok(_) => {
              // The link proved node 1, so this answer claims node 3 --
              // a member, and not the one that was asked.
              let forged : @cluster.AppendAck = {
                follower_id: 3U.to_uint16(),
                leader_epoch: 1UL,
                flushed_seq: 5UL,
                dirty_seq: 5UL,
              }
              match
                @cluster.write_peer_msg(conn, @cluster.PeerMsg::Ack(forged)) {
                Err(_) => ()
                Ok(_) => ()
              }
              // Drain the batch the leader sent before letting the
              // socket go. Closing with bytes still unread sends a
              // reset, and a reset discards this end's own outbound
              // data -- the forged acknowledgement would never arrive
              // and the case would fail for the wrong reason.
              match
                @cluster.read_peer_msg(conn, @cluster.PEER_FRAME_TIMEOUT_MS) {
                Err(_) => ()
                Ok(_) => ()
              }
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
          None => fail("the far member must be in the static table")
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
              [b"payload"],
              true,
              handshake_budget_ms(),
            )
            // The write itself was made, but nothing was counted from
            // an answer that came from the wrong node.
            assert_eq(outcome, Err(@protocol.AuthFailed))
            assert_eq(leader_log.last_flushed_seq(), 1UL)
            assert_eq(leader.commit_horizon(leader_log.last_flushed_seq()), 0UL)
            assert_eq(leader.follower_positions().length(), 0)
          }
        }
        @net.Conn::close(conn)
      }
    }
  }
}

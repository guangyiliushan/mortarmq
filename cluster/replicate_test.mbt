/// The replication sequence, as an ordering property.
///
/// Every case runs a real round over a real loopback socket and asserts
/// the *order* things happened in, not only the end state: a trace
/// shared by both logs records each append and each fsync as it occurs,
/// so "the leader was durable before it shipped" and "the follower
/// fsynced before it acked" are checked rather than assumed.

///|
/// The mutable positions of one fake log, behind a `Ref` so a trait
/// method can advance them whichever way the receiver is passed.
struct LogState {
  mut appended : UInt64
  mut flushed : UInt64
}

///|
/// A replica log that records what it was asked to do.
///
/// It models exactly the two positions `ReplicaLog` promises and
/// nothing else -- no bytes, no segments -- because the replication
/// exchange must be testable without a disk, and because a log that
/// only tracked the end of the log could not distinguish the very
/// distinction this stream exists to carry: written versus fsynced.
struct TracedLog {
  name : String
  trace : Ref[Array[(String, UInt64)]]
  state : Ref[LogState]
}

///|
fn traced_log(name : String, trace : Ref[Array[(String, UInt64)]]) -> TracedLog {
  { name, trace, state: Ref::Ref({ appended: 0UL, flushed: 0UL, }), }
}

///|
impl @cluster.ReplicaLog for TracedLog with fn last_appended_seq(self) -> UInt64 {
  self.state.val.appended
}

///|
impl @cluster.ReplicaLog for TracedLog with fn last_flushed_seq(self) -> UInt64 {
  self.state.val.flushed
}

///|
impl @cluster.ReplicaLog for TracedLog with fn append(
  self,
  payloads : Array[Bytes],
  durable : Bool,
) -> Result[UInt64, @protocol.ErrCode] {
  let first = self.state.val.appended + 1UL
  let mut last = self.state.val.appended
  for _ in payloads {
    last = last + 1UL
  }
  self.state.val.appended = last
  self.trace.val.push((self.name + ".append", first))
  if durable {
    // An fsync that was asked for and reported done: only here does
    // `flushed_seq` move.
    self.state.val.flushed = last
    self.trace.val.push((self.name + ".flush", last))
  } else {
    self.trace.val.push((self.name + ".dirty", last))
  }
  Ok(first)
}

///|
// Promote the trait methods onto the type explicitly rather than relying
// on implicit promotion, the same convention `net/tcp` uses for `Conn`.
extend TracedLog with @cluster.ReplicaLog::{last_appended_seq, last_flushed_seq}

///|
/// Run one replication round over a fresh loopback link: node 1
/// accepts and serves one `APPEND`, node 2 dials, handshakes, and
/// sends one.
///
/// Returns both verdicts; the logs stay readable by the caller through
/// the `Ref` they were built with.
async fn replication_round(
  leader_log : TracedLog,
  follower_log : TracedLog,
  payloads : Array[Bytes],
  flush_after_append : Bool,
) -> (
  Result[@cluster.AppendAck, @protocol.ErrCode],
  Result[@cluster.AppendAck, @protocol.ErrCode],
) {
  let secret = fixture_secret()
  let server = bind_loopback()
  let follower_port = server.addr.port()
  let follower_config = handshake_config(
    1U.to_uint16(),
    follower_port,
    2U.to_uint16(),
    secret,
  )
  let leader_config = handshake_config(
    2U.to_uint16(),
    follower_port,
    2U.to_uint16(),
    secret,
  )
  let follower_epoch = fresh_epoch()
  let follower_outcome : Ref[Result[@cluster.AppendAck, @protocol.ErrCode]] = Ref::Ref(
    Err(@protocol.Internal),
  )
  let leader_outcome : Ref[Result[@cluster.AppendAck, @protocol.ErrCode]] = Ref::Ref(
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
          match
            @cluster.ClusterNode::serve_peer(
              @cluster.ClusterNode::new(follower_config),
              conn,
            ) {
            Err(code) => follower_outcome.val = Err(code)
            Ok(_) =>
              follower_outcome.val = @cluster.ClusterNode::serve_append(
                @cluster.ClusterNode::new(follower_config),
                conn,
                follower_log,
                follower_epoch,
              )
          }
          @net.Conn::close(conn)
        }
      }
    }
    match dial_loopback(follower_port) {
      Err(code) => leader_outcome.val = Err(code)
      Ok(conn) => {
        let node = @cluster.ClusterNode::new(leader_config)
        let expected = match leader_config.peer_entry(1U.to_uint16()) {
          None => fail("node 1 must be in the static table")
          Some(entry) => entry
        }
        match @cluster.ClusterNode::dial_peer(node, conn, expected) {
          Err(code) => leader_outcome.val = Err(code)
          Ok(_) =>
            leader_outcome.val = @cluster.ClusterNode::send_append(
              node,
              conn,
              leader_log,
              1UL,
              payloads,
              flush_after_append,
              handshake_budget_ms(),
            )
        }
        @net.Conn::close(conn)
      }
    }
  }
  (leader_outcome.val, follower_outcome.val)
}

///|
async test "a round is durable on the leader before it ships, and fsynced on the follower before it acks" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let leader_log = traced_log("leader", trace)
  let follower_log = traced_log("follower", trace)
  let payloads : Array[Bytes] = [b"one", b"two", b"three"]
  let (leader, follower) = replication_round(
    leader_log, follower_log, payloads, true,
  )
  match follower {
    Err(_) => fail("the follower must apply the batch")
    Ok(ack) => {
      assert_eq(ack.follower_id, 1U.to_uint16())
      assert_eq(ack.leader_epoch, 1UL)
      // Both positions are three: the follower was told to flush, so
      // nothing it reports is merely written.
      assert_eq(ack.flushed_seq, 3UL)
      assert_eq(ack.dirty_seq, 3UL)
      assert_eq(follower_log.last_appended_seq(), 3UL)
      assert_eq(follower_log.last_flushed_seq(), 3UL)
      trace.val.push(("ack", ack.flushed_seq))
    }
  }
  match leader {
    Err(_) => fail("the round must complete")
    Ok(ack) => {
      assert_eq(ack.flushed_seq, 3UL)
      assert_eq(leader_log.last_appended_seq(), 3UL)
      assert_eq(leader_log.last_flushed_seq(), 3UL)
    }
  }
  // The whole point of the round, as one ordered fact: the leader's
  // append and fsync happen before the follower sees anything, and the
  // follower's append and fsync both happen before the ack is read.
  assert_eq(trace.val, [
    ("leader.append", 1UL),
    ("leader.flush", 3UL),
    ("follower.append", 1UL),
    ("follower.flush", 3UL),
    ("ack", 3UL),
  ])
}

///|
async test "a batch the follower is told not to flush advances dirty without advancing flushed" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let leader_log = traced_log("leader", trace)
  let follower_log = traced_log("follower", trace)
  let payloads : Array[Bytes] = [b"only-written"]
  let (_leader, follower) = replication_round(
    leader_log, follower_log, payloads, false,
  )
  match follower {
    Err(_) => fail("the follower must apply the batch")
    Ok(ack) => {
      // Written, not durable: the two positions diverge, which is the
      // distinction the acknowledgement carries so a lagging follower
      // shows up as lagging instead of looking caught up.
      assert_eq(ack.dirty_seq, 1UL)
      assert_eq(ack.flushed_seq, 0UL)
    }
  }
  assert_eq(follower_log.last_appended_seq(), 1UL)
  assert_eq(follower_log.last_flushed_seq(), 0UL)
  // The leader still flushes its own copy before it ships, whatever it
  // asks the follower to do.
  assert_eq(leader_log.last_flushed_seq(), 1UL)
  assert_eq(trace.val, [
    ("leader.append", 1UL),
    ("leader.flush", 1UL),
    ("follower.append", 1UL),
    ("follower.dirty", 1UL),
  ])
}

///|
async test "an empty batch is refused before it is appended or written" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let leader_log = traced_log("leader", trace)
  let secret = fixture_secret()
  let server = bind_loopback()
  let port = server.addr.port()
  let config = handshake_config(2U.to_uint16(), port, 2U.to_uint16(), secret)
  let node = @cluster.ClusterNode::new(config)
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => server.accept()) {
        None => ()
        Some(accepted) => accepted.0.close()
      }
    }
    match dial_loopback(port) {
      Err(_) => fail("the listener is bound, so the dial must connect")
      Ok(conn) => {
        let outcome = @cluster.ClusterNode::send_append(
          node,
          conn,
          leader_log,
          1UL,
          [],
          true,
          handshake_budget_ms(),
        )
        assert_eq(outcome, Err(@protocol.MalformedPayload))
        @net.Conn::close(conn)
      }
    }
  }
  // Nothing was written and nothing was logged: the guard runs before
  // the log is touched, so an empty batch costs no durability claim.
  assert_eq(leader_log.last_appended_seq(), 0UL)
  assert_eq(trace.val, [])
}

///|
/// A node over the handshake fixture's three-node table, bound to
/// nothing -- the acknowledgement checks below are pure bookkeeping.
fn tracked_node() -> @cluster.ClusterNode raise {
  let config = handshake_config(
    1U.to_uint16(),
    7191,
    2U.to_uint16(),
    fixture_secret(),
  )
  @cluster.ClusterNode::new(config)
}

///|
/// One acknowledgement, fully spelled out so a test states only the one
/// field it is about.
fn ack_from(
  follower_id : UInt16,
  flushed_seq : UInt64,
  dirty_seq : UInt64,
) -> @cluster.AppendAck {
  { follower_id, leader_epoch: 1UL, flushed_seq, dirty_seq, }
}

///|
test "an acknowledgement from outside the static table is refused" {
  let node = tracked_node()
  let foreign = ack_from(9U.to_uint16(), 1UL, 1UL)
  assert_eq(
    @cluster.ClusterNode::record_append_ack(node, foreign),
    Err(@protocol.MalformedPayload),
  )
  // A refused acknowledgement records nothing: the node's view of the
  // cluster changes only for a peer it actually has.
  assert_eq(node.follower_positions().length(), 0)
  assert_eq(node.follower_progress(9U.to_uint16()), None)
}

///|
test "an acknowledgement claiming to be flushed past its own writes is refused" {
  let node = tracked_node()
  let impossible = ack_from(2U.to_uint16(), 5UL, 2UL)
  assert_eq(
    @cluster.ClusterNode::record_append_ack(node, impossible),
    Err(@protocol.MalformedPayload),
  )
  assert_eq(node.follower_positions().length(), 0)
}

///|
test "a stale acknowledgement never moves a position backwards" {
  let node = tracked_node()
  let reported = ack_from(2U.to_uint16(), 5UL, 7UL)
  assert_eq(@cluster.ClusterNode::record_append_ack(node, reported), Ok(()))
  assert_eq(
    node.follower_progress(2U.to_uint16()),
    Some({ peer_id: 2U.to_uint16(), flushed_seq: 5UL, dirty_seq: 7UL, }),
  )
  // A late or replayed copy of an older acknowledgement is accepted as
  // information and ignored as an update.
  let stale = ack_from(2U.to_uint16(), 3UL, 4UL)
  assert_eq(@cluster.ClusterNode::record_append_ack(node, stale), Ok(()))
  assert_eq(
    node.follower_progress(2U.to_uint16()),
    Some({ peer_id: 2U.to_uint16(), flushed_seq: 5UL, dirty_seq: 7UL, }),
  )
  // A genuinely newer one still advances both.
  let newer = ack_from(2U.to_uint16(), 6UL, 8UL)
  assert_eq(@cluster.ClusterNode::record_append_ack(node, newer), Ok(()))
  assert_eq(
    node.follower_progress(2U.to_uint16()),
    Some({ peer_id: 2U.to_uint16(), flushed_seq: 6UL, dirty_seq: 8UL, }),
  )
}

///|
async test "a batch from a leader outside the static table is refused before the log is touched" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let secret = fixture_secret()
  let server = bind_loopback()
  let port = server.addr.port()
  let follower_config = handshake_config(
    1U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  let other_config = handshake_config(
    2U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  let follower_outcome : Ref[Result[@cluster.AppendAck, @protocol.ErrCode]] = Ref::Ref(
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
          let node = @cluster.ClusterNode::new(follower_config)
          let epoch = fresh_epoch()
          match @cluster.ClusterNode::serve_peer(node, conn) {
            Err(code) => follower_outcome.val = Err(code)
            Ok(_) =>
              follower_outcome.val = @cluster.ClusterNode::serve_append(
                node, conn, follower_log, epoch,
              )
          }
          @net.Conn::close(conn)
        }
      }
    }
    match dial_loopback(port) {
      Err(_) => fail("the listener is bound, so the dial must connect")
      Ok(conn) => {
        let node = @cluster.ClusterNode::new(other_config)
        let expected = match other_config.peer_entry(1U.to_uint16()) {
          None => fail("node 1 must be in the static table")
          Some(entry) => entry
        }
        match @cluster.ClusterNode::dial_peer(node, conn, expected) {
          Err(_) =>
            fail("both sides hold the same secret, so the handshake must pass")
          Ok(_) => {
            // A well-formed batch whose claimed leader is not a member:
            // the frame is valid, the sender is not.
            let forged : @cluster.AppendBatch = {
              leader_id: 9U.to_uint16(),
              leader_epoch: 1UL,
              base_seq: 1UL,
              flush_after_append: true,
              entries: [b"smuggled"],
            }
            assert_eq(
              @cluster.write_peer_msg(conn, @cluster.PeerMsg::Append(forged)),
              Ok(()),
            )
            match @cluster.read_peer_msg(conn) {
              Ok(@cluster.PeerMsg::Reject(code)) =>
                assert_eq(code, @protocol.AuthFailed.to_uint16().to_uint16())
              _ => fail("the follower must refuse with a Reject frame")
            }
          }
        }
        @net.Conn::close(conn)
      }
    }
  }
  assert_eq(follower_outcome.val, Err(@protocol.AuthFailed))
  // The refusal came before the write, so nothing reached the log.
  assert_eq(follower_log.last_appended_seq(), 0UL)
  assert_eq(trace.val, [])
}

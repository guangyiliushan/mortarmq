/// A lease that runs out leads to a new leader at a higher term, and
/// only with a majority behind it.
///
/// The injection here is time, not a process: every case hands the lease
/// a tick it chose and reads the verdict, which is both how a
/// deterministic test is possible and the same discipline that keeps a
/// wall-clock step out of the production path.

///|
/// Everything one election round produced, from both ends.
///
/// Held in one value rather than a tuple because a case often needs the
/// member node as well as its verdicts -- the committed prefix it
/// adopted is readable only from the node itself.
struct RoundOutcome {
  candidate_prepare : Result[@cluster.PrepareAckMsg, @protocol.ErrCode]
  candidate_install : Result[@cluster.InstallAckMsg, @protocol.ErrCode]
  peer_prepare : Result[@cluster.PrepareAckMsg, @protocol.ErrCode]
  peer_install : Result[@cluster.InstallAckMsg, @protocol.ErrCode]
  peer_node : @cluster.ClusterNode
}

///|
/// Run one full election round against a single peer over a fresh
/// loopback link, reporting both halves from both sides.
async fn election_round(
  candidate : @cluster.ClusterNode,
  candidate_epoch : UInt64,
  commit_seq : UInt64,
  candidate_log : TracedLog,
  follower_log : TracedLog,
  candidate_epoch_state : @cluster.LeaderEpoch,
  follower_epoch : @cluster.LeaderEpoch,
) -> RoundOutcome {
  let secret = fixture_secret()
  let server = bind_loopback()
  let port = server.addr.port()
  let peer_config = handshake_config(
    1U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  let candidate_config = handshake_config(
    2U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  // Built here, outside the background task, so the outcome hands back
  // the node that actually served -- not a fresh one standing in for it.
  let peer_node = @cluster.ClusterNode::new(peer_config)

  let peer_prepare : Ref[Result[@cluster.PrepareAckMsg, @protocol.ErrCode]] = Ref::Ref(
    Err(@protocol.Internal),
  )
  let peer_install : Ref[Result[@cluster.InstallAckMsg, @protocol.ErrCode]] = Ref::Ref(
    Err(@protocol.Internal),
  )
  let candidate_prepare : Ref[Result[@cluster.PrepareAckMsg, @protocol.ErrCode]] = Ref::Ref(
    Err(@protocol.Internal),
  )
  let candidate_install : Ref[Result[@cluster.InstallAckMsg, @protocol.ErrCode]] = Ref::Ref(
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
          match @cluster.ClusterNode::serve_peer(peer_node, conn) {
            Err(_) => ()
            Ok(link) => {
              peer_prepare.val = @cluster.ClusterNode::serve_prepare(
                peer_node, link, follower_epoch, follower_log,
              )
              peer_install.val = @cluster.ClusterNode::serve_install(
                peer_node, link, follower_epoch, follower_log,
              )
            }
          }
          @net.Conn::close(conn)
        }
      }
    }
    candidate.begin_election()
    match dial_loopback(port) {
      Err(_) => fail("the listener is bound, so the dial must connect")
      Ok(conn) => {
        let expected = match candidate_config.peer_entry(1U.to_uint16()) {
          None => fail("the member must be in the static table")
          Some(entry) => entry
        }
        match @cluster.ClusterNode::dial_peer(candidate, conn, expected) {
          Err(_) =>
            fail("both sides hold the same secret, so the handshake must pass")
          Ok(link) => {
            candidate_prepare.val = @cluster.ClusterNode::send_prepare(
              candidate, link, candidate_log, candidate_epoch_state, candidate_epoch,
            )
            candidate_install.val = @cluster.ClusterNode::send_install(
              candidate, link, candidate_epoch_state, candidate_epoch, commit_seq,
            )
          }
        }
        @net.Conn::close(conn)
      }
    }
  }
  {
    candidate_prepare: candidate_prepare.val,
    candidate_install: candidate_install.val,
    peer_prepare: peer_prepare.val,
    peer_install: peer_install.val,
    peer_node,
  }
}

///|
async test "an expired lease ends in a new leader at a higher term, with a majority behind it" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let candidate_log = traced_log("candidate", trace)
  let follower_log = traced_log("follower", trace)
  let candidate_term = fresh_epoch()
  let follower_term = fresh_epoch()
  let candidate = @cluster.ClusterNode::new(
    handshake_config(2U.to_uint16(), 7191, 2U.to_uint16(), fixture_secret()),
  )

  // The lease runs out.
  let lease = @cluster.Lease::new(0UL, @cluster.FOLLOWER_LEASE_MS)
  assert_eq(lease.expired(@cluster.FOLLOWER_LEASE_MS - 1UL), false)
  assert_eq(lease.expired(@cluster.FOLLOWER_LEASE_MS), true)
  // ... which is the candidate's licence to stand. Its own term is
  // durable before it asks anyone, so it counts from the first moment.
  assert_eq(candidate_term.elect(1UL), Ok(1UL))
  // The member has to hold what the install calls settled: a committed
  // prefix past the end of one's own log is capped at what is there,
  // so a member that had nothing would adopt nothing.
  match follower_log.append([b"a", b"b"], true) {
    Err(_) => fail("the fixture log must accept its seed")
    Ok(_) => ()
  }

  let outcome = election_round(
    candidate, 1UL, 2UL, candidate_log, follower_log, candidate_term, follower_term,
  )

  // Both halves succeeded on both ends: a round that promised but never
  // installed would leave a leader only in its own memory.
  match outcome.candidate_prepare {
    Err(_) => fail("the member must promise the proposed term")
    Ok(ack) => {
      assert_eq(ack.responder_id, 1U.to_uint16())
      assert_eq(ack.promised_epoch, 1UL)
    }
  }
  match outcome.candidate_install {
    Err(_) => fail("the member must install the term")
    Ok(ack) => {
      assert_eq(ack.responder_id, 1U.to_uint16())
      assert_eq(ack.epoch, 1UL)
    }
  }
  match outcome.peer_prepare {
    Err(_) => fail("the member's own half must succeed")
    Ok(ack) => assert_eq(ack.promised_epoch, 1UL)
  }
  match outcome.peer_install {
    Err(_) => fail("the member's own half must succeed")
    Ok(ack) => assert_eq(ack.epoch, 1UL)
  }

  // Two answers plus the candidate itself: a majority of three.
  assert_eq(candidate.prepared_count(), 2)
  assert_eq(candidate.has_prepare_quorum(), true)
  assert_eq(candidate.installed_count(), 2)
  assert_eq(candidate.has_install_quorum(), true)
  assert_eq(candidate.promised_members(), [1U.to_uint16()])
  assert_eq(candidate.installed_members(), [1U.to_uint16()])

  // The new term is in force on both sides, and it is higher than the
  // one the cluster was under.
  assert_eq(candidate_term.current(), 1UL)
  assert_eq(follower_term.current(), 1UL)
  // The committed prefix travelled with the install.
  assert_eq(outcome.peer_node.commit_seq(), 2UL)
}

///|
async test "an expired lease names a successor, and that successor cannot stand for a term already held" {
  let config = leader_preference([1U, 2U, 3U].map(id => id.to_uint16()))
  // The order was fixed before anything failed, so the successor is
  // decided by preference rather than by a contest.
  assert_eq(config.candidate_after(1U.to_uint16()), Some(2U.to_uint16()))

  let term = fresh_epoch()
  assert_eq(term.elect(1UL), Ok(1UL))
  // Standing for the term the cluster is already in is not an election,
  // it is a duplicate -- refused rather than quietly accepted.
  assert_eq(term.elect(1UL), Err(@protocol.StaleLeaderEpoch))
  assert_eq(term.elect(0UL), Err(@protocol.StaleLeaderEpoch))
  // The next term goes through.
  assert_eq(term.elect(2UL), Ok(2UL))
  assert_eq(term.current(), 2UL)
}

///|
test "a candidate with no answers holds no quorum" {
  let candidate = @cluster.ClusterNode::new(
    handshake_config(2U.to_uint16(), 7191, 2U.to_uint16(), fixture_secret()),
  )
  candidate.begin_election()
  // Only its own durable promise: one of three is not a majority, so a
  // candidate nobody answers is simply not the leader.
  assert_eq(candidate.prepared_count(), 1)
  assert_eq(candidate.has_prepare_quorum(), false)
  assert_eq(candidate.installed_count(), 1)
  assert_eq(candidate.has_install_quorum(), false)
  assert_eq(candidate.promised_members().length(), 0)
  assert_eq(candidate.installed_members().length(), 0)
}

///|
async test "a prepare for a term the cluster has already left is refused" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let candidate_log = traced_log("candidate", trace)
  let follower_log = traced_log("follower", trace)
  let candidate_term = fresh_epoch()
  let follower_term = fresh_epoch()
  let candidate = @cluster.ClusterNode::new(
    handshake_config(2U.to_uint16(), 7191, 2U.to_uint16(), fixture_secret()),
  )

  assert_eq(candidate_term.elect(3UL), Ok(3UL))
  let current = election_round(
    candidate, 3UL, 0UL, candidate_log, follower_log, candidate_term, follower_term,
  )
  match current.candidate_prepare {
    Err(_) => fail("a term nobody holds must be promised")
    Ok(_) => ()
  }
  assert_eq(follower_term.current(), 3UL)

  // A candidate still proposing term two arrives after the cluster has
  // moved to three. The member has promised three durably, so it has
  // already given up its right to answer a lower one.
  candidate.begin_election()
  let stale = election_round(
    candidate, 2UL, 0UL, candidate_log, follower_log, candidate_term, follower_term,
  )
  assert_eq(stale.candidate_prepare, Err(@protocol.StaleLeaderEpoch))
  assert_eq(candidate.has_prepare_quorum(), false)
  // The refusal left the log alone: no install was attempted.
  match stale.candidate_install {
    Err(_) => ()
    Ok(_) => fail("a refused prepare must not be followed by an install")
  }
  assert_eq(follower_term.current(), 3UL)
}

///|
async test "a member that has committed further than this candidate is not counted" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let candidate_log = traced_log("candidate", trace)
  let candidate = tracked_node()
  candidate.begin_election()
  let ahead : @cluster.PrepareAckMsg = {
    responder_id: 2U.to_uint16(),
    promised_epoch: 1UL,
    last_seq: 9UL,
    last_flushed_seq: 9UL,
    commit_seq: 9UL,
  }
  // The member has committed through nine and this candidate through
  // nothing: standing would install a committed prefix smaller than a
  // member already holds.
  assert_eq(
    @cluster.ClusterNode::record_prepare_ack(
      candidate,
      ahead,
      1UL,
      2U.to_uint16(),
    ),
    Err(@protocol.UncleanElectionRejected),
  )
  // Refused means not counted: the quorum did not move.
  assert_eq(candidate.prepared_count(), 1)
  assert_eq(candidate.has_prepare_quorum(), false)

  // Once this candidate has committed at least as far, the same answer
  // is perfectly ordinary. The log has to hold it first: a committed
  // prefix past the end of one's own log is capped there, and a
  // candidate claiming otherwise has nothing to compare against.
  match
    candidate_log.append(
      [b"1", b"2", b"3", b"4", b"5", b"6", b"7", b"8", b"9"],
      true,
    ) {
    Err(_) => fail("the fixture log must accept its seed")
    Ok(_) => ()
  }
  candidate.note_committed(9UL, candidate_log)
  assert_eq(
    @cluster.ClusterNode::record_prepare_ack(
      candidate,
      ahead,
      1UL,
      2U.to_uint16(),
    ),
    Ok(()),
  )
  assert_eq(candidate.prepared_count(), 2)
  assert_eq(candidate.has_prepare_quorum(), true)
}

///|
/// A candidate may only stand for a term it already holds.
///
/// Writing the term down first is what makes the promises worth
/// anything: a proposal for one this node never recorded would have
/// every member that answered give up its right to answer a lower term,
/// and a crash would take the term with it. The member side already
/// refuses a term at or below what it holds -- this is the other half,
/// on the side that is asking.
async test "a candidate may only stand for a term it already holds" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let candidate_log = traced_log("candidate", trace)
  let secret = fixture_secret()
  let server = bind_loopback()
  let port = server.addr.port()
  let peer_config = handshake_config(
    1U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  let candidate_config = handshake_config(
    2U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  let peer_node = @cluster.ClusterNode::new(peer_config)
  let candidate = @cluster.ClusterNode::new(candidate_config)
  // The candidate holds one and is standing for two: a term it never
  // wrote down.
  let candidate_term = fresh_epoch()
  assert_eq(candidate_term.elect(1UL), Ok(1UL))

  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => server.accept()) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          // Handshake and nothing else: the round is refused before it
          // writes, so there is nothing on this side to answer.
          match @cluster.ClusterNode::serve_peer(peer_node, conn) {
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
        let expected = match candidate_config.peer_entry(1U.to_uint16()) {
          None => fail("the member must be in the static table")
          Some(entry) => entry
        }
        match @cluster.ClusterNode::dial_peer(candidate, conn, expected) {
          Err(_) =>
            fail("both sides hold the same secret, so the handshake must pass")
          Ok(link) => {
            let prepare = @cluster.ClusterNode::send_prepare(
              candidate, link, candidate_log, candidate_term, 2UL,
            )
            assert_eq(prepare, Err(@protocol.StaleLeaderEpoch))
            let install = @cluster.ClusterNode::send_install(
              candidate, link, candidate_term, 2UL, 0UL,
            )
            assert_eq(install, Err(@protocol.StaleLeaderEpoch))
            // Refused before the first write: the member heard of no
            // round, so no promise or install is recorded on this side.
            assert_eq(candidate.prepared_count(), 1)
            assert_eq(candidate.installed_count(), 1)
          }
        }
        @net.Conn::close(conn)
      }
    }
  }
}

///|
/// A member that goes quiet costs one round, and is counted.
///
/// The round has its own deadline, well inside the frame's. Waiting the
/// full frame timeout for an answer that is not coming would hold up an
/// election that can be run again on the next tick, and the answer to a
/// silent member is a round to repeat rather than a connection to tear
/// down -- so the deadline fires, nothing is closed, and the count is
/// where the difference between one slow member and rounds that keep
/// ending this way shows up.
async test "a member that never answers costs the round, and is counted" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let candidate_log = traced_log("candidate", trace)
  let secret = fixture_secret()
  let server = bind_loopback()
  let port = server.addr.port()
  let peer_config = handshake_config(
    1U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  let candidate_config = handshake_config(
    2U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  let peer_node = @cluster.ClusterNode::new(peer_config)
  let candidate = @cluster.ClusterNode::new(candidate_config)
  let candidate_term = fresh_epoch()
  assert_eq(candidate_term.elect(1UL), Ok(1UL))
  assert_eq(candidate.election_timeouts(), 0)

  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => server.accept()) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          match @cluster.ClusterNode::serve_peer(peer_node, conn) {
            Err(_) => ()
            Ok(_) => ()
          }
          // Hold the connection open without answering, so the round is
          // what ends -- a closed socket would end the read instead, and
          // that is a different failure.
          @async.sleep(2500)
          @net.Conn::close(conn)
        }
      }
    }
    match dial_loopback(port) {
      Err(_) => fail("the listener is bound, so the dial must connect")
      Ok(conn) => {
        let expected = match candidate_config.peer_entry(1U.to_uint16()) {
          None => fail("the member must be in the static table")
          Some(entry) => entry
        }
        match @cluster.ClusterNode::dial_peer(candidate, conn, expected) {
          Err(_) =>
            fail("both sides hold the same secret, so the handshake must pass")
          Ok(link) => {
            let prepare = @cluster.ClusterNode::send_prepare(
              candidate, link, candidate_log, candidate_term, 1UL,
            )
            assert_eq(prepare, Err(@protocol.ElectionTimeout))
            assert_eq(candidate.election_timeouts(), 1)
            // The link is still open and nothing was recorded: one round
            // ended, and the next one is still worth running on it.
            let install = @cluster.ClusterNode::send_install(
              candidate, link, candidate_term, 1UL, 0UL,
            )
            assert_eq(install, Err(@protocol.ElectionTimeout))
            assert_eq(candidate.election_timeouts(), 2)
            assert_eq(candidate.prepared_count(), 1)
            assert_eq(candidate.installed_count(), 1)
          }
        }
        @net.Conn::close(conn)
      }
    }
  }
}

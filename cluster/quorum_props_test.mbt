/// The consistency properties CQ1 and CQ2, expressed for the sampling
/// checker (suite S6, INV-005 and INV-007).
///
/// Both are properties of the quorum arithmetic rather than of any one
/// round: CQ1 says the committed ceiling the consumers read never moves
/// backwards, and CQ2 says a majority that promised a term and a
/// majority that made it durable cannot be different sets of nodes. The
/// second one is what makes a leader's term survive a crash -- if those
/// two groups could be disjoint, a term could be installed somewhere it
/// was never committed and committed somewhere it was never installed.
///
/// `MORTARMQ_PROP_DAILY` switches both to the daily tier: a
/// run-unique seed from the clock with a larger count, and the seed is
/// printed so a failure reproduces. Without it they run a pinned seed
/// and count, so a plain `moon test` never surprises.

///|
/// Whether the property is being run in the daily tier.
fn quorum_daily() -> Bool {
  match @env.get_env_var("MORTARMQ_PROP_DAILY") {
    Some(_) => true
    None => false
  }
}

///|
/// The seed this run draws from: a run-unique one in the daily tier,
/// a pinned one otherwise.
fn quorum_seed() -> UInt64 {
  if quorum_daily() {
    @env.now()
  } else {
    20261014UL
  }
}

///|
/// The sample count for this run.
fn quorum_count() -> UInt {
  if quorum_daily() {
    1000U
  } else {
    250U
  }
}

///|
/// Every member of `left` that is also a member of `right`.
fn quorum_overlap(left : Array[UInt16], right : Array[UInt16]) -> Array[UInt16] {
  let shared : Array[UInt16] = []
  for candidate in left {
    for other in right {
      if candidate == other {
        shared.push(candidate)
      }
    }
  }
  shared
}

///|
/// `quorum` distinct members of `table`, starting at `start` and
/// wrapping.
///
/// Taking consecutive members from a rotating start covers every
/// contiguous run, which for three members is every pair -- and keeps
/// the set free of duplicates, so a failure can only come from the
/// quorum being wrong rather than from a set that could never have been
/// a quorum in the first place.
fn quorum_subset(
  table : Array[@cluster.PeerEntry],
  quorum : Int,
  start : Int,
) -> Array[UInt16] {
  let picked : Array[UInt16] = []
  for offset in 0..<quorum {
    let index = (start + offset) % table.length()
    picked.push(table[index].node_id)
  }
  picked
}

///|
/// What one peer has reported, or zero when it has not reported at all.
fn quorum_position(node : @cluster.ClusterNode, peer_id : UInt16) -> UInt64 {
  match node.follower_progress(peer_id) {
    None => 0UL
    Some(progress) => progress.flushed_seq
  }
}

///|
test "CQ1 the committed ceiling never moves backwards (pin seed=20261014; daily mode logs the run seed)" {
  let seed = quorum_seed()
  let count = quorum_count()
  if quorum_daily() {
    println("CQ1-daily seed=\{seed} count=\{count}")
  }
  // One configuration, but a fresh node per sample: state carried
  // across samples would let one sample's assertion ride on another's
  // positions, and the property would be about neither.
  let config = match fixture_config() {
    Err(_) => fail("the fixture table must be valid")
    Ok(config) => config
  }
  @quickcheck.check(
    (draw : UInt) => {
      let node = @cluster.ClusterNode::new(config)
      // The leader's own durability varies per sample but is fixed
      // within one, because the ceiling is capped by it and a cap that
      // moved mid-sample would hide the thing being measured.
      let own = (draw % 64U).to_uint64() + 1UL
      let mut ceiling = node.commit_horizon(own)
      for step in 0..<4 {
        let peer = if step % 2 == 0 { 2U.to_uint16() } else { 3U.to_uint16() }
        // Half the steps replay a position the peer may already have
        // passed; those are the ones that must not walk anything back.
        let reported = if step % 3 == 0 {
          0UL
        } else {
          (draw % 64U).to_uint64() + 1UL
        }
        let before = quorum_position(node, peer)
        let ack : @cluster.AppendAck = {
          follower_id: peer,
          leader_epoch: 1UL,
          flushed_seq: reported,
          dirty_seq: reported + 1UL,
        }
        let accepted = match node.record_append_ack(ack, peer) {
          Ok(_) => true
          Err(_) => false
        }
        // The two outcomes are different claims and are checked
        // differently: an accepted acknowledgement may hold or advance
        // the position, while a refused one must leave it exactly as it
        // was -- "refused, and nothing moved" is not the same statement
        // as "moved forward".
        let after = quorum_position(node, peer)
        if accepted {
          if after < before {
            return false
          }
        } else if after != before {
          return false
        }
        let next = node.commit_horizon(own)
        if next < ceiling {
          return false
        }
        ceiling = next
      }
      true
    },
    count~,
    seed~,
  )
}

///|
/// One quorum as the code counts it: the candidate plus the members
/// that answered.
///
/// The candidate belongs to every quorum it builds -- it promised its
/// own term before asking anyone and installed it on itself -- which is
/// why two such quorums intersect even when no member is shared.
fn quorum_with_candidate(
  candidate : UInt16,
  members : Array[UInt16],
) -> Array[UInt16] {
  let full : Array[UInt16] = [candidate]
  for id in members {
    full.push(id)
  }
  full
}

///|
test "CQ2 a promise quorum and a commit quorum cannot be disjoint (pin seed=20261014; daily mode logs the run seed)" {
  let seed = quorum_seed()
  let count = quorum_count()
  if quorum_daily() {
    println("CQ2-daily seed=\{seed} count=\{count}")
  }
  let config = match fixture_config() {
    Err(_) => fail("the fixture table must be valid")
    Ok(config) => config
  }
  let table = config.peers()
  let quorum = config.quorum()
  let candidate = config.node_id()
  // The arithmetic the rest rests on: two groups that each hold more
  // than half the members cannot avoid each other, whichever candidate
  // built them. Stated separately so a failure says which half broke --
  // the reasoning or the code.
  assert_eq(quorum * 2 > table.length(), true)
  @quickcheck.check(
    (draw : UInt) => {
      // Both halves run through the real bookkeeping, one member at a
      // time, stopping when the code says the quorum is there. The
      // counts that come out are therefore the code's, not the
      // fixture's: a quorum the counters would never have reached is
      // exactly what this property exists to catch.
      let node = @cluster.ClusterNode::new(config)
      node.begin_election()
      let span = table.length().reinterpret_as_uint()
      let start_a = (draw % span).reinterpret_as_int()
      let start_b = (draw / 7U % span).reinterpret_as_int()
      let offered = quorum_subset(table, quorum, start_a).filter(id => {
        id != candidate
      })
      for id in offered {
        if !node.has_prepare_quorum() {
          let ack : @cluster.PrepareAckMsg = {
            responder_id: id,
            promised_epoch: 1UL,
            last_seq: 0UL,
            last_flushed_seq: 0UL,
            commit_seq: 0UL,
          }
          match @cluster.ClusterNode::record_prepare_ack(node, ack, 1UL, id) {
            Err(_) => return false
            Ok(_) => ()
          }
        }
      }
      // The candidate counts as one of the quorum, so exactly this many
      // members are needed. Delete the conjunct in `has_prepare_quorum`
      // and the loop above stops before recording anyone -- which is
      // where this assertion fails rather than passing quietly.
      if node.promised_members().length() != quorum - 1 {
        return false
      }
      let installed_offered = quorum_subset(table, quorum, start_b).filter(id => {
        id != candidate
      })
      for id in installed_offered {
        if !node.has_install_quorum() {
          let ack : @cluster.InstallAckMsg = {
            responder_id: id,
            epoch: 1UL,
            flushed_seq: 0UL,
          }
          match @cluster.ClusterNode::record_install_ack(node, ack, 1UL, id) {
            Err(_) => return false
            Ok(_) => ()
          }
        }
      }
      if node.installed_members().length() != quorum - 1 {
        return false
      }
      // The two quorums the code actually built, counted the way the
      // code counts them. The candidate is in both -- it promised its
      // own term durably and installed it -- so they intersect in it
      // whenever no member is shared, and in a member whenever the two
      // draws happened to land on one. The arithmetic line above is
      // what carries the general case: quorums that share no fixed
      // member cannot be disjoint when each holds more than half.
      let promised_quorum = quorum_with_candidate(
        candidate,
        node.promised_members(),
      )
      let installed_quorum = quorum_with_candidate(
        candidate,
        node.installed_members(),
      )
      if promised_quorum.length() < quorum || installed_quorum.length() < quorum {
        return false
      }
      quorum_overlap(promised_quorum, installed_quorum).length() > 0
    },
    count~,
    seed~,
  )
}

///|
test "a promise counts once, and only from the member it came from" {
  let node = tracked_node()
  node.begin_election()
  let first : @cluster.PrepareAckMsg = {
    responder_id: 2U.to_uint16(),
    promised_epoch: 1UL,
    last_seq: 0UL,
    last_flushed_seq: 0UL,
    commit_seq: 0UL,
  }
  assert_eq(
    @cluster.ClusterNode::record_prepare_ack(node, first, 1UL, 2U.to_uint16()),
    Ok(()),
  )
  assert_eq(node.prepared_count(), 2)
  // The same member answering again does not count a second time: one
  // member out of three must not be able to make a quorum on its own.
  assert_eq(
    @cluster.ClusterNode::record_prepare_ack(node, first, 1UL, 2U.to_uint16()),
    Ok(()),
  )
  assert_eq(node.prepared_count(), 2)
  assert_eq(node.promised_members(), [2U.to_uint16()])

  // A promise on a term this round never proposed is not this round's.
  let wrong_term : @cluster.PrepareAckMsg = {
    responder_id: 3U.to_uint16(),
    promised_epoch: 9UL,
    last_seq: 0UL,
    last_flushed_seq: 0UL,
    commit_seq: 0UL,
  }
  assert_eq(
    @cluster.ClusterNode::record_prepare_ack(
      node,
      wrong_term,
      1UL,
      3U.to_uint16(),
    ),
    Err(@protocol.StaleLeaderEpoch),
  )
  assert_eq(node.prepared_count(), 2)

  // Neither is an answer from a member the table does not contain.
  let stranger : @cluster.PrepareAckMsg = {
    responder_id: 9U.to_uint16(),
    promised_epoch: 1UL,
    last_seq: 0UL,
    last_flushed_seq: 0UL,
    commit_seq: 0UL,
  }
  assert_eq(
    @cluster.ClusterNode::record_prepare_ack(
      node,
      stranger,
      1UL,
      9U.to_uint16(),
    ),
    Err(@protocol.MalformedPayload),
  )
  assert_eq(node.prepared_count(), 2)
  assert_eq(node.has_prepare_quorum(), true)
}

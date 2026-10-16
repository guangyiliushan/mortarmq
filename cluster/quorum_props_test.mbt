/// Two properties of the quorum arithmetic rather than of any one
/// round, expressed for the sampling checker: the committed ceiling the
/// consumers read never moves backwards and is the number the rule says
/// it is; and a majority that promised a term and a majority that made
/// it durable cannot be different sets of nodes. The second is what
/// makes a leader's term survive a crash -- if those two groups could
/// be disjoint, a term could be installed somewhere it was never
/// committed and committed somewhere it was never installed.
///
/// What each property can and cannot fail on is written where it
/// matters. On a three-member table a majority is two, so two majorities
/// always share a member and the intersection itself is arithmetic; the
/// thing the code can get wrong is whether it has built a majority at
/// all, so the thresholds and the sizes are pinned beside the property
/// rather than folded into a claim that could not fail either way.
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
fn quorum_count() -> UInt32 {
  if quorum_daily() {
    1000U
  } else {
    250U
  }
}

///|
/// One position out of a slice of the draw.
///
/// Dividing by a power of two takes a different run of bits each time,
/// so the three positions one sample uses are three different values.
/// Reading them from a single number made them equal, and a ceiling
/// that always equals the value it was seeded with is never asked to
/// choose between them -- which is the whole rule.
fn quorum_slice(draw : UInt32, divisor : UInt32) -> UInt64 {
  (draw / divisor % 64U).to_uint64() + 1UL
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
/// The member this sample's acknowledgement does not come from.
fn quorum_other(peer : UInt16) -> UInt16 {
  if peer == 2U.to_uint16() {
    3U.to_uint16()
  } else {
    2U.to_uint16()
  }
}

///|
/// The ceiling the rule describes, stated rather than recomputed.
///
/// The rule is "the quorum-th largest of the three positions, capped at
/// the leader's own". This reads it by counting: a position qualifies
/// when at least `quorum` of the three sit at or above it, and the
/// answer is the highest position that qualifies -- which is exactly
/// the quorum-th largest, arrived at without the sort the production
/// function performs. A property that answered with the same sort it is
/// checking would only be showing that the code agrees with itself.
///
/// `own` is one of the three, so the cap is a second rule layered over
/// the first: a horizon above what the leader itself has on disk would
/// not be recoverable by a majority, whatever the other two reported.
fn quorum_ceiling(
  own : UInt64,
  first : UInt64,
  second : UInt64,
  quorum : Int32,
) -> UInt64 {
  let positions : Array[UInt64] = [own, first, second]
  let mut answer = own
  let mut found = false
  for candidate in positions {
    let mut at_or_above = 0
    for other in positions {
      if other >= candidate {
        at_or_above = at_or_above + 1
      }
    }
    if at_or_above >= quorum {
      if !found || candidate > answer {
        answer = candidate
        found = true
      }
    }
  }
  if answer > own {
    own
  } else {
    answer
  }
}

///|
test "the committed ceiling never moves backwards and is the number the rule says (pin seed=20261014; daily mode logs the run seed)" {
  let seed = quorum_seed()
  let count = quorum_count()
  if quorum_daily() {
    println("ceiling-daily seed=\{seed} count=\{count}")
  }
  // One configuration, but a fresh node per sample: state carried
  // across samples would let one sample's assertion ride on another's
  // positions, and the property would be about neither.
  let config = match fixture_config() {
    Err(_) => fail("the fixture table must be valid")
    Ok(config) => config
  }
  let quorum = config.quorum()
  // Four slices, none of them the slice the leader's own position
  // comes from, so the three positions a sample compares are three
  // different numbers.
  let divisors : Array[UInt32] = [64U, 4096U, 262144U, 16777216U]
  @quickcheck.check(
    (draw : UInt32) => {
      let node = @cluster.ClusterNode::new(config)
      let own = quorum_slice(draw, 1U)
      let mut ceiling = node.commit_horizon(own)
      let mut accepted_seen = false
      for step in 0..<4 {
        let peer = if step % 2 == 0 { 2U.to_uint16() } else { 3U.to_uint16() }
        // Half the steps replay a position the peer may already have
        // passed; those are the ones that must not walk anything back.
        let reported = if step % 3 == 0 {
          0UL
        } else {
          quorum_slice(draw, divisors[step])
        }
        let before = quorum_position(node, peer)
        // Some steps are an acknowledgement the connection did not
        // attest: the body names a member the connection proved a
        // different one for, so the code has to refuse it with the
        // position left exactly as it was. Driven by the draw so half
        // the samples exercise it.
        let unattested = step == 1 && draw % 2U == 1U
        let ack : @cluster.AppendAck = {
          follower_id: peer,
          leader_epoch: 1UL,
          flushed_seq: reported,
          dirty_seq: reported + 1UL,
        }
        let proved = if unattested { quorum_other(peer) } else { peer }
        let accepted = match node.record_append_ack(ack, proved) {
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
        // Never backwards...
        let next = node.commit_horizon(own)
        if next < ceiling {
          return false
        }
        ceiling = next
        // ...and equal to the rule, not merely consistent with it. A
        // horizon that only has to fail to decrease passes whichever of
        // the three positions it reads, whether it reads `flushed` or
        // `dirty`, and whether or not it lets the leader's own durable
        // position bound it -- and each of those gives a different
        // number here.
        if accepted {
          accepted_seen = true
          let expected = quorum_ceiling(
            own,
            quorum_position(node, 2U.to_uint16()),
            quorum_position(node, 3U.to_uint16()),
            quorum,
          )
          if next != expected {
            return false
          }
        }
      }
      // A sample where every ack was refused proves nothing about the
      // ceiling: require at least one accepted acknowledgement per
      // sample, so a record_append_ack that always refuses cannot ride
      // green on vacuous samples.
      accepted_seen
    },
    count~,
    max_shrinks=20,
    seed~,
  )
}

///|
/// The arithmetic the ceiling rests on, stated as a fact about the
/// configuration rather than asserted inside a property.
///
/// A property that opens by checking its own fixture proves the fixture
/// on every sample and says nothing about the code; this belongs where
/// a failure names the table instead.
test "a majority of the static table is more than half of it" {
  let config = match fixture_config() {
    Err(_) => fail("the fixture table must be valid")
    Ok(config) => config
  }
  assert_eq(config.quorum() * 2 > config.peers().length(), true)
}

///|
/// The ceiling worked through by hand, on positions no sampling run
/// has to wait for.
///
/// Four cases with four different answers: the leader's own position in
/// the middle of the three, the smallest, and the largest, plus one
/// where `dirty` sits above `flushed` and must be ignored. Each pins a
/// different way of getting it wrong -- the largest position instead of
/// the quorum-th, a horizon the leader cannot recover, a horizon that
/// ignores the leader's own durability, and one that counts an entry a
/// crash would lose.
test "the ceiling picks the quorum-th largest position and stops at the leader's own" {
  let config = match fixture_config() {
    Err(_) => fail("the fixture table must be valid")
    Ok(config) => config
  }
  let quorum = config.quorum()
  let second = 2U.to_uint16()
  let third = 3U.to_uint16()

  // The leader is in the middle: its own position is the answer, and
  // the largest of the three is one too high.
  let middle = @cluster.ClusterNode::new(config)
  assert_eq(
    middle.record_append_ack(
      {
        follower_id: second,
        leader_epoch: 1UL,
        flushed_seq: 3UL,
        dirty_seq: 3UL,
      },
      second,
    ),
    Ok(()),
  )
  assert_eq(
    middle.record_append_ack(
      {
        follower_id: third,
        leader_epoch: 1UL,
        flushed_seq: 9UL,
        dirty_seq: 9UL,
      },
      third,
    ),
    Ok(()),
  )
  assert_eq(middle.commit_horizon(5UL), 5UL)
  assert_eq(quorum_ceiling(5UL, 3UL, 9UL, quorum), 5UL)

  // The leader is the smallest: a horizon above its own durability
  // would not be recoverable, so the cap is what answers.
  let capped = @cluster.ClusterNode::new(config)
  assert_eq(
    capped.record_append_ack(
      {
        follower_id: second,
        leader_epoch: 1UL,
        flushed_seq: 5UL,
        dirty_seq: 5UL,
      },
      second,
    ),
    Ok(()),
  )
  assert_eq(
    capped.record_append_ack(
      {
        follower_id: third,
        leader_epoch: 1UL,
        flushed_seq: 5UL,
        dirty_seq: 5UL,
      },
      third,
    ),
    Ok(()),
  )
  assert_eq(capped.commit_horizon(1UL), 1UL)
  assert_eq(quorum_ceiling(1UL, 5UL, 5UL, quorum), 1UL)

  // The leader is the largest: the answer is the follower that is
  // second, and returning the leader's own position would be one too
  // high.
  let ahead = @cluster.ClusterNode::new(config)
  assert_eq(
    ahead.record_append_ack(
      {
        follower_id: second,
        leader_epoch: 1UL,
        flushed_seq: 3UL,
        dirty_seq: 3UL,
      },
      second,
    ),
    Ok(()),
  )
  assert_eq(
    ahead.record_append_ack(
      {
        follower_id: third,
        leader_epoch: 1UL,
        flushed_seq: 2UL,
        dirty_seq: 2UL,
      },
      third,
    ),
    Ok(()),
  )
  assert_eq(ahead.commit_horizon(9UL), 3UL)
  assert_eq(quorum_ceiling(9UL, 3UL, 2UL, quorum), 3UL)

  // Only what is on disk counts: this follower has written further than
  // it has fsynced, and an entry a crash would take with it must not
  // move the number a consumer reads as committed.
  let unwritten = @cluster.ClusterNode::new(config)
  assert_eq(
    unwritten.record_append_ack(
      {
        follower_id: second,
        leader_epoch: 1UL,
        flushed_seq: 3UL,
        dirty_seq: 7UL,
      },
      second,
    ),
    Ok(()),
  )
  assert_eq(
    unwritten.record_append_ack(
      {
        follower_id: third,
        leader_epoch: 1UL,
        flushed_seq: 1UL,
        dirty_seq: 1UL,
      },
      third,
    ),
    Ok(()),
  )
  assert_eq(unwritten.commit_horizon(5UL), 3UL)
  assert_eq(quorum_ceiling(5UL, 3UL, 1UL, quorum), 3UL)
}

///|
test "a promise quorum and a commit quorum cannot be disjoint (pin seed=20261014; daily mode logs the run seed)" {
  let seed = quorum_seed()
  let count = quorum_count()
  if quorum_daily() {
    println("quorum-daily seed=\{seed} count=\{count}")
  }
  let config = match fixture_config() {
    Err(_) => fail("the fixture table must be valid")
    Ok(config) => config
  }
  @quickcheck.check(
    (draw : UInt32) => {
      // Every member of the quorums below comes out of the code's own
      // bookkeeping, read inside the sample: which members there are,
      // what majority they commit at and who proposed the term are the
      // configuration's, not the property's.
      let node = @cluster.ClusterNode::new(config)
      let table = config.peers()
      let quorum = config.quorum()
      let candidate = config.node_id()
      let others : Array[UInt16] = []
      for entry in table {
        if entry.node_id != candidate {
          others.push(entry.node_id)
        }
      }
      node.begin_election()
      // Nobody has answered, so the candidate's own durable term is one
      // copy and one is not a majority. This is the half of the
      // property a weakened threshold breaks: a `has_*_quorum` that
      // stopped asking for a majority is already true on this line.
      if node.has_prepare_quorum() {
        return false
      }
      if node.has_install_quorum() {
        return false
      }
      // Which member answers each phase comes from the draw, so the two
      // phases sometimes share a member and sometimes do not.
      let span = others.length().reinterpret_as_uint()
      let first = others[(draw % span).reinterpret_as_int()]
      let second = others[(draw / 2U % span).reinterpret_as_int()]

      let promise : @cluster.PrepareAckMsg = {
        responder_id: first,
        promised_epoch: 1UL,
        last_seq: 0UL,
        last_flushed_seq: 0UL,
        commit_seq: 0UL,
      }
      if !node.has_prepare_quorum() {
        match
          @cluster.ClusterNode::record_prepare_ack(node, promise, 1UL, first) {
          Err(_) => return false
          Ok(_) => ()
        }
      }
      // The majority the promise half had to reach: the candidate
      // counts as one of the quorum, so exactly `quorum - 1` members
      // are owed, and the count the code reports has to be that list
      // plus the candidate rather than the list alone.
      if !node.has_prepare_quorum() {
        return false
      }
      if node.promised_members().length() != quorum - 1 {
        return false
      }
      if node.prepared_count() != node.promised_members().length() + 1 {
        return false
      }

      let install : @cluster.InstallAckMsg = {
        responder_id: second,
        epoch: 1UL,
        flushed_seq: 0UL,
      }
      if !node.has_install_quorum() {
        match
          @cluster.ClusterNode::record_install_ack(node, install, 1UL, second) {
          Err(_) => return false
          Ok(_) => ()
        }
      }
      if !node.has_install_quorum() {
        return false
      }
      if node.installed_members().length() != quorum - 1 {
        return false
      }
      if node.installed_count() != node.installed_members().length() + 1 {
        return false
      }

      // The two quorums as the code counts them: the candidate, which
      // the two counts above pin as being on both sides, plus each
      // phase's members.
      let promised_quorum : Array[UInt16] = [candidate]
      for id in node.promised_members() {
        promised_quorum.push(id)
      }
      let installed_quorum : Array[UInt16] = [candidate]
      for id in node.installed_members() {
        installed_quorum.push(id)
      }
      if promised_quorum.length() < quorum || installed_quorum.length() < quorum {
        return false
      }
      // Over a three-member table this holds because both hold the
      // candidate, and the sizes pinned above are what keep it holding.
      // It is stated rather than assumed so that a quorum built without
      // the candidate has somewhere to fail.
      let mut shared = false
      for id in promised_quorum {
        if installed_quorum.contains(id) {
          shared = true
        }
      }
      shared
    },
    count~,
    max_shrinks=20,
    seed~,
  )
}

///|
/// The threshold a quorum is decided at, and the three ways an answer
/// is not one.
///
/// The property above reaches both quorums through these same
/// functions, but a property only shows a threshold to be wrong when a
/// draw happens to land on the wrong side of it. These are the sides
/// themselves: nobody answered, one member answered, the same member
/// answered twice, a term nobody proposed, and a member the table does
/// not hold. The install half is stated beside the promise half because
/// the two are counted separately and can be wrong separately.
test "a quorum is a majority, and only from the members it came from" {
  let node = tracked_node()
  node.begin_election()

  // Nobody has answered: the candidate's own durable term is one copy,
  // and one is not a majority of three.
  assert_eq(node.prepared_count(), 1)
  assert_eq(node.has_prepare_quorum(), false)
  assert_eq(node.installed_count(), 1)
  assert_eq(node.has_install_quorum(), false)

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
  assert_eq(node.has_prepare_quorum(), true)
  // The count is the list plus the candidate, not the list: the
  // assertions above build their quorums the same way, and this pins
  // that the code does too.
  assert_eq(node.prepared_count(), node.promised_members().length() + 1)

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

  // The install half, counted on its own.
  let install : @cluster.InstallAckMsg = {
    responder_id: 3U.to_uint16(),
    epoch: 1UL,
    flushed_seq: 0UL,
  }
  assert_eq(
    @cluster.ClusterNode::record_install_ack(node, install, 1UL, 3U.to_uint16()),
    Ok(()),
  )
  assert_eq(node.installed_count(), 2)
  assert_eq(node.has_install_quorum(), true)
  assert_eq(node.installed_count(), node.installed_members().length() + 1)

  assert_eq(
    @cluster.ClusterNode::record_install_ack(node, install, 1UL, 3U.to_uint16()),
    Ok(()),
  )
  assert_eq(node.installed_count(), 2)
  assert_eq(node.installed_members(), [3U.to_uint16()])

  let wrong_term_install : @cluster.InstallAckMsg = {
    responder_id: 2U.to_uint16(),
    epoch: 9UL,
    flushed_seq: 0UL,
  }
  assert_eq(
    @cluster.ClusterNode::record_install_ack(
      node,
      wrong_term_install,
      1UL,
      2U.to_uint16(),
    ),
    Err(@protocol.StaleLeaderEpoch),
  )
  assert_eq(node.installed_count(), 2)

  let stranger_install : @cluster.InstallAckMsg = {
    responder_id: 9U.to_uint16(),
    epoch: 1UL,
    flushed_seq: 0UL,
  }
  assert_eq(
    @cluster.ClusterNode::record_install_ack(
      node,
      stranger_install,
      1UL,
      9U.to_uint16(),
    ),
    Err(@protocol.MalformedPayload),
  )
  assert_eq(node.installed_count(), 2)
  assert_eq(node.has_install_quorum(), true)
}

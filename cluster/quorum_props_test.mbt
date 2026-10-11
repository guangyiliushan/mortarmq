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
  // One node for the whole run: the property is about what a sequence
  // of acknowledgements does to a position, so the node carrying them
  // has to be the same one across them.
  let node = tracked_node()
  @quickcheck.check(
    (draw : UInt) => {
      // The leader's own durability varies per sample but is fixed
      // within one, because the ceiling is capped by it and a cap that
      // moved mid-sample would hide the thing being measured.
      let own = (draw % 64U).to_uint64() + 1UL
      let mut ceiling = node.commit_horizon(own)
      // What each peer has already reported, so a replay can be checked
      // against the position it was replaying rather than only against
      // the ceiling -- a single peer moving back would often leave the
      // ceiling where it was, and would still be a regression.
      let mut reported_by_two = quorum_position(node, 2U.to_uint16())
      let mut reported_by_three = quorum_position(node, 3U.to_uint16())
      for step in 0..<4 {
        let peer = if step % 2 == 0 { 2U.to_uint16() } else { 3U.to_uint16() }
        // Half the steps replay a position the peer may already have
        // passed; those are the ones that must not walk anything back.
        let reported = if step % 3 == 0 {
          0UL
        } else {
          (draw % 64U).to_uint64() + 1UL
        }
        let before = if peer == 2U.to_uint16() {
          reported_by_two
        } else {
          reported_by_three
        }
        let ack : @cluster.AppendAck = {
          follower_id: peer,
          leader_epoch: 1UL,
          flushed_seq: reported,
          dirty_seq: reported + 1UL,
        }
        match @cluster.ClusterNode::record_append_ack(node, ack) {
          // A refused acknowledgement changes nothing, which is the
          // same conclusion the property draws from an accepted one.
          Err(_) => ()
          Ok(_) => ()
        }
        match node.follower_progress(peer) {
          None => return false
          Some(progress) => if progress.flushed_seq < before { return false }
        }
        if peer == 2U.to_uint16() {
          reported_by_two = quorum_position(node, 2U.to_uint16())
        } else {
          reported_by_three = quorum_position(node, 3U.to_uint16())
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
  // The reason the rest of this holds: two groups that each hold more
  // than half of the members cannot avoid each other. Stated separately
  // so a failure says which half broke -- the arithmetic or the
  // sampling.
  assert_eq(quorum * 2 > table.length(), true)
  @quickcheck.check(
    (draw : UInt) => {
      let span = table.length().reinterpret_as_uint()
      let start_a = (draw % span).reinterpret_as_int()
      let start_b = (draw / 7U % span).reinterpret_as_int()
      let promised = quorum_subset(table, quorum, start_a)
      let durable = quorum_subset(table, quorum, start_b)
      // A member that promised the term and a member that made it
      // durable are never different sets of nodes, so a term is always
      // installed where somebody committed to it first.
      quorum_overlap(promised, durable).length() > 0
    },
    count~,
    seed~,
  )
}

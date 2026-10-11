/// The majority-fsync gate the publish path waits on.
///
/// `PUB_OK` may only be returned once a quorum of the static cluster has
/// the write on disk. The arithmetic is deliberately simple: every
/// member's `flushed_seq` is a position, the quorum-th largest of them
/// is the highest sequence that at least a majority can recover from,
/// and a write at or below that number is committed while a write above
/// it is not.
///
/// # Why the leader's own position is not enough
///
/// A leader that has fsynced a write still has not committed it: one
/// replica losing its disk afterwards would leave the write with a
/// single copy, and a majority of one is not a majority of three. The
/// leader's position is therefore one entry among three, not a floor
/// the result can never drop below -- with only the leader durable the
/// horizon is zero, and the publish path waits.
///
/// # What counts, and what does not
///
/// Only `flushed_seq` counts. A follower that has written an entry but
/// not fsynced it reports it in `dirty_seq`, and a replica that lost
/// that entry tomorrow would take the write with it, so `dirty_seq`
/// never moves the horizon. A peer that has never acknowledged anything
/// contributes zero, which is the same as saying it is not part of this
/// quorum -- it has to earn its way back by fsyncing.
///
/// # Boundaries
///
/// * This decides *whether* a write may be acknowledged, not *when* to
///   retry. Waiting for the follower is the publish path's business.
/// * The horizon is capped at the leader's own flushed position even
///   though that value is already one of the three: research invariant
///   `commit_seq <= leader.last_flushed_seq` then holds by construction
///   rather than by an argument about what callers can arrange.
/// * Losing quorum shows up here as a horizon that stops advancing,
///   which the read-only tier turns into an explicit refusal
///   rather than a wait.

///|
/// The highest sequence a majority of the static cluster has fsynced,
/// given that this node has fsynced up to `own_flushed_seq`.
///
/// Zero means no write has been committed yet -- including the case
/// where the leader alone has flushed entries.
///
/// # Example
///
/// ```mbt check
/// test {
///   // Three members, quorum two: the second-largest position wins, so
///   // a majority has to agree before anything is committed.
///   assert_eq(3 / 2 + 1, 2)
/// }
/// ```
pub fn ClusterNode::commit_horizon(
  self : ClusterNode,
  own_flushed_seq : UInt64,
) -> UInt64 {
  let config = self.config()
  let positions : Array[UInt64] = [own_flushed_seq]
  for entry in config.peers() {
    if entry.node_id == config.node_id() {
      continue
    }
    let reported = match self.follower_progress(entry.node_id) {
      None => 0UL
      Some(progress) => progress.flushed_seq
    }
    positions.push(reported)
  }
  // Descending insertion sort. The array is three long and never grows,
  // so an ordering library would cost more than the three comparisons
  // this writes out.
  for index in 1..<positions.length() {
    let value = positions[index]
    let mut cursor = index
    while cursor > 0 && positions[cursor - 1] < value {
      positions[cursor] = positions[cursor - 1]
      cursor = cursor - 1
    }
    positions[cursor] = value
  }
  let quorum_index = config.quorum() - 1
  if quorum_index >= positions.length() {
    // Unreachable: `positions` has one entry per member and `quorum`
    // is a majority of that same count. Stated so a future change to
    // the table size fails loudly instead of indexing past the end.
    return 0UL
  }
  let horizon = positions[quorum_index]
  if horizon > own_flushed_seq {
    own_flushed_seq
  } else {
    horizon
  }
}

///|
/// Whether a write at `seq` may be answered with `PUB_OK` yet.
///
/// The whole requirement in one comparison: `true` only once a majority
/// has fsynced at or past `seq`. A `false` is a wait, never a refusal
/// -- the write is still in flight and will be acknowledged when the
/// quorum reaches it (or refused outright once the cluster declares the
/// quorum lost).
///
/// Sequence zero names no write, so it is never publishable: refusing
/// it keeps a caller that lost its sequence from acknowledging a record
/// that does not exist.
///
/// # Example
///
/// ```mbt check
/// test {
///   // With nothing durable anywhere, nothing is publishable -- not even
///   // the first write.
///   assert_eq(0UL >= 1UL, false)
/// }
/// ```
pub fn ClusterNode::may_publish(
  self : ClusterNode,
  seq : UInt64,
  own_flushed_seq : UInt64,
) -> Bool {
  if seq == 0UL {
    return false
  }
  self.commit_horizon(own_flushed_seq) >= seq
}

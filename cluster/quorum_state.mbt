/// The three-tier quorum state, and the one place it is named
/// (T045, WP-06.05, REQ-REP-004).
///
/// The frozen degradation matrix has three tiers the cluster can be in,
/// and four surfaces have to agree on them: `/healthz`, the
/// `mortarmq_quorum_state` gauge, the CLI's `quorum_state` column, and
/// the write path's answer to a producer. Four restatements of one
/// table is how they drift, so the tiers, their gauge codes, and the
/// refusal each one owes a producer are defined exactly once, here.
///
/// ```text
/// gauge   tier        runbook level   producer sees
///   0     healthy          2          PUB_OK, durability=quorum
///   1     soft             1          PUB_OK + 0x6004 FOLLOWER_LAG
///   2     read-only        0          refusal, never PUB_OK
/// ```
///
/// # Read-only is a refusal, not a downgrade
///
/// A cluster that cannot form a majority answers `0x6002
/// READ_ONLY_DEGRADED` (or `0x6003 IN_SYNC_REPLICAS_NOT_ENOUGH` when no
/// follower is in sync at all) and does not acknowledge the write. The
/// alternative -- accepting the write on the leader's word alone -- is
/// exactly the false success the requirement forbids: it would tell a
/// producer its record is durable when a single disk loss could take it
/// away. Reads and the consumer-visible ceiling keep working while the
/// cluster is read-only, and that ceiling freezes rather than retreats.
///
/// # Recovery
///
/// The state is re-evaluated after every replication round, so it
/// clears itself as soon as a round completes with a majority in sync.
/// REQ-REP-004's recovery scenario needs no separate trigger: the same
/// classification that declared the loss declares the return.

///|
/// Default deadline for a quorum acknowledgement, in milliseconds.
///
/// From the A06 lease-timing table (`quorum_ack_timeout_ms`, default 50,
/// range 10..1000). It is how long a write waits for a majority to
/// fsync before the cluster declares itself read-only; a producer is
/// never left waiting indefinitely for an answer already known to be
/// no.
pub const QUORUM_ACK_TIMEOUT_MS : Int = 50

///|
/// Why the cluster is read-only -- the row of the frozen matrix, kept
/// distinct from the tier it collapses into.
///
/// Both rows report gauge `2` and both refuse writes, but they owe a
/// producer different codes and an operator different first steps: one
/// says "the majority did not answer in time", the other says "there is
/// no follower to form a majority with", and the runbook sends you to
/// disk and network for the first and to repairing the follower before
/// anything else for the second.
pub(all) enum ReadOnlyReason {
  /// Matrix level 0 (soft timeout): the ack deadline passed before a
  /// majority fsynced. Producer sees `0x6002 READ_ONLY_DEGRADED`.
  AckTimeout
  /// Matrix level 0 (no follower): fewer than a quorum of replicas are
  /// in sync. Producer sees `0x6003 IN_SYNC_REPLICAS_NOT_ENOUGH`.
  NoFollower
} derive(Eq, Debug)

///|
pub extend ReadOnlyReason with Eq::{not_equal, equal}

///|
pub extend ReadOnlyReason with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The three tiers a cluster's quorum can be in.
///
/// Named once so every surface reports the same thing. The gauge code
/// is deliberately derived rather than stored: a new tier cannot be
/// added without deciding what number the operator's alert sees.
pub(all) enum QuorumState {
  /// Gauge `0`. A majority is in sync; writes are answered normally.
  Healthy
  /// Gauge `1`. A quorum is still attainable but at least one member is
  /// trailing; writes still succeed and carry `0x6004 FOLLOWER_LAG`.
  Soft
  /// Gauge `2`. No quorum can be formed right now; writes are refused.
  ReadOnly(ReadOnlyReason)
} derive(Eq, Debug)

///|
pub extend QuorumState with Eq::{not_equal, equal}

///|
pub extend QuorumState with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The gauge code for this tier: `0` healthy, `1` soft, `2` read-only.
///
/// The number `/metrics`, `/healthz` and the CLI all print. Both
/// read-only reasons report `2`, because the operator's alert asks
/// "can this cluster accept writes", not which row caused the no.
///
/// # Example
///
/// ```mbt check
/// test {
///   assert_eq(@cluster.QuorumState::Healthy.code(), 0U.to_uint16())
///   assert_eq(@cluster.QuorumState::Soft.code(), 1U.to_uint16())
///   let timeout = @cluster.QuorumState::ReadOnly(
///     @cluster.ReadOnlyReason::AckTimeout,
///   )
///   let silent = @cluster.QuorumState::ReadOnly(
///     @cluster.ReadOnlyReason::NoFollower,
///   )
///   assert_eq(timeout.code(), 2U.to_uint16())
///   assert_eq(silent.code(), 2U.to_uint16())
/// }
/// ```
pub fn QuorumState::code(self : QuorumState) -> UInt16 {
  match self {
    Healthy => 0U.to_uint16()
    Soft => 1U.to_uint16()
    ReadOnly(_) => 2U.to_uint16()
  }
}

///|
/// Whether a producer may be answered with `PUB_OK` in this tier.
///
/// `false` for every read-only reason: that is the whole point of the
/// tier. The write is refused with `write_refusal`, never acknowledged
/// on the leader's word alone.
///
/// # Example
///
/// ```mbt check
/// test {
///   assert_eq(@cluster.QuorumState::Healthy.may_write(), true)
///   // Soft is still writable: the quorum is short one lagging member,
///   // not missing.
///   assert_eq(@cluster.QuorumState::Soft.may_write(), true)
///   let silent = @cluster.QuorumState::ReadOnly(
///     @cluster.ReadOnlyReason::NoFollower,
///   )
///   assert_eq(silent.may_write(), false)
/// }
/// ```
pub fn QuorumState::may_write(self : QuorumState) -> Bool {
  match self {
    ReadOnly(_) => false
    _ => true
  }
}

///|
/// The registered code a producer gets for a write in this tier, or
/// `None` when the write may proceed.
///
/// The refusal is carried by the row that caused it, which is why the
/// two read-only reasons differ: `0x6002` tells the producer to retry
/// later once a majority answers, `0x6003` says there is no majority to
/// wait for until a follower is repaired.
///
/// # Example
///
/// ```mbt check
/// test {
///   assert_eq(@cluster.QuorumState::Healthy.write_refusal(), None)
///   assert_eq(@cluster.QuorumState::Soft.write_refusal(), None)
///   let timeout = @cluster.QuorumState::ReadOnly(
///     @cluster.ReadOnlyReason::AckTimeout,
///   )
///   let silent = @cluster.QuorumState::ReadOnly(
///     @cluster.ReadOnlyReason::NoFollower,
///   )
///   assert_eq(timeout.write_refusal(), Some(@protocol.ReadOnlyDegraded))
///   assert_eq(silent.write_refusal(), Some(@protocol.InSyncReplicasNotEnough))
/// }
/// ```
pub fn QuorumState::write_refusal(self : QuorumState) -> @protocol.ErrCode? {
  match self {
    Healthy => None
    Soft => None
    ReadOnly(AckTimeout) => Some(@protocol.ReadOnlyDegraded)
    ReadOnly(NoFollower) => Some(@protocol.InSyncReplicasNotEnough)
  }
}

///|
/// The advisory warning a producer gets alongside a successful write in
/// this tier, or `None` when there is nothing to warn about.
///
/// `0x6004 FOLLOWER_LAG` is a success-with-warning: the write is
/// committed and one member is behind. It is never a refusal, which is
/// why the read-only reasons report `None` -- there the refusal already
/// carries the message.
///
/// # Example
///
/// ```mbt check
/// test {
///   assert_eq(@cluster.QuorumState::Soft.warning(), Some(@protocol.FollowerLag))
///   assert_eq(@cluster.QuorumState::Healthy.warning(), None)
///   let timeout = @cluster.QuorumState::ReadOnly(
///     @cluster.ReadOnlyReason::AckTimeout,
///   )
///   assert_eq(timeout.warning(), None)
/// }
/// ```
pub fn QuorumState::warning(self : QuorumState) -> @protocol.ErrCode? {
  match self {
    Soft => Some(@protocol.FollowerLag)
    _ => None
  }
}

///|
/// Classify one observation into a row of the frozen matrix.
///
/// The parameters are the matrix's own columns, so this function is the
/// table rather than a paraphrase of it:
///
/// * `in_sync_count` -- replicas, the leader included, durable at the
///   leader's own position.
/// * `quorum` -- the majority the static table commits at.
/// * `trailing` -- a member is behind the leader while a quorum is
///   still attainable: matrix level 1.
/// * `ack_timeout` -- the ack deadline passed before a majority fsynced:
///   matrix level 0, soft timeout.
///
/// The order matters and follows the runbook. "No follower" is checked
/// first because it is the row the operator must act on before
/// anything else -- repairing the follower, not the network -- and a
/// cluster with no follower to form a majority with has no deadline
/// worth timing. A soft lag is the mildest of the three and so last.
///
/// # Example
///
/// ```mbt check
/// test {
///   // Level 2: leader and a follower both durable, nobody behind.
///   assert_eq(
///     @cluster.classify_quorum(3, 2, false, false),
///     @cluster.QuorumState::Healthy,
///   )
///   // Level 1: quorum attainable, one member trailing.
///   assert_eq(
///     @cluster.classify_quorum(2, 2, true, false),
///     @cluster.QuorumState::Soft,
///   )
///   // Level 0, soft timeout: majority present, this write never made it.
///   let timeout = @cluster.QuorumState::ReadOnly(
///     @cluster.ReadOnlyReason::AckTimeout,
///   )
///   assert_eq(@cluster.classify_quorum(2, 2, true, true), timeout)
///   // Level 0, no follower: not even a majority is in sync.
///   let silent = @cluster.QuorumState::ReadOnly(
///     @cluster.ReadOnlyReason::NoFollower,
///   )
///   assert_eq(@cluster.classify_quorum(1, 2, true, true), silent)
/// }
/// ```
pub fn classify_quorum(
  in_sync_count : Int,
  quorum : Int,
  trailing : Bool,
  ack_timeout : Bool,
) -> QuorumState {
  if in_sync_count < quorum {
    return ReadOnly(NoFollower)
  }
  if ack_timeout {
    return ReadOnly(AckTimeout)
  }
  if trailing {
    return Soft
  }
  Healthy
}

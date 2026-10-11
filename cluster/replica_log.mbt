/// The durability seam replication reads and writes.
///
/// Replication only ever needs four facts about a replica's log: what
/// has been written, what has been fsynced, and the ability to write
/// more. Everything else -- segments, sparse indexes, CRC, quarantine --
/// belongs to the storage layer and is deliberately out of view here,
/// because the two sides of a replication exchange must agree on *when*
/// something is durable, not on *how* it is laid out.
///
/// # The two positions and why they are separate
///
/// A record that has been written but not fsynced is `appended`; one
/// that has been fsynced is `flushed`. The distinction is the whole
/// point of the exchange: a follower that reports a `flushed_seq` it has
/// not fsynced would let a leader count durability it does not have, and
/// `commit_seq` would then run ahead of what any majority can recover
/// from. The wire carries both (`AppendAck.flushed_seq` and
/// `AppendAck.dirty_seq`) so a lagging follower is visible as lagging
/// rather than looking caught up.
///
/// # Invariants a `ReplicaLog` must hold
///
/// 1. `last_flushed_seq <= last_appended_seq`, always. Flush never
///    invents data that was not written.
/// 2. Both positions only ever move forward within one leader epoch; a
///    truncation is a different operation and lands on its own.
/// 3. `append(payloads, true)` returns only after the payloads are
///    durable, so the sequence it reports is a `flushed_seq` by the
///    time the caller can act on it.
/// 4. `append(payloads, false)` advances `last_appended_seq` only; the
///    gap between the two positions is exactly what a later flush
///    closes.
/// 5. One batch is one durable unit, and a `truncate` and the `append`
///    that follows it are never observed apart. The pair is what a
///    divergent tail becomes: the tail goes and the leader's entries
///    take its place, and a crash between the two would leave a log that
///    lost one and did not gain the other. That is indistinguishable
///    from corruption from anywhere outside, so it has to be
///    impossible -- one write, or one that recovery can finish.
/// 6. `truncate(to_seq)` removes every sequence above `to_seq` from both
///    positions. The bytes go, they are not marked: this format has no
///    compaction, so there is no legitimate hole for a removed record to
///    stand in for, and a placeholder left behind would be a record
///    recovery could mistake for data. What is gone is gone.
///
/// # Boundaries
///
/// This trait does not model concurrency, epochs, or quorum. A caller
/// that needs those gets them from the replication exchange, not from
/// the log. Sequence 0 means "nothing has been written", so the first
/// entry of a fresh log carries sequence 1.

///|
/// One replica's view of what it has written and what it has made
/// durable.
///
/// Implemented by whoever owns the bytes: the storage layer for a real
/// node, a test double in the replication tests for a timing case.
/// `cluster` never names an implementation, so the peer protocol can be
/// exercised without a disk and the storage layer never has to know it
/// is being replicated.
pub(open) trait ReplicaLog {
  /// Highest sequence written locally, whether or not it is durable.
  fn last_appended_seq(Self) -> UInt64

  /// Highest sequence that has been fsynced; never above
  /// `last_appended_seq`.
  fn last_flushed_seq(Self) -> UInt64

  /// Write `payloads` in sequence and, when `durable` is set, fsync
  /// before returning.
  ///
  /// Returns the sequence assigned to the first payload, which is one
  /// above the previous `last_appended_seq`, so a caller can build an
  /// `APPEND` batch without asking where the next entry goes. An empty
  /// batch is a no-op and reports the current end of the log.
  async fn append(Self, payloads : Array[Bytes], durable : Bool) -> Result[
    UInt64,
    @protocol.ErrCode,
  ]

  /// Drop every sequence above `to_seq`, moving both positions back to
  /// `to_seq` -- or to zero when the log becomes empty.
  ///
  /// Used when a replica's tail diverges from the leader's: the leader
  /// is offering entries that do not continue what this replica holds,
  /// so the tail goes before the batch lands. Nothing below `to_seq` is
  /// ever requested: a caller's own append position is always at or
  /// above its commit point, so the committed prefix is out of reach by
  /// construction. A `to_seq` at or above the current end is a no-op.
  async fn truncate(Self, to_seq : UInt64) -> Result[Unit, @protocol.ErrCode]

  /// Read back the payloads of the entries starting at `from_seq`, up to
  /// `limit` of them.
  ///
  /// Returns fewer than `limit` at the end of the log and an empty array
  /// when `from_seq` is already past it. It never invents a sequence it
  /// does not hold: a caller catching a follower up asks from a position
  /// the follower reported rather than from a guess, and what comes back
  /// is exactly what this replica has to offer.
  async fn read(Self, from_seq : UInt64, limit : Int) -> Result[
    Array[Bytes],
    @protocol.ErrCode,
  ]
}

/// The leader epoch, written to metadata before it takes effect
/// (T043, WP-06.03, REQ-REP-003).
///
/// One number stands for "which leadership term this replica
/// recognises". It is monotone by construction: a proposal at or below
/// the epoch already recorded is refused rather than applied, so the
/// clock never runs backwards and a delayed or replayed election cannot
/// revive a term the cluster has already left. That is the whole safety
/// property fencing later leans on -- WP-06.06 rejects a stale
/// `APPEND` by comparing against this value, and a comparison is only
/// meaningful if the value underneath it never retreats.
///
/// # Written, not remembered
///
/// The epoch is recorded in the metadata log *before* it becomes the
/// value this replica acts on. If the write fails, nothing changes: a
/// replica that cannot durably record its epoch must not behave as
/// though it had one, or a crash would leave two nodes each believing
/// they are current at an epoch the log never held. This is the
/// research rule "every epoch and promise is fsynced before a role
/// change takes effect", applied at the point where the epoch changes.
///
/// # What the record says
///
/// A `LEADER_ELECT` MMML record carries `record_type` and
/// `leader_epoch` in its header and an empty payload. The frozen v0
/// metadata codec registers payload bodies only for the topic and group
/// declares, so a body here would be a schema no decoder knows: the
/// epoch is what this record exists to persist, and naming the elected
/// node is a schema decision that belongs with whoever registers one.
/// `mutation_id` is 0 for the same reason `SnapshotHint` carries 0 --
/// a leadership change is not a client mutation and has no idempotency
/// key to fence.

///|
/// The durable metadata log a replica records its leader epoch in.
///
/// Encoded bytes go in; the byte offset they land at comes back. The
/// seam exists because "durable" is not something the epoch state can
/// decide for itself -- it has to be told, by whoever owns the log,
/// whether the record actually landed.
pub(open) trait MetadataLog {
  /// Durably append one encoded metadata record, reporting the offset
  /// it was written at.
  async fn append(Self, record : Bytes) -> Result[UInt64, @protocol.ErrCode]
}

///|
/// The mutable epoch of one replica, behind a `Ref` so the value can be
/// read while an election is in flight.
priv struct EpochCore {
  mut current : UInt64
}

///|
/// One replica's view of the current leader epoch.
pub struct LeaderEpoch {
  priv log : &MetadataLog
  priv core : Ref[EpochCore]
}

///|
/// Open an epoch at zero -- no leader has been elected yet.
///
/// # Example
///
/// ```mbt nocheck
/// // Needs a `MetadataLog`, so the runnable coverage lives in
/// // cluster/leader_epoch_test.mbt rather than in a checked example.
/// let epoch = @cluster.LeaderEpoch::new(the_log)
/// assert_eq(epoch.current(), 0UL)
/// ```
pub fn LeaderEpoch::new(log : &MetadataLog) -> LeaderEpoch {
  { log, core: Ref::Ref({ current: 0UL, }), }
}

///|
/// The epoch this replica currently recognises; zero until the first
/// election is recorded.
pub fn LeaderEpoch::current(self : LeaderEpoch) -> UInt64 {
  self.core.val.current
}

///|
/// Record a newly elected epoch in metadata and, only then, adopt it.
///
/// `proposed` is the epoch the election offers -- the candidate's own
/// value, which is why it is an argument rather than a counter this
/// function bumps: the caller decides what the next term is, and this
/// function decides whether it is allowed to be.
///
/// Returns the epoch now in force.
///
/// # Errors
///
/// * `StaleLeaderEpoch` (0x6005) when `proposed` does not exceed the
///   epoch already recorded. Nothing is written and nothing changes --
///   a stale proposal is refused, never silently folded in.
/// * Whatever the metadata log reports when the record could not be
///   written. Again nothing changes: the epoch this replica acts on is
///   exactly the epoch it has durably recorded.
///
/// # Example
///
/// ```mbt nocheck
/// // Needs a live `MetadataLog`, so the runnable coverage is the
/// // election tests rather than a checked example.
/// match @cluster.LeaderEpoch::elect(epoch, 1UL) {
///   Ok(recorded) => assert_eq(recorded, 1UL)
///   Err(@protocol.StaleLeaderEpoch) => fail("the first term must be taken")
///   Err(_) => fail("the log must accept the first record")
/// }
/// ```
pub async fn LeaderEpoch::elect(
  self : LeaderEpoch,
  proposed : UInt64,
) -> Result[UInt64, @protocol.ErrCode] {
  if proposed <= self.core.val.current {
    return Err(@protocol.StaleLeaderEpoch)
  }
  let record = match leader_elect_record(proposed) {
    Err(code) => return Err(code)
    Ok(bytes) => bytes
  }
  // Written first, adopted second. Reversing these two lines would let
  // a failed write leave this replica acting on an epoch the log never
  // held.
  match self.log.append(record) {
    Err(code) => return Err(code)
    Ok(_) => ()
  }
  self.core.val.current = proposed
  Ok(proposed)
}

///|
/// Encode the `LEADER_ELECT` metadata record for `epoch`.
///
/// Kept separate from `elect` so the bytes are inspectable in their own
/// right -- the test decodes them back through the metadata codec and
/// checks the type and epoch came out exactly as they went in.
///
/// # Errors
///
/// * `Internal` (0x000A) if the metadata encoder rejects the header.
///   That encoder only refuses a writer-side contract violation (a
///   version byte that is not 1, or a reserved flag bit set), so this
///   is a bug in this module rather than a recoverable condition.
fn leader_elect_record(epoch : UInt64) -> Result[Bytes, @protocol.ErrCode] {
  let header = @metadata.MmmlHeader::new(
    format_version=1,
    header_version=1,
    flags=0,
    record_type=@metadata.MmmlRecordType::LeaderElect,
    leader_epoch=epoch,
    mutation_id=0,
  )
  match @metadata.encode_mmml_record(header, b"") {
    Err(_) => Err(@protocol.Internal)
    Ok(record) => Ok(record)
  }
}

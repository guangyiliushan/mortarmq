/// Wire the metadata gate into the real entry points.
///
/// A metadata anomaly degrades the system to
/// read-only (0x2003, retry later) and can escalate to quarantine
/// (0x2004, human intervention), that the write path returns
/// those registered codes, and that the state is shown honestly. The
/// gate on its own was only a state machine; this service is the
/// single metadata entry that makes it load-bearing: every mutation
/// and every cache publish consults the gate first, recovery feeds
/// the gate on damage and clears it only after a trustworthy rebuild,
/// and the read face reports the mode a health endpoint must show.
///
/// Reads of already-trusted state stay available in read-only mode --
/// read-only means the writes are refused, not that the data hides.

///|
/// The metadata entry: DECLARE mutations, snapshot publication, and
/// crash recovery, all under one gate.
pub(all) struct MetadataService {
  mut machine : DeclareMachine
  mut gate : MetadataGuard
}

///|
pub fn MetadataService::new() -> MetadataService {
  { machine: DeclareMachine::new(), gate: MetadataGuard::new(), }
}

///|
/// The mode a health endpoint must display: the state is shown
/// honestly.
pub fn MetadataService::read_face(self : MetadataService) -> MetadataMode {
  self.gate.mode()
}

///|
/// The quarantined regions on record for the operator.
pub fn MetadataService::quarantine_entries(
  self : MetadataService,
) -> Array[QuarantineEntry] {
  self.gate.entries()
}

///|
/// The gateed DECLARE write path.
///
/// # Errors
///
/// * `MetadataReadOnly` (0x2003) while the gate is degraded;
///   retry later.
/// * `MetadataQuarantined` (0x2004) after escalation; human
///   intervention.
pub fn MetadataService::submit_mutation(
  self : MetadataService,
  mutation_id : UInt64,
  leader_epoch : UInt64,
  ops : Array[DeclareBody],
) -> Result[Array[DeclareOutcome], @protocol.ErrCode] {
  match self.gate.write_refusal() {
    Some(code) => Err(code)
    None => Ok(self.machine.submit_set(mutation_id, leader_epoch, ops))
  }
}

///|
/// The gateed snapshot publication: a degraded system never publishes
/// a new cache generation from state it cannot trust.
///
/// # Errors
///
/// * `MetadataReadOnly` (0x2003) / `MetadataQuarantined` (0x2004) as
///   above.
/// * The disk fault of a failed publish, carried as its registered
///   code.
pub async fn MetadataService::save(
  self : MetadataService,
  disk : &@harness.Disk,
  dir : Bytes,
  epoch : UInt64,
  end_offset : UInt64,
) -> Result[Unit, @protocol.ErrCode] {
  match self.gate.write_refusal() {
    Some(code) => return Err(code)
    None => ()
  }
  match
    save_snapshot(disk, dir, { machine: self.machine, epoch, end_offset, }) {
    Ok(_) => Ok(())
    Err(fault) => Err(fault.to_err_code())
  }
}

///|
/// The gated crash-recovery path: rebuild machine state from the
/// snapshot chain and log, feed the gate on damage, and clear it only
/// after a trustworthy rebuild.
///
/// `log_bytes` is the log content, not a path: passing path bytes
/// cannot fail loudly here and answers with an empty state (end offset
/// zero), so callers read the file first. `dir` is the directory prefix
/// the snapshot slots live under.
///
/// # Errors
///
/// * `MetadataReadOnly` (0x2003) when recovery met record damage; the
///   damaged region is recorded for the operator and later writes are
///   refused until a rebuild clears the gate.
/// * `Internal` (0x000A) for a disk fault during recovery.
pub async fn MetadataService::recover(
  self : MetadataService,
  disk : &@harness.Disk,
  dir : Bytes,
  log_bytes : Bytes,
) -> Result[SnapshotState, @protocol.ErrCode] {
  match recover_snapshot(disk, dir, log_bytes) {
    Ok(state) => {
      self.machine = state.machine
      self.gate.restore_healthy()
      Ok(state)
    }
    Err(Corruption(offset)) => {
      self.gate.note_log_corruption(offset, 0)
      Err(Corruption(offset).to_err_code())
    }
    Err(fault) => Err(fault.to_err_code())
  }
}

///|
/// The read path: trusted state stays readable in read-only mode
/// (read-only degrades writes, not reads).
pub fn MetadataService::partition_count(
  self : MetadataService,
  name : String,
) -> UInt? {
  self.machine.partition_count(name)
}

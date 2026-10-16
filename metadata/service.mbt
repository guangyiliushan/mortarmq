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
  mut tracker : ChangeTracker
  mut gate : MetadataGuard
}

///|
pub fn MetadataService::new() -> MetadataService {
  {
    machine: DeclareMachine::new(),
    tracker: ChangeTracker::new(),
    gate: MetadataGuard::new(),
  }
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
/// The gated DECLARE write path: journal-then-apply. The packed mutation
/// record lands on the metadata log (and fsyncs) before the in-memory
/// table applies anything, so the log stays the single source of truth
/// the snapshot replay already assumes: an acknowledged mutation always
/// replays, and a mutation whose journal failed never applied. A set the
/// machine would refuse (fenced, epoch-regressed, or count-mismatched)
/// is decided first and answered without journaling, so a refusal never
/// lands on the log for the replay to trip over.
///
/// The journal record is one packed record, the format's atomic unit: at
/// most two ops of one kind (a source and its twin create, or a pair of
/// deletes). A set that does not fit one packed record is refused with
/// `MutationNotPackable` (0x2007); submit it as separate mutations.
///
/// Parameters:
///
/// * `disk` : The disk seam the journal appends through.
/// * `log` : The metadata log path (the shared truth source).
///
/// # Errors
///
/// * `MetadataReadOnly` (0x2003) while the gate is degraded; retry later.
/// * `MetadataQuarantined` (0x2004) after escalation; human intervention.
/// * `MutationNotPackable` (0x2007) when the op set exceeds one packed
///   journal record; nothing was journaled or applied.
/// * `Internal` (0x000A) when the journal encode, append, or fsync
///   failed; nothing was applied.
pub async fn[D : @harness.Disk] MetadataService::submit_mutation(
  self : MetadataService,
  disk : D,
  log : Bytes,
  mutation_id : UInt64,
  leader_epoch : UInt64,
  ops : Array[DeclareBody],
) -> Result[Array[DeclareOutcome], @protocol.ErrCode] {
  match self.gate.write_refusal() {
    Some(code) => return Err(code)
    None => ()
  }
  if ops.length() > 0 {
    if self.machine.decide_set(mutation_id, leader_epoch, ops) is Some(_) {
      return Ok(self.machine.submit_set(mutation_id, leader_epoch, ops))
    }
    let record_type = match journal_record_type(ops) {
      Some(record_type) => record_type
      None => return Err(@protocol.MutationNotPackable)
    }
    match
      journal_declare(disk, log, mutation_id, leader_epoch, ops, record_type) {
      Ok(_) => ()
      Err(code) => return Err(code)
    }
  }
  Ok(self.machine.submit_set(mutation_id, leader_epoch, ops))
}

///|
/// The record type one op set packs into: every op of a journal record
/// shares one kind, and the packed record holds at most a source/twin
/// pair. `None` means the set cannot ride one packed record.
fn journal_record_type(ops : Array[DeclareBody]) -> MmmlRecordType? {
  if ops.length() > 2 {
    return None
  }
  let uniform = match ops[0] {
    Create(_, _) => true
    Delete(_) => false
  }
  for op in ops {
    match op {
      Create(_, _) => if !uniform { return None }
      Delete(_) => if uniform { return None }
    }
  }
  Some(ops[0].to_record_type())
}

///|
/// Append one packed DECLARE mutation record to the metadata log and
/// flush it: the journal-then-apply discipline that keeps an
/// acknowledged mutation on the replay path. A failed append or a failed
/// fsync surfaces as `Internal` and leaves the in-memory table
/// untouched.
async fn[D : @harness.Disk] journal_declare(
  disk : D,
  log : Bytes,
  mutation_id : UInt64,
  leader_epoch : UInt64,
  ops : Array[DeclareBody],
  record_type : MmmlRecordType,
) -> Result[Unit, @protocol.ErrCode] {
  let header = MmmlHeader::new(
    format_version=1,
    header_version=1,
    flags=0,
    record_type~,
    leader_epoch~,
    mutation_id~,
  )
  let record = match encode_mmml_record(header, encode_declare_bodies(ops)[:]) {
    Ok(bytes) => bytes
    Err(_) => return Err(@protocol.Internal)
  }
  let existing = match disk.read(log) {
    Ok(data) => data
    Err(@harness.PathMissing) => b""
    Err(_) => return Err(@protocol.Internal)
  }
  match disk.write(log, existing + record) {
    Ok(_) => ()
    Err(_) => return Err(@protocol.Internal)
  }
  match disk.fsync(log) {
    Ok(_) => Ok(())
    Err(_) => Err(@protocol.Internal)
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
    save_snapshot(disk, dir, {
      machine: self.machine,
      tracker: self.tracker,
      epoch,
      end_offset,
    }) {
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
      self.tracker = state.tracker
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

///|
/// Whether the named feature is finalized (the rule-4 gate before any
/// new-format write).
pub fn MetadataService::is_finalized(
  self : MetadataService,
  name : String,
) -> Bool {
  self.tracker.is_finalized(name)
}

///|
/// Whether any tracked metadata change landed after the given log
/// position (the rule-5 downgrade gate).
pub fn MetadataService::has_changes_since(
  self : MetadataService,
  end_offset : UInt64,
) -> Bool {
  self.tracker.has_changes_since(end_offset)
}

///|
/// The one-way changes on record, in log order (the rollback-refusal
/// explanation).
pub fn MetadataService::one_way_changes(
  self : MetadataService,
) -> Array[TrackedChange] {
  self.tracker.one_way_changes()
}

///|
/// The downgrade preconditions of the compatible-tier rollback.
pub fn MetadataService::downgrade_preconditions(
  self : MetadataService,
  upgrade_end_offset : UInt64,
) -> Array[PreconditionCheck] {
  self.tracker.downgrade_preconditions(upgrade_end_offset)
}

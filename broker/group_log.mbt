/// The production persistence path of one consumer group: every state
/// change lands as a `GroupUpdate` record appended to the metadata log,
/// and a restarted coordinator reloads from that log (the failover face).
///
/// The metadata log is shared with the topic mutations, so the append
/// obeys its discipline: the record carries the log's CURRENT leader
/// epoch -- the metadata replay treats a record whose epoch moves
/// backwards as corruption, so a group record is never appended below the
/// running epoch -- and the record type is one the metadata replay
/// already skips. The payload is the complete group state (one
/// deterministic encoding), so a failed append heals on the next one and
/// the newest decodable record is always the state to restore.
///
/// # Stability
///
/// * Persist is read-modify-write append on the single log stream; the
///   envelope's CRC covers the payload, and a torn tail loses only the
///   record it truncates.
/// * A failed append surfaces as its registered code and leaves the
///   in-memory mutation standing: the next append lands the complete
///   state again (complete-state records make the log self-healing).
/// * Group records carry no mutation identity (the log order is the
///   sequence); the metadata idempotency table never sees them.

///|
/// Append one `GroupUpdate` record carrying the complete group state.
///
/// Parameters:
///
/// * `log` : The metadata log path (the shared truth source).
/// * `leader_epoch` : The log's current leader epoch. Appending below it
///   would read as corruption to the metadata replay; the caller passes
///   the running epoch it appends at.
///
/// # Errors
///
/// * `Internal` -- the encode or the disk append failed.
///
/// Example:
///
/// ```mbt nocheck
/// // The event loop's commit step, after every state change:
/// // let _ = persist_group_state(disk, log, coordinator, leader_epoch)
/// ```
pub async fn[D : @harness.Disk] persist_group_state(
  disk : D,
  log : Bytes,
  coordinator : GroupCoordinator,
  leader_epoch : UInt64,
) -> Result[Unit, @protocol.ErrCode] {
  let payload = GroupCoordinator::encode_state(coordinator)
  let header = @metadata.MmmlHeader::new(
    format_version=1,
    header_version=1,
    flags=0,
    record_type=@metadata.MmmlRecordType::GroupUpdate,
    leader_epoch~,
    mutation_id=0UL,
  )
  let record = match @metadata.encode_mmml_record(header, payload[:]) {
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
  // The group state is the truth its failover reload walks back, so the
  // append is fsynced before it reports success, matching the checkpoint
  // and snapshot publication discipline.
  match disk.fsync(log) {
    Ok(_) => Ok(())
    Err(_) => Err(@protocol.Internal)
  }
}

///|
/// Read the newest decodable group state out of one metadata log.
///
/// The walk mirrors the metadata replay's record slicing (the frozen
/// envelope layout) and consumes it from the end: a record whose envelope
/// decodes but whose group payload does not is stepped over, and an
/// envelope that does not decode ends the walk -- the valid prefix
/// decides. Records of other types are walked past untouched.
pub fn scan_group_state(log : BytesView) -> GroupCoordinator? {
  let mut position = 0
  let mut latest : GroupCoordinator? = None
  while position + @metadata.MMML_HEADER_BYTES <= log.length() {
    let payload_len = match state_read_uint32(log, position + 12) {
      Some(value) => value.reinterpret_as_int()
      None => break
    }
    let record_len = @metadata.MMML_HEADER_BYTES + payload_len
    if position + record_len > log.length() {
      break
    }
    match @metadata.decode_mmml_record(log[position:position + record_len]) {
      Err(_) => break
      Ok(record) =>
        if record.header.record_type == @metadata.MmmlRecordType::GroupUpdate {
          match GroupCoordinator::restore(record.payload[:]) {
            Some(coordinator) => latest = Some(coordinator)
            None => ()
          }
        }
    }
    position = position + record_len
  }
  latest
}

///|
/// Read the group state back from the metadata log on disk.
///
/// Returns `None` when the log holds no decodable group record (a fresh
/// log, or one whose group records were never written): the group starts
/// empty and the members re-join, the degraded path of the matrix.
pub async fn[D : @harness.Disk] load_group_state(
  disk : D,
  log : Bytes,
) -> Result[GroupCoordinator?, @protocol.ErrCode] {
  match disk.read(log) {
    Ok(data) => Ok(scan_group_state(data[:]))
    Err(@harness.PathMissing) => Ok(None)
    Err(_) => Err(@protocol.Internal)
  }
}

///|
/// Join and persist in one step: the production entry of the group event
/// loop. The mutation lands in memory first, then its complete state is
/// appended to the log; a failed append surfaces its code with the
/// mutation standing, and the next successful append heals the log.
///
/// # Errors
///
/// * The join refusals (`GroupMemberLimit`, `GroupAssignmentLimit`).
/// * `Internal` -- the state append failed.
pub async fn[D : @harness.Disk] GroupCoordinator::join_persisted(
  self : GroupCoordinator,
  disk : D,
  log : Bytes,
  connection_id : UInt64,
  topic_id : UInt16,
  partition_count : UInt16,
  leader_epoch : UInt64,
) -> Result[JoinResult, @protocol.ErrCode] {
  let joined = match
    GroupCoordinator::join(self, connection_id, topic_id, partition_count) {
    Ok(joined) => joined
    Err(code) => return Err(code)
  }
  match persist_group_state(disk, log, self, leader_epoch) {
    Ok(_) => Ok(joined)
    Err(code) => Err(code)
  }
}

///|
/// Leave and persist in one step (the production entry, twin of
/// `join_persisted`).
///
/// # Errors
///
/// * `UnknownMember` -- no member holds the id.
/// * `Internal` -- the state append failed.
pub async fn[D : @harness.Disk] GroupCoordinator::leave_persisted(
  self : GroupCoordinator,
  disk : D,
  log : Bytes,
  member_id : UInt64,
  leader_epoch : UInt64,
) -> Result[LeaveResult, @protocol.ErrCode] {
  let left = match GroupCoordinator::leave(self, member_id) {
    Ok(left) => left
    Err(code) => return Err(code)
  }
  match persist_group_state(disk, log, self, leader_epoch) {
    Ok(_) => Ok(left)
    Err(code) => Err(code)
  }
}

/// Metadata snapshot: a regenerable cache over the MMML log.
///
/// The log is the single source of truth (ruling Q9-B); a snapshot never
/// truncates it and is never load-bearing: every snapshot can be dropped
/// and the machine rebuilt by replaying the full log. The snapshot file
/// is a sequence of complete MMML records, so every record carries its
/// own CRC32C (ruling: per-record CRC). A SnapshotHeader record opens
/// the file and a SnapshotFooter record closes it; a file whose footer
/// is missing or that carries trailing bytes is incomplete and refused
/// (KIP-630 control-record convention). All snapshot-file records use
/// the SnapshotHint type (0x0050, non-mutation): their mutation_id must
/// be 0, and SnapshotHint records in the log are skipped by replay and
/// never enter the DECLARE machine (ruling Q10-B).
///
/// Atomic publication follows the storage checkpoint convention: the
/// bytes land in a `.part` sibling first, are fsynced there, and only
/// then rename over the slot file (KIP-630 fetched-snapshot convention),
/// so a slot holds either the complete previous generation or the
/// complete new one at every instant, including when a step fails or the
/// process dies between steps. Two rolling slots keep two generations
/// live at all times (ruling: keep >= 2 generations); the fallback chain
/// is corrupt newest -> previous generation + replay -> full replay.
/// Slots are fixed names because the disk seam has no directory
/// enumeration; the generation identity (end offset) lives in the header
/// record of each file, not in the filename.

///|
pub const SNAPSHOT_FORMAT_VERSION : UInt16 = 1

///|
pub const SNAPSHOT_SLOT_A : Bytes = b"mmml-snapshot-a.checkpoint"

///|
pub const SNAPSHOT_SLOT_B : Bytes = b"mmml-snapshot-b.checkpoint"

///|
/// One decoded snapshot: the rebuilt machine plus its log position.
///
/// `endOffset` is the byte offset just past the last log record the
/// snapshot includes (the resume point for replay); `epoch` is the
/// leaderEpoch of the last included record, 0 when the snapshot is of
/// an empty log.
pub(all) struct SnapshotState {
  machine : DeclareMachine
  epoch : UInt64
  endOffset : UInt64
}

///|
fn snapshotHeaderPayload(endOffset : UInt64) -> Bytes {
  let buf = Buffer()
  buf.write_uint16_be(SNAPSHOT_FORMAT_VERSION)
  buf.write_uint64_be(endOffset)
  buf.contents()
}

///|
fn snapshotFooterPayload() -> Bytes {
  let buf = Buffer()
  buf.write_uint16_be(SNAPSHOT_FORMAT_VERSION)
  buf.contents()
}

///|
fn snapshotRecord(
  epoch : UInt64,
  payload : Bytes,
) -> Result[Bytes, MetadataFault] {
  encodeMmmlRecord(
    MmmlHeader::new(
      formatVersion=1,
      headerVersion=1,
      flags=0,
      recordType=SnapshotHint,
      leaderEpoch=epoch,
      mutationId=0,
    ),
    payload[:],
  )
}

///|
fn encodeTopicEntry(name : String, partitionCount : UInt) -> Bytes {
  let nameBytes = @utf8.encode(name)
  let buf = Buffer()
  buf.write_byte(1)
  buf.write_uint16_be(nameBytes.length().to_uint16())
  buf.write_bytes(nameBytes)
  buf.write_uint_be(partitionCount)
  buf.contents()
}

///|
fn encodeAcceptedEntry(
  key : String,
  mutationId : UInt64,
  body : DeclareBody,
) -> Bytes {
  let keyBytes = @utf8.encode(key)
  let buf = Buffer()
  buf.write_byte(2)
  buf.write_uint16_be(keyBytes.length().to_uint16())
  buf.write_bytes(keyBytes)
  buf.write_uint64_be(mutationId)
  buf.write_uint16_be(body.toRecordType().toUint16())
  buf.write_bytes(body.toPayload())
  buf.contents()
}

///|
/// Encode one complete snapshot file: header record, one state record
/// per topic and per accepted-mutation entry, footer record.
pub fn encodeSnapshot(state : SnapshotState) -> Result[Bytes, MetadataFault] {
  let buf = Buffer()
  match snapshotRecord(state.epoch, snapshotHeaderPayload(state.endOffset)) {
    Ok(record) => buf.write_bytes(record)
    Err(fault) => return Err(fault)
  }
  for (name, partitionCount) in state.machine.topics.to_array() {
    match snapshotRecord(state.epoch, encodeTopicEntry(name, partitionCount)) {
      Ok(record) => buf.write_bytes(record)
      Err(fault) => return Err(fault)
    }
  }
  for (key, table) in state.machine.accepted.to_array() {
    for (mutationId, body) in table.to_array() {
      match
        snapshotRecord(state.epoch, encodeAcceptedEntry(key, mutationId, body)) {
        Ok(record) => buf.write_bytes(record)
        Err(fault) => return Err(fault)
      }
    }
  }
  match snapshotRecord(state.epoch, snapshotFooterPayload()) {
    Ok(record) => buf.write_bytes(record)
    Err(fault) => return Err(fault)
  }
  Ok(buf.contents())
}

///|
fn decodeStateEntry(payload : BytesView, machine : DeclareMachine) -> Unit? {
  if payload.length() < 1 {
    return None
  }
  match payload[0].to_uint() {
    1U => {
      let nameLen = match readUint16Be(payload, 1) {
        Ok(value) => value.to_int()
        Err(_) => return None
      }
      if payload.length() != 3 + nameLen + 4 {
        return None
      }
      let name = @utf8.decode(payload[3:3 + nameLen]) catch {
        Malformed(_) => return None
      }
      let partitionCount = match readUintBe(payload, 3 + nameLen) {
        Ok(value) => value
        Err(_) => return None
      }
      machine.topics.set(name, partitionCount)
      Some(())
    }
    2U => {
      let keyLen = match readUint16Be(payload, 1) {
        Ok(value) => value.to_int()
        Err(_) => return None
      }
      if payload.length() < 3 + keyLen + 8 + 2 {
        return None
      }
      let key = @utf8.decode(payload[3:3 + keyLen]) catch {
        Malformed(_) => return None
      }
      let mutationId = match readUint64Be(payload, 3 + keyLen) {
        Ok(value) => value
        Err(_) => return None
      }
      let bodyCode = match readUint16Be(payload, 11 + keyLen) {
        Ok(value) => value
        Err(_) => return None
      }
      let bodyType = match MmmlRecordType::fromUint16(bodyCode) {
        Some(value) => value
        None => return None
      }
      let body = match decodeDeclareBody(bodyType, payload[13 + keyLen:]) {
        Some(value) => value
        None => return None
      }
      let table = machine.accepted.get_or_init(key, () => Map([]))
      table.set(mutationId, body)
      Some(())
    }
    _ => None
  }
}

///|
/// Decode and validate one complete snapshot file.
///
/// # Errors
///
/// * `Malformed` -- any structural check fails: a record is not a
///   SnapshotHint, a mutation_id is nonzero, the version is not 1, the
///   header or footer payload is malformed, a state entry does not parse,
///   the footer is missing or is not the last record, or the file has
///   trailing bytes. The whole snapshot is then refused; the caller
///   falls back instead of trusting a guess.
pub fn decodeSnapshot(data : BytesView) -> Result[SnapshotState, MetadataFault] {
  if data.length() < 2 * MMML_HEADER_BYTES {
    return Err(Malformed)
  }
  let header = match decodeMmmlRecord(data[:MMML_HEADER_BYTES + 10]) {
    Ok(record) => record
    Err(fault) => return Err(fault)
  }
  if header.header.recordType != SnapshotHint ||
    header.header.mutationId != 0UL ||
    header.payload.length() != 10 {
    return Err(Malformed)
  }
  let version = match readUint16Be(header.payload[:], 0) {
    Ok(value) => value
    Err(fault) => return Err(fault)
  }
  if version != SNAPSHOT_FORMAT_VERSION {
    return Err(Malformed)
  }
  let endOffset = match readUint64Be(header.payload[:], 2) {
    Ok(value) => value
    Err(fault) => return Err(fault)
  }
  let machine = DeclareMachine::new()
  let mut position = MMML_HEADER_BYTES + 10
  let mut sawFooter = false
  for ;; {
    if position == data.length() {
      break
    }
    if position + MMML_HEADER_BYTES > data.length() {
      return Err(Malformed)
    }
    let payloadLen = match readUintBe(data, position + 12) {
      Ok(value) => value.reinterpret_as_int()
      Err(fault) => return Err(fault)
    }
    let recordLen = MMML_HEADER_BYTES + payloadLen
    if position + recordLen > data.length() {
      return Err(Malformed)
    }
    let record = match decodeMmmlRecord(data[position:position + recordLen]) {
      Ok(value) => value
      Err(fault) => return Err(fault)
    }
    if record.header.recordType != SnapshotHint ||
      record.header.mutationId != 0UL ||
      record.header.leaderEpoch != header.header.leaderEpoch {
      return Err(Malformed)
    }
    position = position + recordLen
    if position == data.length() {
      if record.payload.length() != 2 {
        return Err(Malformed)
      }
      let footerVersion = match readUint16Be(record.payload[:], 0) {
        Ok(value) => value
        Err(fault) => return Err(fault)
      }
      if footerVersion != SNAPSHOT_FORMAT_VERSION {
        return Err(Malformed)
      }
      sawFooter = true
    } else {
      match decodeStateEntry(record.payload[:], machine) {
        Some(_) => ()
        None => return Err(Malformed)
      }
    }
  }
  if !sawFooter {
    return Err(Malformed)
  }
  machine.maxEpoch = header.header.leaderEpoch
  Ok({ machine, epoch: header.header.leaderEpoch, endOffset, })
}

///|
fn slotPath(dir : Bytes, slot : Bytes) -> Bytes {
  dir + b"/" + slot
}

///|
/// Publish one generation through a `.part` write, fsync, and atomic
/// rename (storage checkpoint convention; a failed attempt may leave the
/// `.part` file behind and it is never snapshot state). The write target
/// is the slot holding the older generation, so two generations stay
/// live across every save. The atomic-rename capability of the disk is a
/// precondition; a backend without one must not be published through.
///
/// # Errors
///
/// * `DiskFault` -- the write, fsync, or rename step faulted. The
///   previous generations in both slots are left as they were.
pub async fn saveSnapshot(
  disk : &@harness.Disk,
  dir : Bytes,
  state : SnapshotState,
) -> Result[Unit, MetadataFault] {
  let bytes = match encodeSnapshot(state) {
    Ok(value) => value
    Err(fault) => return Err(fault)
  }
  let olderSlot = match loadSnapshot(disk, dir, SNAPSHOT_SLOT_A) {
    Ok(first) =>
      match loadSnapshot(disk, dir, SNAPSHOT_SLOT_B) {
        Ok(second) =>
          if first.endOffset <= second.endOffset {
            SNAPSHOT_SLOT_A
          } else {
            SNAPSHOT_SLOT_B
          }
        Err(_) => SNAPSHOT_SLOT_B
      }
    Err(_) => SNAPSHOT_SLOT_A
  }
  let target = slotPath(dir, olderSlot)
  let part = target + b".part"
  match @harness.Disk::write(disk, part, bytes) {
    Ok(_) => ()
    Err(fault) => return Err(DiskFault(fault))
  }
  match @harness.Disk::fsync(disk, part) {
    Ok(_) => ()
    Err(fault) => return Err(DiskFault(fault))
  }
  match @harness.Disk::rename(disk, part, target) {
    Ok(_) => Ok(())
    Err(fault) => Err(DiskFault(fault))
  }
}

///|
/// Read and validate one snapshot slot.
///
/// # Errors
///
/// * `DiskFault` -- the slot could not be read (including `PathMissing`
///   when the slot has never been written).
/// * `Malformed` -- the slot bytes failed snapshot validation.
pub async fn loadSnapshot(
  disk : &@harness.Disk,
  dir : Bytes,
  slot : Bytes,
) -> Result[SnapshotState, MetadataFault] {
  let bytes = match @harness.Disk::read(disk, slotPath(dir, slot)) {
    Ok(value) => value
    Err(fault) => return Err(DiskFault(fault))
  }
  decodeSnapshot(bytes[:])
}

///|
/// Rebuild machine state: prefer the newest valid snapshot generation,
/// fall back to the previous generation when the newest is corrupt, or
/// to full replay when both are, then replay every log record past the
/// end offset of the snapshot. The log is never modified (ruling Q9-B).
///
/// Replay applies TopicCreate and TopicDelete mutations through the
/// DECLARE machine and skips SnapshotHint and other record types. A
/// snapshot whose end offset lies past the log end is refused like a
/// corrupt one (the pair is inconsistent), and replay enforces the
/// non-decreasing leaderEpoch chain from REQ-STO-006. A log record
/// that fails validation aborts recovery with its offset so the
/// quarantine path can act on the exact record; nothing is skipped.
///
/// # Errors
///
/// * `Corruption` -- a log record at the returned byte offset failed
///   header or CRC validation, or a well-formed mutation contradicts the
///   accepted-mutation table.
/// * `DiskFault` -- a slot failed to read for a reason other than a
///   missing path or a validation refusal (those fall through the chain).
pub async fn recoverSnapshot(
  disk : &@harness.Disk,
  dir : Bytes,
  log : Bytes,
) -> Result[SnapshotState, MetadataFault] {
  let mut best : SnapshotState? = None
  for slot in [SNAPSHOT_SLOT_A, SNAPSHOT_SLOT_B] {
    match loadSnapshot(disk, dir, slot) {
      Ok(candidate) =>
        if candidate.endOffset <= log.length().to_uint64() {
          match best {
            None => best = Some(candidate)
            Some(current) =>
              if candidate.endOffset > current.endOffset {
                best = Some(candidate)
              }
          }
        }
      Err(Malformed) => ()
      Err(DiskFault(@harness.PathMissing)) => ()
      Err(fault) => return Err(fault)
    }
  }
  let mut machine = DeclareMachine::new()
  let mut epoch = 0UL
  let mut position = 0
  match best {
    None => ()
    Some(state) => {
      machine = state.machine
      epoch = state.epoch
      position = state.endOffset.to_int()
    }
  }
  for ;; {
    if position == log.length() {
      break
    }
    if position + MMML_HEADER_BYTES > log.length() {
      return Err(Corruption(position.reinterpret_as_uint()))
    }
    let payloadLen = match readUintBe(log[:], position + 12) {
      Ok(value) => value.reinterpret_as_int()
      Err(_) => return Err(Corruption(position.reinterpret_as_uint()))
    }
    let recordLen = MMML_HEADER_BYTES + payloadLen
    if position + recordLen > log.length() {
      return Err(Corruption(position.reinterpret_as_uint()))
    }
    let record = match decodeMmmlRecord(log[position:position + recordLen]) {
      Ok(value) => value
      Err(_) => return Err(Corruption(position.reinterpret_as_uint()))
    }
    if record.header.leaderEpoch < epoch {
      return Err(Corruption(position.reinterpret_as_uint()))
    }
    match decodeDeclareBody(record.header.recordType, record.payload[:]) {
      Some(body) =>
        match
          machine.submit(
            record.header.mutationId,
            record.header.leaderEpoch,
            body,
          ) {
          Created | Deleted | IdempotentOk => ()
          MutationFenced | NameCountMismatch =>
            return Err(Corruption(position.reinterpret_as_uint()))
        }
      None => ()
    }
    epoch = record.header.leaderEpoch
    position = position + recordLen
  }
  Ok({ machine, epoch, endOffset: position.to_uint64(), })
}

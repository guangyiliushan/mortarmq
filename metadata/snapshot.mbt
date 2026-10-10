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
/// `end_offset` is the byte offset just past the last log record the
/// snapshot includes (the resume point for replay); `epoch` is the
/// leader_epoch of the last included record, 0 when the snapshot is of
/// an empty log.
pub(all) struct SnapshotState {
  machine : DeclareMachine
  epoch : UInt64
  end_offset : UInt64
}

///|
fn snapshot_header_payload(end_offset : UInt64) -> Bytes {
  let buf = Buffer()
  buf.write_uint16_be(SNAPSHOT_FORMAT_VERSION)
  buf.write_uint64_be(end_offset)
  buf.contents()
}

///|
fn snapshot_footer_payload() -> Bytes {
  let buf = Buffer()
  buf.write_uint16_be(SNAPSHOT_FORMAT_VERSION)
  buf.contents()
}

///|
fn snapshot_record(
  epoch : UInt64,
  payload : Bytes,
) -> Result[Bytes, MetadataFault] {
  encode_mmml_record(
    MmmlHeader::new(
      format_version=1,
      header_version=1,
      flags=0,
      record_type=SnapshotHint,
      leader_epoch=epoch,
      mutation_id=0,
    ),
    payload[:],
  )
}

///|
fn encode_topic_entry(name : String, partition_count : UInt) -> Bytes {
  let name_bytes = @utf8.encode(name)
  let buf = Buffer()
  buf.write_byte(1)
  buf.write_uint16_be(name_bytes.length().to_uint16())
  buf.write_bytes(name_bytes)
  buf.write_uint_be(partition_count)
  buf.contents()
}

///|
fn encode_accepted_entry(
  key : String,
  mutation_id : UInt64,
  body : DeclareBody,
) -> Bytes {
  let key_bytes = @utf8.encode(key)
  let buf = Buffer()
  buf.write_byte(2)
  buf.write_uint16_be(key_bytes.length().to_uint16())
  buf.write_bytes(key_bytes)
  buf.write_uint64_be(mutation_id)
  buf.write_uint16_be(body.to_record_type().to_uint16())
  buf.write_bytes(body.to_payload())
  buf.contents()
}

///|
/// Encode one complete snapshot file: header record, one state record
/// per topic and per accepted-mutation entry, footer record.
pub fn encode_snapshot(state : SnapshotState) -> Result[Bytes, MetadataFault] {
  let buf = Buffer()
  match
    snapshot_record(state.epoch, snapshot_header_payload(state.end_offset)) {
    Ok(record) => buf.write_bytes(record)
    Err(fault) => return Err(fault)
  }
  for (name, partition_count) in state.machine.topics.to_array() {
    match
      snapshot_record(state.epoch, encode_topic_entry(name, partition_count)) {
      Ok(record) => buf.write_bytes(record)
      Err(fault) => return Err(fault)
    }
  }
  for (key, table) in state.machine.accepted.to_array() {
    for (mutation_id, body) in table.to_array() {
      match
        snapshot_record(
          state.epoch,
          encode_accepted_entry(key, mutation_id, body),
        ) {
        Ok(record) => buf.write_bytes(record)
        Err(fault) => return Err(fault)
      }
    }
  }
  match snapshot_record(state.epoch, snapshot_footer_payload()) {
    Ok(record) => buf.write_bytes(record)
    Err(fault) => return Err(fault)
  }
  Ok(buf.contents())
}

///|
fn decode_state_entry(payload : BytesView, machine : DeclareMachine) -> Unit? {
  if payload.length() < 1 {
    return None
  }
  match payload[0].to_uint() {
    1U => {
      let name_len = match read_uint16_be(payload, 1) {
        Ok(value) => value.to_int()
        Err(_) => return None
      }
      if payload.length() != 3 + name_len + 4 {
        return None
      }
      let name = @utf8.decode(payload[3:3 + name_len]) catch {
        Malformed(_) => return None
      }
      let partition_count = match read_uint_be(payload, 3 + name_len) {
        Ok(value) => value
        Err(_) => return None
      }
      machine.topics.set(name, partition_count)
      Some(())
    }
    2U => {
      let key_len = match read_uint16_be(payload, 1) {
        Ok(value) => value.to_int()
        Err(_) => return None
      }
      if payload.length() < 3 + key_len + 8 + 2 {
        return None
      }
      let key = @utf8.decode(payload[3:3 + key_len]) catch {
        Malformed(_) => return None
      }
      let mutation_id = match read_uint64_be(payload, 3 + key_len) {
        Ok(value) => value
        Err(_) => return None
      }
      let body_code = match read_uint16_be(payload, 11 + key_len) {
        Ok(value) => value
        Err(_) => return None
      }
      let body_type = match MmmlRecordType::from_uint16(body_code) {
        Some(value) => value
        None => return None
      }
      let body = match decode_declare_body(body_type, payload[13 + key_len:]) {
        Some(value) => value
        None => return None
      }
      let table = machine.accepted.get_or_init(key, () => Map([]))
      table.set(mutation_id, body)
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
pub fn decode_snapshot(
  data : BytesView,
) -> Result[SnapshotState, MetadataFault] {
  if data.length() < 2 * MMML_HEADER_BYTES {
    return Err(Malformed)
  }
  let header = match decode_mmml_record(data[:MMML_HEADER_BYTES + 10]) {
    Ok(record) => record
    Err(fault) => return Err(fault)
  }
  if header.header.record_type != SnapshotHint ||
    header.header.mutation_id != 0UL ||
    header.payload.length() != 10 {
    return Err(Malformed)
  }
  let version = match read_uint16_be(header.payload[:], 0) {
    Ok(value) => value
    Err(fault) => return Err(fault)
  }
  if version != SNAPSHOT_FORMAT_VERSION {
    return Err(Malformed)
  }
  let end_offset = match read_uint64_be(header.payload[:], 2) {
    Ok(value) => value
    Err(fault) => return Err(fault)
  }
  let machine = DeclareMachine::new()
  let mut position = MMML_HEADER_BYTES + 10
  let mut saw_footer = false
  for ;; {
    if position == data.length() {
      break
    }
    if position + MMML_HEADER_BYTES > data.length() {
      return Err(Malformed)
    }
    let payload_len = match read_uint_be(data, position + 12) {
      Ok(value) => value.reinterpret_as_int()
      Err(fault) => return Err(fault)
    }
    let record_len = MMML_HEADER_BYTES + payload_len
    if position + record_len > data.length() {
      return Err(Malformed)
    }
    let record = match
      decode_mmml_record(data[position:position + record_len]) {
      Ok(value) => value
      Err(fault) => return Err(fault)
    }
    if record.header.record_type != SnapshotHint ||
      record.header.mutation_id != 0UL ||
      record.header.leader_epoch != header.header.leader_epoch {
      return Err(Malformed)
    }
    position = position + record_len
    if position == data.length() {
      if record.payload.length() != 2 {
        return Err(Malformed)
      }
      let footer_version = match read_uint16_be(record.payload[:], 0) {
        Ok(value) => value
        Err(fault) => return Err(fault)
      }
      if footer_version != SNAPSHOT_FORMAT_VERSION {
        return Err(Malformed)
      }
      saw_footer = true
    } else {
      match decode_state_entry(record.payload[:], machine) {
        Some(_) => ()
        None => return Err(Malformed)
      }
    }
  }
  if !saw_footer {
    return Err(Malformed)
  }
  Ok({ machine, epoch: header.header.leader_epoch, end_offset, })
}

///|
fn slot_path(dir : Bytes, slot : Bytes) -> Bytes {
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
pub async fn save_snapshot(
  disk : &@harness.Disk,
  dir : Bytes,
  state : SnapshotState,
) -> Result[Unit, MetadataFault] {
  let bytes = match encode_snapshot(state) {
    Ok(value) => value
    Err(fault) => return Err(fault)
  }
  let older_slot = match load_snapshot(disk, dir, SNAPSHOT_SLOT_A) {
    Ok(first) =>
      match load_snapshot(disk, dir, SNAPSHOT_SLOT_B) {
        Ok(second) =>
          if first.end_offset <= second.end_offset {
            SNAPSHOT_SLOT_A
          } else {
            SNAPSHOT_SLOT_B
          }
        Err(_) => SNAPSHOT_SLOT_B
      }
    Err(_) => SNAPSHOT_SLOT_A
  }
  let target = slot_path(dir, older_slot)
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
pub async fn load_snapshot(
  disk : &@harness.Disk,
  dir : Bytes,
  slot : Bytes,
) -> Result[SnapshotState, MetadataFault] {
  let bytes = match @harness.Disk::read(disk, slot_path(dir, slot)) {
    Ok(value) => value
    Err(fault) => return Err(DiskFault(fault))
  }
  decode_snapshot(bytes[:])
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
/// non-decreasing leader_epoch chain from REQ-STO-006. A log record
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
pub async fn recover_snapshot(
  disk : &@harness.Disk,
  dir : Bytes,
  log : Bytes,
) -> Result[SnapshotState, MetadataFault] {
  let mut best : SnapshotState? = None
  for slot in [SNAPSHOT_SLOT_A, SNAPSHOT_SLOT_B] {
    match load_snapshot(disk, dir, slot) {
      Ok(candidate) =>
        if candidate.end_offset <= log.length().to_uint64() {
          match best {
            None => best = Some(candidate)
            Some(current) =>
              if candidate.end_offset > current.end_offset {
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
      position = state.end_offset.to_int()
    }
  }
  for ;; {
    if position == log.length() {
      break
    }
    if position + MMML_HEADER_BYTES > log.length() {
      return Err(Corruption(position.reinterpret_as_uint()))
    }
    let payload_len = match read_uint_be(log[:], position + 12) {
      Ok(value) => value.reinterpret_as_int()
      Err(_) => return Err(Corruption(position.reinterpret_as_uint()))
    }
    let record_len = MMML_HEADER_BYTES + payload_len
    if position + record_len > log.length() {
      return Err(Corruption(position.reinterpret_as_uint()))
    }
    let record = match decode_mmml_record(log[position:position + record_len]) {
      Ok(value) => value
      Err(_) => return Err(Corruption(position.reinterpret_as_uint()))
    }
    if record.header.leader_epoch < epoch {
      return Err(Corruption(position.reinterpret_as_uint()))
    }
    match decode_declare_body(record.header.record_type, record.payload[:]) {
      Some(body) =>
        match machine.submit(record.header.mutation_id, body) {
          Created | Deleted | IdempotentOk => ()
          MutationFenced | NameCountMismatch =>
            return Err(Corruption(position.reinterpret_as_uint()))
        }
      None => ()
    }
    epoch = record.header.leader_epoch
    position = position + record_len
  }
  Ok({ machine, epoch, end_offset: position.to_uint64(), })
}

/// Recover durable segment-writer state at startup from a checkpoint plus the
/// records it covers.
///
/// The live checkpoint file is two-valued by construction -- an interrupted
/// publish leaves either the complete previous bytes or the complete new
/// bytes -- so recovery always starts from one of exactly two durable
/// starting points. From the checkpoint's `durable_offset` the segment body
/// is walked as a concatenation of v0 records (`u32_be record_len ||
/// u32_be crc32c || 48-byte header suffix || key || value`), folding each
/// complete record into the recovered state: the sequence becomes
/// `record.sequence + 1` and the offset advances past the record. The edge
/// policies are fixed:
///
/// * A missing live checkpoint file replays from zero -- offset 0, and the
///   sequence comes from the replayed records themselves (0 when none).
/// * Durable bytes that cannot be trusted abort recovery instead of being
///   guessed over: a checkpoint that fails to decode, a complete-length
///   record that fails validation, a checkpoint offset past the segment end,
///   and a missing segment that a nonzero durable prefix still references
///   all report a fault.
/// * A truncated trailing record -- fewer than four remaining bytes, or a
///   length prefix whose record extends past the segment end -- ends replay
///   at the last complete record boundary. Replay never resynchronizes
///   mid-record, so the recovered durable state is the checkpoint plus
///   complete records only.
///
/// # Stability
///
/// `durable_offset` and every replay position are byte offsets into the
/// segment record area starting at 0; the tmp sibling of the checkpoint is
/// never state and is never read. The recovered state is a pure function of
/// the surviving disk bytes: the same bytes always recover the same state,
/// which is what makes a crash replay reproducible bit for bit.

///|
/// One record replayed from the segment body, kept for re-encoding.
///
/// `header`, `key`, and `value` carry exactly the durable bytes; encoding
/// them again reproduces the original record bytes bit for bit.
pub(all) struct RecoveredRecord {
  header : RecordHeader
  key : Bytes
  value : Bytes
} derive(Eq, Debug)

///|
pub extend RecoveredRecord with Eq::{not_equal, equal}

///|
pub extend RecoveredRecord with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The recovered durable state plus the records replayed on top of it.
///
/// `checkpoint` is the state the writer would publish next: the running
/// `next_sequence` and a `durable_offset` ending at the last complete
/// record. `records` lists the replayed records in file order; it is empty
/// when the checkpoint already covers the whole segment.
pub(all) struct SegmentRecovery {
  checkpoint : SegmentCheckpoint
  records : Array[RecoveredRecord]
} derive(Eq, Debug)

///|
pub extend SegmentRecovery with Eq::{not_equal, equal}

///|
pub extend SegmentRecovery with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Recover the durable segment state from its checkpoint and record bytes.
///
/// Reads `checkpoint_path` first: a missing file starts recovery from zero,
/// a readable file fixes the replay start at its `durable_offset`, and bytes
/// that fail to decode abort recovery with that fault. Then walks
/// `segment_path` from that offset, folding every complete record into the
/// recovered state and stopping at the first incomplete trailing record.
///
/// Parameters:
///
/// * `disk` : The durable file seam both files are read through.
/// * `segment_path` : The segment record area, a concatenation of v0
///   records.
/// * `checkpoint_path` : The live checkpoint file; its tmp sibling is never
///   read.
///
/// Returns the recovered durable state -- the checkpoint the writer would
/// publish next -- followed by every record replayed on top of it, in file
/// order.
///
/// # Errors
///
/// * `Malformed` when the checkpoint decodes to nothing usable, a
///   complete-length record fails validation, or the checkpoint's
///   `durable_offset` points past the segment end.
/// * `DiskFault` when a disk read fails for any reason other than a missing
///   file, or when a nonzero durable prefix references a missing segment.
///
/// Example:
///
/// ```mbt check
/// async test {
///   let disk : &@harness.Disk = @harness.FakeDisk::new()
///   let header = @storage.RecordHeader::new(
///     flags=0,
///     key_length=0,
///     value_length=3,
///     sequence=1UL,
///     producer_id=0UL,
///     producer_seq=0UL,
///     timestamp_unix_ms=0UL,
///     leader_epoch=0,
///     replication_flags=0,
///   )
///   let record = match @storage.encode_record_header(header, b"", b"abc") {
///     Ok(bytes) => bytes
///     Err(_) => fail("example record encoding failed")
///   }
///   assert_eq(@harness.Disk::write(disk, b"partition.segment", record), Ok(()))
///   assert_eq(
///     @storage.recover_segment(
///       disk, b"partition.segment", b"partition.checkpoint",
///     ),
///     Ok({
///       checkpoint: { next_sequence: 2UL, durable_offset: 59U, },
///       records: [{ header, key: b"", value: b"abc", }],
///     }),
///   )
/// }
/// ```
pub async fn recover_segment(
  disk : &@harness.Disk,
  segment_path : Bytes,
  checkpoint_path : Bytes,
) -> Result[SegmentRecovery, StorageFault] {
  let checkpoint = match @harness.Disk::read(disk, checkpoint_path) {
    Ok(bytes) =>
      match decode_checkpoint(bytes[:]) {
        Ok(state) => Some(state)
        Err(code) => return Err(code)
      }
    Err(@harness.PathMissing) => None
    Err(fault) => return Err(DiskFault(fault))
  }
  let segment = match @harness.Disk::read(disk, segment_path) {
    Ok(bytes) => bytes
    Err(@harness.PathMissing) => {
      match checkpoint {
        Some(state) =>
          // A nonzero durable prefix names bytes the segment must hold.
          if state.durable_offset > 0U {
            return Err(DiskFault(@harness.PathMissing))
          }
        None => ()
      }
      b""
    }
    Err(fault) => return Err(DiskFault(fault))
  }
  let mut next_sequence = 0UL
  let mut start = 0U
  match checkpoint {
    Some(state) => {
      if state.durable_offset > segment.length().reinterpret_as_uint() {
        return Err(Malformed)
      }
      next_sequence = state.next_sequence
      start = state.durable_offset
    }
    None => ()
  }
  let view = segment[:]
  let length = segment.length()
  let records : Array[RecoveredRecord] = []
  let mut position = start.reinterpret_as_int()
  while position < length {
    if length - position < 4 {
      // Trailing bytes too few to hold a length prefix: torn write tail.
      break
    }
    let record_length = match header_uint(view, position) {
      Ok(value) => value
      Err(code) => return Err(code)
    }
    if record_length > (length - position - 4).reinterpret_as_uint() {
      // The framed record extends past the segment end: torn write tail.
      break
    }
    let total = 4 + record_length.reinterpret_as_int()
    let body = view[position:position + total]
    let header = match decode_record_header(body) {
      Ok(header) => header
      Err(code) => return Err(code)
    }
    let key_end = RECORD_HEADER_BYTES + header.key_length.to_int()
    let value_end = key_end + header.value_length.reinterpret_as_int()
    records.push({
      header,
      key: body[RECORD_HEADER_BYTES:key_end].to_owned(),
      value: body[key_end:value_end].to_owned(),
    })
    next_sequence = header.sequence + 1UL
    position = position + total
  }
  Ok({
    checkpoint: {
      next_sequence,
      durable_offset: position.reinterpret_as_uint(),
    },
    records,
  })
}

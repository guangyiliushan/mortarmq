/// Append validated v0 records into a size-bounded segment file and roll over
/// to a fresh segment at the rotation threshold.
///
/// A segment file is a bare concatenation of v0 records -- `4-byte big-endian
/// record_len || 4-byte big-endian crc32c || 48-byte header suffix || key ||
/// value` -- with no file-level prefix, so every sealed segment is directly
/// readable by the startup replay path and the sparse index reader at its
/// original path. The writer owns one active segment at a time under the
/// names `base_path || "." || segment_index` with the index counting up from
/// zero. Each append encodes one complete record, extends the active file,
/// and fsyncs it; when the next record would push the active record area past
/// `segment_max_bytes`, the active segment seals and the record starts a
/// fresh segment file. Sealed files never change again and stay readable for
/// the life of the log.
///
/// # Rotation
///
/// The threshold is measured on the segment record area in bytes. A record
/// that fits the remaining room lands in the active segment; one that does
/// not rolls over first. An empty active segment accepts any single record
/// even when it exceeds the threshold, so one record can never be refused for
/// being too large for its own segment; at the default 64 MiB threshold the
/// protocol value cap keeps every record smaller than one segment.
///
/// # Sequences
///
/// The writer assigns partition-local sequences strictly increasing from
/// `start_sequence`, so the files it produces carry no sequence gap by
/// construction.
///
/// # Durability
///
/// An append publishes its bytes with a write followed by an fsync of the
/// segment file. The in-memory state advances once the write succeeds, so a
/// failed fsync still leaves the complete record in the file and the next
/// append builds on it; only a failed write leaves both the file and the
/// writer unchanged. An append that returns an error therefore never
/// silently drops bytes that a later append would overwrite.

///|
/// Default rotation threshold of one segment record area: 64 MiB.
pub const SEGMENT_MAX_BYTES : Int = 67108864

///|
/// Where one append landed and how large it is on disk.
///
/// `file_offset` is the offset of the record's 4-byte length prefix inside
/// the segment record area, and `record_len` is the total encoded length
/// including that prefix -- the two extents a sparse index entry anchors.
pub(all) struct AppendedRecord {
  sequence : UInt64
  segment_index : Int
  segment_path : Bytes
  file_offset : Int
  record_len : Int
} derive(Eq, Debug)

///|
pub extend AppendedRecord with Eq::{not_equal, equal}

///|
pub extend AppendedRecord with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Why an append did not complete.
///
/// The variants name which trust boundary refused: the record request
/// itself, the watermark gate, or the durable file operation.
pub(all) suberror AppendFault {
  /// Wrap a record-validation fault raised while building the request.
  Record(StorageFault)
  /// Wrap a disk fault raised while publishing the new record area.
  Disk(@harness.HarnessFault)
  /// Report a watermark-gate refusal decided before any disk operation
  /// ran. The wire mapping to 0x4004 STORAGE_HIGH_WATERMARK belongs to
  /// the protocol/delivery layer, not this module.
  Capacity
} derive(Eq, Debug)

///|
pub extend AppendFault with Eq::{not_equal, equal}

///|
pub extend AppendFault with @moonbitlang/core/debug.Debug::{to_repr}

///|
priv struct SegmentWriterState {
  base_path : Bytes
  segment_max_bytes : Int
  mut segment_index : Int
  mut active_body : Bytes
  mut next_sequence : UInt64
} derive(Debug)

///|
/// Own one partition's append-only segment file series.
///
/// The writer is a pure state machine over the disk seam: it holds the
/// active segment's record area in memory as the source of truth for the
/// next write, and every append goes through the caller-supplied disk.
/// Rotation is decided before any disk operation runs, so a failed append
/// leaves the segment index and the record area exactly as they were.
pub(all) struct SegmentWriter {
  priv state : Ref[SegmentWriterState]
} derive(Debug)

///|
pub extend SegmentWriter with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Open a segment series that starts empty at `start_sequence`.
///
/// Parameters:
///
/// * `base_path` : Path prefix every segment file derives from; segment
///   `n` lives at `base_path || "." || n`.
/// * `segment_max_bytes` : Rotation threshold of one segment record area.
///   Defaults to `SEGMENT_MAX_BYTES`; a non-positive value makes every
///   record start its own segment.
/// * `start_sequence` : Sequence assigned to the first appended record.
///
/// Example:
///
/// ```mbt check
/// async test {
///   let disk : &@harness.Disk = @harness.FakeDisk::new()
///   let writer = @storage.SegmentWriter::new(b"part-0.segment")
///   let result = @storage.SegmentWriter::append(writer, disk, b"", b"abc")
///   let appended = match result {
///     Ok(record) => record
///     Err(_) => fail("append failed")
///   }
///   inspect(appended.sequence, content="0")
///   inspect(writer.active_bytes(), content="59")
/// }
/// ```
pub fn SegmentWriter::new(
  base_path : Bytes,
  segment_max_bytes? : Int = SEGMENT_MAX_BYTES,
  start_sequence? : UInt64 = 0UL,
) -> SegmentWriter {
  {
    state: Ref::Ref({
      base_path,
      segment_max_bytes,
      segment_index: 0,
      active_body: b"",
      next_sequence: start_sequence,
    }),
  }
}

///|
/// Derive the file path of one segment of the series.
pub fn SegmentWriter::segment_path(self : SegmentWriter, index : Int) -> Bytes {
  segment_path_of(self.state.val.base_path, index)
}

///|
/// Derive the file path of one segment of the series.
pub fn segment_path_of(base_path : Bytes, index : Int) -> Bytes {
  base_path + b"." + @utf8.encode(index.to_string())
}

///|
/// Report the path of the segment appends currently extend.
pub fn SegmentWriter::active_path(self : SegmentWriter) -> Bytes {
  segment_path_of(self.state.val.base_path, self.state.val.segment_index)
}

///|
/// Report how many bytes the active segment record area holds.
pub fn SegmentWriter::active_bytes(self : SegmentWriter) -> Int {
  self.state.val.active_body.length()
}

///|
/// Report the sequence the next append assigns.
pub fn SegmentWriter::next_sequence(self : SegmentWriter) -> UInt64 {
  self.state.val.next_sequence
}

///|
/// Report how many segments the series holds, sealed and active.
pub fn SegmentWriter::segment_count(self : SegmentWriter) -> Int {
  self.state.val.segment_index + 1
}

///|
/// Encode one record and append it to the active segment, rolling over
/// first when it no longer fits.
///
/// The writer derives the record's flags, key and value lengths, and
/// sequence from the call and the writer state; the remaining header fields
/// are the caller's. A successful append leaves the complete record in the
/// segment file and returns where it landed.
///
/// Parameters:
///
/// * `disk` : The durable file seam the segment series is published through.
/// * `key` : Record key bytes; the empty value produces an unkeyed record.
/// * `value` : Record value bytes, bounded by the protocol value cap.
/// * `producer_id` : Producer identity recorded in the header; 0 when the
///   caller has none.
/// * `producer_seq` : Producer-local sequence recorded in the header.
/// * `timestamp_unix_ms` : Arrival wall time recorded in the header; never
///   used for ordering.
/// * `leader_epoch` : Leader epoch recorded in the header.
/// * `replication_flags` : Replication kind 0-3 recorded in the header.
///
/// Returns the appended record's sequence and on-disk extent.
///
/// # Errors
///
/// * `Record(Malformed)` when the request cannot become a valid v0 record;
///   the writer state is unchanged.
/// * `Capacity` when a supplied watermark gate refuses the projected size;
///   the writer state is unchanged and no disk operation ran.
/// * `Disk(fault)` when the write fails -- the writer state is unchanged --
///   or when only the fsync fails, in which case the complete record is
///   already in the file and the writer state includes it.
///
/// Example:
///
/// ```mbt check
/// async test {
///   let disk : &@harness.Disk = @harness.FakeDisk::new()
///   let writer = @storage.SegmentWriter::new(
///     b"part-0.segment",
///     segment_max_bytes=100,
///   )
///   assert_eq(
///     @storage.SegmentWriter::append(
///       writer,
///       disk,
///       b"k",
///       b"v",
///       timestamp_unix_ms=7UL,
///     )
///     is Ok(_),
///     true,
///   )
///   assert_eq(
///     @storage.SegmentWriter::append(writer, disk, b"", b"vv") is Ok(_),
///     true,
///   )
///   inspect(writer.segment_count(), content="2")
/// }
/// ```
pub async fn SegmentWriter::append(
  self : SegmentWriter,
  disk : &@harness.Disk,
  key : Bytes,
  value : Bytes,
  producer_id? : UInt64 = 0UL,
  producer_seq? : UInt64 = 0UL,
  timestamp_unix_ms? : UInt64 = 0UL,
  leader_epoch? : UInt = 0,
  replication_flags? : Byte = b'\x00',
  watermark? : Watermark,
) -> Result[AppendedRecord, AppendFault] {
  let flags : UInt16 = if key.length() > 0 { 1 } else { 0 }
  let header = RecordHeader::new(
    flags~,
    key_length=key.length().to_uint16(),
    value_length=value.length().reinterpret_as_uint(),
    sequence=self.state.val.next_sequence,
    producer_id~,
    producer_seq~,
    timestamp_unix_ms~,
    leader_epoch~,
    replication_flags~,
  )
  let record = match encode_record_header(header, key, value) {
    Ok(bytes) => bytes
    Err(code) => return Err(Record(code))
  }
  // The watermark gate runs before any disk operation so a refusal never
  // leaves half a record behind; the projected size includes this record.
  match watermark {
    Some(gate) =>
      match gate.check_append(record.length()) {
        Ok(_) => ()
        Err(fault) => return Err(fault)
      }
    None => ()
  }
  // Decide the target segment without mutating state, so a failed write
  // leaves the series exactly as it was.
  let mut target_index = self.state.val.segment_index
  let mut base_body = self.state.val.active_body
  let must_roll = base_body.length() > 0 &&
    base_body.length() + record.length() > self.state.val.segment_max_bytes
  if must_roll {
    target_index = target_index + 1
    base_body = b""
  }
  let file_offset = base_body.length()
  let new_body = base_body + record
  let path = segment_path_of(self.state.val.base_path, target_index)
  match @harness.Disk::write(disk, path, new_body) {
    Ok(_) => ()
    Err(fault) => return Err(Disk(fault))
  }
  // The bytes are in the file: advance the in-memory source of truth before
  // the fsync so a later append can only build on the durable record.
  self.state.val.segment_index = target_index
  self.state.val.active_body = new_body
  self.state.val.next_sequence = header.sequence + 1UL
  match @harness.Disk::fsync(disk, path) {
    Ok(_) => ()
    Err(fault) => return Err(Disk(fault))
  }
  Ok({
    sequence: header.sequence,
    segment_index: target_index,
    segment_path: path,
    file_offset,
    record_len: record.length(),
  })
}

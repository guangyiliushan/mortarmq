/// Encode the segment writer durable checkpoint and replace it atomically.
///
/// A checkpoint file is exactly 21 bytes: `b"MMQC" || u8 format_version ||
/// u32_be crc32c || u64_be next_sequence || u32_be durable_offset`. The CRC
/// covers the 12 payload bytes after the stored CRC field, mirroring the
/// record convention. `write_checkpoint` publishes a new state through a
/// `path.tmp` sibling with write, fsync, rename ordering, so a reader of
/// `path` observes either the complete previous bytes or the complete new
/// bytes and never a mixture: every interruption, at any point, leaves the
/// durable state two-valued. Whatever sits at the tmp path is never
/// checkpoint state -- a failed attempt leaves it behind and the next
/// attempt overwrites it. Renaming over the live file relies on the
/// atomic-rename capability the platform must provide.
///
/// # Stability
///
/// Format version 1 is frozen. Any layout change bumps the version byte as a
/// one-way transition; version-1 decoders reject the new bytes as malformed
/// instead of guessing.

///|
/// Exact encoded size of a version-1 segment checkpoint.
pub const CHECKPOINT_BYTES : Int = 21

///|
const CHECKPOINT_MAGIC : Bytes = b"MMQC"

///|
const CHECKPOINT_FORMAT_VERSION : Byte = b'\x01'

///|
/// Durable segment-writer state that startup replay recovers bit-exact.
///
/// `next_sequence` is the sequence the writer assigns to the next record;
/// `durable_offset` is the byte length of the segment's durable prefix.
pub(all) struct SegmentCheckpoint {
  next_sequence : UInt64
  durable_offset : UInt
} derive(Eq, Debug)

///|
pub extend SegmentCheckpoint with Eq::{not_equal, equal}

///|
pub extend SegmentCheckpoint with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn checkpoint_payload(checkpoint : SegmentCheckpoint) -> Bytes {
  let buf = Buffer()
  buf.write_uint64_be(checkpoint.next_sequence)
  buf.write_uint_be(checkpoint.durable_offset)
  buf.contents()
}

///|
/// Encode a checkpoint into its 21-byte self-identifying, CRC-protected form.
///
/// The output always has exactly `CHECKPOINT_BYTES` bytes and always decodes
/// back to an equal state.
///
/// Example:
///
/// ```mbt check
/// test {
///   let state : @storage.SegmentCheckpoint = {
///     next_sequence: 7UL,
///     durable_offset: 4096U,
///   }
///   let bytes = @storage.encode_checkpoint(state)
///   assert_eq(bytes.length(), @storage.CHECKPOINT_BYTES)
///   assert_eq(@storage.decode_checkpoint(bytes[:]), Ok(state))
/// }
/// ```
pub fn encode_checkpoint(checkpoint : SegmentCheckpoint) -> Bytes {
  let payload = checkpoint_payload(checkpoint)
  let crc = crc32c(payload[:])
  let buf = Buffer()
  buf.write_bytes(CHECKPOINT_MAGIC)
  buf.write_byte(CHECKPOINT_FORMAT_VERSION)
  buf.write_uint_be(crc)
  buf.write_bytes(payload)
  buf.contents()
}

///|
/// Decode and validate exactly one version-1 checkpoint file body.
///
/// The input must be exactly 21 bytes carrying the checkpoint magic, format
/// version 1, and a CRC matching the trailing payload. Truncated, extended,
/// foreign, or corrupted byte streams are rejected as malformed rather than
/// decoded to a guess.
///
/// Example:
///
/// ```mbt check
/// test {
///   let state : @storage.SegmentCheckpoint = {
///     next_sequence: 1UL,
///     durable_offset: 62U,
///   }
///   assert_eq(
///     @storage.decode_checkpoint(@storage.encode_checkpoint(state)[:]),
///     Ok(state),
///   )
///   assert_eq(@storage.decode_checkpoint(b""[:]), Err(@storage.Malformed))
/// }
/// ```
pub fn decode_checkpoint(
  data : BytesView,
) -> Result[SegmentCheckpoint, StorageFault] {
  if data.length() != CHECKPOINT_BYTES {
    return Err(Malformed)
  }
  for index in 0..<4 {
    if data[index] != CHECKPOINT_MAGIC[index] {
      return Err(Malformed)
    }
  }
  if data[4] != CHECKPOINT_FORMAT_VERSION {
    return Err(Malformed)
  }
  let stored_crc32c = match header_uint(data, 5) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if stored_crc32c != crc32c(data[9:CHECKPOINT_BYTES]) {
    return Err(Malformed)
  }
  let next_sequence = match header_uint64(data, 9) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let durable_offset = match header_uint(data, 17) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  Ok({ next_sequence, durable_offset, })
}

///|
/// Publish a checkpoint through a tmp write, fsync, and atomic rename.
///
/// The encoded state lands at `path.tmp` first, is fsynced there, and only
/// then renames over `path`, so `path` holds either the complete previous
/// bytes or the complete new bytes at every instant, including when any step
/// fails or the process dies between steps. The two-state guarantee rests on
/// the disk reporting an atomic rename capability; the v0 fake disk always
/// does, and a backend without one must not be published through. A failed
/// attempt may leave the tmp file behind; it is never checkpoint state, and
/// the next attempt overwrites it.
///
/// Parameters:
///
/// * `disk` : The durable file seam to publish through.
/// * `path` : Live checkpoint file; the tmp sibling is `path.tmp`.
/// * `checkpoint` : The durable state to publish.
///
/// # Errors
///
/// * Any write, fsync, or rename fault stops the attempt immediately with
///   that fault, leaving `path` holding the previous bytes. The harness fault
///   vocabulary is propagated verbatim because a kill-point fault is the
///   publisher's observable outcome; recovery reads wrap their faults into
///   `DiskFault` instead, since a reader only reports why the bytes could
///   not be trusted.
///
/// Example:
///
/// ```mbt check
/// async test {
///   let disk : &@harness.Disk = @harness.FakeDisk::new()
///   let state : @storage.SegmentCheckpoint = {
///     next_sequence: 7UL,
///     durable_offset: 4096U,
///   }
///   assert_eq(
///     @storage.write_checkpoint(disk, b"segment.checkpoint", state),
///     Ok(()),
///   )
///   assert_eq(
///     @harness.Disk::read(disk, b"segment.checkpoint"),
///     Ok(@storage.encode_checkpoint(state)),
///   )
/// }
/// ```
pub async fn write_checkpoint(
  disk : &@harness.Disk,
  path : Bytes,
  checkpoint : SegmentCheckpoint,
) -> Result[Unit, @harness.HarnessFault] {
  let tmp_path = path + b".tmp"
  match @harness.Disk::write(disk, tmp_path, encode_checkpoint(checkpoint)) {
    Err(fault) => return Err(fault)
    Ok(_) => ()
  }
  match @harness.Disk::fsync(disk, tmp_path) {
    Err(fault) => return Err(fault)
    Ok(_) => ()
  }
  @harness.Disk::rename(disk, tmp_path, path)
}

/// Validate the frozen v0 sparse index entry boundary.
///
/// One entry is exactly 32 bytes: `u64_be sequence || u64_be
/// timestamp_unix_ms || u32_be file_offset || u32_be record_len || 8 zero
/// bytes`. The 32-byte width is a frozen hardware-alignment decision: four
/// entries fill each 64-byte cache block exactly, and an index file is a bare
/// concatenation of entries starting at file offset 0, so entry `k` occupies
/// `[32k, 32k+32)` and no entry ever straddles a block boundary.
///
/// # Stability
///
/// Field order, widths, and the all-zero reserved tail are part of the v0
/// on-disk contract and never change in place. A reserved byte other than
/// zero, or an input length other than exactly 32 bytes, decodes to
/// `Err(Malformed)` rather than to a guess.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@storage.INDEX_ENTRY_BYTES, 32)
/// }
/// ```

///|
/// Exact encoded size of one v0 sparse index entry.
pub const INDEX_ENTRY_BYTES : Int = 32

///|
/// Fixed fields of one sparse index entry.
///
/// `sequence` is the broker sequence of the record the entry anchors;
/// `file_offset` points at the record's 4-byte length prefix in the segment
/// file, and `record_len` is that record's total encoded length including the
/// prefix. The 8 reserved on-disk bytes are not part of the in-memory DTO.
pub(all) struct IndexEntry {
  sequence : UInt64
  timestamp_unix_ms : UInt64
  file_offset : UInt
  record_len : UInt
} derive(Eq, Debug)

///|
pub extend IndexEntry with Eq::{not_equal, equal}

///|
pub extend IndexEntry with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Materialize caller-provided v0 sparse index fields without normalizing
/// them.
///
/// Encode and decode perform the trust-boundary validation; this constructor
/// exists only as an explicit literal constructor for tests.
///
/// Example:
///
/// ```mbt check
/// test {
///   let entry = @storage.IndexEntry::new(
///     sequence=1UL,
///     timestamp_unix_ms=2UL,
///     file_offset=56U,
///     record_len=64U,
///   )
///   assert_eq(entry.file_offset, 56U)
/// }
/// ```
pub fn IndexEntry::new(
  sequence~ : UInt64,
  timestamp_unix_ms~ : UInt64,
  file_offset~ : UInt,
  record_len~ : UInt,
) -> IndexEntry {
  { sequence, timestamp_unix_ms, file_offset, record_len, }
}

///|
/// Encode one entry into its exact 32-byte on-disk layout.
///
/// The reserved tail is always written as zero bytes. Every field is
/// fixed-width, so encoding cannot fail; the decoder is the trust boundary.
///
/// Example:
///
/// ```mbt check
/// test {
///   let entry = @storage.IndexEntry::new(
///     sequence=100UL,
///     timestamp_unix_ms=200UL,
///     file_offset=56U,
///     record_len=64U,
///   )
///   assert_eq(@storage.encode_index_entry(entry).length(), 32)
/// }
/// ```
pub fn encode_index_entry(entry : IndexEntry) -> Bytes {
  let buf = Buffer()
  buf.write_uint64_be(entry.sequence)
  buf.write_uint64_be(entry.timestamp_unix_ms)
  buf.write_uint_be(entry.file_offset)
  buf.write_uint_be(entry.record_len)
  buf.write_bytes(b"\x00\x00\x00\x00\x00\x00\x00\x00")
  buf.contents()
}

///|
/// Decode and validate one sparse index entry from exactly 32 bytes.
///
/// The input must contain exactly `INDEX_ENTRY_BYTES` bytes and every
/// reserved byte must be zero. Length consistency and the reserved tail are
/// checked at this trust boundary.
///
/// # Errors
///
/// Raises `Malformed` when the input length is not exactly 32 bytes or any
/// reserved byte is nonzero.
///
/// Example:
///
/// ```mbt check
/// test {
///   let entry = @storage.IndexEntry::new(
///     sequence=100UL,
///     timestamp_unix_ms=200UL,
///     file_offset=56U,
///     record_len=64U,
///   )
///   let encoded = @storage.encode_index_entry(entry)
///   assert_eq(@storage.decode_index_entry(encoded[:]), Ok(entry))
/// }
/// ```
pub fn decode_index_entry(data : BytesView) -> Result[IndexEntry, StorageFault] {
  if data.length() != INDEX_ENTRY_BYTES {
    return Err(Malformed)
  }
  let sequence = match header_uint64(data, 0) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let timestamp_unix_ms = match header_uint64(data, 8) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let file_offset = match header_uint(data, 16) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let record_len = match header_uint(data, 20) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  for index in 24..<32 {
    if data[index] != 0 {
      return Err(Malformed)
    }
  }
  Ok({ sequence, timestamp_unix_ms, file_offset, record_len, })
}

/// Query a v0 sparse index file and the record each entry anchors.
///
/// An index file is a bare concatenation of `INDEX_ENTRY_BYTES` entries
/// starting at file offset 0 with no header or padding, so the decoder walks
/// it in fixed strides and never guesses a boundary. A point read is two
/// steps: locate the entry whose sequence equals the requested sequence by
/// binary search over the sequence-ordered entries -- `lookup_index_view`
/// touches only the strides it visits, so the cost is logarithmic in the
/// index size no matter how the file is read -- then decode the record
/// header found at the entry's `file_offset` spanning exactly `record_len`
/// bytes. One visited stride and one record header are touched per point
/// read regardless of the index size.
///
/// # Staleness
///
/// The index is a snapshot of the prefix that was indexed when it was
/// written. Appends that land in the segment afterwards are invisible to
/// lookup until the index is rewritten, and a sequence above the last
/// indexed entry is a miss, not a fault; a caller that must observe newer
/// records scans the segment forward from the last entry's offset.
///
/// # Constraints
///
/// The search requires entries sorted by strictly increasing `sequence`,
/// which the append-only writer produces; an unsorted array is outside the
/// contract and is never re-sorted here. A sequence no entry carries is a
/// normal miss and returns `None`, not a fault. A missing or malformed
/// index file fails the lookup instead of degrading to a full segment
/// scan; recovering from that state is a caller policy, not a property of
/// this file. A found entry whose extent falls outside the segment bytes,
/// or whose record decodes with a different sequence than the entry's,
/// reports `Malformed`: the index and the segment disagree.

///|
/// Decode a whole v0 sparse index file into its entries, in file order.
///
/// This is a load-time bulk decode: it validates every stride and hands
/// back the full entry array, for startup validation or in-memory index
/// use. Per-read lookups over a file should go through `lookup_index_view`,
/// which decodes only the strides it visits. Empty input decodes to an
/// empty index. Each stride is validated by `decode_index_entry`, so a
/// nonzero reserved byte anywhere in the file fails the whole file.
///
/// # Errors
///
/// Raises `Malformed` when the length is not an exact multiple of
/// `INDEX_ENTRY_BYTES` or any entry stride fails entry validation.
///
/// Example:
///
/// ```mbt check
/// test {
///   let entry = @storage.IndexEntry::new(
///     sequence=1UL,
///     timestamp_unix_ms=2UL,
///     file_offset=0U,
///     record_len=62U,
///   )
///   let file = @storage.encode_index_entry(entry)
///   assert_eq(@storage.decode_index_file(file[:]), Ok([entry]))
///   assert_eq(@storage.decode_index_file(b""[:]), Ok([]))
/// }
/// ```
pub fn decode_index_file(
  data : BytesView,
) -> Result[Array[IndexEntry], StorageFault] {
  if data.length() % INDEX_ENTRY_BYTES != 0 {
    return Err(Malformed)
  }
  let entries : Array[IndexEntry] = []
  for index in 0..<(data.length() / INDEX_ENTRY_BYTES) {
    let start = index * INDEX_ENTRY_BYTES
    match decode_index_entry(data[start:start + INDEX_ENTRY_BYTES]) {
      Ok(entry) => entries.push(entry)
      Err(code) => return Err(code)
    }
  }
  Ok(entries)
}

///|
/// Locate the entry carrying exactly `sequence` by binary search.
///
/// The entries must be sorted by strictly increasing `sequence`, as the
/// append-only writer produces. Empty input yields `None`, as does a miss --
/// including a sequence below the first or above the last entry.
///
/// Example:
///
/// ```mbt check
/// test {
///   let entries = [
///     @storage.IndexEntry::new(
///       sequence=7UL,
///       timestamp_unix_ms=0UL,
///       file_offset=0U,
///       record_len=62U,
///     ),
///   ]
///   assert_eq(@storage.lookup_index_entry(entries, 7UL), Some(entries[0]))
///   assert_eq(@storage.lookup_index_entry(entries, 8UL), None)
/// }
/// ```
pub fn lookup_index_entry(
  entries : Array[IndexEntry],
  sequence : UInt64,
) -> IndexEntry? {
  let mut base = 0
  let mut size = entries.length()
  while size > 1 {
    let half = size / 2
    if entries[base + half - 1].sequence < sequence {
      base = base + half
    }
    size = size - half
  }
  if size == 1 && entries[base].sequence == sequence {
    Some(entries[base])
  } else {
    None
  }
}

///|
/// Locate the entry carrying exactly `sequence` in raw index-file bytes.
///
/// The view is searched as `INDEX_ENTRY_BYTES` strides sorted by strictly
/// increasing `sequence`; only the strides the search visits are decoded,
/// so the cost is logarithmic in the file size and a corrupted stride the
/// search never visits stays invisible, exactly as it would on disk. A
/// length that is not an exact multiple of `INDEX_ENTRY_BYTES`, a visited
/// stride that fails entry validation, or an unreadable stride prefix
/// reports `Malformed`. Empty input is a valid empty index and misses.
///
/// # Errors
///
/// Raises `Malformed` for a partial trailing stride and for a visited
/// stride that fails validation.
///
/// Example:
///
/// ```mbt check
/// test {
///   let entry = @storage.IndexEntry::new(
///     sequence=7UL,
///     timestamp_unix_ms=0UL,
///     file_offset=0U,
///     record_len=62U,
///   )
///   let file = @storage.encode_index_entry(entry)
///   assert_eq(@storage.lookup_index_view(file[:], 7UL), Ok(Some(entry)))
///   assert_eq(@storage.lookup_index_view(file[:], 8UL), Ok(None))
/// }
/// ```
pub fn lookup_index_view(
  data : BytesView,
  sequence : UInt64,
) -> Result[IndexEntry?, StorageFault] {
  if data.length() % INDEX_ENTRY_BYTES != 0 {
    return Err(Malformed)
  }
  let mut base = 0
  let mut size = data.length() / INDEX_ENTRY_BYTES
  while size > 1 {
    let half = size / 2
    let pivot = (base + half - 1) * INDEX_ENTRY_BYTES
    let pivot_sequence = match read_uint64_be(data, pivot) {
      Ok(value) => value
      Err(code) => return Err(code)
    }
    if pivot_sequence < sequence {
      base = base + half
    }
    size = size - half
  }
  if size != 1 {
    return Ok(None)
  }
  let start = base * INDEX_ENTRY_BYTES
  let found_sequence = match read_uint64_be(data, start) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if found_sequence != sequence {
    return Ok(None)
  }
  match decode_index_entry(data[start:start + INDEX_ENTRY_BYTES]) {
    Ok(entry) => Ok(Some(entry))
    Err(code) => Err(code)
  }
}

///|
/// Decode the record header one index entry anchors from the segment bytes.
///
/// The entry's extent is `[file_offset, file_offset + record_len)` counted
/// from offset 0 of the given bytes. An extent outside those bytes, a record
/// that fails record validation, or a decoded record whose sequence differs
/// from the entry's all report `Malformed`: the index and the segment
/// disagree.
///
/// # Errors
///
/// Raises `Malformed` for an out-of-range extent and for any record-level
/// validation failure, including a sequence mismatch with the entry.
///
/// Example:
///
/// ```mbt check
/// test {
///   let header = @storage.RecordHeader::new(
///     flags=1,
///     key_length=1,
///     value_length=1,
///     sequence=1UL,
///     producer_id=1UL,
///     producer_seq=1UL,
///     timestamp_unix_ms=2UL,
///     leader_epoch=0,
///     replication_flags=0,
///   )
///   let record = match @storage.encode_record_header(header, b"k", b"v") {
///     Ok(bytes) => bytes
///     Err(_) => fail("record fixture encoding failed")
///   }
///   let entry = @storage.IndexEntry::new(
///     sequence=1UL,
///     timestamp_unix_ms=2UL,
///     file_offset=0U,
///     record_len=record.length().reinterpret_as_uint(),
///   )
///   match @storage.read_record_header_at(record[:], entry) {
///     Ok(decoded) => assert_eq(decoded.sequence, 1UL)
///     Err(_) => fail("expected the anchored record to decode")
///   }
/// }
/// ```
pub fn read_record_header_at(
  records : BytesView,
  entry : IndexEntry,
) -> Result[RecordHeader, StorageFault] {
  let total = records.length().reinterpret_as_uint()
  if entry.file_offset > total || entry.record_len > total - entry.file_offset {
    return Err(Malformed)
  }
  let start = entry.file_offset.reinterpret_as_int()
  let end = start + entry.record_len.reinterpret_as_int()
  let decoded = match decode_record_header(records[start:end]) {
    Ok(header) => header
    Err(code) => return Err(code)
  }
  if decoded.sequence == entry.sequence {
    Ok(decoded)
  } else {
    Err(Malformed)
  }
}

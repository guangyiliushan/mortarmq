/// Fixed v0 layouts for storage segment identity and append-only record headers.

///|
/// Segment magic shared by every v0 storage file.
const SEGMENT_MAGIC : Bytes = b"MMQS"

///|
/// Maximum value bytes permitted by the A01 wire protocol.
const MAX_RECORD_VALUE_BYTES : UInt = 0x00FFFC00U

///|
/// Exact encoded size of a v0 record header.
pub const RECORD_HEADER_BYTES : Int = 56

///|
/// Report malformed on-disk storage bytes without leaking an OS error.
pub(all) suberror StorageFault {
  Malformed
} derive(Eq, Debug)

///|
pub extend StorageFault with Eq::{not_equal, equal}

///|
pub extend StorageFault with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Fixed fields preceding one record's key and value bytes.
///
/// `record_len` is derived from the two length fields and therefore is not part
/// of the in-memory DTO. `record_crc32c` is supplied by the write path after
/// the key/value bytes are available.
pub(all) struct RecordHeader {
  flags : UInt16
  key_length : UInt16
  value_length : UInt
  sequence : UInt64
  producer_id : UInt64
  producer_seq : UInt64
  timestamp_unix_ms : UInt64
  leader_epoch : UInt
  replication_flags : Byte
  record_crc32c : UInt
} derive(Eq, Debug)

///|
pub extend RecordHeader with Eq::{not_equal, equal}

///|
pub extend RecordHeader with @moonbitlang/core/debug.Debug::{to_repr}

///|
priv struct HeaderCursor {
  data : BytesView
  mut offset : Int
}

///|
fn HeaderCursor::take(
  self : HeaderCursor,
  length : Int,
) -> Result[BytesView, StorageFault] {
  let remaining = self.data.length() - self.offset
  if length < 0 || length > remaining {
    return Err(Malformed)
  }
  let view = self.data[self.offset:self.offset + length]
  self.offset = self.offset + length
  Ok(view)
}

///|
fn HeaderCursor::uint16(self : HeaderCursor) -> Result[UInt16, StorageFault] {
  match self.take(2) {
    Ok(data) => Ok(((data[0].to_uint() << 8) | data[1].to_uint()).to_uint16())
    Err(code) => Err(code)
  }
}

///|
fn HeaderCursor::uint(self : HeaderCursor) -> Result[UInt, StorageFault] {
  match self.take(4) {
    Ok(data) =>
      Ok(
        (data[0].to_uint() << 24) +
        (data[1].to_uint() << 16) +
        (data[2].to_uint() << 8) +
        data[3].to_uint(),
      )
    Err(code) => Err(code)
  }
}

///|
fn HeaderCursor::uint64(self : HeaderCursor) -> Result[UInt64, StorageFault] {
  match self.take(8) {
    Ok(data) => {
      let mut value = 0UL
      for index in 0..<=7 {
        value = (value << 8) | data[index].to_uint64()
      }
      Ok(value)
    }
    Err(code) => Err(code)
  }
}

///|
/// Validate the leading `MMQS`, format, and header-version bytes of a segment.
///
/// This is the segment-level identity check; v0 record headers do not repeat
/// magic or format version in every record.
pub fn validate_segment_identity(
  data : BytesView,
) -> Result[Unit, StorageFault] {
  if data.length() < 6 {
    return Err(Malformed)
  }
  for index in 0..<4 {
    if data[index] != SEGMENT_MAGIC[index] {
      return Err(Malformed)
    }
  }
  if data[4] != 1 || data[5] != 1 {
    return Err(Malformed)
  }
  Ok(())
}

///|
/// Decode and validate the fixed fields of a 56-byte record header.
///
/// The input must contain the complete record (`4 + record_len` bytes), so
/// length consistency and protocol value bounds are checked at the trust
/// boundary before recovery or append code sees the header.
///
/// # Example
///
/// ```mbt check
/// test {
///   let bytes = @storage.encode_record_header(
///     @storage.RecordHeader::new(
///       flags=0,
///       key_length=0,
///       value_length=5,
///       sequence=1UL,
///       producer_id=2UL,
///       producer_seq=3UL,
///       timestamp_unix_ms=4UL,
///       leader_epoch=0,
///       replication_flags=0,
///       record_crc32c=6,
///     ),
///     b"",
///     b"value",
///   )
///   match @storage.decode_record_header(bytes[:]) {
///     Ok(header) => assert_eq(header.sequence, 1UL)
///     Err(_) => fail("expected record header")
///   }
/// }
/// ```
pub fn decode_record_header(
  data : BytesView,
) -> Result[RecordHeader, StorageFault] {
  if data.length() < RECORD_HEADER_BYTES {
    return Err(Malformed)
  }
  let cursor = { data, offset: 0, }
  let record_length = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let record_crc32c = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let flags = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let key_length = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let value_length = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let sequence = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let producer_id = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let producer_seq = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let timestamp_unix_ms = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let leader_epoch = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let replication_flags = match cursor.take(1) {
    Ok(value) => value[0]
    Err(code) => return Err(code)
  }
  let reserved = match cursor.take(3) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if record_length != 52U + key_length.to_uint() + value_length {
    return Err(Malformed)
  }
  if value_length > MAX_RECORD_VALUE_BYTES {
    return Err(Malformed)
  }
  let reserved_flag_bits = flags.to_uint() & 0xFFFCU
  if reserved_flag_bits != 0U {
    return Err(Malformed)
  }
  if replication_flags > 3 {
    return Err(Malformed)
  }
  for byte in reserved {
    if byte != 0 {
      return Err(Malformed)
    }
  }
  if data.length() < 4 + record_length.reinterpret_as_int() {
    return Err(Malformed)
  }
  if cursor.offset != RECORD_HEADER_BYTES {
    return Err(Malformed)
  }
  Ok({
    flags,
    key_length,
    value_length,
    sequence,
    producer_id,
    producer_seq,
    timestamp_unix_ms,
    leader_epoch,
    replication_flags,
    record_crc32c,
  })
}

///|
/// Encode exact header fields and key/value bytes into a v0 record.
///
/// The caller supplies the CRC after key/value bytes because the frozen CRC
/// scope is every byte after the four-byte CRC field.
///
/// # Example
///
/// ```mbt check
/// test {
///   let bytes = @storage.encode_record_header(
///     @storage.RecordHeader::new(
///       flags=0,
///       key_length=0,
///       value_length=5,
///       sequence=1UL,
///       producer_id=2UL,
///       producer_seq=3UL,
///       timestamp_unix_ms=4UL,
///       leader_epoch=0,
///       replication_flags=0,
///       record_crc32c=6,
///     ),
///     b"",
///     b"value",
///   )
///   assert_eq(bytes.length(), 61)
/// }
/// ```
pub fn encode_record_header(
  header : RecordHeader,
  key : BytesView,
  value : BytesView,
) -> Bytes {
  let buf = Buffer()
  let record_length = 52 + key.length() + value.length()
  buf.write_uint_be(record_length.reinterpret_as_uint())
  buf.write_uint_be(header.record_crc32c)
  buf.write_uint16_be(header.flags)
  buf.write_uint16_be(header.key_length)
  buf.write_uint_be(header.value_length)
  buf.write_uint64_be(header.sequence)
  buf.write_uint64_be(header.producer_id)
  buf.write_uint64_be(header.producer_seq)
  buf.write_uint64_be(header.timestamp_unix_ms)
  buf.write_uint_be(header.leader_epoch)
  buf.write_byte(header.replication_flags)
  buf.write_bytes(b"\x00\x00\x00")
  buf.write_bytes(key)
  buf.write_bytes(value)
  buf.contents()
}

///|
/// Construct a v0 header with zero reserved and replication-normal fields.
pub fn RecordHeader::new(
  flags~ : UInt16,
  key_length~ : UInt16,
  value_length~ : UInt,
  sequence~ : UInt64,
  producer_id~ : UInt64,
  producer_seq~ : UInt64,
  timestamp_unix_ms~ : UInt64,
  leader_epoch~ : UInt,
  replication_flags~ : Byte,
  record_crc32c~ : UInt,
) -> RecordHeader {
  {
    flags,
    key_length,
    value_length,
    sequence,
    producer_id,
    producer_seq,
    timestamp_unix_ms,
    leader_epoch,
    replication_flags,
    record_crc32c,
  }
}

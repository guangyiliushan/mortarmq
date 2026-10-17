/// Validate the frozen v0 MMML metadata-log record boundary.
///
/// An MMML record is `4-byte magic "MMML" || 1-byte format_version || 1-byte
/// header_version || 2-byte flags || 4-byte record_crc32c || 4-byte
/// payload_len || 2-byte record_type || 8-byte leader_epoch || 8-byte
/// mutation_id || payload`. The fixed header is exactly 34 bytes including
/// the magic; `record_crc32c` covers every byte after the stored CRC field
/// (the header tail and the payload), mirroring the v0 storage record
/// convention, so a flip in `payload_len`, `record_type`, `leader_epoch`, or
/// `mutation_id` is corruption and never a silent re-interpretation of the
/// idempotency key. Field order and widths are part of the v0 on-disk
/// contract and never change in place.
///
/// # Stability
///
/// `format_version` 1 and `header_version` 1 are frozen. Any layout change
/// bumps the version bytes as a one-way transition; version-1 decoders
/// reject the new bytes as malformed instead of guessing. `flags` bit0 marks
/// a compressed payload and bit1 a tombstone; the remaining bits are
/// reserved and must be zero. Unregistered `record_type` values are refused
/// at the trust boundary: the v0 policy for a type the format cannot name is
/// fail-fast, never an implicit skip.

///|
/// Exact encoded size of a v0 MMML record header.
pub const MMML_HEADER_BYTES : Int32 = 34

///|
/// Current frozen MMML format and header layout versions.
pub const MMML_FORMAT_VERSION : Int32 = 1

///|

///|
pub const MMML_HEADER_VERSION : Int32 = 1

///|
const MMML_MAGIC : Bytes = b"MMML"

///|
/// Report metadata failures without leaking an OS error.
///
/// The codec boundary folds every structural and content rejection into
/// `Malformed`; `Corruption` names the byte offset of a record that failed
/// validation while walking a log, so recovery can quarantine from the
/// damaged record instead of guessing over durable state it cannot trust.
pub(all) suberror MetadataFault {
  Malformed
  /// A record at the given byte offset of the metadata log failed header or
  /// CRC validation; the offset is the record's first byte.
  Corruption(UInt32)
  /// Wrap a disk fault raised while reading or publishing metadata state;
  /// recovery fails closed instead of guessing over durable state it cannot
  /// read.
  DiskFault(@ports.PortFault)
} derive(Eq, Debug)

///|
pub extend MetadataFault with Eq::{not_equal, equal}

///|
pub extend MetadataFault with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The thirteen v0 MMML record types, including the explicit fallback slot.
///
/// The numeric codes are the frozen on-disk discriminants. `UnknownFallback`
/// is a registered placeholder, not a decode catch-all: a decode of a code
/// that is not registered returns `None`, so an unknown type can never be
/// silently replayed as a known one.
pub(all) enum MmmlRecordType {
  TopicCreate
  TopicUpdate
  TopicDelete
  GroupCreate
  GroupUpdate
  GroupDelete
  BrokerRegister
  BrokerDeregister
  LeaderElect
  LeaderResign
  ConfigUpdate
  SnapshotHint
  UnknownFallback
} derive(Eq, Debug)

///|
pub extend MmmlRecordType with Eq::{not_equal, equal}

///|
pub extend MmmlRecordType with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Encode the record-type discriminant that follows `payload_len`.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@metadata.MmmlRecordType::TopicCreate.to_uint16(), 0x0001)
///   assert_eq(@metadata.MmmlRecordType::UnknownFallback.to_uint16(), 0xFFFE)
/// }
/// ```
pub fn MmmlRecordType::to_uint16(self : MmmlRecordType) -> UInt16 {
  match self {
    TopicCreate => 0x0001U.to_uint16()
    TopicUpdate => 0x0002U.to_uint16()
    TopicDelete => 0x0003U.to_uint16()
    GroupCreate => 0x0010U.to_uint16()
    GroupUpdate => 0x0011U.to_uint16()
    GroupDelete => 0x0012U.to_uint16()
    BrokerRegister => 0x0020U.to_uint16()
    BrokerDeregister => 0x0021U.to_uint16()
    LeaderElect => 0x0030U.to_uint16()
    LeaderResign => 0x0031U.to_uint16()
    ConfigUpdate => 0x0040U.to_uint16()
    SnapshotHint => 0x0050U.to_uint16()
    UnknownFallback => 0xFFFEU.to_uint16()
  }
}

///|
/// Decode a record-type discriminant without allocating.
///
/// Returns `None` for every code that is not one of the thirteen registered
/// values; the caller turns that into a refusal at the trust boundary
/// instead of inventing a fallback.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(
///     @metadata.MmmlRecordType::from_uint16(0x0050),
///     Some(@metadata.MmmlRecordType::SnapshotHint),
///   )
///   assert_eq(@metadata.MmmlRecordType::from_uint16(0x1234), None)
/// }
/// ```
pub fn MmmlRecordType::from_uint16(code : UInt16) -> MmmlRecordType? {
  match code.to_uint() {
    0x0001U => Some(TopicCreate)
    0x0002U => Some(TopicUpdate)
    0x0003U => Some(TopicDelete)
    0x0010U => Some(GroupCreate)
    0x0011U => Some(GroupUpdate)
    0x0012U => Some(GroupDelete)
    0x0020U => Some(BrokerRegister)
    0x0021U => Some(BrokerDeregister)
    0x0030U => Some(LeaderElect)
    0x0031U => Some(LeaderResign)
    0x0040U => Some(ConfigUpdate)
    0x0050U => Some(SnapshotHint)
    0xFFFEU => Some(UnknownFallback)
    _ => None
  }
}

///|
/// Fixed fields of one MMML record, without its derived length and CRC.
///
/// `payload_len` and `record_crc32c` are derived by the write path and are
/// not part of the in-memory DTO, mirroring the v0 storage record header.
pub(all) struct MmmlHeader {
  format_version : Byte
  header_version : Byte
  flags : UInt16
  record_type : MmmlRecordType
  leader_epoch : UInt64
  mutation_id : UInt64
} derive(Eq, Debug)

///|
pub extend MmmlHeader with Eq::{not_equal, equal}

///|
pub extend MmmlHeader with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Materialize caller-provided MMML header fields without normalizing them.
///
/// Encode and decode perform the actual trust-boundary validation; this
/// constructor exists only as an explicit literal constructor for tests.
pub fn MmmlHeader::new(
  format_version~ : Byte,
  header_version~ : Byte,
  flags~ : UInt16,
  record_type~ : MmmlRecordType,
  leader_epoch~ : UInt64,
  mutation_id~ : UInt64,
) -> MmmlHeader {
  {
    format_version,
    header_version,
    flags,
    record_type,
    leader_epoch,
    mutation_id,
  }
}

///|
/// One decoded MMML record: its validated header and its payload bytes.
pub(all) struct MmmlRecord {
  header : MmmlHeader
  payload : Bytes
} derive(Eq, Debug)

///|
pub extend MmmlRecord with Eq::{not_equal, equal}

///|
pub extend MmmlRecord with @moonbitlang/core/debug.Debug::{to_repr}

///|
// ponytail: bit-by-bit CRC is correct but O(8n); table/native CRC when measured metadata throughput needs it.
fn crc32c(data : BytesView) -> UInt32 {
  let mut crc = 0xFFFFFFFFU
  for byte in data {
    crc = crc ^ byte.to_uint()
    for _index in 0..<8 {
      let low_bit = crc & 1U
      if low_bit != 0U {
        crc = (crc >> 1) ^ 0x82F63B78U
      } else {
        crc = crc >> 1
      }
    }
  }
  crc ^ 0xFFFFFFFFU
}

///|
fn read_uint16_be(
  data : BytesView,
  offset : Int32,
) -> Result[UInt16, MetadataFault] {
  if offset + 2 > data.length() {
    return Err(Malformed)
  }
  Ok(((data[offset].to_uint() << 8) | data[offset + 1].to_uint()).to_uint16())
}

///|
fn read_uint_be(
  data : BytesView,
  offset : Int32,
) -> Result[UInt32, MetadataFault] {
  if offset + 4 > data.length() {
    return Err(Malformed)
  }
  Ok(
    (data[offset].to_uint() << 24) +
    (data[offset + 1].to_uint() << 16) +
    (data[offset + 2].to_uint() << 8) +
    data[offset + 3].to_uint(),
  )
}

///|
fn read_uint64_be(
  data : BytesView,
  offset : Int32,
) -> Result[UInt64, MetadataFault] {
  if offset + 8 > data.length() {
    return Err(Malformed)
  }
  let mut value = 0UL
  for index in 0..<=7 {
    value = (value << 8) | data[offset + index].to_uint64()
  }
  Ok(value)
}

///|
/// Encode a validated header and payload into a CRC-protected MMML record.
///
/// The CRC is calculated here so callers cannot publish a stale checksum;
/// it covers the four length bytes through the end of the payload. Both
/// version bytes must be 1 and the reserved flag bits must be zero, so the
/// encoder can never write bytes the decoder would refuse.
///
/// Returns the complete record bytes: exactly `MMML_HEADER_BYTES +
/// payload.length()` bytes that always decode back to an equal record.
///
/// # Errors
///
/// * `Malformed` -- a version byte is not 1, or the reserved flag bits are
///   nonzero. These are writer-side contract violations, not recoverable
///   input mistakes.
///
/// Example:
///
/// ```mbt check
/// test {
///   let header = @metadata.MmmlHeader::new(
///     format_version=1,
///     header_version=1,
///     flags=0,
///     record_type=@metadata.MmmlRecordType::TopicCreate,
///     leader_epoch=2,
///     mutation_id=7,
///   )
///   assert_eq(@metadata.encode_mmml_record(header, b"ab") is Ok(_), true)
/// }
/// ```
pub fn encode_mmml_record(
  header : MmmlHeader,
  payload : BytesView,
) -> Result[Bytes, MetadataFault] {
  if header.format_version != MMML_FORMAT_VERSION.to_byte() {
    return Err(Malformed)
  }
  if header.header_version != MMML_HEADER_VERSION.to_byte() {
    return Err(Malformed)
  }
  if (header.flags.to_uint() & 0xFFFCU) != 0U {
    return Err(Malformed)
  }
  let buf = Buffer()
  buf.write_uint_be(payload.length().reinterpret_as_uint())
  buf.write_uint16_be(header.record_type.to_uint16())
  buf.write_uint64_be(header.leader_epoch)
  buf.write_uint64_be(header.mutation_id)
  buf.write_bytes(payload)
  let crc_covered = buf.contents()
  let crc = crc32c(crc_covered[:])
  let out = Buffer()
  out.write_bytes(MMML_MAGIC)
  out.write_byte(header.format_version)
  out.write_byte(header.header_version)
  out.write_uint16_be(header.flags)
  out.write_uint_be(crc)
  out.write_bytes(crc_covered)
  Ok(out.contents())
}

///|
/// Decode and validate exactly one complete MMML record.
///
/// The input must be exactly `MMML_HEADER_BYTES + payload_len` bytes
/// carrying the MMML magic, version bytes 1, zero reserved flag bits, a
/// registered record type, a self-consistent length, and a CRC matching
/// everything after the stored CRC field. Truncated, extended, foreign,
/// unregistered, or corrupted byte streams are rejected as malformed rather
/// than decoded to a guess.
///
/// # Errors
///
/// * `Malformed` -- any structural or content check fails at the trust
///   boundary: bad magic, unknown version, nonzero reserved flag bits, an
///   unregistered record type, a length that does not match the input
///   extent, or a CRC mismatch.
///
/// Example:
///
/// ```mbt check
/// test {
///   let header = @metadata.MmmlHeader::new(
///     format_version=1,
///     header_version=1,
///     flags=0,
///     record_type=@metadata.MmmlRecordType::TopicCreate,
///     leader_epoch=2,
///     mutation_id=7,
///   )
///   let bytes = match @metadata.encode_mmml_record(header, b"ab") {
///     Ok(record) => record
///     Err(_) => fail("encoding failed")
///   }
///   assert_eq(
///     @metadata.decode_mmml_record(bytes[:]),
///     Ok({ header, payload: b"ab", }),
///   )
/// }
/// ```
pub fn decode_mmml_record(
  data : BytesView,
) -> Result[MmmlRecord, MetadataFault] {
  if data.length() < MMML_HEADER_BYTES {
    return Err(Malformed)
  }
  for index in 0..<4 {
    if data[index] != MMML_MAGIC[index] {
      return Err(Malformed)
    }
  }
  let format_version = data[4]
  if format_version != MMML_FORMAT_VERSION.to_byte() {
    return Err(Malformed)
  }
  let header_version = data[5]
  if header_version != MMML_HEADER_VERSION.to_byte() {
    return Err(Malformed)
  }
  let flags = match read_uint16_be(data, 6) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if (flags.to_uint() & 0xFFFCU) != 0U {
    return Err(Malformed)
  }
  let stored_crc = match read_uint_be(data, 8) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let payload_len = match read_uint_be(data, 12) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if payload_len != (data.length() - MMML_HEADER_BYTES).reinterpret_as_uint() {
    return Err(Malformed)
  }
  let record_type = match read_uint16_be(data, 16) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let record_type = match MmmlRecordType::from_uint16(record_type) {
    Some(value) => value
    None => return Err(Malformed)
  }
  let leader_epoch = match read_uint64_be(data, 18) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let mutation_id = match read_uint64_be(data, 26) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let crc_data = data[12:]
  if stored_crc != crc32c(crc_data) {
    return Err(Malformed)
  }
  Ok({
    header: {
      format_version,
      header_version,
      flags,
      record_type,
      leader_epoch,
      mutation_id,
    },
    payload: data[MMML_HEADER_BYTES:].to_owned(),
  })
}

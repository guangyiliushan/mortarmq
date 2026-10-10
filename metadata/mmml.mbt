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
pub const MMML_HEADER_BYTES : Int = 34

///|
/// Current frozen MMML format and header layout versions.
pub const MMML_FORMAT_VERSION : Int = 1

///|

///|
pub const MMML_HEADER_VERSION : Int = 1

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
  Corruption(UInt)
  /// Wrap a disk fault raised while reading or publishing metadata state;
  /// recovery fails closed instead of guessing over durable state it cannot
  /// read.
  DiskFault(@harness.HarnessFault)
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
///   assert_eq(@metadata.MmmlRecordType::TopicCreate.toUint16(), 0x0001)
///   assert_eq(@metadata.MmmlRecordType::UnknownFallback.toUint16(), 0xFFFE)
/// }
/// ```
pub fn MmmlRecordType::toUint16(self : MmmlRecordType) -> UInt16 {
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
///     @metadata.MmmlRecordType::fromUint16(0x0050),
///     Some(@metadata.MmmlRecordType::SnapshotHint),
///   )
///   assert_eq(@metadata.MmmlRecordType::fromUint16(0x1234), None)
/// }
/// ```
pub fn MmmlRecordType::fromUint16(code : UInt16) -> MmmlRecordType? {
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
  formatVersion : Byte
  headerVersion : Byte
  flags : UInt16
  recordType : MmmlRecordType
  leaderEpoch : UInt64
  mutationId : UInt64
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
  formatVersion~ : Byte,
  headerVersion~ : Byte,
  flags~ : UInt16,
  recordType~ : MmmlRecordType,
  leaderEpoch~ : UInt64,
  mutationId~ : UInt64,
) -> MmmlHeader {
  { formatVersion, headerVersion, flags, recordType, leaderEpoch, mutationId, }
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
fn crc32c(data : BytesView) -> UInt {
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
fn readUint16Be(
  data : BytesView,
  offset : Int,
) -> Result[UInt16, MetadataFault] {
  if offset + 2 > data.length() {
    return Err(Malformed)
  }
  Ok(((data[offset].to_uint() << 8) | data[offset + 1].to_uint()).to_uint16())
}

///|
fn readUintBe(data : BytesView, offset : Int) -> Result[UInt, MetadataFault] {
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
fn readUint64Be(
  data : BytesView,
  offset : Int,
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
///     formatVersion=1,
///     headerVersion=1,
///     flags=0,
///     recordType=@metadata.MmmlRecordType::TopicCreate,
///     leaderEpoch=2,
///     mutationId=7,
///   )
///   assert_eq(@metadata.encodeMmmlRecord(header, b"ab") is Ok(_), true)
/// }
/// ```
pub fn encodeMmmlRecord(
  header : MmmlHeader,
  payload : BytesView,
) -> Result[Bytes, MetadataFault] {
  if header.formatVersion != MMML_FORMAT_VERSION.to_byte() {
    return Err(Malformed)
  }
  if header.headerVersion != MMML_HEADER_VERSION.to_byte() {
    return Err(Malformed)
  }
  if (header.flags.to_uint() & 0xFFFCU) != 0U {
    return Err(Malformed)
  }
  let buf = Buffer()
  buf.write_uint_be(payload.length().reinterpret_as_uint())
  buf.write_uint16_be(header.recordType.toUint16())
  buf.write_uint64_be(header.leaderEpoch)
  buf.write_uint64_be(header.mutationId)
  buf.write_bytes(payload)
  let crcCovered = buf.contents()
  let crc = crc32c(crcCovered[:])
  let out = Buffer()
  out.write_bytes(MMML_MAGIC)
  out.write_byte(header.formatVersion)
  out.write_byte(header.headerVersion)
  out.write_uint16_be(header.flags)
  out.write_uint_be(crc)
  out.write_bytes(crcCovered)
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
///     formatVersion=1,
///     headerVersion=1,
///     flags=0,
///     recordType=@metadata.MmmlRecordType::TopicCreate,
///     leaderEpoch=2,
///     mutationId=7,
///   )
///   let bytes = match @metadata.encodeMmmlRecord(header, b"ab") {
///     Ok(record) => record
///     Err(_) => fail("encoding failed")
///   }
///   assert_eq(
///     @metadata.decodeMmmlRecord(bytes[:]),
///     Ok({ header, payload: b"ab", }),
///   )
/// }
/// ```
pub fn decodeMmmlRecord(data : BytesView) -> Result[MmmlRecord, MetadataFault] {
  if data.length() < MMML_HEADER_BYTES {
    return Err(Malformed)
  }
  for index in 0..<4 {
    if data[index] != MMML_MAGIC[index] {
      return Err(Malformed)
    }
  }
  let formatVersion = data[4]
  if formatVersion != MMML_FORMAT_VERSION.to_byte() {
    return Err(Malformed)
  }
  let headerVersion = data[5]
  if headerVersion != MMML_HEADER_VERSION.to_byte() {
    return Err(Malformed)
  }
  let flags = match readUint16Be(data, 6) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if (flags.to_uint() & 0xFFFCU) != 0U {
    return Err(Malformed)
  }
  let storedCrc = match readUintBe(data, 8) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let payloadLen = match readUintBe(data, 12) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if payloadLen != (data.length() - MMML_HEADER_BYTES).reinterpret_as_uint() {
    return Err(Malformed)
  }
  let recordType = match readUint16Be(data, 16) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let recordType = match MmmlRecordType::fromUint16(recordType) {
    Some(value) => value
    None => return Err(Malformed)
  }
  let leaderEpoch = match readUint64Be(data, 18) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let mutationId = match readUint64Be(data, 26) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let crc_data = data[12:]
  if storedCrc != crc32c(crc_data) {
    return Err(Malformed)
  }
  Ok({
    header: {
      formatVersion,
      headerVersion,
      flags,
      recordType,
      leaderEpoch,
      mutationId,
    },
    payload: data[MMML_HEADER_BYTES:].to_owned(),
  })
}

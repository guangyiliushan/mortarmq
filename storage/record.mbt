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
/// `record_len` and `record_crc32c` are derived by the write path and are not
/// part of the in-memory DTO.
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
} derive(Eq, Debug)

///|
pub extend RecordHeader with Eq::{not_equal, equal}

///|
pub extend RecordHeader with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn header_uint16(
  data : BytesView,
  offset : Int,
) -> Result[UInt16, StorageFault] {
  if offset + 2 > data.length() {
    return Err(Malformed)
  }
  Ok(((data[offset].to_uint() << 8) | data[offset + 1].to_uint()).to_uint16())
}

///|
fn header_uint(data : BytesView, offset : Int) -> Result[UInt, StorageFault] {
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
fn header_uint64(
  data : BytesView,
  offset : Int,
) -> Result[UInt64, StorageFault] {
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
/// Validate segment magic and both v0 header-version bytes.
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
/// Compute CRC32C over every byte after the stored CRC field.

///|
fn record_suffix(
  header : RecordHeader,
  key : BytesView,
  value : BytesView,
) -> Bytes {
  let buf = Buffer()
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
/// Decode and validate the fixed fields of a complete v0 record.
///
/// The input must contain exactly `4 + record_len` bytes. Length consistency,
/// protocol value bounds, reserved bits, reserved bytes, and CRC are checked at
/// this trust boundary.
pub fn decode_record_header(
  data : BytesView,
) -> Result[RecordHeader, StorageFault] {
  if data.length() < RECORD_HEADER_BYTES {
    return Err(Malformed)
  }
  let record_length = match header_uint(data, 0) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let stored_crc32c = match header_uint(data, 4) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let flags = match header_uint16(data, 8) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let key_length = match header_uint16(data, 10) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let value_length = match header_uint(data, 12) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let sequence = match header_uint64(data, 16) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let producer_id = match header_uint64(data, 24) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let producer_seq = match header_uint64(data, 32) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let timestamp_unix_ms = match header_uint64(data, 40) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let leader_epoch = match header_uint(data, 48) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let replication_flags = data[52]
  if replication_flags > 3 {
    return Err(Malformed)
  }
  if data[53] != 0 || data[54] != 0 || data[55] != 0 {
    return Err(Malformed)
  }
  if record_length != 52U + key_length.to_uint() + value_length {
    return Err(Malformed)
  }
  if value_length > MAX_RECORD_VALUE_BYTES {
    return Err(Malformed)
  }
  let key_present = (flags.to_uint() & 1U) != 0U
  if key_present != (key_length.to_int() > 0) {
    return Err(Malformed)
  }
  let reserved_flag_bits = flags.to_uint() & 0xFFFCU
  if reserved_flag_bits != 0U {
    return Err(Malformed)
  }
  if data.length() != 4 + record_length.reinterpret_as_int() {
    return Err(Malformed)
  }
  let crc_data = data[8:4 + record_length.reinterpret_as_int()]
  if stored_crc32c != crc32c(crc_data) {
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
  })
}

///|
/// Encode a validated header, key, and value into a CRC-protected record.
///
/// The CRC is calculated here so callers cannot publish a stale checksum.
/// `flags` bit0 must agree with key presence; bits1 is tombstone and bits2+ are
/// reserved. The replication kind must be 0-3.
pub fn encode_record_header(
  header : RecordHeader,
  key : BytesView,
  value : BytesView,
) -> Result[Bytes, StorageFault] {
  if header.key_length.to_int() != key.length() {
    return Err(Malformed)
  }
  if header.value_length != value.length().reinterpret_as_uint() {
    return Err(Malformed)
  }
  if header.value_length > MAX_RECORD_VALUE_BYTES {
    return Err(Malformed)
  }
  let key_present_bit = header.flags.to_uint() & 1U
  let key_present = key_present_bit != 0U
  if key_present != (key.length() > 0) {
    return Err(Malformed)
  }
  let reserved_flag_bits = header.flags.to_uint() & 0xFFFCU
  if reserved_flag_bits != 0U {
    return Err(Malformed)
  }
  if header.replication_flags > 3 {
    return Err(Malformed)
  }
  let suffix = record_suffix(header, key, value)
  let crc = crc32c(suffix)
  let buf = Buffer()
  let record_length = 52 + key.length() + value.length()
  buf.write_uint_be(record_length.reinterpret_as_uint())
  buf.write_uint_be(crc)
  buf.write_bytes(suffix)
  Ok(buf.contents())
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
  }
}

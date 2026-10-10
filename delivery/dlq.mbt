/// The frozen v0 MMDL dead-letter envelope and the DLQ flow's pure pieces
/// (WP-04.04, REQ-DEL-002).
///
/// A DLQ record's value is always an envelope, never the bare original:
/// `magic "MMDL" || format_ver:u8 || header_ver:u8 || reason:u8 ||
/// source_topic_id:u16be || source_partition:u16be || source_sequence:u64be ||
/// source_producer_id:u64be || source_producer_seq:u64be ||
/// consumer_group_id:u16be || attempt:u16be || failed_unix_ms:u64be ||
/// death_path_len:u8 || death_path[len]{topic:u16be, partition:u16be,
/// group:u16be} || original_key_len:u16be || original_key ||
/// original_value_len:u32be || original_value || crc32c:u32be`. CRC32C
/// covers every byte before the trailer. Field order and widths are part of
/// the v0 on-disk contract and never change in place; both version bytes are
/// frozen at 1. `death_path` is the cycle-detection vector (v0 length is
/// usually 1; a DLX chain in v2 grows it).
///
/// When a dead-letter candidate's value is itself an envelope (a manually
/// replayed DLQ message), the flow flattens it: the new envelope carries the
/// inner original key/value and the inner death_path extended by one hop, so
/// envelopes never nest and the loop guards see the full history.

///|
const MMDL_MAGIC : Bytes = b"MMDL"

///|
const MMDL_FORMAT_VER : Byte = 0x01

///|
const MMDL_HEADER_VER : Byte = 0x01

///|
/// One `(topic_id, partition, group_id)` hop of the death path.
pub(all) struct DlqHop {
  topic_id : UInt16
  partition : UInt16
  group_id : UInt16
} derive(Eq, Debug)

///|
pub extend DlqHop with Eq::{not_equal, equal}

///|
pub extend DlqHop with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn DlqHop::new(
  topic_id~ : UInt16,
  partition~ : UInt16,
  group_id~ : UInt16,
) -> DlqHop {
  { topic_id, partition, group_id, }
}

///|
/// The message record a dead-letter wraps: its producer coordinates and the
/// original key/value bytes as delivered.
pub(all) struct DeadLetterSource {
  producer_id : UInt64
  producer_seq : UInt64
  key : Bytes
  value : Bytes
} derive(Eq, Debug)

///|
pub extend DeadLetterSource with Eq::{not_equal, equal}

///|
pub extend DeadLetterSource with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The decoded envelope. The death path is ordered oldest hop first.
pub(all) struct MmdlEnvelope {
  reason : NackReason
  source_topic_id : UInt16
  source_partition : UInt16
  source_sequence : UInt64
  source_producer_id : UInt64
  source_producer_seq : UInt64
  consumer_group_id : UInt16
  attempt : UInt16
  failed_unix_ms : UInt64
  death_path : Array[DlqHop]
  original_key : Bytes
  original_value : Bytes
}

///|
pub fn MmdlEnvelope::new(
  reason~ : NackReason,
  source_topic_id~ : UInt16,
  source_partition~ : UInt16,
  source_sequence~ : UInt64,
  source_producer_id~ : UInt64,
  source_producer_seq~ : UInt64,
  consumer_group_id~ : UInt16,
  attempt~ : UInt16,
  failed_unix_ms~ : UInt64,
  death_path~ : Array[DlqHop],
  original_key~ : Bytes,
  original_value~ : Bytes,
) -> MmdlEnvelope {
  {
    reason,
    source_topic_id,
    source_partition,
    source_sequence,
    source_producer_id,
    source_producer_seq,
    consumer_group_id,
    attempt,
    failed_unix_ms,
    death_path,
    original_key,
    original_value,
  }
}

///|
/// Report whether a delivered value is an envelope (magic probe only; a
/// value that fails to decode later is treated as a raw payload).
pub fn is_mmdl(value : BytesView) -> Bool {
  if value.length() < 4 {
    return false
  }
  for index in 0..<4 {
    if value[index] != MMDL_MAGIC[index] {
      return false
    }
  }
  true
}

///|
/// Encode one envelope into its frozen variable-length layout.
pub fn encode_mmdl(envelope : MmdlEnvelope) -> Result[Bytes, DeliveryError] {
  if envelope.death_path.length() > 255 {
    return Err(Malformed)
  }
  if envelope.original_key.length() > 0xFFFF {
    return Err(Malformed)
  }
  let buf = Buffer()
  buf.write_bytes(MMDL_MAGIC)
  buf.write_byte(MMDL_FORMAT_VER)
  buf.write_byte(MMDL_HEADER_VER)
  buf.write_byte(reason_code(envelope.reason))
  buf.write_uint16_be(envelope.source_topic_id)
  buf.write_uint16_be(envelope.source_partition)
  buf.write_uint64_be(envelope.source_sequence)
  buf.write_uint64_be(envelope.source_producer_id)
  buf.write_uint64_be(envelope.source_producer_seq)
  buf.write_uint16_be(envelope.consumer_group_id)
  buf.write_uint16_be(envelope.attempt)
  buf.write_uint64_be(envelope.failed_unix_ms)
  buf.write_byte(envelope.death_path.length().to_byte())
  for hop in envelope.death_path {
    buf.write_uint16_be(hop.topic_id)
    buf.write_uint16_be(hop.partition)
    buf.write_uint16_be(hop.group_id)
  }
  buf.write_uint16_be(envelope.original_key.length().to_uint16())
  buf.write_bytes(envelope.original_key)
  buf.write_uint_be(envelope.original_value.length().reinterpret_as_uint())
  buf.write_bytes(envelope.original_value)
  let payload = buf.contents()
  let out = Buffer()
  out.write_bytes(payload)
  out.write_uint_be(crc32c(payload[:]))
  Ok(out.contents())
}

///|
/// Decode one complete envelope; rejects foreign magic, unknown version or
/// reason bytes, inconsistent lengths, and CRC mismatches at this trust
/// boundary.
pub fn decode_mmdl(data : BytesView) -> Result[MmdlEnvelope, DeliveryError] {
  if data.length() < 48 + 4 {
    return Err(Malformed)
  }
  for index in 0..<4 {
    if data[index] != MMDL_MAGIC[index] {
      return Err(Malformed)
    }
  }
  if data[4] != MMDL_FORMAT_VER || data[5] != MMDL_HEADER_VER {
    return Err(Malformed)
  }
  let total = data.length()
  let stored_crc = match read_uint32_be(data, total - 4) {
    Ok(value) => value
    Err(_) => return Err(Malformed)
  }
  if stored_crc != crc32c(data[0:total - 4]) {
    return Err(Malformed)
  }
  let reason = match reason_kind(data[6]) {
    Ok(value) => value
    Err(_) => return Err(Malformed)
  }
  let source_topic_id = match read_uint16_be(data, 7) {
    Ok(value) => value
    Err(_) => return Err(Malformed)
  }
  let source_partition = match read_uint16_be(data, 9) {
    Ok(value) => value
    Err(_) => return Err(Malformed)
  }
  let source_sequence = match read_uint64_be(data, 11) {
    Ok(value) => value
    Err(_) => return Err(Malformed)
  }
  let source_producer_id = match read_uint64_be(data, 19) {
    Ok(value) => value
    Err(_) => return Err(Malformed)
  }
  let source_producer_seq = match read_uint64_be(data, 27) {
    Ok(value) => value
    Err(_) => return Err(Malformed)
  }
  let consumer_group_id = match read_uint16_be(data, 35) {
    Ok(value) => value
    Err(_) => return Err(Malformed)
  }
  let attempt = match read_uint16_be(data, 37) {
    Ok(value) => value
    Err(_) => return Err(Malformed)
  }
  let failed_unix_ms = match read_uint64_be(data, 39) {
    Ok(value) => value
    Err(_) => return Err(Malformed)
  }
  let death_path_len = data[47].to_int()
  let mut offset = 48
  let death_path : Array[DlqHop] = []
  for _ in 0..<death_path_len {
    if offset + 6 > total - 4 {
      return Err(Malformed)
    }
    let topic_id = match read_uint16_be(data, offset) {
      Ok(value) => value
      Err(_) => return Err(Malformed)
    }
    let partition = match read_uint16_be(data, offset + 2) {
      Ok(value) => value
      Err(_) => return Err(Malformed)
    }
    let group_id = match read_uint16_be(data, offset + 4) {
      Ok(value) => value
      Err(_) => return Err(Malformed)
    }
    death_path.push({ topic_id, partition, group_id, })
    offset = offset + 6
  }
  if offset + 2 > total - 4 {
    return Err(Malformed)
  }
  let key_len = match read_uint16_be(data, offset) {
    Ok(value) => value.to_int()
    Err(_) => return Err(Malformed)
  }
  offset = offset + 2
  if offset + key_len + 4 > total - 4 {
    return Err(Malformed)
  }
  let original_key = data[offset:offset + key_len].to_owned()
  offset = offset + key_len
  let value_len = match read_uint32_be(data, offset) {
    Ok(value) => value.reinterpret_as_int()
    Err(_) => return Err(Malformed)
  }
  offset = offset + 4
  if offset + value_len != total - 4 {
    return Err(Malformed)
  }
  let original_value = data[offset:offset + value_len].to_owned()
  Ok({
    reason,
    source_topic_id,
    source_partition,
    source_sequence,
    source_producer_id,
    source_producer_seq,
    consumer_group_id,
    attempt,
    failed_unix_ms,
    death_path,
    original_key,
    original_value,
  })
}

/// The frozen v0 delivery-ledger event log (`delivery.mql`).
///
/// One event is exactly 52 bytes: `magic "MMLQ" || format_ver:u8 ||
/// header_ver:u8 || group_id:u16be || event:u8 || sequence:u64be ||
/// delivery_id:u64be || owner_conn:u64be || attempt:u16be || delay_ms:u32be ||
/// reason:u8 || timestamp:u64be || crc32c:u32be`. CRC32C covers the leading
/// 48 bytes. Field order and widths are part of the v0 on-disk contract and
/// never change in place; both version bytes are frozen at 1.
///
/// The ledger stream never shares a file with message records: the writer
/// only targets `delivery.mql` paths while the record side keeps its own
/// `MMQS` segments, and each format's decoder rejects the other's magic.

///|
const LEDGER_MAGIC : Bytes = b"MMLQ"

///|
/// Frozen ledger file name; the per-group checkpoint uses `delivery.mqc`.
pub const LEDGER_FILE_NAME : Bytes = b"delivery.mql"

///|
/// Exact encoded size of one ledger event.
pub const LEDGER_EVENT_BYTES : Int = 52

///|
const LEDGER_FORMAT_VER : Byte = 0x01

///|
const LEDGER_HEADER_VER : Byte = 0x01

///|
const LEDGER_CRC_OFFSET : Int = 48

///|
/// Count of events that triggers a group commit; the 5ms timer half of the
/// frozen "5ms or 128 events" rule is wired with the executor (T028).
const GROUP_COMMIT_EVENTS : Int = 128

///|
/// Report delivery-ledger failures without leaking an OS error.
///
/// `Capacity` is a Q18 watermark-gate rejection (maps to 0x4004 upstream);
/// a hard IO failure arrives as `DiskFault` and follows a different path.
pub(all) suberror LedgerFault {
  Malformed
  Capacity
  DiskFault(@harness.HarnessFault)
} derive(Eq, Debug)

///|
pub extend LedgerFault with Eq::{not_equal, equal}

///|
pub extend LedgerFault with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Frozen v0 event codes 1..9. Unknown codes are malformed input.
pub(all) enum LedgerEventKind {
  Deliver
  Ack
  NackRetry
  NackTerminal
  Timeout
  SendFailed
  DlqWritten
  SourceTerminated
  Fenced
} derive(Eq, Debug)

///|
pub extend LedgerEventKind with Eq::{not_equal, equal}

///|
pub extend LedgerEventKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Frozen v0 NACK reasons 0..3. `Slow` is a v0.1 extension kept in the format
/// range; non-NACK event kinds carry `Retry` (0) as their zero value.
pub(all) enum NackReason {
  Retry
  Terminal
  Poison
  Slow
} derive(Eq, Debug)

///|
pub extend NackReason with Eq::{not_equal, equal}

///|
pub extend NackReason with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One delivery-ledger event. Fields a kind does not carry are zeroed by the
/// caller; the codec stays state-machine neutral.
pub(all) struct LedgerEvent {
  group_id : UInt16
  event : LedgerEventKind
  sequence : UInt64
  delivery_id : UInt64
  owner_conn : UInt64
  attempt : UInt16
  delay_ms : UInt
  reason : NackReason
  timestamp : UInt64
} derive(Eq, Debug)

///|
pub extend LedgerEvent with Eq::{not_equal, equal}

///|
pub extend LedgerEvent with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn LedgerEvent::new(
  group_id~ : UInt16,
  event~ : LedgerEventKind,
  sequence~ : UInt64,
  delivery_id~ : UInt64,
  owner_conn~ : UInt64,
  attempt~ : UInt16,
  delay_ms~ : UInt,
  reason~ : NackReason,
  timestamp~ : UInt64,
) -> LedgerEvent {
  {
    group_id,
    event,
    sequence,
    delivery_id,
    owner_conn,
    attempt,
    delay_ms,
    reason,
    timestamp,
  }
}

///|
fn event_code(kind : LedgerEventKind) -> Byte {
  match kind {
    Deliver => 1
    Ack => 2
    NackRetry => 3
    NackTerminal => 4
    Timeout => 5
    SendFailed => 6
    DlqWritten => 7
    SourceTerminated => 8
    Fenced => 9
  }
}

///|
fn event_kind(code : Byte) -> Result[LedgerEventKind, LedgerFault] {
  match code {
    1 => Ok(Deliver)
    2 => Ok(Ack)
    3 => Ok(NackRetry)
    4 => Ok(NackTerminal)
    5 => Ok(Timeout)
    6 => Ok(SendFailed)
    7 => Ok(DlqWritten)
    8 => Ok(SourceTerminated)
    9 => Ok(Fenced)
    _ => Err(Malformed)
  }
}

///|
fn reason_code(reason : NackReason) -> Byte {
  match reason {
    NackReason::Retry => 0
    NackReason::Terminal => 1
    NackReason::Poison => 2
    NackReason::Slow => 3
  }
}

///|
fn reason_kind(code : Byte) -> Result[NackReason, LedgerFault] {
  match code {
    0 => Ok(NackReason::Retry)
    1 => Ok(NackReason::Terminal)
    2 => Ok(NackReason::Poison)
    3 => Ok(NackReason::Slow)
    _ => Err(Malformed)
  }
}

///|
// ponytail: bit-by-bit CRC is correct but O(8n); table/native CRC when measured ledger throughput needs it.
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
fn read_uint16_be(
  data : BytesView,
  offset : Int,
) -> Result[UInt16, LedgerFault] {
  if offset + 2 > data.length() {
    return Err(Malformed)
  }
  Ok(((data[offset].to_uint() << 8) | data[offset + 1].to_uint()).to_uint16())
}

///|
fn read_uint32_be(data : BytesView, offset : Int) -> Result[UInt, LedgerFault] {
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
  offset : Int,
) -> Result[UInt64, LedgerFault] {
  if offset + 8 > data.length() {
    return Err(Malformed)
  }
  let mut value = 0UL
  for index in 0..<8 {
    value = (value << 8) | data[offset + index].to_uint64()
  }
  Ok(value)
}

///|
/// Encode one event as its frozen 52-byte on-disk layout.
pub fn encode_ledger_event(event : LedgerEvent) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(LEDGER_MAGIC)
  buf.write_byte(LEDGER_FORMAT_VER)
  buf.write_byte(LEDGER_HEADER_VER)
  buf.write_uint16_be(event.group_id)
  buf.write_byte(event_code(event.event))
  buf.write_uint64_be(event.sequence)
  buf.write_uint64_be(event.delivery_id)
  buf.write_uint64_be(event.owner_conn)
  buf.write_uint16_be(event.attempt)
  buf.write_uint_be(event.delay_ms)
  buf.write_byte(reason_code(event.reason))
  buf.write_uint64_be(event.timestamp)
  let payload = buf.contents()
  let crc = crc32c(payload[:])
  let out = Buffer()
  out.write_bytes(payload)
  out.write_uint_be(crc)
  out.contents()
}

///|
/// Decode one complete event; rejects short views, foreign magic, unknown
/// version or code bytes, and CRC mismatches at this trust boundary.
pub fn decode_ledger_event(
  data : BytesView,
) -> Result[LedgerEvent, LedgerFault] {
  if data.length() != LEDGER_EVENT_BYTES {
    return Err(Malformed)
  }
  for index in 0..<4 {
    if data[index] != LEDGER_MAGIC[index] {
      return Err(Malformed)
    }
  }
  if data[4] != LEDGER_FORMAT_VER || data[5] != LEDGER_HEADER_VER {
    return Err(Malformed)
  }
  let stored_crc = match read_uint32_be(data, LEDGER_CRC_OFFSET) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if stored_crc != crc32c(data[0:LEDGER_CRC_OFFSET]) {
    return Err(Malformed)
  }
  let group_id = match read_uint16_be(data, 6) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let event = match event_kind(data[8]) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let sequence = match read_uint64_be(data, 9) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let delivery_id = match read_uint64_be(data, 17) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let owner_conn = match read_uint64_be(data, 25) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let attempt = match read_uint16_be(data, 33) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let delay_ms = match read_uint32_be(data, 35) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let reason = match reason_kind(data[39]) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let timestamp = match read_uint64_be(data, 40) {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  Ok({
    group_id,
    event,
    sequence,
    delivery_id,
    owner_conn,
    attempt,
    delay_ms,
    reason,
    timestamp,
  })
}

///|
/// A path is a ledger stream only when it ends in the frozen file name; the
/// writer refuses anything else so a ledger append can never land on a record
/// segment.
fn is_ledger_path(path : Bytes) -> Bool {
  let name_len = LEDGER_FILE_NAME.length()
  if path.length() < name_len {
    return false
  }
  let start = path.length() - name_len
  for index in 0..<name_len {
    if path[start + index] != LEDGER_FILE_NAME[index] {
      return false
    }
  }
  true
}

///|
/// Append-only writer for one `delivery.mql` stream.
///
/// The frozen v0 write path is read-modify-write over `Disk::write`; a host
/// adapter may later switch to true append IO behind the same seam. Each
/// `append` runs the caller-supplied Q18 capacity-gate check first
/// (`Watermark::check_append` at wiring), then writes, then group-syncs every
/// 128 events; `sync` forces the fsync early.
pub(all) struct LedgerWriter {
  priv path : Bytes
  priv mut unflushed_events : Int
}

///|
pub fn LedgerWriter::new(path : Bytes) -> Result[LedgerWriter, LedgerFault] {
  if !is_ledger_path(path) {
    return Err(Malformed)
  }
  Ok({ path, unflushed_events: 0, })
}

///|
pub fn LedgerWriter::path(self : LedgerWriter) -> Bytes {
  self.path
}

///|
pub fn LedgerWriter::unflushed_events(self : LedgerWriter) -> Int {
  self.unflushed_events
}

///|
/// Append one event: capacity gate, then read-modify-write, then a group
/// commit once the frozen 128-event threshold is reached.
pub async fn[D : @harness.Disk] LedgerWriter::append(
  self : LedgerWriter,
  disk : D,
  event : LedgerEvent,
  precheck : (Int) -> Result[Unit, LedgerFault],
) -> Result[Unit, LedgerFault] {
  match precheck(LEDGER_EVENT_BYTES) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  let existing = match disk.read(self.path) {
    Ok(data) => data
    Err(@harness.PathMissing) => b""
    Err(other) => return Err(DiskFault(other))
  }
  if existing.length() % LEDGER_EVENT_BYTES != 0 {
    return Err(Malformed)
  }
  let next = existing + encode_ledger_event(event)
  match disk.write(self.path, next) {
    Ok(_) => ()
    Err(code) => return Err(DiskFault(code))
  }
  self.unflushed_events = self.unflushed_events + 1
  if self.unflushed_events >= GROUP_COMMIT_EVENTS {
    match self.sync(disk) {
      Ok(_) => ()
      Err(code) => return Err(code)
    }
  }
  Ok(())
}

///|
/// Force the group commit now.
pub async fn[D : @harness.Disk] LedgerWriter::sync(
  self : LedgerWriter,
  disk : D,
) -> Result[Unit, LedgerFault] {
  if self.unflushed_events == 0 {
    return Ok(())
  }
  match disk.fsync(self.path) {
    Ok(_) => ()
    Err(code) => return Err(DiskFault(code))
  }
  self.unflushed_events = 0
  Ok(())
}

///|
/// Scan a ledger stream and return every event up to the first torn or
/// invalid tail chunk. Recovery-time tail truncation is T032; here a bad
/// tail simply ends the valid prefix.
pub async fn[D : @harness.Disk] read_ledger_events(
  disk : D,
  path : Bytes,
) -> Result[Array[LedgerEvent], LedgerFault] {
  let data = match disk.read(path) {
    Ok(data) => data
    Err(code) => return Err(DiskFault(code))
  }
  let events : Array[LedgerEvent] = []
  let mut offset = 0
  while offset + LEDGER_EVENT_BYTES <= data.length() {
    match decode_ledger_event(data[offset:offset + LEDGER_EVENT_BYTES]) {
      Ok(event) => events.push(event)
      Err(_) => break
    }
    offset = offset + LEDGER_EVENT_BYTES
  }
  Ok(events)
}

/// Decode and encode operation payloads for all fifteen v0 operations.
///
/// The decoder owns field-order, fixed-width, bound, trailing-byte, and
/// operation/payload matching checks. Semantic topic syntax, authentication,
/// quota, and replication policy remain with their later subsystems.

///|
/// Carry the token and client capabilities requested by `CONNECT`.
pub(all) struct ConnectPayload {
  protocol_version : Byte
  client_flags : UInt16
  token : Bytes
} derive(Eq, Debug)

///|
/// Carry the topic metadata requested by `DECLARE`.
pub(all) struct DeclarePayload {
  topic : Bytes
  partition_count : UInt16
  flags : UInt16
} derive(Eq, Debug)

///|
/// Carry an idempotent `PUB` value and its producer identity.
pub(all) struct PubPayload {
  topic_id : UInt16
  partition : UInt16
  producer_id : UInt64
  producer_seq : UInt64
  flags : UInt16
  key : Bytes
  value : Bytes
} derive(Eq, Debug)

///|
/// Carry a consumer-group subscription and its initial credit window.
pub(all) struct SubPayload {
  group : Bytes
  topic_id : UInt16
  partition : UInt16
  start_policy : Byte
  credit_count : UInt16
  credit_bytes : UInt
  flags : UInt16
} derive(Eq, Debug)

///|
/// Acknowledge one delivered message.
pub(all) struct AckPayload {
  subscription_id : UInt16
  topic_id : UInt16
  partition : UInt16
  sequence : UInt64
  delivery_id : UInt64
  ownership_epoch : UInt64
  flags : UInt16
} derive(Eq, Debug)

///|
/// Return one delivered message for retry.
pub(all) struct NackPayload {
  subscription_id : UInt16
  topic_id : UInt16
  partition : UInt16
  sequence : UInt64
  delivery_id : UInt64
  ownership_epoch : UInt64
  reason : Byte
  flags : UInt16
} derive(Eq, Debug)

///|
/// Carry a protocol-level diagnostic.
pub(all) struct ErrPayload {
  code : ErrCode
  request_op : Op
  message : Bytes
} derive(Eq, Debug)

///|
/// Carry an opaque operation result in the common `OK` envelope.
pub(all) struct OkPayload {
  request_op : Op
  result : Bytes
} derive(Eq, Debug)

///|
/// Model the request, response, and server-push payload for each operation.
///
/// `Ping` has an empty wire payload. The success results nested inside `OK`
/// (for example `DECLARE`'s topic id) are decoded by their operation-specific
/// result contracts as those contracts enter the broker and client.

///|
/// Deliver one stored message to a subscribed client.
pub(all) struct MsgPayload {
  subscription_id : UInt16
  topic_id : UInt16
  partition : UInt16
  sequence : UInt64
  delivery_id : UInt64
  attempt : UInt16
  ownership_epoch : UInt64
  producer_id : UInt64
  producer_seq : UInt64
  flags : UInt16
  key : Bytes
  value : Bytes
} derive(Eq, Debug)

///|
/// Request available messages for one assigned partition.
pub(all) struct PullPayload {
  subscription_id : UInt16
  member_id : UInt64
  membership_epoch : UInt
  assignment_epoch : UInt
  ownership_epochs : Array[UInt64]
  max_msgs : UInt16
  max_bytes : UInt
  wait_ms : UInt16
  min_bytes : UInt
} derive(Eq, Debug)

///|
/// Report consumer membership liveness or an explicit leave.
pub(all) struct HeartbeatPayload {
  subscription_id : UInt16
  member_id : UInt64
  membership_epoch : UInt
  assignment_epoch : UInt
  state : Byte
} derive(Eq, Debug)

///|
/// Push an assignment or revocation to a consumer member.
pub(all) struct NoticePayload {
  notice_id : UInt64
  kind : Byte
  group_id : UInt16
  membership_epoch : UInt
  assignment_epoch : UInt
  ownership_epoch : UInt64
  topic_id : UInt16
  partition : UInt16
  member_id : UInt64
} derive(Eq, Debug)

///|
/// Acknowledge an assignment or revocation notice.
pub(all) struct ControlAckPayload {
  notice_id : UInt64
  notice_kind : Byte
  group_id : UInt16
  membership_epoch : UInt
  assignment_epoch : UInt
  ownership_epoch : UInt64
  result : Byte
} derive(Eq, Debug)

///|
/// Add or replace a consumer credit window.
pub(all) struct CreditPayload {
  subscription_id : UInt16
  membership_epoch : UInt
  ownership_epoch : UInt64
  mode : Byte
  credit_count : UInt16
  credit_bytes : UInt
} derive(Eq, Debug)

///|
pub(all) enum WirePayload {
  Connect(ConnectPayload)
  Declare(DeclarePayload)
  Pub(PubPayload)
  Sub(SubPayload)
  Ack(AckPayload)
  Nack(NackPayload)
  Ping
  Err(ErrPayload)
  Ok(OkPayload)
  Msg(MsgPayload)
  Pull(PullPayload)
  Heartbeat(HeartbeatPayload)
  Notice(NoticePayload)
  ControlAck(ControlAckPayload)
  Credit(CreditPayload)
} derive(Eq, Debug)

///|
pub extend ConnectPayload with Eq::{not_equal, equal}

///|
pub extend ConnectPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend DeclarePayload with Eq::{not_equal, equal}

///|
pub extend DeclarePayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend PubPayload with Eq::{not_equal, equal}

///|
pub extend PubPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend SubPayload with Eq::{not_equal, equal}

///|
pub extend SubPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend AckPayload with Eq::{not_equal, equal}

///|
pub extend AckPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend NackPayload with Eq::{not_equal, equal}

///|
pub extend NackPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ErrPayload with Eq::{not_equal, equal}

///|
pub extend ErrPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend OkPayload with Eq::{not_equal, equal}

///|
pub extend OkPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend WirePayload with Eq::{not_equal, equal}

///|
pub extend WirePayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend MsgPayload with Eq::{not_equal, equal}

///|
pub extend MsgPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend PullPayload with Eq::{not_equal, equal}

///|
pub extend PullPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend HeartbeatPayload with Eq::{not_equal, equal}

///|
pub extend HeartbeatPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend NoticePayload with Eq::{not_equal, equal}

///|
pub extend NoticePayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend ControlAckPayload with Eq::{not_equal, equal}

///|
pub extend ControlAckPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend CreditPayload with Eq::{not_equal, equal}

///|
pub extend CreditPayload with @moonbitlang/core/debug.Debug::{to_repr}

///|
priv struct Cursor {
  data : BytesView
  mut offset : Int
}

///|
fn Cursor::take(self : Cursor, length : Int) -> Result[BytesView, ErrCode] {
  let remaining = self.data.length() - self.offset
  if length < 0 || length > remaining {
    return Err(MalformedPayload)
  }
  let view = self.data[self.offset:self.offset + length]
  self.offset = self.offset + length
  Ok(view)
}

///|
fn Cursor::byte(self : Cursor) -> Result[Byte, ErrCode] {
  match self.take(1) {
    Ok(data) => Ok(data[0])
    Err(code) => Err(code)
  }
}

///|
fn Cursor::uint16(self : Cursor) -> Result[UInt16, ErrCode] {
  match self.take(2) {
    Ok(data) => Ok(((data[0].to_uint() << 8) | data[1].to_uint()).to_uint16())
    Err(code) => Err(code)
  }
}

///|
fn Cursor::uint(self : Cursor) -> Result[UInt, ErrCode] {
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
fn Cursor::uint64(self : Cursor) -> Result[UInt64, ErrCode] {
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
fn Cursor::finished(self : Cursor) -> Result[Unit, ErrCode] {
  if self.offset == self.data.length() {
    Ok(())
  } else {
    Err(MalformedPayload)
  }
}

///|
fn checked_len(value : BytesView, maximum : Int) -> Result[Int, ErrCode] {
  if value.length() > maximum {
    return Err(MalformedPayload)
  }
  Ok(value.length())
}

///|
fn Cursor::key_value(self : Cursor) -> Result[(Bytes, Bytes), ErrCode] {
  let key_length = match self.uint16() {
    Ok(value) => value.to_int()
    Err(code) => return Err(code)
  }
  if key_length > MAX_KEY_LEN.reinterpret_as_int() {
    return Err(MalformedPayload)
  }
  let key = match self.take(key_length) {
    Ok(value) => value.to_owned()
    Err(code) => return Err(code)
  }
  let value_length = match self.uint() {
    Ok(value) => {
      if value > MAX_VALUE_LEN {
        return Err(MalformedPayload)
      }
      value.reinterpret_as_int()
    }
    Err(code) => return Err(code)
  }
  let value = match self.take(value_length) {
    Ok(value) => value.to_owned()
    Err(code) => return Err(code)
  }
  Ok((key, value))
}

///|
fn decode_connect(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let version = match cursor.byte() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if version.to_uint() != WIRE_VERSION {
    return Err(UnsupportedVersion)
  }
  let client_flags = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let token_length = match cursor.uint16() {
    Ok(value) => value.to_int()
    Err(code) => return Err(code)
  }
  let token = match cursor.take(token_length) {
    Ok(value) => value.to_owned()
    Err(code) => return Err(code)
  }
  let reserved = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if reserved != 0U {
    return Err(MalformedPayload)
  }
  match cursor.finished() {
    Ok(_) => Ok(Connect({ protocol_version: version, client_flags, token, }))
    Err(code) => Err(code)
  }
}

///|
fn decode_declare(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let topic_length = match cursor.uint16() {
    Ok(value) => value.to_int()
    Err(code) => return Err(code)
  }
  if topic_length > MAX_TOPIC_LEN.reinterpret_as_int() {
    return Err(MalformedPayload)
  }
  let topic = match cursor.take(topic_length) {
    Ok(value) => value.to_owned()
    Err(code) => return Err(code)
  }
  let partition_count = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let flags = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  match cursor.finished() {
    Ok(_) => Ok(Declare({ topic, partition_count, flags, }))
    Err(code) => Err(code)
  }
}

///|
fn decode_pub(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let topic_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let partition = match cursor.uint16() {
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
  let flags = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let (key, value) = match cursor.key_value() {
    Ok(pair) => pair
    Err(code) => return Err(code)
  }
  match cursor.finished() {
    Ok(_) =>
      Ok(
        Pub({
          topic_id,
          partition,
          producer_id,
          producer_seq,
          flags,
          key,
          value,
        }),
      )
    Err(code) => Err(code)
  }
}

///|
fn decode_sub(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let group_length = match cursor.uint16() {
    Ok(value) => value.to_int()
    Err(code) => return Err(code)
  }
  let group = match cursor.take(group_length) {
    Ok(value) => value.to_owned()
    Err(code) => return Err(code)
  }
  let topic_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let partition = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if partition.to_uint() != 0xFFFFU {
    return Err(MalformedPayload)
  }
  let start_policy = match cursor.byte() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let credit_count = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let credit_bytes = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let flags = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  match cursor.finished() {
    Ok(_) =>
      Ok(
        Sub({
          group,
          topic_id,
          partition,
          start_policy,
          credit_count,
          credit_bytes,
          flags,
        }),
      )
    Err(code) => Err(code)
  }
}

///|
fn decode_ack(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let subscription_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let topic_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let partition = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let sequence = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let delivery_id = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let ownership_epoch = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let flags = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  match cursor.finished() {
    Ok(_) =>
      Ok(
        Ack({
          subscription_id,
          topic_id,
          partition,
          sequence,
          delivery_id,
          ownership_epoch,
          flags,
        }),
      )
    Err(code) => Err(code)
  }
}

///|
fn decode_nack(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let subscription_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let topic_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let partition = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let sequence = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let delivery_id = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let ownership_epoch = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let reason = match cursor.byte() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let flags = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  match cursor.finished() {
    Ok(_) =>
      Ok(
        Nack({
          subscription_id,
          topic_id,
          partition,
          sequence,
          delivery_id,
          ownership_epoch,
          reason,
          flags,
        }),
      )
    Err(code) => Err(code)
  }
}

///|
fn decode_error(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let code = match cursor.uint16() {
    Ok(value) =>
      match ErrCode::from_u16(value.to_uint()) {
        Some(code) => code
        None => return Err(MalformedPayload)
      }
    Err(code) => return Err(code)
  }
  let request_op_byte = match cursor.byte() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let request_op = match Op::from_byte(request_op_byte) {
    Some(op) => op
    None => return Err(MalformedPayload)
  }
  let message_length = match cursor.uint16() {
    Ok(value) => value.to_int()
    Err(code) => return Err(code)
  }
  if message_length > MAX_ERR_MESSAGE.reinterpret_as_int() {
    return Err(MalformedPayload)
  }
  let message = match cursor.take(message_length) {
    Ok(value) => value.to_owned()
    Err(code) => return Err(code)
  }
  match cursor.finished() {
    Ok(_) => Ok(WirePayload::Err({ code, request_op, message, }))
    Err(code) => Err(code)
  }
}

///|
fn decode_ok(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let request_op_byte = match cursor.byte() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let request_op = match Op::from_byte(request_op_byte) {
    Some(op) => op
    None => return Err(MalformedPayload)
  }
  let result_length = match cursor.uint() {
    Ok(value) => value.reinterpret_as_int()
    Err(code) => return Err(code)
  }
  let result = match cursor.take(result_length) {
    Ok(value) => value.to_owned()
    Err(code) => return Err(code)
  }
  match cursor.finished() {
    Ok(_) => Ok(WirePayload::Ok({ request_op, result, }))
    Err(code) => Err(code)
  }
}

///|
/// Decode one operation payload and reject trailing or unknown bytes.
///
/// The payload must match `op`; semantic validation (topic syntax, producer
/// sequencing, quotas, and authorization) remains in later subsystems.
///
/// # Example
///
/// ```mbt check
/// test {
///   match @protocol.decode_wire_payload(@protocol.Ping, b"") {
///     Ok(@protocol.WirePayload::Ping) => assert_eq(true, true)
///     _ => fail("expected PING")
///   }
/// }
/// ```

///|
fn decode_msg(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let subscription_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let topic_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let partition = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let sequence = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let delivery_id = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let attempt = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let ownership_epoch = match cursor.uint64() {
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
  let flags = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let (key, value) = match cursor.key_value() {
    Ok(pair) => pair
    Err(code) => return Err(code)
  }
  match cursor.finished() {
    Ok(_) =>
      Ok(
        WirePayload::Msg({
          subscription_id,
          topic_id,
          partition,
          sequence,
          delivery_id,
          attempt,
          ownership_epoch,
          producer_id,
          producer_seq,
          flags,
          key,
          value,
        }),
      )
    Err(code) => Err(code)
  }
}

///|
fn decode_pull(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let subscription_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let member_id = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let membership_epoch = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let assignment_epoch = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let epoch_count = match cursor.uint16() {
    Ok(value) => value.to_int()
    Err(code) => return Err(code)
  }
  let ownership_epochs : Array[UInt64] = []
  for _index in 0..<epoch_count {
    let epoch = match cursor.uint64() {
      Ok(value) => value
      Err(code) => return Err(code)
    }
    ownership_epochs.push(epoch)
  }
  let max_msgs = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let max_bytes = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let wait_ms = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let min_bytes = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  match cursor.finished() {
    Ok(_) =>
      Ok(
        WirePayload::Pull({
          subscription_id,
          member_id,
          membership_epoch,
          assignment_epoch,
          ownership_epochs,
          max_msgs,
          max_bytes,
          wait_ms,
          min_bytes,
        }),
      )
    Err(code) => Err(code)
  }
}

///|
fn decode_heartbeat(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let subscription_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let member_id = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let membership_epoch = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let assignment_epoch = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let state = match cursor.byte() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if state.to_uint() > 1U {
    return Err(MalformedPayload)
  }
  match cursor.finished() {
    Ok(_) =>
      Ok(
        WirePayload::Heartbeat({
          subscription_id,
          member_id,
          membership_epoch,
          assignment_epoch,
          state,
        }),
      )
    Err(code) => Err(code)
  }
}

///|
fn decode_notice(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let notice_id = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let kind = match cursor.byte() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if kind.to_uint() > 1U {
    return Err(MalformedPayload)
  }
  let group_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let membership_epoch = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let assignment_epoch = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let ownership_epoch = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let topic_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let partition = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let member_id = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  match cursor.finished() {
    Ok(_) =>
      Ok(
        WirePayload::Notice({
          notice_id,
          kind,
          group_id,
          membership_epoch,
          assignment_epoch,
          ownership_epoch,
          topic_id,
          partition,
          member_id,
        }),
      )
    Err(code) => Err(code)
  }
}

///|
fn decode_control_ack(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let notice_id = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let notice_kind = match cursor.byte() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if notice_kind.to_uint() > 1U {
    return Err(MalformedPayload)
  }
  let group_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let membership_epoch = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let assignment_epoch = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let ownership_epoch = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let result = match cursor.byte() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if result.to_uint() > 2U {
    return Err(MalformedPayload)
  }
  match cursor.finished() {
    Ok(_) =>
      Ok(
        WirePayload::ControlAck({
          notice_id,
          notice_kind,
          group_id,
          membership_epoch,
          assignment_epoch,
          ownership_epoch,
          result,
        }),
      )
    Err(code) => Err(code)
  }
}

///|
fn decode_credit(data : BytesView) -> Result[WirePayload, ErrCode] {
  let cursor = { data, offset: 0, }
  let subscription_id = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let membership_epoch = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let ownership_epoch = match cursor.uint64() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let mode = match cursor.byte() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if mode.to_uint() > 1U {
    return Err(MalformedPayload)
  }
  let credit_count = match cursor.uint16() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let credit_bytes = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  let reserved = match cursor.uint() {
    Ok(value) => value
    Err(code) => return Err(code)
  }
  if reserved != 0U {
    return Err(MalformedPayload)
  }
  match cursor.finished() {
    Ok(_) =>
      Ok(
        WirePayload::Credit({
          subscription_id,
          membership_epoch,
          ownership_epoch,
          mode,
          credit_count,
          credit_bytes,
        }),
      )
    Err(code) => Err(code)
  }
}

///|
pub fn decode_wire_payload(
  op : Op,
  data : BytesView,
) -> Result[WirePayload, ErrCode] {
  match op {
    Op::Connect => decode_connect(data)
    Op::Declare => decode_declare(data)
    Op::Pub => decode_pub(data)
    Op::Sub => decode_sub(data)
    Op::Ack => decode_ack(data)
    Op::Nack => decode_nack(data)
    Op::Ping =>
      if data.is_empty() {
        Ok(WirePayload::Ping)
      } else {
        Err(MalformedPayload)
      }
    Op::Err => decode_error(data)
    Op::Ok => decode_ok(data)
    Op::Msg => decode_msg(data)
    Op::Pull => decode_pull(data)
    Op::Heartbeat => decode_heartbeat(data)
    Op::Notice => decode_notice(data)
    Op::ControlAck => decode_control_ack(data)
    Op::Credit => decode_credit(data)
  }
}

///|
fn write_field(
  buf : Buffer,
  value : BytesView,
  maximum : Int,
) -> Result[Unit, ErrCode] {
  match checked_len(value, maximum) {
    Ok(length) => {
      buf.write_uint16_be(length.to_uint16())
      buf.write_bytes(value)
      Ok(())
    }
    Err(code) => Err(code)
  }
}

///|
fn write_fixed_field(buf : Buffer, value : BytesView) -> Unit {
  buf.write_uint_be(value.length().reinterpret_as_uint())
  buf.write_bytes(value)
}

///|
fn encode_connect(payload : ConnectPayload) -> Result[Bytes, ErrCode] {
  if payload.protocol_version.to_uint() != WIRE_VERSION {
    return Err(UnsupportedVersion)
  }
  let buf = Buffer()
  buf.write_byte(payload.protocol_version)
  buf.write_uint16_be(payload.client_flags)
  match write_field(buf, payload.token[:], 0xFFFF) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  buf.write_uint_be(0U)
  Ok(buf.contents())
}

///|
fn encode_declare(payload : DeclarePayload) -> Result[Bytes, ErrCode] {
  let buf = Buffer()
  match write_field(buf, payload.topic[:], MAX_TOPIC_LEN.reinterpret_as_int()) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  buf.write_uint16_be(payload.partition_count)
  buf.write_uint16_be(payload.flags)
  Ok(buf.contents())
}

///|
fn write_key_value(
  buf : Buffer,
  key : BytesView,
  value : BytesView,
) -> Result[Unit, ErrCode] {
  match checked_len(key, MAX_KEY_LEN.reinterpret_as_int()) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  match checked_len(value, MAX_VALUE_LEN.reinterpret_as_int()) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  buf.write_uint16_be(key.length().to_uint16())
  buf.write_bytes(key)
  write_fixed_field(buf, value)
  Ok(())
}

///|
fn encode_pub(payload : PubPayload) -> Result[Bytes, ErrCode] {
  let buf = Buffer()
  buf.write_uint16_be(payload.topic_id)
  buf.write_uint16_be(payload.partition)
  buf.write_uint64_be(payload.producer_id)
  buf.write_uint64_be(payload.producer_seq)
  buf.write_uint16_be(payload.flags)
  match write_key_value(buf, payload.key[:], payload.value[:]) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  Ok(buf.contents())
}

///|
fn encode_sub(payload : SubPayload) -> Result[Bytes, ErrCode] {
  if payload.partition.to_uint() != 0xFFFFU {
    return Err(MalformedPayload)
  }
  let buf = Buffer()
  match write_field(buf, payload.group[:], 0xFFFF) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  buf.write_uint16_be(payload.topic_id)
  buf.write_uint16_be(payload.partition)
  buf.write_byte(payload.start_policy)
  buf.write_uint16_be(payload.credit_count)
  buf.write_uint_be(payload.credit_bytes)
  buf.write_uint16_be(payload.flags)
  Ok(buf.contents())
}

///|
fn encode_ack(payload : AckPayload) -> Result[Bytes, ErrCode] {
  let buf = Buffer()
  buf.write_uint16_be(payload.subscription_id)
  buf.write_uint16_be(payload.topic_id)
  buf.write_uint16_be(payload.partition)
  buf.write_uint64_be(payload.sequence)
  buf.write_uint64_be(payload.delivery_id)
  buf.write_uint64_be(payload.ownership_epoch)
  buf.write_uint16_be(payload.flags)
  Ok(buf.contents())
}

///|
fn encode_nack(payload : NackPayload) -> Result[Bytes, ErrCode] {
  let buf = Buffer()
  buf.write_uint16_be(payload.subscription_id)
  buf.write_uint16_be(payload.topic_id)
  buf.write_uint16_be(payload.partition)
  buf.write_uint64_be(payload.sequence)
  buf.write_uint64_be(payload.delivery_id)
  buf.write_uint64_be(payload.ownership_epoch)
  buf.write_byte(payload.reason)
  buf.write_uint16_be(payload.flags)
  Ok(buf.contents())
}

///|
fn encode_error(payload : ErrPayload) -> Result[Bytes, ErrCode] {
  match checked_len(payload.message[:], MAX_ERR_MESSAGE.reinterpret_as_int()) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  let buf = Buffer()
  buf.write_uint16_be(payload.code.to_u16().to_uint16())
  buf.write_byte(payload.request_op.to_byte())
  buf.write_uint16_be(payload.message.length().to_uint16())
  buf.write_bytes(payload.message[:])
  Ok(buf.contents())
}

///|
fn encode_ok(payload : OkPayload) -> Result[Bytes, ErrCode] {
  let buf = Buffer()
  buf.write_byte(payload.request_op.to_byte())
  write_fixed_field(buf, payload.result[:])
  Ok(buf.contents())
}

///|
/// Encode one operation payload and its operation byte in wire v0 field order.
///
/// # Example
///
/// ```mbt check
/// test {
///   let encoded = match @protocol.encode_wire_payload(@protocol.Ping) {
///     Ok(bytes) => bytes
///     Err(_) => fail("PING encoding failed")
///   }
///   assert_eq(encoded.length(), 0)
/// }
/// ```

///|
fn encode_msg(payload : MsgPayload) -> Result[Bytes, ErrCode] {
  let buf = Buffer()
  buf.write_uint16_be(payload.subscription_id)
  buf.write_uint16_be(payload.topic_id)
  buf.write_uint16_be(payload.partition)
  buf.write_uint64_be(payload.sequence)
  buf.write_uint64_be(payload.delivery_id)
  buf.write_uint16_be(payload.attempt)
  buf.write_uint64_be(payload.ownership_epoch)
  buf.write_uint64_be(payload.producer_id)
  buf.write_uint64_be(payload.producer_seq)
  buf.write_uint16_be(payload.flags)
  match write_key_value(buf, payload.key[:], payload.value[:]) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  Ok(buf.contents())
}

///|
fn encode_pull(payload : PullPayload) -> Result[Bytes, ErrCode] {
  if payload.ownership_epochs.length() > 0xFFFF {
    return Err(MalformedPayload)
  }
  let buf = Buffer()
  buf.write_uint16_be(payload.subscription_id)
  buf.write_uint64_be(payload.member_id)
  buf.write_uint_be(payload.membership_epoch)
  buf.write_uint_be(payload.assignment_epoch)
  buf.write_uint16_be(payload.ownership_epochs.length().to_uint16())
  for epoch in payload.ownership_epochs {
    buf.write_uint64_be(epoch)
  }
  buf.write_uint16_be(payload.max_msgs)
  buf.write_uint_be(payload.max_bytes)
  buf.write_uint16_be(payload.wait_ms)
  buf.write_uint_be(payload.min_bytes)
  Ok(buf.contents())
}

///|
fn encode_heartbeat(payload : HeartbeatPayload) -> Result[Bytes, ErrCode] {
  if payload.state.to_uint() > 1U {
    return Err(MalformedPayload)
  }
  let buf = Buffer()
  buf.write_uint16_be(payload.subscription_id)
  buf.write_uint64_be(payload.member_id)
  buf.write_uint_be(payload.membership_epoch)
  buf.write_uint_be(payload.assignment_epoch)
  buf.write_byte(payload.state)
  Ok(buf.contents())
}

///|
fn encode_notice(payload : NoticePayload) -> Result[Bytes, ErrCode] {
  if payload.kind.to_uint() > 1U {
    return Err(MalformedPayload)
  }
  let buf = Buffer()
  buf.write_uint64_be(payload.notice_id)
  buf.write_byte(payload.kind)
  buf.write_uint16_be(payload.group_id)
  buf.write_uint_be(payload.membership_epoch)
  buf.write_uint_be(payload.assignment_epoch)
  buf.write_uint64_be(payload.ownership_epoch)
  buf.write_uint16_be(payload.topic_id)
  buf.write_uint16_be(payload.partition)
  buf.write_uint64_be(payload.member_id)
  Ok(buf.contents())
}

///|
fn encode_control_ack(payload : ControlAckPayload) -> Result[Bytes, ErrCode] {
  if payload.notice_kind.to_uint() > 1U || payload.result.to_uint() > 2U {
    return Err(MalformedPayload)
  }
  let buf = Buffer()
  buf.write_uint64_be(payload.notice_id)
  buf.write_byte(payload.notice_kind)
  buf.write_uint16_be(payload.group_id)
  buf.write_uint_be(payload.membership_epoch)
  buf.write_uint_be(payload.assignment_epoch)
  buf.write_uint64_be(payload.ownership_epoch)
  buf.write_byte(payload.result)
  Ok(buf.contents())
}

///|
fn encode_credit(payload : CreditPayload) -> Result[Bytes, ErrCode] {
  if payload.mode.to_uint() > 1U {
    return Err(MalformedPayload)
  }
  let buf = Buffer()
  buf.write_uint16_be(payload.subscription_id)
  buf.write_uint_be(payload.membership_epoch)
  buf.write_uint64_be(payload.ownership_epoch)
  buf.write_byte(payload.mode)
  buf.write_uint16_be(payload.credit_count)
  buf.write_uint_be(payload.credit_bytes)
  buf.write_uint_be(0U)
  Ok(buf.contents())
}

///|
pub fn encode_wire_payload(payload : WirePayload) -> Result[Bytes, ErrCode] {
  match payload {
    WirePayload::Connect(payload) => encode_connect(payload)
    WirePayload::Declare(payload) => encode_declare(payload)
    WirePayload::Pub(payload) => encode_pub(payload)
    WirePayload::Sub(payload) => encode_sub(payload)
    WirePayload::Ack(payload) => encode_ack(payload)
    WirePayload::Nack(payload) => encode_nack(payload)
    WirePayload::Ping => Ok(b"")
    WirePayload::Err(payload) => encode_error(payload)
    WirePayload::Ok(payload) => encode_ok(payload)
    WirePayload::Msg(payload) => encode_msg(payload)
    WirePayload::Pull(payload) => encode_pull(payload)
    WirePayload::Heartbeat(payload) => encode_heartbeat(payload)
    WirePayload::Notice(payload) => encode_notice(payload)
    WirePayload::ControlAck(payload) => encode_control_ack(payload)
    WirePayload::Credit(payload) => encode_credit(payload)
  }
}

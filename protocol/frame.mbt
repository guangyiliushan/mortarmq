/// Frame boundary codec for the v0 wire protocol.
///
/// A frame is `u32_be length || u8 op || payload[length - 1]`. The length counts
/// the operation byte and payload, not the four length bytes. Decoding borrows
/// the payload as a `BytesView`; it never copies payload bytes or searches for a
/// new frame after an error. Backpressure is therefore applied only at complete
/// frame boundaries.

///|
/// The result of feeding the accumulated connection read buffer to the decoder.
///
/// `Need` is the number of additional bytes required before the decoder can
/// make another decision. `Frame` borrows the operation payload only until the
/// underlying read buffer is mutated. `DecodeError` carries a wire error code
/// and always requires the connection to be handled at a policy boundary.
pub enum DecodeResult {
  Need(Int)
  Frame(Op, BytesView)
  DecodeError(ErrCode)
}

///|
/// Read a big-endian unsigned 32-bit length prefix.
///
/// `UInt` keeps the full 32-bit input representable before the protocol bound
/// is checked; converting to `Int` only after that check stays within the
/// 16 MiB frame budget.
fn read_u32_be(data : BytesView, offset : Int) -> UInt {
  (data[offset].to_uint() << 24) +
  (data[offset + 1].to_uint() << 16) +
  (data[offset + 2].to_uint() << 8) +
  data[offset + 3].to_uint()
}

///|
/// Decode from the accumulated read buffer without copying the payload.
///
/// A short prefix returns the exact missing byte count. A zero or oversized
/// length returns `BAD_LENGTH`; an unknown operation returns `UNKNOWN_OP`.
/// Both conditions close the connection because the byte stream has no
/// resynchronisation point.
pub fn decode_frame(data : BytesView) -> DecodeResult {
  let available = data.length()
  if available < 4 {
    return Need(4 - available)
  }
  let body_length = read_u32_be(data, 0)
  if body_length < 1U || body_length > MAX_FRAME_LEN {
    return DecodeError(BadLength)
  }
  let body_length = body_length.reinterpret_as_int()
  if available < 4 + body_length {
    return Need(4 + body_length - available)
  }
  match Op::from_byte(data[4]) {
    Some(op) => Frame(op, data[5:4 + body_length])
    None => DecodeError(UnknownOp)
  }
}

///|
/// Encode one complete frame.
///
/// The length prefix counts the operation byte and payload, matching
/// `decode_frame`. The payload bound is checked before adding the operation
/// byte, so a caller-supplied oversized view can never overflow intermediate
/// arithmetic. Oversized payloads return `BAD_LENGTH` instead of a programmer
/// failure panic.
pub fn encode_frame(op : Op, payload : BytesView) -> Result[Bytes, ErrCode] {
  let payload_length = payload.length()
  if payload_length < 0 || payload_length >= MAX_FRAME_LEN.reinterpret_as_int() {
    return Err(BadLength)
  }
  let body_length = 1 + payload_length
  let buf = Buffer()
  buf.write_int_be(body_length)
  buf.write_byte(op.to_byte())
  buf.write_bytes(payload)
  Ok(buf.contents())
}

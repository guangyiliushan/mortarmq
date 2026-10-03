/// Decode v0 wire frames at complete-frame boundaries without copying payload.
///
/// A frame is `u32_be length || u8 op || payload[length - 1]`. The length counts
/// the operation byte and payload, not the four length bytes. Decoding borrows
/// the payload as a `BytesView`; it never copies payload bytes or searches for a
/// new frame after an error. Backpressure is therefore applied only at complete
/// frame boundaries.

///|
/// Classify the decoder outcome so callers can wait, consume a borrowed
/// payload, or close on a wire error without interpreting reserved bytes.
///
/// `Need` is the number of additional bytes required before the decoder can
/// make another decision. `Frame` borrows the operation payload only until the
/// underlying read buffer is mutated. `DecodeError` carries a wire error code
/// and always requires the connection to be handled at a policy boundary.
///
/// # Example
///
/// ```mbt check
/// test {
///   match @protocol.decode_frame(b"") {
///     @protocol.Need(more) => assert_eq(more, 4)
///     _ => fail("expected Need for empty input")
///   }
/// }
/// ```
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
/// length returns `BAD_LENGTH`; an unknown operation is rejected once its fifth
/// header byte is visible, before waiting for a potentially oversized payload.
/// Both error classes close the connection because the byte stream has no
/// resynchronisation point.
///
/// # Example
///
/// ```mbt check
/// test {
///   match @protocol.decode_frame(b"\x00\x00\x00\x01\x07") {
///     @protocol.Frame(op, payload) => {
///       assert_eq(op, @protocol.Ping)
///       assert_eq(payload.length(), 0)
///     }
///     _ => fail("expected the minimum frame to decode")
///   }
/// }
/// ```
pub fn decode_frame(data : BytesView) -> DecodeResult {
  let available = data.length()
  if available < 4 {
    return Need(4 - available)
  }
  let body_length = read_u32_be(data, 0)
  if body_length < 1U || body_length > MAX_FRAME_LEN {
    return DecodeError(BadLength)
  }
  if available < 5 {
    return Need(1)
  }
  let op = match Op::from_byte(data[4]) {
    Some(op) => op
    None => return DecodeError(UnknownOp)
  }
  let body_length = body_length.reinterpret_as_int()
  if available < 4 + body_length {
    return Need(4 + body_length - available)
  }
  Frame(op, data[5:4 + body_length])
}

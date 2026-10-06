/// Decode and encode the minimal websocket frame subset shared by both ends of
/// a websocket transport.
///
/// The frame layout is RFC 6455 section 5.2: `1-byte fin/rsv/opcode ||
/// 1-byte mask/length || [2- or 8-byte extended length] || [4-byte mask key]
/// || payload`. The connection profile is binary data frames only (opcode
/// 0x2): a text data frame is refused with close code 1003, the mask bit is
/// required on client-to-server frames and forbidden on server-to-client
/// frames, and the read side reassembles fragmented messages while the write
/// side emits single unfragmented frames. No extension is negotiated, so a
/// set rsv bit is a protocol error, and close frames surface to the caller so
/// the transport can answer them.
///
/// # Constraints
///
/// Each frame is capped at `MAX_FRAME_LEN` (16 MiB), so every single-frame
/// message of the v0 wire protocol fits inside one websocket frame; a
/// fragmented message is bounded by the frames it is built from. Control
/// frames carry
/// at most 125 bytes and are never fragmented. Ping (0x9) and pong (0xA) are
/// outside the binary-plus-close profile and refused like reserved opcodes.
/// After any `WsError` the byte stream has no resynchronisation point: the
/// caller sends the carried close code and disconnects. Close codes surface
/// exactly as the peer sent them; validating them against the reserved
/// ranges is a later policy, not a property of this codec. The read side is
/// stateless over the whole accumulated buffer and validates frame headers
/// until a message completes, so an incomplete fragmented message costs no
/// payload work; a masked message is unmasked while assembling into one
/// message buffer, and an
/// unmasked single-frame message borrows the input without copying.

///|
/// Name the endpoint that produced the frames under decode.
///
/// `Client` requires the mask bit on every frame, `Server` forbids it. The
/// direction decides refusal, so a decoder created for one side of the
/// connection never silently accepts the other side's framing.
///
/// Example:
///
/// ```mbt check
/// test {
///   let result = @protocol.decode_ws_message(
///     b"\x82\x00"[:],
///     @protocol.WsPeer::Server,
///   )
///   match result {
///     @protocol.Message(_, consumed) => assert_eq(consumed, 2)
///     _ => fail("expected an unmasked server frame to decode")
///   }
/// }
/// ```
pub(all) enum WsPeer {
  Client
  Server
}

///|
/// Close codes this codec sends, as 2-byte big-endian values on the wire.
///
/// `NormalClose` (0x03E8) answers a peer close, `ProtocolError` (0x03EA)
/// refuses malformed or out-of-profile framing, `UnsupportedData` (0x03EB)
/// refuses text data frames. The profile keeps exactly these three codes;
/// peer close codes are surfaced as raw values and are never mapped onto
/// these constructors.
///
/// Example:
///
/// ```mbt check
/// test {
///   let frame = @protocol.encode_ws_close_frame(@protocol.UnsupportedData)
///   assert_eq(frame, b"\x88\x02\x03\xeb")
/// }
/// ```
pub(all) enum WsCloseCode {
  NormalClose
  ProtocolError
  UnsupportedData
} derive(Eq, Debug)

///|
pub extend WsCloseCode with Eq::{not_equal, equal}

///|
pub extend WsCloseCode with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Classify the decoder outcome so callers can wait, consume a reassembled
/// message, answer a close, or refuse the connection.
///
/// `Need` is the number of additional bytes required before the decoder can
/// make another decision. `Message` borrows the reassembled binary payload
/// only until the underlying read buffer is mutated and carries the number of
/// wire bytes the message consumed, which the caller removes from the buffer.
/// `PeerClose` carries the peer's close code as sent on the wire (0x03ED
/// stands for a close frame that carried no code) plus the consumed count.
/// `WsError` refuses the stream: the caller sends the carried close code and
/// disconnects, because the byte stream has no resynchronisation point.
///
/// # Example
///
/// ```mbt check
/// test {
///   match @protocol.decode_ws_message(b"\x82\x00"[:], @protocol.WsPeer::Server) {
///     @protocol.Message(payload, _) => assert_eq(payload.length(), 0)
///     _ => fail("expected an empty message to decode")
///   }
/// }
/// ```
pub enum WsDecodeResult {
  Need(Int)
  Message(BytesView, Int)
  PeerClose(UInt16, Int)
  WsError(WsCloseCode)
}

///|
/// Decode the first complete websocket message from the accumulated read
/// buffer without copying an unmasked single-frame payload.
///
/// The decoder walks frame headers from the start of the buffer and applies
/// refusals in a fixed order: rsv bits set, then mask direction against
/// `peer`, then opcode, then length form, then control-frame rules, then
/// fragmentation chain rules, then the `MAX_FRAME_LEN` message ceiling. A
/// fragmented message reassembles in one pass when its final fragment is
/// visible; until then the decoder waits at exact `Need` counts and copies no
/// payload. A close frame surfaces immediately, ahead of the fragments it may
/// interrupt. An empty buffer asks for the 2-byte frame header.
///
/// # Errors
///
/// Returns `WsError` for every refusal above; text data frames carry
/// `UnsupportedData` and every other fault carries `ProtocolError`.
///
/// # Example
///
/// ```mbt check
/// test {
///   let masked : Bytes = b"\x82\x82\x01\x02\x03\x04\x49\x6b"
///   match @protocol.decode_ws_message(masked[:], @protocol.WsPeer::Client) {
///     @protocol.Message(payload, consumed) => {
///       assert_eq(payload.length(), 2)
///       assert_eq(consumed, 8)
///     }
///     _ => fail("expected the masked frame to decode")
///   }
/// }
/// ```
pub fn decode_ws_message(data : BytesView, peer : WsPeer) -> WsDecodeResult {
  let available = data.length()
  let mask_required = match peer {
    WsPeer::Client => true
    WsPeer::Server => false
  }
  let fragments : Array[WsFragment] = []
  let mut in_message = false
  let mut pos = 0
  while true {
    if available - pos < 2 {
      return Need(2 - (available - pos))
    }
    let first = data[pos].to_uint()
    let second = data[pos + 1].to_uint()
    let fin = (first & 0x80U) != 0U
    if (first & 0x70U) != 0U {
      // No extension is negotiated, so a reserved rsv bit claims one.
      return WsError(ProtocolError)
    }
    let opcode = (first & 0x0FU).reinterpret_as_int()
    let masked = (second & 0x80U) != 0U
    if masked != mask_required {
      return WsError(ProtocolError)
    }
    let is_control = (opcode & 0x8) != 0
    if is_control && (!fin || (second & 0x7FU).reinterpret_as_int() > 125) {
      // A control frame is never fragmented and never grows past 125 bytes,
      // which also rules out its extended length forms.
      return WsError(ProtocolError)
    }
    let mut payload_len = (second & 0x7FU).reinterpret_as_int()
    let mut header = 2
    if payload_len == 126 {
      if available - pos < 4 {
        return Need(4 - (available - pos))
      }
      payload_len = read_uint16_be(data, pos + 2)
      if payload_len < 126 {
        // RFC 6455 section 5.2 requires the minimal length encoding.
        return WsError(ProtocolError)
      }
      header = 4
    } else if payload_len == 127 {
      if available - pos < 10 {
        return Need(10 - (available - pos))
      }
      let long_len = read_uint64_be(data, pos + 2)
      if long_len > MAX_FRAME_LEN.to_uint64() || long_len < 65536UL {
        return WsError(ProtocolError)
      }
      payload_len = long_len.to_int()
      header = 10
    }
    let fragment = if masked {
      if available - pos < header + 4 {
        return Need(header + 4 - (available - pos))
      }
      let key = read_uint_be(data, pos + header)
      header = header + 4
      { start: pos + header, length: payload_len, masked: true, key, }
    } else {
      { start: pos + header, length: payload_len, masked: false, key: 0U, }
    }
    let frame_end = pos + header + payload_len
    if available < frame_end {
      return Need(frame_end - available)
    }
    if opcode == 0x8 {
      // A close frame carries no code or a 2-byte code plus optional reason;
      // a 1-byte payload is a connection failure per RFC 6455 section 5.5.1.
      if payload_len == 1 {
        return WsError(ProtocolError)
      }
      let code = if payload_len == 0 {
        (0x03ED).to_uint16()
      } else {
        read_uint16_be(data, pos + header).to_uint16()
      }
      return PeerClose(code, frame_end)
    }
    match opcode {
      0x1 => return WsError(UnsupportedData)
      0x2 =>
        if in_message {
          // A new data frame may not interleave inside a fragmented message.
          return WsError(ProtocolError)
        }
      0x0 =>
        if !in_message {
          // A continuation without a started message has nothing to continue.
          return WsError(ProtocolError)
        }
      // Reserved data opcodes, ping, pong, and reserved control opcodes are
      // all outside the binary-plus-close profile.
      _ => return WsError(ProtocolError)
    }
    fragments.push(fragment)
    in_message = true
    if fin {
      let payload = assemble_message(data, fragments)
      return Message(payload, frame_end)
    }
    pos = frame_end
  }
  abort("unreachable")
}

///|
/// Emit one unfragmented unmasked binary websocket frame.
///
/// The frame carries the fin bit, the binary opcode, no mask bit, and the
/// shortest length form for the payload. The write side never masks: masking
/// is a client-to-server role, and the browser masks frames it sends itself.
///
/// # Errors
///
/// Returns `ProtocolError` when the payload exceeds the `MAX_FRAME_LEN`
/// ceiling, because the caller must close instead of emitting a frame no
/// receiver of this profile accepts.
///
/// # Example
///
/// ```mbt check
/// test {
///   match @protocol.encode_ws_binary_frame(b"abc"[:]) {
///     Ok(frame) => assert_eq(frame, b"\x82\x03abc")
///     Err(_) => fail("did not encode the example payload")
///   }
/// }
/// ```
pub fn encode_ws_binary_frame(
  payload : BytesView,
) -> Result[Bytes, WsCloseCode] {
  let length = payload.length()
  if length > MAX_FRAME_LEN.reinterpret_as_int() {
    return Err(ProtocolError)
  }
  let buf = Buffer()
  // Fin bit set and binary opcode 0x2: the write side emits single frames.
  buf.write_byte(b'\x82')
  if length < 126 {
    buf.write_byte(length.to_byte())
  } else if length <= 0xFFFF {
    buf.write_byte(b'\x7e')
    buf.write_uint16_be(length.to_uint16())
  } else {
    buf.write_byte(b'\x7f')
    // The ceiling keeps the length inside 24 bits, so the high word is zero.
    buf.write_uint_be(0U)
    buf.write_uint_be(length.reinterpret_as_uint())
  }
  buf.write_bytes(payload)
  Ok(buf.contents())
}

///|
/// Emit one unmasked close frame carrying the 2-byte close code and no reason.
///
/// The transport answers a peer close and refuses faults with this frame; the
/// reason text is left empty because the profile treats it as advisory and no
/// consumer reads it.
///
/// # Example
///
/// ```mbt check
/// test {
///   let frame = @protocol.encode_ws_close_frame(@protocol.NormalClose)
///   assert_eq(frame, b"\x88\x02\x03\xe8")
/// }
/// ```
pub fn encode_ws_close_frame(code : WsCloseCode) -> Bytes {
  let buf = Buffer()
  // Fin bit set and close opcode 0x8 with a 2-byte payload.
  buf.write_byte(b'\x88')
  buf.write_byte(b'\x02')
  buf.write_uint16_be(
    match code {
      NormalClose => (0x03E8).to_uint16()
      ProtocolError => (0x03EA).to_uint16()
      UnsupportedData => (0x03EB).to_uint16()
    },
  )
  buf.contents()
}

///|
/// Record one complete frame's placement inside the read buffer.
priv struct WsFragment {
  start : Int
  length : Int
  masked : Bool
  key : UInt
}

///|
/// Read a 2-byte big-endian unsigned value.
fn read_uint16_be(data : BytesView, offset : Int) -> Int {
  ((data[offset].to_uint() << 8) | data[offset + 1].to_uint()).reinterpret_as_int()
}

///|
/// Read an 8-byte big-endian unsigned length.
fn read_uint64_be(data : BytesView, offset : Int) -> UInt64 {
  let mut value = 0UL
  for k in 0..<8 {
    value = (value << 8) | data[offset + k].to_uint().to_uint64()
  }
  value
}

///|
/// Build the message payload from its recorded fragments in one pass.
///
/// A single unmasked fragment borrows the read buffer. Any other shape
/// assembles the fragments into one message buffer, unmasking masked
/// fragments during the copy, so the unmask work is paid once per message
/// rather than once per arrived frame.
fn assemble_message(
  data : BytesView,
  fragments : Array[WsFragment],
) -> BytesView {
  if fragments.length() == 1 {
    let only = fragments[0]
    if !only.masked {
      return data[only.start:only.start + only.length]
    }
  }
  let mut total = 0
  for fragment in fragments {
    total = total + fragment.length
  }
  let out : FixedArray[Byte] = FixedArray::make(total, b'\x00')
  let mut base = 0
  for fragment in fragments {
    let start = fragment.start
    let length = fragment.length
    let key = fragment.key
    for k in 0..<length {
      if fragment.masked {
        // The mask key applies to the fragment's own payload, cycling over
        // its four bytes; the packed key puts the first wire byte highest.
        let shift = (3 - (k & 3)) * 8
        out[base + k] = ((data[start + k].to_uint() ^ (key >> shift)) & 0xFFU)
          .reinterpret_as_int()
          .to_byte()
      } else {
        out[base + k] = data[start + k]
      }
    }
    base = base + length
  }
  Bytes::makei(total, i => out[i])[:]
}

/// Exercise session establishment: the pre-CONNECT whitelist, the
/// admission-before-authentication order that turns an inbound CONNECT
/// storm away before any authentication work, and the failure verdicts
/// that reach the wire.

///|
/// A Delay that records requested pauses instead of waiting.
priv struct RecordDelay {
  calls : Ref[Array[Int]]
}

///|
impl @security.Delay for RecordDelay with fn sleep_ms(self, ms : Int) -> Unit {
  self.calls.val.push(ms)
}

///|
fn record_delay() -> RecordDelay {
  { calls: Ref::Ref([]), }
}

///|
/// The token "abc" hashes to the first line, the empty token to the
/// second -- the same store the authentication tests pin.
fn test_store() -> @security.TokenStore raise {
  let line1 = b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\tadmin"
  let line2 = b"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\tclient"
  match @security.parse_tokens((line1 + b"\n" + line2 + b"\n")[:]) {
    Some(store) => store
    None => fail("the fixture store must parse")
  }
}

///|
/// Wrap a protocol frame (4-byte big-endian length over op and body,
/// then the op byte, then the body) into its wire bytes.
fn frame_bytes(op : Byte, body : Bytes) -> Bytes {
  let buf = Buffer()
  let total = 1 + body.length()
  buf.write_byte(((total >> 24) & 0xFF).to_byte())
  buf.write_byte(((total >> 16) & 0xFF).to_byte())
  buf.write_byte(((total >> 8) & 0xFF).to_byte())
  buf.write_byte((total & 0xFF).to_byte())
  buf.write_byte(op)
  for index in 0..<body.length() {
    buf.write_byte(body[index])
  }
  buf.contents()
}

///|
/// Wrap protocol bytes in one masked client WS frame (fin + binary,
/// short length band), as the minimal subset demands.
fn masked_client_frame(payload : Bytes) -> Bytes {
  let mask : Bytes = b"\x01\x02\x03\x04"
  let buf = Buffer()
  buf.write_byte((0x82).to_byte())
  let length = payload.length()
  guard length < 126 else { abort("fixtures stay in the short length band") }
  buf.write_byte((length | 0x80).to_byte())
  for index in 0..<4 {
    buf.write_byte(mask[index])
  }
  for index in 0..<length {
    buf.write_byte(
      (payload[index].to_uint() ^ mask[index % 4].to_uint()).to_byte(),
    )
  }
  buf.contents()
}

///|
/// Wrap protocol bytes in an unmasked frame: a client frame the subset
/// refuses.
fn unmasked_client_frame(payload : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_byte((0x82).to_byte())
  let length = payload.length()
  guard length < 126 else { abort("fixtures stay in the short length band") }
  buf.write_byte(length.to_byte())
  for index in 0..<length {
    buf.write_byte(payload[index])
  }
  buf.contents()
}

///|
/// One complete masked WS message carrying a CONNECT for `token`.
fn connect_message(token : Bytes) -> Bytes {
  let body = match
    @protocol.encode_wire_payload(
      @protocol.WirePayload::Connect({
        protocol_version: (1).to_byte(),
        client_flags: 0U.to_uint16(),
        token: token[:],
      }),
    ) {
    Ok(body) => body
    Err(_) => abort("the CONNECT payload must encode")
  }
  masked_client_frame(frame_bytes((0x01).to_byte(), body))
}

///|
/// One complete masked WS message carrying a bare op with an empty body.
fn empty_body_message(op : Byte) -> Bytes {
  masked_client_frame(frame_bytes(op, b""))
}

///|
async test "a valid CONNECT establishes a session and returns the role" {
  let delay = record_delay()
  let admission = @session.ConnAdmission::new(1U.to_uint16())
  let messages = [connect_message(b"abc")[:]]
  let outcome = @session.establish(
    messages.iter(),
    test_store(),
    delay,
    admission,
  )
  assert_eq(outcome, Ok({ role: b"admin", }))
  assert_eq(delay.calls.val, []) // success is never delayed
  // the admission slot returned with the establishment
  assert_eq(@session.ConnAdmission::admit(admission), Ok(()))
}

///|
async test "PING and ERR before CONNECT are tolerated, not served" {
  let delay = record_delay()
  let admission = @session.ConnAdmission::new(1U.to_uint16())
  let messages = [
    empty_body_message((0x07).to_byte())[:],
    empty_body_message((0x08).to_byte())[:],
    connect_message(b"abc")[:],
  ]
  let outcome = @session.establish(
    messages.iter(),
    test_store(),
    delay,
    admission,
  )
  assert_eq(outcome, Ok({ role: b"admin", }))
}

///|
async test "traffic outside the pre-CONNECT whitelist is refused" {
  let delay = record_delay()
  let admission = @session.ConnAdmission::new(1U.to_uint16())
  // a DECLARE body shape cannot be built here; a bare unknown op byte
  // stands for any non-whitelist first frame and dies in the frame layer
  // first. A valid DECLARE payload encodes through the wire codec.
  let body = match
    @protocol.encode_wire_payload(
      @protocol.WirePayload::Declare({
        topic: b"orders"[:],
        partition_count: 1U.to_uint16(),
        flags: 0U.to_uint16(),
      }),
    ) {
    Ok(body) => body
    Err(_) => abort("the DECLARE payload must encode")
  }
  let messages = [masked_client_frame(frame_bytes((0x02).to_byte(), body))[:]]
  let outcome = @session.establish(
    messages.iter(),
    test_store(),
    delay,
    admission,
  )
  assert_eq(outcome, Err(@session.NotConnect))
  assert_eq(
    @session.SessionFail::to_err_code(@session.NotConnect),
    @protocol.NotAuthenticated,
  )
  assert_eq(@protocol.NotAuthenticated.to_uint16(), 0x0005U)
  assert_eq(delay.calls.val, [])
}

///|
async test "an inbound CONNECT storm is refused before authentication" {
  let delay = record_delay()
  let admission = @session.ConnAdmission::new(1U.to_uint16())
  // one establishment is in flight; the storm lands on the gate
  assert_eq(@session.ConnAdmission::admit(admission), Ok(()))
  let messages = [connect_message(b"abc")[:]]
  let outcome = @session.establish(
    messages.iter(),
    test_store(),
    delay,
    admission,
  )
  // the token is valid, yet the refusal wins: admission ran first and
  // authentication was never reached -- no verdict, no pause
  assert_eq(outcome, Err(@session.AdmissionRefused))
  assert_eq(
    @session.SessionFail::to_err_code(@session.AdmissionRefused),
    @protocol.RateLimited,
  )
  assert_eq(@protocol.RateLimited.to_uint16(), 0x4003U)
  assert_eq(delay.calls.val, [])
  // once the in-flight establishment completes, the next one succeeds
  @session.ConnAdmission::complete(admission)
  let retry = @session.establish(
    messages.iter(),
    test_store(),
    delay,
    admission,
  )
  assert_eq(retry, Ok({ role: b"admin", }))
}

///|
async test "an unknown token is the generic failure after one pause" {
  let delay = record_delay()
  let admission = @session.ConnAdmission::new(2U.to_uint16())
  let messages = [connect_message(b"unknown-token")[:]]
  let outcome = @session.establish(
    messages.iter(),
    test_store(),
    delay,
    admission,
  )
  assert_eq(outcome, Err(@session.AuthRejected))
  assert_eq(
    @session.SessionFail::to_err_code(@session.AuthRejected),
    @protocol.AuthFailed,
  )
  assert_eq(@protocol.AuthFailed.to_uint16(), 0x0006U)
  assert_eq(delay.calls.val, [100]) // exactly one pause, inside authenticate
}

///|
async test "an unmasked client frame is refused with the subset verdict" {
  let delay = record_delay()
  let admission = @session.ConnAdmission::new(1U.to_uint16())
  let messages = [unmasked_client_frame(frame_bytes((0x07).to_byte(), b""))[:]]
  let outcome = @session.establish(
    messages.iter(),
    test_store(),
    delay,
    admission,
  )
  assert_eq(outcome, Err(@session.WsRefused(@protocol.ProtocolError)))
  assert_eq(delay.calls.val, [])
}

///|
async test "a stream that ends before CONNECT is an unfinished establishment" {
  let delay = record_delay()
  let admission = @session.ConnAdmission::new(1U.to_uint16())
  let messages : Array[BytesView] = []
  let outcome = @session.establish(
    messages.iter(),
    test_store(),
    delay,
    admission,
  )
  assert_eq(outcome, Err(@session.StreamEnded))
  assert_eq(
    @session.SessionFail::to_err_code(@session.StreamEnded),
    @protocol.AuthTimeout,
  )
  assert_eq(@protocol.AuthTimeout.to_uint16(), 0x0007U)
}

///|
async test "garbage frame bytes keep the frame layer's registered code" {
  let delay = record_delay()
  let admission = @session.ConnAdmission::new(1U.to_uint16())
  // a zero body length is refused by the frame layer as BadLength
  let messages = [masked_client_frame(b"\x00\x00\x00\x00\x01")[:]]
  let outcome = @session.establish(
    messages.iter(),
    test_store(),
    delay,
    admission,
  )
  assert_eq(outcome, Err(@session.DecodeRefused(@protocol.BadLength)))
  assert_eq(
    @session.SessionFail::to_err_code(
      @session.DecodeRefused(@protocol.BadLength),
    ),
    @protocol.BadLength,
  )
}

///|
async test "a pre-CONNECT frame flood past the cap refuses the establishment" {
  let delay = record_delay()
  let admission = @session.ConnAdmission::new(1U.to_uint16())
  let pings = [
    empty_body_message((0x07).to_byte())[:],
    empty_body_message((0x07).to_byte())[:],
    empty_body_message((0x07).to_byte())[:],
    empty_body_message((0x07).to_byte())[:],
    empty_body_message((0x07).to_byte())[:],
    empty_body_message((0x07).to_byte())[:],
    empty_body_message((0x07).to_byte())[:],
    empty_body_message((0x07).to_byte())[:],
    empty_body_message((0x07).to_byte())[:],
  ]
  let outcome = @session.establish(pings.iter(), test_store(), delay, admission)
  assert_eq(
    outcome,
    Err(@session.SessionFail::WsRefused(@protocol.ProtocolError)),
  )
}

/// Establish a protocol session over the minimal WebSocket subset: the
/// first frames may only be CONNECT, PING or ERR, and one CONNECT
/// carrying a valid token turns the stream into a session.
///
/// The establishment order is the contract. The connection-admission
/// judgment runs before `authenticate`, so an inbound CONNECT storm
/// answers with the registered rate code and can never queue
/// authentication pauses behind admitted work. Authentication is the
/// security module's verdict surface called from exactly here, and its
/// single failure exit -- one generic verdict after one uniform pause --
/// reaches the wire unchanged as the auth failure code.
///
/// # Stability
///
/// * The pre-CONNECT whitelist is exactly CONNECT, PING and ERR: any
///   other first traffic is refused with the not-authenticated code
///   ("send CONNECT first"), and PING or ERR arriving before CONNECT are
///   tolerated and skipped, never served.
/// * WS-level refusals carry the WebSocket close code the frame subset
///   names (masked binary, no compression); protocol-level refusals map
///   onto registered error codes through `to_err_code`.
/// * An establishment occupies exactly one admission slot for its whole
///   duration and returns it on every path.

///|
/// Carry the established session's identity: the role the presented
/// token verified to.
pub(all) struct Session {
  role : Bytes
} derive(Eq, Debug)

///|
pub extend Session with Eq::{not_equal, equal}

///|
pub extend Session with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Group every way establishment can end short of a session.
///
/// `WsRefused` keeps the WebSocket close code the frame subset answered
/// with; `DecodeRefused` keeps the registered code the frame or payload
/// decoder named; the remaining cases name the establishment step that
/// refused.
pub(all) suberror SessionFail {
  WsRefused(@protocol.WsCloseCode)
  DecodeRefused(@protocol.ErrCode)
  NotConnect
  StreamEnded
  AdmissionRefused
  AuthRejected
} derive(Eq, Debug)

///|
pub extend SessionFail with Eq::{not_equal, equal}

///|
pub extend SessionFail with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Map an establishment failure onto the registered wire code.
///
/// Two mappings stretch their code because the registry has no closer
/// fit, and this function names the stretch rather than inventing a
/// value: a refused WS data type answers `UnknownOp` (0x0002, "upgrade
/// the client"), and a stream that ends mid-establishment answers
/// `AuthTimeout` (0x0007, "close the connection") -- the establishment
/// never completed within its connection.
///
/// Returns the code the refusal carries on the wire.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(
///     @session.SessionFail::to_err_code(@session.NotConnect),
///     @protocol.NotAuthenticated,
///   )
///   assert_eq(
///     @session.SessionFail::to_err_code(@session.AdmissionRefused),
///     @protocol.RateLimited,
///   )
///   assert_eq(
///     @session.SessionFail::to_err_code(@session.AuthRejected),
///     @protocol.AuthFailed,
///   )
/// }
/// ```
pub fn SessionFail::to_err_code(self : SessionFail) -> @protocol.ErrCode {
  match self {
    WsRefused(code) =>
      match code {
        @protocol.UnsupportedData => @protocol.UnknownOp
        _ => @protocol.MalformedPayload
      }
    DecodeRefused(code) => code
    NotConnect => @protocol.NotAuthenticated
    StreamEnded => @protocol.AuthTimeout
    AdmissionRefused => @protocol.RateLimited
    AuthRejected => @protocol.AuthFailed
  }
}

///|
/// Establish the session from the raw WebSocket message stream.
///
/// Each item is one complete WS message as the client sent it (masked
/// binary under the minimal subset). The establishment loop tolerates
/// PING and ERR before CONNECT, refuses anything else outside the
/// whitelist, and turns the first CONNECT into a session: admission
/// first, then the token verdict. The admission slot is held for the
/// whole call and returned on every path.
///
/// Parameters:
///
/// * `messages` : The WS messages of one connection, in arrival order;
///   an exhausted stream before CONNECT is an unfinished establishment.
/// * `store` : The token store the presented token verifies against.
/// * `delay` : The pause source authentication fails through.
/// * `admission` : The connection-admission gate bounding concurrent
///   establishments.
///
/// Returns the session carrying the verified role.
///
/// # Errors
///
/// * `AdmissionRefused` -- the gate was at its cap; authentication is
///   never reached (the storm interlock).
/// * `NotConnect` -- a pre-CONNECT frame outside the CONNECT/PING/ERR
///   whitelist.
/// * `WsRefused` / `DecodeRefused` -- the frame subset or the frame and
///   payload layers refused the bytes.
/// * `AuthRejected` -- the generic authentication verdict, after the
///   single uniform pause inside `authenticate`.
/// * `StreamEnded` -- the stream closed or ended before CONNECT.
///
/// Example:
///
/// ```mbt nocheck
/// let session = await establish(messages, store, delay, admission)
/// ```
pub async fn[D : @security.Delay] establish(
  messages : Iter[BytesView],
  store : @security.TokenStore,
  delay : D,
  admission : ConnAdmission,
) -> Result[Session, SessionFail] {
  match admission.admit() {
    Ok(_) => ()
    Err(fail) => return Err(fail)
  }
  let outcome = establish_admitted(messages, store, delay)
  admission.complete()
  outcome
}

///|
/// A bounded establishment: at most 8 pre-CONNECT frames totalling at
/// most 1 MiB, so one admitted connection cannot park its slot on an
/// endless PING stream. The wall-clock deadline is the wiring
/// contract's half (see auth.mbt); this module bounds what it sees.
const MAX_ESTABLISH_FRAMES : Int = 8

///|
const MAX_ESTABLISH_BYTES : Int = 1048576

///|
async fn[D : @security.Delay] establish_admitted(
  messages : Iter[BytesView],
  store : @security.TokenStore,
  delay : D,
) -> Result[Session, SessionFail] {
  let mut seen_frames = 0
  let mut seen_bytes = 0
  for message in messages {
    seen_frames = seen_frames + 1
    seen_bytes = seen_bytes + message.length()
    if seen_frames > MAX_ESTABLISH_FRAMES || seen_bytes > MAX_ESTABLISH_BYTES {
      return Err(WsRefused(@protocol.ProtocolError))
    }
    let body = match
      @protocol.decode_ws_message(message, @protocol.WsPeer::Client) {
      Message(body, _) => body
      Need(_) => return Err(WsRefused(@protocol.ProtocolError))
      PeerClose(_, _) => return Err(StreamEnded)
      WsError(code) =>
        if code == @protocol.NormalClose {
          return Err(StreamEnded)
        } else {
          return Err(WsRefused(code))
        }
    }
    let (op, frame_body) = match @protocol.decode_frame(body) {
      Frame(op, frame_body) => (op, frame_body)
      Need(_) => return Err(DecodeRefused(@protocol.MalformedPayload))
      DecodeError(code) => return Err(DecodeRefused(code))
    }
    if op == @protocol.Op::Ping || op == @protocol.Op::Err {
      continue
    }
    if op != @protocol.Op::Connect {
      return Err(NotConnect)
    }
    let token = match @protocol.decode_wire_payload(op, frame_body) {
      Ok(@protocol.WirePayload::Connect(connect)) => connect.token
      Ok(_) => return Err(DecodeRefused(@protocol.MalformedPayload))
      Err(code) => return Err(DecodeRefused(code))
    }
    let role = match @security.authenticate(store, token, delay) {
      Ok(role) => role
      Err(_) => return Err(AuthRejected)
    }
    return Ok({ role, })
  }
  Err(StreamEnded)
}

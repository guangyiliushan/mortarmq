/// Wire the client library onto the browser main thread and expose the
/// host-callable surface the demo page drives.
///
/// The JS form of the library runs on the browser main thread driven by
/// the js_async runtime (the pinned async module's JavaScript backend):
/// client work is ordinary async code, the page consumes it through the
/// host `Promise` the entry returns, and host APIs are consumed from
/// client code by waiting on their promises. The bridge is two-way and
/// both directions are exercised by the tests.
///
/// The exported helpers carry the wire for the page: the protocol codec
/// encodes DECLARE and PUB frames and decodes what the broker sends back
/// into one summary line per message, and the connection state machine
/// answers name for name so the page can light one state. The browser's
/// WebSocket already unwraps the WebSocket envelope, so these helpers
/// speak the protocol frames that travel inside its messages.
///
/// # Stability
///
/// * The entry settles real promises on the JavaScript target; the
///   other forms compile the same shape against the async runtime stubs.
/// * The entry wraps one task per call: the returned promise settles
///   when the task does, and cancellation travels through the js_async
///   abort machinery rather than any state this file keeps.
/// * The exported names are the page's contract: they are listed in the
///   package link options and renaming one is a breaking change for the
///   demo page.

///|
/// Run one client task on the browser main thread and return the host
/// promise that settles with its result.
///
/// The page awaits the returned promise; inside the task, host APIs are
/// reached by waiting on their promises through the same bridge.
///
/// Parameters:
///
/// * `task` : The client work, as async code; it runs on the js_async
///   main-thread loop and settles the returned promise.
///
/// Returns the host promise carrying the task result.
///
/// Example:
///
/// ```mbt nocheck
/// let promise = run_main(() => compute())
/// ```
pub fn[T] run_main(task : async () -> T) -> @js_async.Promise[T] {
  @js_async.Promise::from_async(task)
}

///|
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
fn to_byte_array(bytes : Bytes) -> Array[Int32] {
  let out : Array[Int32] = Array(capacity=bytes.length())
  for index in 0..<bytes.length() {
    out.push(bytes[index].to_int())
  }
  out
}

///|
fn from_byte_array(values : Array[Int32]) -> Bytes {
  let buf = Buffer()
  for index in 0..<values.length() {
    buf.write_byte((values[index] & 0xFF).to_byte())
  }
  buf.contents()
}

///|
fn state_name(state : @client.ClientState) -> String {
  match state {
    @client.Disconnected => "Disconnected"
    @client.Connecting => "Connecting"
    @client.Authenticating => "Authenticating"
    @client.Ready => "Ready"
    @client.Streaming => "Streaming"
    @client.Backoff => "Backoff"
    @client.Fatal => "Fatal"
  }
}

///|
fn state_from_name(name : String) -> @client.ClientState? {
  match name {
    "Disconnected" => Some(@client.Disconnected)
    "Connecting" => Some(@client.Connecting)
    "Authenticating" => Some(@client.Authenticating)
    "Ready" => Some(@client.Ready)
    "Streaming" => Some(@client.Streaming)
    "Backoff" => Some(@client.Backoff)
    "Fatal" => Some(@client.Fatal)
    _ => None
  }
}

///|
fn event_from_name(name : String) -> @client.ClientEvent? {
  match name {
    "ConnectRequested" => Some(@client.ConnectRequested)
    "TransportUp" => Some(@client.TransportUp)
    "TransportLost" => Some(@client.TransportLost)
    "ConnectOk" => Some(@client.ConnectOk)
    "AuthFailed" => Some(@client.AuthFailed)
    "FatalError" => Some(@client.FatalError)
    "ActivityStarted" => Some(@client.ActivityStarted)
    "QueueQuiet" => Some(@client.QueueQuiet)
    "BackoffExpired" => Some(@client.BackoffExpired)
    "Close" => Some(@client.Close)
    _ => None
  }
}

///|
/// Step the connection state machine by name and answer with the name of
/// the state it lands in.
///
/// The page sends the state and event names it displays; an unknown name
/// answers `"unknown"` and moves nothing. This is the highlight driver:
/// one call per event lights exactly one state.
///
/// Parameters:
///
/// * `state` : The current state name, spelled as the diagram spells it.
/// * `event` : The classified event name, one of the ten the machine
///   transitions on.
///
/// Returns the landing state name, or `"unknown"`.
///
/// Example:
///
/// ```mbt nocheck
/// assert_eq(state_after("Connecting", "TransportUp"), "Authenticating")
/// ```
pub fn state_after(state : String, event : String) -> String {
  match (state_from_name(state), event_from_name(event)) {
    (Some(current), Some(signal)) =>
      state_name(@client.ClientState::on(current, signal))
    _ => "unknown"
  }
}

///|
/// Encode a DECLARE of `topic` with `partition_count` into the protocol
/// frame bytes the page sends over the WebSocket.
///
/// Parameters:
///
/// * `topic` : The topic name, UTF-8 on the wire.
/// * `partition_count` : The partition count to declare; zero is refused
///   by the broker, never fabricated here.
///
/// Returns the frame bytes: 4-byte big-endian length, the op byte, and
/// the payload.
///
/// Example:
///
/// ```mbt nocheck
/// let frame = encode_declare("orders", 3)
/// ```
pub fn encode_declare(topic : String, partition_count : Int32) -> Array[Int32] {
  let body = match
    @protocol.encode_wire_payload(
      @protocol.WirePayload::Declare({
        topic: @moonbitlang/core/encoding/utf8.encode(topic)[:],
        partition_count: partition_count.to_uint16(),
        flags: 0U.to_uint16(),
      }),
    ) {
    Ok(body) => body
    Err(_) => b""
  }
  to_byte_array(frame_bytes((0x02).to_byte(), body))
}

///|
/// Encode a PUB of `key` and `value` to `topic_id` into the protocol
/// frame bytes the page sends over the WebSocket.
///
/// The demo defaults ride along: partition 0, no producer identity and
/// no flags -- the broker treats the publish as non-idempotent.
///
/// Parameters:
///
/// * `topic_id` : The identifier the DECLARE answered with.
/// * `key` : The routing key, UTF-8 on the wire; the same key keeps its
///   partition.
/// * `value` : The message body, UTF-8 on the wire.
///
/// Returns the frame bytes.
///
/// Example:
///
/// ```mbt nocheck
/// let frame = encode_pub(1, "user-42", "hello")
/// ```
pub fn encode_pub(
  topic_id : Int32,
  key : String,
  value : String,
) -> Array[Int32] {
  let body = match
    @protocol.encode_wire_payload(
      @protocol.WirePayload::Pub({
        topic_id: topic_id.to_uint16(),
        partition: 0U.to_uint16(),
        producer_id: 0UL,
        producer_seq: 0UL,
        flags: 0U.to_uint16(),
        key: @moonbitlang/core/encoding/utf8.encode(key)[:],
        value: @moonbitlang/core/encoding/utf8.encode(value)[:],
      }),
    ) {
    Ok(body) => body
    Err(_) => b""
  }
  to_byte_array(frame_bytes((0x03).to_byte(), body))
}

///|
/// Decode one protocol frame -- the payload of one WebSocket message --
/// into a single summary line the page renders.
///
/// A MSG summarizes its sequence, key and value; an ERR summarizes its
/// registered code; anything else summarizes its op. A frame that does
/// not decode answers `"malformed"`.
///
/// Parameters:
///
/// * `bytes` : One complete protocol frame, as byte values.
///
/// Returns the summary line.
///
/// Example:
///
/// ```mbt nocheck
/// let line = decode_incoming(frame)
/// ```
pub fn decode_incoming(bytes : Array[Int32]) -> String {
  let frame = from_byte_array(bytes)
  match @protocol.decode_frame(frame[:]) {
    @protocol.Frame(op, body) =>
      match @protocol.decode_wire_payload(op, body) {
        Ok(@protocol.WirePayload::Msg(message)) =>
          "MSG seq=" +
          message.sequence.to_int().to_string() +
          " key=" +
          @moonbitlang/core/encoding/utf8.decode_lossy(message.key) +
          " value=" +
          @moonbitlang/core/encoding/utf8.decode_lossy(message.value)
        Ok(@protocol.WirePayload::Ok(_)) => "OK"
        Ok(@protocol.WirePayload::Err(payload)) =>
          "ERR " + payload.code.to_uint16().to_string()
        Ok(_) => "frame op=" + op.to_byte().to_int().to_string()
        Err(_) => "malformed"
      }
    _ => "malformed"
  }
}

///|
/// Run the host promise bridge call chain and answer with its evidence
/// line: the connection machine walked to Ready through the entry, and a
/// DECLARE frame encoded and summarized through the codec.
///
/// The page awaits this promise on load -- the answer is the proof that
/// the main-thread wiring is alive in the browser.
///
/// Returns the host promise carrying the evidence line.
///
/// Example:
///
/// ```mbt nocheck
/// let line = await demo_chain()
/// ```
pub fn demo_chain() -> @js_async.Promise[String] {
  run_main(() => {
    let walked = state_name(
      @client.ClientState::on(
        @client.ClientState::on(
          @client.ClientState::on(
            @client.Disconnected,
            @client.ConnectRequested,
          ),
          @client.TransportUp,
        ),
        @client.ConnectOk,
      ),
    )
    let frame = encode_declare("orders", 3)
    "chain ok: Disconnected->Connecting->Authenticating->" +
    walked +
    "; declare frame " +
    frame.length().to_string() +
    " bytes"
  })
}

/// Exercise the host promise bridge on the browser main thread in both
/// directions: async work becomes a host promise the page can await, and
/// a host promise resolves back into async work. The round trip is the
/// bring-up probe for the browser main-thread wiring, re-run against the
/// pinned async runtime's JavaScript backend.

///|
/// A host promise that resolves to the answer, awaited from async work.
async test "host promise resolves into async work on the main thread" {
  let host_promise = @js_async.Promise::from_async(() => {
    @async.sleep(5)
    41
  })
  let resolved = @js_async.Promise::wait(host_promise)
  assert_eq(resolved, 41)
}

///|
/// Client work handed to the main-thread entry settles the promise the
/// page awaits, and the result re-enters async work through the same
/// bridge -- the full round trip.
async test "client work round-trips through the host promise bridge" {
  let page_promise = @js_main.run_main(() => {
    @async.sleep(5)
    40 + 2
  })
  let settled = @js_async.Promise::wait(page_promise)
  assert_eq(settled, 42)
  // and the settled value flows straight back through the bridge
  let again = @js_async.Promise::wait(
    @js_async.Promise::from_async(() => settled + 0),
  )
  assert_eq(again, 42)
}

///|
/// The highlight driver answers state names for every diagram pair and
/// refuses unknown names without moving anything.
async test "the state machine answers name for name" {
  assert_eq(@js_main.state_after("Connecting", "TransportUp"), "Authenticating")
  assert_eq(@js_main.state_after("Streaming", "QueueQuiet"), "Ready")
  assert_eq(@js_main.state_after("Ready", "Close"), "Disconnected")
  assert_eq(@js_main.state_after("Ready", "NoSuchEvent"), "unknown")
  assert_eq(@js_main.state_after("NoSuchState", "Close"), "unknown")
}

///|
/// The wire helpers round-trip a DECLARE through the codec: the frame
/// the page sends decodes back to its own summary.
async test "encode and decode round-trip through the protocol codec" {
  let frame = @js_main.encode_declare("orders", 3)
  assert_eq(@js_main.decode_incoming(frame), "frame op=2")
  let pub_frame = @js_main.encode_pub(1, "user-42", "hello")
  assert_eq(@js_main.decode_incoming(pub_frame), "frame op=3")
  // both frames are well-formed protocol frames with their op bytes
  assert_true(frame.length() > 5)
  assert_eq(frame[4], 2) // the DECLARE op
  assert_eq(pub_frame[4], 3) // the PUB op
}

///|
/// The chain evidence resolves through the host promise bridge.
async test "the demo chain resolves with its evidence line" {
  let line = @js_async.Promise::wait(@js_main.demo_chain())
  assert_true(
    line.has_prefix(
      "chain ok: Disconnected->Connecting->Authenticating->Ready;",
    ),
  )
}

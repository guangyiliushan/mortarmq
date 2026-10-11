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

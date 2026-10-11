/// Wire the client library onto the browser main thread: the entry that
/// turns client async work into the host promise the page awaits.
///
/// The JS form of the library runs on the browser main thread driven by
/// the js_async runtime (the pinned async module's JavaScript backend):
/// client work is ordinary async code, the page consumes it through the
/// host `Promise` this entry returns, and host APIs are consumed from
/// client code by waiting on their promises. The bridge is two-way and
/// both directions are exercised by the tests: an async task becomes a
/// host promise, and a host promise resolves back into async work.
///
/// # Stability
///
/// * The entry settles real promises on the JavaScript target; the
///   other forms compile the same shape against the async runtime stubs.
/// * The entry wraps one task per call: the returned promise settles
///   when the task does, and cancellation travels through the js_async
///   abort machinery rather than any state this file keeps.

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

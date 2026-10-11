/// Serve one `PULL` over the long-poll wait queue and shape its response.
///
/// A `PULL` that arrives while messages are ready is answered at once with
/// `MSG×N` then `OK`; one that arrives to an empty subscription either
/// answers `OK(empty)` immediately at a zero wait or parks behind
/// `PullQueue` until data wakes it, its deadline expires it, or its
/// connection cancels it. The service is the response boundary of the
/// long-poll path: it clamps batches to the request bounds, maps the wait
/// cap onto the registered `MaxWaitingPulls` refusal, and keeps the frame
/// order the pull contract names. It holds no transport and no credit window:
/// the connection loop owns sending, the record path owns data, and the
/// credit window of a subscription is fenced elsewhere.
///
/// # Stability
///
/// * A parked pull terminates exactly once: `expire` answers it empty,
///   `wake` serves it a batch, `cancel` drops it unanswered. No path lets a
///   wait outlive `MAX_PULL_WAIT_MS`, so a request never hangs.
/// * Batch sizing belongs to the request, not the record path: at most
///   `max_msgs` messages and at most `max_bytes` payload bytes (key plus
///   value) go out, and the message that would cross the byte bound stops
///   the batch whole.
/// * The epoch fields of `PullPayload` are carried but not yet fenced here;
///   generation and ownership fencing enter with the four-epoch model.

///|
/// Answer one `PULL` request that was not parked.
pub(all) enum PullServe {
  /// Send these payloads in order: `MSG×N` then `OK`, a lone `OK` with an
  /// empty result, or a lone `ERR` carrying the refusal code.
  Send(Array[@protocol.WirePayload])
  /// The request parked behind the wait queue; it completes later through
  /// `expire`, `wake`, or `cancel`.
  Parked(PullTicket)
} derive(Eq, Debug)

///|
pub extend PullServe with Eq::{not_equal, equal}

///|
pub extend PullServe with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Shape the success response of one `PULL`: `MSG×N` then `OK`.
///
/// An empty batch yields the lone `OK` with an empty result that answers a
/// timed-out or an immediate empty pull. The `OK` closes the request; the
/// `MSG` frames before it are pushes and take no request slot.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@broker.pull_ok([]).length(), 1)
/// }
/// ```
pub fn pull_ok(
  batch : Array[@protocol.MsgPayload],
) -> Array[@protocol.WirePayload] {
  let frames : Array[@protocol.WirePayload] = []
  for msg in batch {
    frames.push(@protocol.WirePayload::Msg(msg))
  }
  frames.push(
    @protocol.WirePayload::Ok({ request_op: @protocol.Pull, result: b"", }),
  )
  frames
}

///|
/// Shape the refusal of a pull beyond the wait cap: a lone `ERR` carrying
/// the registered `MaxWaitingPulls` code and an actionable message.
pub fn pull_refused() -> @protocol.WirePayload {
  @protocol.WirePayload::Err({
    code: @protocol.MaxWaitingPulls,
    request_op: @protocol.Pull,
    message: b"waiting pull cap reached; await in-flight pulls",
  })
}

///|
/// Clamp a ready batch to the response bounds of one request.
///
/// Takes messages in serve order until `max_msgs` messages are taken or the
/// next message payload bytes (key plus value) would cross `max_bytes`.
/// A message that does not fit stops the batch whole, so no response ever
/// carries a partial message.
pub fn clamp_batch(
  batch : Array[@protocol.MsgPayload],
  max_msgs : UInt16,
  max_bytes : UInt,
) -> Array[@protocol.MsgPayload] {
  let served : Array[@protocol.MsgPayload] = []
  let mut used : UInt = 0U
  for msg in batch {
    if served.length() >= max_msgs.to_int() {
      break
    }
    let size : UInt = msg.key.length().reinterpret_as_uint() +
      msg.value.length().reinterpret_as_uint()
    if used + size > max_bytes {
      break
    }
    served.push(msg)
    used = used + size
  }
  served
}

///|
/// Own the long-poll serving state behind one broker `PULL` path.
pub struct PullService {
  priv queue : PullQueue
} derive(Debug)

///|
pub extend PullService with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Create an empty service over a fresh wait queue.
///
/// Example:
///
/// ```mbt check
/// test {
///   let service = @broker.PullService::new()
///   assert_eq(@broker.PullService::pending_count(service), 0)
/// }
/// ```
pub fn PullService::new() -> PullService {
  { queue: PullQueue::new(), }
}

///|
/// Serve one `PULL` request.
///
/// Parameters:
///
/// * `request` : The decoded pull payload. `wait_ms`, `max_msgs` and
///   `max_bytes` bound this request; the membership, assignment and
///   ownership epochs ride along untouched until the four-epoch model
///   fences them.
/// * `ready` : The messages the record path currently holds for the
///   subscription, in serve order. The service clamps the batch to the
///   request bounds; an empty array means nothing is ready and the request
///   parks or answers empty.
/// * `now_ms` : The monotonic reading the deadline is measured from.
///
/// Returns `Send` with the payloads to write now -- `MSG×N` then `OK`, a
/// lone `OK`, or the `MaxWaitingPulls` refusal -- or `Parked` with the
/// ticket whose terminal path builds the later response.
pub fn PullService::pull(
  self : PullService,
  request : @protocol.PullPayload,
  ready : Array[@protocol.MsgPayload],
  now_ms : UInt64,
) -> PullServe {
  if ready.length() > 0 {
    return PullServe::Send(
      pull_ok(clamp_batch(ready, request.max_msgs, request.max_bytes)),
    )
  }
  if request.wait_ms == 0U.to_uint16() {
    return PullServe::Send(pull_ok([]))
  }
  match
    PullQueue::enqueue(
      self.queue,
      request.member_id,
      request.subscription_id,
      request.wait_ms,
      request.max_msgs,
      request.max_bytes,
      now_ms,
    ) {
    Ok(ticket) => PullServe::Parked(ticket)
    Err(_) => PullServe::Send([pull_refused()])
  }
}

///|
/// Serve the longest-waiting pull of one subscription with a ready batch.
///
/// Call this when data for `subscription_id` became available: the oldest
/// waiter of the subscription takes the batch clamped to its own bounds and
/// its response is `MSG×N` then `OK`. When nothing is waiting, or the batch
/// is empty, no waiter is taken and the caller keeps the data for the next
/// pull.
///
/// Returns the response payloads for the woken waiter, or `None` when the
/// data stays unused.
pub fn PullService::wake(
  self : PullService,
  subscription_id : UInt16,
  ready : Array[@protocol.MsgPayload],
) -> Array[@protocol.WirePayload]? {
  if ready.length() == 0 {
    return None
  }
  match PullQueue::wake_next(self.queue, subscription_id) {
    None => None
    Some(ticket) =>
      Some(pull_ok(clamp_batch(ready, ticket.max_msgs, ticket.max_bytes)))
  }
}

///|
/// Take every waiter whose deadline has elapsed; each answers `OK(empty)`.
///
/// Returns the expired tickets in arrival order; the caller sends one
/// `pull_ok([])` per ticket to the connection that parked it. Pump this on
/// every event-loop turn: after it returns, no waiter is past its deadline,
/// which is the no-hang half of the bounded wait.
pub fn PullService::expire(
  self : PullService,
  now_ms : UInt64,
) -> Array[PullTicket] {
  PullQueue::due(self.queue, now_ms)
}

///|
/// Drop one member waiters for one subscription when its connection closes.
///
/// The dropped tickets are answered by nothing: the connection behind them
/// is gone. Returns them in arrival order so the caller can free their
/// request state.
pub fn PullService::cancel(
  self : PullService,
  member_id : UInt64,
  subscription_id : UInt16,
) -> Array[PullTicket] {
  PullQueue::cancel(self.queue, member_id, subscription_id)
}

///|
/// Count the parked pulls across every member and subscription.
///
/// Returns the depth an operator sees as long-poll pressure: zero means no
/// request is waiting on data or deadline.
pub fn PullService::pending_count(self : PullService) -> Int {
  PullQueue::pending_count(self.queue)
}

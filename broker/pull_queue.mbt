/// Hold the bounded long-poll waiters behind `PULL` and complete them by
/// data or by deadline, so a wait can never outlive its bound.
///
/// A `PULL` that arrives when no message is ready enqueues one waiter with an
/// absolute deadline. The queue owns exactly three terminal paths: `due`
/// returns every waiter whose deadline has elapsed so the request is answered
/// with an empty result; `wake_next` hands one waiter to the record path that
/// just produced data; `cancel` drops a member's waiters when its connection
/// closes. Every deadline is at most `MAX_PULL_WAIT_MS` past its enqueue time
/// and `due` removes every matured waiter, so a waiter survives past its
/// deadline only while the caller stops pumping `due` -- the queue itself
/// never retains one.
///
/// # Stability
///
/// * The wait is bounded at 5000 ms: a larger request is clamped, never
///   refused and never honored at its full length.
/// * At most `MAX_WAITING_PULLS` waiters per member and subscription are
///   held; a further enqueue fails with `MaxWaitingPulls` instead of queueing
///   deeper.
/// * Every terminal path removes waiters in arrival order, so the served
///   order is fair and same-seed runs replay identically.
/// * The queue holds memory state only. Message bytes never enter it; a
///   terminal path returns the ticket and the caller builds the response
///   within the bounds the ticket carries.

///|
/// Bound one long-poll wait at 5000 ms.
///
/// The wire `wait_ms` is a request, not a promise: a larger value is served
/// at this bound so one client cannot park a server response path.
pub const MAX_PULL_WAIT_MS : UInt64 = 5000UL

///|
/// Cap the waiting pulls held per member and subscription at 16.
///
/// The cap bounds server-side queue memory and matches the registered
/// `MaxWaitingPulls` refusal: a seventeenth waiter is rejected rather than
/// queued deeper.
pub const MAX_WAITING_PULLS : Int32 = 16

///|
/// Identify one enqueued long-poll waiter.
///
/// `wait_id` is the queue-local arrival number: increasing from zero, never
/// reused within one queue, and the tie-breaker that makes terminal order
/// deterministic. A ticket is the handle one terminal path returns; it is not
/// valid for a second terminal action. `max_msgs` and `max_bytes` carry the
/// response bounds of the request so the wake path can size its batch
/// without remembering the request elsewhere.
pub(all) struct PullTicket {
  member_id : UInt64
  subscription_id : UInt16
  wait_id : UInt64
  max_msgs : UInt16
  max_bytes : UInt32
} derive(Eq, Debug)

///|
pub extend PullTicket with Eq::{not_equal, equal}

///|
pub extend PullTicket with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Store one waiter until exactly one terminal path takes it.
priv struct WaitingPull {
  ticket : PullTicket
  deadline_ms : UInt64
} derive(Debug)

///|
/// Own the live waiters and the arrival counter behind the queue.
priv struct PullQueueState {
  mut waiting : Array[WaitingPull]
  mut next_wait_id : UInt64
} derive(Debug)

///|
/// Hold the live long-poll waiters of one broker.
///
/// Construct through `PullQueue::new`; a waiter enters only through `enqueue`
/// and leaves only through `due`, `wake_next`, or `cancel`, so every terminal
/// path is named in the API and a waiter cannot be dropped silently.
pub struct PullQueue {
  priv state : Ref[PullQueueState]
} derive(Debug)

///|
pub extend PullQueue with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Create an empty queue whose first ticket carries wait id zero.
///
/// The arrival counter is per queue; two queues never share wait ids.
///
/// Example:
///
/// ```mbt check
/// test {
///   let queue = @broker.PullQueue::new()
///   assert_eq(@broker.PullQueue::pending_count(queue), 0)
/// }
/// ```
pub fn PullQueue::new() -> PullQueue {
  { state: Ref::Ref({ waiting: [], next_wait_id: 0UL, }), }
}

///|
/// Register one waiting pull and return its ticket.
///
/// The deadline is `now_ms` plus the requested wait clamped to
/// `MAX_PULL_WAIT_MS`, so a 20000 ms request completes at 5000 ms exactly
/// like a 5000 ms one. A zero wait enqueues a waiter that is already due, so
/// the immediate-pull empty answer and the timeout answer share one path.
///
/// Parameters:
///
/// * `member_id` : The requesting member; half of the per-member cap key.
/// * `subscription_id` : The subscription being pulled; the other half of
///   the cap key and the filter `wake_next` matches.
/// * `wait_ms` : The requested wait in milliseconds; clamped, not refused,
///   above `MAX_PULL_WAIT_MS`.
/// * `max_msgs` : The response bound on message count; the wake path serves
///   at most this many messages to the ticket.
/// * `max_bytes` : The response bound on payload bytes (key plus value); the
///   wake path stops before the message that would cross it.
/// * `now_ms` : The monotonic reading the deadline is measured from. Read
///   the fake clock in simulations; real adapters pass their own reading.
///
/// Returns the ticket that the terminal paths hand back.
///
/// # Errors
///
/// * `MaxWaitingPulls` -- the member and subscription pair already holds
///   `MAX_WAITING_PULLS` waiters. The request is answered with the
///   registered code so the client waits for its in-flight pulls instead of
///   queueing deeper.
///
/// Example:
///
/// ```mbt check
/// test {
///   let queue = @broker.PullQueue::new()
///   assert_eq(
///     @broker.PullQueue::enqueue(
///       queue,
///       1UL,
///       7,
///       5000U.to_uint16(),
///       65_535U.to_uint16(),
///       1_048_576U,
///       0UL,
///     ),
///     Ok({
///       member_id: 1UL,
///       subscription_id: 7,
///       wait_id: 0UL,
///       max_msgs: 65_535U.to_uint16(),
///       max_bytes: 1_048_576U,
///     }),
///   )
///   assert_eq(
///     @broker.PullQueue::enqueue(
///       queue,
///       1UL,
///       7,
///       5000U.to_uint16(),
///       65_535U.to_uint16(),
///       1_048_576U,
///       0UL,
///     ),
///     Ok({
///       member_id: 1UL,
///       subscription_id: 7,
///       wait_id: 1UL,
///       max_msgs: 65_535U.to_uint16(),
///       max_bytes: 1_048_576U,
///     }),
///   )
/// }
/// ```
pub fn PullQueue::enqueue(
  self : PullQueue,
  member_id : UInt64,
  subscription_id : UInt16,
  wait_ms : UInt16,
  max_msgs : UInt16,
  max_bytes : UInt32,
  now_ms : UInt64,
) -> Result[PullTicket, @protocol.ErrCode] {
  let mut held = 0
  for entry in self.state.val.waiting {
    let ticket = entry.ticket
    if ticket.member_id == member_id &&
      ticket.subscription_id == subscription_id {
      held = held + 1
    }
  }
  if held >= MAX_WAITING_PULLS {
    return Err(@protocol.MaxWaitingPulls)
  }
  let requested = wait_ms.to_uint64()
  let bounded = if requested < MAX_PULL_WAIT_MS {
    requested
  } else {
    MAX_PULL_WAIT_MS
  }
  let ticket = {
    member_id,
    subscription_id,
    wait_id: self.state.val.next_wait_id,
    max_msgs,
    max_bytes,
  }
  self.state.val.next_wait_id = self.state.val.next_wait_id + 1UL
  self.state.val.waiting.push({ ticket, deadline_ms: now_ms + bounded, })
  Ok(ticket)
}

///|
/// Take every waiter whose deadline has elapsed, in arrival order.
///
/// Each returned ticket is answered with an empty result: the bounded wait
/// ran out before data arrived. After the call no waiter with a deadline at
/// or before `now_ms` remains, which is the no-hang guarantee a caller
/// event loop relies on.
///
/// Parameters:
///
/// * `now_ms` : The monotonic reading deadlines are compared against. The
///   comparison includes equality: a waiter due exactly now is returned.
///
/// Returns the expired tickets in arrival order; empty when nothing matured.
///
/// Example:
///
/// ```mbt check
/// test {
///   let queue = @broker.PullQueue::new()
///   let ticket = match
///     @broker.PullQueue::enqueue(
///       queue,
///       1UL,
///       7,
///       5000U.to_uint16(),
///       65_535U.to_uint16(),
///       1_048_576U,
///       0UL,
///     ) {
///     Ok(ticket) => ticket
///     Err(_) => abort("first enqueue must succeed")
///   }
///   assert_eq(@broker.PullQueue::due(queue, 4999UL), [])
///   assert_eq(@broker.PullQueue::due(queue, 5000UL), [ticket])
/// }
/// ```
pub fn PullQueue::due(self : PullQueue, now_ms : UInt64) -> Array[PullTicket] {
  let expired = []
  let kept = []
  for entry in self.state.val.waiting {
    if entry.deadline_ms <= now_ms {
      expired.push(entry.ticket)
    } else {
      kept.push(entry)
    }
  }
  self.state.val.waiting = kept
  expired
}

///|
/// Hand the longest-waiting pull of one subscription to the record path.
///
/// Call this when data for `subscription_id` became available: the returned
/// ticket is served its batch and answered with a result instead of waiting
/// out its deadline. Arrival order is FIFO, so the oldest waiter is served
/// first and a late arrival never overtakes it.
///
/// Parameters:
///
/// * `subscription_id` : The subscription that produced data; waiters of
///   other subscriptions are never taken.
///
/// Returns the oldest waiter of the subscription, or `None` when nothing is
/// waiting -- the caller then keeps the data for the next pull.
///
/// Example:
///
/// ```mbt check
/// test {
///   let queue = @broker.PullQueue::new()
///   let ticket = match
///     @broker.PullQueue::enqueue(
///       queue,
///       1UL,
///       7,
///       5000U.to_uint16(),
///       65_535U.to_uint16(),
///       1_048_576U,
///       0UL,
///     ) {
///     Ok(ticket) => ticket
///     Err(_) => abort("first enqueue must succeed")
///   }
///   assert_eq(@broker.PullQueue::wake_next(queue, 7), Some(ticket))
///   assert_eq(@broker.PullQueue::wake_next(queue, 7), None)
/// }
/// ```
pub fn PullQueue::wake_next(
  self : PullQueue,
  subscription_id : UInt16,
) -> PullTicket? {
  let mut found : Int32? = None
  for index in 0..<self.state.val.waiting.length() {
    let entry = self.state.val.waiting[index]
    if entry.ticket.subscription_id == subscription_id {
      found = Some(index)
      break
    }
  }
  match found {
    None => None
    Some(index) => {
      let entry = self.state.val.waiting[index]
      ignore(self.state.val.waiting.remove(index))
      Some(entry.ticket)
    }
  }
}

///|
/// Drop every waiter of one member and subscription, in arrival order.
///
/// The connection behind a pull can close while the request is still
/// waiting; the terminal path then takes the tickets without answering them.
/// Waiters of the same subscription under other members are kept.
///
/// Parameters:
///
/// * `member_id` : The member whose waiters to drop.
/// * `subscription_id` : The subscription whose waiters to drop.
///
/// Returns the dropped tickets in arrival order; empty when nothing was
/// waiting.
///
/// Example:
///
/// ```mbt check
/// test {
///   let queue = @broker.PullQueue::new()
///   ignore(
///     @broker.PullQueue::enqueue(
///       queue,
///       1UL,
///       7,
///       5000U.to_uint16(),
///       65_535U.to_uint16(),
///       1_048_576U,
///       0UL,
///     ),
///   )
///   ignore(
///     @broker.PullQueue::enqueue(
///       queue,
///       1UL,
///       7,
///       5000U.to_uint16(),
///       65_535U.to_uint16(),
///       1_048_576U,
///       0UL,
///     ),
///   )
///   assert_eq(@broker.PullQueue::cancel(queue, 1UL, 7).length(), 2)
///   assert_eq(@broker.PullQueue::pending_count(queue), 0)
/// }
/// ```
pub fn PullQueue::cancel(
  self : PullQueue,
  member_id : UInt64,
  subscription_id : UInt16,
) -> Array[PullTicket] {
  let dropped = []
  let kept = []
  for entry in self.state.val.waiting {
    let ticket = entry.ticket
    if ticket.member_id == member_id &&
      ticket.subscription_id == subscription_id {
      dropped.push(ticket)
    } else {
      kept.push(entry)
    }
  }
  self.state.val.waiting = kept
  dropped
}

///|
/// Count the waiters currently held across every member and subscription.
///
/// Returns the depth an operator sees as queue pressure: zero means every
/// enqueued waiter has reached a terminal path.
///
/// Example:
///
/// ```mbt check
/// test {
///   let queue = @broker.PullQueue::new()
///   ignore(
///     @broker.PullQueue::enqueue(
///       queue,
///       1UL,
///       7,
///       5000U.to_uint16(),
///       65_535U.to_uint16(),
///       1_048_576U,
///       0UL,
///     ),
///   )
///   assert_eq(@broker.PullQueue::pending_count(queue), 1)
/// }
/// ```
pub fn PullQueue::pending_count(self : PullQueue) -> Int32 {
  self.state.val.waiting.length()
}

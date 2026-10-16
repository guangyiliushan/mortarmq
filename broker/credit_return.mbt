/// Model the client-side credit return policy.
///
/// A client does not return credit per `ACK`: it accumulates what it has
/// processed and sends one `CREDIT` frame when a flush trigger fires.
/// The flush triggers are four, any one of them sufficing: 32 pending
/// messages, 1 MiB pending bytes, the granted budget dropping under the
/// low-water mark, or 20 ms since the first pending return. `CREDIT`
/// only carries the accumulated return (`mode = Add`); it never tops the
/// window back up to its initial size, so an ACK storm cannot become a
/// credit storm (update coalescing).
///
/// This tracker is the policy half of that contract: it accumulates
/// returns and answers when to flush. It holds no transport and no
/// window -- the client's own view of the granted budget is passed into
/// `should_flush`, and the caller sends whatever `take` hands back.
///
/// # Stability
///
/// * A tracker with nothing pending never flushes: every trigger is
///   about returning accumulated credit, and there is none to return.
/// * `take` drains the accumulator completely; the next return starts a
///   fresh 20 ms window from its own first pending tick.
/// * The low-water thresholds are fixed at construction (a ratio of the
///   initial grant) so the flush policy cannot drift with later window
///   reconfigurations.

///|
/// The accumulated return one `CREDIT` frame should carry.
pub(all) struct ReturnedCredit {
  count : UInt16
  bytes : UInt32
} derive(Eq, Debug)

///|
pub extend ReturnedCredit with Eq::{not_equal, equal}

///|
pub extend ReturnedCredit with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The mutable accumulators of one tracker.
priv struct ReturnCore {
  mut pending_count : UInt16
  mut pending_bytes : UInt32
  mut first_pending_ms : UInt64
  mut has_pending : Bool
}

///|
/// Decide when a client returns accumulated credit.
///
/// Build with `CreditReturnTracker::new` for explicit policy values or
/// `CreditReturnTracker::with_window_defaults` for the default parameter
/// table.
pub struct CreditReturnTracker {
  priv flush_count : UInt16
  priv flush_bytes : UInt32
  priv low_count : UInt16
  priv low_bytes : UInt32
  priv max_delay_ms : UInt64
  priv core : Ref[ReturnCore]
}

///|
/// Build a tracker with explicit flush thresholds.
///
/// `flush_count` / `flush_bytes` are the batch triggers (defaults 32
/// messages / 1 MiB), `low_count` / `low_bytes` the low-water marks the
/// granted budget is compared against (default 25% of the initial
/// grant), and `max_delay_ms` the deadline since the first pending
/// return (default 20 ms).
pub fn CreditReturnTracker::new(
  flush_count : UInt16,
  flush_bytes : UInt32,
  low_count : UInt16,
  low_bytes : UInt32,
  max_delay_ms : UInt64,
) -> CreditReturnTracker {
  {
    flush_count,
    flush_bytes,
    low_count,
    low_bytes,
    max_delay_ms,
    core: Ref::Ref({
      pending_count: 0U.to_uint16(),
      pending_bytes: 0U,
      first_pending_ms: 0UL,
      has_pending: false,
    }),
  }
}

///|
/// Build a tracker from the default parameter table for a window opened
/// with the given initial grant: flush at 32 messages or 1 MiB, flush
/// early when the granted budget drops under 25% of the initial grant,
/// and flush at the latest 20 ms after the first pending return.
///
/// Example:
///
/// ```mbt check
/// test {
///   let tracker = @broker.CreditReturnTracker::with_window_defaults(
///     256U.to_uint16(),
///     2097152U,
///   )
///   @broker.CreditReturnTracker::record_ack(tracker, 0UL, 4096U)
///   assert_eq(
///     @broker.CreditReturnTracker::should_flush(
///       tracker,
///       19UL,
///       256U.to_uint16(),
///       2097152U,
///     ),
///     false,
///   )
///   assert_eq(
///     @broker.CreditReturnTracker::should_flush(
///       tracker,
///       20UL,
///       256U.to_uint16(),
///       2097152U,
///     ),
///     true,
///   )
/// }
/// ```
pub fn CreditReturnTracker::with_window_defaults(
  initial_count : UInt16,
  initial_bytes : UInt32,
) -> CreditReturnTracker {
  CreditReturnTracker::new(
    32U.to_uint16(),
    0x00100000U,
    (initial_count.to_uint() / 4U).to_uint16(),
    initial_bytes / 4U,
    20UL,
  )
}

///|
/// Accumulate one processed message: the client has taken delivery of
/// `msg_bytes` (`key_len + value_len`) and will return its credit with
/// the next flush. The first call since the last `take` starts the 20 ms
/// deadline.
pub fn CreditReturnTracker::record_ack(
  self : CreditReturnTracker,
  now_ms : UInt64,
  msg_bytes : UInt32,
) -> Unit {
  if !self.core.val.has_pending {
    self.core.val.has_pending = true
    self.core.val.first_pending_ms = now_ms
  }
  self.core.val.pending_count = (self.core.val.pending_count.to_uint() + 1U).to_uint16()
  self.core.val.pending_bytes = self.core.val.pending_bytes + msg_bytes
}

///|
/// Answer whether a `CREDIT` frame should go out now, given the client's
/// view of the granted budget.
///
/// The four flush triggers, any one sufficing: 32 pending messages, 1
/// MiB pending bytes (with the defaults), `available_count` under
/// the low-water mark, `available_bytes` under the low-water mark, or 20
/// ms (the configured deadline) elapsed since the first pending return.
/// With nothing pending the answer is always false.
pub fn CreditReturnTracker::should_flush(
  self : CreditReturnTracker,
  now_ms : UInt64,
  available_count : UInt16,
  available_bytes : UInt32,
) -> Bool {
  if !self.core.val.has_pending {
    return false
  }
  if self.core.val.pending_count >= self.flush_count {
    return true
  }
  if self.core.val.pending_bytes >= self.flush_bytes {
    return true
  }
  if available_count < self.low_count {
    return true
  }
  if available_bytes < self.low_bytes {
    return true
  }
  now_ms >= self.core.val.first_pending_ms + self.max_delay_ms
}

///|
/// Take the accumulated return for one `CREDIT` frame and reset the
/// accumulator. Returns `None` when nothing is pending; the caller sends
/// `mode = Add` with the taken amounts.
pub fn CreditReturnTracker::take(self : CreditReturnTracker) -> ReturnedCredit? {
  if !self.core.val.has_pending {
    return None
  }
  let returned = {
    count: self.core.val.pending_count,
    bytes: self.core.val.pending_bytes,
  }
  self.core.val.pending_count = 0U.to_uint16()
  self.core.val.pending_bytes = 0U
  self.core.val.first_pending_ms = 0UL
  self.core.val.has_pending = false
  Some(returned)
}

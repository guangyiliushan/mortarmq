/// Reconnect the client after a disconnect: the backoff schedule and the
/// full-state renegotiation plan that rebuilds the session.
///
/// The reconnect backoff is the frozen schedule `500ms * 2^n + jitter`
/// capped at 30s, counted from `n` 0 so the first reconnect waits 500ms.
/// The jitter is additive, drawn from `0..=delay/4` through the injected
/// RNG -- the same form the delivery retry backoff freezes, so one house
/// rule covers both schedules. The schedule function owns no clock and no
/// randomness: the surrounding loop times `BackoffExpired` and supplies
/// the RNG, keeping the numbers a pure table.
///
/// The renegotiation plan is the full-state recovery the connection
/// diagram notes: `CONNECT(token)`, then the complete subscription set,
/// each subscription carrying its initial credit window (the window is
/// reset by the SUB itself) and its resume position at the saved
/// `ack_floor` (the cursor derives from `ack_floor`, so resuming there
/// never regresses).
///
/// # Stability
///
/// * The plan is a pure projection of the saved intent: the same
///   subscriptions and token always produce the same steps, in order,
///   with no step dropped and none invented.
/// * A subscription's credit fields and cursor travel with it: the plan
///   never mutates a saved subscription.

///|
const RECONNECT_BACKOFF_BASE_MS : UInt = 500U

///|
const RECONNECT_BACKOFF_CAP_MS : UInt = 30000U

///|
/// The durable intent of one subscription the reconnect must restore.
///
/// The wire fields mirror the SUB payload; `ack_floor` is the consumer
/// cursor the resume position derives from, kept here because the
/// reconnect must restore it and never let it regress.
pub(all) struct Subscription {
  group : Bytes
  topic_id : UInt16
  partition : UInt16
  start_policy : Byte
  credit_count : UInt16
  credit_bytes : UInt
  flags : UInt16
  ack_floor : UInt64
} derive(Eq, Debug)

///|
pub extend Subscription with Eq::{not_equal, equal}

///|
pub extend Subscription with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One step of the renegotiation plan, in send order.
///
/// `Connect` opens the re-established session with the saved token;
/// `Resubscribe` re-sends one subscription with its credit window and
/// its resume position intact.
pub(all) enum RenewalStep {
  Connect(BytesView)
  Resubscribe(Subscription)
} derive(Eq, Debug)

///|
pub extend RenewalStep with Eq::{not_equal, equal}

///|
pub extend RenewalStep with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The reconnect delay before one attempt: `500ms * 2^n + jitter`,
/// capped at 30s.
///
/// The base grows `500 * 2^attempt` until it reaches the cap and then
/// stays there; the additive jitter is drawn from `0..=base/4` through
/// `rng`, the frozen delivery-retry form. Attempt 0 is the first
/// reconnect and waits 500ms before its jitter.
///
/// Parameters:
///
/// * `attempt` : The reconnect attempt number, counting from zero.
/// * `rng` : The randomness source the jitter is drawn from.
///
/// Returns the delay in milliseconds.
///
/// Example:
///
/// ```mbt nocheck
/// // with a zero-valued RNG the schedule is exactly 500, 1000, 2000, ...
/// let delay = reconnect_delay(0, rng)
/// ```
pub fn[R : @harness.Rng] reconnect_delay(attempt : UInt16, rng : R) -> UInt {
  let mut base = RECONNECT_BACKOFF_BASE_MS
  for _ in 0..<attempt.to_int() {
    if base >= RECONNECT_BACKOFF_CAP_MS {
      break
    }
    base = base * 2
    if base > RECONNECT_BACKOFF_CAP_MS {
      base = RECONNECT_BACKOFF_CAP_MS
    }
  }
  let jitter_span = base / 4
  let jitter = (rng.next_uint64() % (jitter_span + 1).to_uint64()).to_uint()
  base + jitter
}

///|
/// Plan the full-state renegotiation after a reconnect.
///
/// The plan is the documented recovery order: one `Connect` carrying the
/// saved token, then one `Resubscribe` per saved subscription in save
/// order. Each resubscription carries its own initial credit window (the
/// window is reset by the SUB itself) and its resume position at the
/// saved `ack_floor`, so every assertion of the reconnect golden is a
/// property of this projection.
///
/// Parameters:
///
/// * `token` : The saved authentication token the session re-opens with.
/// * `subs` : The saved subscription set, in the order they must be
///   re-established.
///
/// Returns the ordered step list.
///
/// Example:
///
/// ```mbt check
/// test {
///   let plan = @client.plan_renewal(b"tok"[:], [])
///   assert_eq(plan.length(), 1)
///   assert_eq(plan[0], @client.Connect(b"tok"[:]))
/// }
/// ```
pub fn plan_renewal(
  token : BytesView,
  subs : Array[Subscription],
) -> Array[RenewalStep] {
  let plan : Array[RenewalStep] = Array(capacity=1 + subs.length())
  plan.push(Connect(token))
  for index in 0..<subs.length() {
    plan.push(Resubscribe(subs[index]))
  }
  plan
}

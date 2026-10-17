/// Send one matured retry through the credit gate (redelivery counts
/// credit).
///
/// The retry path ends at `RetryTimers::due`, which hands back the
/// keys whose backoff matured. This is the next hop before anything is
/// billed or sent: the popped key is re-checked (the frozen timer
/// contract -- "the executor must re-check the entry's current state
/// before it redelivers"), then the attempt goes through the credit gate
/// exactly like a first delivery, keeping the
/// single "delivered <= window" invariant, and only a booked attempt
/// reaches `DeliveryMachine::begin_delivery`, which charges it on the
/// ledger as `attempt + 1`.
///
/// # Stability
///
/// * A gate refusal (`NoCredit`, `StaleGeneration`, `MessageExceedsCredit`)
///   sends nothing and bills nothing: the entry stays `RetryScheduled`
///   and the timer path may try again later ("信用耗尽时
///   MSG 停发").
/// * A key that is not `RetryScheduled` (already acked, still delivering,
///   dead-lettered) is refused before the gate: no credit is booked for a
///   send that cannot happen.
/// * The gate is the caller's `CreditRegistry` (S6 owns it; this path
///   only calls). `ownership_generation` is the coordinator's wholesale
///   generation, so a stale-subscription retry is refused by the
///   same fence as a fresh delivery.

///|
/// Report why one redelivery attempt did not reach the wire.
pub(all) suberror RedeliverError {
  /// The credit gate refused the attempt; nothing was billed.
  CreditRefused(CreditError)
  /// The delivery machine refused the attempt after the gate booked it.
  /// The booked tranche unwinds through the normal return triggers or an
  /// ownership-change release.
  DeliveryFailed(@delivery.DeliveryError)
} derive(Eq, Debug)

///|
pub extend RedeliverError with Eq::{not_equal, equal}

///|
pub extend RedeliverError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Re-check, gate, and bill one matured retry.
///
/// Parameters:
///
/// * `machine` : The partition delivery machine holding the entry.
/// * `registry` : The credit registry (the credit gate).
/// * `key` : The matured timer key; only a `RetryScheduled` entry passes.
/// * `subscription_id` : The window to bill.
/// * `owner_conn` : The connection the redelivery goes out on.
/// * `owner_epoch` : The ownership epoch the attempt is booked under.
/// * `ownership_generation` : The wholesale generation the window
///   is validated against.
/// * `msg_bytes` : The message size the gate books (key plus value).
///
/// Returns the delivery attempt the ledger booked (`attempt + 1`).
///
/// # Errors
///
/// * `CreditRefused` -- the gate refused; nothing was billed or sent.
/// * `DeliveryFailed` -- the machine refused the attempt.
///
/// Example:
///
/// ```mbt nocheck
/// // The executor's due-timer hop, once per popped key:
/// // let attempt = await redeliver_one(machine, registry, disk, key, ...)
/// ```
pub async fn[D : @ports.Disk] redeliver_one(
  machine : @delivery.DeliveryMachine,
  registry : CreditRegistry,
  disk : D,
  key : @delivery.DeliveryKey,
  subscription_id : UInt16,
  owner_conn : UInt64,
  owner_epoch : UInt64,
  ownership_generation : UInt64,
  msg_bytes : UInt32,
  now_unix_ms : UInt64,
  watermark : @storage.Watermark?,
) -> Result[@delivery.DeliveryAttempt, RedeliverError] {
  // 1. The timer contract: only a matured retry redelivers, so a stale
  //    due-timer never bills credit for a send that cannot happen.
  match @delivery.DeliveryMachine::state_of(machine, key) {
    Some(@delivery.DeliveryState::RetryScheduled(_)) => ()
    _ => return Err(DeliveryFailed(@delivery.DeliveryError::InvalidTransition))
  }
  // 2. The gate books the attempt's credit (a redelivery counts).
  match
    CreditRegistry::admit(
      registry,
      subscription_id,
      key.partition,
      owner_epoch,
      ownership_generation,
      msg_bytes,
    ) {
    Ok(_) => ()
    Err(code) => return Err(CreditRefused(code))
  }
  // 3. Only now is the attempt charged on the ledger (attempt + 1).
  match
    @delivery.DeliveryMachine::begin_delivery(
      machine, disk, key, owner_conn, now_unix_ms, watermark,
    ) {
    Ok(attempt) => Ok(attempt)
    Err(code) => Err(DeliveryFailed(code))
  }
}

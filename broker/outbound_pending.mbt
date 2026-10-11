/// Track the approximate outbound pending bytes of one connection.
///
/// `moonbitlang/async` 0.20.2 exposes no outbound queued/byte
/// statistics on its socket and io surface, so the soft/hard pending
/// judgement is fed by an application-level approximation: the sending
/// path itself counts `bytes_queued - bytes_written`, where `written`
/// accumulates the byte counts `write_once` returns. The threshold
/// semantics stay exactly as designed -- soft slow at 75% of the hard
/// limit, hard slow above the hard limit (the connection
/// backpressure state machine, NATS-style) -- and this counter is the
/// gauge they read.
///
/// # Counting accuracy
///
/// * `pending_bytes` is an **approximation that excludes kernel
///   buffers**. It measures what the application has handed to the
///   transport and not yet seen accepted back: once `write_once`
///   returns, those bytes are counted as written even though the OS
///   socket buffer may still hold them. The gauge therefore
///   under-counts true resident socket memory and never over-counts it.
/// * `written` is the transport's return value, not a peer
///   acknowledgement: a peer that stops reading still leaves the
///   kernel draining at its own pace, so the gauge can read zero while
///   a slow consumer is already the bottleneck. That is why the hard
///   limit also has the write-deadline escape of the state machine
///   (a deadline exceeded jumps straight to hard slow).
/// * The counter saturates at zero: a transport that reports more
///   written than queued is a caller bug, and the gauge floors rather
///   than wrapping.
/// * If a future `moonbitlang/async` exposes real socket statistics the
///   judgement can be tightened to them without changing the threshold
///   semantics.
///
/// # Boundaries
///
/// The counter classifies; it never acts. Stopping new `MSG` at soft
/// slow and closing the slow consumer at hard slow (`SLOW_CONSUMER`
/// 0x4007) are the connection state machine's moves, as is the
/// recovery-watermark hysteresis back to normal -- `level` is a raw
/// classification of the current gauge against the two thresholds.

///|
/// The classification of the outbound gauge against the two thresholds.
pub(all) enum PendingLevel {
  Normal
  SoftSlow
  HardSlow
} derive(Eq, Debug)

///|
pub extend PendingLevel with Eq::{not_equal, equal}

///|
pub extend PendingLevel with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The mutable gauge of one connection.
priv struct PendingCore {
  mut queued_bytes : UInt
  mut written_bytes : UInt
}

///|
/// Count the outbound pending bytes of one connection.
///
/// Build with `OutboundPending::new` for explicit thresholds or
/// `OutboundPending::with_defaults` for the default parameter table
/// (soft 75% of a 64 MiB hard limit).
pub struct OutboundPending {
  priv soft_bytes : UInt
  priv hard_bytes : UInt
  priv core : Ref[PendingCore]
}

///|
/// Open a gauge with explicit thresholds.
///
/// `soft_bytes` is where soft slow begins (inclusive) and `hard_bytes`
/// is where hard slow begins (exclusive), matching the state machine's
/// `>= 75%` entry and `> hard` escalation. The contract is
/// `soft_bytes <= hard_bytes`; the constructor does not police it.
pub fn OutboundPending::new(
  soft_bytes : UInt,
  hard_bytes : UInt,
) -> OutboundPending {
  {
    soft_bytes,
    hard_bytes,
    core: Ref::Ref({ queued_bytes: 0U, written_bytes: 0U, }),
  }
}

///|
/// Open a gauge at the default parameter set: soft slow at 75%
/// of the hard limit, hard limit 64 MiB (the NATS default the table
/// adopted).
///
/// Example:
///
/// ```mbt check
/// test {
///   let gauge = @broker.OutboundPending::with_defaults()
///   assert_eq(@broker.OutboundPending::queued(gauge, 50331648U), @broker.SoftSlow)
///   assert_eq(@broker.OutboundPending::pending_bytes(gauge), 50331648U)
/// }
/// ```
pub fn OutboundPending::with_defaults() -> OutboundPending {
  // 75% of 64 MiB is 48 MiB, kept as literals so the product never
  // overflows the 32-bit gauge arithmetic.
  OutboundPending::new(50331648U, 67108864U)
}

///|
/// Count `bytes` as handed to the transport and classify the gauge.
///
/// Call this when a write is queued to the transport; the returned
/// level is the current soft/hard judgement for the caller to act on
/// (stop new `MSG` at soft slow). The counter itself never acts.
pub fn OutboundPending::queued(
  self : OutboundPending,
  bytes : UInt,
) -> PendingLevel {
  self.core.val.queued_bytes = self.core.val.queued_bytes + bytes
  self.level()
}

///|
/// Count `bytes` as accepted by the transport -- the return value of
/// `write_once` accumulated over the sending path.
///
/// The subtraction saturates at zero: more written than queued is a
/// caller bug and the gauge floors rather than wrapping.
pub fn OutboundPending::written(self : OutboundPending, bytes : UInt) -> Unit {
  let pending = self.pending_bytes()
  self.core.val.written_bytes = if bytes > pending {
    self.core.val.queued_bytes
  } else {
    self.core.val.written_bytes + bytes
  }
}

///|
/// Read the approximate gauge: queued minus written. See the module
/// note for what the approximation does and does not cover.
pub fn OutboundPending::pending_bytes(self : OutboundPending) -> UInt {
  self.core.val.queued_bytes - self.core.val.written_bytes
}

///|
/// Classify the current gauge: `SoftSlow` from `soft_bytes` inclusive
/// upward, `HardSlow` strictly above `hard_bytes`, `Normal` below.
pub fn OutboundPending::level(self : OutboundPending) -> PendingLevel {
  let pending = self.pending_bytes()
  if pending > self.hard_bytes {
    HardSlow
  } else if pending >= self.soft_bytes {
    SoftSlow
  } else {
    Normal
  }
}

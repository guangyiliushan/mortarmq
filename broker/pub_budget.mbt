/// Bound the outstanding PUB budget of one connection (T110,
/// REQ-DEL-007 producer overload, hard decision 5).
///
/// A connection keeps a bounded number and volume of accepted-but-not
/// yet completed PUBs: every accepted PUB occupies `outstanding_count`
/// and `outstanding_bytes` until its `PUB OK` or `PUB ERR` completes,
/// and over-budget PUBs are refused explicitly with a registered,
/// actionable code before anything can pile up toward an out-of-memory
/// condition. A refused PUB is never accepted and never dropped
/// silently -- the record is not appended and the producer is told
/// exactly why (decision 5: refuse by backpressure first).
///
/// The budget is the connection-scoped protection from the A07
/// producer section: `conn_max_outstanding_pub_count` guards against a
/// flood of un-quorumed publishes and `conn_max_outstanding_pub_bytes`
/// guards leader and replication memory. The rate token bucket, the
/// storage high watermark and the replication read-only gate sit next
/// to this one in the admission chain and refuse with their own codes
/// (0x4003 / 0x4004 / 0x6002); this module owns only the budget pair.
/// A producer that self-throttles at 80% is being polite, not correct:
/// the broker never depends on it.
///
/// # Errors
///
/// * `OverBudgetCount` -- `outstanding_count` reached the count cap;
///   the producer should back off and retry (0x4001).
/// * `OverBudgetBytes` -- this payload would push `outstanding_bytes`
///   past the byte cap; the producer should slow down (0x4002).
///
/// # Stability
///
/// * The count cap is exclusive of the caller's next accept: the budget
///   refuses once `outstanding_count >= max_count`, so at most
///   `max_count` PUBs occupy the connection at any time.
/// * The byte cap is exact: a payload that would land
///   `outstanding_bytes` exactly on `max_bytes` is accepted, one byte
///   more is refused. The check subtracts rather than adds so a huge
///   payload cannot overflow the gauge arithmetic.
/// * `complete` saturates: a completion that reports more bytes than
///   are outstanding floors the gauge at zero instead of wrapping, and
///   the count refuses to underflow.

///|
/// Refuse a PUB with the reason the producer must act on.
pub(all) enum PubError {
  OverBudgetCount
  OverBudgetBytes
} derive(Eq, Debug)

///|
pub extend PubError with Eq::{not_equal, equal}

///|
pub extend PubError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Translate one budget refusal into the registered wire code.
///
/// `OverBudgetCount` becomes `BACKPRESSURE` (0x4001, back off and
/// retry) and `OverBudgetBytes` becomes `QUOTA_EXCEEDED` (0x4002, slow
/// down) -- the two producer-overload codes REQ-DEL-007 names, both
/// already registered with distinct client actions. The A07 admission
/// notes collapse both budget checks onto `BACKPRESSURE`; the split
/// follows the registry's distinct actions so a volume-stalled producer
/// is told to slow down rather than to retry harder. Zero new codes.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(
///     @broker.PubError::OverBudgetCount.to_err_code(),
///     @protocol.Backpressure,
///   )
///   assert_eq(
///     @broker.PubError::OverBudgetBytes.to_err_code(),
///     @protocol.QuotaExceeded,
///   )
/// }
/// ```
pub fn PubError::to_err_code(self : PubError) -> @protocol.ErrCode {
  match self {
    OverBudgetCount => @protocol.Backpressure
    OverBudgetBytes => @protocol.QuotaExceeded
  }
}

///|
/// Copy the occupancy of one budget: how many PUBs are accepted but not
/// yet complete, and how many bytes they occupy.
pub(all) struct PubReport {
  outstanding_count : UInt16
  outstanding_bytes : UInt
} derive(Eq, Debug)

///|
pub extend PubReport with Eq::{not_equal, equal}

///|
pub extend PubReport with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The mutable occupancy of one budget.
priv struct PubCore {
  mut outstanding_count : UInt16
  mut outstanding_bytes : UInt
}

///|
/// Count the outstanding PUBs of one connection against its caps.
///
/// Build with `PubBudget::new` for explicit caps or
/// `PubBudget::with_defaults` for the A07 parameter table.
pub struct PubBudget {
  priv max_count : UInt16
  priv max_bytes : UInt
  priv core : Ref[PubCore]
}

///|
/// Open a budget with explicit caps.
///
/// `max_count` is the most PUBs that may be outstanding at once (A07
/// default 256) and `max_bytes` the most bytes they may occupy (A07
/// default 8 MiB).
pub fn PubBudget::new(max_count : UInt16, max_bytes : UInt) -> PubBudget {
  {
    max_count,
    max_bytes,
    core: Ref::Ref({ outstanding_count: 0U.to_uint16(), outstanding_bytes: 0U, }),
  }
}

///|
/// Open a budget at the A07 parameter table defaults: 256 outstanding
/// PUBs or 8 MiB of un-completed publish volume per connection.
pub fn PubBudget::with_defaults() -> PubBudget {
  PubBudget::new(256U.to_uint16(), 8388608U)
}

///|
/// Take one PUB into the budget, or refuse it explicitly.
///
/// `pub_bytes` is the publish payload volume the connection will hold
/// until completion. On success the PUB occupies the budget until
/// `complete` runs for it; on refusal nothing is occupied and the
/// producer keeps the record (nothing is appended, nothing is dropped).
pub fn PubBudget::admit(
  self : PubBudget,
  pub_bytes : UInt,
) -> Result[Unit, PubError] {
  if self.core.val.outstanding_count.to_uint() >= self.max_count.to_uint() {
    return Err(OverBudgetCount)
  }
  // Compare by subtraction so an oversized payload cannot overflow the
  // gauge sum; outstanding never exceeds max, so the room is safe.
  if pub_bytes > self.max_bytes - self.core.val.outstanding_bytes {
    return Err(OverBudgetBytes)
  }
  self.core.val.outstanding_count = (self.core.val.outstanding_count.to_uint() +
  1U).to_uint16()
  self.core.val.outstanding_bytes = self.core.val.outstanding_bytes + pub_bytes
  Ok(())
}

///|
/// Release one completed PUB -- the `PUB OK` or `PUB ERR` path -- back
/// out of the budget.
///
/// The subtraction saturates on both gauges: a completion that reports
/// more than the budget holds is a caller bug and the gauges floor
/// instead of wrapping.
pub fn PubBudget::complete(self : PubBudget, pub_bytes : UInt) -> Unit {
  self.core.val.outstanding_count = if self.core.val.outstanding_count.to_uint() ==
    0U {
    0U.to_uint16()
  } else {
    (self.core.val.outstanding_count.to_uint() - 1U).to_uint16()
  }
  self.core.val.outstanding_bytes = if pub_bytes >
    self.core.val.outstanding_bytes {
    0U
  } else {
    self.core.val.outstanding_bytes - pub_bytes
  }
}

///|
/// Copy the occupancy for a report or an invariant check.
pub fn PubBudget::report(self : PubBudget) -> PubReport {
  {
    outstanding_count: self.core.val.outstanding_count,
    outstanding_bytes: self.core.val.outstanding_bytes,
  }
}

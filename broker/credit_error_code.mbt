/// Map every credit-window refusal onto the registered wire code (T053,
/// REQ-DEL-007, hard decision 5).
///
/// Hard decision 5 says overload is refused explicitly first and the
/// system degrades before it can run out of memory; REQ-DEL-007 turns
/// that into a wire contract: a refusal must carry a registered code
/// whose table entry tells the client what to do (back off, slow down,
/// raise `credit_bytes`, re-`SUB`), and a message is never dropped
/// silently. This file is the T053 mapping surface: the mechanism-level
/// `CreditError` values of the A07 credit algorithm translated to the
/// codes that are already registered in `protocol/errcode.mbt`. The
/// 0x4xxx backpressure and quota range stays exactly as registered --
/// zero new codes.
///
/// # Stability
///
/// * Every mapping target is a registered code by construction: this
///   module names only constructors of `ErrCode`, and the registry's own
///   bijection property test owns the wire values. The membership test
///   in `credit_error_code_test.mbt` proves the pairing through
///   `from_uint16` rather than trusting names.
/// * The mapping is total and injective: each `CreditError` constructor
///   has exactly one code and no two constructors share one, so a client
///   can dispatch on the code without a side table.
/// * One mapping is a documented stretch: `UnknownSubscription` has no
///   successor in the 0x4xxx range (the old research-note code
///   SUBSCRIPTION_CREDIT_UNKNOWN 0x7005 was never registered on the
///   wire, and the ruled 0x70xx note maps that family onto 0x4001-0x4007
///   without covering an unknown subscription). It maps to `StaleOwner`
///   (0x0022) because that code's registered client action -- re-SUB /
///   re-PULL -- is exactly how a client rebuilds a discarded credit
///   window. The registry entry keeps its meaning; this module states
///   the stretch instead of inventing a code.

///|
/// Translate one credit refusal into the registered wire code.
///
/// `Backpressure` becomes 0x4001 (back off and retry), `NoCredit` 0x4006
/// (send CREDIT), `MessageExceedsCredit` 0x4005 (raise `credit_bytes`),
/// `StaleGeneration` 0x0020 (wait for NOTICE, then re-negotiate), and
/// `UnknownSubscription` 0x0022 `StaleOwner` (re-SUB / re-PULL -- see
/// the module note).
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@broker.CreditError::NoCredit.to_err_code(), @protocol.NoCredit)
///   assert_eq(
///     @protocol.ErrCode::from_uint16(
///       @broker.CreditError::Backpressure.to_err_code().to_uint16(),
///     ),
///     Some(@protocol.Backpressure),
///   )
/// }
/// ```
pub fn CreditError::to_err_code(self : CreditError) -> @protocol.ErrCode {
  match self {
    Backpressure => @protocol.Backpressure
    NoCredit => @protocol.NoCredit
    MessageExceedsCredit => @protocol.MessageExceedsCredit
    StaleGeneration => @protocol.StaleGeneration
    UnknownSubscription => @protocol.StaleOwner
  }
}

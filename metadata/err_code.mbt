/// Map every metadata-domain refusal onto the registered wire code.
///
/// The 49-code table is the single global registry:
/// every refusal a client can observe carries a registered code whose
/// table entry says what the client should do, and unregistered
/// segments stay reserved. This file is the metadata mapping surface,
/// mirroring the form of `broker/credit_error_code.mbt`: the
/// mechanism-level `MetadataFault` values of the MMML trust boundary
/// translated to constructors that already exist in
/// `protocol/errcode.mbt`. The 0x2xxx metadata range stays exactly as
/// registered -- zero new codes, zero raw numeric literals.
///
/// # Stability
///
/// * Every mapping target is a registered code by construction: this
///   module names only constructors of `ErrCode`, and the registry's
///   own bijection property test owns the wire values. The membership
///   test in `err_code_test.mbt` proves the pairing through
///   `from_uint16` rather than trusting names.
/// * The mapping is total and injective: each `MetadataFault`
///   constructor has exactly one code and no two constructors share
///   one, so a client can dispatch on the code without a side table.
/// * `Corruption` maps to the first-stage read-only response
///   (0x2003 METADATA_READ_ONLY, retry later); the escalated 0x2004
///   (human intervention) is owned by the guard state machine
///   (`MetadataGuard::write_refusal`), never guessed from one fault.

///|
/// Translate one metadata fault into the registered wire code.
///
/// `Malformed` becomes 0x0003 (MalformedPayload: fix the client),
/// `Corruption` 0x2003 (MetadataReadOnly: retry later, the first-stage
/// response), and `DiskFault` 0x000A (Internal: file an issue
/// carrying the diagnostic code).
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@metadata.Malformed.to_err_code(), @protocol.MalformedPayload)
///   assert_eq(
///     @protocol.ErrCode::from_uint16(
///       @metadata.Corruption(64U).to_err_code().to_uint16(),
///     ),
///     Some(@protocol.MetadataReadOnly),
///   )
/// }
/// ```
pub fn MetadataFault::to_err_code(self : MetadataFault) -> @protocol.ErrCode {
  match self {
    Malformed => @protocol.MalformedPayload
    Corruption(_) => @protocol.MetadataReadOnly
    DiskFault(_) => @protocol.Internal
  }
}

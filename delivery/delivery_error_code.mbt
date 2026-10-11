/// Map every delivery refusal onto the registered wire code.
///
/// The delivery layer's mechanism-level `DeliveryError` values translate
/// to codes already registered in the protocol table -- zero new codes.
/// The mapping is total: every constructor lands on a registered code
/// whose table entry tells the client what to do. Two targets are shared
/// on purpose: `AlreadyAcked` and `AlreadyDeadLettered` join
/// `UnknownDelivery` in the 0x0023 idempotent-no-op family (there is
/// nothing left for the client to do), and `InvalidTransition` joins
/// `DiskFault` in `Internal` (executor or storage facts, never client
/// actions). `Capacity` is the registered 0x4004 STORAGE_HIGH_WATERMARK
/// refusal and `DlqUnavailable` the registered 0x0031 retry path.

///|
/// Translate one delivery refusal into the registered wire code.
///
/// `UnknownDelivery` becomes 0x0023 (idempotent no-op), `StaleOwner`
/// 0x0022 (re-SUB / re-PULL), `DlqPathOverflow` 0x0030 (quarantine,
/// human intervention), `DlqUnavailable` 0x0031 (back off and retry --
/// the source is kept), `Capacity` 0x4004 (retry later; the high
/// watermark is a write-side refusal only), `Malformed` the registered
/// malformed-payload code, and the remaining constructor-logic and disk
/// facts map to `Internal`.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(
///     @delivery.DeliveryError::Capacity.to_err_code(),
///     @protocol.StorageHighWatermark,
///   )
///   assert_eq(
///     @protocol.ErrCode::from_uint16(
///       @delivery.DeliveryError::DlqUnavailable.to_err_code().to_uint16(),
///     ),
///     Some(@protocol.DlqUnavailable),
///   )
/// }
/// ```
pub fn DeliveryError::to_err_code(self : DeliveryError) -> @protocol.ErrCode {
  match self {
    UnknownDelivery => @protocol.UnknownDelivery
    StaleOwner => @protocol.StaleOwner
    AlreadyAcked => @protocol.UnknownDelivery
    AlreadyDeadLettered => @protocol.UnknownDelivery
    InvalidTransition => @protocol.Internal
    DlqPathOverflow => @protocol.DlqPathOverflow
    DlqUnavailable => @protocol.DlqUnavailable
    Capacity => @protocol.StorageHighWatermark
    Malformed => @protocol.MalformedPayload
    DiskFault(_) => @protocol.Internal
  }
}

/// Hold the durable-storage high watermark and gate appends before they run.
///
/// The gate is the shared pre-write check of the volume's writers (segment
/// appends and the delivery ledger alike): usage is volume-level, with
/// segments and ledger bytes counted together and no per-file-type split,
/// and the check runs before any disk operation so a refusal never leaves
/// half a record behind. Tier policy is fixed at three thresholds: under
/// 70% normal,
/// 70--85% warning (writes still land), 85--95% producer writes are
/// rejected with `AppendFault::Capacity`, and at 95% and above the volume is
/// read-only -- only recovery and retention work may still run, which the
/// layers above enforce. The wire mapping of a refusal to 0x4004
/// STORAGE_HIGH_WATERMARK belongs to the protocol/delivery layer; this
/// module never produces wire codes. The gate is the backstop for v0's
/// unbounded append-only growth (the boundary is stated in
/// `storage/retention`): explicit refusals, never an OOM, never a silent
/// drop.
///
/// The gate is stateless over its `DiskUsage` source: every call reads the
/// usage now, so several gates over one volume always agree. A zero
/// `total_bytes` means "no capacity configured" and is treated as
/// unlimited.

///|
/// The volume's position against the three watermark thresholds.
pub(all) enum WatermarkTier {
  /// Usage below the warning threshold.
  Normal
  /// Usage at or above the warning threshold: alert and shed background work.
  Warn
  /// Usage at or above the high watermark: producer writes are refused.
  High
  /// Usage at or above the read-only threshold: only recovery/retention.
  Full
} derive(Eq, Debug)

///|
pub extend WatermarkTier with Eq::{not_equal, equal}

///|
pub extend WatermarkTier with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A stateless watermark gate over one volume's usage source.
///
/// The gate holds a trait reference, so it carries no `Debug` derive; the
/// tier and percent accessors are the observable face.
pub(all) struct Watermark {
  usage : &@harness.DiskUsage
  warn_percent : UInt64
  high_percent : UInt64
  full_percent : UInt64
}

///|
/// Build a gate over a usage source with the default thresholds
/// 70/85/95.
pub fn Watermark::new(
  usage : &@harness.DiskUsage,
  warn_percent~ : UInt64 = 70UL,
  high_percent~ : UInt64 = 85UL,
  full_percent~ : UInt64 = 95UL,
) -> Watermark {
  { usage, warn_percent, high_percent, full_percent, }
}

///|
/// Report the volume's current usage as a whole percentage.
pub fn Watermark::used_percent(self : Watermark) -> UInt64 {
  let total = self.usage.total_bytes()
  if total == 0UL {
    return 0UL
  }
  self.usage.used_bytes() * 100UL / total
}

///|
/// Classify the volume's current usage against the thresholds.
pub fn Watermark::tier(self : Watermark) -> WatermarkTier {
  if self.usage.total_bytes() == 0UL {
    return Normal
  }
  let percent = self.used_percent()
  if percent >= self.full_percent {
    Full
  } else if percent >= self.high_percent {
    High
  } else if percent >= self.warn_percent {
    Warn
  } else {
    Normal
  }
}

///|
/// Refuse an append that would reach the high watermark.
///
/// The check projects `used_bytes + append_bytes` against the volume, so an
/// append that would cross the 85% line is refused while smaller appends in
/// the warning band still land. A refusal is `AppendFault::Capacity`: an
/// explicit, actionable rejection before any disk operation, never a
/// silent drop and never unbounded buffering.
pub fn Watermark::check_append(
  self : Watermark,
  append_bytes : Int32,
) -> Result[Unit, AppendFault] {
  let total = self.usage.total_bytes()
  if total == 0UL {
    return Ok(())
  }
  let projected = self.usage.used_bytes() + append_bytes.to_uint64()
  if projected * 100UL / total >= self.high_percent {
    return Err(Capacity)
  }
  Ok(())
}

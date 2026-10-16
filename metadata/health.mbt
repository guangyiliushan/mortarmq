/// Metadata-side corruption handling: quarantine and read-only
/// degradation.
///
/// Record damage (a CRC failure or a gap in the metadata log) MUST enter
/// quarantine and MUST never be silently skipped: recovery aborts at the
/// damaged record (see `recover_snapshot`) and the guard records the
/// refused region so the operator runbook can act on it. The
/// system degrades to read-only on any anomaly and may escalate to
/// quarantined; the write path is then refused with the registered
/// protocol codes 0x2003 (METADATA_READ_ONLY, retry later) or 0x2004
/// (METADATA_QUARANTINED, human intervention). The mode and the
/// quarantine entries are the honest state a health endpoint must show.
///
/// This is the metadata-side counterpart of the storage segment
/// quarantine: a damaged segment quarantines data, a damaged metadata
/// record quarantines the metadata log region and degrades every
/// metadata write. The two never share machinery.

///|
pub(all) enum MetadataMode {
  /// No anomaly observed; the write path is open.
  Healthy
  /// An anomaly degraded the metadata to read-only; writes are refused
  /// with the registered `MetadataReadOnly` code and can be retried later.
  ReadOnly
  /// Damage was escalated for human intervention; writes are
  /// refused with the registered `MetadataQuarantined` code.
  Quarantined
} derive(Eq, Debug)

///|
pub extend MetadataMode with Eq::{not_equal, equal}

///|
pub extend MetadataMode with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One refused region of the metadata log: the byte offset of the
/// damaged record and the extent that recovery would not cross.
pub(all) struct QuarantineEntry {
  offset : UInt32
  length : UInt32
} derive(Eq, Debug)

///|
pub extend QuarantineEntry with Eq::{not_equal, equal}

///|
pub extend QuarantineEntry with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Degrade and quarantine state for the metadata write path.
pub(all) struct MetadataGuard {
  mut mode : MetadataMode
  mut entries : Array[QuarantineEntry]
}

///|
pub fn MetadataGuard::new() -> MetadataGuard {
  { mode: Healthy, entries: [], }
}

///|
/// Record one damaged log region and degrade to read-only. The damaged
/// record is quarantined here; it is never skipped or repaired in place.
pub fn MetadataGuard::note_log_corruption(
  self : MetadataGuard,
  offset : UInt32,
  length : UInt32,
) -> Unit {
  self.entries.push({ offset, length, })
  self.mode = ReadOnly
}

///|
/// Escalate to quarantined: writes stay refused and the state now asks
/// for human intervention instead of a retry.
pub fn MetadataGuard::escalate_to_quarantine(self : MetadataGuard) -> Unit {
  self.mode = Quarantined
}

///|
/// Clear the guard after a recovery path rebuilt trustworthy state
/// (for example a fallback generation plus replay). Entries stay on
/// record for the operator; only the write gate reopens.
pub fn MetadataGuard::restore_healthy(self : MetadataGuard) -> Unit {
  self.mode = Healthy
}

///|
pub fn MetadataGuard::mode(self : MetadataGuard) -> MetadataMode {
  self.mode
}

///|
pub fn MetadataGuard::entries(self : MetadataGuard) -> Array[QuarantineEntry] {
  self.entries.copy()
}

///|
/// The registered write-path refusal code for the current mode, or
/// `None` while the write path is open.
///
/// Both targets are constructors of the 49-code registry;
/// this module never emits raw numeric codes.
pub fn MetadataGuard::write_refusal(self : MetadataGuard) -> @protocol.ErrCode? {
  match self.mode {
    Healthy => None
    ReadOnly => Some(@protocol.MetadataReadOnly)
    Quarantined => Some(@protocol.MetadataQuarantined)
  }
}

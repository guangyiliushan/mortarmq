/// Move a damaged sealed segment aside so the series can keep serving.
///
/// Dual-layer isolation: the active segment truncates to its last valid
/// record, while a damaged sealed segment is moved out of the replay path
/// as a whole. The move is a rename to `segment_path || ".quarantined"` plus
/// a sidecar note at `segment_path || ".quarantine"` recording the first bad
/// offset and the reason, so a damaged region is locatable and clearable:
/// the quarantined file stays an ordinary file that `delete_before` can
/// remove like any sealed segment. Replay never silently skips a damaged
/// region -- the gap the missing records leave is surfaced by
/// `recover_series` as a visible `GapDetected` marker.

///|
/// Suffix of the renamed quarantined segment file.
pub const QUARANTINE_SUFFIX : Bytes = b".quarantined"

///|
/// Suffix of the sidecar note naming the first bad offset.
pub const QUARANTINE_SIDECAR_SUFFIX : Bytes = b".quarantine"

///|
/// Why a sealed segment was moved aside.
pub(all) enum QuarantineReason {
  /// A complete-length record failed header or CRC validation.
  CorruptRecord
  /// A complete record breaks the segment's own sequence continuity.
  SequenceGap
} derive(Eq, Debug)

///|
pub extend QuarantineReason with Eq::{not_equal, equal}

///|
pub extend QuarantineReason with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Where a quarantined segment went and what was wrong with it.
pub(all) struct QuarantineRecord {
  segment_path : Bytes
  quarantined_path : Bytes
  sidecar_path : Bytes
  first_bad_offset : Int32
  reason : QuarantineReason
} derive(Eq, Debug)

///|
pub extend QuarantineRecord with Eq::{not_equal, equal}

///|
pub extend QuarantineRecord with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Derive the rename and sidecar paths of one segment's quarantine.
pub fn quarantine_paths(segment_path : Bytes) -> (Bytes, Bytes) {
  (segment_path + QUARANTINE_SUFFIX, segment_path + QUARANTINE_SIDECAR_SUFFIX)
}

///|
/// Encode the sidecar note: the first bad offset and the reason, as text so
/// an operator can read the damage without tools.
pub fn encode_quarantine_note(
  first_bad_offset : Int32,
  reason : QuarantineReason,
) -> Bytes {
  let reason_text = match reason {
    CorruptRecord => b"corrupt_record"
    SequenceGap => b"sequence_gap"
  }
  b"first_bad_offset=" +
  @utf8.encode(first_bad_offset.to_string()) +
  b"\nreason=" +
  reason_text +
  b"\n"
}

///|
/// Finish a quarantine whose rename already happened: write the sidecar note
/// and report where everything landed.
///
/// This is the re-entry point after a crash between the rename and the
/// sidecar write: the segment is already out of the replay path, and the
/// note is rewritten from the caller's rediscovered damage facts.
pub async fn complete_quarantine(
  disk : &@ports.Disk,
  segment_path : Bytes,
  first_bad_offset : Int32,
  reason : QuarantineReason,
) -> Result[QuarantineRecord, StorageFault] {
  let (quarantined_path, sidecar_path) = quarantine_paths(segment_path)
  let write_result = @ports.Disk::write(
    disk,
    sidecar_path,
    encode_quarantine_note(first_bad_offset, reason),
  )
  match write_result {
    Ok(_) => ()
    Err(fault) => return Err(DiskFault(fault))
  }
  Ok({ segment_path, quarantined_path, sidecar_path, first_bad_offset, reason, })
}

///|
/// Move a damaged sealed segment aside and record the damage.
///
/// Renames `segment_path` to its `.quarantined` twin, then writes the
/// sidecar note. Re-entry after a crash between the two steps is safe: when
/// the rename reports a missing source and the quarantined twin exists, the
/// call completes the sidecar instead of failing.
///
/// # Errors
///
/// * `DiskFault(PathMissing)` when neither the segment nor its quarantined
///   twin exists.
/// * `DiskFault(fault)` for any other disk failure; a failed rename leaves
///   the segment in the replay path, and a failed sidecar write leaves the
///   rename done with the note missing.
pub async fn quarantine_segment(
  disk : &@ports.Disk,
  segment_path : Bytes,
  first_bad_offset : Int32,
  reason : QuarantineReason,
) -> Result[QuarantineRecord, StorageFault] {
  let (quarantined_path, _sidecar_path) = quarantine_paths(segment_path)
  match @ports.Disk::rename(disk, segment_path, quarantined_path) {
    Ok(_) => ()
    Err(@ports.PathMissing) =>
      match @ports.Disk::read(disk, quarantined_path) {
        Ok(_) => ()
        Err(_) => return Err(DiskFault(@ports.PathMissing))
      }
    Err(fault) => return Err(DiskFault(fault))
  }
  complete_quarantine(disk, segment_path, first_bad_offset, reason)
}

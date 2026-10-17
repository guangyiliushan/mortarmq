/// Delete whole sealed segments below a sequence watermark.
///
/// # Growth boundary
///
/// v0 does not truncate, compact, or reclaim the series on its own:
/// append-only growth is unbounded within the volume, by honest design.
/// The 70/85/95 watermark is the backstop that turns exhaustion into
/// explicit refusals instead of an OOM or silent loss, and
/// `delete_before` is the only relief -- a manual mechanism with no
/// policy executor and no configuration. Automatic retention or
/// truncation is v1 work.
///
/// This module is the deletion mechanism only:
/// `delete_before` removes sealed segments whose highest readable sequence
/// lies entirely below the caller's watermark, plus any quarantine twin and
/// sidecar note those segments left behind. There is no automatic retention
/// executor and no configuration: an operator (or a future policy layer)
/// supplies the watermark. The active segment is never deleted -- it is
/// still being written -- and a segment is only deleted when its readable
/// records are entirely below the watermark, so a damaged segment with an
/// unreadable tail is reclaimed conservatively (its readable prefix must
/// already lie below the line; the tail sits between that prefix and the
/// next surviving segment by the writer's monotonicity). Deletion frees the
/// bytes: removed files stop counting against the volume's watermark.

///|
/// The highest sequence a scan could read, if it held any record.
fn scan_last_sequence(scan : SegmentScan) -> UInt64? {
  match scan {
    Intact(intact) =>
      if intact.records.length() > 0 {
        Some(intact.records[intact.records.length() - 1].header.sequence)
      } else {
        None
      }
    Damaged(damaged) =>
      if damaged.records.length() > 0 {
        Some(damaged.records[damaged.records.length() - 1].header.sequence)
      } else {
        None
      }
  }
}

///|
/// The later of two optional sequence readings.
fn later_sequence(a : UInt64?, b : UInt64?) -> UInt64? {
  match a {
    Some(x) =>
      match b {
        Some(y) => if x >= y { Some(x) } else { Some(y) }
        None => Some(x)
      }
    None => b
  }
}

///|
/// Remove one file if it exists; report whether it was there.
async fn remove_if_present(
  disk : &@ports.Disk,
  path : Bytes,
) -> Result[Bool, StorageFault] {
  match @ports.Disk::remove(disk, path) {
    Ok(_) => Ok(true)
    Err(@ports.PathMissing) => Ok(false)
    Err(fault) => Err(DiskFault(fault))
  }
}

///|
/// Delete the sealed segments entirely below `before_sequence`.
///
/// Scans segments `0 .. segment_count-1` (the last index is the active
/// segment and is never deleted). For each sealed index the primary file
/// and its quarantined twin are scanned; when the highest readable sequence
/// is below the watermark, all of the segment's files -- primary, twin and
/// sidecar note -- are removed and the segment counts as deleted. An
/// orphan sidecar whose segment files are both gone is cleaned up with the
/// deletion it belonged to.
///
/// Returns the number of segments whose files were reclaimed.
///
/// # Errors
///
/// * `DiskFault(fault)` when a scan or a removal fails for any reason
///   other than a missing file.
pub async fn delete_before(
  disk : &@ports.Disk,
  base_path : Bytes,
  segment_count : Int32,
  before_sequence : UInt64,
) -> Result[Int32, StorageFault] {
  let active_index = segment_count - 1
  let mut removed = 0
  let mut index = 0
  while index < segment_count {
    if index != active_index {
      let path = segment_path_of(base_path, index)
      let (quarantined_path, sidecar_path) = quarantine_paths(path)
      let mut primary_present = false
      let mut twin_present = false
      let mut last : UInt64? = None
      match scan_segment(disk, path) {
        Ok(scan) => {
          primary_present = true
          last = scan_last_sequence(scan)
        }
        Err(code) => if is_missing(code) { () } else { return Err(code) }
      }
      match scan_segment(disk, quarantined_path) {
        Ok(scan) => {
          twin_present = true
          let twin_last = scan_last_sequence(scan)
          last = later_sequence(last, twin_last)
        }
        Err(code) => if is_missing(code) { () } else { return Err(code) }
      }
      let deletable = match last {
        Some(seq) => seq < before_sequence
        None => false
      }
      if (primary_present || twin_present) && deletable {
        match remove_if_present(disk, path) {
          Ok(_) => ()
          Err(code) => return Err(code)
        }
        match remove_if_present(disk, quarantined_path) {
          Ok(_) => ()
          Err(code) => return Err(code)
        }
        match remove_if_present(disk, sidecar_path) {
          Ok(_) => ()
          Err(code) => return Err(code)
        }
        removed = removed + 1
      } else if primary_present == false && twin_present == false {
        // No segment files at all: drop an orphan sidecar note.
        match remove_if_present(disk, sidecar_path) {
          Ok(_) => ()
          Err(code) => return Err(code)
        }
      }
    }
    index = index + 1
  }
  Ok(removed)
}

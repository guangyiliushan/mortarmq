/// Recover a whole segment series under the quarantine policy.
///
/// Dual-layer isolation over `recover_segment`'s single-file contract:
/// sealed segments that fail validation are quarantined as a whole
/// (`storage/quarantine`), the active segment truncates to its last valid
/// record, and every hole in the recovered sequence is surfaced as a visible
/// `GapDetected` marker -- recovery never silently skips damaged bytes.
/// Sequence continuity is enforced inside each segment (a jump means the
/// file was rewritten and the sealed segment is quarantined); across
/// segments a discontinuity is reported but not cascaded, because the cause
/// of a cross-segment hole has already been dispositioned (a quarantine, a
/// missing file, or an acknowledged loss) and quarantining the next healthy
/// segment would wipe the series.

///|
/// What a single-segment scan found.
pub(all) enum SegmentScan {
  /// Complete valid records with a torn tail boundary (or a whole file).
  Intact(IntactScan)
  /// Valid records up to the first corrupt record or in-segment sequence jump.
  Damaged(DamagedScan)
} derive(Eq, Debug)

///|
pub extend SegmentScan with Eq::{not_equal, equal}

///|
pub extend SegmentScan with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The valid part of a segment whose scan found no structural damage.
pub(all) struct IntactScan {
  /// Every complete valid record, in file order.
  records : Array[RecoveredRecord]
  /// Byte offset just past the last complete record.
  end_offset : Int
  /// True when the walk stopped at an incomplete trailing record. A
  /// normal crash tail on the active segment; damage on a sealed one.
  truncated : Bool
} derive(Eq, Debug)

///|
pub extend IntactScan with Eq::{not_equal, equal}

///|
pub extend IntactScan with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The valid prefix of a damaged segment plus the damage location.
pub(all) struct DamagedScan {
  /// Complete valid records before the damage.
  records : Array[RecoveredRecord]
  /// Byte offset of the first untrusted record.
  first_bad_offset : Int
  reason : QuarantineReason
} derive(Eq, Debug)

///|
pub extend DamagedScan with Eq::{not_equal, equal}

///|
pub extend DamagedScan with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One visible hole in the recovered series (REQ-STO-003/005: a sequence gap
/// is corruption and is never skipped silently).
pub(all) struct GapDetected {
  segment_index : Int
  file_offset : Int
  /// Sequence the replay expected at this position; the series' first
  /// record establishes the base with its own sequence.
  expected_sequence : UInt64
  /// Sequence actually found; equals `expected_sequence` for a missing file.
  found_sequence : UInt64
  /// True when the whole segment file is missing rather than mis-sequenced.
  segment_missing : Bool
} derive(Eq, Debug)

///|
pub extend GapDetected with Eq::{not_equal, equal}

///|
pub extend GapDetected with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The recovered series: valid records, the segments moved aside, and every
/// visible hole, with the sequence the next append must assign.
pub(all) struct SeriesRecovery {
  /// Every recovered record in series order (quarantined segments excluded).
  records : Array[RecoveredRecord]
  /// Segments moved aside, in segment order.
  quarantined : Array[QuarantineRecord]
  /// Holes the replay surfaced, in order; empty means an unbroken series.
  gaps : Array[GapDetected]
  /// `Some(offset)` when the active tail was dropped at a corrupt record.
  active_truncated_at : Int?
  /// Sequence the next append assigns after this recovery.
  next_sequence : UInt64
} derive(Eq, Debug)

///|
pub extend SeriesRecovery with Eq::{not_equal, equal}

///|
pub extend SeriesRecovery with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn is_missing(fault : StorageFault) -> Bool {
  match fault {
    DiskFault(@harness.PathMissing) => true
    _ => false
  }
}

///|
/// Scan one segment file under the quarantine policy.
///
/// Walks the record area like `recover_segment`, but classifies damage
/// instead of failing closed: an incomplete trailing record ends the walk at
/// the last complete boundary (`Intact`), while a complete record that fails
/// validation or breaks the segment's own sequence continuity returns the
/// valid prefix and the first bad offset (`Damaged`).
///
/// # Errors
///
/// * `DiskFault(PathMissing)` when the file does not exist.
/// * `DiskFault(fault)` for any other disk read failure.
pub async fn scan_segment(
  disk : &@harness.Disk,
  segment_path : Bytes,
) -> Result[SegmentScan, StorageFault] {
  let segment = match @harness.Disk::read(disk, segment_path) {
    Ok(bytes) => bytes
    Err(@harness.PathMissing) => return Err(DiskFault(@harness.PathMissing))
    Err(fault) => return Err(DiskFault(fault))
  }
  let view = segment[:]
  let length = segment.length()
  let records : Array[RecoveredRecord] = []
  let mut position = 0
  let mut expected = 0UL
  let mut expected_set = false
  let mut truncated = false
  while position < length {
    if length - position < 4 {
      // Trailing bytes too few to hold a length prefix: torn write tail.
      truncated = true
      break
    }
    let record_length = match read_uint_be(view, position) {
      Ok(value) => value
      Err(code) => return Err(code)
    }
    if record_length > (length - position - 4).reinterpret_as_uint() {
      // The framed record extends past the segment end: torn write tail.
      truncated = true
      break
    }
    let total = 4 + record_length.reinterpret_as_int()
    let body = view[position:position + total]
    let header = match decode_record_header(body) {
      Ok(header) => header
      Err(_) =>
        return Ok(
          Damaged({
            records,
            first_bad_offset: position,
            reason: CorruptRecord,
          }),
        )
    }
    if expected_set && header.sequence != expected {
      return Ok(
        Damaged({ records, first_bad_offset: position, reason: SequenceGap, }),
      )
    }
    let key_end = RECORD_HEADER_BYTES + header.key_length.to_int()
    let value_end = key_end + header.value_length.reinterpret_as_int()
    records.push({
      header,
      key: body[RECORD_HEADER_BYTES:key_end].to_owned(),
      value: body[key_end:value_end].to_owned(),
    })
    expected = header.sequence + 1UL
    expected_set = true
    position = position + total
  }
  Ok(Intact({ records, end_offset: position, truncated, }))
}

///|
/// Recover a whole segment series under the quarantine policy.
///
/// Scans segments `0 .. segment_count-1`, where the last index is the active
/// segment. Sealed damage is quarantined and reported; active damage
/// truncates to the valid prefix; sequence holes across segments (and sealed
/// segments whose file is missing with no quarantined twin) are surfaced in
/// `gaps`. When a sealed segment is missing but its quarantined twin exists,
/// the scan rediscovers the damage on the twin and completes the sidecar
/// note, so a crash mid-quarantine re-converges.
///
/// # Errors
///
/// * `DiskFault(fault)` when a read fails for any reason other than a
///   missing sealed segment, or when a quarantine move fails.
pub async fn recover_series(
  disk : &@harness.Disk,
  base_path : Bytes,
  segment_count : Int,
) -> Result[SeriesRecovery, StorageFault] {
  let records : Array[RecoveredRecord] = []
  let quarantined : Array[QuarantineRecord] = []
  let gaps : Array[GapDetected] = []
  let mut active_truncated_at : Int? = None
  let mut running_next = 0UL
  let mut running_set = false
  if segment_count <= 0 {
    return Ok({
      records,
      quarantined,
      gaps,
      active_truncated_at,
      next_sequence: 0UL,
    })
  }
  let active_index = segment_count - 1
  let mut index = 0
  while index < segment_count {
    let path = segment_path_of(base_path, index)
    let scan_result = scan_segment(disk, path)
    let scan_opt = match scan_result {
      Ok(scan) => Some(scan)
      Err(code) =>
        if is_missing(code) {
          if index == active_index {
            // A missing active segment is a fresh series tail, not damage.
            None
          } else {
            // The file may have been moved aside by an interrupted
            // quarantine; re-discover the damage on its twin.
            let (quarantined_path, _sidecar_path) = quarantine_paths(path)
            let twin_result = scan_segment(disk, quarantined_path)
            match twin_result {
              Ok(Damaged(damaged)) => {
                let entry_result = complete_quarantine(
                  disk,
                  path,
                  damaged.first_bad_offset,
                  damaged.reason,
                )
                match entry_result {
                  Ok(entry) => quarantined.push(entry)
                  Err(inner) => return Err(inner)
                }
                if damaged.records.length() > 0 {
                  let last = damaged.records[damaged.records.length() - 1]
                  running_next = last.header.sequence + 1UL
                  running_set = true
                }
                None
              }
              Ok(Intact(_)) => {
                gaps.push({
                  segment_index: index,
                  file_offset: 0,
                  expected_sequence: running_next,
                  found_sequence: running_next,
                  segment_missing: true,
                })
                None
              }
              Err(inner) =>
                if is_missing(inner) {
                  gaps.push({
                    segment_index: index,
                    file_offset: 0,
                    expected_sequence: running_next,
                    found_sequence: running_next,
                    segment_missing: true,
                  })
                  None
                } else {
                  return Err(inner)
                }
            }
          }
        } else {
          return Err(code)
        }
    }
    match scan_opt {
      Some(scan) =>
        match scan {
          Intact(intact) =>
            if intact.truncated && index != active_index {
              // A sealed segment is complete by construction: a torn tail
              // is damage, quarantined like any other and localized at the
              // first missing byte.
              if intact.records.length() > 0 {
                let last = intact.records[intact.records.length() - 1]
                running_next = last.header.sequence + 1UL
                running_set = true
              }
              let entry_result = quarantine_segment(
                disk,
                path,
                intact.end_offset,
                CorruptRecord,
              )
              match entry_result {
                Ok(entry) => quarantined.push(entry)
                Err(inner) => return Err(inner)
              }
            } else if intact.records.length() > 0 {
              let first = intact.records[0]
              if running_set && first.header.sequence != running_next {
                gaps.push({
                  segment_index: index,
                  file_offset: 0,
                  expected_sequence: running_next,
                  found_sequence: first.header.sequence,
                  segment_missing: false,
                })
              }
              for record in intact.records {
                records.push(record)
              }
              let last = intact.records[intact.records.length() - 1]
              running_next = last.header.sequence + 1UL
              running_set = true
            }
          Damaged(damaged) =>
            if index == active_index {
              // The active segment truncates to the last valid record.
              for record in damaged.records {
                records.push(record)
              }
              if damaged.records.length() > 0 {
                let last = damaged.records[damaged.records.length() - 1]
                running_next = last.header.sequence + 1UL
                running_set = true
              }
              active_truncated_at = Some(damaged.first_bad_offset)
            } else {
              if damaged.records.length() > 0 {
                let last = damaged.records[damaged.records.length() - 1]
                running_next = last.header.sequence + 1UL
                running_set = true
              }
              let entry_result = quarantine_segment(
                disk,
                path,
                damaged.first_bad_offset,
                damaged.reason,
              )
              match entry_result {
                Ok(entry) => quarantined.push(entry)
                Err(inner) => return Err(inner)
              }
              // The valid prefix is excluded with the file but still anchors
              // the running expectation: the sidecar proves those records
              // were valid, so the hole is reported precisely at the next
              // segment instead of cascading into it.
            }
        }
      None => ()
    }
    index = index + 1
  }
  Ok({
    records,
    quarantined,
    gaps,
    active_truncated_at,
    next_sequence: running_next,
  })
}

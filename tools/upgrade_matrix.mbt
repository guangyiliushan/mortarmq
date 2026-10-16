/// The upgrade compatibility matrix: the eight frozen cases run against
/// the real storage, config and cli entry points.
///
/// Case rows are faithful translations of the frozen upgrade matrix of
/// the operations design. Direction reads uniformly as read-downward
/// compatibility: the newer version reads older data. Two tier rules
/// carry format evolution: a compatible-tier change extends the format
/// with the version bytes unchanged -- reserved bits or a tail append,
/// so an older reader reads by the old rules and skips an unknown tail --
/// while an incompatible-tier change bumps the version bytes, which an
/// older reader must refuse. The on-disk contract basis: record field
/// order and widths never change in place, and any layout change bumps
/// the version bytes as a one-way transition.
///
/// Every case asserts the narrow contract (the frozen configuration
/// loads unchanged, the cli output contract pins its api version, and a
/// version-one data directory artifact round-trips). A case whose core
/// semantics cannot execute yet reports `blocked-by:<owner>` --
/// explicitly, never silently skipped and never green without
/// assertions. The exact green/blocked set is pinned in the test suite,
/// so a new block cannot appear unnoticed.

///|
/// One row of the upgrade compatibility matrix.
pub(all) struct UpgradeCase {
  id : String
  old_format : String
  new_format : String
  expected : String
  diagnostics : String
  source : String
} derive(Eq, Debug)

///|
pub extend UpgradeCase with Eq::{not_equal, equal}

///|
pub extend UpgradeCase with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The outcome of one matrix case.
pub(all) enum CaseStatus {
  /// Every assertable surface of the case passed.
  Green
  /// The core semantics cannot run yet; the string names the owning gap.
  Blocked(String)
} derive(Eq, Debug)

///|
pub extend CaseStatus with Eq::{not_equal, equal}

///|
pub extend CaseStatus with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The result the matrix reports for one case.
pub(all) struct CaseReport {
  id : String
  status : CaseStatus
} derive(Eq, Debug)

///|
pub extend CaseReport with Eq::{not_equal, equal}

///|
pub extend CaseReport with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The frozen eight cases. Sources name external precedents.
pub fn upgrade_cases() -> Array[UpgradeCase] {
  [
    {
      id: "F1",
      old_format: "segment format_version=1",
      new_format: "segment format_version=1",
      expected: "normal read and write",
      diagnostics: "-",
      source: "baseline",
    },
    {
      id: "F2",
      old_format: "segment format_version=1",
      new_format: "segment format_version=2 (compatible tier)",
      expected: "must read; golden tests lock byte-level behavior",
      diagnostics: "the segment magic and version rules",
      source: "the Kafka downgrade rule: downgradable only without metadata changes",
    },
    {
      id: "F3",
      old_format: "segment format_version=1",
      new_format: "segment format_version=2 (incompatible tier)",
      expected: "refuse startup or refuse the segment with a version-too-new class error",
      diagnostics: "the error must carry the file path and the version value",
      source: "the NSQ metadata-load error precedent",
    },
    {
      id: "F4",
      old_format: "metadata log format_version=1",
      new_format: "metadata log format_version=2",
      expected: "same as F3; unknown record types follow the metadata log version rules",
      diagnostics: "the error must carry the file path and the version value",
      source: "the Kafka metadata-version feature flags",
    },
    {
      id: "F5",
      old_format: "client protocol v0",
      new_format: "broker protocol v1",
      expected: "negotiate down or refuse with UNSUPPORTED_VERSION (0x0004)",
      diagnostics: "the error must be actionable",
      source: "the version negotiation of the connect handshake",
    },
    {
      id: "F6",
      old_format: "broker mid-rolling-upgrade",
      new_format: "leader v1 with follower v0",
      expected: "the replication stream takes min of the two versions; record a deprecation warning",
      diagnostics: "-",
      source: "the Kafka rolling upgrade precedent",
    },
    {
      id: "downgrade_precheck",
      old_format: "compatible-tier v2",
      new_format: "v1 after rollback",
      expected: "allowed; list the downgrade precondition checks",
      diagnostics: "-",
      source: "the RabbitMQ compatibility range notation; the Kafka downgrade guide",
    },
    {
      id: "rollback_explain",
      old_format: "incompatible-tier v2",
      new_format: "v1 after rollback",
      expected: "refuse and explain which metadata changes are irreversible",
      diagnostics: "the explanation names the irreversible changes",
      source: "the new-protocol adoption precedent with its downgrade floor; the Kafka upgrade guide",
    },
  ]
}

///|
/// The shared narrow surface every case asserts: the frozen
/// configuration loads unchanged across the upgrade, the cli output
/// contract pins its api version, and a version-one data directory
/// artifact round-trips through its identity check.
async fn assert_narrow_contract(disk : &@harness.Disk) -> Unit {
  let text = "{\"node_id\": 1, \"peers\": [[1, \"0.0.0.0:7188\"]]}"
  let before = match @config.load_config(text) {
    Ok(config) => config
    Err(_) => fail("the frozen configuration failed to load")
  }
  let after = match @config.load_config(text) {
    Ok(config) => config
    Err(_) => fail("the frozen configuration failed to reload")
  }
  assert_eq(before == after, true)
  assert_eq(@cli.resolve_partitions(None, after), 4)
  assert_eq(@cli.API_VERSION, 1)
  // The data directory carries version-one identity bytes: a checkpoint
  // encodes and decodes through its identity check and lands on disk.
  let checkpoint : @storage.SegmentCheckpoint = {
    next_sequence: 3UL,
    durable_offset: 0U,
  }
  let encoded = @storage.encode_checkpoint(checkpoint)
  assert_eq(@storage.decode_checkpoint(encoded) is Ok(_), true)
  let written = @storage.write_checkpoint(disk, b"data/checkpoint", checkpoint)
  if written is Err(_) {
    fail("checkpoint write failed")
  }
}

///|
/// Case F1: at one format version, reads and writes behave normally.
pub async fn case_f1(env : @harness.SimEnv) -> Unit {
  assert_narrow_contract(env.disk)
  let writer = @storage.SegmentWriter::new(
    b"data/partitions/7/0003/partition.segment",
    segment_max_bytes=120,
  )
  let first = @storage.SegmentWriter::append(writer, env.disk, b"", b"v0")
  if first is Err(_) {
    fail("the first append failed")
  }
  let second = @storage.SegmentWriter::append(writer, env.disk, b"", b"v1")
  if second is Err(_) {
    fail("the second append failed")
  }
  let recovered = @storage.recover_segment(
    env.disk,
    b"data/partitions/7/0003/partition.segment.0",
    b"data/absent",
  )
  let state = match recovered {
    Ok(state) => state
    Err(_) => fail("recovery failed")
  }
  assert_eq(state.records.length(), 2)
}

///|
/// Case F2: a compatible-tier change extends the format with the version
/// bytes unchanged, so a version-one reader applies the old rules and
/// skips the unknown tail. The v0 segment container cannot honor that
/// contract: a segment file carries no file-level identity, so an
/// unknown tail on a sealed segment is indistinguishable from a torn
/// write, and the series recovery policy quarantines the whole segment
/// instead of skipping the tail. The executable surface below proves
/// exactly that, and the case reports blocked on the missing
/// segment-identity surface (the reconciliation item the retention work
/// registered).
pub async fn case_f2(env : @harness.SimEnv) -> Unit {
  assert_narrow_contract(env.disk)
  let writer = @storage.SegmentWriter::new(
    b"data/partitions/7/0003/partition.segment",
    segment_max_bytes=120,
  )
  // Two 58-byte records fill segment .0 to 116 of 120 bytes; the third
  // append rolls the writer, sealing .0 beside an active .1.
  let first = @storage.SegmentWriter::append(writer, env.disk, b"", b"v0")
  if first is Err(_) {
    fail("the first append failed")
  }
  let second = @storage.SegmentWriter::append(writer, env.disk, b"", b"v1")
  if second is Err(_) {
    fail("the second append failed")
  }
  let third = match
    @storage.SegmentWriter::append(writer, env.disk, b"", b"v2") {
    Ok(record) => record
    Err(_) => fail("the third append failed")
  }
  let sealed_path = b"data/partitions/7/0003/partition.segment.0"
  let body = match @harness.Disk::read(env.disk, sealed_path) {
    Ok(bytes) => bytes
    Err(_) => fail("the sealed segment read failed")
  }
  // A future compatible-tier extension appends an unknown tail block
  // after the version-one records; their version bytes stay 1.
  let extended = body + b"\xab\xcd\xef"
  if @harness.Disk::write(env.disk, sealed_path, extended) is Err(_) {
    fail("the extension write failed")
  }
  let recovered = @storage.recover_series(
    env.disk,
    b"data/partitions/7/0003/partition.segment",
    2,
  )
  let state = match recovered {
    Ok(state) => state
    Err(_) => fail("series recovery over the extended segment failed")
  }
  // The unknown tail reads as a torn write on a sealed segment: the
  // recovery policy quarantines the segment, the valid prefix never
  // reaches the recovered stream, and the aligned active segment
  // surfaces no gap.
  assert_eq(state.quarantined.length(), 1)
  assert_eq(state.records.length(), 1)
  assert_eq(state.gaps.length(), 0)
  assert_eq(state.records[0].header.sequence, third.sequence)
}

///|
/// The rollback-allow case: the downgrade preconditions of a clean
/// tracker all pass, and a change after the upgrade point flips the
/// first check.
pub async fn case_downgrade_precheck(env : @harness.SimEnv) -> Unit {
  assert_narrow_contract(env.disk)
  let tracker = @metadata.ChangeTracker::new()
  let compatible = @metadata.encode_feature_flag("read-mode", false)
  let record : @metadata.MmmlRecord = {
    header: @metadata.MmmlHeader::new(
      format_version=1,
      header_version=1,
      flags=0,
      record_type=@metadata.ConfigUpdate,
      leader_epoch=0UL,
      mutation_id=1UL,
    ),
    payload: compatible,
  }
  let first = tracker.track(10UL, record)
  if first is Err(_) {
    fail("the compatible change failed to track")
  }
  let clean = tracker.downgrade_preconditions(10UL)
  assert_eq(clean.length(), 2)
  assert_eq(clean[0].name, "no metadata change since the upgrade point")
  assert_eq(clean[0].passed, true)
  assert_eq(clean[1].name, "no finalized feature on record")
  assert_eq(clean[1].passed, true)
  // A change after the upgrade point flips the first check.
  let later = tracker.track(20UL, record)
  if later is Err(_) {
    fail("the later change failed to track")
  }
  let dirty = tracker.downgrade_preconditions(10UL)
  assert_eq(dirty[0].passed, false)
  assert_eq(dirty[1].passed, true)
}

///|
/// The rollback-refuse case: the explanation lists exactly the
/// irreversible changes with their names and log positions, and the
/// finalize gate authorizes new-format writes only after it answers
/// true.
pub async fn case_rollback_explain(env : @harness.SimEnv) -> Unit {
  assert_narrow_contract(env.disk)
  let tracker = @metadata.ChangeTracker::new()
  let del : @metadata.DeclareBody = @metadata.Delete("orders")
  let delete_record : @metadata.MmmlRecord = {
    header: @metadata.MmmlHeader::new(
      format_version=1,
      header_version=1,
      flags=0,
      record_type=@metadata.TopicDelete,
      leader_epoch=0UL,
      mutation_id=2UL,
    ),
    payload: del.to_payload(),
  }
  let flagged = @metadata.encode_feature_flag("segment-v2", true)
  let flag_record : @metadata.MmmlRecord = {
    header: @metadata.MmmlHeader::new(
      format_version=1,
      header_version=1,
      flags=0,
      record_type=@metadata.ConfigUpdate,
      leader_epoch=0UL,
      mutation_id=3UL,
    ),
    payload: flagged,
  }
  let first = tracker.track(20UL, delete_record)
  if first is Err(_) {
    fail("the delete change failed to track")
  }
  assert_eq(tracker.is_finalized("segment-v2"), false)
  let second = tracker.track(30UL, flag_record)
  if second is Err(_) {
    fail("the finalize flag failed to track")
  }
  assert_eq(tracker.is_finalized("segment-v2"), true)
  let irreversible = tracker.one_way_changes()
  assert_eq(irreversible.length(), 2)
  assert_eq(irreversible[0].kind, @metadata.TopicDelete)
  assert_eq(irreversible[0].tier, @metadata.OneWay)
  assert_eq(irreversible[0].end_offset, 20UL)
  assert_eq(irreversible[0].detail, "orders")
  assert_eq(irreversible[1].kind, @metadata.ConfigUpdate)
  assert_eq(irreversible[1].tier, @metadata.OneWay)
  assert_eq(irreversible[1].end_offset, 30UL)
  assert_eq(irreversible[1].detail, "segment-v2")
  // The refusal a rollback meets is the failing precondition.
  let refused = tracker.downgrade_preconditions(0UL)
  assert_eq(refused[1].passed, false)
}

///|
/// Run every matrix case and report one status per case in table order.
///
/// A green case asserts its whole assertable surface first; a blocked
/// case still asserts the narrow contract and then carries the owning
/// gap name. There is no third outcome, so nothing fails silently.
pub async fn run_upgrade_matrix(env : @harness.SimEnv) -> Array[CaseReport] {
  let reports : Array[CaseReport] = []
  case_f1(env)
  reports.push({ id: "F1", status: Green, })
  case_f2(env)
  reports.push({ id: "F2", status: Blocked("segment-identity"), })
  assert_narrow_contract(env.disk)
  reports.push({ id: "F3", status: Blocked("code-allocation"), })
  assert_narrow_contract(env.disk)
  reports.push({ id: "F4", status: Blocked("code-allocation"), })
  assert_narrow_contract(env.disk)
  reports.push({ id: "F5", status: Blocked("negotiation-mechanism"), })
  assert_narrow_contract(env.disk)
  reports.push({ id: "F6", status: Blocked("replica-version-field"), })
  case_downgrade_precheck(env)
  reports.push({ id: "downgrade_precheck", status: Green, })
  case_rollback_explain(env)
  reports.push({ id: "rollback_explain", status: Green, })
  reports
}

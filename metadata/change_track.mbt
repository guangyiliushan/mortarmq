/// Persistent change tracking for the upgrade matrix (upgrade matrix
/// design rules 2 and 4 of the operations research README; the
/// downgrading gate of its rule 5).
///
/// Design note (the four rules, as the sources state them):
///
/// * Rule 4 (finalize): before any new-format write the metadata log
///   must carry an explicit feature flag. The completion criteria reuse
///   the registered ConfigUpdate record for it, so the flag rides that
///   record type and no new record type is introduced.
/// * Rule 5 (downgrading gate): downgrade is allowed only when no
///   metadata changed between the versions; the matrix splits format
///   bumps into a compatible tier (additive extension, old readers
///   read by the old rules) and an incompatible tier (version bump,
///   old readers must refuse).
/// * Compatible-tier rollback: allowed, and the caller lists the
///   downgrade preconditions -- the machine-checkable one is "no
///   metadata change since the upgrade point".
/// * Incompatible-tier rollback: refused, and the caller explains
///   which metadata changes are irreversible -- the enumerable one-way
///   list below.
///
/// Change classification (the tier table, destructive semantics are
/// one-way): TopicCreate/GroupCreate and the broker/leader records are
/// compatible; TopicDelete/GroupDelete are one-way (the data loss is
/// not undone by an old binary); a ConfigUpdate carrying a finalized
/// feature flag is one-way (finalizing is a one-way transition), while
/// a non-finalized flag entry is compatible. SnapshotHint records are
/// cache maintenance and track as no change at all.
///
/// `end_offset` on every tracked change is the log position just past
/// the change record, the same position identity the snapshots carry.

///|
pub(all) enum ChangeTier {
  /// The old binary still reads and serves this state.
  Compatible
  /// Downgrading loses or cannot interpret this state.
  OneWay
} derive(Eq, Debug)

///|
pub extend ChangeTier with Eq::{not_equal, equal}

///|
pub extend ChangeTier with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One tracked metadata change: where it landed, what kind it was, its
/// tier, and the name that explains it (topic or feature name; empty
/// when the kind carries none).
pub(all) struct TrackedChange {
  end_offset : UInt64
  kind : MmmlRecordType
  tier : ChangeTier
  detail : String
} derive(Eq, Debug)

///|
pub extend TrackedChange with Eq::{not_equal, equal}

///|
pub extend TrackedChange with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One downgrade precondition check for a compatible-tier rollback.
pub(all) struct PreconditionCheck {
  name : String
  passed : Bool
} derive(Eq, Debug)

///|
pub extend PreconditionCheck with Eq::{not_equal, equal}

///|
pub extend PreconditionCheck with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Encode one feature-flag entry for a ConfigUpdate payload: a 2-byte
/// big-endian name length, the name bytes, and a 1-byte finalized
/// state (0 announced, 1 finalized). One entry per record.
pub fn encode_feature_flag(name : String, finalized : Bool) -> Bytes {
  let name_bytes = @utf8.encode(name)
  let buf = Buffer()
  buf.write_uint16_be(name_bytes.length().to_uint16())
  buf.write_bytes(name_bytes)
  buf.write_byte(if finalized { 1 } else { 0 })
  buf.contents()
}

///|
/// Decode one feature-flag entry from a ConfigUpdate payload.
///
/// Returns `None` for a truncated or overlong payload, a state byte
/// that is neither 0 nor 1, or a name that is not valid UTF-8.
pub fn decode_feature_flag(payload : BytesView) -> (String, Bool)? {
  let name_len = match read_uint16_be(payload, 0) {
    Ok(value) => value.to_int()
    Err(_) => return None
  }
  if payload.length() != 3 + name_len {
    return None
  }
  let name = @utf8.decode(payload[2:2 + name_len]) catch {
    Malformed(_) => return None
  }
  match payload[2 + name_len].to_uint() {
    0U => Some((name, false))
    1U => Some((name, true))
    _ => None
  }
}

///|
/// Durable change tracking: the feature flags on record and every
/// tracked change in log order. Both ride the metadata snapshot so a
/// recovery that resumes past a snapshot still answers the upgrade
/// questions over the whole history.
pub(all) struct ChangeTracker {
  flags : Map[String, Bool]
  mut changes : Array[TrackedChange]
}

///|
pub fn ChangeTracker::new() -> ChangeTracker {
  { flags: Map([]), changes: [], }
}

///|
/// The tier of one record kind (the classification table above).
fn change_tier(kind : MmmlRecordType) -> ChangeTier {
  match kind {
    TopicDelete | GroupDelete => OneWay
    TopicCreate
    | TopicUpdate
    | GroupCreate
    | GroupUpdate
    | BrokerRegister
    | BrokerDeregister
    | LeaderElect
    | LeaderResign
    | ConfigUpdate
    | SnapshotHint
    | UnknownFallback => Compatible
  }
}

///|
/// Track one decoded record as of the log position just past it.
///
/// SnapshotHint records track as no change (cache maintenance). A
/// ConfigUpdate record must decode as one feature-flag entry; its
/// finalized state upgrades the tier to one-way. Every other record
/// tracks under the classification table.
///
/// # Errors
///
/// * `Malformed` -- a ConfigUpdate payload that is not exactly one
///   feature-flag entry.
pub fn ChangeTracker::track(
  self : ChangeTracker,
  end_offset : UInt64,
  record : MmmlRecord,
) -> Result[Unit, MetadataFault] {
  let kind = record.header.record_type
  if kind == SnapshotHint {
    return Ok(())
  }
  let mut tier = change_tier(kind)
  let mut detail = ""
  if kind == ConfigUpdate {
    match decode_feature_flag(record.payload[:]) {
      Some((name, finalized)) => {
        self.flags.set(name, finalized)
        detail = name
        if finalized {
          tier = OneWay
        }
      }
      None => return Err(Malformed)
    }
  } else {
    match decode_declare_body(kind, record.payload[:]) {
      Some(body) => detail = body.key()
      None => ()
    }
  }
  self.changes.push({ end_offset, kind, tier, detail, })
  Ok(())
}

///|
/// Whether the named feature is finalized (rule 4: new-format writes
/// are authorized only after this answers true).
pub fn ChangeTracker::is_finalized(self : ChangeTracker, name : String) -> Bool {
  match self.flags.get(name) {
    Some(finalized) => finalized
    None => false
  }
}

///|
/// Whether any tracked change landed after the given log position
/// (rule 5: the downgrade gate is "no metadata change since").
pub fn ChangeTracker::has_changes_since(
  self : ChangeTracker,
  end_offset : UInt64,
) -> Bool {
  for change in self.changes {
    if change.end_offset > end_offset {
      return true
    }
  }
  false
}

///|
/// The one-way changes on record, in log order -- the explanation a
/// refused rollback gives.
pub fn ChangeTracker::one_way_changes(
  self : ChangeTracker,
) -> Array[TrackedChange] {
  let out : Array[TrackedChange] = []
  for change in self.changes {
    if change.tier == OneWay {
      out.push(change)
    }
  }
  out
}

///|
/// List the downgrade preconditions of the compatible-tier rollback:
/// the checks the matrix script must show. A rollback is allowed
/// exactly when every check passes.
pub fn ChangeTracker::downgrade_preconditions(
  self : ChangeTracker,
  upgrade_end_offset : UInt64,
) -> Array[PreconditionCheck] {
  [
    {
      name: "no metadata change since the upgrade point",
      passed: !self.has_changes_since(upgrade_end_offset),
    },
    {
      name: "no finalized feature on record",
      passed: self.one_way_changes().length() == 0,
    },
  ]
}

/// Exercise metadata-side quarantine and read-only degradation (T058).

///|
test "gate starts healthy with an open write path" {
  let gate = @metadata.MetadataGuard::new()
  assert_eq(gate.mode(), @metadata.MetadataMode::Healthy)
  assert_eq(gate.write_refusal_code(), None)
  assert_eq(gate.entries().length(), 0)
}

///|
test "record corruption degrades to read-only and quarantines the region" {
  let gate = @metadata.MetadataGuard::new()
  gate.note_log_corruption(64U, 40U)
  assert_eq(gate.mode(), @metadata.MetadataMode::ReadOnly)
  assert_eq(gate.write_refusal_code(), Some(@metadata.METADATA_READ_ONLY_CODE))
  assert_eq(gate.entries(), [{ offset: 64U, length: 40U, }])
}

///|
test "escalation asks for human intervention and restore reopens writes" {
  let gate = @metadata.MetadataGuard::new()
  gate.note_log_corruption(64U, 40U)
  gate.note_log_corruption(128U, 40U)
  gate.escalate_to_quarantine()
  assert_eq(gate.mode(), @metadata.MetadataMode::Quarantined)
  assert_eq(
    gate.write_refusal_code(),
    Some(@metadata.METADATA_QUARANTINED_CODE),
  )
  gate.restore_healthy()
  assert_eq(gate.mode(), @metadata.MetadataMode::Healthy)
  assert_eq(gate.write_refusal_code(), None)
  assert_eq(gate.entries().length(), 2)
}

///|
test "write refusal codes match the protocol registry" {
  assert_eq(@metadata.METADATA_READ_ONLY_CODE, 0x2003U.to_uint16())
  assert_eq(@metadata.METADATA_QUARANTINED_CODE, 0x2004U.to_uint16())
}

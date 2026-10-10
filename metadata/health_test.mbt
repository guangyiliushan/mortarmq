/// Exercise metadata-side quarantine and read-only degradation (T058).

///|
test "gate starts healthy with an open write path" {
  let gate = @metadata.MetadataGuard::new()
  assert_eq(gate.mode(), @metadata.MetadataMode::Healthy)
  assert_eq(gate.writeRefusalCode(), None)
  assert_eq(gate.entries().length(), 0)
}

///|
test "record corruption degrades to read-only and quarantines the region" {
  let gate = @metadata.MetadataGuard::new()
  gate.noteLogCorruption(64U, 40U)
  assert_eq(gate.mode(), @metadata.MetadataMode::ReadOnly)
  assert_eq(gate.writeRefusalCode(), Some(@metadata.METADATA_READ_ONLY_CODE))
  assert_eq(gate.entries(), [{ offset: 64U, length: 40U, }])
}

///|
test "escalation asks for human intervention and restore reopens writes" {
  let gate = @metadata.MetadataGuard::new()
  gate.noteLogCorruption(64U, 40U)
  gate.noteLogCorruption(128U, 40U)
  gate.escalateToQuarantine()
  assert_eq(gate.mode(), @metadata.MetadataMode::Quarantined)
  assert_eq(gate.writeRefusalCode(), Some(@metadata.METADATA_QUARANTINED_CODE))
  gate.restoreHealthy()
  assert_eq(gate.mode(), @metadata.MetadataMode::Healthy)
  assert_eq(gate.writeRefusalCode(), None)
  assert_eq(gate.entries().length(), 2)
}

///|
test "write refusal codes match the protocol registry" {
  assert_eq(@metadata.METADATA_READ_ONLY_CODE, 0x2003U.to_uint16())
  assert_eq(@metadata.METADATA_QUARANTINED_CODE, 0x2004U.to_uint16())
}

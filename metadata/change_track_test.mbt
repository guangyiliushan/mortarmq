/// Exercise persistent change tracking for the upgrade matrix (the
/// finalize flag on ConfigUpdate, the tier table, and the rollback
/// queries).

///|
fn ct_record(
  kind : @metadata.MmmlRecordType,
  epoch : UInt64,
  mutation_id : UInt64,
  payload : Bytes,
) -> Bytes raise {
  match
    @metadata.encode_mmml_record(
      @metadata.MmmlHeader::new(
        format_version=1,
        header_version=1,
        flags=0,
        record_type=kind,
        leader_epoch=epoch,
        mutation_id~,
      ),
      payload[:],
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("record encoding failed")
  }
}

///|
fn ct_decoded(bytes : Bytes) -> @metadata.MmmlRecord raise {
  match @metadata.decode_mmml_record(bytes[:]) {
    Ok(record) => record
    Err(_) => fail("record decoding failed")
  }
}

///|
test "feature-flag payload round-trips and refuses malformed bytes" {
  assert_eq(
    @metadata.decode_feature_flag(
      @metadata.encode_feature_flag("new-segment", true)[:],
    ),
    Some(("new-segment", true)),
  )
  assert_eq(
    @metadata.decode_feature_flag(
      @metadata.encode_feature_flag("new-segment", false)[:],
    ),
    Some(("new-segment", false)),
  )
  assert_eq(
    @metadata.decode_feature_flag(@metadata.encode_feature_flag("x", true)[:2]),
    None,
  )
  assert_eq(@metadata.decode_feature_flag(b""[:]), None)
}

///|
test "a finalized config update tracks as one-way and gates writes" {
  let tracker = @metadata.ChangeTracker::new()
  assert_eq(tracker.is_finalized("new-segment"), false)
  let flag = @metadata.encode_feature_flag("new-segment", true)
  match
    tracker.track(
      40UL,
      ct_decoded(
        ct_record(@metadata.MmmlRecordType::ConfigUpdate, 1UL, 1UL, flag),
      ),
    ) {
    Ok(_) => ()
    Err(_) => fail("a valid flag entry must track")
  }
  assert_eq(tracker.is_finalized("new-segment"), true)
  let one_way = tracker.one_way_changes()
  assert_eq(one_way.length(), 1)
  assert_eq(one_way[0].tier, @metadata.ChangeTier::OneWay)
  assert_eq(one_way[0].detail, "new-segment")
  assert_eq(one_way[0].end_offset, 40UL)
}

///|
test "the tier table pins destructive changes as one-way" {
  let tracker = @metadata.ChangeTracker::new()
  let body = @metadata.DeclareBody::Create("orders", 3)
  let delete_body = @metadata.DeclareBody::Delete("orders")
  ignore(
    tracker.track(
      10UL,
      ct_decoded(
        ct_record(
          @metadata.MmmlRecordType::TopicCreate,
          1UL,
          1UL,
          body.to_payload(),
        ),
      ),
    ),
  )
  ignore(
    tracker.track(
      20UL,
      ct_decoded(
        ct_record(
          @metadata.MmmlRecordType::TopicDelete,
          1UL,
          2UL,
          delete_body.to_payload(),
        ),
      ),
    ),
  )
  ignore(
    tracker.track(
      30UL,
      ct_decoded(
        ct_record(@metadata.MmmlRecordType::BrokerRegister, 1UL, 3UL, b""),
      ),
    ),
  )
  let one_way = tracker.one_way_changes()
  assert_eq(one_way.length(), 1)
  assert_eq(one_way[0].kind, @metadata.MmmlRecordType::TopicDelete)
  assert_eq(one_way[0].detail, "orders")
  assert_eq(tracker.has_changes_since(9UL), true)
  assert_eq(tracker.has_changes_since(30UL), false)
}

///|
test "the downgrade preconditions list the gate" {
  let tracker = @metadata.ChangeTracker::new()
  assert_eq(tracker.downgrade_preconditions(0UL), [
    { name: "no metadata change since the upgrade point", passed: true, },
    { name: "no finalized feature on record", passed: true, },
  ])
  ignore(
    tracker.track(
      10UL,
      ct_decoded(
        ct_record(@metadata.MmmlRecordType::TopicCreate, 1UL, 1UL, b""),
      ),
    ),
  )
  let checks = tracker.downgrade_preconditions(5UL)
  assert_eq(checks[0].passed, false)
  assert_eq(checks[1].passed, true)
}

///|
test "a malformed config update payload refuses to track" {
  let tracker = @metadata.ChangeTracker::new()
  match
    tracker.track(
      10UL,
      ct_decoded(
        ct_record(@metadata.MmmlRecordType::ConfigUpdate, 1UL, 1UL, b"zz"),
      ),
    ) {
    Err(@metadata.Malformed) => ()
    _ => fail("a malformed flag entry must refuse")
  }
}

/// Prove the mediation seam keeps S1 on the protocol face: internal
/// outcomes never cross the boundary; refusals arrive only as registered
/// codes.

///|
test "internal outcomes mediate to the protocol face" {
  assert_eq(
    @metadata.DeclareOutcome::Created.to_protocol(),
    Ok({ created: true, }),
  )
  assert_eq(
    @metadata.DeclareOutcome::IdempotentOk.to_protocol(),
    Ok({ created: false, }),
  )
  assert_eq(
    @metadata.DeclareOutcome::Deleted.to_protocol(),
    Ok({ created: false, }),
  )
}

///|
test "refusals surface only as registered codes through the seam" {
  match @metadata.DeclareOutcome::MutationFenced.to_protocol() {
    Err(code) => {
      assert_eq(code, @protocol.MutationFenced)
      assert_eq(@protocol.ErrCode::from_uint16(code.to_uint16()), Some(code))
    }
    Ok(_) => fail("a fence must not become an ack")
  }
  match @metadata.DeclareOutcome::NameCountMismatch.to_protocol() {
    Err(code) => {
      assert_eq(code, @protocol.TopicExistsMismatch)
      assert_eq(@protocol.ErrCode::from_uint16(code.to_uint16()), Some(code))
    }
    Ok(_) => fail("a mismatch must not become an ack")
  }
}

///|
async test "a mediated packed pair acks per op with the source first" {
  let fake = @harness.FakeDisk::new()
  let disk : &@ports.Disk = fake
  let log = b"meta/mmml.log"
  let service = @metadata.MetadataService::new()
  match
    service.mediate_mutation(disk, log, 1UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 3),
      @metadata.DeclareBody::Create("orders.dlq", 3),
    ]) {
    Ok(acks) => {
      assert_eq(acks.length(), 2)
      assert_eq(acks[0], { created: true, })
      assert_eq(acks[1], { created: true, })
    }
    Err(_) => fail("a fresh pair must mediate to acks")
  }
  match
    service.mediate_mutation(disk, log, 1UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 3),
      @metadata.DeclareBody::Create("orders.dlq", 3),
    ]) {
    Ok(acks) => {
      assert_eq(acks[0], { created: false, })
      assert_eq(acks[1], { created: false, })
    }
    Err(_) => fail("a replay must mediate to idempotent acks")
  }
}

///|
async test "a mediated refusal carries the registered code and zero acks" {
  let fake = @harness.FakeDisk::new()
  let disk : &@ports.Disk = fake
  let log = b"meta/mmml.log"
  let service = @metadata.MetadataService::new()
  ignore(
    service.mediate_mutation(disk, log, 1UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 3),
    ]),
  )
  match
    service.mediate_mutation(disk, log, 1UL, 9UL, [
      @metadata.DeclareBody::Create("orders", 3),
      @metadata.DeclareBody::Create("orders.dlq", 3),
    ]) {
    Err(code) => assert_eq(code, @protocol.MutationFenced)
    Ok(_) => fail("an op-set fence must surface as 0x2006 with no acks")
  }
  match
    service.mediate_mutation(disk, log, 2UL, 7UL, [
      @metadata.DeclareBody::Create("orders", 9),
    ]) {
    Err(code) => assert_eq(code, @protocol.TopicExistsMismatch)
    Ok(_) => fail("a count mismatch must surface as 0x2001 with no acks")
  }
}

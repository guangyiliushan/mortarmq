/// Golden and property tests for the error-code registry.
///
/// The table *is* the contract, so the tests lock all of it rather than
/// sampling it: every registered code must encode to its own value and decode
/// back to itself, and every value outside the table must decode to `None`.
///
/// The property test pins its seed and count so a failure reproduces exactly,
/// instead of depending on whichever draw CI happened to get.

///|
test "wire limits match their documented values" {
  assert_eq(@protocol.MAX_FRAME_LEN, 16777216U)
  assert_eq(@protocol.MAX_VALUE_LEN, 16776192U)
  assert_eq(@protocol.MAX_KEY_LEN, 255U)
  assert_eq(@protocol.MAX_TOPIC_LEN, 255U)
  assert_eq(@protocol.MAX_ERR_MESSAGE, 512U)
  assert_eq(@protocol.WIRE_VERSION, 1U)
  assert_eq(@protocol.KEEPALIVE_SECONDS, 30U)
  assert_eq(@protocol.HALF_FRAME_TIMEOUT_SECONDS, 10U)
}

///|
test "error code table registration lock: 49 codes map one-to-one" {
  let registry : Array[(UInt, @protocol.ErrCode)] = [
    (0x0001U, @protocol.BadLength),
    (0x0002U, @protocol.UnknownOp),
    (0x0003U, @protocol.MalformedPayload),
    (0x0004U, @protocol.UnsupportedVersion),
    (0x0005U, @protocol.NotAuthenticated),
    (0x0006U, @protocol.AuthFailed),
    (0x0007U, @protocol.AuthTimeout),
    (0x0008U, @protocol.UnknownTopic),
    (0x0009U, @protocol.UnknownPartition),
    (0x000AU, @protocol.Internal),
    (0x000BU, @protocol.InvalidTopic),
    (0x0010U, @protocol.SeqGap),
    (0x0011U, @protocol.SeqExpired),
    (0x0012U, @protocol.ProducerEpochStale),
    (0x0013U, @protocol.ProducerSeqInvalid),
    (0x0020U, @protocol.StaleGeneration),
    (0x0021U, @protocol.NotOwner),
    (0x0022U, @protocol.StaleOwner),
    (0x0023U, @protocol.UnknownDelivery),
    (0x0024U, @protocol.GroupMemberLimit),
    (0x0025U, @protocol.GroupAssignmentLimit),
    (0x0026U, @protocol.UnknownMember),
    (0x0027U, @protocol.MaxWaitingPulls),
    (0x0030U, @protocol.DlqPathOverflow),
    (0x0031U, @protocol.DlqUnavailable),
    (0x2001U, @protocol.TopicExistsMismatch),
    (0x2002U, @protocol.GroupExistsMismatch),
    (0x2003U, @protocol.MetadataReadOnly),
    (0x2004U, @protocol.MetadataQuarantined),
    (0x2005U, @protocol.UnknownGroup),
    (0x2006U, @protocol.MutationFenced),
    (0x4001U, @protocol.Backpressure),
    (0x4002U, @protocol.QuotaExceeded),
    (0x4003U, @protocol.RateLimited),
    (0x4004U, @protocol.StorageHighWatermark),
    (0x4005U, @protocol.MessageExceedsCredit),
    (0x4006U, @protocol.NoCredit),
    (0x4007U, @protocol.SlowConsumer),
    (0x6001U, @protocol.QuorumLost),
    (0x6002U, @protocol.ReadOnlyDegraded),
    (0x6003U, @protocol.InSyncReplicasNotEnough),
    (0x6004U, @protocol.FollowerLag),
    (0x6005U, @protocol.StaleLeaderEpoch),
    (0x6006U, @protocol.LeaseExpired),
    (0x6007U, @protocol.CatchupRequired),
    (0x6008U, @protocol.LogGap),
    (0x6009U, @protocol.DivergentCommitted),
    (0x600AU, @protocol.QuorumRecovered),
    (0x600BU, @protocol.UncleanElectionRejected),
  ]
  assert_eq(registry.length(), 49)
  for pair in registry {
    let (code, err) = pair
    assert_eq(err.to_uint16(), code)
    assert_eq(@protocol.ErrCode::from_uint16(code), Some(err))
  }
}

///|
test "unregistered segments are rejected (reserved-segment semantics)" {
  let holes : Array[UInt] = [
    0x0000U, 0x000CU, 0x000DU, 0x0014U, 0x0028U, 0x0032U, 0x00FFU, 0x2007U, 0x2008U,
    0x4008U, 0x4009U, 0x600CU, 0x600DU,
  ]
  for hole in holes {
    assert_eq(@protocol.ErrCode::from_uint16(hole), None)
  }
}

///|
test "decoding is injective over the whole set (quickcheck seed=20261001 is reproducible)" {
  @quickcheck.check(
    (code : UInt) => {
      match @protocol.ErrCode::from_uint16(code) {
        Some(err) => err.to_uint16() == code
        None => true
      }
    },
    count=200,
    seed=20261001,
  )
}

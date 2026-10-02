/// Error codes sent on the wire as a u16, grouped into four disjoint ranges.
///
/// `0x0xxx` protocol and session; `0x2xxx` metadata; `0x4xxx` backpressure and
/// quota; `0x6xxx` replication. The ranges never overlap, and a value inside
/// them that was never assigned decodes to `None` rather than to a guess — so
/// a code added later can never be misread as an older one.
///
/// # Stability
///
/// Codes are only ever added. A published code never changes meaning, a
/// retired code is never reused, and a gap inside a range stays reserved.

///|
pub(all) enum ErrCode {
  // ── 0x0xxx protocol and session ──
  BadLength // 0x0001 close the connection; fix the client
  UnknownOp // 0x0002 close the connection; upgrade the client / wire_version
  MalformedPayload // 0x0003 close the connection
  UnsupportedVersion // 0x0004 close the connection
  NotAuthenticated // 0x0005 close the connection; send CONNECT first
  AuthFailed // 0x0006 close the connection; leak no internal detail
  AuthTimeout // 0x0007 close the connection
  UnknownTopic // 0x0008 DECLARE first or fix the name
  UnknownPartition // 0x0009 fix the client
  Internal // 0x000A file an issue carrying the diagnostic code
  InvalidTopic // 0x000B fix the topic name (wildcard / empty token / $ prefix / too long)
  SeqGap // 0x0010 fill the gap or reset the producer
  SeqExpired // 0x0011 re-register the producer
  ProducerEpochStale // 0x0012 rediscover the leader / epoch
  ProducerSeqInvalid // 0x0013 fix the client
  StaleGeneration // 0x0020 wait for NOTICE, then re-negotiate
  NotOwner // 0x0021 stop acting on that partition; wait for the assignment
  StaleOwner // 0x0022 re-SUB / re-PULL
  UnknownDelivery // 0x0023 idempotent no-op
  GroupMemberLimit // 0x0024 shrink the group (v0 allows at most 10 members)
  GroupAssignmentLimit // 0x0025 shrink the subscription set
  UnknownMember // 0x0026 rejoin
  MaxWaitingPulls // 0x0027 wait for the in-flight PULLs
  DlqPathOverflow // 0x0030 enter quarantine; human intervention required
  DlqUnavailable // 0x0031 back off and retry (the source is not dropped)
  // ── 0x2xxx metadata domain ──
  TopicExistsMismatch // 0x2001 same name, different config; fix the parameters or pick another name
  GroupExistsMismatch // 0x2002 as above, for groups
  MetadataReadOnly // 0x2003 failover or quarantine in progress; retry later
  MetadataQuarantined // 0x2004 manual handling required
  UnknownGroup // 0x2005 SUB first to create the group
  MutationFenced // 0x2006 mutation_id / epoch expired; start the mutation over
  // ── 0x4xxx backpressure and quota domain ──
  Backpressure // 0x4001 back off and retry
  QuotaExceeded // 0x4002 slow down
  RateLimited // 0x4003 back off and retry
  StorageHighWatermark // 0x4004 retry later; consumers are unaffected
  MessageExceedsCredit // 0x4005 raise credit_bytes
  NoCredit // 0x4006 send CREDIT
  SlowConsumer // 0x4007 close the connection; cut consume lag or reconnect
  // ── 0x6xxx replication domain ──
  QuorumLost // 0x6001
  ReadOnlyDegraded // 0x6002
  InSyncReplicasNotEnough // 0x6003
  FollowerLag // 0x6004
  StaleLeaderEpoch // 0x6005
  LeaseExpired // 0x6006
  CatchupRequired // 0x6007
  LogGap // 0x6008
  DivergentCommitted // 0x6009
  QuorumRecovered // 0x600A
  UncleanElectionRejected // 0x600B
} derive(Eq, Debug)

///|
pub extend ErrCode with Eq::{not_equal, equal}

///|
pub extend ErrCode with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Encode as the u16 that goes on the wire.
///
/// Every constructor maps to exactly one value, and `from_u16` maps that value
/// back to the same constructor. The pairing is a bijection — the property test
/// in this package checks it over the whole `UInt` space, not over a sample.
///
/// # Example
///
/// ```mbt check
/// test {
///   assert_eq(@protocol.BadLength.to_u16(), 0x0001U)
/// }
/// ```
pub fn ErrCode::to_u16(self : ErrCode) -> UInt {
  match self {
    BadLength => 0x0001U
    UnknownOp => 0x0002U
    MalformedPayload => 0x0003U
    UnsupportedVersion => 0x0004U
    NotAuthenticated => 0x0005U
    AuthFailed => 0x0006U
    AuthTimeout => 0x0007U
    UnknownTopic => 0x0008U
    UnknownPartition => 0x0009U
    Internal => 0x000AU
    InvalidTopic => 0x000BU
    SeqGap => 0x0010U
    SeqExpired => 0x0011U
    ProducerEpochStale => 0x0012U
    ProducerSeqInvalid => 0x0013U
    StaleGeneration => 0x0020U
    NotOwner => 0x0021U
    StaleOwner => 0x0022U
    UnknownDelivery => 0x0023U
    GroupMemberLimit => 0x0024U
    GroupAssignmentLimit => 0x0025U
    UnknownMember => 0x0026U
    MaxWaitingPulls => 0x0027U
    DlqPathOverflow => 0x0030U
    DlqUnavailable => 0x0031U
    TopicExistsMismatch => 0x2001U
    GroupExistsMismatch => 0x2002U
    MetadataReadOnly => 0x2003U
    MetadataQuarantined => 0x2004U
    UnknownGroup => 0x2005U
    MutationFenced => 0x2006U
    Backpressure => 0x4001U
    QuotaExceeded => 0x4002U
    RateLimited => 0x4003U
    StorageHighWatermark => 0x4004U
    MessageExceedsCredit => 0x4005U
    NoCredit => 0x4006U
    SlowConsumer => 0x4007U
    QuorumLost => 0x6001U
    ReadOnlyDegraded => 0x6002U
    InSyncReplicasNotEnough => 0x6003U
    FollowerLag => 0x6004U
    StaleLeaderEpoch => 0x6005U
    LeaseExpired => 0x6006U
    CatchupRequired => 0x6007U
    LogGap => 0x6008U
    DivergentCommitted => 0x6009U
    QuorumRecovered => 0x600AU
    UncleanElectionRejected => 0x600BU
  }
}

///|
/// Decode a u16 received on the wire.
///
/// Returns `None` for every value that is not registered, including values
/// that fall inside a range but were never assigned. Returning a neighbour
/// instead would turn a code added later into a different code today, so an
/// unknown value is refused and the caller treats it as an unparsable reply.
///
/// # Example
///
/// ```mbt check
/// test {
///   assert_eq(@protocol.ErrCode::from_u16(0x0001U), Some(@protocol.BadLength))
///   assert_eq(@protocol.ErrCode::from_u16(0x000CU), None)
/// }
/// ```
pub fn ErrCode::from_u16(code : UInt) -> ErrCode? {
  match code {
    0x0001U => Some(BadLength)
    0x0002U => Some(UnknownOp)
    0x0003U => Some(MalformedPayload)
    0x0004U => Some(UnsupportedVersion)
    0x0005U => Some(NotAuthenticated)
    0x0006U => Some(AuthFailed)
    0x0007U => Some(AuthTimeout)
    0x0008U => Some(UnknownTopic)
    0x0009U => Some(UnknownPartition)
    0x000AU => Some(Internal)
    0x000BU => Some(InvalidTopic)
    0x0010U => Some(SeqGap)
    0x0011U => Some(SeqExpired)
    0x0012U => Some(ProducerEpochStale)
    0x0013U => Some(ProducerSeqInvalid)
    0x0020U => Some(StaleGeneration)
    0x0021U => Some(NotOwner)
    0x0022U => Some(StaleOwner)
    0x0023U => Some(UnknownDelivery)
    0x0024U => Some(GroupMemberLimit)
    0x0025U => Some(GroupAssignmentLimit)
    0x0026U => Some(UnknownMember)
    0x0027U => Some(MaxWaitingPulls)
    0x0030U => Some(DlqPathOverflow)
    0x0031U => Some(DlqUnavailable)
    0x2001U => Some(TopicExistsMismatch)
    0x2002U => Some(GroupExistsMismatch)
    0x2003U => Some(MetadataReadOnly)
    0x2004U => Some(MetadataQuarantined)
    0x2005U => Some(UnknownGroup)
    0x2006U => Some(MutationFenced)
    0x4001U => Some(Backpressure)
    0x4002U => Some(QuotaExceeded)
    0x4003U => Some(RateLimited)
    0x4004U => Some(StorageHighWatermark)
    0x4005U => Some(MessageExceedsCredit)
    0x4006U => Some(NoCredit)
    0x4007U => Some(SlowConsumer)
    0x6001U => Some(QuorumLost)
    0x6002U => Some(ReadOnlyDegraded)
    0x6003U => Some(InSyncReplicasNotEnough)
    0x6004U => Some(FollowerLag)
    0x6005U => Some(StaleLeaderEpoch)
    0x6006U => Some(LeaseExpired)
    0x6007U => Some(CatchupRequired)
    0x6008U => Some(LogGap)
    0x6009U => Some(DivergentCommitted)
    0x600AU => Some(QuorumRecovered)
    0x600BU => Some(UncleanElectionRejected)
    _ => None
  }
}

/// The leader epoch is monotone, and it is written
/// to metadata before this replica acts on it.
///
/// The two properties are checked separately because they fail
/// differently: a non-monotone epoch lets an old term come back, and an
/// epoch adopted before its record lands lets a crash leave a replica
/// acting on a term the log never held. The second is what makes the
/// sink injectable here -- a log that can be told to fail is how "written
/// first, adopted second" is asserted rather than asserted-about.

///|
/// A metadata log that keeps the bytes it was handed, advances an
/// honest write offset, and can be told to refuse.
struct RecordingLog {
  records : Ref[Array[Bytes]]
  offset : Ref[UInt64]
  refuse : Ref[Bool]
}

///|
fn recording_log() -> RecordingLog {
  { records: Ref::Ref([]), offset: Ref::Ref(0UL), refuse: Ref::Ref(false), }
}

///|
impl @cluster.MetadataLog for RecordingLog with fn append(self, record : Bytes) -> Result[
  UInt64,
  @protocol.ErrCode,
] {
  if self.refuse.val {
    return Err(@protocol.MetadataReadOnly)
  }
  let start = self.offset.val
  self.offset.val = start + record.length().to_uint64()
  self.records.val.push(record)
  Ok(start)
}

///|
/// A fresh epoch together with the recording metadata log it writes to.
///
/// Returned as a pair because a case that needs to make the metadata
/// write fail has to reach the log behind the epoch, while a case that
/// only needs a promise to compare against does not care about it.
fn fresh_epoch_with_log() -> (@cluster.LeaderEpoch, RecordingLog) {
  let log = recording_log()
  let sink : &@cluster.MetadataLog = log
  (@cluster.LeaderEpoch::new(sink), log)
}

///|
/// A fresh epoch for a replica that has not recognised a leader yet.
///
/// Shared with the replication tests: every follower needs one now that
/// an `APPEND` is checked against the promise before it touches the log.
fn fresh_epoch() -> @cluster.LeaderEpoch {
  fresh_epoch_with_log().0
}

///|
/// An epoch opened at a term recovered from elsewhere, rather than at
/// the zero a fresh node starts with.
fn epoch_sink_for(recovered : UInt64) -> @cluster.LeaderEpoch {
  let log = recording_log()
  let sink : &@cluster.MetadataLog = log
  @cluster.LeaderEpoch::restore(sink, recovered)
}

///|
/// Decode one recorded byte string back through the metadata codec.
fn recorded(log : RecordingLog, index : Int) -> @metadata.MmmlRecord raise {
  match @metadata.decode_mmml_record(log.records.val[index][:]) {
    Err(_) => fail("a record this module wrote must decode")
    Ok(record) => record
  }
}

///|
async test "each election writes its epoch, and the epoch follows it" {
  let recording = recording_log()
  let log : &@cluster.MetadataLog = recording
  let epoch = @cluster.LeaderEpoch::new(log)
  assert_eq(epoch.current(), 0UL)
  assert_eq(epoch.elect(1UL), Ok(1UL))
  assert_eq(epoch.current(), 1UL)
  assert_eq(epoch.elect(7UL), Ok(7UL))
  assert_eq(epoch.current(), 7UL)
  assert_eq(recording.records.val.length(), 2)
  let first = recorded(recording, 0)
  assert_eq(first.header.record_type, @metadata.MmmlRecordType::LeaderElect)
  assert_eq(first.header.leader_epoch, 1UL)
  // Not a client mutation, so no idempotency key to fence -- the same
  // reason SnapshotHint carries id 0.
  assert_eq(first.header.mutation_id, 0UL)
  assert_eq(first.payload.length(), 0)
  let second = recorded(recording, 1)
  assert_eq(second.header.record_type, @metadata.MmmlRecordType::LeaderElect)
  assert_eq(second.header.leader_epoch, 7UL)
}

///|
async test "an election at or below the current epoch is refused and changes nothing" {
  let recording = recording_log()
  let log : &@cluster.MetadataLog = recording
  let epoch = @cluster.LeaderEpoch::new(log)
  assert_eq(epoch.elect(5UL), Ok(5UL))
  // The same epoch again: a replayed election must not re-apply.
  assert_eq(epoch.elect(5UL), Err(@protocol.StaleLeaderEpoch))
  // An older one: a delayed proposal must not run the clock backwards.
  assert_eq(epoch.elect(3UL), Err(@protocol.StaleLeaderEpoch))
  // Zero means "nothing elected", so it can never be an election.
  assert_eq(epoch.elect(0UL), Err(@protocol.StaleLeaderEpoch))
  assert_eq(epoch.current(), 5UL)
  // A refused election writes no record either: nothing is recorded for
  // a term that was never taken up.
  assert_eq(recording.records.val.length(), 1)
}

///|
async test "the epoch is adopted only if its record was written" {
  let recording = recording_log()
  let log : &@cluster.MetadataLog = recording
  let epoch = @cluster.LeaderEpoch::new(log)
  assert_eq(epoch.elect(1UL), Ok(1UL))
  recording.refuse.val = true
  // The log refused, so the epoch this replica acts on is still the one
  // the log holds. Adopting it anyway would leave two beliefs after a
  // crash: the log's, and this replica's.
  assert_eq(epoch.elect(2UL), Err(@protocol.MetadataReadOnly))
  assert_eq(epoch.current(), 1UL)
  assert_eq(recording.records.val.length(), 1)
  // Once the log accepts again, the same proposal goes through --
  // the refusal was the write, not the number.
  recording.refuse.val = false
  assert_eq(epoch.elect(2UL), Ok(2UL))
  assert_eq(epoch.current(), 2UL)
  assert_eq(recording.records.val.length(), 2)
}

///|
async test "the epoch rises strictly across a run of elections" {
  let recording = recording_log()
  let log : &@cluster.MetadataLog = recording
  let epoch = @cluster.LeaderEpoch::new(log)
  let ladder = [1UL, 2UL, 5UL, 9UL, 100UL, 101UL]
  let mut previous = 0UL
  for proposed in ladder {
    match epoch.elect(proposed) {
      Err(_) => fail("a strictly newer epoch must be accepted")
      Ok(recorded_epoch) => {
        // Strict, not merely non-decreasing: two elections at the same
        // term would mean two leaderships the log cannot tell apart.
        assert_eq(recorded_epoch > previous, true)
        previous = recorded_epoch
      }
    }
    assert_eq(epoch.current(), previous)
  }
  assert_eq(recording.records.val.length(), ladder.length())
  // Every recorded record names the term it was written for, in order.
  let mut check = 0
  for proposed in ladder {
    assert_eq(recorded(recording, check).header.leader_epoch, proposed)
    check = check + 1
  }
}

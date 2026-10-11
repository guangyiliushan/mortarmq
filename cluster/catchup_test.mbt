/// Catch-up truncation: a divergent tail is dropped, and nothing of it
/// survives: no ghost records after a truncation.
///
/// The format has no compaction, so a truncation has nowhere to hide a
/// removed record and no reason to leave one behind. What these cases
/// assert is exactly that: the sequences that were cut are not readable
/// afterwards, the positions agree with what is actually held, and the
/// refusals leave the log untouched.

///|
/// An `APPEND` at `epoch` starting at `base`, carrying `payloads`.
fn batch_from(
  epoch : UInt64,
  base : UInt64,
  payloads : Array[Bytes],
) -> @cluster.AppendBatch {
  {
    leader_id: 2U.to_uint16(),
    leader_epoch: epoch,
    base_seq: base,
    flush_after_append: true,
    entries: payloads,
  }
}

///|
async test "a divergent tail is cut away before the batch lands" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let epoch = fresh_epoch()
  assert_eq(epoch.elect(1UL), Ok(1UL))

  // First batch: three entries, so the follower's tail runs to 3.
  let (first, _reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    epoch,
    batch_from(1UL, 1UL, [b"a", b"b", b"c"]),
  )
  match first {
    Err(_) => fail("the first batch must land")
    Ok(ack) => assert_eq(ack.flushed_seq, 3UL)
  }
  assert_eq(follower_log.held(), [1UL, 2UL, 3UL])

  // Second batch: the leader continues from sequence 2, so everything
  // this replica holds above 1 belongs to a history the leader does not
  // share. The tail goes, then the batch lands at 2.
  let (second, _reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    epoch,
    batch_from(1UL, 2UL, [b"p"]),
  )
  match second {
    Err(_) => fail("the divergent tail must be cut, not refused")
    Ok(ack) => assert_eq(ack.flushed_seq, 2UL)
  }
  // The property: sequence 3 is not readable any more. A counter that
  // still reported 3, or a placeholder standing where 3 used to be,
  // would both show up here.
  assert_eq(follower_log.held(), [1UL, 2UL])
  assert_eq(follower_log.last_appended_seq(), 2UL)
  assert_eq(follower_log.last_flushed_seq(), 2UL)
  assert_eq(trace.val.contains(("follower.truncate", 1UL)), true)
  // The cut happened before the batch, not after it: a truncation that
  // ran last would only be tidying up after the fact.
  let mut cut_at = -1
  let mut landed_at = -1
  for position in 0..<trace.val.length() {
    if trace.val[position] == ("follower.truncate", 1UL) {
      cut_at = position
    }
    if trace.val[position] == ("follower.append", 2UL) {
      landed_at = position
    }
  }
  assert_eq(cut_at >= 0, true)
  assert_eq(landed_at > cut_at, true)
}

///|
async test "a batch that would leave a gap is refused and the log stands" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let epoch = fresh_epoch()
  assert_eq(epoch.elect(1UL), Ok(1UL))
  let (first, _reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    epoch,
    batch_from(1UL, 1UL, [b"a", b"b"]),
  )
  match first {
    Err(_) => fail("the first batch must land")
    Ok(_) => ()
  }
  assert_eq(follower_log.held(), [1UL, 2UL])

  // The leader is at 5 while this replica stops at 2. Taking the batch
  // would punch sequences 3 and 4 out of the log, and this format has
  // no legitimate holes -- a gap is corruption, not a rewind marker.
  let (gap, reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    epoch,
    batch_from(1UL, 5UL, [b"e"]),
  )
  assert_eq(gap, Err(@protocol.CatchupRequired))
  match reply {
    Some(@cluster.PeerMsg::Reject(code)) =>
      assert_eq(code, @protocol.CatchupRequired.to_uint16().to_uint16())
    _ => fail("the follower must answer with a Reject frame")
  }
  assert_eq(follower_log.held(), [1UL, 2UL])
  assert_eq(follower_log.last_appended_seq(), 2UL)
  assert_eq(trace.val.contains(("follower.truncate", 4UL)), false)
}

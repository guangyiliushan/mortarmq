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
      assert_eq(code.to_uint(), @protocol.CatchupRequired.to_uint16())
    _ => fail("the follower must answer with a Reject frame")
  }
  assert_eq(follower_log.held(), [1UL, 2UL])
  assert_eq(follower_log.last_appended_seq(), 2UL)
  assert_eq(trace.val.contains(("follower.truncate", 4UL)), false)
}

///|
async test "a batch whose cut reaches the committed prefix is refused" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let follower_epoch = fresh_epoch()
  match follower_log.append([b"a", b"b", b"c", b"d"], true) {
    Err(_) => fail("the fixture log must accept its seed")
    Ok(_) => ()
  }
  assert_eq(follower_log.held(), [1UL, 2UL, 3UL, 4UL])

  // This replica has committed through three. The sender offers a base
  // of one, so the cut would be sequence zero -- underneath everything
  // that is already committed.
  let (outcome, reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    follower_epoch,
    claim(2U.to_uint16(), 1UL, 1UL),
    committed_seq=3UL,
  )
  assert_eq(outcome, Err(@protocol.DivergentCommitted))
  match reply {
    Some(@cluster.PeerMsg::Reject(code)) =>
      assert_eq(code.to_uint(), @protocol.DivergentCommitted.to_uint16())
    _ => fail("the follower must refuse with a Reject frame")
  }
  // Refused before the cut, not after it: all four entries are still
  // there, because a cut at or below the committed prefix is data loss
  // rather than reconciliation.
  assert_eq(follower_log.held(), [1UL, 2UL, 3UL, 4UL])
  assert_eq(trace.val.contains(("follower.truncate", 0UL)), false)
}

///|
async test "the same batch is cut when the committed prefix is below it" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let follower_epoch = fresh_epoch()
  match follower_log.append([b"a", b"b", b"c", b"d"], true) {
    Err(_) => fail("the fixture log must accept its seed")
    Ok(_) => ()
  }
  // Committed only through one, and the sender continues from two: the
  // cut lands exactly on the committed prefix, which is where it is
  // allowed to reach.
  let (outcome, _reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    follower_epoch,
    claim(2U.to_uint16(), 1UL, 2UL),
    committed_seq=1UL,
  )
  match outcome {
    Err(_) => fail("a cut above the committed prefix must be allowed")
    Ok(ack) => assert_eq(ack.flushed_seq, 2UL)
  }
  // Sequence one survives -- it is committed -- sequences two to four
  // belonged to a history the sender does not share and are gone, and
  // the batch took the slot the cut opened.
  assert_eq(follower_log.held(), [1UL, 2UL])
}

///|
/// A truncation leaves a record of where the tail was cut.
///
/// A log's end moving backwards is the one decrease an observer cannot
/// explain from outside: without a record, the cut this format performs
/// on a divergent tail and the failure that cut exists to catch look
/// exactly alike. The record is read off the node the round ran on,
/// which is where the cut is made, and it is read there for both
/// outcomes -- a round that cut nothing has nothing to say, and a round
/// refused before the cut has nothing to say either.
async test "a truncation records where the tail was cut, and a round that does not cut records nothing" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let follower_epoch = fresh_epoch()
  assert_eq(follower_epoch.elect(1UL), Ok(1UL))

  // A round that lands without cutting: the tail only grows, so there
  // is no decrease to explain.
  let untouched : Ref[@cluster.ClusterNode?] = Ref::Ref(None)
  let (first, _reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    follower_epoch,
    batch_from(1UL, 1UL, [b"a", b"b", b"c"]),
    observed=untouched,
  )
  match first {
    Err(_) => fail("the first batch must land")
    Ok(ack) => assert_eq(ack.flushed_seq, 3UL)
  }
  match untouched.val {
    None => fail("the round must hand back the node it ran on")
    Some(node) => assert_eq(node.last_truncation(), None)
  }

  // The divergent tail goes: sequences two and three belonged to a
  // history the sender does not share, and the cut lands at one.
  let cut : Ref[@cluster.ClusterNode?] = Ref::Ref(None)
  let (second, _reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    follower_epoch,
    batch_from(1UL, 2UL, [b"p"]),
    observed=cut,
  )
  match second {
    Err(_) => fail("the divergent tail must be cut, not refused")
    Ok(ack) => assert_eq(ack.flushed_seq, 2UL)
  }
  assert_eq(follower_log.held(), [1UL, 2UL])
  match cut.val {
    None => fail("the round must hand back the node it ran on")
    Some(node) => assert_eq(node.last_truncation(), Some(1UL))
  }

  // A batch refused before the cut reaches one: nothing moved backwards,
  // so nothing is recorded as having done so.
  let refused : Ref[@cluster.ClusterNode?] = Ref::Ref(None)
  let (gap, _reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    follower_epoch,
    batch_from(1UL, 5UL, [b"e"]),
    observed=refused,
  )
  assert_eq(gap, Err(@protocol.CatchupRequired))
  match refused.val {
    None => fail("the round must hand back the node it ran on")
    Some(node) => assert_eq(node.last_truncation(), None)
  }
}

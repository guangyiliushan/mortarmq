/// The epoch fence: a batch from an older term changes nothing.
///
/// The property under test is not "the follower says no" but "the
/// follower's log is byte-for-byte what it was". A stale leader that
/// gets rejected *after* its entries landed has still split the log --
/// the refusal arrives too late to undo the write -- so every case here
/// checks the log and the recorded trace, not only the return value.

///|
/// Run one hand-written `APPEND` against a follower that has already
/// completed the handshake, and report both the follower's verdict and
/// the frame the other end received.
///
/// The batch is written by hand rather than through `send_append`
/// because `send_append` stamps the leader's own current epoch; the
/// point of these cases is to offer an epoch the follower has not
/// promised, which only the raw frame can do.
async fn handwritten_append(
  follower_node_id : UInt16,
  initiator_node_id : UInt16,
  initiator_second_id : UInt16,
  follower_log : TracedLog,
  follower_epoch : @cluster.LeaderEpoch,
  batch : @cluster.AppendBatch,
) -> (Result[@cluster.AppendAck, @protocol.ErrCode], @cluster.PeerMsg?) {
  let secret = fixture_secret()
  let server = bind_loopback()
  let port = server.addr.port()
  let follower_config = handshake_config(
    follower_node_id,
    port,
    2U.to_uint16(),
    secret,
  )
  let initiator_config = handshake_config(
    initiator_node_id, port, initiator_second_id, secret,
  )
  let follower_outcome : Ref[Result[@cluster.AppendAck, @protocol.ErrCode]] = Ref::Ref(
    Err(@protocol.Internal),
  )
  let reply : Ref[@cluster.PeerMsg?] = Ref::Ref(None)
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => server.accept()) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          let node = @cluster.ClusterNode::new(follower_config)
          match @cluster.ClusterNode::serve_peer(node, conn) {
            Err(_) => ()
            Ok(_) =>
              follower_outcome.val = @cluster.ClusterNode::serve_append(
                node, conn, follower_log, follower_epoch,
              )
          }
          @net.Conn::close(conn)
        }
      }
    }
    match dial_loopback(port) {
      Err(_) => fail("the listener is bound, so the dial must connect")
      Ok(conn) => {
        let node = @cluster.ClusterNode::new(initiator_config)
        let expected = match initiator_config.peer_entry(follower_node_id) {
          None => fail("the follower must be in the static table")
          Some(entry) => entry
        }
        match @cluster.ClusterNode::dial_peer(node, conn, expected) {
          Err(_) =>
            fail("both sides hold the same secret, so the handshake must pass")
          Ok(_) => {
            match
              @cluster.write_peer_msg(conn, @cluster.PeerMsg::Append(batch)) {
              Err(_) => fail("the link is open, so the batch must be written")
              Ok(_) => ()
            }
            reply.val = match
              @async.with_timeout_opt(handshake_budget_ms(), () => {
                @cluster.read_peer_msg(conn)
              }) {
              None => None
              Some(result) =>
                match result {
                  Err(_) => None
                  Ok(msg) => Some(msg)
                }
            }
          }
        }
        @net.Conn::close(conn)
      }
    }
  }
  (follower_outcome.val, reply.val)
}

///|
/// An `APPEND` at `epoch` from the fixture's other member, carrying one
/// entry at base sequence 1.
fn batch_at(epoch : UInt64) -> @cluster.AppendBatch {
  {
    leader_id: 2U.to_uint16(),
    leader_epoch: epoch,
    base_seq: 1UL,
    flush_after_append: true,
    entries: [b"payload"],
  }
}

///|
async test "a batch from an older term is refused before the log is touched" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let epoch = fresh_epoch()
  assert_eq(epoch.elect(5UL), Ok(5UL))
  let (outcome, reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    epoch,
    batch_at(3UL),
  )
  // The refusal is the registered code, and it is the one the client
  // protocol reserves for exactly this: rediscover the leader.
  assert_eq(outcome, Err(@protocol.StaleLeaderEpoch))
  match reply {
    Some(@cluster.PeerMsg::Reject(code)) => {
      assert_eq(code, 0x6005U.to_uint16())
      assert_eq(
        @protocol.ErrCode::from_uint16(code.to_uint()),
        Some(@protocol.StaleLeaderEpoch),
      )
    }
    _ => fail("the follower must answer with a Reject frame")
  }
  // The property that makes this a fence rather than a politeness: the
  // log is byte-for-byte what it was. Refusing after the append would
  // still have left the bytes behind.
  assert_eq(follower_log.last_appended_seq(), 0UL)
  assert_eq(follower_log.last_flushed_seq(), 0UL)
  assert_eq(trace.val, [])
}

///|
async test "a batch at the epoch this replica already promised is accepted" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let epoch = fresh_epoch()
  assert_eq(epoch.elect(5UL), Ok(5UL))
  let (outcome, reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    epoch,
    batch_at(5UL),
  )
  match outcome {
    Err(_) => fail("a batch at the promised epoch must be accepted")
    Ok(ack) => assert_eq(ack.flushed_seq, 1UL)
  }
  match reply {
    Some(@cluster.PeerMsg::Ack(_)) => ()
    _ => fail("the follower must answer with an acknowledgement")
  }
  assert_eq(follower_log.last_appended_seq(), 1UL)
  // The promise itself did not move: this term was already recorded.
  assert_eq(epoch.current(), 5UL)
}

///|
async test "a newer term is adopted durably before any of its writes land" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let (epoch, sink) = fresh_epoch_with_log()
  assert_eq(epoch.elect(5UL), Ok(5UL))
  assert_eq(sink.records.val.length(), 1)
  // The metadata write fails, so the promise cannot be taken up -- and
  // a batch arriving under a promise this replica never recorded must
  // not touch the log either.
  sink.refuse.val = true
  let (outcome, _reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    epoch,
    batch_at(7UL),
  )
  assert_eq(outcome, Err(@protocol.MetadataReadOnly))
  assert_eq(epoch.current(), 5UL)
  assert_eq(follower_log.last_appended_seq(), 0UL)
  assert_eq(trace.val, [])
}

///|
async test "a newer term is adopted, recorded, and its writes land under it" {
  let trace : Ref[Array[(String, UInt64)]] = Ref::Ref([])
  let follower_log = traced_log("follower", trace)
  let (epoch, sink) = fresh_epoch_with_log()
  assert_eq(epoch.elect(5UL), Ok(5UL))
  let (outcome, reply) = handwritten_append(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    follower_log,
    epoch,
    batch_at(7UL),
  )
  match outcome {
    Err(_) => fail("a batch at a newer term must be accepted")
    Ok(ack) => assert_eq(ack.flushed_seq, 1UL)
  }
  match reply {
    Some(@cluster.PeerMsg::Ack(ack)) => assert_eq(ack.leader_epoch, 7UL)
    _ => fail("the follower must answer with an acknowledgement")
  }
  // The promise moved, and it moved in the metadata log rather than
  // only in memory: two records, the second naming the new term.
  assert_eq(epoch.current(), 7UL)
  assert_eq(sink.records.val.length(), 2)
  match @metadata.decode_mmml_record(sink.records.val[1][:]) {
    Err(_) => fail("the adopted promise must be a decodable record")
    Ok(record) => {
      assert_eq(
        record.header.record_type,
        @metadata.MmmlRecordType::LeaderElect,
      )
      assert_eq(record.header.leader_epoch, 7UL)
    }
  }
  assert_eq(follower_log.last_appended_seq(), 1UL)
}

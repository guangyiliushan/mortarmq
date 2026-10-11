/// What a peer may claim before it has proved anything, and how long a
/// frame may take to arrive.
///
/// The claim and the allocation are the same number in a naive reader:
/// four bytes arrive, say sixteen megabytes, and sixteen megabytes are
/// handed over before a single further byte has been seen. On an
/// established link that is a cost; on the handshake's very first read
/// it is a cost an unauthenticated peer chooses, and chooses again for
/// every connection it opens. These cases pin the two things that stop
/// it -- a pre-authentication bound and a deadline -- and the chunking
/// that keeps a declared length from being an allocation size at all.

///|
/// Write `outbound` at one end of a fresh loopback link and read it at
/// the other end, under whichever bound the case is about.
async fn crafted_read(
  outbound : Bytes,
  pre_auth : Bool,
  deadline_ms : Int,
  hold_open_ms? : Int = 0,
) -> Result[@cluster.PeerMsg, @protocol.ErrCode] {
  let server = bind_loopback()
  let port = server.addr.port()
  let outcome : Ref[Result[@cluster.PeerMsg, @protocol.ErrCode]] = Ref::Ref(
    Err(@protocol.Internal),
  )
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => server.accept()) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          outcome.val = if pre_auth {
            @cluster.read_handshake_msg(conn, deadline_ms)
          } else {
            @cluster.read_peer_msg(conn, deadline_ms)
          }
          @net.Conn::close(conn)
        }
      }
    }
    match dial_loopback(port) {
      Err(_) => fail("the listener is bound, so the dial must connect")
      Ok(conn) => {
        match @net.Conn::write_all(conn, outbound) {
          Err(_) => fail("the link is open, so the bytes must be written")
          Ok(_) => ()
        }
        // Silence has to be silence: closing here would hand the reader
        // an end of stream and it would report the close rather than the
        // deadline it is supposed to be waiting on.
        if hold_open_ms > 0 {
          @async.sleep(hold_open_ms)
        }
        @net.Conn::close(conn)
      }
    }
  }
  outcome.val
}

///|
/// A frame whose body is one entry too large for a handshake but
/// perfectly ordinary for replication.
fn oversized_for_handshake() -> Bytes {
  let batch : @cluster.AppendBatch = {
    leader_id: 2U.to_uint16(),
    leader_epoch: 1UL,
    base_seq: 1UL,
    flush_after_append: true,
    entries: [Bytes::makei(40, i => i.to_byte())],
  }
  @cluster.encode_peer_msg(@cluster.PeerMsg::Append(batch))
}

///|
async test "the same frame is refused before the handshake and accepted after it" {
  let frame = oversized_for_handshake()
  // The body is larger than a handshake can carry, so the claim itself
  // is refused: nothing is read and nothing is allocated on the strength
  // of a peer that has not proved which node it is.
  assert_eq(crafted_read(frame, true, 4000), Err(@protocol.BadLength))
  // The identical bytes on an established link are an ordinary
  // replication batch, and they decode.
  match crafted_read(frame, false, 4000) {
    Ok(@cluster.PeerMsg::Append(batch)) => assert_eq(batch.entries.length(), 1)
    _ => fail("an established link must accept an ordinary batch")
  }
}

///|
async test "a frame that stops arriving is given up on at the deadline" {
  // A legal length, a type byte, and then silence: the reader has
  // promised itself more than it will ever be sent.
  let abandoned = b"\x00\x00\x00\x33\x01\x00\x01"
  let deadline_ms = 150
  let started = @env.now()
  let outcome = crafted_read(abandoned, true, deadline_ms, hold_open_ms=600)
  let elapsed = @env.now() - started
  assert_eq(outcome, Err(@protocol.BadLength))
  // It waited, so the read did not succeed behind the deadline's back...
  assert_eq(elapsed >= deadline_ms.to_uint64(), true)
  // ...and it stopped when this call said so rather than at the standing
  // package default, which is what makes the deadline a seam a caller
  // controls.
  assert_eq(elapsed < 4000UL, true)
}

///|
async test "a body larger than one chunk is assembled from several reads" {
  // One entry of seventy kilobytes: the frame body crosses the chunk
  // boundary, so the reader has to loop, and a loop that lost or
  // duplicated a byte would not decode back to the batch that was
  // written.
  let batch : @cluster.AppendBatch = {
    leader_id: 2U.to_uint16(),
    leader_epoch: 1UL,
    base_seq: 1UL,
    flush_after_append: true,
    entries: [Bytes::makei(70000, i => (i % 251).to_byte())],
  }
  let frame = @cluster.encode_peer_msg(@cluster.PeerMsg::Append(batch))
  assert_eq(frame.length() > @cluster.PEER_READ_CHUNK_BYTES + 4, true)
  match crafted_read(frame, false, 8000) {
    Ok(@cluster.PeerMsg::Append(decoded)) => {
      assert_eq(decoded.entries.length(), 1)
      assert_eq(decoded.entries[0].length(), 70000)
      assert_eq(decoded.entries[0][69999], (69999 % 251).to_byte())
    }
    _ => fail("a multi-chunk frame must reassemble")
  }
}

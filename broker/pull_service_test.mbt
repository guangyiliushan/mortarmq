/// Exercise the PULL serving path over the long-poll wait queue: the
/// immediate answers, the parked deadline that returns instead of hanging,
/// the wake path sized to the request bounds, the wait-cap refusal, and the
/// cancel path of a closing connection. Time is passed in as readings, so
/// every deadline boundary is exact and no test sleeps.

///|
fn pull_request(
  subscription_id : UInt16,
  member_id : UInt64,
  wait_ms : UInt16,
  max_msgs : UInt16,
  max_bytes : UInt32,
) -> @protocol.PullPayload {
  {
    subscription_id,
    member_id,
    membership_epoch: 0U,
    assignment_epoch: 0U,
    ownership_epochs: [],
    max_msgs,
    max_bytes,
    wait_ms,
    min_bytes: 0U,
  }
}

///|
fn sample_msg(sequence : UInt64, value : Bytes) -> @protocol.MsgPayload {
  {
    subscription_id: 7,
    topic_id: 1,
    partition: 0,
    sequence,
    delivery_id: sequence + 100UL,
    attempt: 1U.to_uint16(),
    ownership_epoch: 1UL,
    producer_id: 1UL,
    producer_seq: sequence,
    flags: 0U.to_uint16(),
    key: b"",
    value,
  }
}

///|
fn as_parked(serve : @broker.PullServe) -> @broker.PullTicket {
  match serve {
    @broker.PullServe::Parked(ticket) => ticket
    _ => abort("expected the pull to park")
  }
}

///|
test "a parked pull answers ok empty at its five second bound and never hangs" {
  let service = @broker.PullService::new()
  let request = pull_request(7, 1UL, 5000U.to_uint16(), 16U.to_uint16(), 65536U)
  let ticket = as_parked(@broker.PullService::pull(service, request, [], 0UL))
  assert_eq(@broker.PullService::expire(service, 4_999UL), [])
  assert_eq(@broker.PullService::pending_count(service), 1)
  // The deadline returns the ticket at the bound exactly: the request is
  // answered empty and the queue is drained, which is the no-hang half.
  assert_eq(@broker.PullService::expire(service, 5_000UL), [ticket])
  assert_eq(@broker.PullService::pending_count(service), 0)
  assert_eq(@broker.pull_ok([]).length(), 1)
}

///|
test "a zero wait pull with no data answers ok empty at once" {
  let service = @broker.PullService::new()
  let request = pull_request(7, 1UL, 0U.to_uint16(), 16U.to_uint16(), 65536U)
  assert_eq(
    @broker.PullService::pull(service, request, [], 100UL),
    @broker.PullServe::Send(@broker.pull_ok([])),
  )
  assert_eq(@broker.PullService::pending_count(service), 0)
}

///|
test "ready messages answer msg frames then ok within the count bound" {
  let service = @broker.PullService::new()
  let request = pull_request(7, 1UL, 5000U.to_uint16(), 2U.to_uint16(), 65536U)
  let ready = [
    sample_msg(1UL, b"aa"),
    sample_msg(2UL, b"bb"),
    sample_msg(3UL, b"cc"),
  ]
  match @broker.PullService::pull(service, request, ready, 0UL) {
    @broker.PullServe::Send(frames) => {
      assert_eq(frames.length(), 3)
      match frames[0] {
        @protocol.WirePayload::Msg(msg) => assert_eq(msg.sequence, 1UL)
        _ => fail("expected the first frame to be MSG")
      }
      match frames[1] {
        @protocol.WirePayload::Msg(msg) => assert_eq(msg.sequence, 2UL)
        _ => fail("expected the second frame to be MSG")
      }
      match frames[2] {
        @protocol.WirePayload::Ok(_) => assert_eq(true, true)
        _ => fail("expected the closing frame to be OK")
      }
    }
    _ => fail("expected an immediate answer")
  }
  assert_eq(@broker.PullService::pending_count(service), 0)
}

///|
test "the byte bound stops the batch whole" {
  let service = @broker.PullService::new()
  let request = pull_request(7, 1UL, 5000U.to_uint16(), 16U.to_uint16(), 4U)
  let ready = [sample_msg(1UL, b"aaa"), sample_msg(2UL, b"aaa")]
  match @broker.PullService::pull(service, request, ready, 0UL) {
    @broker.PullServe::Send(frames) => {
      assert_eq(frames.length(), 2)
      match frames[0] {
        @protocol.WirePayload::Msg(msg) => assert_eq(msg.sequence, 1UL)
        _ => fail("expected one MSG")
      }
    }
    _ => fail("expected an immediate answer")
  }
}

///|
test "a seventeenth waiting pull is refused with the registered code" {
  let service = @broker.PullService::new()
  let request = pull_request(7, 1UL, 5000U.to_uint16(), 16U.to_uint16(), 65536U)
  for _ in 0..<@broker.MAX_WAITING_PULLS {
    ignore(as_parked(@broker.PullService::pull(service, request, [], 0UL)))
  }
  match @broker.PullService::pull(service, request, [], 0UL) {
    @broker.PullServe::Send(frames) => {
      assert_eq(frames.length(), 1)
      match frames[0] {
        @protocol.WirePayload::Err(err) => {
          assert_eq(err.code, @protocol.MaxWaitingPulls)
          assert_eq(err.request_op, @protocol.Pull)
        }
        _ => fail("expected the refusal frame to be ERR")
      }
    }
    _ => fail("expected the seventeenth pull to be refused")
  }
  assert_eq(@broker.PullService::pending_count(service), 16)
}

///|
test "wake serves the oldest waiter clamped to its own bounds" {
  let service = @broker.PullService::new()
  let wide = pull_request(7, 1UL, 5000U.to_uint16(), 2U.to_uint16(), 65536U)
  let narrow = pull_request(7, 1UL, 5000U.to_uint16(), 1U.to_uint16(), 65536U)
  ignore(as_parked(@broker.PullService::pull(service, wide, [], 0UL)))
  ignore(as_parked(@broker.PullService::pull(service, narrow, [], 0UL)))
  let ready = [
    sample_msg(1UL, b"aa"),
    sample_msg(2UL, b"bb"),
    sample_msg(3UL, b"cc"),
  ]
  match @broker.PullService::wake(service, 7, ready) {
    None => fail("expected the oldest waiter to be served")
    Some(frames) => assert_eq(frames.length(), 3)
  }
  match @broker.PullService::wake(service, 7, ready) {
    None => fail("expected the second waiter to be served")
    Some(frames) => assert_eq(frames.length(), 2)
  }
  assert_eq(@broker.PullService::pending_count(service), 0)
  assert_eq(@broker.PullService::wake(service, 7, ready), None)
}

///|
test "cancel on connection close drops the waiters unanswered" {
  let service = @broker.PullService::new()
  let request = pull_request(7, 1UL, 5000U.to_uint16(), 16U.to_uint16(), 65536U)
  let first = as_parked(@broker.PullService::pull(service, request, [], 0UL))
  let second = as_parked(@broker.PullService::pull(service, request, [], 0UL))
  let other = as_parked(
    @broker.PullService::pull(
      service,
      pull_request(7, 2UL, 5000U.to_uint16(), 16U.to_uint16(), 65536U),
      [],
      0UL,
    ),
  )
  assert_eq(@broker.PullService::cancel(service, 1UL, 7), [first, second])
  assert_eq(@broker.PullService::pending_count(service), 1)
  assert_eq(@broker.PullService::expire(service, 5_000UL), [other])
  assert_eq(@broker.PullService::pending_count(service), 0)
}

///|
test "the deadline answer encodes and decodes as an ok frame" {
  let frames = @broker.pull_ok([])
  match frames[0] {
    @protocol.WirePayload::Ok(payload) => {
      let bytes = match
        @protocol.encode_wire_payload(@protocol.WirePayload::Ok(payload)) {
        Ok(bytes) => bytes
        Err(_) => fail("expected the ok frame to encode")
      }
      match @protocol.decode_wire_payload(@protocol.Op::Ok, bytes) {
        Ok(@protocol.WirePayload::Ok(decoded)) =>
          assert_eq(decoded.request_op, @protocol.Pull)
        _ => fail("expected the frame to decode back to OK")
      }
    }
    _ => fail("expected the lone frame to be OK")
  }
}

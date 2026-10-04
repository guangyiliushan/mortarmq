/// Pin v0 wire frames to literal byte vectors, independent of any encoder.

///|
fn expect_golden_payload(
  data : Bytes,
  op : @protocol.Op,
  expected : @protocol.WirePayload,
) -> Unit raise {
  match @protocol.decode_frame(data[:]) {
    @protocol.Frame(decoded_op, payload) => {
      assert_eq(decoded_op, op)
      match @protocol.decode_wire_payload(decoded_op, payload) {
        Ok(decoded_payload) => assert_eq(decoded_payload, expected)
        Err(code) => fail("golden payload failed with \{code.to_u16()})")
      }
    }
    _ => fail("expected a complete golden frame")
  }
}

///|
test "golden CONNECT frame maps every header and payload field" {
  let frame : Bytes = b"\x00\x00\x00\x0d\x01\x01\x00\x00\x00\x03a\x62\x63\x00\x00\x00\x00"
  expect_golden_payload(
    frame,
    @protocol.Op::Connect,
    @protocol.WirePayload::Connect({
      protocol_version: 1,
      client_flags: 0,
      token: b"abc",
    }),
  )
}

///|
test "golden DECLARE frame maps topic metadata" {
  let frame : Bytes = b"\x00\x00\x00\x08\x02\x00\x01t\x00\x02\x00\x00"
  expect_golden_payload(
    frame,
    @protocol.Op::Declare,
    @protocol.WirePayload::Declare({
      topic: b"t",
      partition_count: 2,
      flags: 0,
    }),
  )
}

///|
test "golden PING frame is the minimum legal frame" {
  let frame : Bytes = b"\x00\x00\x00\x01\x07"
  match @protocol.decode_frame(frame[:]) {
    @protocol.Frame(op, payload) => {
      assert_eq(op, @protocol.Op::Ping)
      assert_eq(payload.length(), 0)
      match @protocol.decode_wire_payload(op, payload) {
        Ok(@protocol.WirePayload::Ping) => assert_eq(true, true)
        _ => fail("expected golden PING payload")
      }
    }
    _ => fail("expected golden PING frame")
  }
}

///|
test "golden MSG frame pins delivery, fencing, producer, and value fields" {
  let frame : Bytes = b"\x00\x00\x00\x43\x0a\x00\x09\x00\x07\x00\x03\x00\x00\x00\x00\x00\x00\x00\x64\x00\x00\x00\x00\x00\x00\x00\xc8\x00\x01\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x06\x00\x00\x00\x03key\x00\x00\x00\x07message"
  expect_golden_payload(
    frame,
    @protocol.Op::Msg,
    @protocol.WirePayload::Msg({
      subscription_id: 9,
      topic_id: 7,
      partition: 3,
      sequence: 100UL,
      delivery_id: 200UL,
      attempt: 1,
      ownership_epoch: 4UL,
      producer_id: 5UL,
      producer_seq: 6UL,
      flags: 0,
      key: b"key",
      value: b"message",
    }),
  )
}

///|
test "golden frame prefixes request the exact number of missing bytes" {
  let empty : Bytes = b""
  match @protocol.decode_frame(empty[:]) {
    @protocol.Need(more) => assert_eq(more, 4)
    _ => fail("expected four missing header bytes")
  }
  let short_prefix : Bytes = b"\x00\x00"
  match @protocol.decode_frame(short_prefix[:]) {
    @protocol.Need(more) => assert_eq(more, 2)
    _ => fail("expected two missing header bytes")
  }
  let truncated_pub : Bytes = b"\x00\x00\x00\x1f\x03\x00\x01\x00\x00\x00\x00\x00\x00\x00\x01"
  match @protocol.decode_frame(truncated_pub[:]) {
    @protocol.Need(more) => assert_eq(more, 20)
    _ => fail("expected exact truncated-body count")
  }
}

///|
test "golden hostile frames reject length and operation faults" {
  let zero_length : Bytes = b"\x00\x00\x00\x00"
  match @protocol.decode_frame(zero_length[:]) {
    @protocol.DecodeError(code) => assert_eq(code, @protocol.BadLength)
    _ => fail("expected zero-length rejection")
  }
  let unknown_op : Bytes = b"\x00\x00\x00\x01\x10"
  match @protocol.decode_frame(unknown_op[:]) {
    @protocol.DecodeError(code) => assert_eq(code, @protocol.UnknownOp)
    _ => fail("expected unknown-operation rejection")
  }
  let oversized_length : Bytes = b"\x01\x00\x00\x01"
  match @protocol.decode_frame(oversized_length[:]) {
    @protocol.DecodeError(code) => assert_eq(code, @protocol.BadLength)
    _ => fail("expected oversized-length rejection")
  }
}

///|
test "golden max-plus-one frame is rejected at the length boundary" {
  let max_plus_one : Bytes = b"\x01\x00\x00\x01"
  match @protocol.decode_frame(max_plus_one[:]) {
    @protocol.DecodeError(code) => assert_eq(code, @protocol.BadLength)
    _ => fail("expected literal MAX_FRAME_LEN + 1 rejection")
  }
}

///|
test "golden exact-maximum frame waits for its full body" {
  let exact_max_prefix : Bytes = b"\x01\x00\x00\x00\x07"
  match @protocol.decode_frame(exact_max_prefix[:]) {
    @protocol.Need(more) =>
      assert_eq(more, @protocol.MAX_FRAME_LEN.reinterpret_as_int() - 1)
    _ => fail("expected exact-maximum frame to wait")
  }
}

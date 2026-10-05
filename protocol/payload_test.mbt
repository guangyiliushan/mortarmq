/// Exercise encode/decode round trips and hostile payload boundaries.

///|
fn expect_roundtrip(
  op : @protocol.Op,
  payload : @protocol.WirePayload,
) -> Unit raise {
  let bytes = match @protocol.encode_wire_payload(payload) {
    Ok(bytes) => bytes
    Err(code) => fail("encoding failed with \{code.to_uint16()})")
  }
  match @protocol.decode_wire_payload(op, bytes[:]) {
    Ok(decoded) => assert_eq(decoded, payload)
    Err(code) => fail("decoding failed with \{code.to_uint16()})")
  }
}

///|
test "core CONNECT payload round-trips" {
  expect_roundtrip(
    @protocol.Op::Connect,
    @protocol.WirePayload::Connect({
      protocol_version: 1,
      client_flags: 0x0003,
      token: b"token",
    }),
  )
}

///|
test "core DECLARE payload round-trips" {
  expect_roundtrip(
    @protocol.Op::Declare,
    @protocol.WirePayload::Declare({
      topic: b"orders",
      partition_count: 4,
      flags: 0,
    }),
  )
}

///|
test "core PUB payload round-trips" {
  expect_roundtrip(
    @protocol.Op::Pub,
    @protocol.WirePayload::Pub({
      topic_id: 7,
      partition: 3,
      producer_id: 0x1122334455667788UL,
      producer_seq: 42UL,
      flags: 1,
      key: b"key-1",
      value: b"hello",
    }),
  )
}

///|
test "core SUB payload round-trips with the v0 wildcard partition" {
  expect_roundtrip(
    @protocol.Op::Sub,
    @protocol.WirePayload::Sub({
      group: b"workers",
      topic_id: 7,
      partition: 0xFFFF,
      start_policy: 0,
      credit_count: 16,
      credit_bytes: 1048576,
      flags: 0,
    }),
  )
}

///|
test "core ACK payload round-trips" {
  expect_roundtrip(
    @protocol.Op::Ack,
    @protocol.WirePayload::Ack({
      subscription_id: 9,
      topic_id: 7,
      partition: 3,
      sequence: 100UL,
      delivery_id: 200UL,
      ownership_epoch: 4UL,
      flags: 0,
    }),
  )
}

///|
test "core NACK payload round-trips" {
  expect_roundtrip(
    @protocol.Op::Nack,
    @protocol.WirePayload::Nack({
      subscription_id: 9,
      topic_id: 7,
      partition: 3,
      sequence: 100UL,
      delivery_id: 200UL,
      ownership_epoch: 4UL,
      reason: 2,
      flags: 0,
    }),
  )
}

///|
test "core PING payload round-trips" {
  expect_roundtrip(@protocol.Op::Ping, @protocol.WirePayload::Ping)
}

///|
test "core ERR payload round-trips" {
  expect_roundtrip(
    @protocol.Op::Err,
    @protocol.WirePayload::Err({
      code: @protocol.InvalidTopic,
      request_op: @protocol.Op::Pub,
      message: b"fix topic name",
    }),
  )
}

///|
test "core OK payload round-trips" {
  expect_roundtrip(
    @protocol.Op::Ok,
    @protocol.WirePayload::Ok({
      request_op: @protocol.Op::Declare,
      result: b"\x00\x07\x00\x04\x00",
    }),
  )
}

///|
test "CONNECT rejects truncation and unsupported versions" {
  match @protocol.decode_wire_payload(@protocol.Op::Connect, b"\x01\x00") {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected truncation failure")
  }
  let unsupported : Bytes = b"\x02\x00\x00\x00\x00\x00\x00\x00\x00"
  match @protocol.decode_wire_payload(@protocol.Op::Connect, unsupported[:]) {
    Err(@protocol.UnsupportedVersion) => assert_eq(true, true)
    _ => fail("expected unsupported version")
  }
}

///|
test "DECLARE rejects trailing bytes" {
  let trailing : Bytes = b"\x00\x01a\x00\x01\x00\x00\xff"
  match @protocol.decode_wire_payload(@protocol.Op::Declare, trailing[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected trailing-byte failure")
  }
}

///|
test "PUB rejects a key above the protocol maximum" {
  let oversized_key = Bytes::makei(256, index => (index % 251).to_byte())
  let payload : @protocol.WirePayload = @protocol.WirePayload::Pub({
    topic_id: 1,
    partition: 0,
    producer_id: 1UL,
    producer_seq: 1UL,
    flags: 0,
    key: oversized_key,
    value: b"value",
  })
  match @protocol.encode_wire_payload(payload) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected oversized-key failure")
  }
}

///|
test "SUB rejects a concrete partition in v0" {
  let payload : Bytes = b"\x00\x01g\x00\x07\x00\x00\x00\x00\x00\x10\x00\x01\x00\x00"
  match @protocol.decode_wire_payload(@protocol.Op::Sub, payload[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected reserved-partition rejection")
  }
}

///|
test "ACK and NACK reject truncated fields" {
  let truncated_ack : Bytes = b"\x00\x09\x00\x07\x00"
  match @protocol.decode_wire_payload(@protocol.Op::Ack, truncated_ack[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected ACK truncation failure")
  }
  let truncated_nack : Bytes = b"\x00\x09\x00\x07\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  match @protocol.decode_wire_payload(@protocol.Op::Nack, truncated_nack[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected NACK truncation failure")
  }
}

///|
test "PING rejects trailing bytes" {
  let trailing : Bytes = b"\x00"
  match @protocol.decode_wire_payload(@protocol.Op::Ping, trailing[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected PING trailing-byte failure")
  }
}

///|
test "ERR accepts the maximum diagnostic boundary" {
  let message = Bytes::makei(@protocol.MAX_ERR_MESSAGE.reinterpret_as_int(), _index => {
    b'a'
  })
  expect_roundtrip(
    @protocol.Op::Err,
    @protocol.WirePayload::Err({
      code: @protocol.Internal,
      request_op: @protocol.Op::Pub,
      message,
    }),
  )
}

///|
test "ERR rejects oversized diagnostics and unknown request ops" {
  let message = Bytes::makei(513, _index => b'a')
  let payload : @protocol.WirePayload = @protocol.WirePayload::Err({
    code: @protocol.Internal,
    request_op: @protocol.Op::Pub,
    message,
  })
  match @protocol.encode_wire_payload(payload) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected oversized-message failure")
  }
  let unknown_request_op : Bytes = b"\x00\x08\x10\x00\x00\x00\x00"
  match
    @protocol.decode_wire_payload(@protocol.Op::Err, unknown_request_op[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected unknown request-op rejection")
  }
}

///|
test "OK rejects trailing bytes" {
  let trailing : Bytes = b"\x02\x00\x00\x00\x01a\xff"
  match @protocol.decode_wire_payload(@protocol.Op::Ok, trailing[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected OK trailing-byte failure")
  }
}

///|
test "CONNECT accepts an empty token and the maximum token length" {
  expect_roundtrip(
    @protocol.Op::Connect,
    @protocol.WirePayload::Connect({
      protocol_version: 1,
      client_flags: 0,
      token: b"",
    }),
  )
  let max_token = Bytes::makei(0xFFFF, _index => b't')
  expect_roundtrip(
    @protocol.Op::Connect,
    @protocol.WirePayload::Connect({
      protocol_version: 1,
      client_flags: 0,
      token: max_token,
    }),
  )
}

///|
test "DECLARE accepts empty and maximum topic lengths" {
  expect_roundtrip(
    @protocol.Op::Declare,
    @protocol.WirePayload::Declare({ topic: b"", partition_count: 1, flags: 0, }),
  )
  let max_topic = Bytes::makei(@protocol.MAX_TOPIC_LEN.reinterpret_as_int(), _index => {
    b'a'
  })
  expect_roundtrip(
    @protocol.Op::Declare,
    @protocol.WirePayload::Declare({
      topic: max_topic,
      partition_count: 1,
      flags: 0,
    }),
  )
}

///|
test "DECLARE rejects a topic above the protocol maximum" {
  let buf = Buffer()
  buf.write_uint16_be(256)
  for _index in 0..<256 {
    buf.write_byte(b'a')
  }
  let bytes = buf.contents()
  match @protocol.decode_wire_payload(@protocol.Op::Declare, bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected oversized topic rejection")
  }
}

///|
test "PUB accepts empty and maximum key lengths" {
  expect_roundtrip(
    @protocol.Op::Pub,
    @protocol.WirePayload::Pub({
      topic_id: 1,
      partition: 0,
      producer_id: 1UL,
      producer_seq: 1UL,
      flags: 0,
      key: b"",
      value: b"",
    }),
  )
  let max_key = Bytes::makei(@protocol.MAX_KEY_LEN.reinterpret_as_int(), _index => {
    b'k'
  })
  expect_roundtrip(
    @protocol.Op::Pub,
    @protocol.WirePayload::Pub({
      topic_id: 1,
      partition: 0,
      producer_id: 1UL,
      producer_seq: 1UL,
      flags: 0,
      key: max_key,
      value: b"",
    }),
  )
}

///|
test "PUB rejects an oversized key before taking bytes" {
  let buf = Buffer()
  buf.write_uint16_be(1)
  buf.write_uint16_be(0)
  buf.write_uint64_be(1UL)
  buf.write_uint64_be(1UL)
  buf.write_uint16_be(0)
  buf.write_uint16_be(256)
  let bytes = buf.contents()
  match @protocol.decode_wire_payload(@protocol.Op::Pub, bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected oversized key rejection")
  }
}

///|
test "PUB rejects the first value length above MAX_VALUE_LEN" {
  let buf = Buffer()
  buf.write_uint16_be(1)
  buf.write_uint16_be(0)
  buf.write_uint64_be(1UL)
  buf.write_uint64_be(1UL)
  buf.write_uint16_be(0)
  buf.write_uint16_be(0)
  buf.write_uint_be(@protocol.MAX_VALUE_LEN + 1U)
  let bytes = buf.contents()
  match @protocol.decode_wire_payload(@protocol.Op::Pub, bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected MAX_VALUE_LEN + 1 rejection")
  }
}

///|
test "PUB rejects value lengths with the high bit set" {
  let buf = Buffer()
  buf.write_uint16_be(1)
  buf.write_uint16_be(0)
  buf.write_uint64_be(1UL)
  buf.write_uint64_be(1UL)
  buf.write_uint16_be(0)
  buf.write_uint16_be(0)
  buf.write_uint_be(0x80000000U)
  let bytes = buf.contents()
  match @protocol.decode_wire_payload(@protocol.Op::Pub, bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected high value-length rejection")
  }
}

///|
test "PUB rejects an oversized value length without materializing it" {
  let buf = Buffer()
  buf.write_uint16_be(1)
  buf.write_uint16_be(0)
  buf.write_uint64_be(1UL)
  buf.write_uint64_be(1UL)
  buf.write_uint16_be(0)
  buf.write_uint16_be(0)
  buf.write_uint_be(0x7FFFFFFFU)
  let bytes = buf.contents()
  match @protocol.decode_wire_payload(@protocol.Op::Pub, bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected integer-window value-length rejection")
  }
}

///|
test "OK rejects an oversized result length without materializing it" {
  let bytes : Bytes = b"\x01\x7f\xff\xff\xff"
  match @protocol.decode_wire_payload(@protocol.Op::Ok, bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected integer-window result-length rejection")
  }
}

///|
test "MSG rejects an empty payload as truncation" {
  match @protocol.decode_wire_payload(@protocol.Op::Msg, b"") {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected MSG truncation rejection")
  }
}

///|
test "ERR rejects an unknown diagnostic code" {
  let unknown_code : Bytes = b"\xff\xff\x01\x00\x00\x00\x00"
  match @protocol.decode_wire_payload(@protocol.Op::Err, unknown_code[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected unknown diagnostic-code rejection")
  }
}

///|
test "core payload codec rejects an operation/payload mismatch" {
  let connect_payload = match
    @protocol.encode_wire_payload(
      @protocol.WirePayload::Connect({
        protocol_version: 1,
        client_flags: 0,
        token: b"",
      }),
    ) {
    Ok(bytes) => bytes
    Err(code) => fail("CONNECT encoding failed with \{code.to_uint16()})")
  }
  match
    @protocol.decode_wire_payload(@protocol.Op::Declare, connect_payload[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected operation/payload mismatch rejection")
  }
}

///|
test "extension MSG payload round-trips" {
  expect_roundtrip(
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
test "extension PULL payload round-trips ownership epochs" {
  expect_roundtrip(
    @protocol.Op::Pull,
    @protocol.WirePayload::Pull({
      subscription_id: 9,
      member_id: 11UL,
      membership_epoch: 2,
      assignment_epoch: 3,
      ownership_epochs: [4UL, 5UL, 6UL],
      max_msgs: 10,
      max_bytes: 65536,
      wait_ms: 250,
      min_bytes: 1,
    }),
  )
}

///|
test "extension HEARTBEAT payload round-trips" {
  expect_roundtrip(
    @protocol.Op::Heartbeat,
    @protocol.WirePayload::Heartbeat({
      subscription_id: 9,
      member_id: 11UL,
      membership_epoch: 2,
      assignment_epoch: 3,
      state: 0,
    }),
  )
}

///|
test "extension NOTICE accepts ASSIGN and REVOKE kinds" {
  expect_roundtrip(
    @protocol.Op::Notice,
    @protocol.WirePayload::Notice({
      notice_id: 1UL,
      kind: 0,
      group_id: 2,
      membership_epoch: 3,
      assignment_epoch: 4,
      ownership_epoch: 5UL,
      topic_id: 6,
      partition: 7,
      member_id: 8UL,
    }),
  )
  expect_roundtrip(
    @protocol.Op::Notice,
    @protocol.WirePayload::Notice({
      notice_id: 1UL,
      kind: 1,
      group_id: 2,
      membership_epoch: 3,
      assignment_epoch: 4,
      ownership_epoch: 5UL,
      topic_id: 6,
      partition: 7,
      member_id: 8UL,
    }),
  )
}

///|
test "extension NOTICE payload round-trips" {
  expect_roundtrip(
    @protocol.Op::Notice,
    @protocol.WirePayload::Notice({
      notice_id: 77UL,
      kind: 1,
      group_id: 2,
      membership_epoch: 3,
      assignment_epoch: 4,
      ownership_epoch: 5UL,
      topic_id: 7,
      partition: 3,
      member_id: 11UL,
    }),
  )
}

///|
test "extension CONTROL_ACK payload round-trips" {
  expect_roundtrip(
    @protocol.Op::ControlAck,
    @protocol.WirePayload::ControlAck({
      notice_id: 77UL,
      notice_kind: 0,
      group_id: 2,
      membership_epoch: 3,
      assignment_epoch: 4,
      ownership_epoch: 5UL,
      result: 2,
    }),
  )
}

///|
test "extension CREDIT payload round-trips" {
  expect_roundtrip(
    @protocol.Op::Credit,
    @protocol.WirePayload::Credit({
      subscription_id: 9,
      membership_epoch: 2,
      ownership_epoch: 5UL,
      mode: 1,
      credit_count: 8,
      credit_bytes: 65536,
    }),
  )
}

///|
test "MSG rejects oversized key and integer-window value length" {
  let buf = Buffer()
  buf.write_uint16_be(9)
  buf.write_uint16_be(7)
  buf.write_uint16_be(3)
  buf.write_uint64_be(1UL)
  buf.write_uint64_be(2UL)
  buf.write_uint16_be(1)
  buf.write_uint64_be(3UL)
  buf.write_uint64_be(4UL)
  buf.write_uint64_be(5UL)
  buf.write_uint16_be(0)
  buf.write_uint16_be(256)
  let bytes = buf.contents()
  match @protocol.decode_wire_payload(@protocol.Op::Msg, bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected oversized MSG key rejection")
  }
  let value_buf = Buffer()
  value_buf.write_uint16_be(9)
  value_buf.write_uint16_be(7)
  value_buf.write_uint16_be(3)
  value_buf.write_uint64_be(1UL)
  value_buf.write_uint64_be(2UL)
  value_buf.write_uint16_be(1)
  value_buf.write_uint64_be(3UL)
  value_buf.write_uint64_be(4UL)
  value_buf.write_uint64_be(5UL)
  value_buf.write_uint16_be(0)
  value_buf.write_uint16_be(0)
  value_buf.write_uint_be(0x7FFFFFFFU)
  let value_bytes = value_buf.contents()
  match @protocol.decode_wire_payload(@protocol.Op::Msg, value_bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected integer-window MSG value rejection")
  }
}

///|
test "PULL rejects trailing bytes" {
  let trailing : Bytes = b"\x00\x09\x00\x00\x00\x00\x00\x00\x00\x0b\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x0a\x00\x01\x00\x00\x00\x00\x00\xfa\x00\x00\x00\x01\xff"
  match @protocol.decode_wire_payload(@protocol.Op::Pull, trailing[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected PULL trailing-byte rejection")
  }
}

///|
test "extension enums reject out-of-range discriminants" {
  let heartbeat : Bytes = b"\x00\x09\x00\x00\x00\x00\x00\x00\x00\x0b\x00\x00\x00\x02\x00\x00\x00\x03\x02"
  match @protocol.decode_wire_payload(@protocol.Op::Heartbeat, heartbeat[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected invalid heartbeat state rejection")
  }
  let notice : Bytes = b"\x00\x00\x00\x00\x00\x00\x00\x4d\x02\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x05\x00\x07\x00\x03\x00\x00\x00\x00\x00\x00\x00\x0b"
  match @protocol.decode_wire_payload(@protocol.Op::Notice, notice[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected invalid notice kind rejection")
  }
  let control : Bytes = b"\x00\x00\x00\x00\x00\x00\x00\x4d\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x05\x03"
  match @protocol.decode_wire_payload(@protocol.Op::ControlAck, control[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected invalid control result rejection")
  }
  let credit : Bytes = b"\x00\x09\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x05\x02\x00\x08\x00\x01\x00\x00\x00\x01"
  match @protocol.decode_wire_payload(@protocol.Op::Credit, credit[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected invalid credit mode rejection")
  }
  let reserved_credit : Bytes = b"\x00\x09\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x08\x00\x01\x00\x00\x00\x01"
  match
    @protocol.decode_wire_payload(@protocol.Op::Credit, reserved_credit[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected nonzero CREDIT reserved rejection")
  }
}

///|
test "MSG golden vector pins every extension field" {
  let expected : Bytes = b"\x00\x09\x00\x07\x00\x03\x00\x00\x00\x00\x00\x00\x00\x64\x00\x00\x00\x00\x00\x00\x00\xc8\x00\x01\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x05\x00\x00\x00\x00\x00\x00\x00\x06\x00\x00\x00\x03key\x00\x00\x00\x07message"
  match @protocol.decode_wire_payload(@protocol.Op::Msg, expected[:]) {
    Ok(@protocol.WirePayload::Msg(msg)) => {
      assert_eq(msg.subscription_id, 9)
      assert_eq(msg.topic_id, 7)
      assert_eq(msg.partition, 3)
      assert_eq(msg.sequence, 100UL)
      assert_eq(msg.delivery_id, 200UL)
      assert_eq(msg.attempt, 1)
      assert_eq(msg.ownership_epoch, 4UL)
      assert_eq(msg.producer_id, 5UL)
      assert_eq(msg.producer_seq, 6UL)
      assert_eq(msg.flags, 0)
      assert_eq(msg.key, b"key")
      assert_eq(msg.value, b"message")
    }
    _ => fail("expected golden MSG to decode")
  }
  match
    @protocol.encode_wire_payload(
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
    ) {
    Ok(bytes) => assert_eq(bytes, expected)
    Err(code) => fail("MSG encoding failed with \{code.to_uint16()})")
  }
}

///|
test "PULL accepts zero ownership epochs and rejects a short epoch array" {
  expect_roundtrip(
    @protocol.Op::Pull,
    @protocol.WirePayload::Pull({
      subscription_id: 9,
      member_id: 11UL,
      membership_epoch: 2,
      assignment_epoch: 3,
      ownership_epochs: [],
      max_msgs: 1,
      max_bytes: 2,
      wait_ms: 3,
      min_bytes: 4,
    }),
  )
  let short_epochs : Bytes = b"\x00\x09\x00\x00\x00\x00\x00\x00\x00\x0b\x00\x00\x00\x02\x00\x00\x00\x03\x00\x03\x00\x00\x00\x00\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x05\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x03\x00\x00\x00\x04"
  match @protocol.decode_wire_payload(@protocol.Op::Pull, short_epochs[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected short ownership-epoch rejection")
  }
}

///|
test "extension payloads accept every valid discriminant" {
  expect_roundtrip(
    @protocol.Op::Heartbeat,
    @protocol.WirePayload::Heartbeat({
      subscription_id: 1,
      member_id: 2UL,
      membership_epoch: 3,
      assignment_epoch: 4,
      state: 1,
    }),
  )
  expect_roundtrip(
    @protocol.Op::Notice,
    @protocol.WirePayload::Notice({
      notice_id: 1UL,
      kind: 1,
      group_id: 2,
      membership_epoch: 3,
      assignment_epoch: 4,
      ownership_epoch: 5UL,
      topic_id: 6,
      partition: 7,
      member_id: 8UL,
    }),
  )
  expect_roundtrip(
    @protocol.Op::ControlAck,
    @protocol.WirePayload::ControlAck({
      notice_id: 1UL,
      notice_kind: 1,
      group_id: 2,
      membership_epoch: 3,
      assignment_epoch: 4,
      ownership_epoch: 5UL,
      result: 0,
    }),
  )
  expect_roundtrip(
    @protocol.Op::ControlAck,
    @protocol.WirePayload::ControlAck({
      notice_id: 1UL,
      notice_kind: 0,
      group_id: 2,
      membership_epoch: 3,
      assignment_epoch: 4,
      ownership_epoch: 5UL,
      result: 1,
    }),
  )
  expect_roundtrip(
    @protocol.Op::Credit,
    @protocol.WirePayload::Credit({
      subscription_id: 1,
      membership_epoch: 2,
      ownership_epoch: 3UL,
      mode: 0,
      credit_count: 4,
      credit_bytes: 5,
    }),
  )
}

///|
test "OK accepts the frame-maximum result length" {
  let result = Bytes::makei(@protocol.MAX_OK_RESULT_LEN.reinterpret_as_int(), _index => {
    b'o'
  })
  expect_roundtrip(
    @protocol.Op::Ok,
    @protocol.WirePayload::Ok({ request_op: @protocol.Op::Declare, result, }),
  )
}

///|
test "OK rejects the first frame-boundary overflow" {
  let buf = Buffer()
  buf.write_byte(@protocol.Op::Declare.to_byte())
  buf.write_uint_be(@protocol.MAX_OK_RESULT_LEN + 1U)
  let bytes = buf.contents()
  match @protocol.decode_wire_payload(@protocol.Op::Ok, bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected OK frame-boundary rejection")
  }
  let result = Bytes::makei(
    @protocol.MAX_OK_RESULT_LEN.reinterpret_as_int() + 1,
    _index => b'o',
  )
  match
    @protocol.encode_wire_payload(
      @protocol.WirePayload::Ok({ request_op: @protocol.Op::Declare, result, }),
    ) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected oversized OK encoding rejection")
  }
}

///|
test "PUB accepts the maximum value length" {
  let value = Bytes::makei(@protocol.MAX_VALUE_LEN.reinterpret_as_int(), _index => {
    b'v'
  })
  expect_roundtrip(
    @protocol.Op::Pub,
    @protocol.WirePayload::Pub({
      topic_id: 1,
      partition: 0,
      producer_id: 1UL,
      producer_seq: 1UL,
      flags: 0,
      key: b"",
      value,
    }),
  )
}

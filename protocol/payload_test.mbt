/// Exercise encode/decode round trips and hostile payload boundaries.

///|
fn expect_roundtrip(
  op : @protocol.Op,
  payload : @protocol.CorePayload,
) -> Unit raise {
  let bytes = match @protocol.encode_core_payload(payload) {
    Ok(bytes) => bytes
    Err(code) => fail("encoding failed with \{code.to_u16()})")
  }
  match @protocol.decode_core_payload(op, bytes[:]) {
    Ok(decoded) => assert_eq(decoded, payload)
    Err(code) => fail("decoding failed with \{code.to_u16()})")
  }
}

///|
test "core CONNECT payload round-trips" {
  expect_roundtrip(
    @protocol.Op::Connect,
    @protocol.CorePayload::Connect({
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
    @protocol.CorePayload::Declare({
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
    @protocol.CorePayload::Pub({
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
    @protocol.CorePayload::Sub({
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
    @protocol.CorePayload::Ack({
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
    @protocol.CorePayload::Nack({
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
  expect_roundtrip(@protocol.Op::Ping, @protocol.CorePayload::Ping)
}

///|
test "core ERR payload round-trips" {
  expect_roundtrip(
    @protocol.Op::Err,
    @protocol.CorePayload::Err({
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
    @protocol.CorePayload::Ok({
      request_op: @protocol.Op::Declare,
      result: b"\x00\x07\x00\x04\x00",
    }),
  )
}

///|
test "CONNECT rejects truncation and unsupported versions" {
  match @protocol.decode_core_payload(@protocol.Op::Connect, b"\x01\x00") {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected truncation failure")
  }
  let unsupported : Bytes = b"\x02\x00\x00\x00\x00\x00\x00\x00\x00"
  match @protocol.decode_core_payload(@protocol.Op::Connect, unsupported[:]) {
    Err(@protocol.UnsupportedVersion) => assert_eq(true, true)
    _ => fail("expected unsupported version")
  }
}

///|
test "DECLARE rejects trailing bytes" {
  let trailing : Bytes = b"\x00\x01a\x00\x01\x00\x00\xff"
  match @protocol.decode_core_payload(@protocol.Op::Declare, trailing[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected trailing-byte failure")
  }
}

///|
test "PUB rejects a key above the protocol maximum" {
  let oversized_key = Bytes::makei(256, index => (index % 251).to_byte())
  let payload : @protocol.CorePayload = @protocol.CorePayload::Pub({
    topic_id: 1,
    partition: 0,
    producer_id: 1UL,
    producer_seq: 1UL,
    flags: 0,
    key: oversized_key,
    value: b"value",
  })
  match @protocol.encode_core_payload(payload) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected oversized-key failure")
  }
}

///|
test "SUB rejects a concrete partition in v0" {
  let payload : Bytes = b"\x00\x01g\x00\x07\x00\x00\x00\x00\x00\x10\x00\x01\x00\x00"
  match @protocol.decode_core_payload(@protocol.Op::Sub, payload[:]) {
    Err(@protocol.UnknownPartition) => assert_eq(true, true)
    _ => fail("expected concrete-partition rejection")
  }
}

///|
test "ACK and NACK reject truncated fields" {
  let truncated_ack : Bytes = b"\x00\x09\x00\x07\x00"
  match @protocol.decode_core_payload(@protocol.Op::Ack, truncated_ack[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected ACK truncation failure")
  }
  let truncated_nack : Bytes = b"\x00\x09\x00\x07\x00\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  match @protocol.decode_core_payload(@protocol.Op::Nack, truncated_nack[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected NACK truncation failure")
  }
}

///|
test "PING rejects trailing bytes" {
  let trailing : Bytes = b"\x00"
  match @protocol.decode_core_payload(@protocol.Op::Ping, trailing[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected PING trailing-byte failure")
  }
}

///|
test "ERR rejects oversized diagnostics and unknown request ops" {
  let message = Bytes::makei(513, _index => b'a')
  let payload : @protocol.CorePayload = @protocol.CorePayload::Err({
    code: @protocol.Internal,
    request_op: @protocol.Op::Pub,
    message,
  })
  match @protocol.encode_core_payload(payload) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected oversized-message failure")
  }
  let unknown_request_op : Bytes = b"\x00\x08\x10\x00\x00\x00\x00"
  match
    @protocol.decode_core_payload(@protocol.Op::Err, unknown_request_op[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected unknown request-op rejection")
  }
}

///|
test "OK rejects trailing bytes" {
  let trailing : Bytes = b"\x02\x00\x00\x00\x01a\xff"
  match @protocol.decode_core_payload(@protocol.Op::Ok, trailing[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected OK trailing-byte failure")
  }
}

///|
test "CONNECT accepts an empty token and the maximum token length" {
  expect_roundtrip(
    @protocol.Op::Connect,
    @protocol.CorePayload::Connect({
      protocol_version: 1,
      client_flags: 0,
      token: b"",
    }),
  )
  let max_token = Bytes::makei(0xFFFF, _index => b't')
  expect_roundtrip(
    @protocol.Op::Connect,
    @protocol.CorePayload::Connect({
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
    @protocol.CorePayload::Declare({ topic: b"", partition_count: 1, flags: 0, }),
  )
  let max_topic = Bytes::makei(@protocol.MAX_TOPIC_LEN.reinterpret_as_int(), _index => {
    b'a'
  })
  expect_roundtrip(
    @protocol.Op::Declare,
    @protocol.CorePayload::Declare({
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
  match @protocol.decode_core_payload(@protocol.Op::Declare, bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected oversized topic rejection")
  }
}

///|
test "PUB accepts empty and maximum key lengths" {
  expect_roundtrip(
    @protocol.Op::Pub,
    @protocol.CorePayload::Pub({
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
    @protocol.CorePayload::Pub({
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
  match @protocol.decode_core_payload(@protocol.Op::Pub, bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected oversized key rejection")
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
  match @protocol.decode_core_payload(@protocol.Op::Pub, bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected integer-window value-length rejection")
  }
}

///|
test "OK rejects an oversized result length without materializing it" {
  let bytes : Bytes = b"\x01\x7f\xff\xff\xff"
  match @protocol.decode_core_payload(@protocol.Op::Ok, bytes[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected integer-window result-length rejection")
  }
}

///|
test "core payload codec rejects extension operations" {
  match @protocol.decode_core_payload(@protocol.Op::Msg, b"") {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected extension-operation rejection")
  }
}

///|
test "ERR rejects an unknown diagnostic code" {
  let unknown_code : Bytes = b"\xff\xff\x01\x00\x00\x00\x00"
  match @protocol.decode_core_payload(@protocol.Op::Err, unknown_code[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected unknown diagnostic-code rejection")
  }
}

///|
test "core payload codec rejects an operation/payload mismatch" {
  let connect_payload = match
    @protocol.encode_core_payload(
      @protocol.CorePayload::Connect({
        protocol_version: 1,
        client_flags: 0,
        token: b"",
      }),
    ) {
    Ok(bytes) => bytes
    Err(code) => fail("CONNECT encoding failed with \{code.to_u16()})")
  }
  match
    @protocol.decode_core_payload(@protocol.Op::Declare, connect_payload[:]) {
    Err(@protocol.MalformedPayload) => assert_eq(true, true)
    _ => fail("expected operation/payload mismatch rejection")
  }
}

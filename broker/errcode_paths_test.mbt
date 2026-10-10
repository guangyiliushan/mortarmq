/// T009 error-code path reconciliation: ten failure paths across the wire
/// chain, each pinned to the exact registry code it lands on (WP-01.08,
/// REQ-PRO-004; exit: every path lands on the 49-code registry).
///
/// The registry body (names, close semantics, client actions) is owned by the
/// signed-off code table; this file only reconciles paths against it. Each
/// test asserts the exact code surfaces at the public boundary and that the
/// code round-trips through `from_uint16(to_uint16(_))`, so a path can never
/// drift onto an unregistered value. Sampled paths and the guidance each
/// code carries in the registry:
///
/// - P1 length prefix of zero -> BadLength 0x0001 (close; fix the client)
/// - P2 op byte 0x00 -> UnknownOp 0x0002 (close; upgrade the client)
/// - P3 trailing byte after an ACK body -> MalformedPayload 0x0003 (close)
/// - P4 CONNECT body read as DECLARE -> MalformedPayload 0x0003 (close)
/// - P5 CONNECT protocol_version 2 -> UnsupportedVersion 0x0004 (close)
/// - P6 SUB partition not 0xFFFF -> MalformedPayload 0x0003 (close)
/// - P7 PUB key of 256 bytes on encode -> MalformedPayload 0x0003 (close)
/// - P8 DECLARE an empty topic name -> InvalidTopic 0x000B (fix the name)
/// - P9 DECLARE same name, new partition count -> TopicExistsMismatch 0x2001
/// - P10 route an undeclared topic -> UnknownTopic 0x0008 (DECLARE first)

///|
/// Assert that a surfaced code is a registered 49-table entry: the registry
/// decodes its own wire value back to the same constructor.
fn assert_registered(code : @protocol.ErrCode) -> Unit raise {
  assert_eq(@protocol.ErrCode::from_uint16(code.to_uint16()), Some(code))
}

///|
/// Build a well-formed ACK body, then append one hostile trailing byte.
fn ack_body_with_trailing_byte() -> Bytes raise {
  let body = match
    @protocol.encode_wire_payload(
      @protocol.WirePayload::Ack({
        subscription_id: 1,
        topic_id: 2,
        partition: 3,
        sequence: 4UL,
        delivery_id: 5UL,
        ownership_epoch: 6UL,
        flags: 0,
      }),
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("ACK body did not encode")
  }
  let buf = Buffer()
  buf.write_bytes(body[:])
  buf.write_byte(b'\x00')
  buf.contents()
}

///|
/// Build a CONNECT body that offers protocol_version 2.
fn connect_body_version_2() -> Bytes {
  let buf = Buffer()
  buf.write_byte(b'\x02')
  buf.write_uint16_be(0)
  buf.write_uint16_be(0)
  buf.write_uint_be(0U)
  buf.contents()
}

///|
/// Build a SUB body whose partition field is 0x0000 instead of 0xFFFF.
fn sub_body_partition_zero() -> Bytes {
  let buf = Buffer()
  buf.write_uint16_be(1)
  buf.write_byte(b'g')
  buf.write_uint16_be(0)
  buf.write_uint16_be(0)
  buf.write_byte(b'\x00')
  buf.write_uint16_be(0)
  buf.write_uint_be(0U)
  buf.write_uint16_be(0)
  buf.contents()
}

///|
test "P1 a zero length prefix lands on BadLength" {
  match @protocol.decode_frame(b"\x00\x00\x00\x00") {
    @protocol.DecodeError(code) => {
      assert_eq(code, @protocol.BadLength)
      assert_registered(code)
    }
    _ => fail("expected BAD_LENGTH at the length field")
  }
}

///|
test "P2 an unknown op byte lands on UnknownOp" {
  match @protocol.decode_frame(b"\x00\x00\x00\x01\x00") {
    @protocol.DecodeError(code) => {
      assert_eq(code, @protocol.UnknownOp)
      assert_registered(code)
    }
    _ => fail("expected UNKNOWN_OP at the op byte")
  }
}

///|
test "P3 a trailing byte after an ACK body lands on MalformedPayload" {
  match
    @protocol.decode_wire_payload(
      @protocol.Op::Ack,
      ack_body_with_trailing_byte()[:],
    ) {
    Err(code) => {
      assert_eq(code, @protocol.MalformedPayload)
      assert_registered(code)
    }
    Ok(_) => fail("expected MALFORMED_PAYLOAD for a trailing byte")
  }
}

///|
test "P4 a CONNECT body read as DECLARE lands on MalformedPayload" {
  let body = match
    @protocol.encode_wire_payload(
      @protocol.WirePayload::Connect({
        protocol_version: 1,
        client_flags: 0,
        token: b"t",
      }),
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("CONNECT body did not encode")
  }
  match @protocol.decode_wire_payload(@protocol.Op::Declare, body[:]) {
    Err(code) => {
      assert_eq(code, @protocol.MalformedPayload)
      assert_registered(code)
    }
    Ok(_) => fail("expected MALFORMED_PAYLOAD for an op/payload mismatch")
  }
}

///|
test "P5 CONNECT offering protocol_version 2 lands on UnsupportedVersion" {
  match
    @protocol.decode_wire_payload(
      @protocol.Op::Connect,
      connect_body_version_2()[:],
    ) {
    Err(code) => {
      assert_eq(code, @protocol.UnsupportedVersion)
      assert_registered(code)
    }
    Ok(_) => fail("expected UNSUPPORTED_VERSION for version 2")
  }
}

///|
test "P6 a SUB partition other than 0xFFFF lands on MalformedPayload" {
  match
    @protocol.decode_wire_payload(
      @protocol.Op::Sub,
      sub_body_partition_zero()[:],
    ) {
    Err(code) => {
      assert_eq(code, @protocol.MalformedPayload)
      assert_registered(code)
    }
    Ok(_) => fail("expected MALFORMED_PAYLOAD for partition not 0xFFFF")
  }
}

///|
test "P7 encoding a PUB key of 256 bytes lands on MalformedPayload" {
  let key = Bytes::makei(256, i => (i % 251).to_byte())
  match
    @protocol.encode_wire_payload(
      @protocol.WirePayload::Pub({
        topic_id: 1,
        partition: 0,
        producer_id: 1UL,
        producer_seq: 1UL,
        flags: 0,
        key: key[:],
        value: b"",
      }),
    ) {
    Err(code) => {
      assert_eq(code, @protocol.MalformedPayload)
      assert_registered(code)
    }
    Ok(_) => fail("expected MALFORMED_PAYLOAD for an oversized key")
  }
}

///|
test "P8 DECLARE of an empty topic name lands on InvalidTopic" {
  let registry = @broker.TopicRegistry::new()
  match @broker.TopicRegistry::declare_topic(registry, b"", 3) {
    Err(code) => {
      assert_eq(code, @protocol.InvalidTopic)
      assert_registered(code)
    }
    Ok(_) => fail("expected INVALID_TOPIC for an empty name")
  }
}

///|
test "P9 DECLARE of the same name with a new count lands on TopicExistsMismatch" {
  let registry = @broker.TopicRegistry::new()
  let _ = @broker.TopicRegistry::declare_topic(registry, b"orders", 3)
  match @broker.TopicRegistry::declare_topic(registry, b"orders", 4) {
    Err(code) => {
      assert_eq(code, @protocol.TopicExistsMismatch)
      assert_registered(code)
    }
    Ok(_) => fail("expected TOPIC_EXISTS_MISMATCH for a changed count")
  }
}

///|
test "P10 routing an undeclared topic lands on UnknownTopic" {
  let registry = @broker.TopicRegistry::new()
  let snapshot = @broker.RoutingSnapshot::from_registry(registry, 1UL)
  match @broker.RoutingSnapshot::route(snapshot, b"missing", b"user-42") {
    Err(code) => {
      assert_eq(code, @protocol.UnknownTopic)
      assert_registered(code)
    }
    Ok(_) => fail("expected UNKNOWN_TOPIC for an undeclared name")
  }
}

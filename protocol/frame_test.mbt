/// Exercise the decoder across empty, short, legal, truncated, and hostile frames.

///|
test "decoder requests four bytes for empty input" {
  let empty : Bytes = b""
  match @protocol.decode_frame(empty[:]) {
    @protocol.Need(more) => assert_eq(more, 4)
    _ => fail("expected Need for empty input")
  }
}

///|
test "decoder requests the exact prefix bytes" {
  let prefix : Bytes = b"\x00\x00"
  match @protocol.decode_frame(prefix[:]) {
    @protocol.Need(more) => assert_eq(more, 2)
    _ => fail("expected Need for a length-prefix prefix")
  }
}

///|
test "decoder rejects a zero length at the header boundary" {
  let zero_length : Bytes = b"\x00\x00\x00\x00"
  match @protocol.decode_frame(zero_length[:]) {
    @protocol.DecodeError(code) => assert_eq(code, @protocol.BadLength)
    _ => fail("expected BAD_LENGTH for length zero")
  }
}

///|
test "decoder accepts the minimum legal frame with an empty payload" {
  let frame : Bytes = b"\x00\x00\x00\x01\x07"
  match @protocol.decode_frame(frame[:]) {
    @protocol.Frame(op, payload) => {
      assert_eq(op, @protocol.Ping)
      assert_eq(payload.length(), 0)
    }
    _ => fail("expected the minimum frame to decode")
  }
}

///|
test "decoder requests the exact remainder of a truncated frame" {
  let truncated : Bytes = b"\x00\x00\x00\x03\x01A"
  match @protocol.decode_frame(truncated[:]) {
    @protocol.Need(more) => assert_eq(more, 1)
    _ => fail("expected an exact truncation request")
  }
}

///|
test "decoder requests the full body for the exact maximum length" {
  let exact_max_prefix : Bytes = b"\x01\x00\x00\x00\x07"
  match @protocol.decode_frame(exact_max_prefix[:]) {
    @protocol.Need(more) =>
      assert_eq(more, @protocol.MAX_FRAME_LEN.reinterpret_as_int() - 1)
    _ => fail("expected Need for the exact maximum frame")
  }
}

///|
test "decoder rejects a length above the protocol maximum" {
  let oversized_length : Bytes = b"\x02\x00\x00\x00"
  match @protocol.decode_frame(oversized_length[:]) {
    @protocol.DecodeError(code) => assert_eq(code, @protocol.BadLength)
    _ => fail("expected BAD_LENGTH above MAX_FRAME_LEN")
  }
}

///|
test "decoder rejects an unknown operation before waiting for its payload" {
  let unknown_op : Bytes = b"\x01\x00\x00\x00\x10"
  match @protocol.decode_frame(unknown_op[:]) {
    @protocol.DecodeError(code) => assert_eq(code, @protocol.UnknownOp)
    _ => fail("expected UNKNOWN_OP after the five-byte header")
  }
}

///|
test "decoder rejects an unknown operation at a complete frame boundary" {
  let unknown_op : Bytes = b"\x00\x00\x00\x01\x10"
  match @protocol.decode_frame(unknown_op[:]) {
    @protocol.DecodeError(code) => assert_eq(code, @protocol.UnknownOp)
    _ => fail("expected UNKNOWN_OP")
  }
}

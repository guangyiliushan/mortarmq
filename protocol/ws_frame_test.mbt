/// Golden, boundary, and property tests for the websocket frame subset.
///
/// The golden vectors are literal hand-built bytes, independent of the
/// encoder. The property test pins its seed and count so a failure
/// reproduces exactly, instead of depending on whichever draw CI happened to
/// get.

///|
/// Copy a borrowed payload into owned bytes so tests can compare content.
fn view_to_bytes(view : BytesView) -> Bytes {
  Bytes::makei(view.length(), i => view[i])
}

///|
/// Build a payload of distinct bytes at the requested length.
fn test_payload(length : Int) -> Bytes {
  Bytes::makei(length, i => (i % 251).to_byte())
}

///|
/// Encode a binary frame, failing the test when the encoder refuses.
fn encoded_frame(payload : BytesView) -> Bytes raise {
  match @protocol.encode_ws_binary_frame(payload) {
    Ok(frame) => frame
    Err(_) => fail("did not encode the test payload")
  }
}

///|
test "golden masked binary frame from a client decodes to its payload" {
  let frame : Bytes = b"\x82\x82\x01\x02\x03\x04\x49\x6b"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Client) {
    @protocol.Message(payload, consumed) => {
      assert_eq(view_to_bytes(payload), b"Hi")
      assert_eq(consumed, 8)
    }
    _ => fail("expected the masked client frame to decode")
  }
}

///|
test "golden unmasked binary frame from a server decodes to its payload" {
  let frame : Bytes = b"\x82\x03\x61\x62\x63"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Server) {
    @protocol.Message(payload, consumed) => {
      assert_eq(view_to_bytes(payload), b"abc")
      assert_eq(consumed, 5)
    }
    _ => fail("expected the unmasked server frame to decode")
  }
}

///|
test "golden fragmented message reassembles three masked client fragments" {
  let frame : Bytes = b"\x02\x82\x01\x02\x03\x04\x49\x67\x00\x84\x05\x06\x07\x08\x69\x6a\x68\x28\x80\x82\x09\x0a\x0b\x0c\x5e\x59"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Client) {
    @protocol.Message(payload, consumed) => {
      assert_eq(view_to_bytes(payload), b"Hello WS")
      assert_eq(consumed, 26)
    }
    _ => fail("expected the fragmented message to reassemble")
  }
}

///|
test "an incomplete fragmented message waits at exact counts without copying" {
  let frag1 : Bytes = b"\x02\x82\x01\x02\x03\x04\x49\x67"
  match @protocol.decode_ws_message(frag1[:], @protocol.WsPeer::Client) {
    @protocol.Need(more) => assert_eq(more, 2)
    _ => fail("expected the first fragment to wait for the next header")
  }
  let frag2_prefix : Bytes = b"\x02\x82\x01\x02\x03\x04\x49\x67\x00\x84\x05"
  match @protocol.decode_ws_message(frag2_prefix[:], @protocol.WsPeer::Client) {
    @protocol.Need(more) => assert_eq(more, 3)
    _ => fail("expected the second fragment to wait for its mask key")
  }
  let frag3_prefix : Bytes = b"\x02\x82\x01\x02\x03\x04\x49\x67\x00\x84\x05\x06\x07\x08\x69\x6a\x68\x28\x80\x82\x09"
  match @protocol.decode_ws_message(frag3_prefix[:], @protocol.WsPeer::Client) {
    @protocol.Need(more) => assert_eq(more, 3)
    _ => fail("expected the final fragment to wait for its mask key")
  }
}

///|
test "a text data frame is refused with unsupported-data" {
  let frame : Bytes = b"\x81\x80\x00\x00\x00\x00"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Client) {
    @protocol.WsError(code) => assert_eq(code, @protocol.UnsupportedData)
    _ => fail("expected the text frame refusal")
  }
}

///|
test "an unmasked client frame is refused as a protocol error" {
  let frame : Bytes = b"\x82\x05hello"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Client) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the unmasked client frame refusal")
  }
}

///|
test "a masked server frame is refused as a protocol error" {
  let frame : Bytes = b"\x82\x80\x00\x00\x00\x00"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Server) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the masked server frame refusal")
  }
}

///|
test "a frame with an rsv bit set is refused before the mask check" {
  let frame : Bytes = b"\xc2\x80\x00\x00\x00\x00"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Client) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the rsv-bit refusal")
  }
}

///|
test "reserved opcodes are refused" {
  let reserved_data : Bytes = b"\x83\x80\x00\x00\x00\x00"
  match
    @protocol.decode_ws_message(reserved_data[:], @protocol.WsPeer::Client) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the reserved data opcode refusal")
  }
  let reserved_control : Bytes = b"\xcb\x80\x00\x00\x00\x00"
  match
    @protocol.decode_ws_message(reserved_control[:], @protocol.WsPeer::Client) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the reserved control opcode refusal")
  }
}

///|
test "ping and pong frames are refused outside the binary-plus-close profile" {
  let ping : Bytes = b"\x89\x80\x00\x00\x00\x00"
  match @protocol.decode_ws_message(ping[:], @protocol.WsPeer::Client) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the ping refusal")
  }
  let pong : Bytes = b"\x8a\x00"
  match @protocol.decode_ws_message(pong[:], @protocol.WsPeer::Server) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the pong refusal")
  }
}

///|
test "a continuation frame without a message is refused" {
  let masked : Bytes = b"\x80\x80\x00\x00\x00\x00"
  match @protocol.decode_ws_message(masked[:], @protocol.WsPeer::Client) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the orphan continuation refusal")
  }
  let unmasked : Bytes = b"\x80\x00"
  match @protocol.decode_ws_message(unmasked[:], @protocol.WsPeer::Server) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the orphan continuation refusal")
  }
}

///|
test "a new data frame inside a fragmented message is refused" {
  let frame : Bytes = b"\x02\x80\x00\x00\x00\x00\x82\x80\x00\x00\x00\x00"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Client) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the interleaved data frame refusal")
  }
}

///|
test "a control frame past 125 bytes is refused before its length form" {
  let frame : Bytes = b"\x88\x7e\x00\x7e"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Server) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the oversized control frame refusal")
  }
}

///|
test "a fragmented message past the message ceiling is refused at the crossing header" {
  // An eight-byte first fragment followed by a final continuation declaring
  // 16 MiB: the sum crosses `MAX_FRAME_LEN + 4` while the second fragment's
  // length form is read, so the refusal needs neither its mask key nor its
  // payload.
  let frame : Bytes = b"\x02\x88\x00\x00\x00\x00abcdefgh\x80\xff\x00\x00\x00\x00\x01\x00\x00\x00"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Client) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the message past the ceiling to be refused")
  }
}

///|
test "a fragmented control frame is refused" {
  let frame : Bytes = b"\x08\x80\x00\x00\x00\x00"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Client) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the fragmented control frame refusal")
  }
}

///|
test "golden close frames encode with their code and no reason" {
  assert_eq(
    @protocol.encode_ws_close_frame(@protocol.NormalClose),
    b"\x88\x02\x03\xe8",
  )
  assert_eq(
    @protocol.encode_ws_close_frame(@protocol.ProtocolError),
    b"\x88\x02\x03\xea",
  )
  assert_eq(
    @protocol.encode_ws_close_frame(@protocol.UnsupportedData),
    b"\x88\x02\x03\xeb",
  )
}

///|
test "a close frame surfaces its code and consumed count" {
  let with_code : Bytes = b"\x88\x02\x03\xe8"
  match @protocol.decode_ws_message(with_code[:], @protocol.WsPeer::Server) {
    @protocol.PeerClose(code, consumed) => {
      assert_eq(code, (1000).to_uint16())
      assert_eq(consumed, 4)
    }
    _ => fail("expected the close frame to surface")
  }
  let without_code : Bytes = b"\x88\x00"
  match @protocol.decode_ws_message(without_code[:], @protocol.WsPeer::Server) {
    @protocol.PeerClose(code, consumed) => {
      assert_eq(code, (1005).to_uint16())
      assert_eq(consumed, 2)
    }
    _ => fail("expected the empty close frame to surface")
  }
}

///|
test "a one-byte close payload is refused" {
  let frame : Bytes = b"\x88\x01\x03"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Server) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the one-byte close payload refusal")
  }
}

///|
test "a close frame inside a fragmented message surfaces immediately" {
  let frame : Bytes = b"\x02\x80\x00\x00\x00\x00\x88\x80\x00\x00\x00\x00"
  match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Client) {
    @protocol.PeerClose(code, consumed) => {
      assert_eq(code, (1005).to_uint16())
      assert_eq(consumed, 12)
    }
    _ => fail("expected the interleaved close frame to surface")
  }
}

///|
test "length forms pick the shortest encoding at their boundaries" {
  let p125 = encoded_frame(test_payload(125)[:])
  assert_eq(view_to_bytes(p125[:2]), b"\x82\x7d")
  let p126 = encoded_frame(test_payload(126)[:])
  assert_eq(view_to_bytes(p126[:4]), b"\x82\x7e\x00\x7e")
  let p65535 = encoded_frame(test_payload(65535)[:])
  assert_eq(view_to_bytes(p65535[:4]), b"\x82\x7e\xff\xff")
  let p65536 = encoded_frame(test_payload(65536)[:])
  assert_eq(
    view_to_bytes(p65536[:10]),
    b"\x82\x7f\x00\x00\x00\x00\x00\x01\x00\x00",
  )
}

///|
test "boundary payloads decode back at their exact consumed counts" {
  for length in [125, 126, 65535, 65536] {
    let frame = encoded_frame(test_payload(length)[:])
    match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Server) {
      @protocol.Message(payload, consumed) => {
        assert_eq(view_to_bytes(payload), test_payload(length))
        assert_eq(consumed, frame.length())
      }
      _ => fail("expected the boundary frame at \{length} to decode")
    }
  }
}

///|
test "non-minimal length encodings are refused" {
  let short_in_16bit : Bytes = b"\x82\x7e\x00\x7d"
  match
    @protocol.decode_ws_message(short_in_16bit[:], @protocol.WsPeer::Server) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the 16-bit form declaring 125 to be refused")
  }
  let small_in_64bit : Bytes = b"\x82\x7f\x00\x00\x00\x00\x00\x00\xff\xff"
  match
    @protocol.decode_ws_message(small_in_64bit[:], @protocol.WsPeer::Server) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the 64-bit form declaring 65535 to be refused")
  }
}

///|
test "the message ceiling waits at the cap and refuses one byte past it" {
  let at_cap : Bytes = b"\x82\x7f\x00\x00\x00\x00\x01\x00\x00\x00"
  match @protocol.decode_ws_message(at_cap[:], @protocol.WsPeer::Server) {
    @protocol.Need(more) => assert_eq(more, 16777216)
    _ => fail("expected the exact-ceiling frame to wait")
  }
  let past_cap : Bytes = b"\x82\x7f\x00\x00\x00\x00\x01\x00\x00\x01"
  match @protocol.decode_ws_message(past_cap[:], @protocol.WsPeer::Server) {
    @protocol.WsError(code) => assert_eq(code, @protocol.ProtocolError)
    _ => fail("expected the past-ceiling frame to be refused")
  }
}

///|
test "truncated frames request the exact number of missing bytes" {
  let empty : Bytes = b""
  match @protocol.decode_ws_message(empty[:], @protocol.WsPeer::Server) {
    @protocol.Need(more) => assert_eq(more, 2)
    _ => fail("expected two missing header bytes")
  }
  let one_byte : Bytes = b"\x82"
  match @protocol.decode_ws_message(one_byte[:], @protocol.WsPeer::Server) {
    @protocol.Need(more) => assert_eq(more, 1)
    _ => fail("expected one missing header byte")
  }
  let missing_mask_key : Bytes = b"\x82\x82"
  match
    @protocol.decode_ws_message(missing_mask_key[:], @protocol.WsPeer::Client) {
    @protocol.Need(more) => assert_eq(more, 4)
    _ => fail("expected four missing mask key bytes")
  }
  let short_16bit : Bytes = b"\x82\x7e\x00"
  match @protocol.decode_ws_message(short_16bit[:], @protocol.WsPeer::Server) {
    @protocol.Need(more) => assert_eq(more, 1)
    _ => fail("expected one missing extended length byte")
  }
  let short_64bit : Bytes = b"\x82\x7f\x00\x00\x00"
  match @protocol.decode_ws_message(short_64bit[:], @protocol.WsPeer::Server) {
    @protocol.Need(more) => assert_eq(more, 5)
    _ => fail("expected five missing extended length bytes")
  }
  let short_payload : Bytes = b"\x82\x05hel"
  match
    @protocol.decode_ws_message(short_payload[:], @protocol.WsPeer::Server) {
    @protocol.Need(more) => assert_eq(more, 2)
    _ => fail("expected two missing payload bytes")
  }
  let short_masked_payload : Bytes = b"\x82\x82\x01\x02\x03\x04\x49"
  match
    @protocol.decode_ws_message(
      short_masked_payload[:],
      @protocol.WsPeer::Client,
    ) {
    @protocol.Need(more) => assert_eq(more, 1)
    _ => fail("expected one missing masked payload byte")
  }
}

///|
test "encode then decode returns the payload (quickcheck seed=20261006 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let length = (draw % 700U).reinterpret_as_int()
      let payload = Bytes::makei(length, i => {
        (draw.reinterpret_as_int() + i).to_byte()
      })
      let encoded = encoded_frame(payload[:])
      match @protocol.decode_ws_message(encoded[:], @protocol.WsPeer::Server) {
        @protocol.Message(view, consumed) =>
          view_to_bytes(view) == payload && consumed == encoded.length()
        _ => false
      }
    },
    count=200,
    seed=20261006,
  )
}

///|
test "every close code encodes and surfaces unchanged (quickcheck seed=20261007 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let code = match draw % 3U {
        0U => @protocol.NormalClose
        1U => @protocol.ProtocolError
        _ => @protocol.UnsupportedData
      }
      let frame = @protocol.encode_ws_close_frame(code)
      match @protocol.decode_ws_message(frame[:], @protocol.WsPeer::Server) {
        @protocol.PeerClose(decoded, consumed) => {
          let expected = match code {
            @protocol.NormalClose => (1000).to_uint16()
            @protocol.ProtocolError => (1002).to_uint16()
            @protocol.UnsupportedData => (1003).to_uint16()
          }
          decoded == expected && consumed == 4
        }
        _ => false
      }
    },
    count=200,
    seed=20261007,
  )
}

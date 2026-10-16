/// Pin the peer frame codec: exact bytes for the envelope, round trips
/// for every message, and a `None` for every malformed shape the strict
/// decoder claims to refuse.

///|
fn nonce_byte(index : Int32) -> Byte {
  (index + 1).to_byte()
}

///|
fn fixture_nonce() -> Bytes {
  Bytes::makei(@cluster.PEER_NONCE_BYTES, nonce_byte)
}

///|
fn fixture_tag(seed : Int32) -> Bytes {
  Bytes::makei(@cluster.PEER_TAG_BYTES, index => (index + seed).to_byte())
}

///|
test "a Hello frame is length, type, id, then the 16-byte nonce" {
  let hello = @cluster.PeerMsg::Hello(
    7U.to_uint16(),
    b"\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22",
  )
  assert_eq(
    @cluster.encode_peer_msg(hello),
    b"\x00\x00\x00\x13\x01\x00\x07\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22\x22",
  )
}

///|
test "every message round-trips through encode and decode" {
  let messages : Array[@cluster.PeerMsg] = [
    @cluster.PeerMsg::Hello(65535U.to_uint16(), fixture_nonce()),
    @cluster.PeerMsg::Challenge(3U.to_uint16(), fixture_nonce(), fixture_tag(0)),
    @cluster.PeerMsg::Proof(1U.to_uint16(), fixture_tag(7)),
    @cluster.PeerMsg::Welcome(2U.to_uint16()),
    @cluster.PeerMsg::Reject(0x6005U.to_uint16()),
  ]
  for message in messages {
    let frame = @cluster.encode_peer_msg(message)
    assert_eq(@cluster.decode_peer_msg(frame[:]), Some(message))
  }
}

///|
test "the length field counts the type byte, matching the client frame" {
  let proof = @cluster.PeerMsg::Proof(1U.to_uint16(), fixture_tag(0))
  let frame = @cluster.encode_peer_msg(proof)
  // 1 type byte + 2 id bytes + 32 tag bytes = 35, big-endian.
  assert_eq(frame[:7], b"\x00\x00\x00\x23\x03\x00\x01")
  assert_eq(frame.length(), 4 + 35)
}

///|
test "an unknown type byte decodes to None" {
  // 0x7f was never assigned to this channel.
  assert_eq(@cluster.decode_peer_msg(b"\x00\x00\x00\x03\x7f\x00\x01"), None)
}

///|
test "a payload of the wrong size for its type decodes to None" {
  // Hello carries exactly two id bytes; one byte short is not a Hello.
  assert_eq(@cluster.decode_peer_msg(b"\x00\x00\x00\x02\x01"), None)
  // And one byte long is not a Hello either.
  assert_eq(@cluster.decode_peer_msg(b"\x00\x00\x00\x04\x01\x00\x01\xff"), None)
}

///|
test "a length field that disagrees with the frame decodes to None" {
  // The length promises three bytes; six follow.
  assert_eq(
    @cluster.decode_peer_msg(b"\x00\x00\x00\x03\x01\x00\x01\x00\x00"),
    None,
  )
  // The length promises nine bytes; three follow.
  assert_eq(@cluster.decode_peer_msg(b"\x00\x00\x00\x09\x01\x00\x01"), None)
}

///|
test "a length below one byte decodes to None" {
  assert_eq(@cluster.decode_peer_msg(b"\x00\x00\x00\x00"), None)
}

///|
test "a frame shorter than the length prefix decodes to None" {
  assert_eq(@cluster.decode_peer_msg(b"\x00\x00"), None)
  assert_eq(@cluster.decode_peer_msg(b""), None)
}

///|
test "a frame whose length exceeds the protocol bound decodes to None" {
  // 0x02000000 is twice MAX_FRAME_LEN and the frame itself is only nine
  // bytes, so the bound rejects it before the size check could.
  assert_eq(
    @cluster.decode_peer_msg(b"\x02\x00\x00\x00\x01\x00\x01\x00\x00"),
    None,
  )
}

///|
test "nonce and tag constants are the sizes the handshake signs over" {
  assert_eq(@cluster.PEER_NONCE_BYTES, 16)
  assert_eq(@cluster.PEER_TAG_BYTES, 32)
  assert_eq(fixture_nonce().length(), @cluster.PEER_NONCE_BYTES)
  assert_eq(fixture_tag(0).length(), @cluster.PEER_TAG_BYTES)
}

///|
/// A hand-built `APPEND` frame whose length claims a twenty-three byte
/// payload -- the fixed prefix alone -- whatever entry count it
/// declares.
///
/// Hand-built rather than encoded, so the decoder's own guard is what
/// answers: an `APPEND` promising five entries inside a payload that
/// ends after the count is malformed by inspection, and encoding it
/// would be asking the encoder to reproduce the very mistake. Bytes are
/// written as numbers rather than literals so the frame's layout stays
/// readable next to the field order it encodes.
fn append_prefix(flush_flag : Byte, entry_count : UInt32) -> Bytes {
  let frame = Buffer()
  // length 0x00000018 = one type byte plus twenty-three payload bytes
  for _ in 0..<3 {
    frame.write_byte((0x00).to_byte())
  }
  frame.write_byte((0x18).to_byte())
  // type 0x06 = APPEND
  frame.write_byte((0x06).to_byte())
  // leader_id = 1
  frame.write_byte((0x00).to_byte())
  frame.write_byte((0x01).to_byte())
  // leader_epoch = 0 and base_seq = 0: sixteen zero bytes
  for _ in 0..<16 {
    frame.write_byte((0x00).to_byte())
  }
  frame.write_byte(flush_flag)
  // entry count, big-endian
  frame.write_byte(((entry_count >> 24) & 0xFFU).reinterpret_as_int().to_byte())
  frame.write_byte(((entry_count >> 16) & 0xFFU).reinterpret_as_int().to_byte())
  frame.write_byte(((entry_count >> 8) & 0xFFU).reinterpret_as_int().to_byte())
  frame.write_byte((entry_count & 0xFFU).reinterpret_as_int().to_byte())
  frame.contents()
}

///|
test "an APPEND round-trips with its entries intact" {
  let batch : @cluster.AppendBatch = {
    leader_id: 1U.to_uint16(),
    leader_epoch: 4UL,
    base_seq: 41UL,
    flush_after_append: true,
    entries: [b"alpha", b"", b"gamma"],
  }
  let frame = @cluster.encode_peer_msg(@cluster.PeerMsg::Append(batch))
  assert_eq(
    @cluster.decode_peer_msg(frame[:]),
    Some(@cluster.PeerMsg::Append(batch)),
  )
}

///|
test "an APPEND_ACK round-trips both positions" {
  let ack : @cluster.AppendAck = {
    follower_id: 3U.to_uint16(),
    leader_epoch: 9UL,
    flushed_seq: 100UL,
    dirty_seq: 120UL,
  }
  let frame = @cluster.encode_peer_msg(@cluster.PeerMsg::Ack(ack))
  assert_eq(
    @cluster.decode_peer_msg(frame[:]),
    Some(@cluster.PeerMsg::Ack(ack)),
  )
}

///|
test "an APPEND whose entry count outruns its payload decodes to None" {
  // Count claims five entries; the payload ends immediately after the
  // count, so there is no way to read even the first length word.
  let over_promise = append_prefix(b'\x01', 5U)
  assert_eq(@cluster.decode_peer_msg(over_promise[:]), None)
}

///|
test "an APPEND whose flush flag is neither zero nor one decodes to None" {
  let bad_flag = append_prefix(b'\x02', 0U)
  assert_eq(@cluster.decode_peer_msg(bad_flag[:]), None)
  // The legal values both decode.
  let asked = append_prefix(b'\x01', 0U)
  match @cluster.decode_peer_msg(asked[:]) {
    Some(@cluster.PeerMsg::Append(batch)) =>
      assert_eq(batch.flush_after_append, true)
    _ => fail("flag 1 must decode as a request to flush")
  }
  let unasked = append_prefix(b'\x00', 0U)
  match @cluster.decode_peer_msg(unasked[:]) {
    Some(@cluster.PeerMsg::Append(batch)) =>
      assert_eq(batch.flush_after_append, false)
    _ => fail("flag 0 must decode as no flush")
  }
}

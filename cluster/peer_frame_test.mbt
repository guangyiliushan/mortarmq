/// Pin the peer frame codec: exact bytes for the envelope, round trips
/// for every message, and a `None` for every malformed shape the strict
/// decoder claims to refuse.

///|
fn nonce_byte(index : Int) -> Byte {
  (index + 1).to_byte()
}

///|
fn fixture_nonce() -> Bytes {
  Bytes::makei(@cluster.PEER_NONCE_BYTES, nonce_byte)
}

///|
fn fixture_tag(seed : Int) -> Bytes {
  Bytes::makei(@cluster.PEER_TAG_BYTES, index => (index + seed).to_byte())
}

///|
test "a Hello frame is four length bytes, one type byte, then the id" {
  let hello = @cluster.PeerMsg::Hello(7U.to_uint16())
  assert_eq(@cluster.encode_peer_msg(hello), b"\x00\x00\x00\x03\x01\x00\x07")
}

///|
test "every message round-trips through encode and decode" {
  let messages : Array[@cluster.PeerMsg] = [
    @cluster.PeerMsg::Hello(65535U.to_uint16()),
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

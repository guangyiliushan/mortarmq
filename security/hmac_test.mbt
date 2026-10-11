/// Pin HMAC-SHA256 against the RFC 4231 outside vectors and the two
/// boundaries that matter for the peer channel: a key at exactly one
/// block (the pad path) and a key longer than one block (the hash-down
/// path). Every expected value below is an outside number, so a broken
/// implementation cannot satisfy any of them by construction.

///|
/// RFC 4231 test case 1: 20-byte key of 0x0b over a short ASCII message.
test "hmac_sha256 matches RFC 4231 case 1" {
  assert_eq(
    @security.digest_hex(
      @security.hmac_sha256(
        b"\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b",
        b"Hi There",
      ),
    ),
    b"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
  )
}

///|
/// RFC 4231 test case 2: short ASCII key over a short ASCII message --
/// the shape the peer secret handshake actually uses.
test "hmac_sha256 matches RFC 4231 case 2" {
  assert_eq(
    @security.digest_hex(
      @security.hmac_sha256(b"Jefe", b"what do ya want for nothing?"),
    ),
    b"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  )
}

///|
/// RFC 4231 test case 4: 25-byte binary key over 50 bytes of 0xcd.
test "hmac_sha256 matches RFC 4231 case 4" {
  assert_eq(
    @security.digest_hex(
      @security.hmac_sha256(
        b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19",
        Bytes::make(50, b'\xcd'),
      ),
    ),
    b"82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
  )
}

///|
/// RFC 4231 test case 6: a 131-byte key, longer than one block, so the
/// key itself is hashed before the pads are built.
test "hmac_sha256 matches RFC 4231 case 6 with an over-block key" {
  assert_eq(
    @security.digest_hex(
      @security.hmac_sha256(
        Bytes::make(131, b'\xaa'),
        b"Test Using Larger Than Block-Size Key - Hash Key First",
      ),
    ),
    b"60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
  )
}

///|
/// RFC 4231 test case 7: an over-block key with an over-block message,
/// so neither side of the construction is a short-input special case.
test "hmac_sha256 matches RFC 4231 case 7 with an over-block message" {
  assert_eq(
    @security.digest_hex(
      @security.hmac_sha256(
        Bytes::make(131, b'\xaa'),
        b"This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.",
      ),
    ),
    b"9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2",
  )
}

///|
/// The pad boundary: a key of exactly one block is padded, never hashed,
/// so it must differ from the same key hashed down by one byte.
test "a key of exactly one block takes the pad path, not the hash path" {
  let at_block = Bytes::make(64, b'\xaa')
  let over_block = Bytes::make(65, b'\xaa')
  let message = b"boundary"
  let padded = @security.hmac_sha256(at_block, message)
  let hashed = @security.hmac_sha256(over_block, message)
  // Both key schedules pin to outside values (cross-checked against an
  // independent HMAC-SHA256 oracle at development time), so the pad path
  // and the hash-down path each bite their key input and neither can
  // silently collapse into the other.
  assert_eq(
    @security.digest_hex(padded),
    b"75eb5ffe3a1f602eab7e09004e78064769aa0eed261e4a3888dfe62d6a945b4e",
  )
  assert_eq(
    @security.digest_hex(hashed),
    b"8667c9376a80b4946a91a671f539eb3769a0928f3ccbf5c819a0b5af61f86d10",
  )
}

///|
/// Empty key and empty message are legal inputs; HMAC still produces a
/// full tag rather than collapsing to a shorter one.
test "hmac_sha256 handles an empty key and an empty message" {
  let tag = @security.hmac_sha256(b"", b"")
  assert_eq(tag.length(), @security.HMAC_DIGEST_BYTES)
  assert_eq(
    @security.digest_hex(tag),
    b"b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad",
  )
  assert_eq(
    @security.hmac_sha256(b"k", b"").length(),
    @security.HMAC_DIGEST_BYTES,
  )
}

///|
/// The tag is a function of the key: the same message under two keys
/// must not collide, which is what stops a peer from forging a proof
/// with a key it does not hold.
test "hmac_sha256 separates messages that differ only by key" {
  let message = b"mortarmq-peer-v1"
  let left = @security.hmac_sha256(b"secret-one", message)
  let right = @security.hmac_sha256(b"secret-two", message)
  assert_eq(left == right, false)
}

/// Known-answer tests for the shared SHA-256 one-shot digest (FIPS 180-4).
///
/// Vector provenance: the RFC 6234 `hashes` table SHA256 rows whose
/// `extrabits` is zero — the byte-oriented cases of the reference driver —
/// plus padding-boundary lengths cross-checked against an independent
/// oracle (Python hashlib) at development time. The extrabits rows (5/7/9)
/// exercise a bit-padding API this package deliberately does not expose and
/// are out of scope for the frozen Bytes surface.

///|
/// Check one vector: `input` must hash to `expected_hex` (64 lowercase bytes).
fn check_hex(input : Bytes, expected_hex : Bytes) -> Unit raise {
  assert_eq(@security.sha256_hex(input[:]), expected_hex)
}

///|
test "sha256 matches RFC 6234 TEST1: \"abc\"" {
  check_hex(
    b"abc", b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
}

///|
test "sha256 matches RFC 6234 TEST2_1: 56-byte two-block message" {
  check_hex(
    b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", b"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
  )
}

///|
test "sha256 matches RFC 6234 TEST3: one million \"a\" bytes" {
  check_hex(
    Bytes::makei(1000000, _ => b'a'),
    b"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0",
  )
}

///|
test "sha256 matches RFC 6234 TEST4: 64-byte block repeated ten times" {
  let base : Bytes = b"0123456701234567012345670123456701234567012345670123456701234567"
  let mut message = b""
  for _ in 0..<10 {
    message = message + base
  }
  check_hex(
    message, b"594847328451bdfa85056225462cc1d867d877fb388df0ce35f25ab5562bfbb5",
  )
}

///|
test "sha256 matches RFC 6234 TEST6: single byte 0x19" {
  check_hex(
    b"\x19", b"68aa2e2ee5dff96e3355e6c7ee373e3d6a4e17f75f9518d843709c0c9bc3e3d4",
  )
}

///|
test "sha256 matches RFC 6234 TEST8: 16-byte message" {
  check_hex(
    b"\xe3\xd7\x25\x70\xdc\xdd\x78\x7c\xe3\x88\x7a\xb2\xcd\x68\x46\x52", b"175ee69b02ba9b58e2b0a5fd13819cea573f3940a94f825128cf4209beabb4e8",
  )
}

///|
test "sha256 matches RFC 6234 TEST10: 163-byte message" {
  check_hex(
    b"\x83\x26\x75\x4e\x22\x77\x37\x2f\x4f\xc1\x2b\x20\x52\x7a\xfe\xf0" +
    b"\x4d\x8a\x05\x69\x71\xb1\x1a\xd5\x71\x23\xa7\xc1\x37\x76\x00\x00" +
    b"\xd7\xbe\xf6\xf3\xc1\xf7\xa9\x08\x3a\xa3\x9d\x81\x0d\xb3\x10\x77" +
    b"\x7d\xab\x8b\x1e\x7f\x02\xb8\x4a\x26\xc7\x73\x32\x5f\x8b\x23\x74" +
    b"\xde\x7a\x4b\x5a\x58\xcb\x5c\x5c\xf3\x5b\xce\xe6\xfb\x94\x6e\x5b" +
    b"\xd6\x94\xfa\x59\x3a\x8b\xeb\x3f\x9d\x65\x92\xec\xed\xaa\x66\xca" +
    b"\x82\xa2\x9d\x0c\x51\xbc\xf9\x33\x62\x30\xe5\xd7\x84\xe4\xc0\xa4" +
    b"\x3f\x8d\x79\xa3\x0a\x16\x5c\xba\xbe\x45\x2b\x77\x4b\x9c\x71\x09" +
    b"\xa9\x7d\x13\x8f\x12\x92\x28\x96\x6f\x6c\x0a\xdc\x10\x6a\xad\x5a" +
    b"\x9f\xdd\x30\x82\x57\x69\xb2\xc6\x71\xaf\x67\x59\xdf\x28\xeb\x39" +
    b"\x3d\x54\xd6",
    b"97dbca7df46d62c8a422c941dd7e835b8ad3361763f7e9b2d95f4f0da6e1ccbc",
  )
}

///|
test "sha256 matches the length-0 boundary: empty message" {
  check_hex(
    b"", b"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
}

///|
test "sha256 matches the length-55 padding boundary" {
  // 55 message bytes leave room for 0x80 and the length word in one block.
  check_hex(
    Bytes::makei(55, _ => b'a'),
    b"9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
  )
}

///|
test "sha256 matches the length-56 padding boundary" {
  // 56 message bytes push 0x80 into a second block.
  check_hex(
    Bytes::makei(56, _ => b'a'),
    b"b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
  )
}

///|
test "sha256 matches the length-63 padding boundary" {
  check_hex(
    Bytes::makei(63, _ => b'a'),
    b"7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
  )
}

///|
test "sha256 matches the length-64 padding boundary" {
  // Exactly one full block; the padding lands in a fresh block.
  check_hex(
    Bytes::makei(64, _ => b'a'),
    b"ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
  )
}

///|
test "sha256 matches the length-65 padding boundary" {
  check_hex(
    Bytes::makei(65, _ => b'a'),
    b"635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
  )
}

///|
test "sha256_hex is the lowercase hex of sha256" {
  let digest = @security.sha256(b"abc")
  assert_eq(digest.length(), 32)
  assert_eq(@security.sha256_hex(b"abc"[:]), @security.digest_hex(digest))
}

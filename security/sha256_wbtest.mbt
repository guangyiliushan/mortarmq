/// Incremental-update tests for the shared SHA-256 engine (whitebox).
///
/// The one-shot wrapper must equal arbitrary chunked `update` schedules.
/// The two-chunk split is the RFC 6234 TEST2_2 message (TEST2_2a then
/// TEST2_2b); its digest is cross-checked against an independent oracle
/// (Python hashlib) at development time.

///|
/// RFC 6234 TEST2_2a.
let test2_2a : Bytes = b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmn"

///|
/// RFC 6234 TEST2_2b.
let test2_2b : Bytes = b"hijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"

///|
test "incremental updates match one-shot across the RFC 6234 TEST2_2 split" {
  let hasher = Sha256::new()
  hasher.update(test2_2a[:])
  hasher.update(test2_2b[:])
  assert_eq(
    hasher.digest(),
    b"\xcf\x5b\x16\xa7\x78\xaf\x83\x80\x03\x6c\xe5\x9e\x7b\x04\x92\x37" +
    b"\x0b\x24\x9b\x11\xe8\xf0\x7a\x51\xaf\xac\x45\x03\x7a\xfe\xe9\xd1",
  )
  assert_eq(hasher.digest(), sha256((test2_2a + test2_2b)[:]))
}

///|
test "byte-at-a-time updates match one-shot on the RFC 6234 TEST2_1 message" {
  let message : Bytes = b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
  let hasher = Sha256::new()
  for index in 0..<message.length() {
    hasher.update(message[index:index + 1])
  }
  assert_eq(hasher.digest(), sha256(message[:]))
}

///|
test "chunked updates match one-shot across the length-65 boundary" {
  let message = Bytes::makei(65, _ => b'a')
  let hasher = Sha256::new()
  hasher.update(message[0:1])
  hasher.update(message[1:29])
  hasher.update(message[29:65])
  assert_eq(
    hasher.digest(),
    b"\x63\x53\x61\xc4\x8b\xb9\xea\xb1\x41\x98\xe7\x6e\xa8\xab\x7f\x1a" +
    b"\x41\x68\x5d\x6a\xd6\x2a\xa9\x14\x6d\x30\x1d\x4f\x17\xeb\x0a\xe0",
  )
}

///|
test "empty updates are a no-op" {
  let hasher = Sha256::new()
  hasher.update(b"")
  hasher.update(b"ab"[:])
  hasher.update(b"")
  hasher.update(b"c"[:])
  assert_eq(hasher.digest(), sha256(b"abc"[:]))
}

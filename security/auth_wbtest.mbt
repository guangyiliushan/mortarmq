/// Whitebox tests for the constant-time digest comparison (CWE-208).
///
/// `digest_eq` is the single place where two digests are compared. Its
/// contract: equal digests decide true, any content difference decides
/// false, and the decision happens only after every byte pair has been
/// folded into one accumulator — the Go crypto/subtle form.

///|
/// A 32-byte digest pattern that is easy to flip bits in.
fn probe_digest(fill : Byte) -> Bytes {
  Bytes::makei(32, _ => fill)
}

///|
/// `original` with byte `index` replaced by `value`.
fn with_byte(original : Bytes, index : Int, value : Byte) -> Bytes {
  original[0:index].to_owned() +
  Bytes::make(1, value) +
  original[index + 1:].to_owned()
}

///|
test "digest_eq holds for identical digests" {
  assert_eq(digest_eq(probe_digest(b'\x00'), probe_digest(b'\x00')), true)
  assert_eq(digest_eq(probe_digest(b'\xa5'), probe_digest(b'\xa5')), true)
}

///|
test "digest_eq rejects a first-byte difference" {
  let a = probe_digest(b'\x00')
  let b = with_byte(a, 0, b'\x01')
  assert_eq(digest_eq(a, b), false)
}

///|
test "digest_eq rejects a last-byte difference" {
  let a = probe_digest(b'\x00')
  let b = with_byte(a, 31, b'\x80')
  assert_eq(digest_eq(a, b), false)
}

///|
test "digest_eq rejects a single-bit difference anywhere in the middle" {
  let a = probe_digest(b'\xff')
  let b = with_byte(a, 15, b'\x7f')
  assert_eq(digest_eq(a, b), false)
}

///|
test "digest_eq rejects operands that are not exactly 32 bytes" {
  let digest = probe_digest(b'\x00')
  assert_eq(digest_eq(b"short", digest), false)
  assert_eq(digest_eq(digest, b"short"), false)
  assert_eq(digest_eq(Bytes::makei(33, _ => b'\x00'), digest), false)
}

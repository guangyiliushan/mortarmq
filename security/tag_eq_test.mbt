/// Export-surface tests for the constant-time equality of 32-byte secret
/// material (CWE-208).
///
/// `tag_eq` is the one comparison point for secret-derived 32-byte values:
/// HMAC-SHA256 peer tags and token digests both verify through it. Its
/// contract: equal operands decide true, any content difference decides
/// false, and the decision happens only after every byte pair has been
/// folded into one accumulator -- the Go crypto/subtle form. Length is not
/// secret and is checked first; the content loop never exits early.

///|
/// A 32-byte pattern that is easy to flip bits in.
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
test "tag_eq holds for identical digests" {
  assert_eq(
    @security.tag_eq(probe_digest(b'\x00')[:], probe_digest(b'\x00')[:]),
    true,
  )
  assert_eq(
    @security.tag_eq(probe_digest(b'\xa5')[:], probe_digest(b'\xa5')[:]),
    true,
  )
}

///|
test "tag_eq rejects a first-byte difference" {
  let a = probe_digest(b'\x00')
  let b = with_byte(a, 0, b'\x01')
  assert_eq(@security.tag_eq(a[:], b[:]), false)
}

///|
test "tag_eq rejects a last-byte difference" {
  let a = probe_digest(b'\x00')
  let b = with_byte(a, 31, b'\x80')
  assert_eq(@security.tag_eq(a[:], b[:]), false)
}

///|
test "tag_eq rejects a single-bit difference anywhere in the middle" {
  let a = probe_digest(b'\xff')
  let b = with_byte(a, 15, b'\x7f')
  assert_eq(@security.tag_eq(a[:], b[:]), false)
}

///|
test "tag_eq rejects operands that are not exactly 32 bytes" {
  let digest = probe_digest(b'\x00')
  assert_eq(@security.tag_eq(b"short"[:], digest[:]), false)
  assert_eq(@security.tag_eq(digest[:], b"short"[:]), false)
  assert_eq(
    @security.tag_eq(Bytes::makei(33, _ => b'\x00')[:], digest[:]),
    false,
  )
}

///|
test "tag_eq accepts borrowed views of larger buffers" {
  // The peer handshake compares tags inside frame buffers: the operands
  // arrive as slices, not as freshly owned digests.
  let left : Bytes = b"aaaa-0123456789012345678901234567-aaaa"
  let right : Bytes = b"bbbb-0123456789012345678901234568-bbbb"
  assert_eq(@security.tag_eq(left[5:37], left[5:37]), true)
  assert_eq(@security.tag_eq(left[5:37], right[5:37]), false)
}

/// Tests for the `hash-token` developer tool.
///
/// The tool is the generation half of the tokens-file path: it renders
/// `digest<TAB>role` for a token so the plaintext never reaches the file,
/// and the verifier recomputes the same digest through the same shared
/// SHA-256 implementation. "生成路径可复制" is pinned by the exact-output
/// test below.

///|
/// Whether `needle` occurs in `haystack`.
fn contains(haystack : BytesView, needle : BytesView) -> Bool {
  if needle.length() == 0 || needle.length() > haystack.length() {
    return false
  }
  for start in 0..<(haystack.length() - needle.length() + 1) {
    let mut matches = true
    for offset in 0..<needle.length() {
      if haystack[start + offset] != needle[offset] {
        matches = false
      }
    }
    if matches {
      return true
    }
  }
  false
}

///|
test "hash-token generation path is reproducible (RFC 6234 TEST1 anchor)" {
  assert_eq(
    @tools.hash_token(b"abc"[:], b"admin"),
    Ok(
      b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" +
      b"\t" +
      b"admin",
    ),
  )
}

///|
test "hash-token output never contains the token plaintext" {
  let token : Bytes = b"correct-horse-battery-staple"
  match @tools.hash_token(token[:], b"writer") {
    Ok(line) => {
      assert_eq(contains(line[:], token[:]), false)
      assert_eq(contains(line[:], b"correct"), false)
    }
    Err(_) => fail("hash-token must accept a valid role")
  }
}

///|
test "hash-token rejects invalid roles" {
  assert_eq(@tools.hash_token(b"abc"[:], b""), Err(@security.BadRole))
  assert_eq(@tools.hash_token(b"abc"[:], b"has space"), Err(@security.BadRole))
}

///|
test "hash-token output round-trips through parse_tokens" {
  let digest = @security.sha256(b"correct-horse-battery-staple")
  match @tools.hash_token(b"correct-horse-battery-staple"[:], b"writer") {
    Ok(line) => {
      let store = @security.parse_tokens((line + b"\n")[:])
      assert_eq(store.entries.length(), 1)
      assert_eq(store.entries[0].digest, digest)
      assert_eq(store.entries[0].role, b"writer")
    }
    Err(_) => fail("hash-token must accept a valid role")
  }
}

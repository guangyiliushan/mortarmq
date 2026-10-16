/// Tests for the frozen tokens-file format: one entry per
/// line, `digest<TAB>role`, where `digest` is 64 lowercase hex bytes of the
/// token's SHA-256 and `role` is a non-empty printable-ASCII name. The
/// token plaintext never appears in the file. Malformed lines are treated
/// as if the entry did not exist: they are skipped, never
/// reported with detail.

///|
test "token_line renders digest<TAB>role exactly" {
  let digest = @security.sha256(b"abc")
  assert_eq(
    @security.token_line(digest, b"admin"),
    Ok(
      b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" +
      b"\t" +
      b"admin",
    ),
  )
}

///|
test "token_line rejects a digest that is not 32 bytes" {
  assert_eq(@security.token_line(b"short", b"admin"), Err(@security.BadDigest))
  let long = Bytes::makei(33, _ => b'\x00')
  assert_eq(@security.token_line(long, b"admin"), Err(@security.BadDigest))
}

///|
test "token_line rejects empty and unprintable roles" {
  let digest = @security.sha256(b"abc")
  assert_eq(@security.token_line(digest, b""), Err(@security.BadRole))
  assert_eq(@security.token_line(digest, b"has space"), Err(@security.BadRole))
  assert_eq(@security.token_line(digest, b"tab\there"), Err(@security.BadRole))
  assert_eq(@security.token_line(digest, b"nl\nhere"), Err(@security.BadRole))
}

///|
test "parse_tokens reads well-formed entries in order" {
  let line1 = b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\tadmin"
  let line2 = b"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\tclient"
  let store = match @security.parse_tokens((line1 + b"\n" + line2 + b"\n")[:]) {
    Some(store) => store
    None => fail("the two-entry store must parse")
  }
  assert_eq(store.entries.length(), 2)
  assert_eq(store.entries[0].role, b"admin")
  assert_eq(store.entries[0].digest, @security.sha256(b"abc"))
  assert_eq(store.entries[1].role, b"client")
}

///|
test "parse_tokens refuses a repeated digest whole" {
  let line = b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\tadmin"
  let again = b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\twriter"
  assert_eq(
    @security.parse_tokens((line + b"\n" + again + b"\n")[:]) is None,
    true,
  )
}

///|
test "parse_tokens treats malformed lines as absent entries" {
  let good = b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\tadmin"
  let bad_hex = b"zz7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\trole1"
  let upper_hex = b"BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD\trole2"
  let short_hex = b"ba7816bf\trole3"
  let no_tab = b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  let bad_role = b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\tbad role"
  let text = good +
    b"\n" +
    bad_hex +
    b"\n\n" +
    upper_hex +
    b"\n" +
    short_hex +
    b"\n" +
    no_tab +
    b"\n" +
    bad_role +
    b"\n"
  let store = match @security.parse_tokens(text[:]) {
    Some(store) => store
    None => fail("the malformed-line store must parse")
  }
  assert_eq(store.entries.length(), 1)
  assert_eq(store.entries[0].role, b"admin")
}

///|
test "parse_tokens tolerates CRLF line endings" {
  let line1 = b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\tadmin"
  let line2 = b"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\tclient"
  let store = match
    @security.parse_tokens((line1 + b"\r\n" + line2 + b"\r\n")[:]) {
    Some(store) => store
    None => fail("the CRLF store must parse")
  }
  assert_eq(store.entries.length(), 2)
  assert_eq(store.entries[0].role, b"admin")
}

///|
test "token_line output parses back to the same entry" {
  let digest = @security.sha256(b"correct-horse-battery-staple")
  let line = @security.token_line(digest, b"writer")
  let store = match line {
    Ok(text) =>
      match @security.parse_tokens((text + b"\n")[:]) {
        Some(store) => store
        None => fail("the token_line store must parse")
      }
    Err(_) => abort("token_line must accept a valid role")
  }
  assert_eq(store.entries.length(), 1)
  assert_eq(store.entries[0].digest, digest)
  assert_eq(store.entries[0].role, b"writer")
}

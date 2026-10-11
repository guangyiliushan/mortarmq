/// Tests for the admin-face bind policy (the admin HTTP surface must
/// live on the loopback face only).
///
/// Two contracts pin the face down: the effective bind is loopback --
/// 127.0.0.1 by default, or a configured loopback literal -- and every
/// non-loopback value is refused with a distinct error a CLI can map to
/// its own exit code. The connection side of the same rule is the
/// `is_loopback` admission check: the admin accept path refuses any peer
/// whose address is not loopback, so a connection whose address is not
/// on the loopback face is rejected before it can reach an endpoint.

///|
test "the default admin bind is the loopback literal" {
  assert_eq(@security.admin_bind(b""), Ok(b"127.0.0.1"))
}

///|
test "an explicit loopback literal is accepted as-is" {
  assert_eq(@security.admin_bind(b"127.0.0.1"), Ok(b"127.0.0.1"))
  assert_eq(@security.admin_bind(b"127.0.0.2"), Ok(b"127.0.0.2"))
  assert_eq(@security.admin_bind(b"::1"), Ok(b"::1"))
}

///|
test "a non-loopback bind target is refused" {
  assert_eq(@security.admin_bind(b"0.0.0.0"), Err(@security.NonLoopback))
  assert_eq(@security.admin_bind(b"192.168.1.10"), Err(@security.NonLoopback))
  assert_eq(@security.admin_bind(b"10.0.0.1"), Err(@security.NonLoopback))
  assert_eq(@security.admin_bind(b"::"), Err(@security.NonLoopback))
  assert_eq(@security.admin_bind(b"2001:db8::1"), Err(@security.NonLoopback))
}

///|
test "a hostname or malformed value is refused as malformed" {
  // Resolution is a transport concern and a poisoned resolver could
  // point a name anywhere, so the admin face accepts literals only.
  assert_eq(@security.admin_bind(b"localhost"), Err(@security.Malformed))
  assert_eq(@security.admin_bind(b"256.0.0.1"), Err(@security.Malformed))
  assert_eq(@security.admin_bind(b"127.0.0"), Err(@security.Malformed))
  assert_eq(@security.admin_bind(b" 127.0.0.1"), Err(@security.Malformed))
}

///|
test "the connection-side admission check rejects non-loopback peers" {
  assert_eq(@security.is_loopback(b"127.0.0.1"), true)
  assert_eq(@security.is_loopback(b"127.255.255.254"), true)
  assert_eq(@security.is_loopback(b"::1"), true)
  assert_eq(@security.is_loopback(b"192.168.1.10"), false)
  assert_eq(@security.is_loopback(b"0.0.0.0"), false)
  assert_eq(@security.is_loopback(b"10.1.2.3"), false)
  assert_eq(@security.is_loopback(b"localhost"), false)
}

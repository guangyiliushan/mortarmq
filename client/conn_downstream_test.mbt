/// Prove the transport trait is dependable from a downstream package.
///
/// This file is the compile-time use case for depending on `@net.Conn`
/// without any transport: this package, which sits outside the broker stack,
/// implements the trait for its own private scripted type and drives it both
/// generically and as a trait object. No socket is opened.

///|
// A scripted connection: reads replay `inbox` from the front, writes append
// to `outbox`, and `closed` records the close call.
struct ScriptedConn {
  mut inbox : Bytes
  outbox : Buffer
  mut closed : Bool
}

///|
impl @net.Conn for ScriptedConn with fn read_exact(self, len : Int) -> Result[
  Bytes,
  @protocol.ErrCode,
] {
  if len > self.inbox.length() {
    return Err(@protocol.Internal)
  }
  let served = self.inbox[:len].to_owned()
  self.inbox = self.inbox[len:].to_owned()
  Ok(served)
}

///|
impl @net.Conn for ScriptedConn with fn write_all(self, data : Bytes) -> Result[
  Unit,
  @protocol.ErrCode,
] {
  self.outbox.write_bytes(data)
  Ok(())
}

///|
impl @net.Conn for ScriptedConn with fn close(self) -> Unit {
  self.closed = true
}

///|
// One request-reply exchange driven generically over any connection
// implementation; this is the static-dispatch shape the session layer copies.
async fn[T : @net.Conn] exchange(
  conn : T,
  request : Bytes,
  reply_len : Int,
) -> Result[Bytes, @protocol.ErrCode] {
  match @net.Conn::write_all(conn, request) {
    Err(code) => return Err(code)
    Ok(_) => ()
  }
  @net.Conn::read_exact(conn, reply_len)
}

///|
async test "downstream package implements and drives the Conn trait" {
  let scripted : ScriptedConn = {
    inbox: b"pongpong",
    outbox: Buffer(),
    closed: false,
  }
  assert_eq(exchange(scripted, b"ping", 4), Ok(b"pong"))
  assert_eq(scripted.outbox.contents(), b"ping")
  let conn : &@net.Conn = scripted
  match @net.Conn::read_exact(conn, 5) {
    Err(@protocol.Internal) => ()
    _ => fail("a read past the scripted stream must fail whole")
  }
  @net.Conn::close(scripted)
  assert_true(scripted.closed)
}

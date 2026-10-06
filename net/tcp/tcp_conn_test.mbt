/// Drive the native TCP transport over real loopback sockets.
///
/// Each test binds an ephemeral 127.0.0.1 port, accepts once in a background
/// task, and talks to it through `TcpConn`; the client side is the code under
/// test. These tests run only on the targets where the underlying socket
/// package supports TCP.

///|
async test "TcpConn exchanges bytes in both directions over loopback" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      let (tcp, _) = server.accept()
      defer tcp.close()
      @io.Writer::write(tcp, @io.Reader::read_exactly(tcp, 5))
    }
    let conn : @tcp.TcpConn = match @tcp.TcpConn::connect("127.0.0.1", port) {
      Ok(conn) => conn
      Err(_) => fail("loopback connect must not fail")
    }
    assert_eq(@net.Conn::write_all(conn, b"hello"), Ok(()))
    assert_eq(@net.Conn::read_exact(conn, 5), Ok(b"hello"))
    @net.Conn::close(conn)
  }
}

///|
async test "TcpConn connect to a closed port reports the transport failure code" {
  match @tcp.TcpConn::connect("127.0.0.1", 1) {
    Err(@protocol.Internal) => ()
    _ =>
      fail(
        "connect to a closed loopback port must report the transport failure code",
      )
  }
}

///|
async test "TcpConn read past a peer close reports the transport failure code" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      let (tcp, _) = server.accept()
      tcp.close()
    }
    let conn : @tcp.TcpConn = match @tcp.TcpConn::connect("127.0.0.1", port) {
      Ok(conn) => conn
      Err(_) => fail("loopback connect must not fail")
    }
    match @net.Conn::read_exact(conn, 4) {
      Err(@protocol.Internal) => ()
      _ => fail("read past a peer close must report the transport failure code")
    }
    @net.Conn::close(conn)
  }
}

///|
async test "TcpConn read_exact with a negative length reports the transport failure code" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      let (tcp, _) = server.accept()
      defer tcp.close()
    }
    let conn : @tcp.TcpConn = match @tcp.TcpConn::connect("127.0.0.1", port) {
      Ok(conn) => conn
      Err(_) => fail("loopback connect must not fail")
    }
    match @net.Conn::read_exact(conn, -1) {
      Err(@protocol.Internal) => ()
      _ => fail("a negative read length must report the transport failure code")
    }
    @net.Conn::close(conn)
  }
}

///|
async test "TcpConn close is idempotent and later reads and writes fail" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      let (tcp, _) = server.accept()
      defer tcp.close()
    }
    let conn : @tcp.TcpConn = match @tcp.TcpConn::connect("127.0.0.1", port) {
      Ok(conn) => conn
      Err(_) => fail("loopback connect must not fail")
    }
    @net.Conn::close(conn)
    @net.Conn::close(conn)
    match @net.Conn::write_all(conn, b"x") {
      Err(@protocol.Internal) => ()
      _ => fail("a write after close must report the transport failure code")
    }
    match @net.Conn::read_exact(conn, 1) {
      Err(@protocol.Internal) => ()
      _ => fail("a read after close must report the transport failure code")
    }
  }
}

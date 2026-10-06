/// Exercise the `Conn` contract on an in-memory transport.
///
/// The pipe-backed implementation pairs the async runtime's in-memory reader
/// -- a background task feeds bytes through a rendezvous pipe -- with a
/// collecting writer, so chunk reassembly, write delivery, close semantics,
/// and the transport-to-registry error mapping run on every target without
/// touching a socket.

///|
// Collects written bytes; accepts at most three bytes per call, so a
// successful delivery exercises the write loop.
struct CollectWriter {
  buf : Buffer
}

///|
impl @io.Writer for CollectWriter with fn write_once(
  self,
  buf : Bytes,
  offset~ : Int,
  len~ : Int,
) -> Int {
  let accepted = if len < 3 { len } else { 3 }
  self.buf.write_bytes(buf[offset:offset + accepted].to_owned())
  accepted
}

///|
// Reads replay a scripted feed; writes collect in memory; close is guarded
// so a read after close fails whole instead of tripping the pipe internals.
struct PipeConn {
  reader : @io.MemoryReader
  writer : CollectWriter
  mut closed : Bool
}

///|
fn pipe_conn(feed : async (&@io.Writer) -> Unit) -> PipeConn {
  let writer : CollectWriter = { buf: Buffer(), }
  { reader: @io.MemoryReader::MemoryReader(feed), writer, closed: false, }
}

///|
impl @net.Conn for PipeConn with fn read_exact(self, len : Int) -> Result[
  Bytes,
  @protocol.ErrCode,
] {
  if self.closed {
    return Err(@protocol.Internal)
  }
  let received = @io.Reader::read_exactly(self.reader, len) catch {
    _ => return Err(@protocol.Internal)
  }
  Ok(received)
}

///|
impl @net.Conn for PipeConn with fn write_all(self, data : Bytes) -> Result[
  Unit,
  @protocol.ErrCode,
] {
  @io.Writer::write(self.writer, data) catch {
    _ => return Err(@protocol.Internal)
  }
  Ok(())
}

///|
impl @net.Conn for PipeConn with fn close(self) -> Unit {
  if !self.closed {
    self.closed = true
    self.reader.close()
  }
}

///|
async test "read_exact reassembles writes split across chunk boundaries" {
  let conn = pipe_conn(writer => {
    @io.Writer::write(writer, b"h")
    @io.Writer::write(writer, b"el")
    @io.Writer::write(writer, b"lo")
  })
  assert_eq(@net.Conn::read_exact(conn, 5), Ok(b"hello"))
}

///|
async test "read_exact with zero length returns an empty frame and consumes nothing" {
  let conn = pipe_conn(writer => @io.Writer::write(writer, b"data"))
  assert_eq(@net.Conn::read_exact(conn, 0), Ok(b""))
  assert_eq(@net.Conn::read_exact(conn, 4), Ok(b"data"))
}

///|
async test "read_exact past the end of the stream reports the transport failure code" {
  let conn = pipe_conn(writer => @io.Writer::write(writer, b"ab"))
  match @net.Conn::read_exact(conn, 4) {
    Err(@protocol.Internal) => ()
    _ => fail("a short stream must fail whole with the transport failure code")
  }
}

///|
async test "write_all delivers every byte to the far end" {
  let conn = pipe_conn(_writer => ())
  assert_eq(@net.Conn::write_all(conn, b"payload"), Ok(()))
  assert_eq(conn.writer.buf.contents(), b"payload")
}

///|
async test "write_all of an empty buffer is a completed no-op" {
  let conn = pipe_conn(_writer => ())
  assert_eq(@net.Conn::write_all(conn, b""), Ok(()))
  assert_eq(conn.writer.buf.contents(), b"")
}

///|
async test "close is idempotent; a read after close reports the transport failure code" {
  let conn = pipe_conn(_writer => ())
  @net.Conn::close(conn)
  @net.Conn::close(conn)
  match @net.Conn::read_exact(conn, 1) {
    Err(@protocol.Internal) => ()
    _ => fail("a read after close must fail with the transport failure code")
  }
}

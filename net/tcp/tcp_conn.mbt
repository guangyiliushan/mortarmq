/// Wrap one native TCP socket as a `Conn`.
///
/// A `TcpConn` is one established TCP connection: `connect` performs the
/// handshake, reads wait for exactly the requested byte count so the frame
/// layer can stop at frame boundaries, writes loop until the peer has
/// accepted every byte, and `close` shuts the socket down without waiting
/// for the far end. The type exists only on the targets where the underlying
/// socket package supports TCP; browser and pure-core builds see the `Conn`
/// trait alone and stay transport-free. The wrapper type itself is load-
/// bearing: the trait cannot be implemented for the foreign socket type
/// directly, so this newtype carries the implementation.
///
/// # Errors
///
/// Every transport failure reports `Internal` (0x000A), the registry's
/// generic unexpected-failure code, because the registry has no
/// transport-domain range. The mapping:
///
/// * `connect` -- name resolution failure, connection refusal,
///   unreachability, or a local socket fault.
/// * `read_exact` -- end of stream before `len` bytes arrive, or a local
///   read fault.
/// * `write_all` -- a write fault, whether the socket was closed locally,
///   reset by the peer, or the buffer is unavailable.
/// * `close` -- never fails and reports nothing.

///|
/// One established native TCP connection, driven through the `Conn` trait.
pub struct TcpConn {
  priv tcp : @socket.Tcp
}

///|
// Trait methods promoted explicitly, matching the harness seam convention;
// keeps the implicit promotion deprecation from naming the surface for us.
pub extend TcpConn with @net.Conn::{read_exact, write_all, close}

///|
/// Open a TCP connection to `host`:`port` and wrap it for the frame layer.
///
/// `host` may be a DNS name or an IP literal; resolution follows the
/// platform resolver. The connection is ready for `read_exact` and
/// `write_all` on return; nothing is buffered here. The connect blocks
/// until the OS reports the handshake outcome -- there is no timeout
/// parameter, and a caller that needs bounded waiting layers it above
/// this call.
///
/// Parameters:
///
/// * `host` : Peer host name or IP literal.
/// * `port` : Peer TCP port.
///
/// Example:
///
/// ```mbt nocheck
/// async test {
///   // Nothing listens on TCP port 1 of the loopback address, so the
///   // connect fails whole instead of half-opening. Not a checked example:
///   // it touches the real loopback, so it would false-fail wherever
///   // something already listens on that port. The runnable coverage lives
///   // in the connect tests.
///   match @tcp.TcpConn::connect("127.0.0.1", 1) {
///     Err(@protocol.Internal) => ()
///     _ =>
///       fail(
///         "connect to a closed loopback port must report the transport failure code",
///       )
///   }
/// }
/// ```
///
/// # Errors
///
/// * Reports `Internal` (0x000A) when resolution, the handshake, or the
///   local socket setup fails; the OS detail is dropped.
pub async fn TcpConn::connect(
  host : String,
  port : Int,
) -> Result[TcpConn, @protocol.ErrCode] {
  let tcp = @socket.Tcp::connect_to_host(host, port~) catch {
    _ => return Err(@protocol.Internal)
  }
  Ok({ tcp, })
}

///|
/// Read exactly `len` bytes off the socket, waiting for frame-sized fills.
///
/// Returns the bytes as one `Bytes` value; a short stream fails whole. The
/// zero-length read returns an empty `Bytes` without touching the socket.
/// There is no upper bound here on purpose: the frame layer owns the
/// protocol maximum, and a negative `len` reports the transport failure
/// rather than inventing a read.
///
/// # Errors
///
/// * Reports `Internal` (0x000A) when the peer closes before `len` bytes
///   arrive or the read itself faults.
///
/// Example:
///
/// ```mbt nocheck
/// // Needs a live peer, so only the call shape is shown; the trait-level
/// // example and the loopback tests carry the runnable coverage.
/// let frame = @net.Conn::read_exact(conn, 4)?
/// ```
pub impl @net.Conn for TcpConn with fn read_exact(self, len : Int) -> Result[
  Bytes,
  @protocol.ErrCode,
] {
  if len < 0 {
    return Err(@protocol.Internal)
  }
  let received = @io.Reader::read_exactly(self.tcp, len) catch {
    _ => return Err(@protocol.Internal)
  }
  Ok(received)
}

///|
/// Push every byte of `data` onto the socket before returning.
///
/// An empty buffer is a completed no-op; a partial write keeps looping, so
/// the caller never resubmits.
///
/// # Errors
///
/// * Reports `Internal` (0x000A) when the write faults, including a socket
///   already closed locally or reset by the peer.
///
/// Example:
///
/// ```mbt nocheck
/// // Needs a live peer, so only the call shape is shown; the trait-level
/// // example and the loopback tests carry the runnable coverage.
/// @net.Conn::write_all(conn, frame)?
/// ```
pub impl @net.Conn for TcpConn with fn write_all(self, data : Bytes) -> Result[
  Unit,
  @protocol.ErrCode,
] {
  @io.Writer::write(self.tcp, data) catch {
    _ => return Err(@protocol.Internal)
  }
  Ok(())
}

///|
/// Shut the socket down now; the peer sees end of stream.
///
/// Idempotent and result-free: tearing down an already-torn-down socket
/// reports nothing. Later reads and writes on this connection fail.
pub impl @net.Conn for TcpConn with fn close(self) -> Unit {
  self.tcp.close()
}

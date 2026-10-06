/// Define the byte-pipe seam every peer connection speaks through.
///
/// A `Conn` is one ordered byte stream to one peer. `read_exact` pulls
/// exactly `len` bytes forward and waits for them, `write_all` pushes every
/// byte of one buffer onto the stream, and `close` releases the transport
/// without waiting for the far end. The frame layer reads its length prefix
/// and frame body with `read_exact` and stops at frame boundaries; nothing
/// in this trait knows about frames.
///
/// The method set is deliberately closed: no message framing, no half-close,
/// no TLS, no peer address. Both the native TCP transport in the `net/tcp`
/// package and any later session transport implement it unchanged, and code
/// written against the trait never names a transport: callers written as
/// `T : Conn` dispatch statically, and `&Conn` carries a connection whose
/// concrete type a lower layer owns.
///
/// # Boundaries
///
/// * `read_exact` with `len` 0 returns an empty `Bytes` without touching the
///   transport; `write_all` with an empty buffer is a completed no-op.
/// * A negative `len` is a caller error: the read reports the transport
///   failure instead of reading, and an implementation must not allocate a
///   buffer for it.
/// * `read_exact` fails whole -- it never returns a partial count.
/// * `close` is synchronous and safe to call after the peer or this side
///   already tore the transport down; later reads and writes fail.
///
/// # Errors
///
/// Transport failures map onto the shared error registry. The registry has
/// no transport-domain range, so a refused connect, a peer that closes
/// mid-read, and a local IO fault all report `Internal` (0x000A) with no OS
/// detail attached. Codes are only ever added, so a transport range can be
/// introduced later without changing this trait.

///|
/// Move exactly the requested bytes in either direction for one peer.
///
/// The example below shows the implementation shape and is not runnable: a
/// checked doc fence carries only test blocks, and an implementation needs
/// declarations. The executable contract lives in `net/conn_test.mbt` and
/// `client/conn_downstream_test.mbt`.
///
/// Example:
///
/// ```mbt nocheck
/// struct FixedConn {
///   mut payload : Bytes
/// }
///
/// impl @net.Conn for FixedConn with fn read_exact(self, len : Int) -> Result[
///   Bytes,
///   @protocol.ErrCode,
/// ] {
///   if len > self.payload.length() {
///     return Err(@protocol.Internal)
///   }
///   let served = self.payload[:len].to_owned()
///   self.payload = self.payload[len:].to_owned()
///   Ok(served)
/// }
///
/// impl @net.Conn for FixedConn with fn write_all(self, _data : Bytes) -> Result[
///   Unit,
///   @protocol.ErrCode,
/// ] {
///   Ok(())
/// }
///
/// impl @net.Conn for FixedConn with fn close(_self) -> Unit {
///
/// }
///
/// test {
///   let fixed = { payload: b"hello", }
///   assert_eq(@net.Conn::read_exact(fixed, 2), Ok(b"he"))
///   assert_eq(@net.Conn::read_exact(fixed, 3), Ok(b"llo"))
///   assert_eq(@net.Conn::read_exact(fixed, 1), Err(@protocol.Internal))
///   assert_eq(@net.Conn::write_all(fixed, b"x"), Ok(()))
///   @net.Conn::close(fixed)
/// }
/// ```
pub(open) trait Conn {
  /// Pull exactly `len` bytes forward through the stream, waiting as needed.
  async fn read_exact(Self, len : Int) -> Result[Bytes, @protocol.ErrCode]

  /// Push every byte of `data` onto the stream before returning.
  async fn write_all(Self, data : Bytes) -> Result[Unit, @protocol.ErrCode]

  /// Release the transport now; later reads and writes fail.
  fn close(Self) -> Unit
}

/// Wire-protocol limits for the v0 frame format.
///
/// A frame is `4-byte big-endian length || 1-byte op || payload[length - 1]`. `length` counts
/// the op byte itself, so the payload is always one byte shorter than the
/// length field claims. Every integer on the wire is big-endian.
///
/// The limits below are part of the protocol, not tuning knobs: two peers that
/// disagree on one of them cannot parse each other's frames.
///
/// Backpressure and flow control act only on whole frames. A reader never
/// stops in the middle of one, and a peer whose half-frame silence reaches
/// `HALF_FRAME_TIMEOUT_SECONDS` is disconnected rather than waited for.

///|
/// Maximum frame length in bytes, op byte included: 16 MiB.
///
/// A longer frame is rejected and the connection is closed. Neither side may
/// raise this on its own — the bound is agreed by the protocol, so changing it
/// is a protocol change rather than a configuration change.
pub const MAX_FRAME_LEN : UInt = 0x01000000U

///|
/// Maximum `PUB`/`MSG` value length: 16 MiB - 1 KiB.
///
/// Deliberately one kibibyte below `MAX_FRAME_LEN`. A value that fills this
/// budget still has to fit inside a frame once the field header, the key and
/// any trailing field are added, so the two limits are never equal and the gap
/// is reserved budget rather than slack.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@protocol.MAX_VALUE_LEN < @protocol.MAX_FRAME_LEN, true)
///   assert_eq(@protocol.MAX_FRAME_LEN - @protocol.MAX_VALUE_LEN, 1024U)
/// }
/// ```
pub const MAX_VALUE_LEN : UInt = 0x00FFFC00U

///|
/// Maximum key length in bytes: 255.
///
/// A key is compared as bytes. UTF-8 is not required, so a caller that stores
/// text chooses its own encoding and must not assume the broker validates it.
pub const MAX_KEY_LEN : UInt = 255U

///|
/// Maximum topic name length in bytes: 255.
///
/// Topic names are UTF-8 and are matched exactly. The bound is what keeps a
/// routing entry small enough to index without a second level of indirection.
pub const MAX_TOPIC_LEN : UInt = 255U

///|
/// Maximum length of an `ERR` diagnostic message in bytes: 512.
///
/// Longer diagnostics are rejected by the sender. The text is advisory:
/// clients branch on the numeric code and never on the message.
pub const MAX_ERR_MESSAGE : UInt = 512U

///|
/// Maximum `OK` result length in bytes: 16 MiB - 6.
///
/// The frame cap includes the operation byte, and an `OK` payload spends one
/// byte on `request_op` plus four bytes on `result_len`. A sender therefore
/// rejects a larger result instead of producing a frame that no receiver can
/// accept.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@protocol.MAX_OK_RESULT_LEN, 0x00FFFFFAU)
///   assert_eq(@protocol.MAX_FRAME_LEN - @protocol.MAX_OK_RESULT_LEN, 6U)
/// }
/// ```
pub const MAX_OK_RESULT_LEN : UInt = 0x00FFFFFAU

///|
/// Protocol version carried in the first `CONNECT` field: 1.
///
/// A receiver that does not know the offered version answers with
/// `UnsupportedVersion` and closes, so an older client fails immediately
/// instead of sending frames the server would misread. Bumping this value is
/// incompatible by definition and moves only with a new frame layout.
///
/// Example:
///
/// ```mbt check
/// test {
///   inspect(@protocol.WIRE_VERSION, content="1")
/// }
/// ```
pub const WIRE_VERSION : UInt = 1U

///|
/// Keepalive interval in seconds: 30.
///
/// If no complete frame arrives for 1.5x this interval (45 s) the server
/// closes the connection, and a partially received frame does not count as
/// liveness. The 1.5x multiplier follows MQTT section 3.1.2.10, so a client
/// written against that keepalive works here without tuning.
pub const KEEPALIVE_SECONDS : UInt = 30U

///|
/// How long a half-received frame may stay open, in seconds: 10.
///
/// The connection is closed when it expires; the byte stream is never
/// re-synchronised. Scanning forward for the next length prefix could not
/// distinguish a real frame from payload bytes, so recovery would corrupt
/// whatever follows instead of repairing it.
pub const HALF_FRAME_TIMEOUT_SECONDS : UInt = 10U

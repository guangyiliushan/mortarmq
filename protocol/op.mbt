///|
/// Defines the operation-byte namespace for the v0 wire protocol and keeps
/// reserved values outside the decoded domain.
///
/// The low nibble is fully assigned: `0x01` through `0x09` are the request and
/// common-response operations, while `0x0A` through `0x0F` carry delivery,
/// membership, and credit traffic. Every other byte is reserved, so decoding
/// returns `None` instead of mapping an unknown byte to a neighboring
/// operation.
///
/// # Stability
///
/// Adding an operation requires a new wire version. Published operation bytes
/// never change meaning and retired values are never reused.
///
/// # Example
///
/// ```mbt check
/// test {
///   assert_eq(@protocol.Op::from_byte(0x01), Some(@protocol.Op::Connect))
///   assert_eq(@protocol.Op::from_byte(0x10), None)
/// }
/// ```
pub(all) enum Op {
  Connect
  Declare
  Pub
  Sub
  Ack
  Nack
  Ping
  Err
  Ok
  Msg
  Pull
  Heartbeat
  Notice
  ControlAck
  Credit
} derive(Eq, Debug)

///|
pub extend Op with Eq::{not_equal, equal}

///|
pub extend Op with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Encode the operation byte that follows the frame length.
///
/// # Example
///
/// ```mbt check
/// test {
///   assert_eq(@protocol.Op::Connect.to_byte(), 0x01)
/// }
/// ```
pub fn Op::to_byte(self : Op) -> Byte {
  match self {
    Connect => 0x01
    Declare => 0x02
    Pub => 0x03
    Sub => 0x04
    Ack => 0x05
    Nack => 0x06
    Ping => 0x07
    Err => 0x08
    Ok => 0x09
    Msg => 0x0A
    Pull => 0x0B
    Heartbeat => 0x0C
    Notice => 0x0D
    ControlAck => 0x0E
    Credit => 0x0F
  }
}

///|
/// Decode an operation byte without allocating.
///
/// Returns `None` for `0x00` and every reserved byte from `0x10` through
/// `0xFF`; the caller turns that into `UnknownOp` and closes the connection.
///
/// # Example
///
/// ```mbt check
/// test {
///   assert_eq(@protocol.Op::from_byte(0x0F), Some(@protocol.Op::Credit))
///   assert_eq(@protocol.Op::from_byte(0x10), None)
/// }
/// ```
pub fn Op::from_byte(byte : Byte) -> Op? {
  match byte {
    0x01 => Some(Connect)
    0x02 => Some(Declare)
    0x03 => Some(Pub)
    0x04 => Some(Sub)
    0x05 => Some(Ack)
    0x06 => Some(Nack)
    0x07 => Some(Ping)
    0x08 => Some(Err)
    0x09 => Some(Ok)
    0x0A => Some(Msg)
    0x0B => Some(Pull)
    0x0C => Some(Heartbeat)
    0x0D => Some(Notice)
    0x0E => Some(ControlAck)
    0x0F => Some(Credit)
    _ => None
  }
}

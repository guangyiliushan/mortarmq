/// Exercise the complete operation-byte domain at its assigned/reserved boundary.

///|
test "operation table maps exactly the fifteen assigned bytes" {
  let mappings : Array[(@protocol.Op, Byte)] = [
    (@protocol.Connect, 0x01),
    (@protocol.Declare, 0x02),
    (@protocol.Pub, 0x03),
    (@protocol.Sub, 0x04),
    (@protocol.Ack, 0x05),
    (@protocol.Nack, 0x06),
    (@protocol.Ping, 0x07),
    (@protocol.Err, 0x08),
    (@protocol.Ok, 0x09),
    (@protocol.Msg, 0x0A),
    (@protocol.Pull, 0x0B),
    (@protocol.Heartbeat, 0x0C),
    (@protocol.Notice, 0x0D),
    (@protocol.ControlAck, 0x0E),
    (@protocol.Credit, 0x0F),
  ]
  assert_eq(mappings.length(), 15)
  for mapping in mappings {
    let (op, byte) = mapping
    assert_eq(op.to_byte(), byte)
    assert_eq(@protocol.Op::from_byte(byte), Some(op))
  }
}

///|
test "reserved operation bytes are pinned byte by byte" {
  let mappings : Array[(@protocol.Op, Byte)] = [
    (@protocol.Connect, 0x01),
    (@protocol.Declare, 0x02),
    (@protocol.Pub, 0x03),
    (@protocol.Sub, 0x04),
    (@protocol.Ack, 0x05),
    (@protocol.Nack, 0x06),
    (@protocol.Ping, 0x07),
    (@protocol.Err, 0x08),
    (@protocol.Ok, 0x09),
    (@protocol.Msg, 0x0A),
    (@protocol.Pull, 0x0B),
    (@protocol.Heartbeat, 0x0C),
    (@protocol.Notice, 0x0D),
    (@protocol.ControlAck, 0x0E),
    (@protocol.Credit, 0x0F),
  ]
  for value in 0..<=255 {
    let expected : @protocol.Op? = if value >= 1 && value <= 15 {
      Some(mappings[value - 1].0)
    } else {
      None
    }
    assert_eq(@protocol.Op::from_byte(value.to_byte()), expected)
  }
}

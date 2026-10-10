/// Frame codec properties CF1-CF4 (M3 suite S2, INV-010, REQ-QUA-002).
///
/// CF1 round-trip, CF2 hostile bytes never panic, CF3 length-boundary errors
/// fire at the exact position, CF4 malformed samples never pollute later
/// decodes. Each property pins seed and count so a failure reproduces
/// exactly. CF1-C3 belong to the commit tier and CF4 to the daily tier in the
/// M3 registry; CI scheduling is wired by the docs lane.
///
/// quickcheck is pinned by the toolchain (moon 0.1.20260920 /
/// moonbitlang/core 0.10.14+7d59c7ec9), see the note in moon.mod.

///|
/// Wrap a payload in a complete frame: `u32_be length || op || payload`.
fn props_frame(op : @protocol.Op, payload : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_uint_be((payload.length() + 1).reinterpret_as_uint())
  buf.write_byte(op.to_byte())
  buf.write_bytes(payload[:])
  buf.contents()
}

///|
/// The receive path under test: frame header, then operation payload.
fn props_decode(
  frame : BytesView,
) -> Result[(@protocol.Op, @protocol.WirePayload), @protocol.ErrCode] {
  match @protocol.decode_frame(frame) {
    @protocol.Frame(op, payload) =>
      match @protocol.decode_wire_payload(op, payload) {
        Ok(decoded) => Ok((op, decoded))
        Err(code) => Err(code)
      }
    @protocol.DecodeError(code) => Err(code)
    @protocol.Need(_) => Err(@protocol.BadLength)
  }
}

///|
/// A legal constructor derived from one draw: seven op shapes with
/// draw-derived field lengths inside protocol bounds.
fn props_legal_payload(
  draw : UInt,
) -> Result[(@protocol.Op, @protocol.WirePayload), @protocol.ErrCode] {
  let d = draw.reinterpret_as_int()
  match draw % 7U {
    0U =>
      Ok(
        (
          @protocol.Op::Pub,
          @protocol.WirePayload::Pub({
            topic_id: (d % 8).to_uint16(),
            partition: (d % 4).to_uint16(),
            producer_id: draw.to_uint64(),
            producer_seq: (draw >> 3).to_uint64(),
            flags: 0,
            key: Bytes::makei(d % 256, i => (i % 251).to_byte()),
            value: Bytes::makei(d % 96, i => ((i * 7 + 1) % 251).to_byte()),
          }),
        ),
      )
    1U =>
      Ok(
        (
          @protocol.Op::Msg,
          @protocol.WirePayload::Msg({
            subscription_id: (d % 5).to_uint16(),
            topic_id: (d % 8).to_uint16(),
            partition: (d % 4).to_uint16(),
            sequence: draw.to_uint64(),
            delivery_id: (draw >> 1).to_uint64(),
            attempt: (d % 3).to_uint16(),
            ownership_epoch: (draw >> 2).to_uint64(),
            producer_id: draw.to_uint64(),
            producer_seq: (draw >> 3).to_uint64(),
            flags: 0,
            key: Bytes::makei(d % 256, i => (i % 251).to_byte()),
            value: Bytes::makei(d % 64, i => ((i * 3 + 2) % 251).to_byte()),
          }),
        ),
      )
    2U =>
      Ok(
        (
          @protocol.Op::Declare,
          @protocol.WirePayload::Declare({
            topic: Bytes::makei(d % 256, i => (i % 251).to_byte()),
            partition_count: (d % 16 + 1).to_uint16(),
            flags: 0,
          }),
        ),
      )
    3U =>
      Ok(
        (
          @protocol.Op::Connect,
          @protocol.WirePayload::Connect({
            protocol_version: 1,
            client_flags: (d % 4).to_uint16(),
            token: Bytes::makei(d % 32, i => ((i * 5 + 1) % 251).to_byte()),
          }),
        ),
      )
    4U =>
      Ok(
        (
          @protocol.Op::Sub,
          @protocol.WirePayload::Sub({
            group: Bytes::makei(d % 64, i => (i % 251).to_byte()),
            topic_id: (d % 8).to_uint16(),
            partition: 0xFFFF,
            start_policy: (d % 3).to_byte(),
            credit_count: (d % 64).to_uint16(),
            credit_bytes: (d % 8192).reinterpret_as_uint(),
            flags: 0,
          }),
        ),
      )
    5U => Ok((@protocol.Op::Ping, @protocol.WirePayload::Ping))
    _ =>
      Ok(
        (
          @protocol.Op::Ack,
          @protocol.WirePayload::Ack({
            subscription_id: (d % 5).to_uint16(),
            topic_id: (d % 8).to_uint16(),
            partition: (d % 4).to_uint16(),
            sequence: draw.to_uint64(),
            delivery_id: (draw >> 1).to_uint64(),
            ownership_epoch: (draw >> 2).to_uint64(),
            flags: 0,
          }),
        ),
      )
  }
}

///|
/// CF1: a legal frame decodes and re-encodes to the same bytes.
test "CF1 legal frame round-trips through decode then encode (quickcheck seed=20261010 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let (op, payload) = match props_legal_payload(draw) {
        Ok(pair) => pair
        Err(_) => return false
      }
      let body = match @protocol.encode_wire_payload(payload) {
        Ok(bytes) => bytes
        Err(_) => return false
      }
      let frame = props_frame(op, body)
      match props_decode(frame[:]) {
        Ok((decoded_op, decoded)) => {
          if decoded_op != op {
            return false
          }
          match @protocol.encode_wire_payload(decoded) {
            Ok(rebuilt) => rebuilt == body && decoded == payload
            Err(_) => false
          }
        }
        Err(_) => false
      }
    },
    count=200,
    seed=20261010,
  )
}

///|
/// CF2: arbitrary bytes never panic; decode only classifies them.
test "CF2 arbitrary bytes decode without panicking (quickcheck seed=20261011 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let length = (draw % 2048U).reinterpret_as_int()
      let junk = Bytes::makei(length, i => {
        (draw.reinterpret_as_int() + i * 31).to_byte()
      })
      // A panic surfaces as an exceptional counterexample and fails the test;
      // every normal outcome folds to true.
      match @protocol.decode_frame(junk[:]) {
        @protocol.Need(_) => true
        @protocol.DecodeError(_) => true
        @protocol.Frame(op, payload) =>
          match @protocol.decode_wire_payload(op, payload) {
            Ok(_) => true
            Err(_) => true
          }
      }
    },
    count=200,
    seed=20261011,
  )
}

///|
/// CF3: length-boundary faults fail at the length field itself.
///
/// The deterministic prelude pins the five documented boundaries with exact
/// outcomes; the property then drives the raw length with the integer
/// portfolio so 0 and u32::max arrive as counterexample candidates.
test "CF3 length boundaries reject at the exact position (quickcheck seed=20261012 is reproducible)" {
  let prefix_of = fn(length : UInt) -> Bytes {
    let buf = Buffer()
    buf.write_uint_be(length)
    buf.contents()
  }
  // 0 -> BAD_LENGTH on the four length bytes alone.
  match @protocol.decode_frame(prefix_of(0U)[:]) {
    @protocol.DecodeError(@protocol.BadLength) => ()
    _ => fail("length=0 must fail at the length field")
  }
  // 1 -> the minimum legal frame waits for its op byte, then decodes empty.
  match @protocol.decode_frame(prefix_of(1U)[:]) {
    @protocol.Need(1) => ()
    _ => fail("length=1 must wait for exactly one byte")
  }
  match @protocol.decode_frame(props_frame(@protocol.Op::Ping, b"")[:]) {
    @protocol.Frame(@protocol.Op::Ping, payload) =>
      if payload.length() != 0 {
        fail("length=1 frame payload must be empty")
      }
    _ => fail("length=1 frame must decode")
  }
  // MAX_FRAME_LEN is legal (waits); MAX_FRAME_LEN+1 and u32::max are not.
  match @protocol.decode_frame(prefix_of(@protocol.MAX_FRAME_LEN)[:]) {
    @protocol.Need(1) => ()
    _ => fail("max length must wait for its op byte")
  }
  match @protocol.decode_frame(prefix_of(@protocol.MAX_FRAME_LEN + 1U)[:]) {
    @protocol.DecodeError(@protocol.BadLength) => ()
    _ => fail("max+1 must fail at the length field")
  }
  match @protocol.decode_frame(prefix_of(0xFFFFFFFFU)[:]) {
    @protocol.DecodeError(@protocol.BadLength) => ()
    _ => fail("u32 max must fail at the length field")
  }
  @quickcheck.check(
    (draw : UInt) => {
      match @protocol.decode_frame(prefix_of(draw)[:]) {
        @protocol.DecodeError(code) =>
          code == @protocol.BadLength &&
          (draw == 0U || draw > @protocol.MAX_FRAME_LEN)
        @protocol.Need(more) =>
          draw >= 1U && draw <= @protocol.MAX_FRAME_LEN && more == 1
        @protocol.Frame(_, _) => false
      }
    },
    count=200,
    seed=20261012,
  )
}

///|
/// CF4: malformed samples never pollute the parser; a legal frame still
/// decodes after any number of hostile inputs.
test "CF4 hostile frames do not pollute later decodes (quickcheck seed=20261013 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let junk_len = (draw % 512U).reinterpret_as_int() + 1
      for round in 0..<4 {
        let junk = Bytes::makei(junk_len, i => {
          (draw.reinterpret_as_int() + round * 17 + i).to_byte()
        })
        match @protocol.decode_frame(junk[:]) {
          @protocol.Need(_) => ()
          @protocol.DecodeError(_) => ()
          @protocol.Frame(op, payload) =>
            match @protocol.decode_wire_payload(op, payload) {
              Ok(_) => ()
              Err(_) => ()
            }
        }
      }
      let (op, payload) = match props_legal_payload(0x00C0FFEEU + draw % 16U) {
        Ok(pair) => pair
        Err(_) => return false
      }
      let body = match @protocol.encode_wire_payload(payload) {
        Ok(bytes) => bytes
        Err(_) => return false
      }
      let frame = props_frame(op, body)
      match props_decode(frame[:]) {
        Ok((decoded_op, decoded)) => decoded_op == op && decoded == payload
        Err(_) => false
      }
    },
    count=200,
    seed=20261013,
  )
}

///|
/// Daily-tier frame property: malformed samples never pollute the
/// parser; a legal frame still decodes after hostile inputs. This is the
/// daily-tier counterpart of the pinned pollution property in
/// `frame_props_test.mbt`: with `MORTARMQ_PROP_DAILY` set the sweep runs
/// registry daily mode -- run-unique seed from the clock, count=1000,
/// max_size=256 -- and logs the seed so a failure reproduces. Without the
/// flag it runs the committed pin (seed=20261013, count=200, max_size=100) so
/// plain `moon test` stays reproducible. The `daily_*` helper names are
/// deliberate: blackbox test files share one package namespace and the
/// pin file owns the `props_*` names.

///|
fn daily_mode() -> Bool {
  match @env.get_env_var("MORTARMQ_PROP_DAILY") {
    Some(_) => true
    None => false
  }
}

///|
fn daily_seed() -> UInt64 {
  if daily_mode() {
    @env.now()
  } else {
    20261013UL
  }
}

///|
fn daily_count() -> UInt {
  if daily_mode() {
    1000U
  } else {
    200U
  }
}

///|
fn daily_max_size() -> UInt {
  if daily_mode() {
    256U
  } else {
    100U
  }
}

///|
/// Wrap a payload in a complete frame: `u32_be length || op || payload`.
fn daily_frame(op : @protocol.Op, payload : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_uint_be((payload.length() + 1).reinterpret_as_uint())
  buf.write_byte(op.to_byte())
  buf.write_bytes(payload[:])
  buf.contents()
}

///|
/// Daily sweep: hostile frames do not pollute later decodes.
test "daily sweep: hostile frames do not pollute later decodes (pin seed=20261013; daily mode logs the run seed)" {
  let seed = daily_seed()
  let count = daily_count()
  let max_size = daily_max_size()
  if daily_mode() {
    println("daily-sweep seed=\{seed} count=\{count} max_size=\{max_size}")
  }
  @quickcheck.check(
    (draw : UInt) => {
      let junk_len = (draw % 512U).reinterpret_as_int() + 1
      for round in 0..<8 {
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
      let body = match
        @protocol.encode_wire_payload(@protocol.WirePayload::Ping) {
        Ok(bytes) => bytes
        Err(_) => return false
      }
      let frame = daily_frame(@protocol.Op::Ping, body)
      match @protocol.decode_frame(frame[:]) {
        @protocol.Frame(op, payload) =>
          op == @protocol.Op::Ping &&
          (match @protocol.decode_wire_payload(op, payload) {
            Ok(decoded) => decoded == @protocol.WirePayload::Ping
            Err(_) => false
          })
        _ => false
      }
    },
    count~,
    max_size~,
    max_shrinks=20,
    seed~,
  )
}

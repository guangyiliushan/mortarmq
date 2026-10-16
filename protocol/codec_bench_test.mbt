/// The codec benchmark grid: frozen size grid x encode / decode / decode+copy.
///
/// The size axis is total frame bytes on the wire, the same axis as the
/// 2026-09-30 historical baseline (decode_64B/1KiB/64KiB were measured on full
/// frame buffers). The grid is frozen: empty / 64B / 1KiB / 64KiB / 1MiB /
/// 16MiB, each measured as
/// `encode`, `decode`, and `decode+copy topic/key/value`. Do not reshape this
/// matrix to make numbers look better; report whatever it prints.
///
/// Workload notes (instantiation, not a change of the grid):
/// - `empty` is the minimum legal frame (PING, 5 bytes on the wire).
/// - `64B`..`1MiB` are exact-size PUB frames (hot producer path) with an
///   8-byte key and the rest of the budget as value.
/// - `16MiB` is the largest legal PUB frame (16 MiB - 736 B: max key plus a
///   value of MAX_VALUE_LEN). An exactly 16 MiB PUB frame is protocol-
///   illegal because MAX_VALUE_LEN deliberately sits below MAX_FRAME_LEN.
/// - `decode` is the full receive path: decode_frame + decode_wire_payload,
///   borrowing every field.
/// - `decode+copy` additionally materializes key and value with to_owned(),
///   the ownership-boundary copy a consumer pays when it keeps a field.
/// - `decode_frame` rows are the continuity check against the historical
///   65-80 ns band, which was measured on the frame layer alone.

///|
/// Build a PUB frame whose total wire size is exactly `total` bytes.
fn bench_pub_frame(total : Int32) -> Bytes raise {
  if total < 33 {
    fail("bench frame smaller than the PUB fixed fields")
  }
  // Prefer an 8-byte key; grow the key only when the value would cross
  // MAX_VALUE_LEN (the 16MiB cell is the max legal frame).
  let value_budget = total - 33
  let value_len = if value_budget - 8 >
    @protocol.MAX_VALUE_LEN.reinterpret_as_int() {
    @protocol.MAX_VALUE_LEN.reinterpret_as_int()
  } else {
    value_budget - 8
  }
  let key_len = value_budget - value_len
  if key_len > 255 {
    fail("bench frame cannot be represented as one PUB key/value")
  }
  let key = Bytes::makei(key_len, i => (i % 251).to_byte())
  let value = Bytes::makei(value_len, i => ((i * 7 + 1) % 251).to_byte())
  let body = match
    @protocol.encode_wire_payload(
      @protocol.WirePayload::Pub({
        topic_id: 1,
        partition: 2,
        producer_id: 3UL,
        producer_seq: 4UL,
        flags: 0,
        key: key[:],
        value: value[:],
      }),
    ) {
    Ok(body) => body
    Err(_) => fail("bench PUB payload did not encode")
  }
  let buf = Buffer()
  buf.write_uint_be((body.length() + 1).reinterpret_as_uint())
  buf.write_byte(@protocol.Op::Pub.to_byte())
  buf.write_bytes(body[:])
  let frame = buf.contents()
  if frame.length() != total {
    fail("bench frame size drifted from the matrix cell")
  }
  frame
}

///|
/// The minimum legal frame: PING with an empty payload.
fn bench_ping_frame() -> Bytes {
  b"\x00\x00\x00\x01\x07"
}

///|
/// Decode one whole frame the way the receive path does: frame header first,
/// then the operation payload, borrowing every field.
fn bench_decode_frame_and_payload(
  frame : BytesView,
) -> Result[@protocol.WirePayload, @protocol.ErrCode] {
  match @protocol.decode_frame(frame) {
    @protocol.Frame(op, payload) => @protocol.decode_wire_payload(op, payload)
    @protocol.DecodeError(code) => Err(code)
    @protocol.Need(_) => Err(@protocol.BadLength)
  }
}

///|
/// The constructor an encoder would be handed for each matrix frame.
fn bench_pub_constructor(
  key_len : Int32,
  value_len : Int32,
) -> @protocol.WirePayload {
  let key = Bytes::makei(key_len, i => (i % 251).to_byte())
  let value = Bytes::makei(value_len, i => ((i * 7 + 1) % 251).to_byte())
  @protocol.WirePayload::Pub({
    topic_id: 1,
    partition: 2,
    producer_id: 3UL,
    producer_seq: 4UL,
    flags: 0,
    key: key[:],
    value: value[:],
  })
}

///|
test "bench encode matrix (frozen grid)" (it : @bench.T) {
  let empty = @protocol.WirePayload::Ping
  let s64 = bench_pub_constructor(8, 64 - 33 - 8)
  let s1k = bench_pub_constructor(8, 1024 - 33 - 8)
  let s64k = bench_pub_constructor(8, 65536 - 33 - 8)
  let s1m = bench_pub_constructor(8, 1048576 - 33 - 8)
  let s16m = bench_pub_constructor(
    255,
    @protocol.MAX_VALUE_LEN.reinterpret_as_int(),
  )
  it.bench(name="encode/empty", fn() {
    it.keep(@protocol.encode_wire_payload(empty))
  })
  it.bench(name="encode/64B", fn() {
    it.keep(@protocol.encode_wire_payload(s64))
  })
  it.bench(name="encode/1KiB", fn() {
    it.keep(@protocol.encode_wire_payload(s1k))
  })
  it.bench(name="encode/64KiB", fn() {
    it.keep(@protocol.encode_wire_payload(s64k))
  })
  it.bench(name="encode/1MiB", fn() {
    it.keep(@protocol.encode_wire_payload(s1m))
  })
  it.bench(name="encode/16MiB", fn() {
    it.keep(@protocol.encode_wire_payload(s16m))
  })
}

///|
test "bench decode matrix (frozen grid)" (it : @bench.T) {
  let empty = bench_ping_frame()
  let s64 = bench_pub_frame(64)
  let s1k = bench_pub_frame(1024)
  let s64k = bench_pub_frame(65536)
  let s1m = bench_pub_frame(1048576)
  let s16m = bench_pub_frame(
    33 + 255 + @protocol.MAX_VALUE_LEN.reinterpret_as_int(),
  )
  it.bench(name="decode/empty", fn() {
    it.keep(bench_decode_frame_and_payload(empty[:]))
  })
  it.bench(name="decode/64B", fn() {
    it.keep(bench_decode_frame_and_payload(s64[:]))
  })
  it.bench(name="decode/1KiB", fn() {
    it.keep(bench_decode_frame_and_payload(s1k[:]))
  })
  it.bench(name="decode/64KiB", fn() {
    it.keep(bench_decode_frame_and_payload(s64k[:]))
  })
  it.bench(name="decode/1MiB", fn() {
    it.keep(bench_decode_frame_and_payload(s1m[:]))
  })
  it.bench(name="decode/16MiB", fn() {
    it.keep(bench_decode_frame_and_payload(s16m[:]))
  })
}

///|
/// The ownership-boundary copy: materialize the borrowed key/value fields.
fn bench_copy_fields(
  decoded : Result[@protocol.WirePayload, @protocol.ErrCode],
) -> Result[(Bytes, Bytes), @protocol.ErrCode] {
  match decoded {
    Ok(@protocol.WirePayload::Pub(p)) =>
      Ok((p.key.to_owned(), p.value.to_owned()))
    Ok(@protocol.WirePayload::Ping) => Ok((b"", b""))
    Ok(_) => Err(@protocol.MalformedPayload)
    Err(code) => Err(code)
  }
}

///|
test "bench decode+copy matrix (frozen grid)" (it : @bench.T) {
  let empty = bench_ping_frame()
  let s64 = bench_pub_frame(64)
  let s1k = bench_pub_frame(1024)
  let s64k = bench_pub_frame(65536)
  let s1m = bench_pub_frame(1048576)
  let s16m = bench_pub_frame(
    33 + 255 + @protocol.MAX_VALUE_LEN.reinterpret_as_int(),
  )
  it.bench(name="decode+copy/empty", fn() {
    it.keep(bench_copy_fields(bench_decode_frame_and_payload(empty[:])))
  })
  it.bench(name="decode+copy/64B", fn() {
    it.keep(bench_copy_fields(bench_decode_frame_and_payload(s64[:])))
  })
  it.bench(name="decode+copy/1KiB", fn() {
    it.keep(bench_copy_fields(bench_decode_frame_and_payload(s1k[:])))
  })
  it.bench(name="decode+copy/64KiB", fn() {
    it.keep(bench_copy_fields(bench_decode_frame_and_payload(s64k[:])))
  })
  it.bench(name="decode+copy/1MiB", fn() {
    it.keep(bench_copy_fields(bench_decode_frame_and_payload(s1m[:])))
  })
  it.bench(name="decode+copy/16MiB", fn() {
    it.keep(bench_copy_fields(bench_decode_frame_and_payload(s16m[:])))
  })
}

///|
test "bench decode_frame continuity vs 2026-09-30 band" (it : @bench.T) {
  let s64 = bench_pub_frame(64)
  let s1k = bench_pub_frame(1024)
  let s64k = bench_pub_frame(65536)
  it.bench(name="decode_frame/64B", fn() {
    it.keep(@protocol.decode_frame(s64[:]))
  })
  it.bench(name="decode_frame/1KiB", fn() {
    it.keep(@protocol.decode_frame(s1k[:]))
  })
  it.bench(name="decode_frame/64KiB", fn() {
    it.keep(@protocol.decode_frame(s64k[:]))
  })
}

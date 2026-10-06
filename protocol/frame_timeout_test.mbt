/// Pin the half-frame timeout policy attached to the decoder's `Need` result.
///
/// `decode_frame` is pure, so the deadline lives in the read loop around it.
/// This file carries a reference loop small enough to copy into a real
/// connection reader: decode what is buffered, measure silence from the last
/// byte that joined the current partial frame, and close the connection once
/// a partial frame has gone `HALF_FRAME_TIMEOUT_SECONDS` without progress.
/// The fake clock moves only forward through `advance_to`, so every deadline
/// below is crossed exactly once and never in reverse.

///|
/// Start the golden CONNECT frame with the first two length-prefix bytes.
let connect_head : Bytes = b"\x00\x00"

///|
/// Complete the length prefix and reveal the CONNECT operation byte.
let connect_mid : Bytes = b"\x00\x0d\x01"

///|
/// Carry the twelve payload bytes that complete the golden frame.
let connect_tail : Bytes = b"\x01\x00\x00\x00\x03a\x62\x63\x00\x00\x00\x00"

///|
/// Pin the chunks to the golden vector they must reassemble; the literal is
/// the same CONNECT frame pinned in golden_test.mbt.
let connect_frame : Bytes = b"\x00\x00\x00\x0d\x01\x01\x00\x00\x00\x03a\x62\x63\x00\x00\x00\x00"

///|
/// Report one step of the reference read loop under the half-frame policy.
priv enum LoopStep {
  /// The partial frame is inside its budget; keep waiting for more bytes.
  Waiting(Int)
  /// The partial frame exhausted its budget; stop reading and close.
  Expired(Int)
  /// A complete frame is buffered and ready to hand downstream.
  Ready
  /// The decoder rejected the stream; close without consulting the clock.
  Rejected(@protocol.ErrCode)
  /// Nothing partial is buffered, so the half-frame clock is not running.
  Idle
} derive(Eq, Debug)

///|
/// Run one read-loop step over `buffer` under the half-frame timeout policy.
///
/// `progress_ms` is when the current partial frame last gained a byte and
/// `now_ms` is the monotonic clock reading, so `now_ms >= progress_ms` always
/// holds. A `Need` result keeps the loop waiting only while the silence since
/// `progress_ms` stays below `HALF_FRAME_TIMEOUT_SECONDS`; once it reaches the
/// budget the loop stops reading the half frame and closes the connection. An
/// empty buffer holds no partial frame, so the deadline is never armed there
/// and keepalive policy governs that silence instead.
fn reader_step(
  buffer : Bytes,
  progress_ms : UInt64,
  now_ms : UInt64,
) -> LoopStep {
  let budget_ms = @protocol.HALF_FRAME_TIMEOUT_SECONDS.to_uint64() * 1000UL
  if buffer.length() == 0 {
    return Idle
  }
  match @protocol.decode_frame(buffer[:]) {
    @protocol.Need(more) =>
      if now_ms - progress_ms >= budget_ms {
        Expired(more)
      } else {
        Waiting(more)
      }
    @protocol.Frame(_, _) => Ready
    @protocol.DecodeError(code) => Rejected(code)
  }
}

///|
async test "a half frame inside its timeout budget keeps the connection open" {
  let clock = @harness.FakeClock::new()
  let buffer : Bytes = connect_head
  // The first bytes of a frame start the deadline at progress + 10_000 ms.
  assert_eq(reader_step(buffer, 0UL, 0UL), Waiting(2))
  assert_eq(@harness.Clock::sleep_until(clock, 10_000UL), false)
  clock.advance_to(9_999UL)
  assert_eq(reader_step(buffer, 0UL, @harness.Clock::now_ms(clock)), Waiting(2))
  assert_eq(clock.fired_deadlines().length(), 0)
}

///|
async test "a half frame whose deadline fires is disconnected rather than waited for" {
  let clock = @harness.FakeClock::new()
  let buffer : Bytes = connect_head
  assert_eq(@harness.Clock::sleep_until(clock, 10_000UL), false)
  clock.advance_to(10_000UL)
  assert_eq(clock.fired_deadlines(), [10_000UL])
  // The deadline fired with no progress, so the loop stops reading the
  // remaining bytes and closes instead of waiting for them.
  assert_eq(reader_step(buffer, 0UL, @harness.Clock::now_ms(clock)), Expired(2))
}

///|
async test "progress moves the half-frame deadline instead of expiring it" {
  let clock = @harness.FakeClock::new()
  let mut buffer : Bytes = connect_head
  assert_eq(@harness.Clock::sleep_until(clock, 10_000UL), false)
  // One millisecond before the first deadline, the length prefix and the
  // operation byte arrive; the wait restarts from this progress.
  clock.advance_to(9_999UL)
  buffer = buffer + connect_mid
  assert_eq(
    reader_step(buffer, 0UL, @harness.Clock::now_ms(clock)),
    Waiting(12),
  )
  assert_eq(@harness.Clock::sleep_until(clock, 19_999UL), false)
  // The 10_000 ms timer still fires after the progress moved the deadline;
  // the loop judges by the latest progress, not by the stale timer.
  clock.advance_to(19_998UL)
  assert_eq(
    reader_step(buffer, 9_999UL, @harness.Clock::now_ms(clock)),
    Waiting(12),
  )
  clock.advance_to(19_999UL)
  assert_eq(
    reader_step(buffer, 9_999UL, @harness.Clock::now_ms(clock)),
    Expired(12),
  )
  assert_eq(clock.fired_deadlines(), [10_000UL, 19_999UL])
}

///|
async test "completing the frame before its deadline delivers and disarms the wait" {
  let clock = @harness.FakeClock::new()
  let mut buffer : Bytes = connect_head
  assert_eq(@harness.Clock::sleep_until(clock, 10_000UL), false)
  clock.advance_to(4_000UL)
  buffer = buffer + connect_mid + connect_tail
  assert_eq(buffer, connect_frame)
  match @protocol.decode_frame(buffer[:]) {
    @protocol.Frame(@protocol.Op::Connect, payload) =>
      assert_eq(payload.length(), 12)
    _ => fail("expected the golden CONNECT frame to decode complete")
  }
  assert_eq(reader_step(buffer, 0UL, @harness.Clock::now_ms(clock)), Ready)
  // The frame left the buffer whole; with nothing partial, elapsed time
  // alone expires nothing and the loop returns to waiting idle.
  clock.advance_to(100_000UL)
  assert_eq(reader_step(b"", 4_000UL, @harness.Clock::now_ms(clock)), Idle)
}

///|
test "a wire error closes without consulting the half-frame deadline" {
  let bad_length : Bytes = b"\x00\x00\x00\x00"
  assert_eq(reader_step(bad_length, 0UL, 0UL), Rejected(@protocol.BadLength))
}

/// Exercise the derived consumer cursor and its truth
/// hierarchy (L4): the delivery log decides, the checkpoint may only
/// agree or lose. The floor advances over durable completions only,
/// never regresses (CQ1), and recovery replays the log whatever the
/// checkpoint claims.

///|
fn deliver_event(group_id : UInt16, sequence : UInt64) -> @delivery.LedgerEvent {
  @delivery.LedgerEvent::new(
    group_id~,
    event=@delivery.LedgerEventKind::Deliver,
    sequence~,
    delivery_id=sequence + 1UL,
    owner_conn=1UL,
    attempt=1U.to_uint16(),
    delay_ms=0U,
    reason=@delivery.NackReason::Retry,
    timestamp=0UL,
  )
}

///|
fn ack_event(group_id : UInt16, sequence : UInt64) -> @delivery.LedgerEvent {
  @delivery.LedgerEvent::new(
    group_id~,
    event=@delivery.LedgerEventKind::Ack,
    sequence~,
    delivery_id=sequence + 1UL,
    owner_conn=1UL,
    attempt=1U.to_uint16(),
    delay_ms=0U,
    reason=@delivery.NackReason::Retry,
    timestamp=0UL,
  )
}

///|
fn nack_terminal_event(
  group_id : UInt16,
  sequence : UInt64,
) -> @delivery.LedgerEvent {
  @delivery.LedgerEvent::new(
    group_id~,
    event=@delivery.LedgerEventKind::NackTerminal,
    sequence~,
    delivery_id=sequence + 1UL,
    owner_conn=1UL,
    attempt=5U.to_uint16(),
    delay_ms=0U,
    reason=@delivery.NackReason::Terminal,
    timestamp=0UL,
  )
}

///|
fn dlq_written_event(
  group_id : UInt16,
  sequence : UInt64,
) -> @delivery.LedgerEvent {
  @delivery.LedgerEvent::new(
    group_id~,
    event=@delivery.LedgerEventKind::DlqWritten,
    sequence~,
    delivery_id=900UL + sequence,
    owner_conn=0UL,
    attempt=5U.to_uint16(),
    delay_ms=0U,
    reason=@delivery.NackReason::Terminal,
    timestamp=0UL,
  )
}

///|
fn fenced_event(group_id : UInt16, sequence : UInt64) -> @delivery.LedgerEvent {
  @delivery.LedgerEvent::new(
    group_id~,
    event=@delivery.LedgerEventKind::Fenced,
    sequence~,
    delivery_id=sequence + 1UL,
    owner_conn=2UL,
    attempt=1U.to_uint16(),
    delay_ms=0U,
    reason=@delivery.NackReason::Retry,
    timestamp=0UL,
  )
}

///|
test "the cursor derives from the log alone" {
  let events = [
    deliver_event(1, 0UL),
    ack_event(1, 0UL),
    deliver_event(1, 1UL),
    ack_event(1, 1UL),
    deliver_event(1, 2UL),
  ]
  let cursor = @broker.ConsumerCursor::replay(1, 0UL, events)
  assert_eq(@broker.ConsumerCursor::ack_floor(cursor), 2UL)
  assert_eq(@broker.ConsumerCursor::scanned(cursor), 5UL)
  // Another group's events never touch this cursor but do move the scan.
  let mixed = [ack_event(2, 0UL), ack_event(1, 2UL)]
  let other = @broker.ConsumerCursor::replay(1, 0UL, mixed)
  assert_eq(@broker.ConsumerCursor::ack_floor(other), 0UL)
  assert_eq(@broker.ConsumerCursor::scanned(other), 2UL)
}

///|
test "out of order acks advance only the contiguous floor" {
  let cursor = @broker.ConsumerCursor::new(1, 0UL)
  @broker.ConsumerCursor::observe(cursor, ack_event(1, 2UL))
  assert_eq(@broker.ConsumerCursor::ack_floor(cursor), 0UL)
  @broker.ConsumerCursor::observe(cursor, ack_event(1, 1UL))
  assert_eq(@broker.ConsumerCursor::ack_floor(cursor), 0UL)
  @broker.ConsumerCursor::observe(cursor, ack_event(1, 0UL))
  assert_eq(@broker.ConsumerCursor::ack_floor(cursor), 3UL)
}

///|
test "a dead letter counts only once its dlq record is durable" {
  let cursor = @broker.ConsumerCursor::new(1, 0UL)
  @broker.ConsumerCursor::observe(cursor, ack_event(1, 0UL))
  @broker.ConsumerCursor::observe(cursor, deliver_event(1, 1UL))
  @broker.ConsumerCursor::observe(cursor, nack_terminal_event(1, 1UL))
  // Terminal intent is not a durable completion: the floor stays put.
  assert_eq(@broker.ConsumerCursor::ack_floor(cursor), 1UL)
  @broker.ConsumerCursor::observe(cursor, dlq_written_event(1, 1UL))
  assert_eq(@broker.ConsumerCursor::ack_floor(cursor), 2UL)
}

///|
test "restart replaying the same log derives the same cursor" {
  let events = [
    deliver_event(1, 0UL),
    ack_event(1, 0UL),
    deliver_event(1, 1UL),
    fenced_event(1, 1UL),
    deliver_event(1, 1UL),
    ack_event(1, 1UL),
    deliver_event(1, 2UL),
  ]
  let first = @broker.ConsumerCursor::replay(1, 0UL, events)
  let second = @broker.ConsumerCursor::replay(1, 0UL, events)
  assert_eq(
    @broker.ConsumerCursor::checkpoint(first),
    @broker.ConsumerCursor::checkpoint(second),
  )
}

///|
test "a checkpoint behind the log is lagging and the log wins" {
  let events = [ack_event(1, 0UL), ack_event(1, 1UL), ack_event(1, 2UL)]
  let cursor = @broker.ConsumerCursor::replay(1, 0UL, events)
  let stale : @broker.CursorCheckpoint = {
    ack_floor: 1UL,
    scanned: 1UL,
    window: Array::make(@broker.BITMAP_WORDS, 0UL),
  }
  assert_eq(
    @broker.ConsumerCursor::classify_hint(cursor, stale),
    @broker.Lagging,
  )
  // The derived cursor is untouched by the stale cache.
  assert_eq(@broker.ConsumerCursor::ack_floor(cursor), 3UL)
}

///|
test "a checkpoint ahead of the log is leading and the log wins" {
  // The log knows only seq 0; a checkpoint claiming 2 led the durable
  // prefix -- the L4 conflict. The log decides, the hint is discarded.
  let events = [deliver_event(1, 0UL), ack_event(1, 0UL)]
  let cursor = @broker.ConsumerCursor::replay(1, 0UL, events)
  let leading : @broker.CursorCheckpoint = {
    ack_floor: 2UL,
    scanned: 2UL,
    window: Array::make(@broker.BITMAP_WORDS, 0UL),
  }
  assert_eq(
    @broker.ConsumerCursor::classify_hint(cursor, leading),
    @broker.Leading,
  )
  assert_eq(@broker.ConsumerCursor::ack_floor(cursor), 1UL)
}

///|
test "a checkpoint that disagrees about the window is divergent" {
  let events = [ack_event(1, 0UL), ack_event(1, 2UL)]
  let cursor = @broker.ConsumerCursor::replay(1, 0UL, events)
  // Right floor, wrong out-of-order set.
  let diverged : @broker.CursorCheckpoint = {
    ack_floor: 1UL,
    scanned: 2UL,
    window: Array::make(@broker.BITMAP_WORDS, 0UL),
  }
  assert_eq(
    @broker.ConsumerCursor::classify_hint(cursor, diverged),
    @broker.Divergent,
  )
  // The checkpoint the cursor exports itself is adopted.
  assert_eq(
    @broker.ConsumerCursor::classify_hint(
      cursor,
      @broker.ConsumerCursor::checkpoint(cursor),
    ),
    @broker.Adopted,
  )
}

///|
test "an adopted checkpoint round-trips through the codec" {
  let events = [ack_event(1, 0UL), ack_event(1, 2UL), ack_event(1, 3UL)]
  let cursor = @broker.ConsumerCursor::replay(1, 0UL, events)
  let saved = @broker.ConsumerCursor::checkpoint(cursor)
  let decoded = @broker.CursorCheckpoint::decode(
    @broker.CursorCheckpoint::encode(saved)[:],
  )
  match decoded {
    None => fail("expected the checkpoint to decode")
    Some(hint) => {
      assert_eq(hint, saved)
      assert_eq(
        @broker.ConsumerCursor::classify_hint(cursor, hint),
        @broker.Adopted,
      )
    }
  }
}

///|
test "a corrupt checkpoint decodes to nothing" {
  let saved : @broker.CursorCheckpoint = {
    ack_floor: 7UL,
    scanned: 9UL,
    window: Array::make(@broker.BITMAP_WORDS, 0UL),
  }
  let bytes = @broker.CursorCheckpoint::encode(saved)
  assert_eq(@broker.CursorCheckpoint::decode(bytes[:148]), None)

  let buf = Buffer()
  buf.write_byte(0x58)
  buf.write_byte(0x58)
  buf.write_byte(0x58)
  buf.write_byte(0x58)
  for _ in 0..<145 {
    buf.write_byte(0x00)
  }
  assert_eq(@broker.CursorCheckpoint::decode(buf.contents()[:]), None)
  assert_eq(@broker.CursorCheckpoint::decode(b"MMCU"), None)
}

///|
test "the floor never regresses as events fold in" {
  let cursor = @broker.ConsumerCursor::new(1, 0UL)
  let events = [
    deliver_event(1, 0UL),
    ack_event(1, 1UL),
    fenced_event(1, 1UL),
    ack_event(1, 2UL),
    ack_event(1, 0UL),
    nack_terminal_event(1, 3UL),
    ack_event(1, 4UL),
    dlq_written_event(1, 3UL),
    ack_event(1, 5UL),
  ]
  let mut previous = @broker.ConsumerCursor::ack_floor(cursor)
  for event in events {
    @broker.ConsumerCursor::observe(cursor, event)
    let floor = @broker.ConsumerCursor::ack_floor(cursor)
    assert_eq(floor >= previous, true)
    previous = floor
  }
  // Everything through 5 is durably completed (3 via its DLQ record).
  assert_eq(@broker.ConsumerCursor::ack_floor(cursor), 6UL)
}

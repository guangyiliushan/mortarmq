/// Exercise the bounded long-poll wait queue: the five-second timeout that
/// returns instead of hanging, the clamp on longer requests, the wake and
/// cancel paths, and the per-member waiting cap.
///
/// Time moves only through the fake clock: every `now_ms` the queue sees is
/// read from `Clock::now_ms` after `FakeClock::advance_to`, so no test sleeps
/// and the deadline boundary is exact.

///|
async test "a waiting pull completes empty at its five second bound" {
  let clock = @harness.FakeClock::new()
  let queue = @broker.PullQueue::new()
  let ticket = match
    @broker.PullQueue::enqueue(
      queue,
      1UL,
      7,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    ) {
    Ok(ticket) => ticket
    Err(_) => abort("first enqueue must succeed")
  }
  clock.advance_to(4_999UL)
  assert_eq(@broker.PullQueue::due(queue, @harness.Clock::now_ms(clock)), [])
  assert_eq(@broker.PullQueue::pending_count(queue), 1)
  clock.advance_to(5_000UL)
  // Timeout returns the ticket so the request is answered empty; the queue
  // is drained, which is the no-hang half of the contract.
  assert_eq(@broker.PullQueue::due(queue, @harness.Clock::now_ms(clock)), [
    ticket,
  ])
  assert_eq(@broker.PullQueue::pending_count(queue), 0)
}

///|
async test "a longer request is served at the five second bound" {
  let clock = @harness.FakeClock::new()
  let queue = @broker.PullQueue::new()
  let ticket = match
    @broker.PullQueue::enqueue(
      queue,
      1UL,
      7,
      65_535U.to_uint16(),
      @harness.Clock::now_ms(clock),
    ) {
    Ok(ticket) => ticket
    Err(_) => abort("first enqueue must succeed")
  }
  clock.advance_to(4_999UL)
  assert_eq(@broker.PullQueue::due(queue, @harness.Clock::now_ms(clock)), [])
  clock.advance_to(5_000UL)
  assert_eq(@broker.PullQueue::due(queue, @harness.Clock::now_ms(clock)), [
    ticket,
  ])
  assert_eq(@broker.PullQueue::pending_count(queue), 0)
}

///|
async test "an arriving record wakes one waiter and leaves the rest waiting" {
  let clock = @harness.FakeClock::new()
  let queue = @broker.PullQueue::new()
  let first = match
    @broker.PullQueue::enqueue(
      queue,
      1UL,
      7,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    ) {
    Ok(ticket) => ticket
    Err(_) => abort("first enqueue must succeed")
  }
  let second = match
    @broker.PullQueue::enqueue(
      queue,
      1UL,
      7,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    ) {
    Ok(ticket) => ticket
    Err(_) => abort("second enqueue must succeed")
  }
  clock.advance_to(1_000UL)
  assert_eq(@broker.PullQueue::wake_next(queue, 7), Some(first))
  assert_eq(@broker.PullQueue::pending_count(queue), 1)
  // The woken waiter is gone before its deadline, so a later due must not
  // complete it a second time.
  clock.advance_to(2_000UL)
  assert_eq(@broker.PullQueue::due(queue, @harness.Clock::now_ms(clock)), [])
  assert_eq(@broker.PullQueue::wake_next(queue, 7), Some(second))
  assert_eq(@broker.PullQueue::pending_count(queue), 0)
}

///|
async test "wake_next takes no waiter of another subscription" {
  let clock = @harness.FakeClock::new()
  let queue = @broker.PullQueue::new()
  let first = match
    @broker.PullQueue::enqueue(
      queue,
      1UL,
      7,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    ) {
    Ok(ticket) => ticket
    Err(_) => abort("first enqueue must succeed")
  }
  ignore(
    @broker.PullQueue::enqueue(
      queue,
      1UL,
      8,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    ),
  )
  assert_eq(@broker.PullQueue::wake_next(queue, 7), Some(first))
  assert_eq(@broker.PullQueue::pending_count(queue), 1)
  clock.advance_to(5_000UL)
  assert_eq(
    @broker.PullQueue::due(queue, @harness.Clock::now_ms(clock)).length(),
    1,
  )
}

///|
async test "the waiting cap refuses a seventeenth pull with the registered code" {
  let clock = @harness.FakeClock::new()
  let queue = @broker.PullQueue::new()
  for _ in 0..<@broker.MAX_WAITING_PULLS {
    let result = @broker.PullQueue::enqueue(
      queue,
      1UL,
      7,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    )
    assert_eq(result is Ok(_), true)
  }
  assert_eq(
    @broker.PullQueue::enqueue(
      queue,
      1UL,
      7,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    ),
    Err(@protocol.MaxWaitingPulls),
  )
  // The cap is per member and subscription: another pair still enqueues.
  assert_eq(
    @broker.PullQueue::enqueue(
      queue,
      2UL,
      7,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    )
    is Ok(_),
    true,
  )
  assert_eq(
    @broker.PullQueue::enqueue(
      queue,
      1UL,
      8,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    )
    is Ok(_),
    true,
  )
  clock.advance_to(5_000UL)
  assert_eq(
    @broker.PullQueue::due(queue, @harness.Clock::now_ms(clock)).length(),
    18,
  )
  assert_eq(@broker.PullQueue::pending_count(queue), 0)
  assert_eq(
    @broker.PullQueue::enqueue(
      queue,
      1UL,
      7,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    )
    is Ok(_),
    true,
  )
}

///|
async test "cancel on connection close drops only that member's waiters" {
  let clock = @harness.FakeClock::new()
  let queue = @broker.PullQueue::new()
  let first = match
    @broker.PullQueue::enqueue(
      queue,
      1UL,
      7,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    ) {
    Ok(ticket) => ticket
    Err(_) => abort("first enqueue must succeed")
  }
  let second = match
    @broker.PullQueue::enqueue(
      queue,
      1UL,
      7,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    ) {
    Ok(ticket) => ticket
    Err(_) => abort("second enqueue must succeed")
  }
  let other = match
    @broker.PullQueue::enqueue(
      queue,
      2UL,
      7,
      5000U.to_uint16(),
      @harness.Clock::now_ms(clock),
    ) {
    Ok(ticket) => ticket
    Err(_) => abort("third enqueue must succeed")
  }
  assert_eq(@broker.PullQueue::cancel(queue, 1UL, 7), [first, second])
  assert_eq(@broker.PullQueue::pending_count(queue), 1)
  clock.advance_to(5_000UL)
  assert_eq(@broker.PullQueue::due(queue, @harness.Clock::now_ms(clock)), [
    other,
  ])
  assert_eq(@broker.PullQueue::pending_count(queue), 0)
}

///|
async test "a zero wait is already due and returns empty at once" {
  let clock = @harness.FakeClock::new()
  let queue = @broker.PullQueue::new()
  clock.advance_to(1_000UL)
  let ticket = match
    @broker.PullQueue::enqueue(
      queue,
      1UL,
      7,
      0U.to_uint16(),
      @harness.Clock::now_ms(clock),
    ) {
    Ok(ticket) => ticket
    Err(_) => abort("first enqueue must succeed")
  }
  assert_eq(@broker.PullQueue::due(queue, @harness.Clock::now_ms(clock)), [
    ticket,
  ])
  assert_eq(@broker.PullQueue::pending_count(queue), 0)
}

///|
async test "same-seed runs time out identically" {
  let scenario : async (@harness.SimEnv) -> Array[UInt64] = async fn(env) {
    let queue = @broker.PullQueue::new()
    let ticket = match
      @broker.PullQueue::enqueue(
        queue,
        1UL,
        7,
        5000U.to_uint16(),
        @harness.Clock::now_ms(env.clock),
      ) {
      Ok(ticket) => ticket
      Err(_) => abort("first enqueue must succeed")
    }
    env.clock.advance_to(5_000UL)
    let expired = @broker.PullQueue::due(
      queue,
      @harness.Clock::now_ms(env.clock),
    )
    assert_eq(expired, [ticket])
    assert_eq(@broker.PullQueue::pending_count(queue), 0)
    let replay = []
    for id in expired {
      replay.push(id.wait_id)
    }
    replay
  }
  assert_eq(@harness.reproducible(9UL, scenario), true)
}

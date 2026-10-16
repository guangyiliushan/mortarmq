/// Exercise the credit window: the admission gate,
/// the `CREDIT` apply path with its clamps and epoch fencing, the
/// redelivery-pays rule, the fenced ownership-change release
/// and the slow-consumer acceptance case -- inject a
/// consumer that stops returning credit and prove the buffered total
/// never leaves the window.

///|
fn sub_one() -> UInt16 {
  1U.to_uint16()
}

///|
fn mem_epoch() -> UInt {
  7U
}

///|
fn gen_three() -> UInt64 {
  3UL
}

///|
/// A small window: 10 messages / 1000 bytes granted, clamped at 20
/// messages / 2000 bytes, in-flight cap 20.
fn small_window(
  initial_count : Int,
  initial_bytes : Int,
) -> @broker.CreditWindow {
  @broker.CreditWindow::new(
    sub_one(),
    mem_epoch(),
    gen_three(),
    initial_count.to_uint16(),
    initial_bytes.reinterpret_as_uint(),
    20U.to_uint16(),
    2000U,
    20U.to_uint16(),
  )
}

///|
/// A window sized to the default grant, for the buffer-bound assertions.
fn default_window() -> @broker.CreditWindow {
  @broker.CreditWindow::new(
    sub_one(),
    mem_epoch(),
    gen_three(),
    256U.to_uint16(),
    2097152U,
    256U.to_uint16(),
    2097152U,
    256U.to_uint16(),
  )
}

///|
fn admit_one(
  window : @broker.CreditWindow,
  msg_bytes : Int,
) -> Result[Unit, @broker.CreditError] {
  @broker.CreditWindow::admit(
    window,
    0U.to_uint16(),
    5UL,
    gen_three(),
    msg_bytes.reinterpret_as_uint(),
  )
}

///|
fn apply(
  window : @broker.CreditWindow,
  mode : @broker.CreditMode,
  count : Int,
  bytes : Int,
) -> Result[@broker.CreditReport, @broker.CreditError] {
  @broker.CreditWindow::apply(
    window,
    mode,
    count.to_uint16(),
    bytes.reinterpret_as_uint(),
    mem_epoch(),
    gen_three(),
  )
}

///|
/// Whether every buffer counter of one report stays inside the window
/// the client was granted: outstanding inside the cap and the whole
/// granted-plus-outstanding total inside it too.
fn bounded(
  report : @broker.CreditReport,
  cap_count : Int,
  cap_bytes : Int,
) -> Bool {
  report.outstanding_count <= cap_count.to_uint16() &&
  report.outstanding_bytes <= cap_bytes.reinterpret_as_uint() &&
  report.granted_count.to_uint() + report.outstanding_count.to_uint() <=
  cap_count.reinterpret_as_uint() &&
  report.granted_bytes + report.outstanding_bytes <=
  cap_bytes.reinterpret_as_uint()
}

///|
test "a zero initial window admits nothing" {
  let window = small_window(0, 0)
  assert_eq(admit_one(window, 1), Err(@broker.NoCredit))
}

///|
test "a one-message window admits one then stops" {
  let window = small_window(1, 100)
  assert_eq(admit_one(window, 100), Ok(()))
  assert_eq(admit_one(window, 1), Err(@broker.NoCredit))
  assert_eq(
    @broker.CreditWindow::report(window).outstanding_count,
    1U.to_uint16(),
  )
}

///|
test "an ADD of one resumes delivery after the stop" {
  let window = small_window(1, 100)
  assert_eq(admit_one(window, 100), Ok(()))
  assert_eq(admit_one(window, 1), Err(@broker.NoCredit))
  assert_eq(
    apply(window, @broker.Add, 1, 100),
    Ok({
      granted_count: 1U.to_uint16(),
      granted_bytes: 100U,
      outstanding_count: 0U.to_uint16(),
      outstanding_bytes: 0U,
      credit_epoch: 1UL,
    }),
  )
  assert_eq(admit_one(window, 100), Ok(()))
}

///|
test "a SET of zero stops delivery immediately" {
  let window = small_window(5, 500)
  assert_eq(admit_one(window, 10), Ok(()))
  assert_eq(apply(window, @broker.Set, 0, 0) is Ok(_), true)
  assert_eq(admit_one(window, 1), Err(@broker.NoCredit))
  assert_eq(
    @broker.CreditWindow::report(window).outstanding_count,
    1U.to_uint16(),
  )
}

///|
test "a SET beyond the maximum clamps into the room above outstanding" {
  let window = small_window(1, 10)
  assert_eq(admit_one(window, 10), Ok(()))
  // maxima are 20 msgs / 2000 bytes; one message is still outstanding.
  assert_eq(
    apply(window, @broker.Set, 100, 5000),
    Ok({
      granted_count: 19U.to_uint16(),
      granted_bytes: 1990U,
      outstanding_count: 1U.to_uint16(),
      outstanding_bytes: 10U,
      credit_epoch: 1UL,
    }),
  )
  assert_eq(bounded(@broker.CreditWindow::report(window), 20, 2000), true)
}

///|
test "an ADD of bytes clamps to max_credit_bytes" {
  let window = small_window(1, 100)
  assert_eq(apply(window, @broker.Add, 0, 5000) is Ok(_), true)
  assert_eq(@broker.CreditWindow::report(window).granted_bytes, 2000U)
}

///|
test "a zero count with a nonzero bytes grant keeps only the bytes dimension" {
  let window = small_window(0, 0)
  assert_eq(apply(window, @broker.Set, 0, 500) is Ok(_), true)
  let report = @broker.CreditWindow::report(window)
  assert_eq(report.granted_count, 0U.to_uint16())
  assert_eq(report.granted_bytes, 500U)
  assert_eq(admit_one(window, 1), Err(@broker.NoCredit))
}

///|
test "a stale membership epoch refuses without touching credit" {
  let window = small_window(2, 200)
  assert_eq(admit_one(window, 100), Ok(()))
  let before = @broker.CreditWindow::report(window)
  assert_eq(
    @broker.CreditWindow::apply(window, @broker.Set, 9, 9, 8U, gen_three()),
    Err(@broker.StaleGeneration),
  )
  assert_eq(@broker.CreditWindow::report(window), before)
}

///|
test "a stale subscription generation refuses without touching credit" {
  let window = small_window(2, 200)
  let before = @broker.CreditWindow::report(window)
  assert_eq(
    @broker.CreditWindow::admit(window, 0U.to_uint16(), 5UL, 4UL, 10U),
    Err(@broker.StaleGeneration),
  )
  assert_eq(
    @broker.CreditWindow::apply(window, @broker.Add, 1, 1, mem_epoch(), 4UL),
    Err(@broker.StaleGeneration),
  )
  assert_eq(@broker.CreditWindow::report(window), before)
}

///|
test "an unknown subscription reports UnknownSubscription" {
  let registry = @broker.CreditRegistry::new()
  assert_eq(
    @broker.CreditRegistry::report(registry, 99U.to_uint16()),
    Err(@broker.UnknownSubscription),
  )
  assert_eq(
    @broker.CreditRegistry::admit(
      registry,
      99U.to_uint16(),
      0U.to_uint16(),
      5UL,
      3UL,
      1U,
    ),
    Err(@broker.UnknownSubscription),
  )
}

///|
test "credit_epoch climbs monotonically and only on successful mutations" {
  let window = small_window(2, 200)
  assert_eq(@broker.CreditWindow::report(window).credit_epoch, 0UL)
  assert_eq(apply(window, @broker.Add, 1, 1) is Ok(_), true)
  assert_eq(@broker.CreditWindow::report(window).credit_epoch, 1UL)
  assert_eq(
    @broker.CreditWindow::apply(window, @broker.Add, 1, 1, 99U, gen_three())
    is Ok(_),
    false,
  )
  assert_eq(@broker.CreditWindow::report(window).credit_epoch, 1UL)
  assert_eq(apply(window, @broker.Add, 1, 1) is Ok(_), true)
  assert_eq(@broker.CreditWindow::report(window).credit_epoch, 2UL)
}

///|
test "a message equal to the byte budget delivers and one byte more does not" {
  let exact = small_window(1, 100)
  assert_eq(admit_one(exact, 100), Ok(()))
  let over = small_window(1, 100)
  // 101 exceeds the whole capacity: raise credit_bytes is the only fix.
  assert_eq(admit_one(over, 101), Err(@broker.MessageExceedsCredit))
  let patient = small_window(2, 100)
  assert_eq(admit_one(patient, 60), Ok(()))
  // 50 fits the capacity after a return but not the current budget.
  assert_eq(admit_one(patient, 50), Err(@broker.NoCredit))
  assert_eq(apply(patient, @broker.Add, 1, 60) is Ok(_), true)
  assert_eq(admit_one(patient, 50), Ok(()))
}

///|
test "a redelivery attempt consumes credit again" {
  let window = small_window(2, 200)
  assert_eq(admit_one(window, 100), Ok(()))
  assert_eq(admit_one(window, 100), Ok(()))
  assert_eq(admit_one(window, 100), Err(@broker.NoCredit))
  // The client processed exactly one message and returns exactly one.
  assert_eq(apply(window, @broker.Add, 1, 100) is Ok(_), true)
  // The redelivery of an unreturned message pays again: three
  // consumes against one return leave the window at two outstanding.
  assert_eq(admit_one(window, 100), Ok(()))
  let report = @broker.CreditWindow::report(window)
  assert_eq(report.outstanding_count, 2U.to_uint16())
  assert_eq(report.outstanding_bytes, 200U)
  assert_eq(report.granted_count, 0U.to_uint16())
}

///|
test "outstanding folds down through returns and stays put otherwise" {
  let window = small_window(3, 300)
  assert_eq(admit_one(window, 100), Ok(()))
  assert_eq(
    @broker.CreditWindow::report(window).outstanding_count,
    1U.to_uint16(),
  )
  // An ACK is the ledger's business: nothing in this module moves on it.
  // Only the credit return folds outstanding down.
  assert_eq(apply(window, @broker.Add, 1, 100) is Ok(_), true)
  let report = @broker.CreditWindow::report(window)
  assert_eq(report.outstanding_count, 0U.to_uint16())
  assert_eq(report.granted_count, 3U.to_uint16())
}

///|
test "an in-flight cap refusal is Backpressure" {
  let window = @broker.CreditWindow::new(
    sub_one(),
    mem_epoch(),
    gen_three(),
    5U.to_uint16(),
    5000U,
    5U.to_uint16(),
    5000U,
    2U.to_uint16(),
  )
  assert_eq(admit_one(window, 10), Ok(()))
  assert_eq(admit_one(window, 10), Ok(()))
  assert_eq(admit_one(window, 10), Err(@broker.Backpressure))
}

///|
test "the byte budget stops delivery before the message count does" {
  let window = @broker.CreditWindow::new(
    sub_one(),
    mem_epoch(),
    gen_three(),
    256U.to_uint16(),
    65536U,
    256U.to_uint16(),
    65536U,
    256U.to_uint16(),
  )
  for _ in 0..<4 {
    assert_eq(admit_one(window, 16384), Ok(()))
  }
  assert_eq(admit_one(window, 16384), Err(@broker.NoCredit))
  let report = @broker.CreditWindow::report(window)
  assert_eq(report.outstanding_count, 4U.to_uint16())
  assert_eq(report.granted_bytes, 0U)
  assert_eq(report.granted_count, 252U.to_uint16())
}

///|
test "the ownership change port releases only the fenced partition tranche" {
  let registry = @broker.CreditRegistry::new()
  @broker.CreditRegistry::register(registry, small_window(10, 1000))
  assert_eq(
    @broker.CreditRegistry::admit(
      registry,
      sub_one(),
      0U.to_uint16(),
      10UL,
      gen_three(),
      100U,
    ),
    Ok(()),
  )
  assert_eq(
    @broker.CreditRegistry::admit(
      registry,
      sub_one(),
      0U.to_uint16(),
      10UL,
      gen_three(),
      100U,
    ),
    Ok(()),
  )
  assert_eq(
    @broker.CreditRegistry::admit(
      registry,
      sub_one(),
      1U.to_uint16(),
      10UL,
      gen_three(),
      50U,
    ),
    Ok(()),
  )
  // Partial migration of partition 0: epoch 10 -> 11. The release runs
  // at Revoking->Released and frees exactly partition 0's tranche.
  @broker.CreditRegistry::on_ownership_changed(
    registry,
    7U.to_uint16(),
    1U.to_uint16(),
    0U.to_uint16(),
    sub_one(),
    7UL,
    8UL,
    10UL,
    11UL,
  )
  let after = @broker.CreditRegistry::report(registry, sub_one())
  assert_eq(
    after,
    Ok({
      granted_count: 9U.to_uint16(),
      granted_bytes: 950U,
      outstanding_count: 1U.to_uint16(),
      outstanding_bytes: 50U,
      credit_epoch: 1UL,
    }),
  )
  // A replay of the same event releases nothing twice.
  @broker.CreditRegistry::on_ownership_changed(
    registry,
    7U.to_uint16(),
    1U.to_uint16(),
    0U.to_uint16(),
    sub_one(),
    7UL,
    8UL,
    10UL,
    11UL,
  )
  assert_eq(@broker.CreditRegistry::report(registry, sub_one()), after)
  // An epoch the tranche was not booked under releases nothing.
  @broker.CreditRegistry::on_ownership_changed(
    registry,
    7U.to_uint16(),
    1U.to_uint16(),
    1U.to_uint16(),
    sub_one(),
    8UL,
    9UL,
    99UL,
    10UL,
  )
  assert_eq(@broker.CreditRegistry::report(registry, sub_one()), after)
}

///|
test "slow consumer injection keeps the buffered total inside the window" {
  // Default grant: 256 messages / 2 MiB. The consumer may stop
  // returning credit entirely; the buffer must never leave the window.
  let window = default_window()
  let tracker = @broker.CreditReturnTracker::with_window_defaults(
    256U.to_uint16(),
    2097152U,
  )
  // Phase 1 -- frozen consumer: no ACKs, no returns. The pump runs until
  // the window refuses and everything delivered sits in the buffer.
  let mut delivered = 0
  for i in 0..<1000 {
    match admit_one(window, 4096) {
      Ok(_) => delivered = delivered + 1
      Err(err) =>
        if err != @broker.NoCredit {
          fail("unexpected refusal in phase 1: " + i.to_string())
        }
    }
  }
  assert_eq(delivered, 256)
  let frozen = @broker.CreditWindow::report(window)
  assert_eq(frozen.outstanding_count, 256U.to_uint16())
  assert_eq(frozen.outstanding_bytes, 1048576U)
  assert_eq(bounded(frozen, 256, 2097152), true)
  // Phase 2 -- slow consumer: one processed message every 5 ms, so the
  // tracker returns in small batches while the pump keeps pushing. The
  // bound must hold after every step and delivery must make progress.
  let mut now = 0UL
  let mut returned_total = 0U
  for i in 0..<400 {
    now = now + 5UL
    @broker.CreditReturnTracker::record_ack(tracker, now, 4096U)
    let live = @broker.CreditWindow::report(window)
    if @broker.CreditReturnTracker::should_flush(
        tracker,
        now,
        live.granted_count,
        live.granted_bytes,
      ) {
      match @broker.CreditReturnTracker::take(tracker) {
        None => fail("flush with nothing pending")
        Some(returned) => {
          returned_total = returned_total + returned.count.to_uint()
          match
            apply(
              window,
              @broker.Add,
              returned.count.to_uint().reinterpret_as_int(),
              returned.bytes.reinterpret_as_int(),
            ) {
            Ok(_) => ()
            Err(_) => fail("credit return refused")
          }
        }
      }
    }
    match admit_one(window, 4096) {
      Ok(_) => delivered = delivered + 1
      Err(err) =>
        if err != @broker.NoCredit {
          fail("unexpected refusal in phase 2: " + i.to_string())
        }
    }
    assert_eq(bounded(@broker.CreditWindow::report(window), 256, 2097152), true)
  }
  assert_eq(delivered > 256, true)
  let summary = @broker.CreditWindow::report(window)
  assert_eq(
    summary.outstanding_count.to_uint(),
    delivered.reinterpret_as_uint() - returned_total,
  )
  assert_eq(bounded(summary, 256, 2097152), true)
}

///|
fn admit_at(
  window : @broker.CreditWindow,
  partition : UInt16,
  msg_bytes : Int,
) -> Result[Unit, @broker.CreditError] {
  @broker.CreditWindow::admit(
    window,
    partition,
    5UL,
    gen_three(),
    msg_bytes.reinterpret_as_uint(),
  )
}

///|
/// The client returns a whole partition tranche and the partition then
/// migrates: the fold-back must refund nothing twice and must leave the
/// counters at the cap. The unclamped fold drove `outstanding_count`
/// through unsigned wraparound (65516 on a 20-cap window) and re-granted
/// a second copy of budget past the maximum.
test "release after a full return stays inside the cap" {
  let window = small_window(20, 2000)
  for _i in 0..<20 {
    assert_eq(admit_at(window, 7U.to_uint16(), 100), Ok(()))
  }
  assert_eq(
    @broker.CreditWindow::report(window).outstanding_count,
    20U.to_uint16(),
  )
  assert_eq(apply(window, @broker.Add, 20, 2000) is Ok(_), true)
  assert_eq(
    @broker.CreditWindow::release_partition(window, 7U.to_uint16(), 5UL),
    true,
  )
  let after = @broker.CreditWindow::report(window)
  assert_eq(after.outstanding_count, 0U.to_uint16())
  assert_eq(after.outstanding_bytes, 0U)
  assert_eq(after.granted_count, 20U.to_uint16())
  assert_eq(after.granted_bytes, 2000U)
}

///|
/// A partial client return before the migration: the fold-back refunds
/// exactly the still-outstanding share, the returned share stays in the
/// grant, and the window is immediately usable again instead of wedged
/// on wrapped counters.
test "release after a partial return refunds only the outstanding share" {
  let window = small_window(10, 1000)
  for _i in 0..<10 {
    assert_eq(admit_at(window, 9U.to_uint16(), 50), Ok(()))
  }
  assert_eq(apply(window, @broker.Add, 4, 200) is Ok(_), true)
  assert_eq(
    @broker.CreditWindow::report(window).outstanding_count,
    6U.to_uint16(),
  )
  assert_eq(
    @broker.CreditWindow::release_partition(window, 9U.to_uint16(), 5UL),
    true,
  )
  let after = @broker.CreditWindow::report(window)
  assert_eq(after.outstanding_count, 0U.to_uint16())
  assert_eq(after.outstanding_bytes, 0U)
  assert_eq(after.granted_count, 10U.to_uint16())
  assert_eq(after.granted_bytes, 1000U)
  assert_eq(admit_at(window, 9U.to_uint16(), 50), Ok(()))
}

///|
/// Two booked tranches, the client returns only partition 2's share, and
/// partition 2 migrates: the refund is bounded by partition 2's
/// still-outstanding share, so partition 1's booked tranche keeps
/// accounting for itself.
test "a migrating partition refunds only its own outstanding share" {
  let window = small_window(10, 1000)
  for _i in 0..<4 {
    assert_eq(admit_at(window, 1U.to_uint16(), 100), Ok(()))
  }
  for _i in 0..<6 {
    assert_eq(admit_at(window, 2U.to_uint16(), 100), Ok(()))
  }
  assert_eq(apply(window, @broker.Add, 6, 600) is Ok(_), true)
  assert_eq(
    @broker.CreditWindow::release_partition(window, 2U.to_uint16(), 5UL),
    true,
  )
  let after = @broker.CreditWindow::report(window)
  assert_eq(after.outstanding_count, 0U.to_uint16())
  assert_eq(after.outstanding_bytes, 0U)
  assert_eq(after.granted_count, 10U.to_uint16())
  assert_eq(after.granted_bytes, 1000U)
  assert_eq(admit_at(window, 1U.to_uint16(), 100), Ok(()))
}

/// Unit tests for the double-buffered quantile estimator and its
/// opt-in face: the rank convention on a known staircase, the window
/// slide dropping exactly the expired half, phase-preserving merge, and
/// the disabled-by-default hot-path face. These pin the deterministic
/// behavior the property suite then generalizes.

///|
/// The default hot-path face is off and holds no state at all.
test "the default quantile face is disabled and holds no state" {
  let face = @metrics.Quantiles::disabled()
  assert_eq(face.enabled, false)
  assert_eq(face.est is None, true)
  assert_eq(face.query(0.5, 0UL), None)
  // Recording on the disabled face allocates nothing and answers nothing.
  face.record(42UL, 0UL)
  face.record(43UL, 1UL)
  assert_eq(face.query(0.5, 2UL), None)
}

///|
/// Opting in is what turns recording and querying on.
test "opting in enables recording and querying" {
  let face = @metrics.Quantiles::opt_in(1000UL, 0UL)
  assert_eq(face.enabled, true)
  face.record(10UL, 0UL)
  face.record(20UL, 1UL)
  assert_eq(face.query(0.5, 2UL), Some(10UL))
}

///|
/// The rank convention on a staircase: nine zeros and one one pin the
/// nearest rank at every interesting p.
test "query picks the nearest rank on a known staircase" {
  let est = @metrics.Estimator::new(1000UL, 0UL)
  for _ in 0..<9 {
    est.insert(0UL, 0UL)
  }
  est.insert(1UL, 0UL)
  assert_eq(est.query(0.0, 0UL), Some(0UL))
  assert_eq(est.query(0.5, 0UL), Some(0UL))
  assert_eq(est.query(0.9, 0UL), Some(0UL))
  assert_eq(est.query(0.99, 0UL), Some(1UL))
  assert_eq(est.query(1.0, 0UL), Some(1UL))
}

///|
/// A constant stream answers the constant at every quantile.
test "a constant stream converges to the constant" {
  let est = @metrics.Estimator::new(1000UL, 0UL)
  for i in 0..<17 {
    est.insert(7UL, i.to_uint64())
  }
  assert_eq(est.query(0.5, 100UL), Some(7UL))
  assert_eq(est.query(0.9, 100UL), Some(7UL))
  assert_eq(est.query(0.99, 100UL), Some(7UL))
}

///|
/// The window slide drops exactly the expired half: samples live for
/// one full window, and the phase flip resets only the stream that
/// becomes current. The counts at each step pin the double-buffer
/// schedule, so a wrong flip or a wrong reset breaks this test.
test "the window slide drops exactly the expired half" {
  let est = @metrics.Estimator::new(100UL, 0UL)
  est.insert(10UL, 0UL)
  est.insert(20UL, 10UL)
  assert_eq(est.sample_count(), 2)
  // At the step boundary nothing slides: the step rule is "after".
  est.insert(25UL, 50UL)
  assert_eq(est.sample_count(), 3)
  // Strictly after the boundary, one flip: the first phase keeps its
  // samples as the older half and the new current starts empty.
  est.insert(30UL, 51UL)
  assert_eq(est.sample_count(), 4)
  assert_eq(est.query(1.0, 51UL), Some(30UL))
  // The second flip resets the stream that held the first phase: the
  // three early samples die together, exactly one window after birth.
  est.insert(40UL, 101UL)
  assert_eq(est.sample_count(), 2)
  assert_eq(est.query(0.0, 101UL), Some(30UL))
  assert_eq(est.query(1.0, 101UL), Some(40UL))
  // Each later flip drops exactly the phase one window old.
  est.insert(50UL, 151UL)
  assert_eq(est.sample_count(), 2)
  assert_eq(est.query(0.0, 151UL), Some(40UL))
  est.insert(60UL, 201UL)
  assert_eq(est.sample_count(), 2)
  assert_eq(est.query(0.0, 201UL), Some(50UL))
}

///|
/// Merge pairs the stream phases and conserves every sample: their
/// current half joins ours, their older half joins ours, and the counts
/// add up.
test "merge pairs phases and conserves every sample" {
  let mine = @metrics.Estimator::new(1000UL, 0UL)
  mine.insert(1UL, 0UL)
  mine.insert(2UL, 1UL)
  mine.insert(3UL, 2UL)
  let theirs = @metrics.Estimator::new(1000UL, 0UL)
  theirs.insert(8UL, 0UL)
  theirs.insert(9UL, 1UL)
  mine.merge(theirs, 3UL)
  assert_eq(mine.sample_count(), 5)
  assert_eq(mine.query(0.0, 3UL), Some(1UL))
  assert_eq(mine.query(1.0, 3UL), Some(9UL))
  // Their side reads as it stood and is unchanged by the merge.
  assert_eq(theirs.sample_count(), 2)
}

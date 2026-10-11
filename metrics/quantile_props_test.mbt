/// Quantile properties over the double-buffered estimator: ordering of
/// the p50/p90/p99 answers, convergence on a constant stream, and a
/// merged window staying between the two streams it came from while
/// conserving every sample.
///
/// Every property pins its seed so a failure reproduces exactly, and
/// every property has an anti-vacuous companion that feeds a mutated
/// subject into the same predicate and must get a counterexample: a
/// property that cannot fail is not a property. The deterministic unit
/// tests pin the rank convention and the window-flip schedule; these
/// properties generalize the claims over generated windows.
///
/// `MORTARMQ_PROP_DAILY` switches to the daily tier: a run-unique seed
/// from the clock with a larger count, printed so a failure reproduces.
/// Without it the run uses a pinned seed and count, so a plain
/// `moon test` never surprises.
///
/// Vocabulary bridge: a sample is one end-to-end publish-to-ack latency
/// in milliseconds -- the registry's quantile domain is derived at query
/// time from exactly these samples.

///|
/// Whether the property is being run in the daily tier.
fn est_daily() -> Bool {
  match @env.get_env_var("MORTARMQ_PROP_DAILY") {
    Some(_) => true
    None => false
  }
}

///|
/// The seed this run draws from: a run-unique one in the daily tier, a
/// pinned one otherwise.
fn est_seed() -> UInt64 {
  if est_daily() {
    @env.now()
  } else {
    20261035UL
  }
}

///|
/// The sample count for this run.
fn est_count() -> UInt {
  if est_daily() {
    1000U
  } else {
    250U
  }
}

///|
/// The three answers are ordered: the median never exceeds the p90,
/// and the p90 never exceeds the p99.
fn quantiles_ordered(x50 : UInt64, x90 : UInt64, x99 : UInt64) -> Bool {
  x50 <= x90 && x90 <= x99
}

///|
/// Every answer on a constant stream is the constant.
fn quantiles_converge(
  x : UInt64,
  q50 : UInt64?,
  q90 : UInt64?,
  q99 : UInt64?,
) -> Bool {
  q50 == Some(x) && q90 == Some(x) && q99 == Some(x)
}

///|
/// A merged answer lies between the two streams' answers at the same
/// quantile.
fn merge_bounded(merged : UInt64, left : UInt64, right : UInt64) -> Bool {
  let lo = if left < right { left } else { right }
  let hi = if left > right { left } else { right }
  merged >= lo && merged <= hi
}

///|
/// A merge conserves every sample: the folded window holds exactly the
/// samples both windows held.
fn merge_conserved(
  merged_count : Int,
  left_count : Int,
  right_count : Int,
) -> Bool {
  merged_count == left_count + right_count
}

///|
/// Build one estimator over a generated sample set, all samples inside
/// one window so nothing expires mid-check.
fn est_filled(draw : UInt, n : Int, window_ms : UInt64) -> @metrics.Estimator {
  let est = @metrics.Estimator::new(window_ms, 0UL)
  let step = window_ms / 2UL
  let mut bits = draw
  for i in 0..<n {
    let value = (bits % 64U).to_uint64()
    bits = bits >> 3
    // Spread the samples across both half-windows: a generator that
    // fills only one phase leaves the phase pairing untested, and a
    // merge that drops the other phase would pass quietly.
    let phase_time = if i % 2 == 0 {
      i.to_uint64()
    } else {
      step + 1UL + i.to_uint64()
    }
    est.insert(value, phase_time)
  }
  est
}

///|
test "property: the three quantile answers are ordered in any window (pin seed=20261035; daily mode logs the run seed)" {
  let seed = est_seed()
  let count = est_count()
  if est_daily() {
    println("quantile-ordering-daily seed=\{seed} count=\{count}")
  }
  @quickcheck.check(
    (draw : UInt) => {
      let n = (draw % 33U).reinterpret_as_int() + 1
      let est = est_filled(draw, n, 100000UL)
      // The query lands before any phase-0 sample expires (a sample
      // lives one full window).
      let now = 100000UL
      match (est.query(0.5, now), est.query(0.9, now), est.query(0.99, now)) {
        (Some(x50), Some(x90), Some(x99)) => quantiles_ordered(x50, x90, x99)
        _ => false
      }
    },
    count~,
    max_shrinks=20,
    seed~,
  )
}

///|
test "property: a constant stream converges at every quantile (pin seed=20261036; daily mode logs the run seed)" {
  let seed = est_seed() + 1UL
  let count = est_count()
  if est_daily() {
    println("quantile-convergence-daily seed=\{seed} count=\{count}")
  }
  @quickcheck.check(
    (draw : UInt) => {
      let x = (draw % 1024U).to_uint64()
      let n = (draw % 33U).reinterpret_as_int() + 1
      let est = @metrics.Estimator::new(100000UL, 0UL)
      for i in 0..<n {
        est.insert(x, i.to_uint64())
      }
      let now = n.to_uint64() + 1UL
      quantiles_converge(
        x,
        est.query(0.5, now),
        est.query(0.9, now),
        est.query(0.99, now),
      )
    },
    count~,
    max_shrinks=20,
    seed~,
  )
}

///|
test "property: a merged window stays between its two streams and keeps every sample (pin seed=20261037; daily mode logs the run seed)" {
  let seed = est_seed() + 2UL
  let count = est_count()
  if est_daily() {
    println("quantile-merge-daily seed=\{seed} count=\{count}")
  }
  @quickcheck.check(
    (draw : UInt) => {
      let n_left = (draw % 17U).reinterpret_as_int() + 1
      let n_right = ((draw >> 5) % 17U).reinterpret_as_int() + 1
      let left = est_filled(draw, n_left, 100000UL)
      let right = est_filled(draw >> 9, n_right, 100000UL)
      let now = 100000UL
      // The two streams' own answers at each quantile, measured before
      // the merge folds them together.
      let mut ok = true
      let bounds : Array[(UInt64, UInt64)] = []
      for p in [0.5, 0.9, 0.99] {
        match (left.query(p, now), right.query(p, now)) {
          (Some(l), Some(r)) => bounds.push((l, r))
          _ => ok = false
        }
      }
      if !ok {
        return false
      }
      let left_count = left.sample_count()
      let right_count = right.sample_count()
      left.merge(right, now)
      if !merge_conserved(left.sample_count(), left_count, right_count) {
        return false
      }
      let mut index = 0
      for p in [0.5, 0.9, 0.99] {
        let (l, r) = bounds[index]
        index = index + 1
        match left.query(p, now) {
          Some(merged) => if !merge_bounded(merged, l, r) { return false }
          None => return false
        }
      }
      true
    },
    count~,
    max_shrinks=20,
    seed~,
  )
}

///|
/// Anti-vacuous companion: reversed answers must fail the ordering
/// check the property above rests on.
test "reversed quantiles are rejected by the ordering check" {
  assert_eq(quantiles_ordered(0UL, 5UL, 9UL), true)
  assert_eq(quantiles_ordered(9UL, 5UL, 0UL), false)
  assert_eq(quantiles_ordered(0UL, 9UL, 5UL), false)
}

///|
/// Anti-vacuous companion: an answer off the constant must fail the
/// convergence check, including a missing answer.
test "an estimate off the constant is rejected by the convergence check" {
  assert_eq(quantiles_converge(7UL, Some(7UL), Some(7UL), Some(7UL)), true)
  assert_eq(quantiles_converge(7UL, Some(7UL), Some(7UL), Some(8UL)), false)
  assert_eq(quantiles_converge(7UL, Some(7UL), None, Some(7UL)), false)
}

///|
/// Anti-vacuous companion: a merged answer outside the two streams must
/// fail the boundedness check.
test "a merged quantile outside the two streams is rejected by the boundedness check" {
  assert_eq(merge_bounded(50UL, 0UL, 100UL), true)
  assert_eq(merge_bounded(150UL, 0UL, 100UL), false)
  assert_eq(merge_bounded(0UL, 100UL, 100UL), false)
}

///|
/// Anti-vacuous companion: a merge that drops a sample must fail the
/// conservation check -- a bounded answer is not enough.
test "a merge that drops samples is rejected by the conservation check" {
  assert_eq(merge_conserved(4, 2, 2), true)
  assert_eq(merge_conserved(3, 2, 2), false)
}

///|
/// The shrink budget is a hard cap, not a hope: a failure must shrink
/// within the pinned limit the properties carry. The driver's report is
/// abstract, so the budget is pinned as the debug snapshot of one
/// expected failure -- a driver that ignored the limit would move this
/// snapshot and the gate would red.
test "a failing property shrinks within the pinned budget" {
  let report = @quickcheck.report(
    (draw : UInt) => draw == 0U,
    count=20,
    max_size=20,
    max_shrinks=20,
    seed=20261040,
  )
  debug_inspect(
    report,
    content=(
      #|Falsified(
      #|  counterexample=65,
      #|  tests=1,
      #|  size=0,
      #|  shrinks=20,
      #|  shrink_attempts=20,
      #|)
    ),
  )
}

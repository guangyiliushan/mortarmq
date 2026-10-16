///|
/// Daily-tier timer property: a cancelled timer never fires, even under a
/// heavy sweep. This is the daily-tier counterpart of the pinned cancel
/// property in `timers_props_test.mbt`: with `MORTARMQ_PROP_DAILY` set
/// the sweep runs registry daily mode -- run-unique seed from the clock,
/// count=1000, max_size=256 -- and logs the seed so a failure
/// reproduces. Without the flag it runs the committed pin so plain
/// `moon test` stays reproducible. The `daily_*` helper names are
/// deliberate: blackbox test files share one package namespace and the
/// pin file owns the `cl_*` names.

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
    20261017UL
  }
}

///|
fn daily_count() -> UInt32 {
  if daily_mode() {
    1000U
  } else {
    200U
  }
}

///|
fn daily_max_size() -> UInt32 {
  if daily_mode() {
    256U
  } else {
    100U
  }
}

///|
fn daily_schedule(draw : UInt32) -> (Array[UInt64], Array[UInt64], Array[Bool]) {
  let ticks : Array[UInt64] = []
  let sequences : Array[UInt64] = []
  let cancelled : Array[Bool] = []
  let n = (draw % 7U).reinterpret_as_int() + 2
  let mut bits = draw >> 3
  for index in 0..<n {
    let tick = (bits % 64U).to_uint64()
    bits = bits >> 6
    let do_cancel = bits % 2U == 1U
    bits = bits >> 1
    ticks.push(tick)
    sequences.push((index + 1).to_uint64())
    cancelled.push(do_cancel)
  }
  (ticks, sequences, cancelled)
}

///|
/// Daily sweep: cancelled timers stay silent at scale.
test "daily sweep: a cancelled timer never fires (pin seed=20261017; daily mode logs the run seed)" {
  @quickcheck.check(
    (draw : UInt32) => {
      let (ticks, sequences, cancelled) = daily_schedule(draw)
      let timers = @delivery.RetryTimers::new()
      let mut index = 0
      while index < sequences.length() {
        timers.schedule(
          ticks[index],
          @delivery.DeliveryKey::new(
            group_id=1,
            topic_id=1,
            partition=0,
            sequence=sequences[index],
          ),
        )
        index = index + 1
      }
      index = 0
      while index < sequences.length() {
        if cancelled[index] {
          ignore(
            timers.cancel(
              @delivery.DeliveryKey::new(
                group_id=1,
                topic_id=1,
                partition=0,
                sequence=sequences[index],
              ),
            ),
          )
        }
        index = index + 1
      }
      let popped = timers.due(63UL)
      let mut ok = popped.length() <= sequences.length()
      index = 0
      while index < popped.length() {
        let sequence = popped[index].sequence.to_int()
        if cancelled[sequence - 1] {
          ok = false
        }
        index = index + 1
      }
      ok
    },
    count=daily_count(),
    max_shrinks=20,
    seed=daily_seed(),
    max_size=daily_max_size(),
  )
}

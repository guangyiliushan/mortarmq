/// The double-buffered quantile estimator: targeted quantiles over a
/// sliding time window in the NSQ quantile shape -- two half-window
/// streams, a phase flip that resets the stream becoming current, and a
/// phase-preserving cross-instance merge. The v0 streams hold their
/// samples sorted-exact within the window, so the estimate is exact
/// there; a bounded sketch is a later concern, not a v0 promise.
///
/// Vocabulary bridge: one inserted value is one end-to-end publish-to-ack
/// latency sample in milliseconds. The registry's quantile domain
/// (`p50`/`p90`/`p99`) is derived at query time from these samples and
/// holds no metric of its own.
///
/// Three operations form the contract the metric face calls: `insert`,
/// `query(p)` and `merge`. Time enters through `now_ms`, carried by the
/// caller's clock, so the window slide is deterministic under test.
///
/// Opt-in: `Quantiles` is the hot-path face and is disabled by default --
/// one flag check per sample and no allocation until a caller opts in.

///|
/// A sliding-window quantile estimator: two streams, one current.
pub(all) struct Estimator {
  streams : Array[Array[UInt64]]
  mut current_index : Int
  mut last_move_ms : UInt64
  move_window_ms : UInt64
}

///|
/// Start an estimator whose samples live for `window_ms` milliseconds.
/// The window slides in half-window steps, so `window_ms` must be at
/// least 2; smaller values are refused by clamping the step to 1ms.
pub fn Estimator::new(window_ms : UInt64, now_ms : UInt64) -> Estimator {
  let half = window_ms / 2UL
  let step = if half == 0UL { 1UL } else { half }
  {
    streams: [[], []],
    current_index: 0,
    last_move_ms: now_ms,
    move_window_ms: step,
  }
}

///|
/// Flip to the other stream and reset it: the stream that was current
/// keeps its samples as the window's older half, and the freshly current
/// stream starts empty. The move advances the clock in fixed steps.
fn Estimator::move_window(self : Estimator) -> Unit {
  self.current_index = 1 - self.current_index
  self.last_move_ms = self.last_move_ms + self.move_window_ms
  self.streams[self.current_index] = []
}

///|
/// Slide the window for everything strictly past its step boundary --
/// the reference slides while "now" is after the step, not at it.
fn Estimator::slide(self : Estimator, now_ms : UInt64) -> Unit {
  while now_ms > self.last_move_ms + self.move_window_ms {
    self.move_window()
  }
}

///|
/// Insert one latency sample at `now_ms`.
pub fn Estimator::insert(
  self : Estimator,
  value : UInt64,
  now_ms : UInt64,
) -> Unit {
  self.slide(now_ms)
  self.streams[self.current_index].push(value)
}

///|
/// Sort a copy of the merged samples ascending (insertion sort; the
/// window's sample count is small and the copy keeps the streams
/// untouched).
fn sorted_samples(streams : Array[Array[UInt64]]) -> Array[UInt64] {
  let out : Array[UInt64] = []
  for stream in streams {
    for value in stream {
      out.push(value)
    }
  }
  for i in 1..<out.length() {
    let mut j = i
    while j > 0 && out[j - 1] > out[j] {
      let tmp = out[j - 1]
      out[j - 1] = out[j]
      out[j] = tmp
      j = j - 1
    }
  }
  out
}

///|
/// The nearest-rank of quantile `p` in `n` sorted samples: the element
/// at one-based rank `ceil(p * n)`, with `p` clamped to [0, 1].
fn nearest_rank(p : Double, n : Int) -> Int {
  let clamped = if p < 0.0 { 0.0 } else if p > 1.0 { 1.0 } else { p }
  let raw = clamped * n.to_double()
  let mut rank = raw.to_int()
  if rank.to_double() < raw {
    rank = rank + 1
  }
  if rank < 1 {
    rank = 1
  }
  if rank > n {
    rank = n
  }
  rank
}

///|
/// Quantile `p` over everything still inside the window: the merged
/// stream's nearest rank. `None` when the window holds no samples.
pub fn Estimator::query(
  self : Estimator,
  p : Double,
  now_ms : UInt64,
) -> UInt64? {
  self.slide(now_ms)
  let merged = sorted_samples(self.streams)
  let n = merged.length()
  if n == 0 {
    return None
  }
  Some(merged[nearest_rank(p, n) - 1])
}

///|
/// Fold `other` into this estimator, pairing the two stream phases the
/// way the reference does: their current half joins ours, their older
/// half joins ours, and the newer window clock wins. `other` is read as
/// it stands -- merging does not slide it.
pub fn Estimator::merge(
  self : Estimator,
  other : Estimator,
  now_ms : UInt64,
) -> Unit {
  self.slide(now_ms)
  let them_current = other.streams[other.current_index]
  let them_older = other.streams[1 - other.current_index]
  for value in them_current {
    self.streams[self.current_index].push(value)
  }
  for value in them_older {
    self.streams[1 - self.current_index].push(value)
  }
  if other.last_move_ms > self.last_move_ms {
    self.last_move_ms = other.last_move_ms
  }
}

///|
/// How many samples the window holds right now.
pub fn Estimator::sample_count(self : Estimator) -> Int {
  self.streams[0].length() + self.streams[1].length()
}

///|
/// The hot-path quantile face, opt-in: a disabled face is one flag check
/// per sample and no state at all, so the common path pays nothing for
/// quantiles it never asked for.
pub(all) struct Quantiles {
  enabled : Bool
  est : Estimator?
}

///|
/// The default face: quantiles off, no state.
pub fn Quantiles::disabled() -> Quantiles {
  { enabled: false, est: None, }
}

///|
/// The opted-in face: samples live for `window_ms` milliseconds.
pub fn Quantiles::opt_in(window_ms : UInt64, now_ms : UInt64) -> Quantiles {
  { enabled: true, est: Some(Estimator::new(window_ms, now_ms)), }
}

///|
/// Record one sample. Disabled faces drop it on the flag check.
pub fn Quantiles::record(
  self : Quantiles,
  value : UInt64,
  now_ms : UInt64,
) -> Unit {
  match self.est {
    None => ()
    Some(est) => est.insert(value, now_ms)
  }
}

///|
/// Quantile `p` of the recorded window; `None` while disabled or empty.
pub fn Quantiles::query(
  self : Quantiles,
  p : Double,
  now_ms : UInt64,
) -> UInt64? {
  match self.est {
    None => None
    Some(est) => est.query(p, now_ms)
  }
}

///|
/// Fold another face into this one; a disabled side contributes nothing.
pub fn Quantiles::merge(
  self : Quantiles,
  other : Quantiles,
  now_ms : UInt64,
) -> Unit {
  match (self.est, other.est) {
    (Some(mine), Some(theirs)) => mine.merge(theirs, now_ms)
    _ => ()
  }
}

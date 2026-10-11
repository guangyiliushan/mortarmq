/// QuickCheck properties for the timer contract (CL1 never early, CL2
/// never missed, CL3 rollback-proof ordering). The generator keeps its
/// own (tick, key) ledger -- independent of the heap the properties
/// drive -- so a wrong pop, a dropped pop, or a reordered pop cannot
/// hide behind the queue's own bookkeeping. Each property pins its seed.

///|
/// Draw a schedule of 2..8 timers with ticks from the low bits and
/// distinct sequence keys, returning the independent ledger as two
/// parallel arrays (tick, then sequence).
fn cl_schedule(draw : UInt) -> (Array[UInt64], Array[UInt64]) {
  let ticks : Array[UInt64] = []
  let sequences : Array[UInt64] = []
  let n = (draw % 7U).reinterpret_as_int() + 2
  let mut bits = draw >> 3
  for index in 0..<n {
    let tick = (bits % 64U).to_uint64()
    bits = bits >> 6
    ticks.push(tick)
    sequences.push((index + 1).to_uint64())
  }
  (ticks, sequences)
}

///|
/// Schedule every ledger entry into a fresh queue.
fn cl_fill(
  ticks : Array[UInt64],
  sequences : Array[UInt64],
) -> @delivery.RetryTimers {
  let timers = @delivery.RetryTimers::new()
  let mut index = 0
  while index < ticks.length() {
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
  timers
}

///|
/// The keys the ledger says are due at or before a tick, in the frozen
/// composite order (tick first, then sequence -- all other key fields
/// are constant here).
fn cl_expected(
  ticks : Array[UInt64],
  sequences : Array[UInt64],
  now : UInt64,
) -> Array[UInt64] {
  let due_seq : Array[UInt64] = []
  let due_tick : Array[UInt64] = []
  let mut index = 0
  while index < ticks.length() {
    if ticks[index] <= now {
      due_tick.push(ticks[index])
      due_seq.push(sequences[index])
    }
    index = index + 1
  }
  // Selection sort by (tick, sequence) -- the frozen composite order.
  let mut i = 0
  while i < due_seq.length() {
    let mut best = i
    let mut j = i + 1
    while j < due_seq.length() {
      if due_tick[j] < due_tick[best] ||
        (due_tick[j] == due_tick[best] && due_seq[j] < due_seq[best]) {
        best = j
      }
      j = j + 1
    }
    if best != i {
      let t = due_tick[i]
      due_tick[i] = due_tick[best]
      due_tick[best] = t
      let s = due_seq[i]
      due_seq[i] = due_seq[best]
      due_seq[best] = s
    }
    i = i + 1
  }
  due_seq
}

///|
fn cl_same(a : Array[UInt64], b : Array[UInt64]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  let mut index = 0
  while index < a.length() {
    if a[index] != b[index] {
      return false
    }
    index = index + 1
  }
  true
}

///|
test "CL1 a timer never fires before its deadline (quickcheck seed=20261014 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let (ticks, sequences) = cl_schedule(draw)
      let timers = cl_fill(ticks, sequences)
      let now = (draw % 96U).to_uint64()
      let popped = timers.due(now)
      let expected = cl_expected(ticks, sequences, now)
      // Everything that fired was due: the popped set is a subset of the
      // expected set (nothing early), sizes included for the strict
      // reading when the sets match exactly.
      let mut ok = popped.length() <= expected.length()
      let mut index = 0
      while index < popped.length() {
        if index >= expected.length() ||
          popped[index].sequence != expected[index] {
          ok = false
        }
        index = index + 1
      }
      ok
    },
    count=200,
    seed=20261014,
  )
}

///|
test "CL2 a timer fires once its deadline passes (quickcheck seed=20261015 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let (ticks, sequences) = cl_schedule(draw)
      let timers = cl_fill(ticks, sequences)
      let now = (draw % 96U).to_uint64()
      let popped = timers.due(now)
      let expected = cl_expected(ticks, sequences, now)
      // Nothing due is left behind: the popped set contains the whole
      // expected set.
      cl_same(popped.map(key => key.sequence), expected) &&
      timers.pending_count() == ticks.length() - expected.length()
    },
    count=200,
    seed=20261015,
  )
}

///|
test "CL3 a rolled-back query tick changes neither what fires nor its order (quickcheck seed=20261016 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let (ticks, sequences) = cl_schedule(draw)
      let timers = cl_fill(ticks, sequences)
      let high = 64UL
      let rolled_back = (draw % 64U).to_uint64()
      // Query out of order: a large tick first, then a smaller one, then
      // the large one again. The rollback tick must fire nothing new and
      // the concatenated pops must equal the single-pass order at the
      // high tick.
      let first = timers.due(high)
      let second = timers.due(rolled_back)
      let third = timers.due(high)
      let mut ok = second.length() == 0 && third.length() == 0
      let expected = cl_expected(ticks, sequences, high)
      if !cl_same(first.map(key => key.sequence), expected) {
        ok = false
      }
      ok
    },
    count=200,
    seed=20261016,
  )
}

/// The frozen v0 retry timer queue.
///
/// One min-heap keyed by the composite
/// `(due_tick_ms, topic, partition, group, sequence)`: the due tick orders
/// the schedule and the remaining fields break ties deterministically, so
/// same-tick pops replay identically (deterministic for replay). Timers live in memory
/// only; the ledger is the truth source and `DeliveryMachine::rebuild_timers`
/// reconstructs the queue after a restart. Per-key heaps are a benchmark
/// comparison point, not the default.

///|
priv struct TimerEntry {
  due_tick_ms : UInt64
  topic_id : UInt16
  partition : UInt16
  group_id : UInt16
  sequence : UInt64
}

///|
/// The frozen composite order: due tick first, then topic, partition,
/// group, sequence.
fn timer_entry_before(a : TimerEntry, b : TimerEntry) -> Bool {
  if a.due_tick_ms != b.due_tick_ms {
    return a.due_tick_ms < b.due_tick_ms
  }
  if a.topic_id != b.topic_id {
    return a.topic_id < b.topic_id
  }
  if a.partition != b.partition {
    return a.partition < b.partition
  }
  if a.group_id != b.group_id {
    return a.group_id < b.group_id
  }
  a.sequence < b.sequence
}

///|
/// The in-memory retry timer queue.
pub(all) struct RetryTimers {
  priv heap : Array[TimerEntry]
}

///|
pub fn RetryTimers::new() -> RetryTimers {
  { heap: [], }
}

///|
pub fn RetryTimers::pending_count(self : RetryTimers) -> Int {
  self.heap.length()
}

///|
fn sift_up(heap : Array[TimerEntry], index : Int) -> Unit {
  let mut current = index
  while current > 0 {
    let parent = (current - 1) / 2
    if timer_entry_before(heap[current], heap[parent]) {
      let tmp = heap[current]
      heap[current] = heap[parent]
      heap[parent] = tmp
      current = parent
    } else {
      break
    }
  }
}

///|
fn sift_down(heap : Array[TimerEntry], index : Int) -> Unit {
  let mut current = index
  let mut settled = false
  while !settled {
    let left = current * 2 + 1
    let right = current * 2 + 2
    let mut best = current
    if left < heap.length() && timer_entry_before(heap[left], heap[best]) {
      best = left
    }
    if right < heap.length() && timer_entry_before(heap[right], heap[best]) {
      best = right
    }
    if best == current {
      settled = true
    } else {
      let tmp = heap[current]
      heap[current] = heap[best]
      heap[best] = tmp
      current = best
    }
  }
}

///|
/// Schedule one retry for `key` at `due_tick_ms`. Duplicate schedules for
/// the same key are the caller's concern; the queue only orders.
pub fn RetryTimers::schedule(
  self : RetryTimers,
  due_tick_ms : UInt64,
  key : DeliveryKey,
) -> Unit {
  let entry = {
    due_tick_ms,
    topic_id: key.topic_id,
    partition: key.partition,
    group_id: key.group_id,
    sequence: key.sequence,
  }
  self.heap.push(entry)
  sift_up(self.heap, self.heap.length() - 1)
}

///|
/// Report the earliest scheduled tick, or `None` when the queue is empty.
/// The executor uses it to arm its next wakeup.
pub fn RetryTimers::next_due_tick(self : RetryTimers) -> UInt64? {
  if self.heap.length() == 0 {
    return None
  }
  Some(self.heap[0].due_tick_ms)
}

///|
/// Pop every matured timer (`due_tick_ms <= now_tick_ms`) in composite
/// order. The executor must re-check the entry's current state before it
/// redelivers (design: "触发时必须重新检查当前状态").
pub fn RetryTimers::due(
  self : RetryTimers,
  now_tick_ms : UInt64,
) -> Array[DeliveryKey] {
  let matured : Array[DeliveryKey] = []
  while self.heap.length() > 0 && self.heap[0].due_tick_ms <= now_tick_ms {
    let head = self.heap[0]
    let last = self.heap.length() - 1
    self.heap[0] = self.heap[last]
    let _dropped = self.heap.pop()
    if self.heap.length() > 0 {
      sift_down(self.heap, 0)
    }
    matured.push(
      DeliveryKey::new(
        group_id=head.group_id,
        topic_id=head.topic_id,
        partition=head.partition,
        sequence=head.sequence,
      ),
    )
  }
  matured
}

/// Provide deterministic fake implementations for the side-effect seams.
///
/// Virtual time advances only through explicit `advance_to`; network queues are
/// FIFO and partition failures leave no deliverable bytes; disk operations model
/// explicit capability limits and injected full-disk and kill-point failures;
/// the RNG is the deterministic SplitMix64 stream.

///|
priv struct TimerEvent {
  deadline_ms : UInt64
  sequence : UInt64
} derive(Debug)

///|
priv struct ClockState {
  mut now_ms : UInt64
  timers : Array[TimerEvent]
  fired : Array[UInt64]
  mut next_sequence : UInt64
} derive(Debug)

///|
/// Own monotonic virtual time and expose deterministic timer observations.
pub(all) struct FakeClock {
  priv state : Ref[ClockState]
} derive(Debug)

///|
pub extend FakeClock with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend FakeClock with Clock::{now_ms, sleep_until}

///|
pub fn FakeClock::new() -> FakeClock {
  {
    state: Ref::Ref({ now_ms: 0UL, timers: [], fired: [], next_sequence: 0UL, }),
  }
}

///|
/// Advance monotonic time to `target_ms`; backward requests are ignored.
///
/// Mature timers fire by deadline, then registration sequence.
pub fn FakeClock::advance_to(self : FakeClock, target_ms : UInt64) -> Unit {
  if target_ms > self.state.val.now_ms {
    self.state.val.now_ms = target_ms
  }
  for ;; {
    let mut best_index : Int? = None
    for index in 0..<self.state.val.timers.length() {
      let timer = self.state.val.timers[index]
      if timer.deadline_ms > self.state.val.now_ms {
        continue
      }
      match best_index {
        None => best_index = Some(index)
        Some(current) => {
          let current_timer = self.state.val.timers[current]
          if timer.deadline_ms < current_timer.deadline_ms ||
            (
              timer.deadline_ms == current_timer.deadline_ms &&
              timer.sequence < current_timer.sequence
            ) {
            best_index = Some(index)
          }
        }
      }
    }
    match best_index {
      Some(index) => {
        let timer = self.state.val.timers[index]
        self.state.val.fired.push(timer.deadline_ms)
        ignore(self.state.val.timers.remove(index))
      }
      None => return
    }
  }
}

///|
/// Copy completed deadline ids without exposing mutable timer state.
pub fn FakeClock::fired_deadlines(self : FakeClock) -> Array[UInt64] {
  let copy = []
  for deadline in self.state.val.fired {
    copy.push(deadline)
  }
  copy
}

///|
/// Count registered timers that have not yet matured.
pub fn FakeClock::pending_count(self : FakeClock) -> Int {
  self.state.val.timers.length()
}

///|
pub impl Clock for FakeClock with fn now_ms(self) -> UInt64 {
  self.state.val.now_ms
}

///|
pub impl Clock for FakeClock with fn sleep_until(self, deadline_ms : UInt64) -> Bool {
  if deadline_ms <= self.state.val.now_ms {
    self.state.val.fired.push(deadline_ms)
    return true
  }
  self.state.val.timers.push({
    deadline_ms,
    sequence: self.state.val.next_sequence,
  })
  self.state.val.next_sequence = self.state.val.next_sequence + 1UL
  false
}

///|
priv struct NetState {
  sent : Array[(UInt16, Bytes)]
  queue : Array[(UInt16, Bytes)]
  partitioned : Array[UInt16]
} derive(Debug)

///|
/// Own an in-memory message queue with explicit partition failures.
pub(all) struct FakeNet {
  priv state : Ref[NetState]
} derive(Debug)

///|
pub extend FakeNet with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend FakeNet with Net::{send, receive}

///|
pub fn FakeNet::new() -> FakeNet {
  { state: Ref::Ref({ sent: [], queue: [], partitioned: [], }), }
}

///|
/// Add a peer to the partition set; later sends observe `PeerPartitioned`.
pub fn FakeNet::partition(self : FakeNet, peer : UInt16) -> Unit {
  self.state.val.partitioned.push(peer)
}

///|
/// Copy sent messages in producer submission order.
pub fn FakeNet::sent_messages(self : FakeNet) -> Array[(UInt16, Bytes)] {
  let copy = []
  for index in 0..<self.state.val.sent.length() {
    copy.push(self.state.val.sent[index])
  }
  copy
}

///|
pub impl Net for FakeNet with fn send(self, peer : UInt16, data : Bytes) -> Result[
  Unit,
  HarnessFault,
] {
  for partitioned in self.state.val.partitioned {
    if partitioned.to_uint() == peer.to_uint() {
      return Err(PeerPartitioned)
    }
  }
  self.state.val.sent.push((peer, data))
  self.state.val.queue.push((peer, data))
  Ok(())
}

///|
/// Remove and return the oldest bytes queued for `peer`.
pub impl Net for FakeNet with fn receive(self, peer : UInt16) -> Bytes? {
  for index in 0..<self.state.val.queue.length() {
    let (queued_peer, data) = self.state.val.queue[index]
    if queued_peer.to_uint() == peer.to_uint() {
      ignore(self.state.val.queue.remove(index))
      return Some(data)
    }
  }
  None
}

///|
priv struct DiskState {
  files : Map[Bytes, Bytes]
  mut disk_full : Bool
  mut kill_at_op : Int
  mut op_count : Int
} derive(Debug)

///|
/// Own in-memory durable files and deterministic storage faults.
pub(all) struct FakeDisk {
  priv state : Ref[DiskState]
} derive(Debug)

///|
pub extend FakeDisk with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend FakeDisk with Disk::{write, read, fsync, rename, capabilities}

///|
pub fn FakeDisk::new() -> FakeDisk {
  {
    state: Ref::Ref({
      files: Map([]),
      disk_full: false,
      kill_at_op: 0,
      op_count: 0,
    }),
  }
}

///|
/// Arm a kill point so the armed and every later mutating operation fails.
///
/// `op_number` counts write, fsync, and rename operations from disk creation;
/// read is excluded so a recovery observer can inspect the surviving state.
/// A fired kill reports `Killed`, dominates `set_disk_full`, and leaves the
/// armed operation with no new state, which stands in for process death.
/// `op_number <= 0` disarms.
///
/// The counter is global across every file the fake serves and every writer,
/// so arms are absolute indices: adding one mutating operation to any writer
/// renumbers every later arm. Tests that pin a specific index break loudly in
/// that case; tests that arm every index in a sweep adapt on their own, which
/// is the preferred shape for writer-invariant validation.
///
/// Example:
///
/// ```mbt check
/// async test {
///   let disk = @harness.FakeDisk::new()
///   disk.set_kill_at(1)
///   assert_eq(@harness.Disk::write(disk, b"a", b"1"), Err(@harness.Killed))
///   assert_eq(@harness.Disk::read(disk, b"a"), Err(@harness.PathMissing))
/// }
/// ```
pub fn FakeDisk::set_kill_at(self : FakeDisk, op_number : Int) -> Unit {
  self.state.val.kill_at_op = op_number
}

///|
/// Enable or disable write and fsync failure injection.
pub fn FakeDisk::set_disk_full(self : FakeDisk, full : Bool) -> Unit {
  self.state.val.disk_full = full
}

///|
/// Copy stored file contents without exposing the mutable map.
pub fn FakeDisk::snapshot(self : FakeDisk) -> Array[(Bytes, Bytes)] {
  let entries = []
  for path, data in self.state.val.files {
    entries.push((path, data))
  }
  entries
}

///|
/// Count one mutating operation and fail it when the armed kill point fired.
fn count_op_and_check_kill(state : DiskState) -> Bool {
  state.op_count = state.op_count + 1
  state.kill_at_op > 0 && state.op_count >= state.kill_at_op
}

///|
pub impl Disk for FakeDisk with fn write(self, path : Bytes, data : Bytes) -> Result[
  Unit,
  HarnessFault,
] {
  if count_op_and_check_kill(self.state.val) {
    return Err(Killed)
  }
  if self.state.val.disk_full {
    return Err(DiskFull)
  }
  self.state.val.files[path] = data
  Ok(())
}

///|
pub impl Disk for FakeDisk with fn read(self, path : Bytes) -> Result[
  Bytes,
  HarnessFault,
] {
  match self.state.val.files.get(path) {
    Some(data) => Ok(data)
    None => Err(PathMissing)
  }
}

///|
pub impl Disk for FakeDisk with fn fsync(self, path : Bytes) -> Result[
  Unit,
  HarnessFault,
] {
  if count_op_and_check_kill(self.state.val) {
    return Err(Killed)
  }
  if self.state.val.disk_full {
    return Err(DiskFull)
  }
  match self.state.val.files.get(path) {
    Some(_) => Ok(())
    None => Err(PathMissing)
  }
}

///|
pub impl Disk for FakeDisk with fn rename(
  self,
  old_path : Bytes,
  new_path : Bytes,
) -> Result[Unit, HarnessFault] {
  if count_op_and_check_kill(self.state.val) {
    return Err(Killed)
  }
  if old_path == new_path {
    match self.state.val.files.get(old_path) {
      Some(_) => return Ok(())
      None => return Err(PathMissing)
    }
  }
  match self.state.val.files.get(old_path) {
    Some(data) => {
      self.state.val.files[new_path] = data
      self.state.val.files.remove(old_path)
      Ok(())
    }
    None => Err(PathMissing)
  }
}

///|
pub impl Disk for FakeDisk with fn capabilities(_self) -> DiskCapabilities {
  // Windows PoC proved file fsync and atomic rename; directory fsync is denied.
  { file_fsync: true, atomic_rename: true, dir_fsync: false, }
}

///|
priv struct RngState {
  mut state : UInt64
} derive(Debug)

///|
/// Own a SplitMix64 random stream initialized from a test seed.
pub(all) struct SplitMix64 {
  priv state : Ref[RngState]
} derive(Debug)

///|
pub extend SplitMix64 with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub extend SplitMix64 with Rng::{next_u64}

///|
pub fn SplitMix64::new(seed : UInt64) -> SplitMix64 {
  { state: Ref::Ref({ state: seed, }), }
}

///|
pub impl Rng for SplitMix64 with fn next_u64(self) -> UInt64 {
  self.state.val.state = self.state.val.state + 0x9E3779B97F4A7C15UL
  let mut value = self.state.val.state
  value = (value ^ (value >> 30)) * 0xBF58476D1CE4E5B9UL
  value = (value ^ (value >> 27)) * 0x94D049BB133111EBUL
  value ^ (value >> 31)
}

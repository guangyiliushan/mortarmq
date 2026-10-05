/// Provide deterministic side-effect seams for MortarMQ simulation tests.
///
/// Production adapters live outside this package. The fake implementations in
/// this package are the only clock, network, disk, and random sources allowed
/// in simulation tests.

///|
/// Report the three disk capabilities observed on supported Windows paths.
pub(all) struct DiskCapabilities {
  file_fsync : Bool
  atomic_rename : Bool
  dir_fsync : Bool
} derive(Eq, Debug)

///|
pub extend DiskCapabilities with Eq::{not_equal, equal}

///|
pub extend DiskCapabilities with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Report a deterministic harness fault without leaking an OS error.
pub(all) suberror HarnessFault {
  PathMissing
  PeerPartitioned
  DiskFull
  /// Report a fired fake-disk kill point, standing in for process death.
  Killed
} derive(Eq, Debug)

///|
pub extend HarnessFault with Eq::{not_equal, equal}

///|
pub extend HarnessFault with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Control monotonic virtual time and deterministic timer registration.
///
/// The simulation owns time: `sleep_until` registers a timer, while
/// `FakeClock::advance_to` decides which timers mature.
pub(open) trait Clock {
  async fn now_ms(Self) -> UInt64
  async fn sleep_until(Self, deadline_ms : UInt64) -> Bool
}

///|
/// Send and receive message bytes through an explicitly partitioned network.
pub(open) trait Net {
  async fn send(Self, peer : UInt16, data : Bytes) -> Result[Unit, HarnessFault]
  async fn receive(Self, peer : UInt16) -> Bytes?
}

///|
/// Perform durable file operations through a capability-aware storage seam.
pub(open) trait Disk {
  async fn write(Self, path : Bytes, data : Bytes) -> Result[Unit, HarnessFault]
  async fn read(Self, path : Bytes) -> Result[Bytes, HarnessFault]
  async fn fsync(Self, path : Bytes) -> Result[Unit, HarnessFault]
  async fn rename(Self, old_path : Bytes, new_path : Bytes) -> Result[
    Unit,
    HarnessFault,
  ]
  fn capabilities(Self) -> DiskCapabilities
}

///|
/// Produce reproducible random values without host entropy.
pub(open) trait Rng {
  fn next_uint64(Self) -> UInt64
}

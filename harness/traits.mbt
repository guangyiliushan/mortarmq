/// Provide deterministic side-effect seams for MortarMQ simulation tests.
///
/// Production adapters live outside this package. The fake implementations in
/// this package are the only clock, network, disk, and random sources allowed
/// in simulation tests.

///|
/// Report a deterministic simulation fault without leaking an OS error.
pub(all) suberror HarnessFault {
  PeerPartitioned
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
/// Produce reproducible random values without host entropy.
pub(open) trait Rng {
  fn next_uint64(Self) -> UInt64
}

///|
/// Report durable volume usage through a capability-free seam.
///
/// Usage is volume-level: every durable writer to the volume -- segments,
/// delivery ledger, metadata -- is counted together, so no per-file-type
/// accounting exists. Production adapters live outside this package with
/// the other adapters; fakes model capacity deterministically.
pub(open) trait DiskUsage {
  fn total_bytes(Self) -> UInt64
  fn used_bytes(Self) -> UInt64
}

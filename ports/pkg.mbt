/// Provide the durable-storage port MortarMQ's production code is written
/// against.
///
/// Production adapters implement these traits outside the simulation; the
/// fakes in `harness` implement them for deterministic tests. Nothing in
/// this package depends on the simulation, so the composition root can take
/// a real adapter without pulling the fake closure into a production build.

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
/// Report a durable-storage fault without leaking an OS error.
///
/// `PathMissing` and `DiskFull` are the two faults a real volume produces;
/// production code may match on either. `Killed` stands in for process
/// death: only the simulation fakes produce it, because a real adapter's
/// process dies instead of returning. The recovery suites drive on it as
/// the crash signal.
pub(all) suberror PortFault {
  PathMissing
  DiskFull
  /// Report a fired fake-disk kill point, standing in for process death.
  Killed
} derive(Eq, Debug)

///|
pub extend PortFault with Eq::{not_equal, equal}

///|
pub extend PortFault with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Perform durable file operations through a capability-aware storage seam.
pub(open) trait Disk {
  async fn write(Self, path : Bytes, data : Bytes) -> Result[Unit, PortFault]
  /// Append `data` at the file's end, creating the file when missing: the
  /// log-shaped writers' O(data) path, versus `write`'s whole-file replace.
  async fn append(Self, path : Bytes, data : Bytes) -> Result[Unit, PortFault]
  async fn read(Self, path : Bytes) -> Result[Bytes, PortFault]
  async fn fsync(Self, path : Bytes) -> Result[Unit, PortFault]
  async fn rename(Self, old_path : Bytes, new_path : Bytes) -> Result[
    Unit,
    PortFault,
  ]
  /// Delete a file so its bytes stop counting against the volume. A
  /// missing path reports `PathMissing`; this is the relief valve
  /// retention (`delete_before`) reclaims space through.
  async fn remove(Self, path : Bytes) -> Result[Unit, PortFault]
  fn capabilities(Self) -> DiskCapabilities
}

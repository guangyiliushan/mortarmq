/// Seed one simulation environment and compare two same-seed runs of a
/// scenario.
///
/// `SimEnv::new` wires an empty clock, network, and disk with a `SplitMix64`
/// stream started at the seed, so the same seed produces identical initial
/// state and identical random draws. `reproducible` runs a scenario twice on
/// two fresh environments and reports whether the outcomes agree; any state a
/// run should contribute to the comparison has to come back inside the
/// scenario's return value.

///|
/// Bundle one clock, network, disk, and random stream for a simulation run.
///
/// A scenario receives one environment and derives everything it observes
/// from it, so handing each run a freshly wired environment is the whole
/// contract the runner has to guarantee. Faults are armed on the exposed
/// fakes after construction, for example `disk.set_kill_at(3)` or
/// `net.partition(peer)`.
///
/// Example:
///
/// ```mbt check
/// async test {
///   let env = @harness.SimEnv::new(3UL)
///   env.disk.set_kill_at(1)
///   assert_eq(
///     @harness.Disk::write(env.disk, b"log", b"bytes"),
///     Err(@harness.Killed),
///   )
/// }
/// ```
pub(all) struct SimEnv {
  clock : FakeClock
  net : FakeNet
  disk : FakeDisk
  rng : SplitMix64
}

///|
/// Wire a fresh simulation environment from one seed.
///
/// The clock starts at zero with no timers, the network and disk hold
/// nothing, and the random stream starts at `seed`; two calls with the same
/// seed therefore hand scenarios identical environments. Fault injection is
/// armed after construction on the exposed fakes.
///
/// Parameters:
///
/// * `seed` : Start value of the `SplitMix64` stream. Every other component
///   is deterministic by construction, so this seed is the whole run's
///   identity.
///
/// Example:
///
/// ```mbt check
/// test {
///   let first = @harness.SimEnv::new(0UL)
///   let second = @harness.SimEnv::new(0UL)
///   assert_eq(
///     @harness.Rng::next_uint64(first.rng),
///     @harness.Rng::next_uint64(second.rng),
///   )
///   assert_eq(first.disk.snapshot().length(), 0)
/// }
/// ```
pub fn SimEnv::new(seed : UInt64) -> SimEnv {
  {
    clock: FakeClock::new(),
    net: FakeNet::new(),
    disk: FakeDisk::new(),
    rng: SplitMix64::new(seed),
  }
}

///|
/// Run a scenario twice from the same seed on fresh environments and report
/// whether the outcomes agree.
///
/// `false` means the scenario does not reproduce: it observed something the
/// seed does not reset, such as mutable state captured across runs. The runs
/// execute sequentially. Surviving disk state is compared only when the
/// scenario returns it, typically by folding `FakeDisk::snapshot` into the
/// outcome.
///
/// Parameters:
///
/// * `seed` : Environment seed handed to both runs unchanged.
/// * `scenario` : One run of the experiment; it must derive everything it
///   observes from the environment it receives.
///
/// Example:
///
/// ```mbt check
/// async test {
///   let draw : async (@harness.SimEnv) -> UInt64 = fn(env) {
///     @harness.Rng::next_uint64(env.rng)
///   }
///   assert_eq(@harness.reproducible(9UL, draw), true)
/// }
/// ```
pub async fn[T : Eq] reproducible(
  seed : UInt64,
  scenario : async (SimEnv) -> T,
) -> Bool {
  let first = scenario(SimEnv::new(seed))
  let second = scenario(SimEnv::new(seed))
  first == second
}

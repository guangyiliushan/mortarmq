/// Exercise the seeded simulation runner: environment wiring determinism,
/// agreement and divergence reporting, and a kill-restart replay sweep over
/// fixed seeds.

///|
/// Hold one kill-restart outcome so a whole cycle can be compared.
struct KillRestartOutcome {
  planned : Int
  armed : Int
  recovered : Array[Bytes]
  files : Array[(Bytes, Bytes)]
} derive(Eq)

///|
/// Run one toy kill-restart cycle: derive a workload and a kill point from
/// the environment stream, write records until the armed disk dies, rebuild a
/// fresh disk from the surviving snapshot, and read back what landed.
async fn kill_restart(env : @harness.SimEnv) -> KillRestartOutcome {
  let paths = [b"record-0", b"record-1", b"record-2", b"record-3"]
  let planned = (@harness.Rng::next_uint64(env.rng) % 4UL).to_int() + 1
  let armed = (@harness.Rng::next_uint64(env.rng) % (planned + 1).to_uint64()).to_int() +
    1
  env.disk.set_kill_at(armed)
  for index in 0..<planned {
    let length = (@harness.Rng::next_uint64(env.rng) % 7UL).to_int()
    let payload = PAYLOAD_ALPHABET[:length].to_owned()
    match @harness.Disk::write(env.disk, paths[index], payload) {
      Ok(_) => ()
      Err(@harness.Killed) => break
      Err(_) => fail("kill-restart cycle hit an unexpected disk fault")
    }
  }
  let mirror = @harness.FakeDisk::new()
  for (path, data) in env.disk.snapshot() {
    assert_eq(@harness.Disk::write(mirror, path, data), Ok(()))
  }
  let recovered : Array[Bytes] = []
  for index in 0..<planned {
    match @harness.Disk::read(mirror, paths[index]) {
      Ok(data) => recovered.push(data)
      Err(@harness.PathMissing) => ()
      Err(_) => fail("the restarted disk holds bytes or nothing")
    }
  }
  { planned, armed, recovered, files: mirror.snapshot(), }
}

///|
const PAYLOAD_ALPHABET : Bytes = b"abcdefghijklmnopqrstuvwxyz"

///|
async test "the same seed wires identical fresh environments" {
  let first = @harness.SimEnv::new(20261008UL)
  let second = @harness.SimEnv::new(20261008UL)
  for _draw in 0..<3 {
    assert_eq(
      @harness.Rng::next_uint64(first.rng),
      @harness.Rng::next_uint64(second.rng),
    )
  }
  assert_eq(@harness.Clock::now_ms(first.clock), 0UL)
  assert_eq(first.clock.pending_count(), 0)
  assert_eq(first.clock.fired_deadlines().length(), 0)
  assert_eq(first.net.sent_messages().length(), 0)
  assert_eq(first.disk.snapshot().length(), 0)
  assert_eq(
    @harness.Disk::capabilities(first.disk),
    @harness.Disk::capabilities(second.disk),
  )
}

///|
test "boundary seeds stay deterministic and distinct seeds diverge" {
  for seed in [0UL, 0xFFFFFFFFFFFFFFFFUL] {
    let first = @harness.SimEnv::new(seed)
    let second = @harness.SimEnv::new(seed)
    for _draw in 0..<3 {
      assert_eq(
        @harness.Rng::next_uint64(first.rng),
        @harness.Rng::next_uint64(second.rng),
      )
    }
  }
  let zero = @harness.SimEnv::new(0UL)
  let max = @harness.SimEnv::new(0xFFFFFFFFFFFFFFFFUL)
  assert_eq(
    @harness.Rng::next_uint64(zero.rng) != @harness.Rng::next_uint64(max.rng),
    true,
  )
}

///|
async test "reproducible reports agreement for a deterministic scenario" {
  let scenario = async fn(
    env : @harness.SimEnv,
  ) -> (UInt64, Array[(Bytes, Bytes)]) {
    assert_eq(@harness.Disk::write(env.disk, b"state", b"payload"), Ok(()))
    (@harness.Rng::next_uint64(env.rng), env.disk.snapshot())
  }
  assert_eq(@harness.reproducible(0x5EEDUL, scenario), true)
}

///|
async test "reproducible reports divergence when state leaks across runs" {
  let drift = Ref::Ref(0UL)
  let scenario : async (@harness.SimEnv) -> UInt64 = fn(_env) {
    let observed = drift.val
    drift.val = observed + 1UL
    observed
  }
  assert_eq(@harness.reproducible(7UL, scenario), false)
}

///|
async test "a killed write run restarts to exactly the records that landed" {
  for seed in [0UL, 7UL, 20261009UL, 0xFFFFFFFFFFFFFFFFUL] {
    let outcome = kill_restart(@harness.SimEnv::new(seed))
    assert_eq(outcome.planned >= 1 && outcome.planned <= 4, true)
    assert_eq(outcome.armed >= 1 && outcome.armed <= outcome.planned + 1, true)
    let landed = if outcome.armed <= outcome.planned {
      outcome.armed - 1
    } else {
      outcome.planned
    }
    assert_eq(outcome.recovered.length(), landed)
    assert_eq(outcome.files.length(), landed)
    for value in outcome.recovered {
      assert_eq(value, PAYLOAD_ALPHABET[:value.length()].to_owned())
    }
  }
}

///|
async test "kill-restart replay agrees across fixed seeds" {
  let seeds = [
    0UL, 1UL, 2UL, 3UL, 4UL, 5UL, 6UL, 7UL, 8UL, 9UL, 0x9E3779B97F4A7C15UL, 0xFFFFFFFFFFFFFFFFUL,
  ]
  for seed in seeds {
    assert_eq(@harness.reproducible(seed, kill_restart), true)
  }
}

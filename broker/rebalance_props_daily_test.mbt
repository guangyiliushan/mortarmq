/// CB2 daily tier: liveness -- after a finite member event
/// sequence the assignment is quiescent. A re-join of a live
/// (connection, topic) is idempotent: zero notices, every owner and
/// ownership epoch stays put, and the epoch counters do not move --
/// migration has stopped. This is the daily-tier counterpart of the CB
/// pins in `rebalance_props_test.mbt`: with
/// `MORTARMQ_PROP_DAILY` set the sweep runs registry daily mode --
/// run-unique seed from the clock, count=1000, max_size=256 -- and logs
/// the seed so a failure reproduces. Without the flag it runs the pinned
/// seed (20261023) so plain `moon test` stays reproducible. The
/// `daily_*` helper names are deliberate: blackbox test files share one
/// package namespace and the pin file owns the `cb_*` names.

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
    20261023UL
  }
}

///|
fn daily_count() -> UInt {
  if daily_mode() {
    1000U
  } else {
    200U
  }
}

///|
fn daily_max_size() -> UInt {
  if daily_mode() {
    256U
  } else {
    100U
  }
}

///|
fn daily_partitions(draw : UInt) -> Int {
  (draw % 8U).reinterpret_as_int() + 1
}

///|
fn daily_steps(draw : UInt) -> Int {
  ((draw >> 4) % 5U).reinterpret_as_int() + 2
}

///|
test "CB2 finite member events reach a quiescent assignment (quickcheck daily tier)" {
  let seed = daily_seed()
  let count = daily_count()
  let max_size = daily_max_size()
  if daily_mode() {
    println("CB2-daily seed=\{seed} count=\{count} max_size=\{max_size}")
  }
  @quickcheck.check(
    (draw : UInt) => {
      let coordinator = @broker.GroupCoordinator::new(1)
      let partitions = daily_partitions(draw)
      let steps = daily_steps(draw)
      let connections : Array[UInt64] = []
      let members : Array[UInt64] = []
      let mut connection = 100UL
      for step in 0..<steps {
        let choice = (draw >> (step * 3 + 6)) & 7U
        if choice < 5U || members.length() == 0 {
          match
            @broker.GroupCoordinator::join(
              coordinator,
              connection,
              1,
              partitions.to_uint16(),
            ) {
            Ok(joined) => {
              connections.push(connection)
              members.push(joined.member_id)
            }
            Err(_) => ()
          }
          connection = connection + 1UL
        } else {
          let index = (choice % members.length().reinterpret_as_uint()).reinterpret_as_int()
          match @broker.GroupCoordinator::leave(coordinator, members[index]) {
            Ok(_) => {
              ignore(connections.remove(index))
              ignore(members.remove(index))
            }
            Err(_) => return false
          }
        }
      }
      if members.length() == 0 {
        // Fully drained: nothing is left to migrate.
        return true
      }
      // Quiescence: a re-join of an existing (connection, topic) is a
      // fixed point -- zero notices and no epoch movement at all.
      let before_assignment = @broker.GroupCoordinator::assignment_epoch(
        coordinator,
      )
      match
        @broker.GroupCoordinator::join(
          coordinator,
          connections[0],
          1,
          partitions.to_uint16(),
        ) {
        Ok(rejoined) => {
          if rejoined.notices.length() != 0 {
            return false
          }
          if rejoined.assignment_epoch != before_assignment {
            return false
          }
        }
        Err(_) => return false
      }
      true
    },
    count~,
    seed~,
    max_size~,
  )
}

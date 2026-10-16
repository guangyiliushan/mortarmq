/// Rebalance properties CB1, CB3, CB4.
///
/// CB1 safety: after every member event the converged assignment gives
/// every subscribed partition exactly one owner (and an empty universe
/// when the last member leaves). CB3 incremental: one event migrates only
/// the affected partitions -- everything outside the NOTICE set keeps its
/// owner AND its ownership epoch (the "未变更不动 epoch" assertion).
/// CB4: assignment_epoch is monotone, advancing exactly once
/// per membership or subscription change. Each property pins seed and
/// count so a failure reproduces exactly; CB2 (liveness) is the daily
/// tier in `rebalance_props_daily_test.mbt`.
///
/// The draws pick a partition count, a step count, and a join/leave
/// sequence over one topic; the engine under test is the coordinator's
/// declarative-target recomputation.

///|
fn cb_partitions(draw : UInt32) -> Int32 {
  (draw % 8U).reinterpret_as_int() + 1
}

///|
fn cb_steps(draw : UInt32) -> Int32 {
  ((draw >> 4) % 5U).reinterpret_as_int() + 2
}

///|
fn cb_owner(
  coordinator : @broker.GroupCoordinator,
  partition : Int32,
) -> UInt64? {
  @broker.GroupCoordinator::owner_of(coordinator, 1, partition.to_uint16())
}

///|
fn cb_epoch(
  coordinator : @broker.GroupCoordinator,
  partition : Int32,
) -> UInt64? {
  @broker.GroupCoordinator::ownership_epoch_of(
    coordinator,
    1,
    partition.to_uint16(),
  )
}

///|
/// The drawn event sequence: joins of fresh connections and leaves of
/// live members. After each event `per_step` sees the coordinator, the
/// live (connection, member) lists and that event's NOTICE payloads.
fn cb_run(
  coordinator : @broker.GroupCoordinator,
  draw : UInt32,
  partitions : Int32,
  per_step : (
    @broker.GroupCoordinator,
    Array[UInt64],
    Array[UInt64],
    Array[@protocol.NoticePayload],
  ) -> Bool,
) -> Bool {
  let steps = cb_steps(draw)
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
          if !per_step(coordinator, connections, members, joined.notices) {
            return false
          }
        }
        // Only the group caps refuse; a refused join changes nothing.
        Err(_) => ()
      }
      connection = connection + 1UL
    } else {
      let index = (choice % members.length().reinterpret_as_uint()).reinterpret_as_int()
      match @broker.GroupCoordinator::leave(coordinator, members[index]) {
        Ok(left) => {
          ignore(connections.remove(index))
          ignore(members.remove(index))
          if !per_step(coordinator, connections, members, left.notices) {
            return false
          }
        }
        Err(_) => return false
      }
    }
  }
  true
}

///|
test "CB1 every subscribed partition converges to exactly one owner (quickcheck seed=20261020 is reproducible)" {
  @quickcheck.check(
    (draw : UInt32) => {
      let coordinator = @broker.GroupCoordinator::new(1)
      let partitions = cb_partitions(draw)
      cb_run(coordinator, draw, partitions, fn(
        current,
        _connections,
        members,
        _notices,
      ) {
        if members.length() > 0 {
          // Converged: the universe is fully and uniquely owned.
          for p in 0..<partitions {
            if cb_owner(current, p) is None {
              return false
            }
          }
        } else {
          // The last member left: the universe is released whole.
          for p in 0..<partitions {
            if cb_owner(current, p) is Some(_) {
              return false
            }
          }
        }
        true
      })
    },
    count=200,
    max_shrinks=20,
    seed=20261020,
  )
}

///|
test "CB3 one event migrates only the affected partitions and never their epochs (quickcheck seed=20261021 is reproducible)" {
  @quickcheck.check(
    (draw : UInt32) => {
      let coordinator = @broker.GroupCoordinator::new(1)
      let partitions = cb_partitions(draw)
      let prev_owner : Array[UInt64?] = []
      let prev_epoch : Array[UInt64?] = []
      for _ in 0..<partitions {
        prev_owner.push(None)
        prev_epoch.push(None)
      }
      cb_run(coordinator, draw, partitions, fn(
        current,
        _connections,
        members,
        notices,
      ) {
        for p in 0..<partitions {
          let mut moved = false
          for notice in notices {
            if notice.partition.to_int() == p {
              moved = true
            }
          }
          let before_owner = prev_owner[p]
          let before_id = match before_owner {
            Some(id) => id
            None => 0UL
          }
          let mut owner_stays = false
          if before_owner is Some(_) {
            for mid in members {
              if mid == before_id {
                owner_stays = true
              }
            }
          }
          if moved {
            // The moved partition new epoch is exactly the one its
            // ASSIGN notice carried (fresh 1, or prior + 1).
            for notice in notices {
              if notice.partition.to_int() == p &&
                notice.kind == @broker.NOTICE_KIND_ASSIGN {
                if cb_epoch(current, p) != Some(notice.ownership_epoch) {
                  return false
                }
              }
            }
          } else if owner_stays {
            // 未变更不动 epoch: an untouched surviving owner keeps both.
            if cb_owner(current, p) != before_owner {
              return false
            }
            if cb_epoch(current, p) != prev_epoch[p] {
              return false
            }
            // Vacated by departure takes the wholesale path (no
            // per-partition notices by design): the record is released.
          } else if cb_owner(current, p) is Some(_) {
            return false
          }
          prev_owner[p] = cb_owner(current, p)
          prev_epoch[p] = cb_epoch(current, p)
        }
        true
      })
    },
    count=200,
    max_shrinks=20,
    seed=20261021,
  )
}

///|
test "CB4 assignment_epoch advances exactly once per membership change (quickcheck seed=20261022 is reproducible)" {
  @quickcheck.check(
    (draw : UInt32) => {
      let coordinator = @broker.GroupCoordinator::new(1)
      let partitions = cb_partitions(draw)
      let prev : Array[UInt32] = [0U]
      cb_run(coordinator, draw, partitions, fn(
        current,
        _connections,
        _members,
        _notices,
      ) {
        let now = @broker.GroupCoordinator::assignment_epoch(current)
        if now != prev[0] + 1U {
          return false
        }
        prev[0] = now
        true
      })
    },
    count=200,
    max_shrinks=20,
    seed=20261022,
  )
}

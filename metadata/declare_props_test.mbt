/// QuickCheck property forms for concurrent DECLARE exactly-once: the
/// case tests exist elsewhere in this package, and this file pins the
/// property half.
///
/// Each property pins seed and count so a failure reproduces exactly
/// (the pinned-seed discipline of protocol/frame_props_test.mbt). quickcheck
/// is bundled with the toolchain (moon 0.1.20260920 /
/// moonbitlang/core 0.10.14+7d59c7ec9), see the note in moon.mod.

///|
test "property: any shuffled concurrent identical declare set is exactly-once (quickcheck seed=20261021 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let n = (draw % 4U).reinterpret_as_int() + 2
      let ids : Array[UInt64] = []
      for i in 0..<n {
        ids.push((i + 1).to_uint64())
      }
      let mut bits = draw
      for i in 0..<n {
        let span = (i + 1).reinterpret_as_uint()
        let j = (bits % span).reinterpret_as_int()
        bits = bits >> 1
        let tmp = ids[i]
        ids[i] = ids[j]
        ids[j] = tmp
      }
      let machine = @metadata.DeclareMachine::new()
      let mut created = 0
      let mut idempotent = 0
      for id in ids {
        match machine.submit(id, 7UL, @metadata.DeclareBody::Create("dp1", 3)) {
          @metadata.DeclareOutcome::Created => created = created + 1
          @metadata.DeclareOutcome::IdempotentOk => idempotent = idempotent + 1
          _ => return false
        }
      }
      if created != 1 || idempotent != n - 1 {
        return false
      }
      machine.partition_count("dp1") == Some(3U)
    },
    count=200,
    seed=20261021,
  )
}

///|
test "property: replaying any accepted mutation is zero-side-effect (quickcheck seed=20261022 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let machine = @metadata.DeclareMachine::new()
      let ops : Array[@metadata.DeclareBody] = [
        @metadata.DeclareBody::Create("dp2", 3),
      ]
      if draw % 2U == 0U {
        ops.push(@metadata.DeclareBody::Create("dp2.dlq", 3))
      }
      ignore(machine.submit_set(5UL, 9UL, ops))
      let before = fingerprint(machine)
      let outcomes = machine.submit_set(5UL, 0UL, ops)
      for outcome in outcomes {
        match outcome {
          @metadata.DeclareOutcome::IdempotentOk => ()
          _ => return false
        }
      }
      if fingerprint(machine) != before {
        return false
      }
      machine.leader_epoch() == 9UL
    },
    count=200,
    seed=20261022,
  )
}

///|
test "property: any altered body-set of an accepted mutation is fenced (quickcheck seed=20261023 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let machine = @metadata.DeclareMachine::new()
      let ops : Array[@metadata.DeclareBody] = [
        @metadata.DeclareBody::Create("dp3", 3),
      ]
      let mut two = false
      if draw % 2U == 0U {
        ops.push(@metadata.DeclareBody::Create("dp3.dlq", 3))
        two = true
      }
      ignore(machine.submit_set(7UL, 9UL, ops))
      let before = fingerprint(machine)
      let altered : Array[@metadata.DeclareBody] = []
      match draw % 3U {
        0U => {
          altered.push(@metadata.DeclareBody::Create("dp3", 5))
          if two {
            altered.push(@metadata.DeclareBody::Create("dp3.dlq", 3))
          }
        }
        1U =>
          if two {
            altered.push(@metadata.DeclareBody::Create("dp3", 3))
          } else {
            altered.push(@metadata.DeclareBody::Delete("dp3"))
          }
        _ => {
          altered.push(@metadata.DeclareBody::Create("dp3", 3))
          altered.push(@metadata.DeclareBody::Create("dp3x", 1))
        }
      }
      let outcomes = machine.submit_set(7UL, 11UL, altered)
      for outcome in outcomes {
        match outcome {
          @metadata.DeclareOutcome::MutationFenced => ()
          _ => return false
        }
      }
      fingerprint(machine) == before
    },
    count=200,
    seed=20261023,
  )
}

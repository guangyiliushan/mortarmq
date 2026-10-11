/// Decision-table properties for idempotent DECLARE (the property-suite
/// gap the second-round review named).
///
/// The table is the seven decision rows the sources agree on: the
/// upgrade research decision table minus its query row (a query is not
/// a (mutation, existing state) decision), with the replay row pinned
/// to the normative wording (a replayed accepted mutation answers
/// IDEMPOTENT_OK) and the tombstone row pinned to the shipped semantics
/// (a deleted name is re-creatable by a new mutation; the table draft's
/// epoch-raise mechanic exists in no requirement and is deferred).
/// Row shape: (mutation status, existing resource state, config match)
/// -> expected decision and whether state changes.
///
/// Each property pins its seed so a failure reproduces exactly (the
/// pinned-seed discipline of protocol/frame_props_test.mbt). The
/// existing declare property tests stay as a separate book; this file
/// drives the table only.

///|
/// The topic-set view of a machine (the resource state a decision row
/// talks about; the accepted-mutation bookkeeping is idempotency
/// memory, not a resource change).
fn dt_topics(machine : @metadata.DeclareMachine) -> Array[String] {
  let out : Array[String] = []
  for (name, count) in machine.topics.to_array() {
    out.push(name + ":" + count.to_string())
  }
  out.sort()
  out
}

///|
/// The expected decision for one table row index:
/// 0 replay, 1 fresh, 2 race-loser same config, 3 race-loser different
/// config, 4 re-declare same config, 5 re-declare different config,
/// 6 tombstone re-create.
fn dt_expect(row : Int) -> @metadata.DeclareOutcome {
  match row {
    0 => @metadata.DeclareOutcome::IdempotentOk
    1 => @metadata.DeclareOutcome::Created
    2 => @metadata.DeclareOutcome::IdempotentOk
    3 => @metadata.DeclareOutcome::NameCountMismatch
    4 => @metadata.DeclareOutcome::IdempotentOk
    5 => @metadata.DeclareOutcome::NameCountMismatch
    6 => @metadata.DeclareOutcome::Created
    _ => @metadata.DeclareOutcome::Created
  }
}

///|
/// Whether the row's decision changes state (CREATED does, the
/// idempotent and mismatch answers do not).
fn dt_state_change(row : Int) -> Bool {
  match row {
    1 | 6 => true
    0 | 2 | 3 | 4 | 5 => false
    _ => false
  }
}

///|
/// Build the machine, the tested mutation and its id for one row, with
/// draw-derived names and counts so the property explores the space.
fn dt_scenario(
  row : Int,
  draw : UInt,
) -> (@metadata.DeclareMachine, UInt64, @metadata.DeclareBody) {
  let name = "dt" + draw.reinterpret_as_int().to_string()
  let count = draw % 4U + 1U
  let machine = @metadata.DeclareMachine::new()
  let body = @metadata.DeclareBody::Create(name, count)
  match row {
    0 => {
      ignore(machine.submit(1UL, 7UL, body))
      (machine, 1UL, body)
    }
    1 => (machine, 2UL, body)
    2 | 4 => {
      ignore(machine.submit(1UL, 7UL, body))
      (machine, 2UL, body)
    }
    3 | 5 => {
      ignore(machine.submit(1UL, 7UL, body))
      (machine, 2UL, @metadata.DeclareBody::Create(name, count + 1U))
    }
    6 => {
      ignore(machine.submit(1UL, 7UL, body))
      ignore(machine.submit(3UL, 7UL, @metadata.DeclareBody::Delete(name)))
      (machine, 2UL, body)
    }
    _ => (machine, 2UL, body)
  }
}

///|
/// Run one row and return the observed outcome; the table property and
/// the anti-hollow check both consume this.
fn dt_run(row : Int, draw : UInt) -> @metadata.DeclareOutcome {
  let (machine, mutation_id, body) = dt_scenario(row, draw)
  machine.submit(mutation_id, 7UL, body)
}

///|
test "the decision table covers every row" {
  for row in 0..<7 {
    let (machine, mutation_id, body) = dt_scenario(row, 42U)
    let before = dt_topics(machine)
    let outcome = machine.submit(mutation_id, 7UL, body)
    assert_eq(outcome, dt_expect(row))
    assert_eq(dt_topics(machine) != before, dt_state_change(row))
  }
}

///|
test "the quickcheck property matches every decision row (quickcheck seed=20261024 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let row = (draw % 7U).reinterpret_as_int()
      let (machine, mutation_id, body) = dt_scenario(row, draw)
      let before = dt_topics(machine)
      let outcome = machine.submit(mutation_id, 7UL, body)
      if outcome != dt_expect(row) {
        return false
      }
      let changed = dt_topics(machine) != before
      changed == dt_state_change(row)
    },
    count=350,
    max_shrinks=20,
    seed=20261024,
  )
}

///|
test "scrambling any decision row breaks the property" {
  for row in 0..<7 {
    let flipped = match dt_expect(row) {
      @metadata.DeclareOutcome::Created =>
        @metadata.DeclareOutcome::IdempotentOk
      @metadata.DeclareOutcome::IdempotentOk =>
        @metadata.DeclareOutcome::Created
      @metadata.DeclareOutcome::NameCountMismatch =>
        @metadata.DeclareOutcome::Created
      _ => @metadata.DeclareOutcome::Created
    }
    assert_eq(dt_run(row, 7U) == flipped, false)
  }
}

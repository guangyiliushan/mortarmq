// The epoch fence as a state machine, so the property can be checked
// rather than argued.
//
// One replica is enough: the fence is a per-replica comparison between
// the term a batch carries and the term this replica has promised, and
// replicas do not share promises. What the model has to hold onto is the
// promise and the term each sequence was written at, which is where a
// stale write would show up.
//
// The property is `promiseCoversEveryAppliedEntry`: no sequence in the
// log was written by a term below the promise this replica holds. It is
// not the guard restated -- the guard alone does not stop the promise
// from being lower than an entry that somehow landed, and the entry's
// term is what would betray a write that slipped past the fence. Drop
// `e == promise` from `apply` and the checker finds a counterexample,
// which is how you know the model is saying something.
//
// Toolchain: quint 0.33.0 (Apache-2.0). Reproduce:
//
//   quint parse formal/fencing.qnt
//   quint typecheck formal/fencing.qnt
//   quint run --invariant=promiseCoversEveryAppliedEntry formal/fencing.qnt
//   quint run --invariant=appliedIsPrefix formal/fencing.qnt
module fencing {
  // Four sequences and three terms is enough: the fence is about the
  // ordering between two integers, not about size.
  val MaxSeq: int = 4
  val MaxEpoch: int = 3

  // The epoch this replica has durably promised. Zero means it has
  // recognised no leader yet, and it must then apply nothing at all.
  var promise: int

  // The term each sequence was written at, or zero when it has not been
  // written. Four flat cells rather than a function: the model is about
  // the relation between these numbers and `promise`, and flat cells
  // keep that relation visible in every invariant.
  var s1: int
  var s2: int
  var s3: int
  var s4: int

  action init = all {
    promise' = 0,
    s1' = 0,
    s2' = 0,
    s3' = 0,
    s4' = 0
  }

  // Take up a new term. The promise only ever moves up, and adopting a
  // term says nothing about what the log already holds.
  action adopt(e: int): bool = all {
    e > promise,
    e <= MaxEpoch,
    promise' = e,
    s1' = s1,
    s2' = s2,
    s3' = s3,
    s4' = s4
  }

  // Apply one batch at the term this replica has promised, into the
  // first free slot.
  //
  // `e == promise` is the fence. A batch from an older term has no
  // transition at all, so nothing about this replica can move; a batch
  // from a newer term is not applied either -- it has to be promised
  // first, which is the durable step before any of its writes land.
  action apply(e: int): bool = all {
    e == promise,
    e > 0,
    s4 == 0,
    s1' = if (s1 == 0) e else s1,
    s2' = if (s1 > 0 and s2 == 0) e else s2,
    s3' = if (s2 > 0 and s3 == 0) e else s3,
    s4' = if (s3 > 0 and s4 == 0) e else s4,
    promise' = promise
  }

  // One step: either take up a term, or apply a batch at the term
  // already taken up. The parameter list is enumerated rather than
  // sampled so the checker sees every term the model allows and the
  // guards decide which of them are legal in the state it is in.
  action step = any {
    adopt(1),
    adopt(2),
    adopt(3),
    apply(1),
    apply(2),
    apply(3),
    stutter
  }

  // A step in which nothing happens.
  //
  // Without it the model has terminal states -- every slot written and
  // every term taken up -- where no other action is enabled, and the
  // model checker reports that as a deadlock rather than as a finished
  // search. It changes no state, so it adds no reachable state and
  // weakens no invariant; it only says that time can pass without
  // anything occurring, which is true of the system it stands for.
  action stutter = all {
    promise' = promise,
    s1' = s1,
    s2' = s2,
    s3' = s3,
    s4' = s4
  }

  // The fencing property: nothing in the log was written by a term this
  // replica has not promised. A stale leader's batch would put a term
  // below `promise` into a slot and break this immediately.
  val promiseCoversEveryAppliedEntry =
    (s1 == 0 or s1 <= promise) and
    (s2 == 0 or s2 <= promise) and
    (s3 == 0 or s3 <= promise) and
    (s4 == 0 or s4 <= promise)

  // The log fills in order: a later sequence is never written before an
  // earlier one, so a slot only opens behind its predecessor.
  val appliedIsPrefix =
    (s2 > 0 implies s1 > 0) and
    (s3 > 0 implies s2 > 0) and
    (s4 > 0 implies s3 > 0)
}

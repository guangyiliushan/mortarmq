// The lease as a trigger, not a decision: when a lease lapses the
// cluster elects, and what the lease says about *when* never decides
// *who*.
//
// The safety claim in one line: a leader exists only where a majority
// has already promised its term, and the term never moves backwards.
// The lease appears as an action of its own precisely so that a model
// in which expiry directly promoted somebody would be checkable -- if
// `expire` were to advance the term without a promise, the first
// invariant below finds it.
//
// The temporal half below states the election liveness claim: a lapsed
// lease eventually sees the term it triggered installed, under the
// progress assumption the scheduler owes the machinery -- expressed as
// `fair_step` so the assumption lives in the transition relation. The
// safety half is unchanged and still runs against `step`.

//
// Toolchain: quint 0.33.0 (Apache-2.0) against the Apalache 0.62.1
// server. On Windows the server must be started first, and a Java 21+
// runtime must be on PATH (Apalache 0.62.1 class files are version 65):
//
//   ~/.quint/apalache-dist-0.62.1/apalache/bin/apalache-mc server --port=8822 &
//   quint run --invariant=leaderImpliesQuorumPromise formal/lease.qnt
//   quint verify --init=init --step=step --invariant=leaderImpliesQuorumPromise formal/lease.qnt
//   quint verify --backend tlc --init=init --step=fair_step --temporal=lapseElects formal/lease.qnt
module lease {
  // Three members, majority of two, three terms -- the same bounds the
  // fencing model uses, and the same reason: the properties are about
  // ordering and counting, not about size.
  val Nodes: int = 3
  val Quorum: int = 2
  val MaxEpoch: int = 3

  // The term in force, or zero when no leader has been installed.
  var leaderEpoch: int

  // The term the previous step held, so a term that moved backwards is
  // visible as state rather than as a missing transition.
  var priorLeaderEpoch: int

  // What each member has promised. Flat cells rather than a function:
  // three is small enough that the counting an install depends on reads
  // directly in the guard.
  var p1: int
  var p2: int
  var p3: int

  // Whether a leader is being followed. A lease is a property of a
  // leader, so there is none before one exists.
  var lease: bool

  // Whether a lease lapse is still waiting on the election it
  // triggers. `expire` raises it and only `install` clears it, so the
  // liveness claim below has a state to hold onto.
  var lapsed: bool

  action init = all {
    leaderEpoch' = 0,
    priorLeaderEpoch' = 0,
    p1' = 0,
    p2' = 0,
    p3' = 0,
    lease' = false,
    lapsed' = false
  }

  // The heartbeat. It refreshes liveness and says nothing at all about
  // which term is in force -- that is the whole separation the design
  // is built on.
  action refresh = all {
    leaderEpoch > 0,
    leaderEpoch' = leaderEpoch,
    priorLeaderEpoch' = leaderEpoch,
    p1' = p1,
    p2' = p2,
    p3' = p3,
    lease' = true,
    lapsed' = lapsed
  }

  // The lease lapses. This is the trigger and nothing more: it names no
  // term, promises none, and cannot make anybody leader. A model in
  // which this action advanced the term would break the first
  // invariant, which is the point of modelling it separately.
  action expire = all {
    lease' = false,
    leaderEpoch' = leaderEpoch,
    priorLeaderEpoch' = leaderEpoch,
    p1' = p1,
    p2' = p2,
    p3' = p3,
    lapsed' = true
  }

  // One member promises a term. Promises only ever move up: a member
  // that has promised a term has given up its right to promise a lower
  // one, which is what stops two candidates collecting the same
  // followers.
  action promise1(e: int): bool = all {
    e > p1,
    e <= MaxEpoch,
    p1' = e,
    leaderEpoch' = leaderEpoch,
    priorLeaderEpoch' = leaderEpoch,
    p2' = p2,
    p3' = p3,
    lease' = lease,
    lapsed' = lapsed
  }

  action promise2(e: int): bool = all {
    e > p2,
    e <= MaxEpoch,
    p2' = e,
    leaderEpoch' = leaderEpoch,
    priorLeaderEpoch' = leaderEpoch,
    p1' = p1,
    p3' = p3,
    lease' = lease,
    lapsed' = lapsed
  }

  action promise3(e: int): bool = all {
    e > p3,
    e <= MaxEpoch,
    p3' = e,
    leaderEpoch' = leaderEpoch,
    priorLeaderEpoch' = leaderEpoch,
    p1' = p1,
    p2' = p2,
    lease' = lease,
    lapsed' = lapsed
  }

  // Install a term, and only where a majority has promised it. This is
  // the one action that can move the term, so the two properties below
  // are properties of this guard.
  action install(e: int): bool = all {
    e > leaderEpoch,
    e <= MaxEpoch,
    ((if (p1 >= e) 1 else 0) +
      (if (p2 >= e) 1 else 0) +
      (if (p3 >= e) 1 else 0)) >= Quorum,
    leaderEpoch' = e,
    priorLeaderEpoch' = leaderEpoch,
    p1' = p1,
    p2' = p2,
    p3' = p3,
    lease' = lease,
    lapsed' = false
  }

  // A step in which nothing happens. Without it the model has terminal
  // states where no action is enabled and the checker reports a
  // deadlock instead of a finished search; it changes no state, so it
  // adds no reachable state and weakens no invariant.
  action stutter = all {
    leaderEpoch' = leaderEpoch,
    priorLeaderEpoch' = leaderEpoch,
    p1' = p1,
    p2' = p2,
    p3' = p3,
    lease' = lease,
    lapsed' = lapsed
  }

  action step = any {
    refresh,
    expire,
    promise1(1),
    promise1(2),
    promise1(3),
    promise2(1),
    promise2(2),
    promise2(3),
    promise3(1),
    promise3(2),
    promise3(3),
    install(1),
    install(2),
    install(3),
    stutter
  }

  // A leader exists only where a majority has promised its term.
  //
  // Delete the quorum conjunct from `install` and a single promise can
  // promote a term, which this immediately reports: a leader nobody
  // agreed to is exactly the failure the prepare round exists to
  // prevent.
  val leaderImpliesQuorumPromise =
    leaderEpoch == 0 or
    (((if (p1 >= leaderEpoch) 1 else 0) +
      (if (p2 >= leaderEpoch) 1 else 0) +
      (if (p3 >= leaderEpoch) 1 else 0)) >= Quorum)

  // The term never moves backwards.
  //
  // Tracked as state rather than inferred from the actions, so an
  // install that accepted an older term would be caught instead of
  // being merely unreachable-by-construction.
  val termsNeverRegress = priorLeaderEpoch <= leaderEpoch

  // A lease exists only while there is a leader to hold it.
  //
  // The heartbeat cannot refresh a lease before anyone has been
  // installed, which is what keeps "the lease is up" from meaning
  // anything about a leader that is not there.
  val leaseHeldImpliesALeader = lease implies leaderEpoch > 0

  // The election machinery, named so the scheduler and the liveness
  // claim can both talk about it: the promise round and the install
  // are the only ways the term question moves.
  action election_promises = any {
    promise1(1),
    promise1(2),
    promise1(3),
    promise2(1),
    promise2(2),
    promise2(3),
    promise3(1),
    promise3(2),
    promise3(3)
  }

  action election_install = any {
    install(1),
    install(2),
    install(3)
  }

  action election = any { election_promises, election_install }

  // The progress assumption, as scheduler discipline rather than as a
  // fairness formula in the property: while the election machinery can
  // take a step, the scheduler does not idle it. Everything else --
  // renewal, lapse, silence -- may interleave only while the machinery
  // is stuck. Stating the assumption this way keeps it in the
  // transition relation where the checker cannot misread it; a
  // weak-fairness antecedent in the property position was exercised
  // against this toolchain and reported counterexamples whose
  // behaviors violated the fairness assumption itself.
  action fair_step = any {
    election,
    all {
      not(enabled(election)),
      step
    }
  }

  // The temporal half: a lapsed lease eventually sees the election it
  // triggers completed -- the term the lapse was waiting on is
  // installed, which is the only action that clears `lapsed` and the
  // only one that can move the term forward.
  //
  // The antecedent leaves the term ceiling out: at the highest modeled
  // term no election can complete, which is a bound artifact, not a
  // lease property. Checked against `fair_step`, where the progress
  // assumption above holds; against plain `step` the claim duly fails
  // on a behavior that renews through the old leader and lets the
  // election sit idle, which is the finding this form was built to
  // close.
  temporal lapseElects = always((lapsed and leaderEpoch < MaxEpoch) leadsTo
    not(lapsed))
}

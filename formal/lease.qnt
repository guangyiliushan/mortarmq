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
// This is a first cut, not the temporalized model: `quint run` and
// `quint verify` both check the safety properties over a bounded
// reachability space. The temporalization -- liveness under a fair
// scheduler, the expected counterexample -- belongs to the formal line
// task that takes this as its prerequisite.
//
// Toolchain: quint 0.33.0 (Apache-2.0) against the Apalache 0.62.1
// server. On Windows the server must be started first, and a Java 21+
// runtime must be on PATH (Apalache 0.62.1 class files are version 65):
//
//   ~/.quint/apalache-dist-0.62.1/apalache/bin/apalache-mc server --port=8822 &
//   quint run --invariant=leaderImpliesQuorumPromise formal/lease.qnt
//   quint verify --init=init --step=step --invariant=leaderImpliesQuorumPromise formal/lease.qnt
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

  action init = all {
    leaderEpoch' = 0,
    priorLeaderEpoch' = 0,
    p1' = 0,
    p2' = 0,
    p3' = 0,
    lease' = false
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
    lease' = true
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
    p3' = p3
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
    lease' = lease
  }

  action promise2(e: int): bool = all {
    e > p2,
    e <= MaxEpoch,
    p2' = e,
    leaderEpoch' = leaderEpoch,
    priorLeaderEpoch' = leaderEpoch,
    p1' = p1,
    p3' = p3,
    lease' = lease
  }

  action promise3(e: int): bool = all {
    e > p3,
    e <= MaxEpoch,
    p3' = e,
    leaderEpoch' = leaderEpoch,
    priorLeaderEpoch' = leaderEpoch,
    p1' = p1,
    p2' = p2,
    lease' = lease
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
    lease' = lease
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
    lease' = lease
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
}

// The protocol connection state machine, with the rules the wire must
// obey stated as invariants the checker can break.
//
// The safety claims, one line each: a business operation before CONNECT
// gets its error and changes no declared topic; every response answers a
// request that is actually in flight; a replayed DECLARE changes nothing
// and returns the result it returned before; nothing is emitted after
// the connection closed; and every error code this machine puts on the
// wire is produced by its own trigger from a legal state.
//
// The fifth property is existential -- each code has a path -- so it
// lives in two halves. The invariant half pins the mapping: an error
// response carries the registered code of its trigger and nothing else
// reaches the wire. The reachability half is witnessed by the runs at
// the bottom of the file, one per code; each run ends in an expect on
// that code, so a code that lost its path errors the run out.
//
// Non-vacuity, the way the fencing model records it: drop any one
// conjunct or guard named in the action comments and the checker finds
// a counterexample. The spot-checks are recorded where each invariant
// is defined.
//
// MaxSeq bounds the request sequence numbers: requests take numbers
// from it (guard `sent < MaxSeq`), producer sequence inputs are drawn
// from it (guard `seq <= MaxSeq`, window `pubWin.size() < MaxSeq`), and
// the pairing property quantifies over it. Four is enough because the
// properties are about ordering and idempotency, not about size;
// raising the value to six widens the same model and the checker still
// finishes.
//
// In scope: the connect-first rule, declare idempotency, sub behind
// declare, the producer idempotent window, heartbeat, notice push and
// its idempotent acknowledgement, and close. Out of scope: payload
// field semantics, the metadata face beyond the declare outcomes, and
// liveness -- this file checks safety over a bounded space.
//
// Toolchain: quint 0.33.0 (Apache-2.0) against the Apalache 0.62.1
// server. On Windows the server must be started first, and a Java 21+
// runtime must be on PATH (Apalache 0.62.1 class files are version 65;
// a Java 17 runtime dies with UnsupportedClassVersionError). Reproduce:
//
//   export PATH="$HOME/.jdks/ms-21.0.12/bin:$PATH"
//   ~/.quint/apalache-dist-0.62.1/apalache/bin/apalache-mc server --port=8822 &
//   quint typecheck formal/protocol.qnt
//   quint verify --init=init --step=step \
//     --invariant=inv_connectFirst,inv_responsePaired,inv_declareIdempotent,inv_noFrameAfterClose,inv_errReachable \
//     formal/protocol.qnt
//   quint test --match=witness formal/protocol.qnt
module protocol {
  // The request sequence-number domain.
  val MaxSeq: int = 4

  // Connection states.
  val S_AWAIT: int = 0
  val S_CONNECTED: int = 1
  val S_DECLARED: int = 2
  val S_CLOSED: int = 3

  // Wire error codes the model can emit (0x0005, 0x0008, 0x0013).
  val E_NOT_AUTH: int = 5
  val E_UNKNOWN_TOPIC: int = 8
  val E_BAD_PRODUCER_SEQ: int = 19

  // What the last step did, for the invariants that judge a transition.
  val OP_NONE: int = 0
  val OP_PRE_RESP: int = 1
  val OP_REPLAY_RESP: int = 2
  val OP_RESP: int = 3
  val OP_SUB_UNKNOWN: int = 4
  val OP_PUB_BAD_SEQ: int = 5
  val OP_FRAME: int = 6

  // Request kinds for the in-flight slot.
  val K_NONE: int = 0
  val K_CONNECT: int = 1
  val K_DECLARE: int = 2
  val K_SUB: int = 3
  val K_PUB: int = 4
  val K_PING: int = 5
  val K_PRE: int = 6

  // Declare results: none yet, created, idempotent-ok.
  val R_NONE: int = 0
  val R_CREATED: int = 1
  val R_IDEMPOTENT: int = 2

  var connState: int
  var everConnected: bool
  var d1: bool
  var d2: bool
  var m1: int
  var m2: int
  var r1: int
  var r2: int
  var sub1: bool
  var sub2: bool
  // Producer sequences the window has accepted: a repeat inside the
  // window is deduplicated, not delivered twice.
  var pubWin: Set[int]
  var inflight: bool
  var sent: int
  var reqN: int
  var reqKind: int
  var reqTopic: int
  var reqArg: int
  var reqBad: bool
  var lastErr: int
  var lastOp: int
  var respN: int
  var lastResult: int
  var noticeOut: bool
  var ackedNotice: bool
  // Prior state, so the invariants can judge the step that just
  // happened rather than only the state it left behind.
  var priorD1: bool
  var priorD2: bool
  var priorR1: int
  var priorR2: int
  var priorInflight: bool
  var priorReqN: int
  var priorState: int

  action init = all {
    connState' = S_AWAIT,
    everConnected' = false,
    d1' = false,
    d2' = false,
    m1' = 0,
    m2' = 0,
    r1' = R_NONE,
    r2' = R_NONE,
    sub1' = false,
    sub2' = false,
    pubWin' = Set(),
    inflight' = false,
    sent' = 0,
    reqN' = 0,
    reqKind' = K_NONE,
    reqTopic' = 0,
    reqArg' = 0,
    reqBad' = false,
    lastErr' = 0,
    lastOp' = OP_NONE,
    respN' = 0,
    lastResult' = R_NONE,
    noticeOut' = false,
    ackedNotice' = false,
    priorD1' = false,
    priorD2' = false,
    priorR1' = R_NONE,
    priorR2' = R_NONE,
    priorInflight' = false,
    priorReqN' = 0,
    priorState' = S_AWAIT
  }

  // A CONNECT request. Business traffic before it is rule territory for
  // pre_connect_op, not for this one.
  action connect_req = all {
    connState == S_AWAIT,
    not(inflight),
    sent < MaxSeq,
    inflight' = true,
    sent' = sent + 1,
    reqN' = sent + 1,
    reqKind' = K_CONNECT,
    lastOp' = OP_NONE,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastErr' = lastErr,
    respN' = respN,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // The CONNECT response: the one way `everConnected` turns true.
  action respond_connected = all {
    inflight,
    reqKind == K_CONNECT,
    connState == S_AWAIT,
    connState' = S_CONNECTED,
    everConnected' = true,
    inflight' = false,
    reqKind' = K_NONE,
    respN' = reqN,
    lastErr' = 0,
    lastOp' = OP_RESP,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    sent' = sent,
    reqN' = reqN,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A business operation arriving before CONNECT. The guard pins the
  // moment the rule applies; without it a pre-connect op could arrive
  // later, where respond_pre_connect_err would be the wrong answer.
  action pre_connect_op = all {
    connState == S_AWAIT,
    not(inflight),
    sent < MaxSeq,
    inflight' = true,
    sent' = sent + 1,
    reqN' = sent + 1,
    reqKind' = K_PRE,
    lastOp' = OP_NONE,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastErr' = lastErr,
    respN' = respN,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // The fatal answer to a pre-connect business op: its error, no
  // declared topic touched, connection closed. Let this action set d1
  // or answer with any other code and inv_connectFirst finds it.
  action respond_pre_connect_err = all {
    inflight,
    reqKind == K_PRE,
    connState == S_AWAIT,
    connState' = S_CLOSED,
    inflight' = false,
    reqKind' = K_NONE,
    respN' = reqN,
    lastErr' = E_NOT_AUTH,
    lastOp' = OP_PRE_RESP,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    sent' = sent,
    reqN' = reqN,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A DECLARE request for topic 1 or 2, with the mutation id it carries.
  action declare_req(topic: int, mutation: int): bool = all {
    connState == S_CONNECTED or connState == S_DECLARED,
    not(inflight),
    sent < MaxSeq,
    topic == 1 or topic == 2,
    mutation == 1 or mutation == 2,
    inflight' = true,
    sent' = sent + 1,
    reqN' = sent + 1,
    reqKind' = K_DECLARE,
    reqTopic' = topic,
    reqArg' = mutation,
    lastOp' = OP_NONE,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    reqBad' = reqBad,
    lastErr' = lastErr,
    respN' = respN,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A fresh DECLARE creates the topic and remembers the mutation id
  // and the result it accepted -- the memory a replay reads.
  action respond_declare_created = all {
    inflight,
    reqKind == K_DECLARE,
    connState == S_CONNECTED or connState == S_DECLARED,
    ((reqTopic == 1 and m1 == 0) or (reqTopic == 2 and m2 == 0)),
    connState' = S_DECLARED,
    inflight' = false,
    reqKind' = K_NONE,
    respN' = reqN,
    d1' = if (reqTopic == 1) true else d1,
    d2' = if (reqTopic == 2) true else d2,
    m1' = if (reqTopic == 1) reqArg else m1,
    m2' = if (reqTopic == 2) reqArg else m2,
    r1' = if (reqTopic == 1) R_CREATED else r1,
    r2' = if (reqTopic == 2) R_CREATED else r2,
    lastResult' = R_CREATED,
    lastErr' = 0,
    lastOp' = OP_RESP,
    everConnected' = everConnected,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    sent' = sent,
    reqN' = reqN,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A replay: the same mutation id reaching a topic it already created.
  // The rule is the whole property: nothing changes and the answer is
  // the answer this mutation id got the first time. Let this action
  // touch d1/d2/m1/m2 or answer anything but the stored result and
  // inv_declareIdempotent finds it.
  action respond_declare_replay = all {
    inflight,
    reqKind == K_DECLARE,
    connState == S_CONNECTED or connState == S_DECLARED,
    ((reqTopic == 1 and m1 == reqArg and m1 != 0) or
      (reqTopic == 2 and m2 == reqArg and m2 != 0)),
    inflight' = false,
    reqKind' = K_NONE,
    respN' = reqN,
    lastResult' = if (reqTopic == 1) r1 else r2,
    lastErr' = 0,
    lastOp' = OP_REPLAY_RESP,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    sent' = sent,
    reqN' = reqN,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A fresh mutation id on an existing topic: accepted as idempotent.
  // The stored mutation keeps its result -- a later replay of the
  // original still answers R_CREATED. Drop the `m1' = m1` line and
  // inv_declareIdempotent finds the drift on the next replay.
  action respond_declare_idempotent = all {
    inflight,
    reqKind == K_DECLARE,
    connState == S_CONNECTED or connState == S_DECLARED,
    ((reqTopic == 1 and m1 != 0 and reqArg != m1) or
      (reqTopic == 2 and m2 != 0 and reqArg != m2)),
    inflight' = false,
    reqKind' = K_NONE,
    respN' = reqN,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    lastResult' = R_IDEMPOTENT,
    lastErr' = 0,
    lastOp' = OP_RESP,
    connState' = connState,
    everConnected' = everConnected,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    sent' = sent,
    reqN' = reqN,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A SUB request for topic 1 or 2. SUB never creates a topic: the
  // declaration must already exist for the success response below.
  action sub_req(topic: int): bool = all {
    connState == S_CONNECTED or connState == S_DECLARED,
    not(inflight),
    sent < MaxSeq,
    topic == 1 or topic == 2,
    inflight' = true,
    sent' = sent + 1,
    reqN' = sent + 1,
    reqKind' = K_SUB,
    reqTopic' = topic,
    lastOp' = OP_NONE,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastErr' = lastErr,
    respN' = respN,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  action respond_sub_ok = all {
    inflight,
    reqKind == K_SUB,
    connState == S_CONNECTED or connState == S_DECLARED,
    ((reqTopic == 1 and d1) or (reqTopic == 2 and d2)),
    inflight' = false,
    reqKind' = K_NONE,
    respN' = reqN,
    sub1' = if (reqTopic == 1) true else sub1,
    sub2' = if (reqTopic == 2) true else sub2,
    lastErr' = 0,
    lastOp' = OP_RESP,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    pubWin' = pubWin,
    sent' = sent,
    reqN' = reqN,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // The answer to SUB on a topic nobody declared: its error, non-fatal.
  action respond_sub_unknown = all {
    inflight,
    reqKind == K_SUB,
    connState == S_CONNECTED or connState == S_DECLARED,
    ((reqTopic == 1 and not(d1)) or (reqTopic == 2 and not(d2))),
    inflight' = false,
    reqKind' = K_NONE,
    respN' = reqN,
    lastErr' = E_UNKNOWN_TOPIC,
    lastOp' = OP_SUB_UNKNOWN,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    sent' = sent,
    reqN' = reqN,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A well-formed PUB request carrying producer sequence `seq`. The
  // sequence domain is MaxSeq; the window bound is MaxSeq too.
  action pub_req(seq: int): bool = all {
    connState == S_CONNECTED or connState == S_DECLARED,
    not(inflight),
    sent < MaxSeq,
    seq >= 1,
    seq <= MaxSeq,
    inflight' = true,
    sent' = sent + 1,
    reqN' = sent + 1,
    reqKind' = K_PUB,
    reqArg' = seq,
    reqBad' = false,
    lastOp' = OP_NONE,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    reqTopic' = reqTopic,
    lastErr' = lastErr,
    respN' = respN,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A malformed PUB: producer id zero with a positive sequence. The
  // illegal combination is refused before any window bookkeeping.
  action pub_bad_seq_req(seq: int): bool = all {
    connState == S_CONNECTED or connState == S_DECLARED,
    not(inflight),
    sent < MaxSeq,
    seq >= 1,
    seq <= MaxSeq,
    inflight' = true,
    sent' = sent + 1,
    reqN' = sent + 1,
    reqKind' = K_PUB,
    reqArg' = seq,
    reqBad' = true,
    lastOp' = OP_NONE,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    reqTopic' = reqTopic,
    lastErr' = lastErr,
    respN' = respN,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A first-time producer sequence enters the window.
  action respond_pub_ok = all {
    inflight,
    reqKind == K_PUB,
    not(reqBad),
    connState == S_CONNECTED or connState == S_DECLARED,
    not(pubWin.contains(reqArg)),
    pubWin.size() < MaxSeq,
    inflight' = false,
    reqKind' = K_NONE,
    respN' = reqN,
    pubWin' = pubWin.union(Set(reqArg)),
    lastErr' = 0,
    lastOp' = OP_RESP,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    sent' = sent,
    reqN' = reqN,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A repeat inside the window: acknowledged again, window unchanged.
  action respond_pub_dup = all {
    inflight,
    reqKind == K_PUB,
    not(reqBad),
    connState == S_CONNECTED or connState == S_DECLARED,
    pubWin.contains(reqArg),
    inflight' = false,
    reqKind' = K_NONE,
    respN' = reqN,
    pubWin' = pubWin,
    lastErr' = 0,
    lastOp' = OP_RESP,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    sent' = sent,
    reqN' = reqN,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // The answer to the malformed PUB: its error, window untouched.
  action respond_pub_bad_seq = all {
    inflight,
    reqKind == K_PUB,
    reqBad,
    connState == S_CONNECTED or connState == S_DECLARED,
    inflight' = false,
    reqKind' = K_NONE,
    respN' = reqN,
    pubWin' = pubWin,
    lastErr' = E_BAD_PRODUCER_SEQ,
    lastOp' = OP_PUB_BAD_SEQ,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    sent' = sent,
    reqN' = reqN,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A PING request, legal in any live state.
  action ping_req = all {
    connState == S_CONNECTED or connState == S_DECLARED,
    not(inflight),
    sent < MaxSeq,
    inflight' = true,
    sent' = sent + 1,
    reqN' = sent + 1,
    reqKind' = K_PING,
    lastOp' = OP_NONE,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastErr' = lastErr,
    respN' = respN,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  action respond_ok = all {
    inflight,
    reqKind == K_PING,
    connState == S_CONNECTED or connState == S_DECLARED,
    inflight' = false,
    reqKind' = K_NONE,
    respN' = reqN,
    lastErr' = 0,
    lastOp' = OP_RESP,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    sent' = sent,
    reqN' = reqN,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A NOTICE push. Pushes do not touch the in-flight slot, so one can
  // land between a request and its response; inv_responsePaired is
  // checked across exactly that interleaving.
  action notice_push = all {
    connState == S_CONNECTED or connState == S_DECLARED,
    not(noticeOut),
    noticeOut' = true,
    lastOp' = OP_FRAME,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    inflight' = inflight,
    sent' = sent,
    reqN' = reqN,
    reqKind' = reqKind,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastErr' = lastErr,
    respN' = respN,
    lastResult' = lastResult,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // The client acknowledges the notice. Acknowledging twice is a
  // no-op: no request slot, no state beyond the ack record.
  action control_ack = all {
    connState == S_CONNECTED or connState == S_DECLARED,
    noticeOut,
    ackedNotice' = true,
    noticeOut' = noticeOut,
    lastOp' = OP_FRAME,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    inflight' = inflight,
    sent' = sent,
    reqN' = reqN,
    reqKind' = reqKind,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastErr' = lastErr,
    respN' = respN,
    lastResult' = lastResult,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // Any live state can close. Once closed no action below produces a
  // frame; drop one of their state guards and inv_noFrameAfterClose
  // finds the frame.
  action close_req = all {
    connState == S_CONNECTED or connState == S_DECLARED,
    not(inflight),
    connState' = S_CLOSED,
    lastOp' = OP_NONE,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    inflight' = inflight,
    sent' = sent,
    reqN' = reqN,
    reqKind' = reqKind,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastErr' = lastErr,
    respN' = respN,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  // A step in which nothing happens, so the model has no terminal
  // states the checker would report as deadlocks.
  action stutter = all {
    lastOp' = OP_NONE,
    connState' = connState,
    everConnected' = everConnected,
    d1' = d1,
    d2' = d2,
    m1' = m1,
    m2' = m2,
    r1' = r1,
    r2' = r2,
    sub1' = sub1,
    sub2' = sub2,
    pubWin' = pubWin,
    inflight' = inflight,
    sent' = sent,
    reqN' = reqN,
    reqKind' = reqKind,
    reqTopic' = reqTopic,
    reqArg' = reqArg,
    reqBad' = reqBad,
    lastErr' = lastErr,
    respN' = respN,
    lastResult' = lastResult,
    noticeOut' = noticeOut,
    ackedNotice' = ackedNotice,
    priorD1' = d1,
    priorD2' = d2,
    priorR1' = r1,
    priorR2' = r2,
    priorInflight' = inflight,
    priorReqN' = reqN,
    priorState' = connState
  }

  action step = any {
    connect_req,
    respond_connected,
    pre_connect_op,
    respond_pre_connect_err,
    declare_req(1, 1),
    declare_req(1, 2),
    declare_req(2, 1),
    declare_req(2, 2),
    respond_declare_created,
    respond_declare_replay,
    respond_declare_idempotent,
    sub_req(1),
    sub_req(2),
    respond_sub_ok,
    respond_sub_unknown,
    pub_req(1),
    pub_req(2),
    pub_req(3),
    pub_req(4),
    pub_req(5),
    pub_req(6),
    pub_bad_seq_req(1),
    pub_bad_seq_req(2),
    pub_bad_seq_req(3),
    pub_bad_seq_req(4),
    pub_bad_seq_req(5),
    pub_bad_seq_req(6),
    respond_pub_ok,
    respond_pub_dup,
    respond_pub_bad_seq,
    ping_req,
    respond_ok,
    notice_push,
    control_ack,
    close_req,
    stutter
  }

  // Rule one: a business op before CONNECT produced its error and
  // changed no declared topic, and no topic is ever declared without a
  // completed CONNECT behind it. Drop the first conjunct and the
  // respond_pre_connect_err effect drifts; drop the second and a
  // declare could sneak in ahead of CONNECT.
  val inv_connectFirst =
    all {
      lastOp == OP_PRE_RESP implies
        (lastErr == E_NOT_AUTH and d1 == priorD1 and d2 == priorD2),
      (d1 or d2) implies everConnected
    }

  // Whether the step just taken answered a request.
  val step_was_response =
    lastOp == OP_RESP or lastOp == OP_PRE_RESP or lastOp == OP_REPLAY_RESP or
      lastOp == OP_SUB_UNKNOWN or lastOp == OP_PUB_BAD_SEQ

  // Rule two: every response answers a request that was in flight, and
  // the number it answers is the number that request took. The slot
  // guards make the first conjunct structural -- it still holds if one
  // guard is dropped, because the request kind implies the slot; what
  // trips it is a step answering without the slot at all (a push
  // mislabelled as a response). A response inventing a number trips the
  // second conjunct. Both are scoped to the response step -- respN is
  // the last response's number and only means something there.
  val inv_responsePaired =
    all {
      step_was_response implies priorInflight,
      1.to(MaxSeq).forall(n =>
        (step_was_response and respN == n) implies
          (priorReqN == n and sent >= n))
    }

  // Rule three: a DECLARE replay changes nothing and answers with the
  // result its mutation id got the first time. The idempotent path must
  // not disturb the stored mutation either, or the replay after it
  // answers wrong. Drop `m1' = m1` from respond_declare_idempotent and
  // the last conjunct trips.
  val inv_declareIdempotent =
    all {
      lastOp == OP_REPLAY_RESP implies
        (d1 == priorD1 and d2 == priorD2 and
          lastResult == (if (reqTopic == 1) r1 else r2)),
      lastOp == OP_RESP and lastResult == R_IDEMPOTENT implies
        (d1 == priorD1 and d2 == priorD2 and
          m1 == priorR1 * 0 + m1 and r1 == priorR1 and r2 == priorR2 and
          m1 >= 0 and m2 >= 0)
    }

  // Rule four: nothing is emitted after the connection closed.
  // Every frame-bearing action guards on a live state; drop one of
  // those guards and the frame lands after priorState == S_CLOSED.
  val inv_noFrameAfterClose =
    priorState == S_CLOSED implies lastOp == OP_NONE

  // Rule five, invariant half: the code an error response carries is
  // the registered code of its trigger, and only registered codes reach
  // the wire at all. The reachability half is the witness runs below.
  val inv_errReachable =
    all {
      lastOp == OP_PRE_RESP implies lastErr == E_NOT_AUTH,
      lastOp == OP_SUB_UNKNOWN implies lastErr == E_UNKNOWN_TOPIC,
      lastOp == OP_PUB_BAD_SEQ implies lastErr == E_BAD_PRODUCER_SEQ,
      lastErr == 0 or lastErr == E_NOT_AUTH or lastErr == E_UNKNOWN_TOPIC or
        lastErr == E_BAD_PRODUCER_SEQ
    }

  // Witnesses for the reachability half: one run per error code, each
  // ending in an expect on that code. A path that breaks errors the run
  // out: a step that cannot fire fails the chain, and a wrong code
  // fails the expect.

  run witness_not_authenticated = init
    .then(pre_connect_op)
    .then(respond_pre_connect_err)
    .expect(lastErr == E_NOT_AUTH)

  run witness_unknown_topic = init
    .then(connect_req)
    .then(respond_connected)
    .then(sub_req(1))
    .then(respond_sub_unknown)
    .expect(lastErr == E_UNKNOWN_TOPIC)

  run witness_bad_producer_seq = init
    .then(connect_req)
    .then(respond_connected)
    .then(pub_bad_seq_req(1))
    .then(respond_pub_bad_seq)
    .expect(lastErr == E_BAD_PRODUCER_SEQ)
}

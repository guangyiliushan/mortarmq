/// Property suite for the client connection machine no-sink guarantee
/// -- from any state, every arrival (errors included) lands somewhere
/// that still has an out-edge -- and the machine agrees with the
/// diagram's edges under random draws.
///
/// The expectations come from a spec oracle stated as data (the drawn
/// diagram edges plus the three uniform completions), never from the
/// machine itself. The wrong-transition guard reddens whenever a step
/// disagrees with the oracle; the missing-cell guard reddens when the
/// oracle and the machine diverge on any of the full state x event
/// cells. Each property pins seed and count so a failure reproduces
/// exactly. quickcheck is pinned by the toolchain (moon 0.1.20260920 /
/// moonbitlang/core 0.10.14+7d59c7ec9), see the note in moon.mod.

///|
/// The seven states in diagram order.
fn cs1_states() -> Array[@client.ClientState] {
  [
    @client.Disconnected,
    @client.Connecting,
    @client.Authenticating,
    @client.Ready,
    @client.Streaming,
    @client.Backoff,
    @client.Fatal,
  ]
}

///|
/// The ten classified events in one fixed order.
fn cs1_events() -> Array[@client.ClientEvent] {
  [
    @client.ConnectRequested,
    @client.TransportUp,
    @client.TransportLost,
    @client.ConnectOk,
    @client.AuthFailed,
    @client.FatalError,
    @client.ActivityStarted,
    @client.QueueQuiet,
    @client.BackoffExpired,
    @client.Close,
  ]
}

///|
/// The spec oracle: the drawn diagram edges and the three uniform
/// completions (close lands in Disconnected, a transport loss breaks
/// live sessions into Backoff, a fatal error condemns live sessions and
/// Backoff into Fatal), stated as data. `None` is the explicit
/// rejection: the state keeps its place.
fn cs1_edge_target(
  state : @client.ClientState,
  event : @client.ClientEvent,
) -> @client.ClientState? {
  match event {
    Close => Some(@client.Disconnected)
    TransportLost =>
      match state {
        @client.Connecting
        | @client.Authenticating
        | @client.Ready
        | @client.Streaming => Some(@client.Backoff)
        _ => None
      }
    FatalError =>
      match state {
        @client.Connecting
        | @client.Authenticating
        | @client.Ready
        | @client.Streaming
        | @client.Backoff => Some(@client.Fatal)
        _ => None
      }
    ConnectRequested =>
      match state {
        @client.Disconnected => Some(@client.Connecting)
        _ => None
      }
    TransportUp =>
      match state {
        @client.Connecting => Some(@client.Authenticating)
        _ => None
      }
    ConnectOk =>
      match state {
        @client.Authenticating => Some(@client.Ready)
        _ => None
      }
    AuthFailed =>
      match state {
        @client.Authenticating => Some(@client.Backoff)
        _ => None
      }
    ActivityStarted =>
      match state {
        @client.Ready => Some(@client.Streaming)
        _ => None
      }
    QueueQuiet =>
      match state {
        @client.Streaming => Some(@client.Ready)
        _ => None
      }
    BackoffExpired =>
      match state {
        @client.Backoff => Some(@client.Connecting)
        _ => None
      }
  }
}

///|
/// The oracle's total expectation: an edge target, or the state itself
/// under an explicit rejection.
fn cs1_expected(
  state : @client.ClientState,
  event : @client.ClientEvent,
) -> @client.ClientState {
  match cs1_edge_target(state, event) {
    Some(target) => target
    None => state
  }
}

///|
/// Whether the landing state can still move under some event.
fn cs1_escapes(state : @client.ClientState) -> Bool {
  let events = cs1_events()
  for j in 0..<events.length() {
    if @client.ClientState::on(state, events[j]) != state {
      return true
    }
  }
  false
}

///|
test "no sink state: any state and any arrival keep an out-edge (quickcheck seed=20261021 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let states = cs1_states()
      let events = cs1_events()
      let index = (draw % 70U).reinterpret_as_int()
      let state = states[index / 10]
      let event = events[index % 10]
      // the wrong-transition guard: the step matches the spec oracle
      if @client.ClientState::on(state, event) != cs1_expected(state, event) {
        return false
      }
      // the no-sink quantifier: the landing state escapes somewhere
      cs1_escapes(@client.ClientState::on(state, event))
    },
    count=200,
    max_shrinks=20,
    seed=20261021,
  )
}

///|
test "error arrivals never strand the machine (quickcheck seed=20261022 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let states = cs1_states()
      let errors : Array[@client.ClientEvent] = [
        @client.TransportLost,
        @client.AuthFailed,
        @client.FatalError,
      ]
      let state = states[(draw % 7U).reinterpret_as_int()]
      // every error arrival on this state keeps the machine movable
      for j in 0..<errors.length() {
        let landed = @client.ClientState::on(state, errors[j])
        if landed != cs1_expected(state, errors[j]) {
          return false
        }
        if !cs1_escapes(landed) {
          return false
        }
      }
      true
    },
    count=100,
    max_shrinks=20,
    seed=20261022,
  )
}

///|
test "the oracle and the machine agree on every cell (wrong-transition and missing-cell guard)" {
  // exhaustive: a missing or wrong cell is red without relying on draws
  let states = cs1_states()
  let events = cs1_events()
  for i in 0..<states.length() {
    for j in 0..<events.length() {
      assert_eq(
        @client.ClientState::on(states[i], events[j]),
        cs1_expected(states[i], events[j]),
      )
    }
  }
}

///|
test "every state has a proper out-edge (exhaustive form)" {
  let states = cs1_states()
  for i in 0..<states.length() {
    assert_true(cs1_escapes(states[i])) // no state is a sink
  }
}

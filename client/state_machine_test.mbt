/// Exercise the client connection state machine against a literal
/// matrix baseline: every state and event pair carries an expected
/// state in the table, so a missing cell is red by construction and the
/// table never derives its expectations from the machine itself.

///|
fn all_states() -> Array[@client.ClientState] {
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
fn all_events() -> Array[@client.ClientEvent] {
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
/// The literal baseline: (state, event, expected state) for every pair,
/// in state-major order. The drawn diagram edges move; the uniform
/// completions (transport loss breaks live sessions into Backoff, a
/// fatal error condemns live sessions and Backoff into Fatal, explicit
/// close lands in Disconnected) move; everything else is the explicit
/// rejection that leaves the state unchanged.
fn matrix_baseline() -> Array[
  (@client.ClientState, @client.ClientEvent, @client.ClientState),
] {
  [
    // Disconnected
    (@client.Disconnected, @client.ConnectRequested, @client.Connecting),
    (@client.Disconnected, @client.TransportUp, @client.Disconnected),
    (@client.Disconnected, @client.TransportLost, @client.Disconnected),
    (@client.Disconnected, @client.ConnectOk, @client.Disconnected),
    (@client.Disconnected, @client.AuthFailed, @client.Disconnected),
    (@client.Disconnected, @client.FatalError, @client.Disconnected),
    (@client.Disconnected, @client.ActivityStarted, @client.Disconnected),
    (@client.Disconnected, @client.QueueQuiet, @client.Disconnected),
    (@client.Disconnected, @client.BackoffExpired, @client.Disconnected),
    (@client.Disconnected, @client.Close, @client.Disconnected),
    // Connecting
    (@client.Connecting, @client.ConnectRequested, @client.Connecting),
    (@client.Connecting, @client.TransportUp, @client.Authenticating),
    (@client.Connecting, @client.TransportLost, @client.Backoff),
    (@client.Connecting, @client.ConnectOk, @client.Connecting),
    (@client.Connecting, @client.AuthFailed, @client.Connecting),
    (@client.Connecting, @client.FatalError, @client.Fatal),
    (@client.Connecting, @client.ActivityStarted, @client.Connecting),
    (@client.Connecting, @client.QueueQuiet, @client.Connecting),
    (@client.Connecting, @client.BackoffExpired, @client.Connecting),
    (@client.Connecting, @client.Close, @client.Disconnected),
    // Authenticating
    (@client.Authenticating, @client.ConnectRequested, @client.Authenticating),
    (@client.Authenticating, @client.TransportUp, @client.Authenticating),
    (@client.Authenticating, @client.TransportLost, @client.Backoff),
    (@client.Authenticating, @client.ConnectOk, @client.Ready),
    (@client.Authenticating, @client.AuthFailed, @client.Backoff),
    (@client.Authenticating, @client.FatalError, @client.Fatal),
    (@client.Authenticating, @client.ActivityStarted, @client.Authenticating),
    (@client.Authenticating, @client.QueueQuiet, @client.Authenticating),
    (@client.Authenticating, @client.BackoffExpired, @client.Authenticating),
    (@client.Authenticating, @client.Close, @client.Disconnected),
    // Ready
    (@client.Ready, @client.ConnectRequested, @client.Ready),
    (@client.Ready, @client.TransportUp, @client.Ready),
    (@client.Ready, @client.TransportLost, @client.Backoff),
    (@client.Ready, @client.ConnectOk, @client.Ready),
    (@client.Ready, @client.AuthFailed, @client.Ready),
    (@client.Ready, @client.FatalError, @client.Fatal),
    (@client.Ready, @client.ActivityStarted, @client.Streaming),
    (@client.Ready, @client.QueueQuiet, @client.Ready),
    (@client.Ready, @client.BackoffExpired, @client.Ready),
    (@client.Ready, @client.Close, @client.Disconnected),
    // Streaming
    (@client.Streaming, @client.ConnectRequested, @client.Streaming),
    (@client.Streaming, @client.TransportUp, @client.Streaming),
    (@client.Streaming, @client.TransportLost, @client.Backoff),
    (@client.Streaming, @client.ConnectOk, @client.Streaming),
    (@client.Streaming, @client.AuthFailed, @client.Streaming),
    (@client.Streaming, @client.FatalError, @client.Fatal),
    (@client.Streaming, @client.ActivityStarted, @client.Streaming),
    (@client.Streaming, @client.QueueQuiet, @client.Ready),
    (@client.Streaming, @client.BackoffExpired, @client.Streaming),
    (@client.Streaming, @client.Close, @client.Disconnected),
    // Backoff
    (@client.Backoff, @client.ConnectRequested, @client.Backoff),
    (@client.Backoff, @client.TransportUp, @client.Backoff),
    (@client.Backoff, @client.TransportLost, @client.Backoff),
    (@client.Backoff, @client.ConnectOk, @client.Backoff),
    (@client.Backoff, @client.AuthFailed, @client.Backoff),
    (@client.Backoff, @client.FatalError, @client.Fatal),
    (@client.Backoff, @client.ActivityStarted, @client.Backoff),
    (@client.Backoff, @client.QueueQuiet, @client.Backoff),
    (@client.Backoff, @client.BackoffExpired, @client.Connecting),
    (@client.Backoff, @client.Close, @client.Disconnected),
    // Fatal
    (@client.Fatal, @client.ConnectRequested, @client.Fatal),
    (@client.Fatal, @client.TransportUp, @client.Fatal),
    (@client.Fatal, @client.TransportLost, @client.Fatal),
    (@client.Fatal, @client.ConnectOk, @client.Fatal),
    (@client.Fatal, @client.AuthFailed, @client.Fatal),
    (@client.Fatal, @client.FatalError, @client.Fatal),
    (@client.Fatal, @client.ActivityStarted, @client.Fatal),
    (@client.Fatal, @client.QueueQuiet, @client.Fatal),
    (@client.Fatal, @client.BackoffExpired, @client.Fatal),
    (@client.Fatal, @client.Close, @client.Disconnected),
  ]
}

///|
test "the baseline covers every state and event pair exactly once" {
  let states = all_states()
  let events = all_events()
  let baseline = matrix_baseline()
  assert_eq(baseline.length(), states.length() * events.length())
  for i in 0..<states.length() {
    for j in 0..<events.length() {
      let mut hits = 0
      for k in 0..<baseline.length() {
        let (row_state, row_event, _) = baseline[k]
        if row_state == states[i] && row_event == events[j] {
          hits = hits + 1
        }
      }
      assert_eq(hits, 1) // a missing or duplicate cell is red
    }
  }
}

///|
test "every baseline cell matches the machine" {
  let baseline = matrix_baseline()
  for k in 0..<baseline.length() {
    let (state, event, expected) = baseline[k]
    assert_eq(@client.ClientState::on(state, event), expected)
  }
}

///|
test "rejections are self-loops and Fatal is terminal until close" {
  // a refusal never moves the machine
  assert_eq(
    @client.ClientState::on(@client.Ready, @client.QueueQuiet),
    @client.Ready,
  )
  assert_eq(
    @client.ClientState::on(@client.Backoff, @client.ConnectRequested),
    @client.Backoff,
  )
  // Fatal swallows everything but the explicit close
  assert_eq(
    @client.ClientState::on(@client.Fatal, @client.BackoffExpired),
    @client.Fatal,
  )
  assert_eq(
    @client.ClientState::on(@client.Fatal, @client.Close),
    @client.Disconnected,
  )
}

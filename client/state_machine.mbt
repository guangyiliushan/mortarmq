/// Define the client connection state machine and its total step
/// function: every state answers every event with a transition or an
/// explicit rejection, so no arrival can fall through undefined.
///
/// The states and the drawn edges follow the published connection-state
/// diagram: `connect()` opens the loop, a transport that comes up moves
/// into authentication, `CONNECT_OK` lands in `Ready`, activity enters
/// `Streaming`, and the recovery loop runs `Backoff -> Connecting` with
/// the reconnect schedule. Three uniform completions extend the drawn
/// edges over the states the diagram leaves implicit, each forced by the
/// meaning of its event: a transport loss breaks any live session into
/// `Backoff`, an unrecoverable protocol or auth-class error condemns any
/// live session to `Fatal`, and an explicit close lands in `Disconnected`
/// from everywhere.
///
/// # Stability
///
/// * A refused event leaves the state unchanged: that self-loop is the
///   machine's explicit rejection, and the step function is total so the
///   rejection is a defined outcome, never a crash.
/// * `Fatal` is terminal until an explicit close; only `Close` leaves it.
/// * The step function reads no clock and owns no timer: the backoff
///   schedule is an event (`BackoffExpired`) the surrounding loop times,
///   so the machine stays a pure table.

///|
/// The connection states of the client, as the diagram names them.
pub(all) enum ClientState {
  Disconnected
  Connecting
  Authenticating
  Ready
  Streaming
  Backoff
  Fatal
} derive(Eq, Debug)

///|
pub extend ClientState with Eq::{not_equal, equal}

///|
pub extend ClientState with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The events the connection-state diagram transitions on.
///
/// `TransportLost` carries both drawn transport failures (a network
/// error while connecting and a disconnect while streaming); the
/// surrounding loop classifies the wire into these signals before they
/// reach the machine.
pub(all) enum ClientEvent {
  ConnectRequested
  TransportUp
  TransportLost
  ConnectOk
  AuthFailed
  FatalError
  ActivityStarted
  QueueQuiet
  BackoffExpired
  Close
} derive(Eq, Debug)

///|
pub extend ClientEvent with Eq::{not_equal, equal}

///|
pub extend ClientEvent with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Step the machine: return the state one event leaves the client in.
///
/// The drawn edges move the machine forward; every other arrival is an
/// explicit rejection and returns the state unchanged. The completions
/// are the uniform ones the event meanings force: `TransportLost` breaks
/// any live session (`Connecting`, `Authenticating`, `Ready`,
/// `Streaming`) into `Backoff`, `FatalError` condemns any live session
/// or a `Backoff` into `Fatal`, and `Close` lands in `Disconnected` from
/// every state.
///
/// Parameters:
///
/// * `event` : The classified signal; the wire's error codes are reduced
///   to `AuthFailed`, `FatalError` or `TransportLost` before this call.
///
/// Returns the state after the event.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(
///     @client.ClientState::on(@client.Connecting, @client.TransportUp),
///     @client.Authenticating,
///   )
///   assert_eq(
///     @client.ClientState::on(@client.Ready, @client.QueueQuiet),
///     @client.Ready,
///   )
/// }
/// ```
pub fn ClientState::on(self : ClientState, event : ClientEvent) -> ClientState {
  match event {
    ConnectRequested =>
      match self {
        Disconnected => Connecting
        _ => self
      }
    TransportUp =>
      match self {
        Connecting => Authenticating
        _ => self
      }
    TransportLost =>
      match self {
        Connecting | Authenticating | Ready | Streaming => Backoff
        _ => self
      }
    ConnectOk =>
      match self {
        Authenticating => Ready
        _ => self
      }
    AuthFailed =>
      match self {
        Authenticating => Backoff
        _ => self
      }
    FatalError =>
      match self {
        Connecting | Authenticating | Ready | Streaming | Backoff => Fatal
        _ => self
      }
    ActivityStarted =>
      match self {
        Ready => Streaming
        _ => self
      }
    QueueQuiet =>
      match self {
        Streaming => Ready
        _ => self
      }
    BackoffExpired =>
      match self {
        Backoff => Connecting
        _ => self
      }
    Close => Disconnected
  }
}

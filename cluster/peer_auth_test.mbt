/// The peer handshake over a real loopback socket, and the separation
/// between the peer secret and a client token.
///
/// Every case here runs the actual protocol over an actual TCP
/// connection: the accept side and the dial side each get a `Conn`, so
/// what is exercised is the same `serve_peer` / `dial_peer` path a
/// wired-up node takes, not a mock of it.

///|
/// How long one side of a handshake may take before the test gives up.
///
/// Bounded so a protocol that stops sending fails the assertion instead
/// of hanging the whole suite. Five seconds is far above anything a
/// loopback round trip needs and far below a CI timeout.
fn handshake_budget_ms() -> Int {
  5000
}

///|
/// One end of a loopback peer connection: an accepted socket or a
/// dialed one, wrapped as the transport-neutral `@net.Conn` the peer
/// protocol speaks.
///
/// The wiring lives in the tests on purpose. `cluster` only ever names
/// the trait, so a concrete socket type in this package would break the
/// rule that the peer channel is transport-neutral, and `net/tcp`'s
/// `TcpConn` wraps the dial side only. Whoever wires a broker main up
/// picks its own adapter; nothing in production code needs one.
struct LoopConn {
  tcp : @socket.Tcp
}

///|
impl @net.Conn for LoopConn with fn read_exact(self, len : Int) -> Result[
  Bytes,
  @protocol.ErrCode,
] {
  if len < 0 {
    return Err(@protocol.Internal)
  }
  let received = @io.Reader::read_exactly(self.tcp, len) catch {
    _ => return Err(@protocol.Internal)
  }
  Ok(received)
}

///|
impl @net.Conn for LoopConn with fn write_all(self, data : Bytes) -> Result[
  Unit,
  @protocol.ErrCode,
] {
  @io.Writer::write(self.tcp, data) catch {
    _ => return Err(@protocol.Internal)
  }
  Ok(())
}

///|
impl @net.Conn for LoopConn with fn close(self) -> Unit {
  self.tcp.close()
}

///|
/// Open a loopback connection to `port`, mapping a refused connect onto
/// the registry's transport code exactly as `net/tcp` does.
async fn dial_loopback(port : Int) -> Result[&@net.Conn, @protocol.ErrCode] {
  let tcp = @socket.Tcp::connect_to_host("127.0.0.1", port~) catch {
    _ => return Err(@protocol.Internal)
  }
  // The coercion is spelled as a type ascription, the same way the
  // storage tests hand a `FakeDisk` to a `&@harness.Disk` parameter.
  let concrete : LoopConn = { tcp, }
  let conn : &@net.Conn = concrete
  Ok(conn)
}

///|
/// Three static rows for a two-party handshake fixture: the responder's
/// real bound port first, then two ports nothing dials.
///
/// `ClusterConfig` always names three members, so a two-party test
/// still carries the full table -- a v0 cluster has no two-node mode --
/// and the third row is never reached. `second_id` is a
/// parameter so a fixture can model a node whose id is missing from the
/// other side's table.
fn handshake_peers(
  responder_port : Int,
  second_id : UInt16,
) -> Array[@cluster.PeerEntry] {
  [
    { node_id: 1U.to_uint16(), host: "127.0.0.1", port: responder_port, },
    { node_id: second_id, host: "127.0.0.1", port: responder_port + 1, },
    { node_id: 3U.to_uint16(), host: "127.0.0.1", port: responder_port + 2, },
  ]
}

///|
/// Build one node's configuration over the handshake fixture.
///
/// The priority list is derived from the table itself, so it is a
/// permutation by construction and a fixture can never trip the
/// `BadLeaderPriority` rule it is not testing.
fn handshake_config(
  node_id : UInt16,
  responder_port : Int,
  second_id : UInt16,
  secret : @cluster.PeerSecret,
) -> @cluster.ClusterConfig raise {
  let peers = handshake_peers(responder_port, second_id)
  let priority = peers.map(row => row.node_id)
  match
    @cluster.ClusterConfig::new(
      node_id, peers, priority, "127.0.0.1", responder_port, secret,
    ) {
    Ok(config) => config
    Err(_) => fail("the handshake fixture must be a valid static table")
  }
}

///|
/// Bind an ephemeral loopback listener and report the port the OS chose.
async fn bind_loopback() -> @socket.TcpServer {
  @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
}

///|
/// Run one complete handshake over a fresh loopback listener and report
/// both ends' verdicts.
///
/// Parameters are the two nodes' ids, the second id of the initiator's
/// own table (which is what makes one side's membership differ from the
/// other's), each side's secret, and the node id the initiator expects
/// the listener to answer as. Every case that has to fail names exactly
/// one of those and leaves the rest at the happy-path value, so a
/// failure cannot come from the wrong knob.
async fn handshake_pair(
  responder_node : UInt16,
  initiator_node : UInt16,
  initiator_second : UInt16,
  responder_secret : @cluster.PeerSecret,
  initiator_secret : @cluster.PeerSecret,
  expected_node : UInt16,
) -> (Result[UInt16, @protocol.ErrCode], Result[UInt16, @protocol.ErrCode]) {
  let server = bind_loopback()
  let responder_port = server.addr.port()
  let responder_config = handshake_config(
    responder_node,
    responder_port,
    2U.to_uint16(),
    responder_secret,
  )
  let initiator_config = handshake_config(
    initiator_node, responder_port, initiator_second, initiator_secret,
  )
  let responder_outcome : Ref[Result[UInt16, @protocol.ErrCode]] = Ref::Ref(
    Err(@protocol.Internal),
  )
  let initiator_outcome : Ref[Result[UInt16, @protocol.ErrCode]] = Ref::Ref(
    Err(@protocol.Internal),
  )
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => server.accept()) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          let outcome = @cluster.peer_handshake_responder(
            responder_config, conn,
          )
          @net.Conn::close(conn)
          responder_outcome.val = outcome
        }
      }
    }
    match dial_loopback(responder_port) {
      Err(code) => initiator_outcome.val = Err(code)
      Ok(conn) => {
        let expected = match responder_config.peer_entry(expected_node) {
          None => fail("the expected peer must be in the static table")
          Some(entry) => entry
        }
        let bounded = @async.with_timeout_opt(handshake_budget_ms(), () => {
          @cluster.peer_handshake_initiator(initiator_config, conn, expected)
        })
        @net.Conn::close(conn)
        initiator_outcome.val = match bounded {
          None => Err(@protocol.Internal)
          Some(outcome) => outcome
        }
      }
    }
  }
  (initiator_outcome.val, responder_outcome.val)
}

///|
async test "a peer handshake authenticates both ends over a live loopback link" {
  let secret = fixture_secret()
  let (initiator, responder) = handshake_pair(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    secret,
    secret,
    1U.to_uint16(),
  )
  // Each end learns the other's id from the handshake, not from the
  // socket: the responder reports the initiator and vice versa.
  assert_eq(initiator, Ok(1U.to_uint16()))
  assert_eq(responder, Ok(2U.to_uint16()))
}

///|
async test "a wrong shared secret refuses the link on both ends" {
  let shared = fixture_secret()
  let other = match @cluster.PeerSecret::new(b"fedcba9876543210") {
    Ok(secret) => secret
    Err(_) => fail("sixteen bytes is the floor and must be accepted")
  }
  let (initiator, responder) = handshake_pair(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    shared,
    other,
    1U.to_uint16(),
  )
  assert_eq(initiator, Err(@protocol.AuthFailed))
  assert_eq(responder, Err(@protocol.AuthFailed))
}

///|
/// The replay the challenge-response design has to kill: a Challenge
/// captured from one genuine session must be worthless in the next one,
/// because the initiator's fresh nonce re-keys both tags. An attacker
/// replays the captured Challenge byte for byte and the link refuses;
/// under responder-nonce-only tags the same script completed the
/// handshake.
async test "a replayed challenge refuses the link" {
  let secret = fixture_secret()
  // Session one: a scripted initiator with a known nonce harvests a
  // genuine Challenge from the real responder, then walks away.
  let captured : Ref[Bytes?] = Ref::Ref(None)
  let server = bind_loopback()
  let port = server.addr.port()
  let responder_config = handshake_config(
    1U.to_uint16(),
    port,
    2U.to_uint16(),
    secret,
  )
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => server.accept()) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          ignore(
            @async.with_timeout_opt(handshake_budget_ms(), () => {
              @cluster.peer_handshake_responder(responder_config, conn)
            }),
          )
          @net.Conn::close(conn)
        }
      }
    }
    let conn = match dial_loopback(port) {
      Ok(conn) => conn
      Err(_) => fail("the capture dial failed")
    }
    // A fixed initiator nonce: the captured Challenge is valid only for
    // sessions that reuse exactly these bytes.
    let fixed_nonce : Bytes = b"\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a\x5a"
    match
      @net.Conn::write_all(
        conn,
        @cluster.encode_peer_msg(
          @cluster.PeerMsg::Hello(2U.to_uint16(), fixed_nonce),
        ),
      ) {
      Ok(_) => ()
      Err(_) => fail("the capture hello failed")
    }
    let header = match @net.Conn::read_exact(conn, 4) {
      Ok(bytes) => bytes
      Err(_) => fail("no challenge length arrived")
    }
    let body_len = ((header[0].to_uint() << 24) |
    (header[1].to_uint() << 16) |
    (header[2].to_uint() << 8) |
    header[3].to_uint()).reinterpret_as_int()
    let body = match @net.Conn::read_exact(conn, body_len) {
      Ok(bytes) => bytes
      Err(_) => fail("no challenge body arrived")
    }
    captured.val = Some(header + body)
    // Unblock the responder: it is waiting on a Proof that never comes.
    ignore(
      @net.Conn::write_all(
        conn,
        @cluster.encode_peer_msg(@cluster.PeerMsg::Reject(0x0006U.to_uint16())),
      ),
    )
    @net.Conn::close(conn)
  }
  let challenge = match captured.val {
    Some(bytes) => bytes
    None => fail("no challenge was captured")
  }
  // Session two: the real initiator runs against a replaying attacker
  // that answers its fresh Hello with the captured Challenge.
  let server2 = bind_loopback()
  let port2 = server2.addr.port()
  let initiator_config = handshake_config(
    2U.to_uint16(),
    port2,
    2U.to_uint16(),
    secret,
  )
  let victim_outcome : Ref[Result[UInt16, @protocol.ErrCode]] = Ref::Ref(
    Err(@protocol.Internal),
  )
  @async.with_task_group() <| group => {
    group.spawn_bg() <| () => {
      defer server2.close()
      match
        @async.with_timeout_opt(handshake_budget_ms(), () => server2.accept()) {
        None => ()
        Some(accepted) => {
          let concrete : LoopConn = { tcp: accepted.0, }
          let conn : &@net.Conn = concrete
          // Consume the victim's Hello (4 length bytes + type + id +
          // nonce), then replay the captured Challenge verbatim.
          ignore(@net.Conn::read_exact(conn, 4 + 19))
          ignore(@net.Conn::write_all(conn, challenge))
          @net.Conn::close(conn)
        }
      }
    }
    let conn = match dial_loopback(port2) {
      Ok(conn) => conn
      Err(_) => fail("the victim dial failed")
    }
    let expected = match initiator_config.peer_entry(1U.to_uint16()) {
      None => fail("node 1 must be in the initiator's table")
      Some(entry) => entry
    }
    let bounded = @async.with_timeout_opt(handshake_budget_ms(), () => {
      @cluster.peer_handshake_initiator(initiator_config, conn, expected)
    })
    @net.Conn::close(conn)
    victim_outcome.val = match bounded {
      None => Err(@protocol.Internal)
      Some(outcome) => outcome
    }
  }
  assert_eq(victim_outcome.val, Err(@protocol.AuthFailed))
}

///|
async test "a node id outside the receiving table refuses the link" {
  // The initiator's own table contains 9, so its configuration is well
  // formed; the responder's table does not contain 9, so the responder
  // must refuse it. This is the case a membership check exists for.
  let secret = fixture_secret()
  let (initiator, responder) = handshake_pair(
    1U.to_uint16(),
    9U.to_uint16(),
    9U.to_uint16(),
    secret,
    secret,
    1U.to_uint16(),
  )
  assert_eq(initiator, Err(@protocol.AuthFailed))
  assert_eq(responder, Err(@protocol.AuthFailed))
}

///|
async test "a listener answering as a different node than its table row refuses the link" {
  // The initiator dials the address the table gives for node 1, but the
  // process listening there answers as node 2. The address and the id
  // have to agree or one node's row could silently reach another.
  let secret = fixture_secret()
  let (initiator, responder) = handshake_pair(
    2U.to_uint16(),
    3U.to_uint16(),
    2U.to_uint16(),
    secret,
    secret,
    1U.to_uint16(),
  )
  assert_eq(initiator, Err(@protocol.AuthFailed))
  assert_eq(responder, Err(@protocol.AuthFailed))
}

///|
/// A Delay that records pauses instead of waiting, so the client-side
/// half of the separation check costs no wall clock.
priv struct NoPause {
  calls : Ref[Array[Int]]
}

///|
impl @security.Delay for NoPause with fn sleep_ms(self, ms : Int) -> Unit {
  self.calls.val.push(ms)
}

///|
async test "a leaked client token cannot open a peer link, and a peer secret is not a client token" {
  // The scenario in both directions: the client token leaks and the peer
  // channel carries on, and the peer secret is not usable as a client
  // credential either. The two are different values held in
  // different types, which is what makes the separation structural.
  let client_token = b"client-token-0123456789"
  let shared = fixture_secret()
  // The token is long enough to clear the peer-secret floor, so the
  // length check is not what separates the two -- the value is.
  let presented_as_peer = match @cluster.PeerSecret::new(client_token) {
    Ok(secret) => secret
    Err(_) =>
      fail("a 24-byte token clears the floor, so this is not the separation")
  }
  let store = match
    @security.parse_tokens(
      (@security.sha256_hex(client_token) + b"\tadmin\n")[:],
    ) {
    Some(store) => store
    None => fail("the single-entry store must parse")
  }
  let client_view : NoPause = { calls: Ref::Ref([]), }
  assert_eq(
    @security.authenticate(store, client_token, client_view),
    Ok(b"admin"),
  )
  let secret_view : NoPause = { calls: Ref::Ref([]), }
  assert_eq(
    // The peer secret itself, exactly as `fixture_secret` builds it:
    // presented to the client channel it is an unknown token.
    @security.authenticate(store, b"0123456789abcdef", secret_view),
    Err(@security.Rejected),
  )
  // The peer channel configured with the shared secret refuses a link
  // presented with the leaked client token.
  let (initiator, responder) = handshake_pair(
    1U.to_uint16(),
    2U.to_uint16(),
    2U.to_uint16(),
    shared,
    presented_as_peer,
    1U.to_uint16(),
  )
  assert_eq(initiator, Err(@protocol.AuthFailed))
  assert_eq(responder, Err(@protocol.AuthFailed))
}

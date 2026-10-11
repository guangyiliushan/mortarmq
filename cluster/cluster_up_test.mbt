/// The T041 exit, L7: three nodes come up.
///
/// Three real loopback listeners are bound at once, one per node's
/// `listen_peer`, and each node completes an authenticated link to both
/// of the others over the transport the tests wire in. What is asserted
/// is the whole statement of "the cluster is up": three distinct
/// addresses are listening, every handshake on them succeeded, and every
/// node reports both of its peers linked -- not merely that three
/// objects were constructed.

///|
/// The three static rows, addressed at the ports the OS assigned.
fn cluster_table(ports : Array[Int]) -> Array[@cluster.PeerEntry] {
  [
    { node_id: 1U.to_uint16(), host: "127.0.0.1", port: ports[0], },
    { node_id: 2U.to_uint16(), host: "127.0.0.1", port: ports[1], },
    { node_id: 3U.to_uint16(), host: "127.0.0.1", port: ports[2], },
  ]
}

///|
/// Build one node over the three real ports, listening on its own.
fn cluster_node(
  node_id : UInt16,
  listen_port : Int,
  ports : Array[Int],
  secret : @cluster.PeerSecret,
) -> @cluster.ClusterNode raise {
  let peers = cluster_table(ports)
  let priority = peers.map(row => row.node_id)
  let config = match
    @cluster.ClusterConfig::new(
      node_id, peers, priority, "127.0.0.1", listen_port, secret,
    ) {
    Ok(config) => config
    Err(_) => fail("the three real ports must form a valid static table")
  }
  @cluster.ClusterNode::new(config)
}

///|
/// Accept `count` connections on `server` and serve each one as `node`,
/// collecting any handshake that refused.
///
/// The bound port and the node are the same fact from two sides: the
/// listener sits where the table says this node's `listen_peer` is, and
/// the node is the thing that decides a link is real.
async fn accept_and_serve(
  server : @socket.TcpServer,
  node : @cluster.ClusterNode,
  count : Int,
  refused : Ref[Array[@protocol.ErrCode]],
) -> Unit {
  for _ in 0..<count {
    match
      @async.with_timeout_opt(handshake_budget_ms(), () => server.accept()) {
      None => refused.val.push(@protocol.Internal)
      Some(accepted) => {
        let concrete : LoopConn = { tcp: accepted.0, }
        let conn : &@net.Conn = concrete
        match @cluster.ClusterNode::serve_peer(node, conn) {
          Ok(_) => ()
          Err(code) => refused.val.push(code)
        }
        @net.Conn::close(conn)
      }
    }
  }
  server.close()
}

///|
/// Dial one peer and record the link it becomes, or the code that
/// refused it.
async fn dial_and_link(
  node : @cluster.ClusterNode,
  expected_id : UInt16,
  port : Int,
  refused : Ref[Array[@protocol.ErrCode]],
) -> Unit {
  let expected = match node.config().peer_entry(expected_id) {
    None => {
      refused.val.push(@protocol.Internal)
      return
    }
    Some(entry) => entry
  }
  match dial_loopback(port) {
    Err(code) => refused.val.push(code)
    Ok(conn) => {
      let bounded = @async.with_timeout_opt(handshake_budget_ms(), () => {
        @cluster.ClusterNode::dial_peer(node, conn, expected)
      })
      @net.Conn::close(conn)
      match bounded {
        None => refused.val.push(@protocol.Internal)
        Some(Ok(_)) => ()
        Some(Err(code)) => refused.val.push(code)
      }
    }
  }
}

///|
async test "three nodes come up on three listen_peer ports with every peer link authenticated" {
  let secret = fixture_secret()
  let server_one = bind_loopback()
  let server_two = bind_loopback()
  let server_three = bind_loopback()
  let ports = [
    server_one.addr.port(),
    server_two.addr.port(),
    server_three.addr.port(),
  ]
  // Three listeners, three addresses: the peers table would not accept
  // a repeat, and a shared address would let one dial reach the wrong
  // node, so this is a precondition of the configuration rather than a
  // convenience of the test.
  assert_eq(ports[0] == ports[1], false)
  assert_eq(ports[0] == ports[2], false)
  assert_eq(ports[1] == ports[2], false)

  let node_one = cluster_node(1U.to_uint16(), ports[0], ports, secret)
  let node_two = cluster_node(2U.to_uint16(), ports[1], ports, secret)
  let node_three = cluster_node(3U.to_uint16(), ports[2], ports, secret)
  // Each node listens where the table says it does -- the face the
  // peer channel runs on, separate from any client listener.
  assert_eq(node_one.config().listen_port(), ports[0])
  assert_eq(node_two.config().listen_port(), ports[1])
  assert_eq(node_three.config().listen_port(), ports[2])
  assert_eq(node_one.link_count(), 0)
  assert_eq(node_one.peers_connected(), false)

  let serve_refused : Ref[Array[@protocol.ErrCode]] = Ref::Ref([])
  let dial_refused : Ref[Array[@protocol.ErrCode]] = Ref::Ref([])
  @async.with_task_group() <| group => {
    // node 2 takes one inbound link (from node 1); node 3 takes two
    // (from node 1 and node 2); node 1 takes none. Dialing only a
    // higher-numbered peer gives each unordered pair exactly one
    // connection, so every node ends with exactly two.
    group.spawn_bg() <| () => {
      accept_and_serve(server_two, node_two, 1, serve_refused)
    }
    group.spawn_bg() <| () => {
      accept_and_serve(server_three, node_three, 2, serve_refused)
    }
    dial_and_link(node_one, 2U.to_uint16(), ports[1], dial_refused)
    dial_and_link(node_one, 3U.to_uint16(), ports[2], dial_refused)
    dial_and_link(node_two, 3U.to_uint16(), ports[2], dial_refused)
  }
  server_one.close()

  // Every handshake on the three listeners succeeded, and every dial
  // found the node the table named.
  assert_eq(serve_refused.val, [])
  assert_eq(dial_refused.val, [])
  for node in [node_one, node_two, node_three] {
    assert_eq(node.link_count(), 2)
    assert_eq(node.peers_connected(), true)
    let peer_ids = node.links().map(link => link.peer_id)
    assert_eq(peer_ids.length(), 2)
  }
  // node 1 dialed both; node 3 answered both; node 2 did one of each.
  assert_eq(node_one.links().all(link => link.outbound), true)
  assert_eq(node_three.links().all(link => !link.outbound), true)
  let inbound_two = node_two.links().filter(link => !link.outbound)
  let outbound_two = node_two.links().filter(link => link.outbound)
  assert_eq(inbound_two.length(), 1)
  assert_eq(outbound_two.length(), 1)
}

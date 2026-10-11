/// Pin every rule `ClusterConfig::new` enforces before a socket is
/// opened (three static members, and the secret that separates the peer
/// channel from every client token), one rejection per fault, plus the majority arithmetic the commit gate
/// will read.

///|
/// The shared secret every well-formed fixture uses: sixteen bytes, the
/// floor exactly, so the floor itself is exercised.
fn fixture_secret() -> @cluster.PeerSecret raise {
  match @cluster.PeerSecret::new(b"0123456789abcdef") {
    Ok(secret) => secret
    Err(_) => fail("sixteen bytes is the floor and must be accepted")
  }
}

///|
/// Three loopback rows, one per node, ports 7191 through 7193.
fn fixture_peers() -> Array[@cluster.PeerEntry] {
  [
    { node_id: 1U.to_uint16(), host: "127.0.0.1", port: 7191, },
    { node_id: 2U.to_uint16(), host: "127.0.0.1", port: 7192, },
    { node_id: 3U.to_uint16(), host: "127.0.0.1", port: 7193, },
  ]
}

///|
fn fixture_priority() -> Array[UInt16] {
  [1U, 2U, 3U].map(id => id.to_uint16())
}

///|
/// Build node 1's configuration from the fixtures.
fn fixture_config() -> Result[@cluster.ClusterConfig, @cluster.ClusterFault] raise {
  @cluster.ClusterConfig::new(
    1U.to_uint16(),
    fixture_peers(),
    fixture_priority(),
    "127.0.0.1",
    7191,
    fixture_secret(),
  )
}

///|
test "a three-node static table is accepted and its quorum is a majority" {
  match fixture_config() {
    Err(_) => fail("the fixture must be accepted")
    Ok(config) => {
      assert_eq(config.peer_count(), @cluster.STATIC_PEER_COUNT)
      assert_eq(config.node_id(), 1U.to_uint16())
      assert_eq(config.listen_port(), 7191)
      // Three members commit at two, never at one.
      assert_eq(config.quorum(), 2)
      assert_eq(config.quorum() < config.peer_count(), true)
    }
  }
}

///|
test "a table that is not three nodes is refused" {
  let truncated : Array[@cluster.PeerEntry] = [
    { node_id: 1U.to_uint16(), host: "127.0.0.1", port: 7191, },
    { node_id: 2U.to_uint16(), host: "127.0.0.1", port: 7192, },
  ]
  match
    @cluster.ClusterConfig::new(
      1U.to_uint16(),
      truncated,
      fixture_priority(),
      "127.0.0.1",
      7191,
      fixture_secret(),
    ) {
    Err(@cluster.NotThreePeers) => ()
    _ => fail("two members must be refused as NotThreePeers")
  }
}

///|
test "a repeated node id is refused" {
  let repeated : Array[@cluster.PeerEntry] = [
    { node_id: 1U.to_uint16(), host: "127.0.0.1", port: 7191, },
    { node_id: 1U.to_uint16(), host: "127.0.0.1", port: 7192, },
    { node_id: 3U.to_uint16(), host: "127.0.0.1", port: 7193, },
  ]
  match
    @cluster.ClusterConfig::new(
      1U.to_uint16(),
      repeated,
      fixture_priority(),
      "127.0.0.1",
      7191,
      fixture_secret(),
    ) {
    Err(@cluster.DuplicatePeerId) => ()
    _ => fail("a repeated id must be refused as DuplicatePeerId")
  }
}

///|
test "two rows sharing one address are refused" {
  let collided : Array[@cluster.PeerEntry] = [
    { node_id: 1U.to_uint16(), host: "127.0.0.1", port: 7191, },
    { node_id: 2U.to_uint16(), host: "127.0.0.1", port: 7191, },
    { node_id: 3U.to_uint16(), host: "127.0.0.1", port: 7193, },
  ]
  match
    @cluster.ClusterConfig::new(
      1U.to_uint16(),
      collided,
      fixture_priority(),
      "127.0.0.1",
      7191,
      fixture_secret(),
    ) {
    Err(@cluster.DuplicatePeerAddr) => ()
    _ => fail("a shared address must be refused as DuplicatePeerAddr")
  }
}

///|
test "a node whose own id is not in the table is refused" {
  match
    @cluster.ClusterConfig::new(
      9U.to_uint16(),
      fixture_peers(),
      fixture_priority(),
      "127.0.0.1",
      7191,
      fixture_secret(),
    ) {
    Err(@cluster.SelfMissing) => ()
    _ => fail("an id absent from the table must be refused as SelfMissing")
  }
}

///|
test "a leader_priority that is not a permutation is refused" {
  let repeated = [1U, 1U, 3U].map(id => id.to_uint16())
  match
    @cluster.ClusterConfig::new(
      1U.to_uint16(),
      fixture_peers(),
      repeated,
      "127.0.0.1",
      7191,
      fixture_secret(),
    ) {
    Err(@cluster.BadLeaderPriority) => ()
    _ => fail("a repeated priority must be refused as BadLeaderPriority")
  }
  let short = [1U, 2U].map(id => id.to_uint16())
  match
    @cluster.ClusterConfig::new(
      1U.to_uint16(),
      fixture_peers(),
      short,
      "127.0.0.1",
      7191,
      fixture_secret(),
    ) {
    Err(@cluster.BadLeaderPriority) => ()
    _ => fail("a short priority must be refused as BadLeaderPriority")
  }
}

///|
test "an unusable listen_peer address is refused" {
  match
    @cluster.ClusterConfig::new(
      1U.to_uint16(),
      fixture_peers(),
      fixture_priority(),
      "",
      7191,
      fixture_secret(),
    ) {
    Err(@cluster.BadListenAddr) => ()
    _ => fail("an empty listen host must be refused as BadListenAddr")
  }
  match
    @cluster.ClusterConfig::new(
      1U.to_uint16(),
      fixture_peers(),
      fixture_priority(),
      "127.0.0.1",
      0,
      fixture_secret(),
    ) {
    Err(@cluster.BadListenAddr) => ()
    _ => fail("port zero must be refused as BadListenAddr")
  }
}

///|
test "peer membership lookup agrees with the static table" {
  match fixture_config() {
    Err(_) => fail("the fixture must be accepted")
    Ok(config) => {
      assert_eq(config.has_peer(2U.to_uint16()), true)
      assert_eq(config.has_peer(4U.to_uint16()), false)
      assert_eq(
        config.peer_entry(3U.to_uint16()),
        Some({ node_id: 3U.to_uint16(), host: "127.0.0.1", port: 7193, }),
      )
      assert_eq(config.peer_entry(4U.to_uint16()), None)
      // The table hands back a copy, so a caller cannot mutate the
      // static membership through the accessor.
      let rows = config.peers()
      rows.clear()
      assert_eq(config.peer_count(), @cluster.STATIC_PEER_COUNT)
    }
  }
}

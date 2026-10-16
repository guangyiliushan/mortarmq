/// Static cluster membership and the peer channel's shared secret.
///
/// A v0 cluster is three nodes named in one static table, dialed at the
/// addresses that table holds, and each node listens on its own
/// `listen_peer` address -- a face that carries replication traffic only
/// and never a client connection. Two things are separated here on
/// purpose, and the separation is structural rather than a convention:
///
/// * `PeerSecret` is its own type holding its own bytes. Nothing in this
///   package reads a client token, and `@security`'s token store is a
///   different type that cannot be passed where a `PeerSecret` is
///   expected, so a leaked client token cannot open a peer link by
///   accident. That the token can leak while the peer channel carries on
///   is a property of the types, not of a check someone has to remember
///   to run.
/// * `listen_peer` is a configuration field of its own, distinct from
///   `listen_client`, so the two faces are separate sockets on separate
///   ports from the moment a node starts.
///
/// Validation runs before any socket is opened: a table that does not
/// name three distinct nodes, an id missing from its own table, a
/// priority list that is not a permutation, or a secret too short to
/// carry weight all fail startup rather than failing one link later
/// with a code that would mean something else.

///|
/// Node count of the v0 cluster, fixed at three.
///
/// Not a tuning knob: the quorum below is derived from it, and a
/// cluster of a different size would need its own ruling rather than a
/// different number typed in here.
pub const STATIC_PEER_COUNT : Int32 = 3

///|
/// Smallest accepted peer secret, in bytes.
///
/// The peer secret authenticates a whole channel, so it carries the same
/// 128-bit floor the threat model sets for client tokens: a shorter
/// secret can be guessed offline from one captured handshake, and there
/// is no rate limit between an attacker and a byte comparison.
pub const PEER_SECRET_MIN_BYTES : Int32 = 16

///|
/// A cluster configuration problem found before any socket is opened.
///
/// These are startup faults, not wire codes: nothing has been sent to a
/// peer yet, so no registered `ErrCode` would mean what happened here.
/// The operator gets the fault's own name.
pub(all) suberror ClusterFault {
  /// v0 is a static three-node cluster, and nothing else.
  NotThreePeers
  /// The table repeats a node id, so it no longer names three nodes.
  DuplicatePeerId
  /// Two rows share an address, so a dial can reach the wrong node.
  DuplicatePeerAddr
  /// This node's own id is absent from the table it dials.
  SelfMissing
  /// `leader_priority` must name every peer once and only once.
  BadLeaderPriority
  /// A `listen_peer` address is empty or outside the TCP port range.
  BadListenAddr
  /// The shared secret is shorter than `PEER_SECRET_MIN_BYTES`.
  WeakPeerSecret
} derive(Eq, Debug)

///|
pub extend ClusterFault with Eq::{not_equal, equal}

///|
pub extend ClusterFault with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One row of the static peer table: a node id and the `listen_peer`
/// address its owner serves replication traffic on.
///
/// The address is what the *other* two nodes dial, so it is an
/// externally reachable address rather than the wildcard a node may
/// bind to.
pub(all) struct PeerEntry {
  node_id : UInt16
  host : String
  port : Int32
} derive(Eq, Debug)

///|
pub extend PeerEntry with Eq::{not_equal, equal}

///|
pub extend PeerEntry with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The shared secret the peer channel authenticates with.
///
/// Independent of every client token by construction: the bytes live
/// only here, are never written to a frame, and are only ever fed to
/// `hmac_sha256`. Callers outside the peer handshake have no way to read
/// them, so a debug print or a log line cannot leak the secret either.
pub struct PeerSecret {
  priv key : Bytes
}

///|
/// Wrap a shared secret, refusing one too short to carry weight.
///
/// # Example
///
/// ```mbt check
/// test {
///   match @cluster.PeerSecret::new(b"short") {
///     Err(@cluster.WeakPeerSecret) => ()
///     _ => fail("a secret below the floor must be refused")
///   }
///   match @cluster.PeerSecret::new(b"0123456789abcdef") {
///     Ok(_) => ()
///     Err(_) => fail("a 16-byte secret is above the floor")
///   }
/// }
/// ```
pub fn PeerSecret::new(key : Bytes) -> Result[PeerSecret, ClusterFault] {
  if key.length() < PEER_SECRET_MIN_BYTES {
    return Err(WeakPeerSecret)
  }
  Ok({ key, })
}

///|
/// Key this secret with `message`, returning the 32-byte tag.
///
/// The only operation a secret supports: the key bytes leave this type
/// solely as the first argument of the keyed hash, so there is no path
/// from holding a `PeerSecret` to printing the shared secret.
pub fn PeerSecret::tag(self : PeerSecret, message : BytesView) -> Bytes {
  @security.hmac_sha256(self.key, message)
}

///|
/// This cluster's static configuration: who the members are, what this
/// node listens on, and the secret that authenticates the links between
/// them.
///
/// Every field is validated once in `new` and then read-only; there is
/// no reconfiguration path in v0, which is what "static" means here.
pub struct ClusterConfig {
  priv node_id : UInt16
  priv peers : Array[PeerEntry]
  priv leader_priority : Array[UInt16]
  priv listen_host : String
  priv listen_port : Int32
  priv secret : PeerSecret
}

///|
/// Build a cluster configuration, rejecting every table that could not
/// name this v0 cluster.
///
/// Parameters:
///
/// * `node_id` : this node's id, which must appear in `peers`.
/// * `peers` : the three static members, including this one.
/// * `leader_priority` : node ids most-preferred first, a permutation of
///   `peers`; the deterministic source the lease failover picks with.
/// * `listen_host` / `listen_port` : this node's `listen_peer` face.
/// * `secret` : the peer channel's shared secret.
///
/// # Example
///
/// ```mbt check
/// test {
///   let secret = match @cluster.PeerSecret::new(b"0123456789abcdef") {
///     Ok(secret) => secret
///     Err(_) => fail("a 16-byte secret is above the floor")
///   }
///   let peers : Array[@cluster.PeerEntry] = [
///     { node_id: 1U.to_uint16(), host: "127.0.0.1", port: 7191, },
///     { node_id: 2U.to_uint16(), host: "127.0.0.1", port: 7192, },
///     { node_id: 3U.to_uint16(), host: "127.0.0.1", port: 7193, },
///   ]
///   let priority = [1U, 2U, 3U].map(id => id.to_uint16())
///   let built = @cluster.ClusterConfig::new(
///     1U.to_uint16(),
///     peers,
///     priority,
///     "127.0.0.1",
///     7191,
///     secret,
///   )
///   match built {
///     Ok(config) => {
///       assert_eq(config.quorum(), 2)
///       assert_eq(config.node_id(), 1U.to_uint16())
///     }
///     Err(_) => fail("a well-formed static table must be accepted")
///   }
/// }
/// ```
pub fn ClusterConfig::new(
  node_id : UInt16,
  peers : Array[PeerEntry],
  leader_priority : Array[UInt16],
  listen_host : String,
  listen_port : Int32,
  secret : PeerSecret,
) -> Result[ClusterConfig, ClusterFault] {
  if peers.length() != STATIC_PEER_COUNT {
    return Err(NotThreePeers)
  }
  for left in 0..<peers.length() {
    for right in (left + 1)..<peers.length() {
      if peers[left].node_id == peers[right].node_id {
        return Err(DuplicatePeerId)
      }
      let same_host = peers[left].host == peers[right].host
      let same_port = peers[left].port == peers[right].port
      if same_host && same_port {
        return Err(DuplicatePeerAddr)
      }
    }
  }
  let mut self_listed = false
  for entry in peers {
    if entry.node_id == node_id {
      self_listed = true
    }
  }
  if !self_listed {
    return Err(SelfMissing)
  }
  if leader_priority.length() != peers.length() {
    return Err(BadLeaderPriority)
  }
  // Counted from the peers side rather than from the list: with equal
  // lengths, "every peer appears exactly once in the list" is what
  // makes it a permutation. Checking the list's own entries cannot show
  // that -- [1, 1, 3] names only members of the table, yet drops node 2
  // out of the leader preference entirely.
  for entry in peers {
    let mut hits = 0
    for candidate in leader_priority {
      if candidate == entry.node_id {
        hits = hits + 1
      }
    }
    if hits != 1 {
      return Err(BadLeaderPriority)
    }
  }
  if listen_host.length() == 0 || listen_port < 1 || listen_port > 65535 {
    return Err(BadListenAddr)
  }
  Ok({ node_id, peers, leader_priority, listen_host, listen_port, secret, })
}

///|
/// This node's id.
pub fn ClusterConfig::node_id(self : ClusterConfig) -> UInt16 {
  self.node_id
}

///|
/// The full static peer table, in configuration order.
pub fn ClusterConfig::peers(self : ClusterConfig) -> Array[PeerEntry] {
  self.peers.copy()
}

///|
/// Number of configured members; always `STATIC_PEER_COUNT` once `new`
/// has accepted the configuration.
pub fn ClusterConfig::peer_count(self : ClusterConfig) -> Int32 {
  self.peers.length()
}

///|
/// Node ids most-preferred first, the static leader preference.
pub fn ClusterConfig::leader_priority(self : ClusterConfig) -> Array[UInt16] {
  self.leader_priority.copy()
}

///|
/// This node's `listen_peer` host -- the face replication binds to and
/// client traffic never reaches.
pub fn ClusterConfig::listen_host(self : ClusterConfig) -> String {
  self.listen_host
}

///|
/// This node's `listen_peer` port.
pub fn ClusterConfig::listen_port(self : ClusterConfig) -> Int32 {
  self.listen_port
}

///|
/// The peer channel's shared secret.
pub fn ClusterConfig::secret(self : ClusterConfig) -> PeerSecret {
  self.secret
}

///|
/// How many members must be durable before a write counts as committed.
///
/// Majority of the static table: three members means two, leader plus
/// one follower. Two of three is this number and nothing else --
/// there is no separate `min_in_sync_replicas` knob to drift away from
/// it.
///
/// # Example
///
/// ```mbt check
/// test {
///   assert_eq(@cluster.STATIC_PEER_COUNT, 3)
/// }
/// ```
pub fn ClusterConfig::quorum(self : ClusterConfig) -> Int32 {
  self.peers.length() / 2 + 1
}

///|
/// Look up one configured peer by id, or `None` when the table does not
/// contain it.
pub fn ClusterConfig::peer_entry(
  self : ClusterConfig,
  node_id : UInt16,
) -> PeerEntry? {
  for entry in self.peers {
    if entry.node_id == node_id {
      return Some(entry)
    }
  }
  None
}

///|
/// Whether `node_id` is one of the three configured members.
///
/// The check a peer handshake runs before it accepts an id off the
/// wire: an id that is not in the table is not a member, whatever
/// address it arrived from.
pub fn ClusterConfig::has_peer(self : ClusterConfig, node_id : UInt16) -> Bool {
  match self.peer_entry(node_id) {
    Some(_) => true
    None => false
  }
}

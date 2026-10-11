/// One static-cluster node: its identity, its peer links, and the two
/// entry points a transport wiring calls (T041, REQ-REP-001,
/// REQ-SEC-003).
///
/// A node here owns the peer *protocol* and the bookkeeping that
/// follows from it, not a socket. `serve_peer` and `dial_peer` take a
/// `@net.Conn` the caller already obtained -- accepted from
/// `listen_peer`, or dialed to a peer table row -- so the whole package
/// stays transport-neutral and the binding, the accept loop and the
/// connect retry stay with whatever wires it up. What the node decides
/// is whether a link is real: a connection counts only after both tags
/// verified, and it counts against a specific configured peer.
///
/// # What "up" means
///
/// A node is up when its caller has bound `listen_peer` and every other
/// member of the static table has an authenticated link to it. The
/// binding is observable only at the edge; `peers_connected` is the
/// node's own half of that statement, and the cluster test asserts both
/// -- three real listeners on three ports, and every node reporting
/// both of its peers linked.

///|
/// One authenticated link to one configured peer.
pub(all) struct PeerLink {
  /// The peer's node id, taken from the handshake rather than the
  /// socket, so a link is attributed to whoever proved it.
  peer_id : UInt16
  /// `true` when this node dialed, `false` when the peer dialed in.
  outbound : Bool
} derive(Eq, Debug)

///|
pub extend PeerLink with Eq::{not_equal, equal}

///|
pub extend PeerLink with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The mutable link table of one node, held behind a `Ref` so a node
/// can be shared between the accept task and the dial tasks that bring
/// it up without aliasing the node itself.
priv struct NodeCore {
  links : Array[PeerLink]
}

///|
/// One node of the static three-node cluster.
pub struct ClusterNode {
  priv config : ClusterConfig
  priv core : Ref[NodeCore]
}

///|
/// Build a node from a validated configuration. It starts with no
/// links; nothing is dialed and nothing is served until a transport
/// hands it a connection.
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
///   let config = match
///     @cluster.ClusterConfig::new(
///       1U.to_uint16(),
///       peers,
///       priority,
///       "127.0.0.1",
///       7191,
///       secret,
///     ) {
///     Ok(config) => config
///     Err(_) => fail("a well-formed static table must be accepted")
///   }
///   let node = @cluster.ClusterNode::new(config)
///   assert_eq(node.link_count(), 0)
///   assert_eq(node.peers_connected(), false)
/// }
/// ```
pub fn ClusterNode::new(config : ClusterConfig) -> ClusterNode {
  { config, core: Ref::Ref({ links: [], }), }
}

///|
/// This node's validated configuration.
pub fn ClusterNode::config(self : ClusterNode) -> ClusterConfig {
  self.config
}

///|
/// Serve one connection accepted on `listen_peer` to completion,
/// returning the link it became.
///
/// The handshake runs first; the link is recorded only after both tags
/// verified, so a refused connection leaves the node's view of the
/// cluster untouched.
///
/// # Errors
///
/// Whatever the handshake refused: `AuthFailed` (0x0006) for a wrong
/// secret or an id outside the static table, `MalformedPayload`
/// (0x0003) for a frame that is not a handshake, `BadLength` (0x0001)
/// for a frame that cannot describe one, and `Internal` (0x000A) when
/// the platform could not produce a fresh nonce.
pub async fn ClusterNode::serve_peer(
  self : ClusterNode,
  conn : &@net.Conn,
) -> Result[PeerLink, @protocol.ErrCode] {
  match peer_handshake_responder(self.config, conn) {
    Err(code) => Err(code)
    Ok(peer_id) => {
      let link = { peer_id, outbound: false, }
      self.core.val.links.push(link)
      Ok(link)
    }
  }
}

///|
/// Dial-side handshake on a connection opened to `expected`, returning
/// the link it became.
///
/// `expected` is the peer table row the transport dialed; the handshake
/// refuses an answer whose id disagrees with it, so a link can never be
/// recorded against a node the transport did not mean to reach.
///
/// # Errors
///
/// The same codes as `serve_peer`, plus `AuthFailed` when the listener
/// answers as a different node than `expected`.
pub async fn ClusterNode::dial_peer(
  self : ClusterNode,
  conn : &@net.Conn,
  expected : PeerEntry,
) -> Result[PeerLink, @protocol.ErrCode] {
  match peer_handshake_initiator(self.config, conn, expected) {
    Err(code) => Err(code)
    Ok(peer_id) => {
      let link = { peer_id, outbound: true, }
      self.core.val.links.push(link)
      Ok(link)
    }
  }
}

///|
/// Every authenticated link, in the order the handshakes completed.
pub fn ClusterNode::links(self : ClusterNode) -> Array[PeerLink] {
  self.core.val.links.copy()
}

///|
/// Number of authenticated links.
///
/// For a three-node cluster every node should end up with exactly two,
/// one per other member: a third would mean a duplicate link was
/// recorded, and one short means a peer never completed a handshake.
pub fn ClusterNode::link_count(self : ClusterNode) -> Int {
  self.core.val.links.length()
}

///|
/// Whether every other member of the static table has an authenticated
/// link, in either direction.
///
/// This is the node's own statement that it is up: it says nothing about
/// whether the caller bound `listen_peer`, which only the wiring that
/// bound it can observe.
pub fn ClusterNode::peers_connected(self : ClusterNode) -> Bool {
  let own_id = self.config.node_id()
  let mut missing = false
  for entry in self.config.peers() {
    if entry.node_id == own_id {
      continue
    }
    let mut found = false
    for link in self.core.val.links {
      if link.peer_id == entry.node_id {
        found = true
      }
    }
    if !found {
      missing = true
    }
  }
  !missing
}

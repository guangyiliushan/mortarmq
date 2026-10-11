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
/// What one peer has reported about its own log: how far it has written
/// and how far it has fsynced.
///
/// Kept per peer rather than as a single "the cluster is caught up"
/// number, because a quorum question is answered from individual
/// positions: which replicas are durable at or past a given sequence.
/// Both fields only ever move forward; an acknowledgement that would
/// move one backwards is refused instead of applied.
pub(all) struct FollowerProgress {
  peer_id : UInt16
  flushed_seq : UInt64
  dirty_seq : UInt64
} derive(Eq, Debug)

///|
pub extend FollowerProgress with Eq::{not_equal, equal}

///|
pub extend FollowerProgress with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The mutable link table and per-peer replication progress of one node,
/// held behind a `Ref` so a node can be shared between the accept task
/// and the dial tasks that bring it up without aliasing the node itself.
priv struct NodeCore {
  links : Array[PeerLink]
  followers : Array[FollowerProgress]
  mut quorum : QuorumState
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
  { config, core: Ref::Ref({ links: [], followers: [], quorum: Healthy, }), }
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

///|
/// This node's id -- the value it puts in an `APPEND` it sends or an
/// `APPEND_ACK` it returns.
pub fn ClusterNode::node_id(self : ClusterNode) -> UInt16 {
  self.config.node_id()
}

///|
/// Record one follower's reported positions.
///
/// An acknowledgement is accepted only if it is consistent and comes
/// from a real peer: `flushed_seq` above `dirty_seq` describes a state
/// no replica can be in, and a peer outside the static table is not a
/// member however it reached us. A refused acknowledgement changes
/// nothing, so a late or replayed ack can never move a position
/// backwards -- both are monotone by construction.
///
/// # Errors
///
/// * `MalformedPayload` (0x0003) for a self-contradictory or
///   out-of-table acknowledgement.
pub fn ClusterNode::record_append_ack(
  self : ClusterNode,
  ack : AppendAck,
) -> Result[Unit, @protocol.ErrCode] {
  if ack.flushed_seq > ack.dirty_seq {
    return Err(@protocol.MalformedPayload)
  }
  let config = self.config
  if ack.follower_id == config.node_id() || !config.has_peer(ack.follower_id) {
    return Err(@protocol.MalformedPayload)
  }
  let mut index = -1
  for position in 0..<self.core.val.followers.length() {
    if self.core.val.followers[position].peer_id == ack.follower_id {
      index = position
    }
  }
  if index < 0 {
    self.core.val.followers.push({
      peer_id: ack.follower_id,
      flushed_seq: ack.flushed_seq,
      dirty_seq: ack.dirty_seq,
    })
    return Ok(())
  }
  let previous = self.core.val.followers[index]
  let flushed = if ack.flushed_seq > previous.flushed_seq {
    ack.flushed_seq
  } else {
    previous.flushed_seq
  }
  let dirty = if ack.dirty_seq > previous.dirty_seq {
    ack.dirty_seq
  } else {
    previous.dirty_seq
  }
  self.core.val.followers[index] = {
    peer_id: ack.follower_id,
    flushed_seq: flushed,
    dirty_seq: dirty,
  }
  Ok(())
}

///|
/// The last positions one peer reported, or `None` if it has never
/// acknowledged anything.
pub fn ClusterNode::follower_progress(
  self : ClusterNode,
  peer_id : UInt16,
) -> FollowerProgress? {
  for progress in self.core.val.followers {
    if progress.peer_id == peer_id {
      return Some(progress)
    }
  }
  None
}

///|
/// The sequences every known peer has reported, both positions.
///
/// The quorum question T044 answers is a function of this list plus the
/// leader's own flushed position, which is why both positions are kept
/// per peer rather than collapsed into one "caught up" flag.
pub fn ClusterNode::follower_positions(
  self : ClusterNode,
) -> Array[FollowerProgress] {
  self.core.val.followers.copy()
}

///|
/// The tier this cluster's quorum is in, as this node last observed it.
///
/// Starts `Healthy`: a node that has completed no round has seen
/// nothing go wrong, and reporting read-only before the first attempt
/// would alarm on a cluster that has not yet been asked to do
/// anything. From then on it is re-evaluated at every round boundary,
/// so it clears itself when a round completes with a majority in sync
/// and sets itself the moment one cannot.
pub fn ClusterNode::quorum_state(self : ClusterNode) -> QuorumState {
  self.core.val.quorum
}

///|
/// Record that a quorum acknowledgement did not arrive inside its
/// deadline.
///
/// The write this round carried is not acknowledged; the tier becomes
/// read-only and stays there until a later round completes with a
/// majority. The caller reports `write_refusal` for it rather than
/// inventing an answer.
fn ClusterNode::note_ack_timeout(self : ClusterNode) -> Unit {
  self.core.val.quorum = ReadOnly(AckTimeout)
}

///|
/// Re-evaluate the tier from the positions now known, after a round
/// completed.
///
/// "In sync" means durable at exactly the leader's own position: a
/// member that has acknowledged nothing has told us nothing about where
/// it is, and a member that acknowledged an older position is behind.
/// The classification itself is `classify_quorum`, so a round and a
/// hand-rolled matrix row can never disagree.
fn ClusterNode::reclassify(
  self : ClusterNode,
  own_flushed_seq : UInt64,
) -> Unit {
  let config = self.config
  let mut in_sync = 1
  for entry in config.peers() {
    if entry.node_id == config.node_id() {
      continue
    }
    match self.follower_progress(entry.node_id) {
      Some(progress) =>
        if progress.flushed_seq == own_flushed_seq {
          in_sync = in_sync + 1
        }
      None => ()
    }
  }
  self.core.val.quorum = classify_quorum(
    in_sync,
    config.quorum(),
    in_sync < config.peer_count(),
    false,
  )
}

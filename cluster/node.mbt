/// One static-cluster node: its identity, its peer links, and the two
/// entry points a transport wiring calls.
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

///|
/// One authenticated link: the node that proved itself, and the
/// connection it proved itself over.
///
/// The two travel together on purpose. Splitting them -- handing a
/// function a connection and a different function an id -- would let a
/// batch claim to come from a node that connection never spoke for, and
/// an acknowledgement claiming to be from a third node could push the
/// commit horizon on behalf of nobody. Binding them makes "handshake
/// first" a property of the type rather than a calling convention: the
/// only way to obtain a `PeerLink` is to complete a handshake, and the
/// only id one carries is the id that handshake established.
///
/// The fields are private, so nothing outside this package can assemble
/// one, and no caller can pair an id with somebody else's connection.
/// What a caller outside the package does need -- the id and which way
/// the link was opened -- is exposed as methods.
pub struct PeerLink {
  priv peer_id : UInt16
  priv outbound : Bool
  priv conn : &@net.Conn
}

///|
/// The peer's node id, taken from the handshake rather than the socket,
/// so a link is attributed to whoever proved it.
pub fn PeerLink::peer_id(self : PeerLink) -> UInt16 {
  self.peer_id
}

///|
/// Whether this node dialed (`true`) or the peer dialed in (`false`).
pub fn PeerLink::outbound(self : PeerLink) -> Bool {
  self.outbound
}

///|
/// Release the transport; later reads and writes on it fail.
pub fn PeerLink::close(self : PeerLink) -> Unit {
  @net.Conn::close(self.conn)
}

///|
/// The connection this link was established over.
///
/// Deliberately not exported: replication and election code inside this
/// package need the bytes, and nothing outside it needs a way to send
/// on a link without going through the identity that came with it.
fn PeerLink::channel(self : PeerLink) -> &@net.Conn {
  self.conn
}

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
  // Members that have promised, and members that have installed, the
  // term this node is standing for. Cleared at the start of each round
  // so a promise from an abandoned attempt cannot be counted in a later
  // one.
  mut promised : Array[UInt16]
  mut installed : Array[UInt16]
  // The committed prefix this replica has been told about. It arrives
  // with an install, so it only ever moves forward.
  mut commit_seq : UInt64
  // A tier change nobody has read yet. Held as a value rather than as
  // a log, because what a watcher needs is that a change happened, not
  // every round that agreed with the change it already reported.
  mut quorum_event : @protocol.ErrCode?
  // Where the divergent tail was last cut back to, or nothing if this
  // replica has never truncated.
  mut last_truncation : UInt64?
  // How many election rounds have ended by running out the clock rather
  // than by an answer.
  mut election_timeouts : Int
  // Whether a leader has ever been observed here, and whether its lease
  // is currently held. The two are separate on purpose: a node that has
  // never heard of a leader and a node whose leader lapsed are both
  // leaderless, and only one of them has a moment to report.
  mut leader_seen : Bool
  mut lease_expired_at : UInt64?
  // The lease change nobody has read yet, held exactly as the quorum
  // one is so the two observability surfaces behave the same way.
  mut lease_event : @protocol.ErrCode?
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
  {
    config,
    core: Ref::Ref({
      links: [],
      followers: [],
      quorum: Healthy,
      promised: [],
      installed: [],
      commit_seq: 0UL,
      quorum_event: None,
      last_truncation: None,
      election_timeouts: 0,
      leader_seen: false,
      lease_expired_at: None,
      lease_event: None,
    }),
  }
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
      let link : PeerLink = { peer_id, outbound: false, conn, }
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
      let link : PeerLink = { peer_id, outbound: true, conn, }
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
  proved : UInt16,
) -> Result[Unit, @protocol.ErrCode] {
  // The id in the body is checked against the one the handshake proved
  // on this connection, never taken on its own. This function is public
  // because a wiring layer may want to feed it acknowledgements
  // directly, and a bare acknowledgement could otherwise name any
  // member of the table and move that member's position -- and with it
  // the commit horizon -- on its behalf.
  if ack.follower_id != proved {
    return Err(@protocol.AuthFailed)
  }
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
/// The quorum question the publish path asks is a function of this list
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
/// Re-evaluate the tier from the positions now known, and report what
/// a producer is owed for it.
///
/// This is the one place the write path decides what the cluster's
/// quorum is in. Every exit of a replication round comes through here,
/// so a link that died on the first byte and a link that never answered
/// inside its deadline are read by the same table instead of by two
/// hand-written answers -- and a round that never got as far as moving
/// a byte leaves the tier saying what the last round observed, rather
/// than leaving it claiming health it was not asked about.
///
/// "In sync" means durable at exactly this replica's own position: a
/// member that has acknowledged nothing has told us nothing about where
/// it is, and a member that acknowledged an older position is behind.
///
/// `ack_timeout` marks a round whose deadline passed before a majority
/// answered. It does not choose the row: `classify_quorum` reads
/// "no follower" first, because a cluster with no follower to form a
/// majority with has no deadline worth timing, and the reason a cluster
/// is read-only is that table's to name rather than this caller's.
///
/// The tier before the change is read, not overwritten blind, because
/// the difference between the two is what `take_quorum_event` turns
/// into a signal: losing the majority and getting it back are events,
/// while a cluster that simply stays read-only is a state.
///
/// # Returns
///
/// `write_refusal` for the tier just computed -- `None` while the
/// cluster still accepts writes, the registered code once it does not.
fn ClusterNode::refresh_quorum(
  self : ClusterNode,
  own_flushed_seq : UInt64,
  ack_timeout : Bool,
) -> @protocol.ErrCode? {
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
  let was = self.core.val.quorum
  let now = classify_quorum(
    in_sync,
    config.quorum(),
    in_sync < config.peer_count(),
    ack_timeout,
  )
  self.core.val.quorum = now
  match now.transition_into(was) {
    Some(code) => self.core.val.quorum_event = Some(code)
    None => ()
  }
  now.write_refusal()
}

///|
/// The tier change this node has not reported yet, consumed by reading.
///
/// `0x6001 QUORUM_LOST` when the cluster stopped accepting writes and
/// `0x600A QUORUM_RECOVERED` when it started again. These are edges
/// rather than states: a cluster that stays read-only reports the loss
/// once, because an alarm that repeats while nothing new has happened
/// is an alarm an operator learns to ignore.
///
/// Reading clears it. A newer edge replaces one that was never read,
/// since the later edge is the one describing where the cluster is now;
/// a consumer that needs every edge has to read between rounds.
pub fn ClusterNode::take_quorum_event(self : ClusterNode) -> @protocol.ErrCode? {
  let seen = self.core.val.quorum_event
  self.core.val.quorum_event = None
  seen
}

///|
/// The committed prefix this replica has been told about, or zero if it
/// has never been installed with one.
///
/// Reported in a prepare so a candidate comparing logs sees what each
/// member considers settled rather than only how far each has written:
/// a longer write is not the better log if the extra of it was never
/// committed.
pub fn ClusterNode::commit_seq(self : ClusterNode) -> UInt64 {
  self.core.val.commit_seq
}

///|
/// Adopt a committed prefix reported by an install, when it is newer
/// than the one already held.
///
/// Monotone: an install from an older term cannot walk the committed
/// prefix back, and a replayed install changes nothing.
///
/// Taken at what this replica's own log holds as well. The reported
/// prefix is a promise about what a majority has, not a position this
/// replica is in: a value past the end of this log would be a committed
/// prefix naming entries that are not here, and the horizon read off it
/// would call a write durable when no majority can recover it. So what
/// the leader says is settled is capped by what this replica actually
/// has, which is the same rule every implementation of this protocol
/// applies to the number that travels with an install.
pub fn ClusterNode::note_committed(
  self : ClusterNode,
  commit_seq : UInt64,
  log : &ReplicaLog,
) -> Unit {
  let held = log.last_appended_seq()
  let bounded = if commit_seq > held { held } else { commit_seq }
  if bounded > self.core.val.commit_seq {
    self.core.val.commit_seq = bounded
  }
}

///|
/// Where this replica's tail was last cut back to, or nothing if it has
/// never truncated.
///
/// A truncation is the one operation that legitimately moves a log's end
/// backwards, and it is rare enough that without a record it is
/// indistinguishable from the thing monitoring exists to catch: a log
/// that went backwards on its own. Recording where the cut landed says
/// that this decrease was the protocol's doing, at that sequence, and
/// that nothing below it moved.
///
/// It records the position the tail was cut *to*, so the sequence that
/// disappeared is everything above it -- which is exactly what the
/// follower reported next when it acknowledged the batch that followed.
/// `None` rather than zero distinguishes "never truncated" from "cut
/// back to the start of the log", which is a real case: a batch whose
/// base sequence is one takes an entire log with it.
pub fn ClusterNode::last_truncation(self : ClusterNode) -> UInt64? {
  self.core.val.last_truncation
}

///|
/// How many election rounds have ended by running out the clock rather
/// than by an answer.
///
/// A count rather than a last-event flag, because what decides whether
/// a cluster has a problem is the shape of the failures: one member that
/// missed one deadline is a slow network, while rounds that keep ending
/// this way are a cluster that cannot find a leader at all. Either way
/// the round is over rather than the connection, so the number is the
/// only place the difference shows up.
pub fn ClusterNode::election_timeouts(self : ClusterNode) -> Int {
  self.core.val.election_timeouts
}

///|
/// Count one election round that ended on its deadline.
fn ClusterNode::note_election_timeout(self : ClusterNode) -> Unit {
  self.core.val.election_timeouts = self.core.val.election_timeouts + 1
}

///|
/// Whether this node currently believes it has a leader.
///
/// False from the moment the node is built until one is observed, which
/// is the distinction a fresh node and a healthy one would otherwise
/// hide: both would say they accept writes, and only one of them has
/// anybody to replicate them to. False again once the lease lapses, so
/// the answer is about now rather than about ever.
pub fn ClusterNode::has_leader(self : ClusterNode) -> Bool {
  self.core.val.leader_seen && self.core.val.lease_expired_at is None
}

///|
/// The tick at which the leader's lease ran out, or nothing while it is
/// held or was never held at all.
///
/// Kept from the first moment of the lapse rather than from the last
/// check of it, so a lease that stays expired reports when it went --
/// the question an operator asks is how long the cluster has been
/// without a leader, not how often somebody looked.
pub fn ClusterNode::lease_expired_at(self : ClusterNode) -> UInt64? {
  self.core.val.lease_expired_at
}

///|
/// The lease change this node has not reported yet, consumed by reading.
///
/// `0x6006 LEASE_EXPIRED` on the transition into a lapsed lease, once:
/// a lease that stays expired is one event, not one per tick it is
/// checked on. Reading clears it, and a later lapse replaces one that
/// was never read, since the later one is the one describing where the
/// cluster is now. The same shape as `take_quorum_event`, so a consumer
/// that handles one can handle the other.
pub fn ClusterNode::take_lease_event(self : ClusterNode) -> @protocol.ErrCode? {
  let seen = self.core.val.lease_event
  self.core.val.lease_event = None
  seen
}

///|
/// Record that the leader's lease has run out, at `now_ms`.
///
/// Only the first transition counts: a lease already expired is left
/// reporting the moment it went rather than the moment somebody
/// noticed, and no second event is raised for a cluster that has not
/// changed. `has_leader` goes false either way.
pub fn ClusterNode::note_lease_expired(
  self : ClusterNode,
  now_ms : UInt64,
) -> Unit {
  self.core.val.leader_seen = true
  if self.core.val.lease_expired_at is None {
    self.core.val.lease_expired_at = Some(now_ms)
    self.core.val.lease_event = Some(@protocol.LeaseExpired)
  }
}

///|
/// Record that a leader is believed in again.
///
/// A lease that is refreshed, or a leader that is installed, both land
/// here: what they share is that this node has somebody to follow again.
/// The lapse is forgotten so the next one is a new event rather than a
/// continuation of the last.
pub fn ClusterNode::note_lease_refreshed(self : ClusterNode) -> Unit {
  self.core.val.leader_seen = true
  self.core.val.lease_expired_at = None
}

///|
/// Open an election round, forgetting every promise and install the
/// last one collected.
///
/// The candidate's own term is durable before this is called, so its
/// own promise counts from the first moment rather than being added by
/// hand later. A promise carried across rounds is how a candidate wins
/// with numbers nobody is responsible for, so it is dropped here.
pub fn ClusterNode::begin_election(self : ClusterNode) -> Unit {
  self.core.val.promised = []
  self.core.val.installed = []
}

///|
/// Record that `responder_id` has promised the term this round stands
/// for.
///
/// An answer from an unknown peer, from this node itself, from a
/// different term, or one whose own positions contradict each other is
/// refused rather than counted: a quorum built from answers nobody is
/// responsible for is not a quorum.
///
/// # Errors
///
/// * `MalformedPayload` (0x0003) for a peer outside the static table,
///   or one reporting a flushed position above its own written one.
/// * `StaleLeaderEpoch` (0x6005) for a promise on a term this round did
///   not propose -- somebody else is already further along.
pub fn ClusterNode::record_prepare_ack(
  self : ClusterNode,
  ack : PrepareAckMsg,
  candidate_epoch : UInt64,
  proved : UInt16,
) -> Result[Unit, @protocol.ErrCode] {
  // Identity comes from the caller's attestation; the body only has to
  // agree with it, so a bare acknowledgement cannot vouch for itself.
  if ack.responder_id != proved {
    return Err(@protocol.AuthFailed)
  }
  let config = self.config
  if ack.responder_id == config.node_id() || !config.has_peer(ack.responder_id) {
    return Err(@protocol.MalformedPayload)
  }
  // The member has committed further than this candidate has. Standing
  // anyway would install a committed prefix smaller than a member
  // already holds -- an unclean election, which the design leaves to an
  // operator rather than resolving silently. Choosing a better log and
  // catching up first is what would make standing legal, and this node
  // cannot pull from a member, so the promise is refused instead of
  // counted.
  if ack.commit_seq > self.commit_seq() {
    return Err(@protocol.UncleanElectionRejected)
  }
  if ack.promised_epoch != candidate_epoch {
    return Err(@protocol.StaleLeaderEpoch)
  }
  if ack.last_flushed_seq > ack.last_seq {
    return Err(@protocol.MalformedPayload)
  }
  // A member's promise is a set, not a tally. Counting the same member
  // twice would let one member out of three form a quorum on its own,
  // which is the whole thing the quorum exists to prevent. A second
  // answer from the same member is redundant rather than malformed, so
  // it is accepted and simply does not count again.
  if !self.core.val.promised.contains(ack.responder_id) {
    self.core.val.promised.push(ack.responder_id)
  }
  Ok(())
}

///|
/// Record that `responder_id` has made the term durable.
///
/// # Errors
///
/// * `MalformedPayload` (0x0003) for a peer outside the static table.
/// * `StaleLeaderEpoch` (0x6005) for an install of a different term --
///   an answer from a round this node is no longer running.
pub fn ClusterNode::record_install_ack(
  self : ClusterNode,
  ack : InstallAckMsg,
  epoch : UInt64,
  proved : UInt16,
) -> Result[Unit, @protocol.ErrCode] {
  if ack.responder_id != proved {
    return Err(@protocol.AuthFailed)
  }
  let config = self.config
  if ack.responder_id == config.node_id() || !config.has_peer(ack.responder_id) {
    return Err(@protocol.MalformedPayload)
  }
  if ack.epoch != epoch {
    return Err(@protocol.StaleLeaderEpoch)
  }
  // The same rule as a promise: one member, one install. Two answers
  // from the same member are one install answered twice.
  if !self.core.val.installed.contains(ack.responder_id) {
    self.core.val.installed.push(ack.responder_id)
  }
  Ok(())
}

///|
/// How many promises this round holds, counting the candidate's own.
///
/// The candidate promised its own term durably before asking anyone, so
/// a round with no answers yet already holds one -- and a quorum of
/// three is that one plus two members, not two members on their own.
pub fn ClusterNode::prepared_count(self : ClusterNode) -> Int {
  self.core.val.promised.length() + 1
}

///|
/// How many installs this round holds, counting the candidate's own.
///
/// The candidate's own term is the same durable record its promise
/// wrote, so it is already taken up on the node that proposed it.
pub fn ClusterNode::installed_count(self : ClusterNode) -> Int {
  self.core.val.installed.length() + 1
}

///|
/// Whether a majority has promised the term.
pub fn ClusterNode::has_prepare_quorum(self : ClusterNode) -> Bool {
  self.prepared_count() >= self.config.quorum()
}

///|
/// Whether a majority has made the term durable.
pub fn ClusterNode::has_install_quorum(self : ClusterNode) -> Bool {
  self.installed_count() >= self.config.quorum()
}

///|
/// The members that promised this round, in the order they answered.
pub fn ClusterNode::promised_members(self : ClusterNode) -> Array[UInt16] {
  self.core.val.promised.copy()
}

///|
/// The members that installed this round, in the order they answered.
pub fn ClusterNode::installed_members(self : ClusterNode) -> Array[UInt16] {
  self.core.val.installed.copy()
}

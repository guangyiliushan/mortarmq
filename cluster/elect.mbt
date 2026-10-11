/// One election round over the peer channel: promises first, installs
/// second, leadership only after a majority of each.
///
/// ```text
/// candidate            member                  candidate
///   -- PREPARE(e) -------->  persist promise(e)
///   <--- PREPARE_ACK ------  positions, committed prefix
///   ... one per member, until a majority has promised ...
///   -- INSTALL(e, c) ----->  persist term, adopt commit point
///   <--- INSTALL_ACK ------  flushed position
///   ... one per member, until a majority has installed ...
///   = leader at e =
/// ```
///
/// Two rounds rather than one, and the split is the point. A candidate
/// that stopped at the promises would know who would follow it but not
/// that anybody had the term; a candidate that skipped straight to
/// installs would be writing over promises nobody made. The prepare
/// decides *who*, the install decides *where the term is durable*, and
/// leadership is what happens only after both.
///
/// # What this does not decide
///
/// Whether the lease that triggered the round was right to expire is
/// not this code's problem -- timing only decides liveness, and the
/// promise each member persists is what decides safety. Two candidates
/// racing the same followers resolve in `serve_prepare`, where a term
/// already promised is refused as stale, not here.

///|
/// Ask one member to promise `candidate_epoch`.
///
/// The candidate reports where its own log and committed prefix stand
/// alongside the term it proposes, so a member sees what it would be
/// joining; the member answers with its own positions.
///
/// Those positions are load-bearing rather than reported for interest.
/// A member that has committed further than this candidate has makes
/// standing an unclean election, because this candidate would install a
/// committed prefix smaller than a member already holds -- so the
/// promise is refused instead of counted. Choosing a better log and
/// catching up to it first is what would make standing legal, and this
/// node cannot yet pull from a member, so the choice of consistency
/// over availability is left where the design puts it: with an operator.
///
/// # Errors
///
/// * `MalformedPayload` (0x0003) for a proposal of term zero, or for a
///   reply that is not an acknowledgement to the round in flight.
/// * `StaleLeaderEpoch` (0x6005) when this node is not holding the term
///   it is standing for -- a proposal has to name one this node has
///   already written down, or every promise it collects would be for
///   something a crash erases -- or when the member promised a
///   different term, which means somebody is already further along than
///   this candidate.
/// * `ElectionTimeout` (0x600C) when the member does not answer inside
///   the round's own deadline. The round is over rather than the
///   connection: nothing more is written and nothing is closed, because
///   the caller can run the round again.
/// * `UncleanElectionRejected` (0x600B) when a member has committed
///   further than this candidate has.
/// * `AuthFailed` (0x0006) when the answer comes from outside the
///   static table.
/// * Whatever the connection reports, and whatever the member refused.
pub async fn ClusterNode::send_prepare(
  self : ClusterNode,
  link : PeerLink,
  log : &ReplicaLog,
  epoch : LeaderEpoch,
  candidate_epoch : UInt64,
) -> Result[PrepareAckMsg, @protocol.ErrCode] {
  if candidate_epoch == 0UL {
    return Err(@protocol.MalformedPayload)
  }
  // The candidate stands for a term it already holds. Writing it down
  // first is what makes the promises it collects worth anything: a
  // proposal for a term this node never recorded would have every
  // member that answered give up its right to answer a lower one, and
  // a crash would take the term with it.
  if epoch.current() != candidate_epoch {
    return Err(@protocol.StaleLeaderEpoch)
  }
  let request : PeerMsg = Prepare({
    candidate_id: self.node_id(),
    candidate_epoch,
    last_seq: log.last_appended_seq(),
    last_leader_epoch: epoch.current(),
    commit_seq: self.commit_seq(),
  })
  match write_peer_msg(link.channel(), request) {
    Err(code) => return Err(code)
    Ok(_) => ()
  }
  let reply = match
    @async.with_timeout_opt(PREPARE_TIMEOUT_MS, () => {
      read_peer_msg(link.channel(), PEER_FRAME_TIMEOUT_MS)
    }) {
    // The member did not answer in time. This is the round ending, not
    // the connection: a silent member is more often slow than gone, and
    // the caller can run the round again on the next tick. It is
    // counted so rounds that keep ending this way are visible as that
    // rather than as one more failure among others.
    None => {
      self.note_election_timeout()
      return Err(@protocol.ElectionTimeout)
    }
    Some(Err(code)) => return Err(code)
    Some(Ok(msg)) => msg
  }
  match refusal(reply) {
    Some(code) => return Err(code)
    None => ()
  }
  let ack = match reply {
    PrepareAck(ack) => ack
    _ => return Err(@protocol.MalformedPayload)
  }
  match self.record_prepare_ack(ack, candidate_epoch, link.peer_id()) {
    Err(code) => Err(code)
    Ok(_) => Ok(ack)
  }
}

///|
/// Answer one prepare: promise the term durably, then report where this
/// log stands.
///
/// The promise is written before the acknowledgement goes out, so a
/// member that has answered has already given up its right to answer a
/// lower term. That single ordering is what keeps two candidates from
/// both collecting the same followers.
///
/// # Errors
///
/// * `AuthFailed` (0x0006) when the candidate is outside the static
///   table or is this node -- nobody runs against itself.
/// * `StaleLeaderEpoch` (0x6005) for a term at or below the one already
///   held, or when the promise could not be written durably. Nothing
///   about this replica moves in either case.
/// * `MalformedPayload` (0x0003) for any frame that is not a prepare.
pub async fn ClusterNode::serve_prepare(
  self : ClusterNode,
  link : PeerLink,
  epoch : LeaderEpoch,
  log : &ReplicaLog,
) -> Result[PrepareAckMsg, @protocol.ErrCode] {
  let request = match read_peer_msg(link.channel(), PEER_FRAME_TIMEOUT_MS) {
    Err(code) => return Err(code)
    Ok(msg) => msg
  }
  match refusal(request) {
    Some(code) => return Err(code)
    None => ()
  }
  let proposed = match request {
    Prepare(msg) => msg
    _ => return refuse(link.channel(), @protocol.MalformedPayload)
  }
  let config = self.config()
  // The prepare must come from the node that proved itself on this link.
  // The handshake already excluded this node itself, so equality with the
  // link's id is the whole check -- and it is a stronger one than
  // membership, which any member of the table would satisfy.
  if proposed.candidate_id != link.peer_id() {
    return refuse(link.channel(), @protocol.AuthFailed)
  }
  match epoch.elect(proposed.candidate_epoch) {
    Err(code) => return refuse(link.channel(), code)
    Ok(_) => ()
  }
  let ack : PrepareAckMsg = {
    responder_id: config.node_id(),
    promised_epoch: proposed.candidate_epoch,
    last_seq: log.last_appended_seq(),
    last_flushed_seq: log.last_flushed_seq(),
    commit_seq: self.commit_seq(),
  }
  match write_peer_msg(link.channel(), PrepareAck(ack)) {
    Err(code) => return Err(code)
    Ok(_) => ()
  }
  Ok(ack)
}

///|
/// Tell one member that `candidate_epoch` is now in force, with the
/// committed position it should adopt.
///
/// Only sent once a majority has already promised the term, so a member
/// receiving this is not being asked to decide anything -- it is being
/// told what was decided, and its job is to make it durable before it
/// answers.
///
/// # Errors
///
/// * `MalformedPayload` (0x0003) for a reply that is not an
///   acknowledgement to this round.
/// * `StaleLeaderEpoch` (0x6005) when this node is not holding the term
///   it is installing -- the same rule as the prepare that preceded it,
///   checked on this side too because the two can be called apart --
///   or when the member installed a different term, which means it is
///   answering somebody else's round.
/// * `ElectionTimeout` (0x600C) when the member does not answer inside
///   the round's own deadline.
/// * `AuthFailed` (0x0006) when the answer comes from outside the
///   static table.
pub async fn ClusterNode::send_install(
  self : ClusterNode,
  link : PeerLink,
  epoch : LeaderEpoch,
  candidate_epoch : UInt64,
  commit_seq : UInt64,
) -> Result[InstallAckMsg, @protocol.ErrCode] {
  if candidate_epoch == 0UL {
    return Err(@protocol.MalformedPayload)
  }
  if epoch.current() != candidate_epoch {
    return Err(@protocol.StaleLeaderEpoch)
  }
  let request : PeerMsg = Install({
    leader_id: self.node_id(),
    epoch: candidate_epoch,
    commit_seq,
  })
  match write_peer_msg(link.channel(), request) {
    Err(code) => return Err(code)
    Ok(_) => ()
  }
  let reply = match
    @async.with_timeout_opt(PREPARE_TIMEOUT_MS, () => {
      read_peer_msg(link.channel(), PEER_FRAME_TIMEOUT_MS)
    }) {
    None => {
      self.note_election_timeout()
      return Err(@protocol.ElectionTimeout)
    }
    Some(Err(code)) => return Err(code)
    Some(Ok(msg)) => msg
  }
  match refusal(reply) {
    Some(code) => return Err(code)
    None => ()
  }
  let ack = match reply {
    InstallAck(ack) => ack
    _ => return Err(@protocol.MalformedPayload)
  }
  match self.record_install_ack(ack, candidate_epoch, link.peer_id()) {
    Err(code) => Err(code)
    Ok(_) => Ok(ack)
  }
}

///|
/// Answer one install: take the term up durably, adopt its committed
/// position, and report what is flushed.
///
/// The term is written before the acknowledgement goes out, so a member
/// that says it installed has actually made the term durable rather
/// than merely received it -- which is the whole difference between a
/// majority that exists and a majority that would survive a crash.
///
/// # Errors
///
/// * `AuthFailed` (0x0006) when the leader is outside the static table
///   or is this node.
/// * `StaleLeaderEpoch` (0x6005) for a term older than the one held,
///   or when the term could not be written durably.
/// * `MalformedPayload` (0x0003) for any frame that is not an install.
pub async fn ClusterNode::serve_install(
  self : ClusterNode,
  link : PeerLink,
  epoch : LeaderEpoch,
  log : &ReplicaLog,
) -> Result[InstallAckMsg, @protocol.ErrCode] {
  let request = match read_peer_msg(link.channel(), PEER_FRAME_TIMEOUT_MS) {
    Err(code) => return Err(code)
    Ok(msg) => msg
  }
  match refusal(request) {
    Some(code) => return Err(code)
    None => ()
  }
  let incoming = match request {
    Install(msg) => msg
    _ => return refuse(link.channel(), @protocol.MalformedPayload)
  }
  let config = self.config()
  if incoming.leader_id != link.peer_id() {
    return refuse(link.channel(), @protocol.AuthFailed)
  }
  match epoch.install(incoming.epoch) {
    Err(code) => return refuse(link.channel(), code)
    Ok(_) => ()
  }
  // The committed prefix arrives with the term, and only moves forward.
  self.note_committed(incoming.commit_seq)
  let ack : InstallAckMsg = {
    responder_id: config.node_id(),
    epoch: incoming.epoch,
    flushed_seq: log.last_flushed_seq(),
  }
  match write_peer_msg(link.channel(), InstallAck(ack)) {
    Err(code) => return Err(code)
    Ok(_) => ()
  }
  Ok(ack)
}

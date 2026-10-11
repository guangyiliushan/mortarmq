/// The APPEND / APPEND_ACK replication stream.
///
/// One round of the normal write path, in the order it has to happen:
///
/// ```text
/// leader  append + fsync locally        last_flushed_seq advances
/// leader  APPEND(base_seq, entries)     only after it is durable
/// follower append locally               last_appended_seq advances
/// follower fsync when told to           last_flushed_seq advances
/// follower APPEND_ACK(flushed, dirty)   both positions travel back
/// leader  record the positions          per-peer progress moves up
/// ```
///
/// Two ordering rules are load-bearing and both are asserted in
/// `cluster/replicate_test.mbt`:
///
/// 1. **The leader is durable before it ships.** A follower can never
///    be asked to hold an entry the leader itself has not fsynced, so
///    `commit_seq` can never rest on something the leader cannot
///    recover from either.
/// 2. **The follower acks after its own fsync.** `flushed_seq` in an
///    acknowledgement is read back from the log *after* the append
///    returned, so a reply can never claim durability the write has not
///    reached. `dirty_seq` travelling alongside it is what makes a
///    follower that was told not to flush show up as lagging rather
///    than looking caught up.
///
/// # Boundaries
///
/// * Nothing here decides whether the write is *committed* -- that is
///   the majority-fsync gate, and it reads the per-peer
///   positions this stream records.
/// * A batch from an older term is refused with `StaleLeaderEpoch`
///   before storage append, so a stale leader leaves no writes behind.
///   A batch from a newer term is adopted durably first, so the writes
///   it carries land under a promise this replica has recorded.
/// * Rounds are sequential: one batch is written and its
///   acknowledgement read before the next batch starts. Pipelining is
///   an optimization and none of the ordering rules above depend on it.

///|
/// Run one replication round as the leader: make `payloads` durable
/// locally, ship them to `peer`, and record what comes back.
///
/// `flush_after_append` is the instruction for the *follower* -- the
/// leader always flushes its own copy first, per rule 1 above.
/// `ack_deadline_ms` is how long to wait for the majority's answer
/// before the cluster declares itself read-only; the standing default
/// is `QUORUM_ACK_TIMEOUT_MS`.
///
/// # Errors
///
/// * `MalformedPayload` (0x0003) for an empty batch, which has no base
///   sequence to name, and for an acknowledgement that is not an
///   acknowledgement.
/// * `BadLength` (0x0001) when the encoded batch would exceed the
///   protocol frame bound; refused locally rather than by the far end,
///   so the caller learns which batch was too large.
/// * Whatever the follower refused, carried back from its `Reject`
///   frame, and `AuthFailed` (0x0006) if an acknowledgement arrives
///   from a node outside the static table.
/// * `ReadOnlyDegraded` (0x6002) when the deadline expires first: the
///   write is not committed and is not acknowledged.
pub async fn ClusterNode::send_append(
  self : ClusterNode,
  link : PeerLink,
  log : &ReplicaLog,
  leader_epoch : UInt64,
  payloads : Array[Bytes],
  flush_after_append : Bool,
  ack_deadline_ms : Int,
) -> Result[AppendAck, @protocol.ErrCode] {
  // An empty batch has no first entry, so it has no base sequence to
  // name; that is a caller bug rather than a message to send.
  if payloads.length() == 0 {
    return Err(@protocol.MalformedPayload)
  }
  // The deadline is not optional: a round that waits forever has no way
  // to notice the quorum is gone, and a producer would hang on an answer
  // that is already known to be no.
  if ack_deadline_ms <= 0 {
    return Err(@protocol.MalformedPayload)
  }
  let base_seq = match log.append(payloads, true) {
    Err(code) => return Err(code)
    Ok(sequence) => sequence
  }
  self.ship_batch(
    link, log, leader_epoch, base_seq, payloads, flush_after_append, ack_deadline_ms,
  )
}

///|
/// Send one batch that is already in this log, and record what the
/// follower reports back.
///
/// Split out from `send_append` because catch-up sends entries this
/// replica already holds rather than ones it is writing now: the
/// shipping half is identical and only the caller differs. Everything
/// after the write -- the deadline, the refusal, the acknowledgement,
/// the tier re-evaluation -- is common to both.
///
/// # Errors
///
/// As `send_append`, plus `MalformedPayload` (0x0003) for an empty
/// batch, which has no base sequence to name.
async fn ClusterNode::ship_batch(
  self : ClusterNode,
  link : PeerLink,
  log : &ReplicaLog,
  leader_epoch : UInt64,
  base_seq : UInt64,
  payloads : Array[Bytes],
  flush_after_append : Bool,
  ack_deadline_ms : Int,
) -> Result[AppendAck, @protocol.ErrCode] {
  if payloads.length() == 0 {
    return Err(@protocol.MalformedPayload)
  }
  if ack_deadline_ms <= 0 {
    return Err(@protocol.MalformedPayload)
  }
  let batch = Append({
    leader_id: self.node_id(),
    leader_epoch,
    base_seq,
    flush_after_append,
    entries: payloads,
  })
  let frame = encode_peer_msg(batch)
  // Checked the same way `read_peer_msg` checks an incoming frame, but
  // before anything is written: the far end would refuse this frame, and
  // the caller should learn which batch was too large instead.
  let body_len = frame.length() - PEER_LEN_BYTES
  if body_len > @protocol.MAX_FRAME_LEN.reinterpret_as_int() {
    return Err(@protocol.BadLength)
  }
  match @net.Conn::write_all(link.channel(), frame) {
    Err(code) => return Err(code)
    Ok(_) => ()
  }
  let reply = match
    @async.with_timeout_opt(ack_deadline_ms, () => {
      read_peer_msg(link.channel(), PEER_FRAME_TIMEOUT_MS)
    }) {
    // The majority did not answer inside the deadline. The write stays
    // uncommitted, the cluster goes read-only, and the caller is told
    // no rather than left waiting or handed a success it cannot stand
    // behind. The link is suspect after a cancelled read, so the caller
    // is expected to tear it down rather than reuse it.
    None => {
      self.note_ack_timeout()
      return Err(@protocol.ReadOnlyDegraded)
    }
    Some(Err(code)) => return Err(code)
    Some(Ok(msg)) => msg
  }
  match refusal(reply) {
    Some(code) => return Err(code)
    None => ()
  }
  match reply {
    Ack(ack) =>
      match self.record_append_ack(ack, link.peer_id()) {
        Err(code) => Err(code)
        Ok(_) => {
          // A completed round is the moment the tier is re-evaluated:
          // this is where a cluster that lost its majority notices, and
          // where one that got it back stops being read-only.
          self.reclassify(log.last_flushed_seq())
          Ok(ack)
        }
      }
    _ => Err(@protocol.MalformedPayload)
  }
}

///|
/// Run one replication round as the follower: apply the batch to `log`
/// and reply with both positions.
///
/// The durability of this batch is the leader's instruction, not the
/// follower's choice: `flush_after_append` decides whether the write is
/// fsynced before the acknowledgement is built, which is why an ack can
/// never report a `flushed_seq` the log has not reached.
///
/// # Errors
///
/// * `AuthFailed` (0x0006) when the batch names a leader outside the
///   static table, or names this node -- a replica does not replicate
///   to itself.
/// * The local log's own failure code, carried back in a `Reject` so
///   the leader learns why this round did not land. Whether the link
///   stays open after that is the caller's decision; this function
///   reports and stops.
/// * `CatchupRequired` (0x6007) when `base_seq` is past this replica's
///   end. Taking it would punch a hole in the log, and this format
///   tolerates none.
/// * `DivergentCommitted` (0x6009) when the divergent tail reaches down
///   to or below what this replica has committed. The tail is refused
///   rather than cut: a cut there would take committed data with it,
///   and reconciliation is the operator's call, not the protocol's.
/// * `StaleLeaderEpoch` (0x6005) when the batch carries an older term
///   than this replica has already promised. Refused before the log is
///   touched, so a stale leader leaves no writes behind.
/// * `MalformedPayload` (0x0003) for any frame that is not an `APPEND`.
pub async fn ClusterNode::serve_append(
  self : ClusterNode,
  link : PeerLink,
  log : &ReplicaLog,
  epoch : LeaderEpoch,
) -> Result[AppendAck, @protocol.ErrCode] {
  let request = match read_peer_msg(link.channel(), PEER_FRAME_TIMEOUT_MS) {
    Err(code) => return Err(code)
    Ok(msg) => msg
  }
  match refusal(request) {
    Some(code) => return Err(code)
    None => ()
  }
  let batch = match request {
    Append(batch) => batch
    _ => return refuse(link.channel(), @protocol.MalformedPayload)
  }
  let config = self.config()
  // The batch must name the node that proved itself on this link. An id
  // from the table that never spoke on this connection is not a voice
  // here, whatever address it arrived from -- accepting one would let
  // any reachable member write into this log as any other.
  if batch.leader_id != link.peer_id() {
    return refuse(link.channel(), @protocol.AuthFailed)
  }
  // The fence runs before storage append, never after. A batch from an
  // older term has to leave this replica's log exactly as it found it:
  // writing first and refusing afterwards would still have left the
  // bytes behind, which is the split a stale leader is trying to open.
  if batch.leader_epoch < epoch.current() {
    return refuse(link.channel(), @protocol.StaleLeaderEpoch)
  }
  if batch.leader_epoch > epoch.current() {
    // A newer term. Adopt it -- durably, or not at all -- before any
    // of the writes it carries are allowed to land; if the metadata
    // write fails, so does the batch.
    match epoch.elect(batch.leader_epoch) {
      Err(code) => return refuse(link.channel(), code)
      Ok(_) => ()
    }
  }
  // Where this replica's log ends and where the batch says it should
  // continue. An empty log ends at zero, so the next sequence is always
  // one above the last one held -- or one when nothing is held at all.
  let next_sequence = log.last_appended_seq() + 1UL
  if batch.base_seq == 0UL {
    // Sequence zero names no entry; a batch that starts there would
    // truncate the log away entirely.
    return refuse(link.channel(), @protocol.MalformedPayload)
  }
  if batch.base_seq > next_sequence {
    // The leader is ahead of us: entries this replica has never seen.
    // Taking the batch would leave sequences missing from the middle of
    // the log, and this format has no legitimate holes -- a gap is
    // corruption, not a rewind marker.
    return refuse(link.channel(), @protocol.CatchupRequired)
  }
  if batch.base_seq < next_sequence {
    // A divergent tail: what this replica holds above the cut belongs to
    // a history the leader does not share. It goes before the batch
    // lands, so the two never coexist.
    let cut = batch.base_seq - 1UL
    // The committed prefix is not in reach of that cut. Nothing about
    // the sender guarantees it: a leader's own append position says
    // nothing about what this replica has already committed, and a
    // stale or buggy one can offer a base below it. Truncating there
    // would destroy committed data, so the divergence is reported as
    // what it is rather than repaired by writing over it.
    if cut < self.commit_seq() {
      return refuse(link.channel(), @protocol.DivergentCommitted)
    }
    match log.truncate(cut) {
      Err(code) => return refuse(link.channel(), code)
      Ok(_) => ()
    }
  }
  let follower_id = config.node_id()
  let leader_epoch = batch.leader_epoch
  match log.append(batch.entries, batch.flush_after_append) {
    Err(code) => return refuse(link.channel(), code)
    Ok(_) => ()
  }
  let ack : AppendAck = {
    follower_id,
    leader_epoch,
    flushed_seq: log.last_flushed_seq(),
    dirty_seq: log.last_appended_seq(),
  }
  match write_peer_msg(link.channel(), Ack(ack)) {
    Err(code) => return Err(code)
    Ok(_) => ()
  }
  Ok(ack)
}

///|
/// Bring a follower that is behind up to this log's end.
///
/// The position is read from what that follower last reported rather
/// than guessed: an acknowledgement carrying `dirty_seq` says exactly
/// how much it has, and a follower that never acknowledged starts from
/// the beginning. Batches are bounded so one round-trip cannot become
/// an unbounded write, and the loop stops the moment the follower is
/// caught up or stops making progress.
///
/// This is what a replica that was away needs on its return. It missed
/// entries the rest of the cluster already has, and refusing it forever
/// would leave the cluster permanently short of a member -- so the
/// answer is to send what it is missing, not to leave it behind.
///
/// Returns the sequence this log ends at, which is where the follower
/// now stands.
///
/// # Errors
///
/// * `MalformedPayload` (0x0003) for a non-positive batch size or
///   deadline: a catch-up with neither would either overrun the
///   protocol bound or never notice it had stalled.
/// * `CatchupRequired` (0x6007) when the log cannot supply the next
///   position, or when a batch made no progress. Stopping beats
///   re-sending the same entries forever, and a log with a hole in it
///   is a corruption for the storage layer to find, not for catch-up to
///   paper over.
/// * Whatever a round reports, including a quorum that timed out.
pub async fn ClusterNode::catch_up(
  self : ClusterNode,
  link : PeerLink,
  log : &ReplicaLog,
  epoch : LeaderEpoch,
  batch_limit : Int,
  ack_deadline_ms : Int,
) -> Result[UInt64, @protocol.ErrCode] {
  if batch_limit <= 0 || ack_deadline_ms <= 0 {
    return Err(@protocol.MalformedPayload)
  }
  let peer_id = link.peer_id()
  let target = log.last_appended_seq()
  let mut next = match self.follower_progress(peer_id) {
    None => 1UL
    Some(progress) => progress.dirty_seq + 1UL
  }
  while next <= target {
    let payloads = match log.read(next, batch_limit) {
      Err(code) => return Err(code)
      Ok(found) => found
    }
    if payloads.length() == 0 {
      // Nothing at this position: the log cannot fill the gap, and
      // re-sending would send the same nothing again.
      return Err(@protocol.CatchupRequired)
    }
    match
      self.ship_batch(
        link,
        log,
        epoch.current(),
        next,
        payloads,
        true,
        ack_deadline_ms,
      ) {
      Err(code) => return Err(code)
      Ok(_) => ()
    }
    let advanced = match self.follower_progress(peer_id) {
      None => false
      Some(progress) => progress.dirty_seq + 1UL > next
    }
    if !advanced {
      // The batch went out and the position did not move: no progress,
      // so stop rather than send it again.
      return Err(@protocol.CatchupRequired)
    }
    next = match self.follower_progress(peer_id) {
      None => next
      Some(progress) => progress.dirty_seq + 1UL
    }
  }
  Ok(target)
}

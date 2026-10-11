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
  conn : &@net.Conn,
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
  match @net.Conn::write_all(conn, frame) {
    Err(code) => return Err(code)
    Ok(_) => ()
  }
  let reply = match
    @async.with_timeout_opt(ack_deadline_ms, () => read_peer_msg(conn)) {
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
      match self.record_append_ack(ack) {
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
/// * `StaleLeaderEpoch` (0x6005) when the batch carries an older term
///   than this replica has already promised. Refused before the log is
///   touched, so a stale leader leaves no writes behind.
/// * `MalformedPayload` (0x0003) for any frame that is not an `APPEND`.
pub async fn ClusterNode::serve_append(
  self : ClusterNode,
  conn : &@net.Conn,
  log : &ReplicaLog,
  epoch : LeaderEpoch,
) -> Result[AppendAck, @protocol.ErrCode] {
  let request = match read_peer_msg(conn) {
    Err(code) => return Err(code)
    Ok(msg) => msg
  }
  match refusal(request) {
    Some(code) => return Err(code)
    None => ()
  }
  let batch = match request {
    Append(batch) => batch
    _ => return refuse(conn, @protocol.MalformedPayload)
  }
  let config = self.config()
  if batch.leader_id == config.node_id() || !config.has_peer(batch.leader_id) {
    return refuse(conn, @protocol.AuthFailed)
  }
  // The fence runs before storage append, never after. A batch from an
  // older term has to leave this replica's log exactly as it found it:
  // writing first and refusing afterwards would still have left the
  // bytes behind, which is the split a stale leader is trying to open.
  if batch.leader_epoch < epoch.current() {
    return refuse(conn, @protocol.StaleLeaderEpoch)
  }
  if batch.leader_epoch > epoch.current() {
    // A newer term. Adopt it -- durably, or not at all -- before any
    // of the writes it carries are allowed to land; if the metadata
    // write fails, so does the batch.
    match epoch.elect(batch.leader_epoch) {
      Err(code) => return refuse(conn, code)
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
    return refuse(conn, @protocol.MalformedPayload)
  }
  if batch.base_seq > next_sequence {
    // The leader is ahead of us: entries this replica has never seen.
    // Taking the batch would leave sequences missing from the middle of
    // the log, and this format has no legitimate holes -- a gap is
    // corruption, not a rewind marker.
    return refuse(conn, @protocol.CatchupRequired)
  }
  if batch.base_seq < next_sequence {
    // A divergent tail: what this replica holds above the cut belongs to
    // a history the leader does not share. It goes before the batch
    // lands, so the two never coexist. The cut is always above the
    // caller's own commit point -- a leader only ever offers a base one
    // past its own append position, and its commit point cannot be past
    // that -- so the committed prefix is out of reach by construction.
    match log.truncate(batch.base_seq - 1UL) {
      Err(code) => return refuse(conn, code)
      Ok(_) => ()
    }
  }
  let follower_id = config.node_id()
  let leader_epoch = batch.leader_epoch
  match log.append(batch.entries, batch.flush_after_append) {
    Err(code) => return refuse(conn, code)
    Ok(_) => ()
  }
  let ack : AppendAck = {
    follower_id,
    leader_epoch,
    flushed_seq: log.last_flushed_seq(),
    dirty_seq: log.last_appended_seq(),
  }
  match write_peer_msg(conn, Ack(ack)) {
    Err(code) => return Err(code)
    Ok(_) => ()
  }
  Ok(ack)
}

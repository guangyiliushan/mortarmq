/// The peer channel's own frame format, distinct from the client wire
/// protocol it must never borrow from.
///
/// The client protocol reserves every operation byte outside `0x01..0x0F`
/// (`Op::from_byte(0x10)` is `None` on purpose), and the replication RPCs
/// are internal: they do not appear in the 15-op table and a client must
/// never be able to send one. So the peer channel defines a five-value
/// namespace of its own on the same envelope shape -- four big-endian
/// length bytes counting the type byte, then one type byte, then payload
/// -- which keeps the two namespaces disjoint while leaving one framing
/// rule to reason about.
///
/// # Boundaries
///
/// * Decode is strict and total: an unknown type, a payload of the wrong
///   size for its type, a body shorter or longer than the length field
///   claims, and a length below one byte all decode to `None`. There is
///   no partially-parsed message and no "best effort" variant.
/// * Decode never reads past the frame it is given; every field is
///   bounds-checked before it is read, so a truncated frame reports
///   `MalformedPayload` instead of raising.
/// * Encode is total. The handshake is the only producer and it always
///   writes a 16-byte nonce and a 32-byte tag, and the strict decoder
///   above is what catches it if that ever stops being true.

///|
/// Bytes the length prefix occupies, matching the client frame.
pub const PEER_LEN_BYTES : Int = 4

///|
/// Size of the handshake nonce, in bytes.
///
/// Fresh per handshake from the platform entropy source; long enough
/// that two handshakes never collide and short enough that the
/// challenge stays one line on a packet capture.
pub const PEER_NONCE_BYTES : Int = 16

///|
/// Largest body a frame may declare before the handshake has completed.
///
/// A challenge is the biggest thing either end sends while still
/// unauthenticated: one type byte, a two-byte id, a nonce and a tag, so
/// 1 + 2 + 16 + 32. Nothing else pre-authentication comes close. A peer
/// that claims more than this is refused on the claim itself rather
/// than handed a buffer sized by what it said it would send -- which is
/// the difference between a four-byte refusal and a sixteen-megabyte
/// allocation made on an unauthenticated word.
pub const PEER_HANDSHAKE_MAX_BODY : UInt = 51U

///|
/// How long one frame may take to arrive in full, in milliseconds.
///
/// Mirrors the client channel's `HALF_FRAME_TIMEOUT_SECONDS`. A peer
/// that stops in the middle of a frame is disconnected rather than
/// waited for, and the stream is never re-synchronised afterwards:
/// scanning forward for the next length prefix could not tell a real
/// frame from payload bytes, so recovery would corrupt what follows
/// instead of repairing it.
pub const PEER_FRAME_TIMEOUT_MS : Int = 10000

///|
/// How many bytes one read of a frame body asks for at a time.
///
/// The bound that keeps a declared length from being an allocation
/// size. What gets allocated follows what has actually arrived, one
/// chunk at a time, whatever the peer claimed it was about to send -- a
/// four-byte prefix that promises sixteen megabytes costs four bytes
/// until four bytes more show up.
pub const PEER_READ_CHUNK_BYTES : Int = 65536

///|
/// Size of an HMAC-SHA256 tag on the wire, in bytes.
pub const PEER_TAG_BYTES : Int = 32

///|
/// Peer-channel message types. The values are this channel's own
/// namespace and are not operation bytes of the client protocol.
const PEER_MSG_HELLO : Byte = 0x01

///|
const PEER_MSG_CHALLENGE : Byte = 0x02

///|
const PEER_MSG_PROOF : Byte = 0x03

///|
const PEER_MSG_WELCOME : Byte = 0x04

///|
const PEER_MSG_REJECT : Byte = 0x05

///|
/// Leader to follower: a batch of entries to write, with the base
/// sequence they continue from.
const PEER_MSG_APPEND : Byte = 0x06

///|
/// Follower to leader: how far this replica has written and how far it
/// has fsynced.
const PEER_MSG_APPEND_ACK : Byte = 0x07

///|
/// Candidate to members: would you promise me this term?
const PEER_MSG_PREPARE : Byte = 0x08

///|
/// Member to candidate: promised, and here is where my log stands.
const PEER_MSG_PREPARE_ACK : Byte = 0x09

///|
/// Candidate to members: this term is installed, take these positions.
const PEER_MSG_INSTALL : Byte = 0x0A

///|
/// Member to candidate: installed and durable.
const PEER_MSG_INSTALL_ACK : Byte = 0x0B

///|
/// One message on the peer channel.
///
/// The handshake is `Hello`, `Challenge`, `Proof`, `Welcome` (or
/// `Reject` at any point). Replication traffic arrives as further
/// variants as the replication stream lands; `Reject` carries a
/// registered protocol code so a refusal is always something the other
/// end can name.
pub(all) enum PeerMsg {
  /// The initiator opens with its node id, before any secret material
  /// has moved.
  Hello(UInt16)
  /// The responder answers with its id, a fresh nonce, and its own tag
  /// over that nonce.
  Challenge(UInt16, Bytes, Bytes)
  /// The initiator proves it holds the shared secret.
  Proof(UInt16, Bytes)
  /// The responder accepted the proof; the link is up.
  Welcome(UInt16)
  /// Either side refuses, carrying a registered `ErrCode` value.
  Reject(UInt16)
  /// Leader to follower: write these entries at this base sequence.
  Append(AppendBatch)
  /// Follower to leader: how far this replica has written and fsynced.
  /// Named `Ack` rather than `AppendAck` so the payload struct keeps its
  /// own unambiguous name at construction sites.
  Ack(AppendAck)
  /// Candidate to members: ask for a promise on a term.
  Prepare(PrepareMsg)
  /// Member to candidate: promised, with the log it stands on.
  PrepareAck(PrepareAckMsg)
  /// Candidate to members: take this term and this committed position.
  Install(InstallMsg)
  /// Member to candidate: installed and durable.
  InstallAck(InstallAckMsg)
} derive(Eq, Debug)

///|
pub extend PeerMsg with Eq::{not_equal, equal}

///|
pub extend PeerMsg with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One replication batch: the entries themselves plus everything the
/// follower needs to place them.
///
/// `base_seq` is the sequence of the first entry; entry `i` carries
/// `base_seq + i`, so the follower's numbering is the leader's by
/// construction rather than by agreement. `leader_epoch` rides along
/// from the first version of the frame so that the fencing check is not
/// a wire change; the check itself compares the epoch against the
/// promise this replica holds, and refuses an older term before any
/// storage append happens.
/// `flush_after_append` selects the follower's durability for this
/// batch -- a follower that is only catching up on written-but-unflushed
/// state reports a `dirty_seq` above its `flushed_seq`, which is exactly
/// the distinction the leader must be able to see.
pub(all) struct AppendBatch {
  leader_id : UInt16
  leader_epoch : UInt64
  base_seq : UInt64
  flush_after_append : Bool
  entries : Array[Bytes]
} derive(Eq, Debug)

///|
pub extend AppendBatch with Eq::{not_equal, equal}

///|
pub extend AppendBatch with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A follower's reply: two positions, not one.
///
/// `flushed_seq` is what has been fsynced and is the only number that
/// may ever count toward a quorum; `dirty_seq` is what has merely been
/// written. Reporting both is what lets a lagging follower show up as
/// lagging instead of looking caught up.
pub(all) struct AppendAck {
  follower_id : UInt16
  leader_epoch : UInt64
  flushed_seq : UInt64
  dirty_seq : UInt64
} derive(Eq, Debug)

///|
pub extend AppendAck with Eq::{not_equal, equal}

///|
pub extend AppendAck with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The first half of an election: a candidate asking members to promise
/// a term before it claims one.
///
/// The candidate reports where its own log stands alongside the term it
/// proposes, so a member can see what it would be joining. The member
/// answers with its own positions, and the candidate picks the log to
/// lead from among them -- never its own by default, because the point
/// of asking is that somebody may be further along.
pub(all) struct PrepareMsg {
  candidate_id : UInt16
  candidate_epoch : UInt64
  last_seq : UInt64
  last_leader_epoch : UInt64
  commit_seq : UInt64
} derive(Eq, Debug)

///|
pub extend PrepareMsg with Eq::{not_equal, equal}

///|
pub extend PrepareMsg with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A member's answer to a prepare: the promise, and the log it made the
/// promise on behalf of.
///
/// `promised_epoch` is written durably before this frame goes out, so a
/// member that has answered has already given up its right to answer a
/// lower term -- which is what stops two candidates from both winning
/// with the same followers.
pub(all) struct PrepareAckMsg {
  responder_id : UInt16
  promised_epoch : UInt64
  last_seq : UInt64
  last_flushed_seq : UInt64
  commit_seq : UInt64
} derive(Eq, Debug)

///|
pub extend PrepareAckMsg with Eq::{not_equal, equal}

///|
pub extend PrepareAckMsg with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The second half of an election: a candidate telling members which
/// term and which committed position it is taking.
///
/// A candidate that collected promises but never installed would be a
/// leader only in its own memory; this is the frame that makes the term
/// durable on a majority before any write under it is allowed.
pub(all) struct InstallMsg {
  leader_id : UInt16
  epoch : UInt64
  commit_seq : UInt64
} derive(Eq, Debug)

///|
pub extend InstallMsg with Eq::{not_equal, equal}

///|
pub extend InstallMsg with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A member confirming the install is durable.
///
/// `flushed_seq` is read back from the log after the write returned, so
/// a member that says it installed has made the term durable rather
/// than merely received it.
pub(all) struct InstallAckMsg {
  responder_id : UInt16
  epoch : UInt64
  flushed_seq : UInt64
} derive(Eq, Debug)

///|
pub extend InstallAckMsg with Eq::{not_equal, equal}

///|
pub extend InstallAckMsg with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Append a big-endian `u16`, the byte order every integer on both
/// channels uses.
fn put_u16(buf : Buffer, value : UInt16) -> Unit {
  let wide = value.to_uint()
  buf.write_byte(((wide >> 8) & 0xFFU).reinterpret_as_int().to_byte())
  buf.write_byte((wide & 0xFFU).reinterpret_as_int().to_byte())
}

///|
/// Append a big-endian `u32` frame length.
fn put_u32(buf : Buffer, value : UInt) -> Unit {
  buf.write_byte(((value >> 24) & 0xFFU).reinterpret_as_int().to_byte())
  buf.write_byte(((value >> 16) & 0xFFU).reinterpret_as_int().to_byte())
  buf.write_byte(((value >> 8) & 0xFFU).reinterpret_as_int().to_byte())
  buf.write_byte((value & 0xFFU).reinterpret_as_int().to_byte())
}

///|
/// Read a big-endian `u16` at `offset`, or `None` when fewer than two
/// bytes remain. Every read goes through here, so no field can be read
/// outside the frame it belongs to.
fn get_u16(view : BytesView, offset : Int) -> UInt16? {
  if offset < 0 || offset + 2 > view.length() {
    return None
  }
  let high = view.at(offset).to_uint()
  let low = view.at(offset + 1).to_uint()
  Some(((high << 8) | low).to_uint16())
}

///|
/// Append a big-endian `u64`, the sequence and epoch width both
/// replication positions use.
fn put_u64(buf : Buffer, value : UInt64) -> Unit {
  for shift in [56, 48, 40, 32, 24, 16, 8, 0] {
    let byte = ((value >> shift) & 0xFFUL).to_uint().reinterpret_as_int()
    buf.write_byte(byte.to_byte())
  }
}

///|
/// Read a big-endian `u64` at `offset`, or `None` when fewer than eight
/// bytes remain.
fn get_u64(view : BytesView, offset : Int) -> UInt64? {
  if offset < 0 || offset + 8 > view.length() {
    return None
  }
  let mut value = 0UL
  for index in 0..<8 {
    value = (value << 8) | view.at(offset + index).to_uint().to_uint64()
  }
  Some(value)
}

///|
/// Read a big-endian `u32` at `offset`, or `None` when fewer than four
/// bytes remain.
fn get_u32(view : BytesView, offset : Int) -> UInt? {
  if offset < 0 || offset + 4 > view.length() {
    return None
  }
  let mut value = 0U
  for index in 0..<4 {
    value = (value << 8) | view.at(offset + index).to_uint()
  }
  Some(value)
}

///|
/// Copy `length` bytes at `offset` into a fresh `Bytes`, or `None` when
/// the window falls outside the frame.
fn take_bytes(view : BytesView, offset : Int, length : Int) -> Bytes? {
  if offset < 0 || length < 0 || offset + length > view.length() {
    return None
  }
  let copied = FixedArray::make(length, b'\x00')
  for index in 0..<length {
    copied[index] = view.at(offset + index)
  }
  Some(Bytes::from_array(copied))
}

///|
/// Serialize one peer message into a complete frame: four big-endian
/// length bytes counting the type byte, then the type byte, then the
/// payload. The length counts the type byte for the same reason the
/// client frame does -- the receiver reads the length, then reads exactly
/// that many bytes, and never has to guess where the body stops.
///
/// # Example
///
/// ```mbt check
/// test {
///   let frame = @cluster.encode_peer_msg(@cluster.PeerMsg::Hello(7U.to_uint16()))
///   // length 3 = type byte plus the two id bytes, big-endian.
///   assert_eq(frame, b"\x00\x00\x00\x03\x01\x00\x07")
/// }
/// ```
pub fn encode_peer_msg(msg : PeerMsg) -> Bytes {
  let body = Buffer()
  match msg {
    Hello(node_id) => {
      body.write_byte(PEER_MSG_HELLO)
      put_u16(body, node_id)
    }
    Challenge(node_id, nonce, tag) => {
      body.write_byte(PEER_MSG_CHALLENGE)
      put_u16(body, node_id)
      body.write_bytes(nonce)
      body.write_bytes(tag)
    }
    Proof(node_id, tag) => {
      body.write_byte(PEER_MSG_PROOF)
      put_u16(body, node_id)
      body.write_bytes(tag)
    }
    Welcome(node_id) => {
      body.write_byte(PEER_MSG_WELCOME)
      put_u16(body, node_id)
    }
    Reject(code) => {
      body.write_byte(PEER_MSG_REJECT)
      put_u16(body, code)
    }
    Append(batch) => {
      body.write_byte(PEER_MSG_APPEND)
      put_u16(body, batch.leader_id)
      put_u64(body, batch.leader_epoch)
      put_u64(body, batch.base_seq)
      let flush_flag = if batch.flush_after_append { 1 } else { 0 }
      body.write_byte(flush_flag.to_byte())
      put_u32(body, batch.entries.length().reinterpret_as_uint())
      for entry in batch.entries {
        put_u32(body, entry.length().reinterpret_as_uint())
        body.write_bytes(entry)
      }
    }
    Ack(ack) => {
      body.write_byte(PEER_MSG_APPEND_ACK)
      put_u16(body, ack.follower_id)
      put_u64(body, ack.leader_epoch)
      put_u64(body, ack.flushed_seq)
      put_u64(body, ack.dirty_seq)
    }
    Prepare(msg) => {
      body.write_byte(PEER_MSG_PREPARE)
      put_u16(body, msg.candidate_id)
      put_u64(body, msg.candidate_epoch)
      put_u64(body, msg.last_seq)
      put_u64(body, msg.last_leader_epoch)
      put_u64(body, msg.commit_seq)
    }
    PrepareAck(msg) => {
      body.write_byte(PEER_MSG_PREPARE_ACK)
      put_u16(body, msg.responder_id)
      put_u64(body, msg.promised_epoch)
      put_u64(body, msg.last_seq)
      put_u64(body, msg.last_flushed_seq)
      put_u64(body, msg.commit_seq)
    }
    Install(msg) => {
      body.write_byte(PEER_MSG_INSTALL)
      put_u16(body, msg.leader_id)
      put_u64(body, msg.epoch)
      put_u64(body, msg.commit_seq)
    }
    InstallAck(msg) => {
      body.write_byte(PEER_MSG_INSTALL_ACK)
      put_u16(body, msg.responder_id)
      put_u64(body, msg.epoch)
      put_u64(body, msg.flushed_seq)
    }
  }
  let inner = body.contents()
  let frame = Buffer()
  put_u32(frame, inner.length().reinterpret_as_uint())
  frame.write_bytes(inner)
  frame.contents()
}

///|
/// Parse one complete peer frame, or `None` if it is not exactly one
/// well-formed message of a known type.
///
/// `None` is the only failure value and it covers every malformed shape:
/// a short frame, a length field that disagrees with the frame, a body
/// above the protocol's frame bound, an unknown type byte, and a payload
/// of the wrong size for its type. The caller turns it into
/// `MalformedPayload`, so a bad frame is always a named code rather than
/// a partially-understood message.
///
/// # Example
///
/// ```mbt check
/// test {
///   let frame = @cluster.encode_peer_msg(@cluster.PeerMsg::Hello(7U.to_uint16()))
///   assert_eq(
///     @cluster.decode_peer_msg(frame[:]),
///     Some(@cluster.PeerMsg::Hello(7U.to_uint16())),
///   )
///   // A payload of the wrong size for its type decodes to None.
///   assert_eq(@cluster.decode_peer_msg(b"\x00\x00\x00\x02\x01"), None)
/// }
/// ```
pub fn decode_peer_msg(frame : BytesView) -> PeerMsg? {
  match get_u32(frame, 0) {
    None => None
    Some(body_len) => decode_peer_body(frame, body_len)
  }
}

///|
/// Decode the body of a frame whose length prefix has already parsed.
///
/// Split from `decode_peer_msg` so the length check happens once and the
/// per-type payload checks below each see a frame that is already known
/// to hold exactly the bytes the length field promised.
fn decode_peer_body(frame : BytesView, body_len : UInt) -> PeerMsg? {
  if body_len < 1U {
    return None
  }
  if body_len > @protocol.MAX_FRAME_LEN {
    return None
  }
  if frame.length() != PEER_LEN_BYTES + body_len.reinterpret_as_int() {
    return None
  }
  let kind = frame.at(PEER_LEN_BYTES)
  let base = PEER_LEN_BYTES + 1
  let payload_len = frame.length() - PEER_LEN_BYTES - 1
  if kind == PEER_MSG_HELLO {
    if payload_len != 2 {
      return None
    }
    let node_id = match get_u16(frame, base) {
      None => return None
      Some(value) => value
    }
    return Some(Hello(node_id))
  }
  if kind == PEER_MSG_CHALLENGE {
    if payload_len != 2 + PEER_NONCE_BYTES + PEER_TAG_BYTES {
      return None
    }
    let node_id = match get_u16(frame, base) {
      None => return None
      Some(value) => value
    }
    let nonce = match take_bytes(frame, base + 2, PEER_NONCE_BYTES) {
      None => return None
      Some(value) => value
    }
    let tag_start = base + 2 + PEER_NONCE_BYTES
    let tag = match take_bytes(frame, tag_start, PEER_TAG_BYTES) {
      None => return None
      Some(value) => value
    }
    return Some(Challenge(node_id, nonce, tag))
  }
  if kind == PEER_MSG_PROOF {
    if payload_len != 2 + PEER_TAG_BYTES {
      return None
    }
    let node_id = match get_u16(frame, base) {
      None => return None
      Some(value) => value
    }
    let tag = match take_bytes(frame, base + 2, PEER_TAG_BYTES) {
      None => return None
      Some(value) => value
    }
    return Some(Proof(node_id, tag))
  }
  if kind == PEER_MSG_WELCOME {
    if payload_len != 2 {
      return None
    }
    let node_id = match get_u16(frame, base) {
      None => return None
      Some(value) => value
    }
    return Some(Welcome(node_id))
  }
  if kind == PEER_MSG_REJECT {
    if payload_len != 2 {
      return None
    }
    let code = match get_u16(frame, base) {
      None => return None
      Some(value) => value
    }
    return Some(Reject(code))
  }
  if kind == PEER_MSG_APPEND {
    return decode_append(frame, base, payload_len)
  }
  if kind == PEER_MSG_APPEND_ACK {
    return decode_append_ack(frame, base, payload_len)
  }
  if kind == PEER_MSG_PREPARE {
    return decode_prepare(frame, base, payload_len)
  }
  if kind == PEER_MSG_PREPARE_ACK {
    return decode_prepare_ack(frame, base, payload_len)
  }
  if kind == PEER_MSG_INSTALL {
    return decode_install(frame, base, payload_len)
  }
  if kind == PEER_MSG_INSTALL_ACK {
    return decode_install_ack(frame, base, payload_len)
  }
  None
}

///|
/// Fixed prefix of an `APPEND` payload: id, epoch, base sequence, the
/// flush flag and the entry count.
const APPEND_PREFIX_BYTES : Int = 2 + 8 + 8 + 1 + 4

///|
/// Fixed size of an `APPEND_ACK` payload: id, epoch, flushed, dirty.
const APPEND_ACK_BYTES : Int = 2 + 8 + 8 + 8

///|
/// Decode one `APPEND` payload, or `None` if any part of it does not
/// line up.
///
/// The entry array is walked with the frame's own end as the bound, so
/// a count that promises more entries than the payload can hold, an
/// entry whose length runs past the end, and a trailing byte after the
/// last entry all fail the same way: there is no partially-parsed
/// batch.
fn decode_append(frame : BytesView, base : Int, payload_len : Int) -> PeerMsg? {
  if payload_len < APPEND_PREFIX_BYTES {
    return None
  }
  let leader_id = match get_u16(frame, base) {
    None => return None
    Some(value) => value
  }
  let leader_epoch = match get_u64(frame, base + 2) {
    None => return None
    Some(value) => value
  }
  let base_seq = match get_u64(frame, base + 10) {
    None => return None
    Some(value) => value
  }
  let flush_flag = frame.at(base + 18)
  if flush_flag != 0 && flush_flag != 1 {
    return None
  }
  let flush_after_append = flush_flag == 1
  let raw_count = match get_u32(frame, base + 19) {
    None => return None
    Some(value) => value
  }
  let entries_body = payload_len - APPEND_PREFIX_BYTES
  // Each entry costs at least its four-byte length, so a count above
  // this bound is impossible before any entry is read.
  if raw_count > (entries_body / 4).reinterpret_as_uint() {
    return None
  }
  let count = raw_count.reinterpret_as_int()
  let end = base + payload_len
  let entries : Array[Bytes] = []
  let mut cursor = base + APPEND_PREFIX_BYTES
  for _ in 0..<count {
    let length = match get_u32(frame, cursor) {
      None => return None
      Some(value) => value
    }
    if length > @protocol.MAX_FRAME_LEN {
      return None
    }
    let span = length.reinterpret_as_int()
    let payload = match take_bytes(frame, cursor + 4, span) {
      None => return None
      Some(value) => value
    }
    entries.push(payload)
    cursor = cursor + 4 + span
    if cursor > end {
      return None
    }
  }
  if cursor != end {
    return None
  }
  Some(
    Append({ leader_id, leader_epoch, base_seq, flush_after_append, entries, }),
  )
}

///|
/// Decode one `APPEND_ACK` payload: a fixed twenty-six bytes with no
/// variable part.
fn decode_append_ack(
  frame : BytesView,
  base : Int,
  payload_len : Int,
) -> PeerMsg? {
  if payload_len != APPEND_ACK_BYTES {
    return None
  }
  let follower_id = match get_u16(frame, base) {
    None => return None
    Some(value) => value
  }
  let leader_epoch = match get_u64(frame, base + 2) {
    None => return None
    Some(value) => value
  }
  let flushed_seq = match get_u64(frame, base + 10) {
    None => return None
    Some(value) => value
  }
  let dirty_seq = match get_u64(frame, base + 18) {
    None => return None
    Some(value) => value
  }
  Some(Ack({ follower_id, leader_epoch, flushed_seq, dirty_seq, }))
}

///|
/// Send one message down a peer connection.
///
/// The whole frame is handed to `write_all` in one buffer, so a message
/// is never observed by the far end in pieces.
pub async fn write_peer_msg(
  conn : &@net.Conn,
  msg : PeerMsg,
) -> Result[Unit, @protocol.ErrCode] {
  @net.Conn::write_all(conn, encode_peer_msg(msg))
}

///|
/// Receive exactly one message from a peer connection.
///
/// The length prefix is read first and checked against the protocol
/// frame bound *before* the body is requested, so a peer that announces
/// an absurd length is refused without allocating for it. A length that
/// cannot describe a frame reports `BadLength`; a body that does not
/// decode to exactly one known message reports `MalformedPayload`. Both
/// are registered codes, so a malformed peer frame is never swallowed.

///|
/// Read one frame whose body may declare at most `max_body` bytes,
/// giving up after `deadline_ms`.
///
/// The deadline is a parameter rather than a constant read inside so a
/// test can exercise it in milliseconds instead of in seconds, and so a
/// caller with a tighter budget of its own can pass one -- the same
/// shape `send_append` uses for the quorum acknowledgement.
async fn read_frame(
  conn : &@net.Conn,
  max_body : UInt,
  deadline_ms : Int,
) -> Result[PeerMsg, @protocol.ErrCode] {
  if deadline_ms <= 0 {
    return Err(@protocol.MalformedPayload)
  }
  match
    @async.with_timeout_opt(deadline_ms, () => read_frame_body(conn, max_body)) {
    // The frame never arrived in full. The stream cannot be
    // re-synchronised, so the connection closes: `BadLength` is the
    // registered code whose action is exactly that, and what was not
    // honoured is the length the frame declared.
    None => Err(@protocol.BadLength)
    Some(result) => result
  }
}

///|
/// Read one frame without a deadline of its own.
///
/// Split from `read_frame` only so the timeout wraps one expression;
/// everything about the bound and the chunking lives here.
async fn read_frame_body(
  conn : &@net.Conn,
  max_body : UInt,
) -> Result[PeerMsg, @protocol.ErrCode] {
  let head = match @net.Conn::read_exact(conn, PEER_LEN_BYTES) {
    Ok(bytes) => bytes
    Err(code) => return Err(code)
  }
  let body_len = match get_u32(head[:], 0) {
    None => return Err(@protocol.BadLength)
    Some(value) => value
  }
  if body_len < 1U || body_len > max_body {
    return Err(@protocol.BadLength)
  }
  // Chunks, not one allocation the size of the claim. Each read asks
  // for at most `PEER_READ_CHUNK_BYTES`, so a peer that stops sending
  // leaves the buffer holding what arrived and nothing more.
  let frame = Buffer()
  frame.write_bytes(head[:])
  let mut remaining = body_len.reinterpret_as_int()
  while remaining > 0 {
    let step = if remaining < PEER_READ_CHUNK_BYTES {
      remaining
    } else {
      PEER_READ_CHUNK_BYTES
    }
    let piece = match @net.Conn::read_exact(conn, step) {
      Ok(bytes) => bytes
      Err(code) => return Err(code)
    }
    frame.write_bytes(piece)
    remaining = remaining - step
  }
  match decode_peer_msg(frame.contents()[:]) {
    None => Err(@protocol.MalformedPayload)
    Some(msg) => Ok(msg)
  }
}

///|
/// Read one message on an established peer link.
///
/// The full frame bound applies: by this point the far end has proved
/// which node it is, and replication batches are the largest thing that
/// travels.
pub async fn read_peer_msg(
  conn : &@net.Conn,
  deadline_ms : Int,
) -> Result[PeerMsg, @protocol.ErrCode] {
  read_frame(conn, @protocol.MAX_FRAME_LEN, deadline_ms)
}

///|
/// Read one message before the handshake has completed.
///
/// The pre-authentication bound applies: whatever the far end claims,
/// it has not proved anything yet, so the claim is checked against what
/// a handshake can actually carry rather than against the replication
/// limit an authenticated peer is allowed.
pub async fn read_handshake_msg(
  conn : &@net.Conn,
  deadline_ms : Int,
) -> Result[PeerMsg, @protocol.ErrCode] {
  read_frame(conn, PEER_HANDSHAKE_MAX_BODY, deadline_ms)
}

///|
/// Fixed payload sizes of the election frames: an id plus four epochs
/// or positions, an id plus three, and so on. None of them has a
/// variable part, which is why each decoder is a length check and a
/// handful of reads.
const PREPARE_PAYLOAD_BYTES : Int = 2 + 32

///|
const PREPARE_ACK_PAYLOAD_BYTES : Int = 2 + 32

///|
const INSTALL_PAYLOAD_BYTES : Int = 2 + 16

///|
const INSTALL_ACK_PAYLOAD_BYTES : Int = 2 + 16

///|
/// Decode one `PREPARE` payload.
fn decode_prepare(frame : BytesView, base : Int, payload_len : Int) -> PeerMsg? {
  if payload_len != PREPARE_PAYLOAD_BYTES {
    return None
  }
  let candidate_id = match get_u16(frame, base) {
    None => return None
    Some(value) => value
  }
  let candidate_epoch = match get_u64(frame, base + 2) {
    None => return None
    Some(value) => value
  }
  let last_seq = match get_u64(frame, base + 10) {
    None => return None
    Some(value) => value
  }
  let last_leader_epoch = match get_u64(frame, base + 18) {
    None => return None
    Some(value) => value
  }
  let commit_seq = match get_u64(frame, base + 26) {
    None => return None
    Some(value) => value
  }
  Some(
    Prepare({
      candidate_id,
      candidate_epoch,
      last_seq,
      last_leader_epoch,
      commit_seq,
    }),
  )
}

///|
/// Decode one `PREPARE_ACK` payload.
fn decode_prepare_ack(
  frame : BytesView,
  base : Int,
  payload_len : Int,
) -> PeerMsg? {
  if payload_len != PREPARE_ACK_PAYLOAD_BYTES {
    return None
  }
  let responder_id = match get_u16(frame, base) {
    None => return None
    Some(value) => value
  }
  let promised_epoch = match get_u64(frame, base + 2) {
    None => return None
    Some(value) => value
  }
  let last_seq = match get_u64(frame, base + 10) {
    None => return None
    Some(value) => value
  }
  let last_flushed_seq = match get_u64(frame, base + 18) {
    None => return None
    Some(value) => value
  }
  let commit_seq = match get_u64(frame, base + 26) {
    None => return None
    Some(value) => value
  }
  Some(
    PrepareAck({
      responder_id,
      promised_epoch,
      last_seq,
      last_flushed_seq,
      commit_seq,
    }),
  )
}

///|
/// Decode one `INSTALL` payload.
fn decode_install(frame : BytesView, base : Int, payload_len : Int) -> PeerMsg? {
  if payload_len != INSTALL_PAYLOAD_BYTES {
    return None
  }
  let leader_id = match get_u16(frame, base) {
    None => return None
    Some(value) => value
  }
  let epoch = match get_u64(frame, base + 2) {
    None => return None
    Some(value) => value
  }
  let commit_seq = match get_u64(frame, base + 10) {
    None => return None
    Some(value) => value
  }
  Some(Install({ leader_id, epoch, commit_seq, }))
}

///|
/// Decode one `INSTALL_ACK` payload.
fn decode_install_ack(
  frame : BytesView,
  base : Int,
  payload_len : Int,
) -> PeerMsg? {
  if payload_len != INSTALL_ACK_PAYLOAD_BYTES {
    return None
  }
  let responder_id = match get_u16(frame, base) {
    None => return None
    Some(value) => value
  }
  let epoch = match get_u64(frame, base + 2) {
    None => return None
    Some(value) => value
  }
  let flushed_seq = match get_u64(frame, base + 10) {
    None => return None
    Some(value) => value
  }
  Some(InstallAck({ responder_id, epoch, flushed_seq, }))
}

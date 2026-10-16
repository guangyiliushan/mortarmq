/// Mutual challenge-response authentication of one peer link.
///
/// Both ends have to prove they hold the same shared secret before a
/// single replication byte moves, and neither ever sends the secret
/// itself. The responder opens with a fresh nonce plus its own tag over
/// that nonce; the initiator verifies, answers with its tag over the
/// same nonce, and the responder verifies in turn. A tag binds the
/// secret to both node ids and to that one nonce, so a recorded
/// handshake cannot be replayed against a later connection and a tag
/// minted for one pair of nodes cannot be offered to another.
///
/// # Why a keyed MAC and not a hash
///
/// `sha256(secret || nonce)` proves nothing: the verifier never chose
/// the byte string it hashes, so it cannot tell knowledge of the secret
/// from an arbitrary preimage. HMAC-SHA256 is the standard answer and
/// lives one package over in `security/`, so this channel keys with the
/// same SHA-256 the tokens file hashes with rather than a second copy.
///
/// # Separation from client tokens
///
/// Nothing here reads a `TokenStore`. The value that authenticates a
/// peer link is a `PeerSecret`, which is a different type from anything
/// `@security.authenticate` accepts, so a leaked client token -- the
/// scenario of a leaked client token cannot be presented on this channel
/// all, and vice versa. The `cluster_peer_auth_test` cases pin both
/// directions.
///
/// # Boundaries
///
/// * Entropy failure is `Internal`, not a rejection: a node that cannot
///   get a fresh nonce refuses to open a link rather than reusing one.
/// * Every refusal is sent as `Reject` carrying the registered code the
///   caller also gets back, so the far end learns why the link closed
///   and the local caller still sees a named error.
/// * The tag comparison is `@security.tag_eq`, the one exported
///   constant-time compare (CWE-208 / Go `crypto/subtle`): XOR
///   accumulator, single verdict extraction, length checked first.
///   There is no `==` anywhere on tag bytes in this package, and no
///   second copy of the comparison either -- the single-point
///   discipline a token check and a peer tag check have to share.
/// * The channel authenticates, it does not encrypt: v0 promises a
///   separate shared secret on a separate listen face, not
///   confidentiality for replication traffic. Secrecy of frame contents
///   is out of scope for v0 and is named here rather than implied.

///|
/// Domain separator prefixed to every tag this channel computes.
///
/// A tag is only meaningful inside the context it was minted for, so
/// the separator makes it structurally impossible for a tag to be
/// replayed as a digest of something else, and it pins the wire version
/// of the handshake alongside it.
pub const PEER_DOMAIN : Bytes = b"mortarmq-peer-v1"

///|
/// Role byte of the responder's tag: minted before the initiator
/// answers, binding the responder to the nonce it chose.
const PEER_ROLE_RESPONDER : Byte = 0x01

///|
/// Role byte of the initiator's tag: minted after verification, proving
/// the initiator derived the same secret from the same nonce.
const PEER_ROLE_INITIATOR : Byte = 0x02

///|
/// Mint one tag over the domain separator, the role, both node ids and
/// the nonce.
///
/// Both ids are inside the signed material so a tag minted between nodes
/// A and B cannot be offered as a tag between A and C, and the role byte
/// stops the responder's tag from being echoed back as the initiator's.
fn peer_tag(
  secret : PeerSecret,
  role : Byte,
  initiator : UInt16,
  responder : UInt16,
  initiator_nonce : BytesView,
  responder_nonce : BytesView,
) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(PEER_DOMAIN)
  buf.write_byte(role)
  put_u16(buf, initiator)
  put_u16(buf, responder)
  buf.write_bytes(initiator_nonce)
  buf.write_bytes(responder_nonce)
  secret.tag(buf.contents()[:])
}

///|
/// Draw a fresh handshake nonce from the platform entropy source.
///
/// `None` means the platform could not produce secure bytes, which the
/// caller turns into `Internal`: reusing a nonce would let a captured
/// handshake be replayed, so a node without entropy opens no links.
fn fresh_nonce() -> Bytes? {
  match @env.rand(PEER_NONCE_BYTES) {
    None => None
    Some(nonce) =>
      if nonce.length() == PEER_NONCE_BYTES {
        Some(nonce)
      } else {
        None
      }
  }
}

///|
/// Tell the far end why the link is closing and hand the same code back
/// to the caller.
///
/// A best-effort farewell on a channel already being torn down: its
/// write failure is swallowed on purpose because the caller reports the
/// real error either way, and the point of the frame is only to save
/// the other end from guessing. The result type is left to the caller,
/// so a refusal reads as `return refuse(conn, code)` anywhere on the
/// channel -- handshake or replication -- instead of a write that has
/// to be checked for a second time.
async fn[X] refuse(
  conn : &@net.Conn,
  code : @protocol.ErrCode,
) -> Result[X, @protocol.ErrCode] {
  // Two different conversions, not one twice. `ErrCode::to_uint16`
  // reports the registered value as a `UInt` -- the accessor's name
  // predates the width it reports -- and the peer frame carries that
  // value as a 16-bit one. Spelled apart so the second is visible as
  // the narrowing it is rather than as a repeated call.
  let registered = code.to_uint16()
  let wire_code : UInt16 = registered.to_uint16()
  match write_peer_msg(conn, PeerMsg::Reject(wire_code)) {
    Ok(_) => ()
    Err(_) => ()
  }
  Err(code)
}

///|
/// The registered code a `Reject` frame carries, or `None` when the
/// frame is not a refusal.
///
/// Both halves use it so a refusal from the far end is reported as the
/// code it names instead of being mistaken for a malformed handshake --
/// when one side gives up, the other side learns *why* rather than
/// guessing at the frame it was sent.
fn refusal(msg : PeerMsg) -> @protocol.ErrCode? {
  match msg {
    Reject(code) =>
      match @protocol.ErrCode::from_uint16(code.to_uint()) {
        None => Some(@protocol.MalformedPayload)
        Some(registered) => Some(registered)
      }
    _ => None
  }
}

///|
/// Run the responder half of the handshake on an accepted connection.
///
/// Returns the initiator's node id once both tags have checked, or the
/// registered code that refused the link. The sequence is `Hello`,
/// `Challenge`, `Proof`, `Welcome`; any other shape, any id that is not
/// in the static table, and any tag that does not verify all end in a
/// `Reject` frame carrying the same code the caller receives.
///
/// # Example
///
/// ```mbt nocheck
/// // Needs two live connections, so the runnable coverage is the
/// // cluster handshake tests rather than a checked example.
/// match @cluster.peer_handshake_responder(config, accepted) {
///   Ok(peer_id) => ()
///   Err(@protocol.AuthFailed) => ()
///   Err(_) => ()
/// }
/// ```
pub async fn peer_handshake_responder(
  config : ClusterConfig,
  conn : &@net.Conn,
) -> Result[UInt16, @protocol.ErrCode] {
  let opener = match read_handshake_msg(conn, PEER_FRAME_TIMEOUT_MS) {
    Err(code) => return Err(code)
    Ok(msg) => msg
  }
  let (initiator, initiator_nonce) = match opener {
    Hello(node_id, nonce) => (node_id, nonce)
    _ => return refuse(conn, @protocol.MalformedPayload)
  }
  // An id that is not in the static table is not a member, whatever
  // address it arrived from; the node's own id is not a peer either.
  if initiator == config.node_id() || !config.has_peer(initiator) {
    return refuse(conn, @protocol.AuthFailed)
  }
  let nonce = match fresh_nonce() {
    None => return refuse(conn, @protocol.Internal)
    Some(value) => value
  }
  let responder_id = config.node_id()
  let secret = config.secret()
  let own_tag = peer_tag(
    secret,
    PEER_ROLE_RESPONDER,
    initiator,
    responder_id,
    initiator_nonce[:],
    nonce[:],
  )
  match write_peer_msg(conn, Challenge(responder_id, nonce, own_tag)) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  let answer = match read_handshake_msg(conn, PEER_FRAME_TIMEOUT_MS) {
    Err(code) => return Err(code)
    Ok(msg) => msg
  }
  match refusal(answer) {
    Some(code) => return Err(code)
    None => ()
  }
  let (claimed, presented) = match answer {
    Proof(node_id, tag) => (node_id, tag)
    _ => return refuse(conn, @protocol.MalformedPayload)
  }
  // The proof must come from the node that said Hello: a third party
  // that hijacked the socket still has to answer for an id that is in
  // the table and holds the secret.
  if claimed != initiator {
    return refuse(conn, @protocol.AuthFailed)
  }
  let expected = peer_tag(
    secret,
    PEER_ROLE_INITIATOR,
    initiator,
    responder_id,
    initiator_nonce[:],
    nonce[:],
  )
  if !@security.tag_eq(presented[:], expected[:]) {
    return refuse(conn, @protocol.AuthFailed)
  }
  match write_peer_msg(conn, Welcome(responder_id)) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  Ok(initiator)
}

///|
/// Run the initiator half of the handshake on a connection to `expected`.
///
/// `expected` is the peer table row this connection was dialed for, so a
/// listener that answers with a different node id is refused even if it
/// holds the secret: the address and the id have to agree, otherwise one
/// node's entry could silently reach another. Returns the responder's
/// node id once both tags have checked.
///
/// # Example
///
/// ```mbt nocheck
/// // Needs a live connection, so the runnable coverage is the cluster
/// // handshake tests rather than a checked example.
/// match @cluster.peer_handshake_initiator(config, dialed, remote) {
///   Ok(peer_id) => ()
///   Err(@protocol.AuthFailed) => ()
///   Err(_) => ()
/// }
/// ```
pub async fn peer_handshake_initiator(
  config : ClusterConfig,
  conn : &@net.Conn,
  expected : PeerEntry,
) -> Result[UInt16, @protocol.ErrCode] {
  let initiator_nonce = match fresh_nonce() {
    None => return refuse(conn, @protocol.Internal)
    Some(value) => value
  }
  match write_peer_msg(conn, Hello(config.node_id(), initiator_nonce)) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  let challenge = match read_handshake_msg(conn, PEER_FRAME_TIMEOUT_MS) {
    Err(code) => return Err(code)
    Ok(msg) => msg
  }
  match refusal(challenge) {
    Some(code) => return Err(code)
    None => ()
  }
  let (responder_id, nonce, presented) = match challenge {
    Challenge(node_id, nonce, tag) => (node_id, nonce, tag)
    _ => return refuse(conn, @protocol.MalformedPayload)
  }
  if responder_id != expected.node_id {
    return refuse(conn, @protocol.AuthFailed)
  }
  if responder_id == config.node_id() || !config.has_peer(responder_id) {
    return refuse(conn, @protocol.AuthFailed)
  }
  let secret = config.secret()
  let expected_tag = peer_tag(
    secret,
    PEER_ROLE_RESPONDER,
    config.node_id(),
    responder_id,
    initiator_nonce[:],
    nonce[:],
  )
  if !@security.tag_eq(presented[:], expected_tag[:]) {
    return refuse(conn, @protocol.AuthFailed)
  }
  let own_tag = peer_tag(
    secret,
    PEER_ROLE_INITIATOR,
    config.node_id(),
    responder_id,
    initiator_nonce[:],
    nonce[:],
  )
  match write_peer_msg(conn, Proof(config.node_id(), own_tag)) {
    Ok(_) => ()
    Err(code) => return Err(code)
  }
  let closing = match read_handshake_msg(conn, PEER_FRAME_TIMEOUT_MS) {
    Err(code) => return Err(code)
    Ok(msg) => msg
  }
  match refusal(closing) {
    Some(code) => Err(code)
    None =>
      match closing {
        Welcome(node_id) =>
          if node_id == responder_id {
            Ok(responder_id)
          } else {
            Err(@protocol.AuthFailed)
          }
        _ => Err(@protocol.MalformedPayload)
      }
  }
}

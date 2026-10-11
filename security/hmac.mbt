/// HMAC-SHA256 (RFC 2104), the keyed MAC the replication peer channel
/// authenticates with.
///
/// The peer channel (REQ-SEC-003) needs a proof that both ends hold the
/// same shared secret without ever putting that secret on the wire, and a
/// plain hash cannot do that: `sha256(secret || nonce)` proves knowledge
/// of nothing, because the verifier never chose the byte string it is
/// hashing. HMAC is the standard construction for this and it is built on
/// the same SHA-256 the rest of the repository already ships, so there is
/// one hash implementation and one place keyed hashing lives.
///
/// # Stability
///
/// * Block size is 64 bytes and digest size is 32 bytes, both fixed by
///   SHA-256; a key longer than one block is hashed down first, exactly
///   as RFC 2104 section 2 requires.
/// * The output is a plain 32-byte tag with no structure of its own, so a
///   caller compares it with `tag_eq` and never with `==`.
/// * The only branch on secret material is the one up-front key-length
///   check, and that length is a public value.

///|
/// Key size of the SHA-256 compression function, in bytes. HMAC keys
/// longer than this are hashed first; shorter ones are zero-padded.
pub const HMAC_BLOCK_BYTES : Int = 64

///|
/// Digest size of HMAC-SHA256, in bytes.
pub const HMAC_DIGEST_BYTES : Int = 32

///|
/// Compute `HMAC-SHA256(key, message)` over one message.
///
/// `key` is copied into a block-sized pad, so the caller keeps ownership
/// of the key bytes and nothing derived from the key survives the call
/// beyond the returned tag. The message is read as a view: no copy of it
/// is taken on the way in.
///
/// # Example
///
/// ```mbt check
/// test {
///   // RFC 4231 test case 2: the keyed MAC of a short ASCII message under
///   // a short ASCII key. The literal is an outside value, not derived
///   // from this implementation, so a broken implementation cannot
///   // satisfy it.
///   let tag = @security.hmac_sha256(b"Jefe", b"what do ya want for nothing?")
///   assert_eq(
///     @security.digest_hex(tag),
///     b"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
///   )
/// }
/// ```
pub fn hmac_sha256(key : Bytes, message : BytesView) -> Bytes {
  // RFC 2104: K is the key zero-padded to one block, hashed first when it
  // is longer than a block. `Bytes` is immutable, so both pads are
  // assembled in fixed arrays and converted once on the way out.
  let block = FixedArray::make(HMAC_BLOCK_BYTES, b'\x00')
  if key.length() > HMAC_BLOCK_BYTES {
    // The digest is 32 bytes and the pad is 64, so only the digest is
    // copied in; the fixed array already holds the zero tail the pad needs.
    let hashed = sha256(key[:])
    for index in 0..<hashed.length() {
      block[index] = hashed[index]
    }
  } else {
    for index in 0..<key.length() {
      block[index] = key[index]
    }
  }
  let inner_pad = FixedArray::make(HMAC_BLOCK_BYTES, b'\x36')
  let outer_pad = FixedArray::make(HMAC_BLOCK_BYTES, b'\x5c')
  for index in 0..<HMAC_BLOCK_BYTES {
    let byte = block[index].to_uint()
    inner_pad[index] = (byte ^ 0x36U).reinterpret_as_int().to_byte()
    outer_pad[index] = (byte ^ 0x5cU).reinterpret_as_int().to_byte()
  }
  outer_hash(
    Bytes::from_array(outer_pad),
    inner_hash(Bytes::from_array(inner_pad), message),
  )
}

///|
/// SHA-256 over one pad followed by `message`.
///
/// Private: HMAC is the only caller that needs the concatenation, and it
/// exists so the pads are built once rather than reallocated per round.
fn inner_hash(pad : Bytes, message : BytesView) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(pad[:])
  buf.write_bytes(message)
  sha256(buf.contents()[:])
}

///|
/// SHA-256 over the outer pad followed by an inner digest.
///
/// The second round of the HMAC nesting, kept separate so
/// `hmac_sha256` reads as the two-round construction RFC 2104 defines.
fn outer_hash(pad : Bytes, inner_digest : Bytes) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(pad[:])
  buf.write_bytes(inner_digest[:])
  sha256(buf.contents()[:])
}

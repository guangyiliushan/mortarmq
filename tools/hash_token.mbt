/// The `hash-token` developer tool.
///
/// Renders one tokens-file line `digest<TAB>role` for a token so the
/// plaintext never reaches the file. The digest is computed by the same
/// shared SHA-256 implementation the server-side verifier uses
/// (`guangyiliushan/mortarmq/security`), which is what makes the generation
/// path reproducible: run this function on the token, copy the line into
/// the tokens file, and verification recomputes the identical digest.
///
/// Deployment note: tokens are stored as fast-hashed digests, so a leaked
/// tokens file is only as strong as the token entropy. Operations must
/// issue random tokens of at least 128 bits (an explicit threat-model non-goal).

///|
/// Hash `token` into one `digest<TAB>role` tokens-file line.
pub fn hash_token(
  token : BytesView,
  role : Bytes,
) -> Result[Bytes, @security.TokensError] {
  @security.token_line(@security.sha256(token), role)
}

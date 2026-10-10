/// The token-verification discipline (REQ-SEC-001, REQ-SEC-002) as one
/// self-contained module API (Q15): CONNECT calls `authenticate` and maps
/// its verdict onto 0x0006 AUTH_FAILED; nothing outside this file compares
/// token material.
///
/// Constant-time shape (CWE-208, Go crypto/subtle form): `digest_eq` is the
/// single comparison point in the repo. It folds every byte pair into one
/// accumulator before any decision and never short-circuits, so timing is a
/// function of the fixed 32-byte length only. The one comparison that
/// extracts the final verdict runs on that accumulator — a single fixed
/// instruction whose outcome is the answer the caller is about to receive
/// anyway — and never on partial content.
///
/// Failure discipline (REQ-SEC-002): every failure — unknown token, empty
/// store, malformed input — leaves through one exit that pauses 100ms and
/// returns the same generic `Rejected` verdict. Failure timing and value
/// carry no reason. Hashing the presented token is deliberately not
/// constant time (T073 won't-defend column), and a leaked tokens file is
/// only as strong as token entropy (ops: ≥128-bit random tokens).

///|
/// The uniform pause applied to every authentication failure (ms).
pub const AUTH_FAILURE_DELAY_MS : Int = 100

///|
/// The only authentication failure. It deliberately carries no reason
/// (REQ-SEC-002): unknown token, wrong token, and empty store are one
/// indistinguishable outcome.
pub(all) suberror AuthFail {
  Rejected
} derive(Eq, Debug)

///|
pub extend AuthFail with Eq::{not_equal, equal}

///|
pub extend AuthFail with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The one side effect authentication needs: a pause of `ms` milliseconds.
/// CONNECT binds this to its timer; tests bind a recorder.
pub(open) trait Delay {
  async fn sleep_ms(Self, ms : Int) -> Unit
}

///|
/// Constant-time equality of two 32-byte digests.
///
/// XOR-accumulates every pair of bytes before the single verdict
/// extraction, in the Go crypto/subtle `ConstantTimeCompare` form (length
/// is not secret and is checked first; the content loop never exits early).
fn digest_eq(a : Bytes, b : Bytes) -> Bool {
  if a.length() != 32 || b.length() != 32 {
    return false
  }
  let mut diff = 0U
  for index in 0..<32 {
    diff = diff | (a[index].to_uint() ^ b[index].to_uint())
  }
  // The single-point verdict extraction: `diff` already folded every byte
  // pair, so this decision cannot reveal which bytes differed. No `==`
  // anywhere else in this module touches token or digest content.
  diff == 0U
}

///|
/// The single failure exit: one uniform pause, one generic verdict.
async fn[D : Delay] reject(delay : D) -> Result[Bytes, AuthFail] {
  delay.sleep_ms(AUTH_FAILURE_DELAY_MS)
  Err(Rejected)
}

///|
/// Verify `token` against the tokens-file `store`, returning its role.
///
/// The presented token is hashed with the shared SHA-256 and compared
/// against every stored digest with `digest_eq` — the loop runs the same
/// fixed work for every entry and never exits early on a match. On any
/// failure the result is the generic `Rejected` after exactly one
/// `AUTH_FAILURE_DELAY_MS` pause; on success the role is returned with no
/// pause. If a store repeats one digest, the later entry's role wins.
pub async fn[D : Delay] authenticate(
  store : TokenStore,
  token : BytesView,
  delay : D,
) -> Result[Bytes, AuthFail] {
  let digest = sha256(token)
  let mut role : Bytes? = None
  for index in 0..<store.entries.length() {
    let entry = store.entries[index]
    if digest_eq(digest, entry.digest) {
      role = Some(entry.role)
    }
  }
  match role {
    Some(matched) => Ok(matched)
    None => reject(delay)
  }
}

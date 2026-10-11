/// The token-verification discipline as one
/// self-contained module API: CONNECT calls `authenticate` and maps
/// its verdict onto 0x0006 AUTH_FAILED; nothing outside this file compares
/// token material.
///
/// Constant-time shape (CWE-208, Go crypto/subtle form): `tag_eq` is the
/// single comparison point in the repo. It folds every byte pair into one
/// accumulator before any decision and never short-circuits, so timing is a
/// function of the fixed 32-byte length only. The one comparison that
/// extracts the final verdict runs on that accumulator — a single fixed
/// instruction whose outcome is the answer the caller is about to receive
/// anyway — and never on partial content.
///
/// Failure discipline: every failure — unknown token, empty
/// store, malformed input — leaves through one exit that pauses 100ms and
/// returns the same generic `Rejected` verdict. Failure timing and value
/// carry no reason. Hashing the presented token is deliberately not
/// constant time (an explicit threat-model non-goal), and a leaked tokens file is
/// only as strong as token entropy (ops: ≥128-bit random tokens).
///
/// Cost model: the pause is pure failure-path latency. A success adds no
/// delay; a failure adds exactly one fixed 100ms pause — never twice, never
/// more — plus microsecond-scale compute (one SHA-256 pass over the token
/// and one 32-byte accumulate) and holds only the failing connection's own
/// state plus one timer. The pause runs on an asynchronous timer: it burns
/// no CPU while it waits and never occupies a worker thread.
///
/// Overload interlock: explicit overload rejection lives in the
/// backpressure layer and runs at admission, before authentication. Under
/// overload, new work is refused fast with the 0x4xxx backpressure codes
/// and never reaches the pause, so a failure storm cannot queue pauses
/// behind admitted work. The auth stage is bounded by the auth timeout and
/// the half-frame timeout, and a failed attempt closes the connection, so
/// one connection yields at most one pause per attempt. With `F` concurrent
/// failing connections the fixed cost is `F` timers, `F` times
/// microsecond-scale compute, and O(F) connection state — the 100ms
/// multiplies no shared resource and amplifies nothing but the attacker's
/// own dwell time.

///|
/// The uniform pause applied to every authentication failure (ms).
pub const AUTH_FAILURE_DELAY_MS : Int = 100

///|
/// The only authentication failure. It deliberately carries no reason
///: unknown token, wrong token, and empty store are one
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
/// Constant-time equality of two 32-byte values of secret material.
///
/// The repo's one comparison point for secret-derived digests and tags:
/// token digests (verification path) and HMAC-SHA256 peer tags both decide
/// equality here. XOR-accumulates every pair of bytes before the single
/// verdict extraction, in the Go crypto/subtle `ConstantTimeCompare` form
/// (length is not secret and is checked first; the content loop never
/// exits early).
pub fn tag_eq(a : BytesView, b : BytesView) -> Bool {
  if a.length() != 32 || b.length() != 32 {
    return false
  }
  let mut diff = 0U
  for index in 0..<32 {
    diff = diff | (a[index].to_uint() ^ b[index].to_uint())
  }
  // The single-point verdict extraction: `diff` already folded every byte
  // pair, so this decision cannot reveal which bytes differed. No `==`
  // anywhere else compares secret material.
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
/// against every stored digest with `tag_eq` — the loop runs the same
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
    if tag_eq(digest[:], entry.digest[:]) {
      role = Some(entry.role)
    }
  }
  match role {
    Some(matched) => Ok(matched)
    None => reject(delay)
  }
}

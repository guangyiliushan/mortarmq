/// Tests for the authentication discipline.
///
/// `authenticate` is the security module's whole verdict surface:
/// CONNECT calls it and maps the result onto 0x0006 AUTH_FAILED. Contract:
/// a known token yields its role with no pause; every failure -- unknown
/// token, empty store, near-miss digest -- is the same generic verdict after
/// exactly one 100ms pause through the injected Delay, so failure reasons
/// are indistinguishable in both value and timing shape.

///|
/// A Delay that records requested pauses instead of waiting.
priv struct RecordDelay {
  calls : Ref[Array[Int32]]
}

///|
impl Delay for RecordDelay with fn sleep_ms(self, ms : Int32) -> Unit {
  self.calls.val.push(ms)
}

///|
fn record_delay() -> RecordDelay {
  { calls: Ref::Ref([]), }
}

///|
fn test_store() -> @security.TokenStore raise {
  let line1 = b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\tadmin"
  let line2 = b"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\tclient"
  match @security.parse_tokens((line1 + b"\n" + line2 + b"\n")[:]) {
    Some(store) => store
    None => fail("the fixture store must parse")
  }
}

///|
async test "authenticate returns the role of a known token without pausing" {
  let delay = record_delay()
  let outcome = @security.authenticate(test_store(), b"abc", delay)
  assert_eq(outcome, Ok(b"admin"))
  assert_eq(delay.calls.val, []) // success is never delayed
}

///|
async test "authenticate finds a role anywhere in the store" {
  let delay = record_delay()
  // The empty message is the second entry.
  let outcome = @security.authenticate(test_store(), b"", delay)
  assert_eq(outcome, Ok(b"client"))
  assert_eq(delay.calls.val, [])
}

///|
async test "authenticate rejects an unknown token with one 100ms pause" {
  let delay = record_delay()
  let outcome = @security.authenticate(test_store(), b"unknown-token", delay)
  assert_eq(outcome, Err(@security.Rejected))
  assert_eq(delay.calls.val, [100])
}

///|
async test "every failure is the same verdict and the same pause" {
  let empty_store = match @security.parse_tokens(b"") {
    Some(store) => store
    None => fail("the empty file must parse")
  }
  let cases = [
    (test_store(), b"abx"), // near miss on "abc"
    (test_store(), b"unknown-token"),
    (empty_store, b"abc"),
    (empty_store, b""),
  ]
  let verdicts = []
  for case in cases {
    let delay = record_delay()
    let outcome = @security.authenticate(case.0, case.1[:], delay)
    verdicts.push(outcome)
    assert_eq(delay.calls.val, [100])
  }
  for verdict in verdicts {
    assert_eq(verdict, Err(@security.Rejected))
  }
}

///|
async test "a file that repeats one digest is refused whole" {
  let line1 = b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\tfirst"
  let line2 = b"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\tsecond"
  // Two lines naming one digest disagree about the role, so the parser
  // refuses the whole file instead of letting line order pick the role.
  // The authenticate level keeps later-entry-wins for stores that are
  // already built in memory; the file parser is what refuses the
  // ambiguity before a store can exist.
  assert_eq(
    @security.parse_tokens((line1 + b"\n" + line2 + b"\n")[:]) is None,
    true,
  )
}

/// Exercise the reconnect story against the golden: the frozen backoff
/// schedule, then the disconnect to reconnect to renegotiation walk with
/// its four assertions -- session rebuilt, subscriptions restored, credit
/// windows reset, and the cursor never regressing.

///|
/// A fixed-value RNG so jitter is deterministic in tests.
priv struct FixedRng {
  value : UInt64
}

///|
impl @harness.Rng for FixedRng with fn next_uint64(self) -> UInt64 {
  self.value
}

///|
fn fixed_rng(value : UInt64) -> FixedRng {
  { value, }
}

///|
fn saved_sub(
  group : Bytes,
  topic_id : Int,
  ack_floor : UInt64,
) -> @client.Subscription {
  {
    group,
    topic_id: topic_id.to_uint16(),
    partition: 0xFFFFU.to_uint16(),
    start_policy: (0).to_byte(),
    credit_count: 256U.to_uint16(),
    credit_bytes: 2097152U,
    flags: 0U.to_uint16(),
    ack_floor,
  }
}

///|
test "the reconnect schedule is 500ms doubling and caps at 30s" {
  // a zero RNG leaves the base bare: the literal frozen schedule
  let quiet = fixed_rng(0UL)
  assert_eq(@client.reconnect_delay(0, quiet), 500U)
  assert_eq(@client.reconnect_delay(1, quiet), 1000U)
  assert_eq(@client.reconnect_delay(2, quiet), 2000U)
  assert_eq(@client.reconnect_delay(3, quiet), 4000U)
  assert_eq(@client.reconnect_delay(4, quiet), 8000U)
  assert_eq(@client.reconnect_delay(5, quiet), 16000U)
  assert_eq(@client.reconnect_delay(6, quiet), 30000U) // 32000 caps
  assert_eq(@client.reconnect_delay(20, quiet), 30000U) // and stays
}

///|
test "the jitter is additive within a quarter of the base" {
  // any draw keeps the delay inside base..=base + base/4
  let loud = fixed_rng(0xFFFFFFFFFFFFFFFFUL)
  let first = @client.reconnect_delay(0, loud)
  assert_true(first >= 500U && first <= 625U)
  let second = @client.reconnect_delay(1, loud)
  assert_true(second >= 1000U && second <= 1250U)
  // a small draw is deterministic: base + draw
  let mid = fixed_rng(2UL)
  assert_eq(@client.reconnect_delay(2, mid), 2002U)
}

///|
test "the reconnect golden passes its four assertions" {
  // the saved intent of a live session: two subscriptions with cursors
  let subs = [saved_sub(b"orders", 1, 40UL), saved_sub(b"payments", 2, 7UL)]
  // the walk: a session streaming when the transport dies
  let mut state = @client.Streaming
  state = @client.ClientState::on(state, @client.TransportLost)
  assert_eq(state, @client.Backoff) // the disconnect lands in Backoff
  state = @client.ClientState::on(state, @client.BackoffExpired)
  state = @client.ClientState::on(state, @client.TransportUp)
  state = @client.ClientState::on(state, @client.ConnectOk)
  // assertion 1: the session is rebuilt -- the machine reaches Ready
  // and the plan opens with the saved token
  assert_eq(state, @client.Ready)
  let plan = @client.plan_renewal(b"secret-token"[:], subs)
  assert_eq(plan[0], @client.Connect(b"secret-token"[:]))
  // assertion 2: every subscription is restored, in order
  assert_eq(plan.length(), 1 + subs.length())
  for index in 0..<subs.length() {
    assert_eq(plan[index + 1], @client.Resubscribe(subs[index]))
  }
  // assertion 3: each resubscription carries the initial credit window
  for index in 0..<subs.length() {
    match plan[index + 1] {
      Resubscribe(sub) => {
        assert_eq(sub.credit_count, 256U.to_uint16())
        assert_eq(sub.credit_bytes, 2097152U)
      }
      _ => fail("every step after the connect is a resubscription")
    }
  }
  // assertion 4: the resume position is the saved floor, so the cursor
  // never regresses across the reconnect
  for index in 0..<subs.length() {
    match plan[index + 1] {
      Resubscribe(sub) => assert_eq(sub.ack_floor, subs[index].ack_floor)
      _ => fail("every step after the connect is a resubscription")
    }
  }
  assert_eq(subs[0].ack_floor, 40UL)
  assert_eq(subs[1].ack_floor, 7UL)
}

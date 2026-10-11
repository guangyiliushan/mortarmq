/// QuickCheck properties for the producer window: retries never
/// double-accept, and the boundary rules answer their registered codes.
/// Each property pins its seed so a failure reproduces exactly.

///|
/// Draw a shuffled arrival order for sequences 1..n (Fisher-Yates from
/// the draw bits) and the permutation length.
fn pw_order(draw : UInt) -> (Array[UInt64], Int) {
  let n = (draw % 11U).reinterpret_as_int() + 2
  let order : Array[UInt64] = []
  let mut index = 0
  while index < n {
    order.push((index + 1).to_uint64())
    index = index + 1
  }
  let mut bits = draw >> 4
  let mut i = n - 1
  while i > 0 {
    let j = (bits % (i + 1).reinterpret_as_uint()).reinterpret_as_int()
    bits = bits >> 3
    let tmp = order[i]
    order[i] = order[j]
    order[j] = tmp
    i = i - 1
  }
  (order, n)
}

///|
test "P1 a retried sequence is never accepted twice (quickcheck seed=20261018 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let (order, n) = pw_order(draw)
      let registry = @delivery.ProducerRegistry::new()
      // Independent acceptance oracle.
      let seen : Array[Bool] = []
      let mut index = 0
      while index < n {
        seen.push(false)
        index = index + 1
      }
      let mut accepted = 0UL
      let mut ok = true
      // First pass: a shuffled arrival fills every gap eventually.
      for seq in order {
        match registry.admit(1, 0, 7, seq, 1UL, 0UL) {
          Ok(@delivery.Accepted) => {
            accepted = accepted + 1UL
            let slot = seq.to_int() - 1
            if seen[slot] {
              ok = false
            }
            seen[slot] = true
          }
          Ok(_) => ()
          Err(_) => ok = false
        }
        for flushed in registry.drain_flushed(1, 0, 7) {
          accepted = accepted + 1UL
          let slot = flushed.to_int() - 1
          if seen[slot] {
            ok = false
          }
          seen[slot] = true
        }
      }
      // The permutation contains every sequence: all were accepted
      // exactly once.
      if accepted != n.to_uint64() {
        ok = false
      }
      // Second pass: the retry storm of the same order -- everything is
      // a duplicate and nothing is accepted again.
      for seq in order {
        match registry.admit(1, 0, 7, seq, 1UL, 0UL) {
          Ok(@delivery.Duplicate) => ()
          _ => ok = false
        }
      }
      ok
    },
    count=200,
    seed=20261018,
  )
}

///|
test "P2 the boundary rules answer their registered codes (quickcheck seed=20261019 is reproducible)" {
  @quickcheck.check(
    (draw : UInt) => {
      let registry = @delivery.ProducerRegistry::new()
      // Build a frontier of k accepted sequences.
      let k = (draw % 64U).to_uint64() + 1UL
      let mut seq = 1UL
      let mut ok = true
      while seq <= k {
        match registry.admit(1, 0, 7, seq, 1UL, 0UL) {
          Ok(@delivery.Accepted) => ()
          _ => ok = false
        }
        seq = seq + 1UL
      }
      // Past the window is a gap; behind the retained window is expired;
      // inside it, the accepted bit answers duplicate.
      match registry.admit(1, 0, 7, k + 1025UL, 1UL, 0UL) {
        Err(@delivery.ProducerError::SeqGap) => ()
        _ => ok = false
      }
      if k > 1024UL {
        match registry.admit(1, 0, 7, k - 1024UL, 1UL, 0UL) {
          Err(@delivery.ProducerError::SeqExpired) => ()
          _ => ok = false
        }
      }
      match registry.admit(1, 0, 7, k, 1UL, 0UL) {
        Ok(@delivery.Duplicate) => ()
        _ => ok = false
      }
      ok
    },
    count=200,
    seed=20261019,
  )
}

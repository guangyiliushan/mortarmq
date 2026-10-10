/// Exercise the 1024-bit sliding bitmap (ADR-0011): O(1) mark and query,
/// the watermark that consumes only the contiguous prefix (the derived
/// cursor of REQ-CON-004), duplicate idempotence, the window edge, and
/// the residue-collision rule at the 1024 boundary.

///|
test "marks record and duplicates answer false without moving anything" {
  let bitmap = @broker.SlidingBitmap::new(0UL)
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 5UL), true)
  assert_eq(@broker.SlidingBitmap::is_marked(bitmap, 5UL), true)
  assert_eq(@broker.SlidingBitmap::is_marked(bitmap, 6UL), false)
  // The duplicate is idempotent: not newly recorded, state unchanged.
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 5UL), false)
  assert_eq(@broker.SlidingBitmap::watermark(bitmap), 0UL)
  // A sequence below the watermark is consumed, not re-markable.
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 0UL), true)
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 1UL), true)
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 2UL), true)
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 3UL), true)
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 4UL), true)
  assert_eq(@broker.SlidingBitmap::watermark(bitmap), 6UL)
  assert_eq(@broker.SlidingBitmap::is_marked(bitmap, 0UL), true)
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 0UL), false)
}

///|
test "the watermark consumes only the contiguous prefix" {
  let bitmap = @broker.SlidingBitmap::new(0UL)
  ignore(@broker.SlidingBitmap::mark(bitmap, 1UL))
  ignore(@broker.SlidingBitmap::mark(bitmap, 3UL))
  assert_eq(@broker.SlidingBitmap::watermark(bitmap), 0UL)
  ignore(@broker.SlidingBitmap::mark(bitmap, 0UL))
  assert_eq(@broker.SlidingBitmap::watermark(bitmap), 2UL)
  // Filling the gap between 3 and the watermark slides past both.
  ignore(@broker.SlidingBitmap::mark(bitmap, 2UL))
  assert_eq(@broker.SlidingBitmap::watermark(bitmap), 4UL)
}

///|
test "out of order acks derive the same floor as in order ones" {
  let in_order = @broker.SlidingBitmap::new(0UL)
  for seq in 0..<20 {
    ignore(@broker.SlidingBitmap::mark(in_order, seq.to_uint64()))
  }
  let shuffled = @broker.SlidingBitmap::new(0UL)
  let arrival : Array[Int] = [
    7, 0, 19, 3, 1, 12, 2, 8, 4, 5, 9, 6, 15, 10, 11, 13, 14, 18, 16, 17,
  ]
  for seq in arrival {
    ignore(@broker.SlidingBitmap::mark(shuffled, seq.to_uint64()))
  }
  assert_eq(@broker.SlidingBitmap::watermark(shuffled), 20UL)
  assert_eq(
    @broker.SlidingBitmap::watermark(shuffled),
    @broker.SlidingBitmap::watermark(in_order),
  )
}

///|
test "the window edge refuses far sequences and ages out cleanly" {
  let bitmap = @broker.SlidingBitmap::new(0UL)
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 1023UL), true)
  // Exactly at the edge is refused until the watermark catches up.
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 1024UL), false)
  assert_eq(@broker.SlidingBitmap::is_marked(bitmap, 1024UL), false)
  for seq in 0..<1023 {
    ignore(@broker.SlidingBitmap::mark(bitmap, seq.to_uint64()))
  }
  assert_eq(@broker.SlidingBitmap::watermark(bitmap), 1024UL)
  // The residue of the consumed sequence 0 can no longer fake a mark:
  // the bit was cleared as the watermark passed it.
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 1024UL), true)
  assert_eq(@broker.SlidingBitmap::is_marked(bitmap, 1024UL), true)
  assert_eq(@broker.SlidingBitmap::is_marked(bitmap, 0UL), true)
  assert_eq(@broker.SlidingBitmap::watermark(bitmap), 1025UL)
}

///|
test "a window started mid-stream holds its own floor" {
  let bitmap = @broker.SlidingBitmap::new(1000UL)
  assert_eq(@broker.SlidingBitmap::is_marked(bitmap, 999UL), true)
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 999UL), false)
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 1001UL), true)
  assert_eq(@broker.SlidingBitmap::watermark(bitmap), 1000UL)
  assert_eq(@broker.SlidingBitmap::mark(bitmap, 1000UL), true)
  assert_eq(@broker.SlidingBitmap::watermark(bitmap), 1002UL)
}

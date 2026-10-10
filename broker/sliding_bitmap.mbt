/// Track one bounded window of sequences in a 1024-bit sliding bitmap.
///
/// One structure serves both bounded sets of ADR-0011: the A05
/// out-of-order ACK set (whose watermark reads as `ack_floor`, the derived
/// cursor of REQ-CON-004) and the A04 producer dedup `accepted_set` (whose
/// watermark reads as `high_watermark`). The bit of a sequence is its low
/// 10 bits (`seq & 1023`), freshness comes from the watermark, and
/// entries age out as the watermark consumes the contiguous prefix.
///
/// # Stability
///
/// * `mark` and `is_marked` are O(1): one residue, one word, one mask.
///   No allocation happens on any path -- the 16 words (128 bytes,
///   L1-resident) are built once in `new`.
/// * The window covers exactly [watermark, watermark + 1024). A sequence
///   below the watermark is already consumed (is_marked answers true,
///   mark answers false); one at or past the edge is refused until the
///   watermark catches up (the in-flight cap of 1000 keeps the A05 site
///   inside the window).
/// * A duplicate mark is idempotent and answers false (not newly
///   recorded). Consumed bits are cleared as the watermark passes them,
///   so the residue of a sequence 1024 older can never fake a live mark.

///|
/// The window width in bits: 128 bytes of backing words.
pub const BITMAP_WINDOW_BITS : Int = 1024

///|
/// The number of 64-bit words backing the window.
pub const BITMAP_WORDS : Int = 16

///|
/// Hold one sliding window of marked sequences.
///
/// Construct through `SlidingBitmap::new`; the watermark only moves
/// forward, and only through the contiguous marked prefix.
pub struct SlidingBitmap {
  priv words : Array[UInt64]
  priv mut floor : UInt64
}

///|
/// Start an empty window whose watermark is `watermark`.
///
/// Sequences below `watermark` are treated as already consumed; the first
/// live sequence is `watermark` itself.
///
/// Example:
///
/// ```mbt check
/// test {
///   let bitmap = @broker.SlidingBitmap::new(0UL)
///   assert_eq(@broker.SlidingBitmap::watermark(bitmap), 0UL)
///   assert_eq(@broker.SlidingBitmap::is_marked(bitmap, 0UL), false)
/// }
/// ```
pub fn SlidingBitmap::new(watermark : UInt64) -> SlidingBitmap {
  { words: Array::make(BITMAP_WORDS, 0UL), floor: watermark, }
}

///|
/// Mark one sequence and advance the watermark over the contiguous prefix.
///
/// Returns true only when the sequence is inside the window and its bit
/// flipped from clear to set. A sequence below the watermark, one at or
/// past the window edge, or one already marked answers false and changes
/// nothing. After the mark, every contiguous marked sequence from the old
/// watermark on is consumed into it (its bit cleared), so the derived
/// cursor is the longest acked prefix -- never a gap.
///
/// Example:
///
/// ```mbt check
/// test {
///   let bitmap = @broker.SlidingBitmap::new(0UL)
///   assert_eq(@broker.SlidingBitmap::mark(bitmap, 1UL), true)
///   assert_eq(@broker.SlidingBitmap::watermark(bitmap), 0UL)
///   assert_eq(@broker.SlidingBitmap::mark(bitmap, 0UL), true)
///   assert_eq(@broker.SlidingBitmap::watermark(bitmap), 2UL)
///   assert_eq(@broker.SlidingBitmap::mark(bitmap, 0UL), false)
/// }
/// ```

///|
/// Consume the contiguous marked prefix into the watermark.
///
/// Tail-recursive: each call clears exactly one consumed bit, so the
/// whole prefix costs one step per sequence and allocates nothing.
fn SlidingBitmap::consume_prefix(self : SlidingBitmap) -> Unit {
  let head = (self.floor & 1023UL).to_int()
  let head_mask = 1UL << (head % 64)
  let head_word = head / 64
  if (self.words[head_word] & head_mask) == 0UL {
    return
  }
  self.words[head_word] = self.words[head_word] ^ head_mask
  self.floor = self.floor + 1UL
  self.consume_prefix()
}

///|
pub fn SlidingBitmap::mark(self : SlidingBitmap, seq : UInt64) -> Bool {
  if seq < self.floor {
    return false
  }
  if seq - self.floor >= BITMAP_WINDOW_BITS.to_uint64() {
    return false
  }
  let residue = (seq & 1023UL).to_int()
  let mask = 1UL << (residue % 64)
  let word = residue / 64
  if (self.words[word] & mask) != 0UL {
    return false
  }
  self.words[word] = self.words[word] | mask
  self.consume_prefix()
  true
}

///|
/// Report whether one sequence is already recorded (O(1)).
///
/// A sequence below the watermark answers true -- it was consumed into
/// the prefix. One at or past the window edge answers false.
///
/// Example:
///
/// ```mbt check
/// test {
///   let bitmap = @broker.SlidingBitmap::new(0UL)
///   ignore(@broker.SlidingBitmap::mark(bitmap, 0UL))
///   assert_eq(@broker.SlidingBitmap::is_marked(bitmap, 0UL), true)
///   assert_eq(@broker.SlidingBitmap::is_marked(bitmap, 1UL), false)
/// }
/// ```
pub fn SlidingBitmap::is_marked(self : SlidingBitmap, seq : UInt64) -> Bool {
  if seq < self.floor {
    return true
  }
  if seq - self.floor >= BITMAP_WINDOW_BITS.to_uint64() {
    return false
  }
  let residue = (seq & 1023UL).to_int()
  (self.words[residue / 64] & (1UL << (residue % 64))) != 0UL
}

///|
/// Read the current watermark (O(1)).
///
/// For the A05 site this is `ack_floor`, the derived cursor of
/// REQ-CON-004: it only advances over the contiguous acked prefix. For
/// the A04 dedup site it plays `high_watermark`.
pub fn SlidingBitmap::watermark(self : SlidingBitmap) -> UInt64 {
  self.floor
}

///|
/// Copy out the 1024 window bits (16 words) for a checkpoint export.
///
/// The rare checkpoint path allocates one array; the hot paths
/// (`mark`, `is_marked`, `watermark`) stay allocation-free.
pub fn SlidingBitmap::snapshot(self : SlidingBitmap) -> Array[UInt64] {
  let copy : Array[UInt64] = []
  for word in self.words {
    copy.push(word)
  }
  copy
}

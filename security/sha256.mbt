/// SHA-256 as specified by FIPS 180-4 (Secure Hash Standard).
///
/// This is the single implementation shared by the `hash-token` developer
/// tool and the server-side token verification path: the
/// digest computed when a tokens file entry is generated must be exactly the
/// digest the verifier recomputes, so both sides call these functions. The
/// implementation is pure MoonBit with no platform calls, so the same code
/// and the same known-answer tests run on every backend the build gates
/// (native, js, wasm, wasm-gc).
///
/// Known-answer coverage lives in `sha256_test.mbt` (RFC 6234 byte-oriented
/// vectors plus padding-boundary lengths) and `sha256_wbtest.mbt`
/// (chunked-update equivalence).

///|
/// Initial hash value H(0) (FIPS 180-4 section 5.3.3).
let iv : Array[UInt32] = [
  0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU, 0x510e527fU, 0x9b05688cU, 0x1f83d9abU,
  0x5be0cd19U,
]

///|
/// Round constants K(0..63) (FIPS 180-4 section 4.2.2).
let k_round : Array[UInt32] = [
  0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U,
  0xab1c5ed5U, 0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU,
  0x9bdc06a7U, 0xc19bf174U, 0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU,
  0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU, 0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U,
  0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U, 0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU,
  0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U, 0xa2bfe8a1U, 0xa81a664bU,
  0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U, 0x19a4c116U,
  0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
  0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U,
  0xc67178f2U,
]

///|
/// One SHA-256 hashing run over an incrementally fed message.
///
/// `digest` finalizes a snapshot of everything pushed so far and leaves the
/// run usable: it answers "the digest of the stream up to here" and later
/// `update` calls continue the same message schedule. That makes double
/// finalization and update-after-digest well-defined instead of trap-prone.
priv struct Sha256 {
  h : FixedArray[UInt32]
  block : FixedArray[Byte]
  mut block_len : Int32
  mut total_len : UInt64
}

///|
/// Start a fresh run at the FIPS 180-4 initial value.
fn Sha256::new() -> Sha256 {
  let h = FixedArray::make(8, 0U)
  for i in 0..<8 {
    h[i] = iv[i]
  }
  { h, block: FixedArray::make(64, b'\x00'), block_len: 0, total_len: 0UL, }
}

///|
/// Rotate `x` right by `n` bits (n in 1..31).
fn rotr(x : UInt32, n : Int32) -> UInt32 {
  (x >> n) | (x << (32 - n))
}

///|
/// Absorb one full 64-byte block from `self.block` into the chain state.
fn Sha256::compress(self : Sha256) -> Unit {
  let w = FixedArray::make(64, 0U)
  for i in 0..<16 {
    let j = i * 4
    w[i] = (self.block[j].to_uint() << 24) |
      (self.block[j + 1].to_uint() << 16) |
      (self.block[j + 2].to_uint() << 8) |
      self.block[j + 3].to_uint()
  }
  for i in 16..<64 {
    let w15 = w[i - 15]
    let w2 = w[i - 2]
    let s0 = rotr(w15, 7) ^ rotr(w15, 18) ^ (w15 >> 3)
    let s1 = rotr(w2, 17) ^ rotr(w2, 19) ^ (w2 >> 10)
    w[i] = w[i - 16] + s0 + w[i - 7] + s1
  }
  let a0 = self.h[0]
  let b0 = self.h[1]
  let c0 = self.h[2]
  let d0 = self.h[3]
  let e0 = self.h[4]
  let f0 = self.h[5]
  let g0 = self.h[6]
  let h0 = self.h[7]
  let mut a = a0
  let mut b = b0
  let mut c = c0
  let mut d = d0
  let mut e = e0
  let mut f = f0
  let mut g = g0
  let mut hh = h0
  for i in 0..<64 {
    let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
    let ch = (e & f) ^ ((e ^ 0xFFFFFFFFU) & g)
    let temp1 = hh + s1 + ch + k_round[i] + w[i]
    let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
    let maj = (a & b) ^ (a & c) ^ (b & c)
    let temp2 = s0 + maj
    hh = g
    g = f
    f = e
    e = d + temp1
    d = c
    c = b
    b = a
    a = temp1 + temp2
  }
  self.h[0] = a0 + a
  self.h[1] = b0 + b
  self.h[2] = c0 + c
  self.h[3] = d0 + d
  self.h[4] = e0 + e
  self.h[5] = f0 + f
  self.h[6] = g0 + g
  self.h[7] = h0 + hh
}

///|
/// Absorb `input` bytes into the run. Empty input is a no-op.
fn Sha256::update(self : Sha256, input : BytesView) -> Unit {
  let total = input.length()
  self.total_len = self.total_len + total.to_uint64()
  let mut offset = 0
  while offset < total {
    let mut take = 64 - self.block_len
    if take > total - offset {
      take = total - offset
    }
    for i in 0..<take {
      self.block[self.block_len + i] = input[offset + i]
    }
    self.block_len = self.block_len + take
    offset = offset + take
    if self.block_len == 64 {
      self.compress()
      self.block_len = 0
    }
  }
}

///|
/// Digest of everything pushed so far, leaving the run usable.
fn Sha256::digest(self : Sha256) -> Bytes {
  // Finalize a snapshot so a second digest call answers the same question
  // and later updates can continue the message.
  let snap = Sha256::new()
  for i in 0..<8 {
    snap.h[i] = self.h[i]
  }
  for i in 0..<64 {
    snap.block[i] = self.block[i]
  }
  snap.block_len = self.block_len
  snap.total_len = self.total_len
  // FIPS 180-4 section 5.1 padding: 0x80, zeros, then the 64-bit big-endian
  // message length in bits.
  snap.block[snap.block_len] = b'\x80'
  snap.block_len = snap.block_len + 1
  if snap.block_len > 56 {
    for i in snap.block_len..<64 {
      snap.block[i] = b'\x00'
    }
    snap.compress()
    snap.block_len = 0
  }
  for i in snap.block_len..<56 {
    snap.block[i] = b'\x00'
  }
  let bits = snap.total_len * 8UL
  for i in 0..<8 {
    let shift = (7 - i) * 8
    snap.block[56 + i] = ((bits >> shift) & 0xFFUL)
      .to_uint()
      .reinterpret_as_int()
      .to_byte()
  }
  snap.compress()
  let buf = Buffer()
  for i in 0..<8 {
    let word = snap.h[i]
    buf.write_byte(((word >> 24) & 0xFFU).reinterpret_as_int().to_byte())
    buf.write_byte(((word >> 16) & 0xFFU).reinterpret_as_int().to_byte())
    buf.write_byte(((word >> 8) & 0xFFU).reinterpret_as_int().to_byte())
    buf.write_byte((word & 0xFFU).reinterpret_as_int().to_byte())
  }
  buf.contents()
}

///|
/// One-shot SHA-256 of `input`: the 32-byte digest (FIPS 180-4).
pub fn sha256(input : BytesView) -> Bytes {
  let hasher = Sha256::new()
  hasher.update(input)
  hasher.digest()
}

///|
/// Lowercase hex rendering of a raw digest: exactly 64 bytes of `[0-9a-f]`.
pub fn digest_hex(digest : Bytes) -> Bytes {
  let buf = Buffer()
  for index in 0..<digest.length() {
    let byte = digest[index].to_uint()
    buf.write_byte(hex_digit((byte >> 4) & 0xFU))
    buf.write_byte(hex_digit(byte & 0xFU))
  }
  buf.contents()
}

///|
/// One hex nibble as its lowercase ASCII byte.
fn hex_digit(nibble : UInt32) -> Byte {
  if nibble < 10U {
    (nibble + 0x30U).reinterpret_as_int().to_byte()
  } else {
    // 10 -> 'a' (0x61).
    (nibble + 0x57U).reinterpret_as_int().to_byte()
  }
}

///|
/// One-shot SHA-256 of `input` as 64 lowercase hex bytes.
pub fn sha256_hex(input : BytesView) -> Bytes {
  digest_hex(sha256(input))
}

/// Exercise deterministic key routing: the frozen FNV-1a reference
/// vectors, the literal modulo contract, and same-key replay stability.

///|
fn all_byte_values() -> Bytes {
  let buf = Buffer()
  for value in 0..<256 {
    buf.write_byte(value.to_byte())
  }
  buf.contents()
}

///|
test "fnv1a32 matches the reference vectors for empty and text keys" {
  assert_eq(@broker.fnv1a32(b""), 0x811C9DC5U)
  assert_eq(@broker.fnv1a32(b"a"), 0xE40C292CU)
  assert_eq(@broker.fnv1a32(b"b"), 0xE70C2DE5U)
  assert_eq(@broker.fnv1a32(b"foobar"), 0xBF9CF968U)
  assert_eq(@broker.fnv1a32(b"orders"), 0x325E96ECU)
  assert_eq(@broker.fnv1a32(b"user-42"), 0x026073ABU)
  assert_eq(@broker.fnv1a32(b"MortarMQ"), 0x1FF5EA16U)
}

///|
test "fnv1a32 matches the reference vectors for binary keys" {
  assert_eq(@broker.fnv1a32(b"\x00"), 0x050C5D1FU)
  assert_eq(@broker.fnv1a32(b"\xff\xfe\xfd"), 0x8D61D617U)
  assert_eq(@broker.fnv1a32(all_byte_values()), 0x90A458C5U)
}

///|
test "routing equals the literal modulo contract" {
  assert_eq(@broker.route_partition(b"a", 7), 5)
  assert_eq(@broker.route_partition(b"a", 65535), 3385)
  assert_eq(@broker.route_partition(b"b", 2), 1)
  assert_eq(@broker.route_partition(b"foobar", 3), 1)
  assert_eq(@broker.route_partition(b"foobar", 255), 190)
  assert_eq(@broker.route_partition(b"orders", 16), 12)
  assert_eq(@broker.route_partition(b"orders", 65535), 51530)
  assert_eq(@broker.route_partition(b"orders", 2), 0)
  assert_eq(@broker.route_partition(b"user-42", 255), 129)
  assert_eq(@broker.route_partition(b"user-42", 3), 0)
  assert_eq(@broker.route_partition(b"MortarMQ", 1024), 534)
  assert_eq(@broker.route_partition(b"", 1), 0)
  assert_eq(@broker.route_partition(b"", 2), 1)
  assert_eq(@broker.route_partition(b"\x00", 2), 1)
  assert_eq(@broker.route_partition(b"\xff\xfe\xfd", 7), 3)
}

///|
test "the same key replays the same partition" {
  let keys : Array[Bytes] = [b"a", b"orders", b"", b"user-42", b"MortarMQ"]
  let counts : Array[UInt16] = [1, 2, 3, 7, 16, 255, 65535]
  for i in 0..<keys.length() {
    for j in 0..<counts.length() {
      let first = @broker.route_partition(keys[i], counts[j])
      for replay in 0..<100 {
        // route other keys between replays; a stateful hash would drift
        let other = (i + replay + 1) % keys.length()
        let noise = @broker.route_partition(keys[other], counts[j])
        assert_true(noise < counts[j])
        assert_eq(@broker.route_partition(keys[i], counts[j]), first)
      }
    }
  }
}

///|
test "a one-partition topic routes every key to partition zero" {
  let keys : Array[Bytes] = [b"a", b"orders", b"", b"user-42", b"\xff\xfe\xfd"]
  for i in 0..<keys.length() {
    assert_eq(@broker.route_partition(keys[i], 1), 0)
  }
}

///|
test "the routed partition stays inside the partition window" {
  let keys : Array[Bytes] = [
    b"a", b"orders", b"", b"user-42", b"MortarMQ", b"\x00",
  ]
  let counts : Array[UInt16] = [1, 2, 3, 7, 16, 255, 1024, 65535]
  for i in 0..<keys.length() {
    for j in 0..<counts.length() {
      assert_true(@broker.route_partition(keys[i], counts[j]) < counts[j])
    }
  }
}

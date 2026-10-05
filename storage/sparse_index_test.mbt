/// Pin the frozen 32-byte sparse index entry layout and its trust boundary.

///|
const EXPECTED_ENTRY_BYTES : Int = 32

///|
fn sample_entry() -> @storage.IndexEntry {
  @storage.IndexEntry::new(
    sequence=100UL,
    timestamp_unix_ms=200UL,
    file_offset=56U,
    record_len=64U,
  )
}

///|
test "sparse index entry size is pinned at exactly 32 bytes" {
  assert_eq(@storage.INDEX_ENTRY_BYTES, EXPECTED_ENTRY_BYTES)
  assert_eq(
    @storage.encode_index_entry(sample_entry()).length(),
    EXPECTED_ENTRY_BYTES,
  )
}

///|
test "32-byte entries never straddle a 64-byte block boundary" {
  assert_eq(64 % @storage.INDEX_ENTRY_BYTES, 0)
  for index in 0..<8 {
    let start = index * @storage.INDEX_ENTRY_BYTES
    assert_eq(start / 64, (start + @storage.INDEX_ENTRY_BYTES - 1) / 64)
  }
}

///|
test "sparse index entry round-trips zero, unit, and maximum fields" {
  let zero = @storage.IndexEntry::new(
    sequence=0UL,
    timestamp_unix_ms=0UL,
    file_offset=0U,
    record_len=0U,
  )
  let unit = @storage.IndexEntry::new(
    sequence=1UL,
    timestamp_unix_ms=1UL,
    file_offset=1U,
    record_len=1U,
  )
  let max = @storage.IndexEntry::new(
    sequence=0xFFFFFFFFFFFFFFFFUL,
    timestamp_unix_ms=0xFFFFFFFFFFFFFFFFUL,
    file_offset=0xFFFFFFFFU,
    record_len=0xFFFFFFFFU,
  )
  for entry in [zero, unit, max] {
    let encoded = @storage.encode_index_entry(entry)
    assert_eq(encoded.length(), EXPECTED_ENTRY_BYTES)
    assert_eq(@storage.decode_index_entry(encoded[:]), Ok(entry))
  }
}

///|
test "sparse index encoder matches the hand-built frozen-layout vector" {
  let expected : Bytes = b"\x00\x00\x00\x00\x00\x00\x00\x64\x00\x00\x00\x00\x00\x00\x00\xc8\x00\x00\x00\x38\x00\x00\x00\x40\x00\x00\x00\x00\x00\x00\x00\x00"
  assert_eq(@storage.encode_index_entry(sample_entry()), expected)
  assert_eq(@storage.decode_index_entry(expected[:]), Ok(sample_entry()))
}

///|
test "sparse index decoder rejects empty, short, and oversized input" {
  let encoded = @storage.encode_index_entry(sample_entry())
  assert_eq(@storage.decode_index_entry(b""[:]), Err(@storage.Malformed))
  assert_eq(@storage.decode_index_entry(encoded[:1]), Err(@storage.Malformed))
  assert_eq(
    @storage.decode_index_entry(encoded[:EXPECTED_ENTRY_BYTES - 1]),
    Err(@storage.Malformed),
  )
  let oversized = encoded[:].to_owned() + b"\x00"
  assert_eq(@storage.decode_index_entry(oversized[:]), Err(@storage.Malformed))
}

///|
test "sparse index decoder rejects nonzero reserved bytes" {
  let encoded = @storage.encode_index_entry(sample_entry())
  let first_reserved = encoded[:24].to_owned() +
    b"\x01" +
    encoded[25:].to_owned()
  assert_eq(
    @storage.decode_index_entry(first_reserved[:]),
    Err(@storage.Malformed),
  )
  let last_reserved = encoded[:31].to_owned() + b"\x80"
  assert_eq(
    @storage.decode_index_entry(last_reserved[:]),
    Err(@storage.Malformed),
  )
}

/// Exercise sparse index file decoding and point reads against real segment
/// and index bytes, including the deterministic hit-rate sweep.

///|
fn anchored_record(
  sequence : UInt64,
  timestamp_unix_ms : UInt64,
) -> Bytes raise {
  match
    @storage.encode_record_header(
      @storage.RecordHeader::new(
        flags=1,
        key_length=1,
        value_length=1,
        sequence~,
        producer_id=1UL,
        producer_seq=sequence,
        timestamp_unix_ms~,
        leader_epoch=0,
        replication_flags=0,
      ),
      b"k",
      b"v",
    ) {
    Ok(bytes) => bytes
    Err(_) => fail("record fixture encoding failed")
  }
}

///|
fn anchored_segment(
  sequences : Array[UInt64],
) -> (Array[@storage.IndexEntry], Bytes) raise {
  let entries : Array[@storage.IndexEntry] = []
  let buf = Buffer()
  let mut offset = 0
  for sequence in sequences {
    let record = anchored_record(sequence, sequence)
    entries.push(
      @storage.IndexEntry::new(
        sequence~,
        timestamp_unix_ms=sequence,
        file_offset=offset.reinterpret_as_uint(),
        record_len=record.length().reinterpret_as_uint(),
      ),
    )
    buf.write_bytes(record)
    offset += record.length()
  }
  (entries, buf.contents())
}

///|
fn sample_segment() -> (Array[@storage.IndexEntry], Bytes) raise {
  anchored_segment([10UL, 20UL, 30UL])
}

///|
fn index_file_bytes(entries : Array[@storage.IndexEntry]) -> Bytes {
  let buf = Buffer()
  for entry in entries {
    buf.write_bytes(@storage.encode_index_entry(entry))
  }
  buf.contents()
}

///|
test "index file decoder round-trips empty, single, and multi-entry files" {
  assert_eq(@storage.decode_index_file(b""[:]), Ok([]))
  let (entries, _segment) = sample_segment()
  let single = index_file_bytes([entries[1]])
  assert_eq(@storage.decode_index_file(single[:]), Ok([entries[1]]))
  let multi = index_file_bytes(entries)
  assert_eq(@storage.decode_index_file(multi[:]), Ok(entries))
}

///|
test "index file decoder rejects partial strides and corrupt entry bytes" {
  let (entries, _segment) = sample_segment()
  let file = index_file_bytes(entries)
  assert_eq(
    @storage.decode_index_file(file[:file.length() - 1]),
    Err(@storage.Malformed),
  )
  let oversized = file[:].to_owned() + b"\x00"
  assert_eq(@storage.decode_index_file(oversized[:]), Err(@storage.Malformed))
  let corrupt_reserved = file[:2 * @storage.INDEX_ENTRY_BYTES + 24].to_owned() +
    b"\x01" +
    file[2 * @storage.INDEX_ENTRY_BYTES + 25:].to_owned()
  assert_eq(
    @storage.decode_index_file(corrupt_reserved[:]),
    Err(@storage.Malformed),
  )
}

///|
async test "index file read back from disk keeps every entry block-aligned" {
  let written = [
    @storage.IndexEntry::new(
      sequence=0UL,
      timestamp_unix_ms=0UL,
      file_offset=0U,
      record_len=62U,
    ),
    @storage.IndexEntry::new(
      sequence=1UL,
      timestamp_unix_ms=1UL,
      file_offset=62U,
      record_len=62U,
    ),
    @storage.IndexEntry::new(
      sequence=2UL,
      timestamp_unix_ms=2UL,
      file_offset=124U,
      record_len=64U,
    ),
    @storage.IndexEntry::new(
      sequence=0x8000000000000000UL,
      timestamp_unix_ms=3UL,
      file_offset=188U,
      record_len=70U,
    ),
    @storage.IndexEntry::new(
      sequence=0xFFFFFFFFFFFFFFFFUL,
      timestamp_unix_ms=0xFFFFFFFFFFFFFFFFUL,
      file_offset=0xFFFFFFFFU,
      record_len=0xFFFFFFFFU,
    ),
  ]
  let file = index_file_bytes(written)
  assert_eq(file.length(), 5 * @storage.INDEX_ENTRY_BYTES)
  let disk = @harness.FakeDisk::new()
  assert_eq(@harness.Disk::write(disk, b"partition-0.index", file), Ok(()))
  let stored = match @harness.Disk::read(disk, b"partition-0.index") {
    Ok(bytes) => bytes
    Err(_) => fail("index file read failed")
  }
  let decoded = match @storage.decode_index_file(stored[:]) {
    Ok(entries) => entries
    Err(_) => fail("stored index file failed to decode")
  }
  assert_eq(decoded, written)
  assert_eq(decoded.length() * @storage.INDEX_ENTRY_BYTES, stored.length())
  for index in 0..<decoded.length() {
    let start = index * @storage.INDEX_ENTRY_BYTES
    assert_eq(start / 64, (start + @storage.INDEX_ENTRY_BYTES - 1) / 64)
  }
}

///|
test "point read hits the first, middle, and last indexed record" {
  let (entries, segment) = sample_segment()
  for sequence in [10UL, 20UL, 30UL] {
    let entry = match @storage.lookup_index_entry(entries, sequence) {
      Some(entry) => entry
      None => fail("expected an indexed sequence to hit")
    }
    match @storage.read_record_header_at(segment[:], entry) {
      Ok(header) => {
        assert_eq(header.sequence, sequence)
        assert_eq(header.timestamp_unix_ms, entry.timestamp_unix_ms)
      }
      Err(_) => fail("expected the anchored record to decode")
    }
  }
}

///|
test "point read misses below-minimum, above-maximum, and empty indexes" {
  let (entries, _segment) = sample_segment()
  assert_eq(@storage.lookup_index_entry(entries, 9UL), None)
  assert_eq(@storage.lookup_index_entry(entries, 31UL), None)
  assert_eq(@storage.lookup_index_entry([], 10UL), None)
  let single = [entries[2]]
  assert_eq(@storage.lookup_index_entry(single, 30UL), Some(entries[2]))
  assert_eq(@storage.lookup_index_entry(single, 29UL), None)
  match @storage.decode_index_file(b""[:]) {
    Ok(empty) => assert_eq(@storage.lookup_index_entry(empty, 10UL), None)
    Err(_) => fail("an empty index file decodes to an empty index")
  }
}

///|
test "point read hits the zero and maximum boundary sequences" {
  let entries = [
    @storage.IndexEntry::new(
      sequence=0UL,
      timestamp_unix_ms=0UL,
      file_offset=0U,
      record_len=62U,
    ),
    @storage.IndexEntry::new(
      sequence=0xFFFFFFFFFFFFFFFFUL,
      timestamp_unix_ms=0UL,
      file_offset=62U,
      record_len=62U,
    ),
  ]
  assert_eq(@storage.lookup_index_entry(entries, 0UL), Some(entries[0]))
  assert_eq(
    @storage.lookup_index_entry(entries, 0xFFFFFFFFFFFFFFFFUL),
    Some(entries[1]),
  )
  assert_eq(@storage.lookup_index_entry(entries, 1UL), None)
}

///|
test "point read rejects record extents outside the segment bytes" {
  let segment : Bytes = b"0123456789"
  let beyond = @storage.IndexEntry::new(
    sequence=1UL,
    timestamp_unix_ms=0UL,
    file_offset=11U,
    record_len=0U,
  )
  assert_eq(
    @storage.read_record_header_at(segment[:], beyond),
    Err(@storage.Malformed),
  )
  let overrun = @storage.IndexEntry::new(
    sequence=1UL,
    timestamp_unix_ms=0UL,
    file_offset=8U,
    record_len=4U,
  )
  assert_eq(
    @storage.read_record_header_at(segment[:], overrun),
    Err(@storage.Malformed),
  )
  let short = @storage.IndexEntry::new(
    sequence=1UL,
    timestamp_unix_ms=0UL,
    file_offset=0U,
    record_len=10U,
  )
  assert_eq(
    @storage.read_record_header_at(segment[:], short),
    Err(@storage.Malformed),
  )
}

///|
test "point read detects an index entry anchored at a different record" {
  let first = anchored_record(1UL, 100UL)
  let second = anchored_record(2UL, 200UL)
  let segment = first + second
  let misanchored = @storage.IndexEntry::new(
    sequence=2UL,
    timestamp_unix_ms=200UL,
    file_offset=0U,
    record_len=first.length().reinterpret_as_uint(),
  )
  assert_eq(
    @storage.read_record_header_at(segment[:], misanchored),
    Err(@storage.Malformed),
  )
  let honest = @storage.IndexEntry::new(
    sequence=1UL,
    timestamp_unix_ms=100UL,
    file_offset=0U,
    record_len=first.length().reinterpret_as_uint(),
  )
  match @storage.read_record_header_at(segment[:], honest) {
    Ok(header) => assert_eq(header.sequence, 1UL)
    Err(_) => fail("expected the honestly anchored record to decode")
  }
}

///|
async test "randomized point reads over a stored segment hit every indexed sequence" {
  let rng = @harness.SplitMix64::new(20261005UL)
  let sequences : Array[UInt64] = []
  for _index in 0..<100 {
    sequences.push(@harness.Rng::next_u64(rng))
  }
  sequences.sort()
  for index in 1..<sequences.length() {
    assert_eq(sequences[index - 1] < sequences[index], true)
  }
  let (entries, segment) = anchored_segment(sequences)
  let disk = @harness.FakeDisk::new()
  assert_eq(
    @harness.Disk::write(disk, b"partition-0.index", index_file_bytes(entries)),
    Ok(()),
  )
  assert_eq(@harness.Disk::write(disk, b"partition-0.log", segment), Ok(()))
  let stored_index = match @harness.Disk::read(disk, b"partition-0.index") {
    Ok(bytes) => bytes
    Err(_) => fail("index file read failed")
  }
  let stored_segment = match @harness.Disk::read(disk, b"partition-0.log") {
    Ok(bytes) => bytes
    Err(_) => fail("segment file read failed")
  }
  let decoded = match @storage.decode_index_file(stored_index[:]) {
    Ok(entries) => entries
    Err(_) => fail("stored index file failed to decode")
  }
  let mut hits = 0
  for sequence in sequences {
    let entry = match @storage.lookup_index_entry(decoded, sequence) {
      Some(entry) => entry
      None => fail("randomized point read missed an indexed sequence")
    }
    match @storage.read_record_header_at(stored_segment[:], entry) {
      Ok(header) => {
        assert_eq(header.sequence, sequence)
        hits += 1
      }
      Err(_) => fail("randomized point read failed to decode its record")
    }
  }
  assert_eq(hits, 100)
}

/// Exercise the frozen v0 MMML metadata-log record boundary.

///|
fn sample_header() -> @metadata.MmmlHeader {
  @metadata.MmmlHeader::new(
    format_version=1,
    header_version=1,
    flags=0,
    record_type=@metadata.MmmlRecordType::TopicCreate,
    leader_epoch=2,
    mutation_id=7,
  )
}

///|
fn encode_or_fail(
  header : @metadata.MmmlHeader,
  payload : Bytes,
) -> Bytes raise {
  match @metadata.encode_mmml_record(header, payload[:]) {
    Ok(bytes) => bytes
    Err(_) => fail("record encoding failed")
  }
}

///|
fn sample_bytes() -> Bytes raise {
  encode_or_fail(sample_header(), b"ab")
}

///|
fn expect_malformed(data : BytesView) -> Unit raise {
  match @metadata.decode_mmml_record(data) {
    Err(@metadata.Malformed) => ()
    _ => fail("expected malformed rejection")
  }
}

///|
fn flip_byte(data : Bytes, index : Int) -> Bytes {
  let flipped = (data[index].to_uint() ^ 0xFFU).to_byte()
  let out = Buffer()
  out.write_bytes(data[:index])
  out.write_byte(flipped)
  out.write_bytes(data[index + 1:])
  out.contents()
}

///|
test "mmml record round-trips every frozen header field" {
  let bytes = sample_bytes()
  assert_eq(bytes.length(), @metadata.MMML_HEADER_BYTES + 2)
  match @metadata.decode_mmml_record(bytes[:]) {
    Ok(decoded) => {
      assert_eq(decoded.header, sample_header())
      assert_eq(decoded.payload, b"ab")
    }
    Err(_) => fail("record decoding failed")
  }
}

///|
test "mmml record round-trips all thirteen record types" {
  let types = [
    @metadata.MmmlRecordType::TopicCreate,
    @metadata.MmmlRecordType::TopicUpdate,
    @metadata.MmmlRecordType::TopicDelete,
    @metadata.MmmlRecordType::GroupCreate,
    @metadata.MmmlRecordType::GroupUpdate,
    @metadata.MmmlRecordType::GroupDelete,
    @metadata.MmmlRecordType::BrokerRegister,
    @metadata.MmmlRecordType::BrokerDeregister,
    @metadata.MmmlRecordType::LeaderElect,
    @metadata.MmmlRecordType::LeaderResign,
    @metadata.MmmlRecordType::ConfigUpdate,
    @metadata.MmmlRecordType::SnapshotHint,
    @metadata.MmmlRecordType::UnknownFallback,
  ]
  for record_type in types {
    let header = @metadata.MmmlHeader::new(
      format_version=1,
      header_version=1,
      flags=0,
      record_type~,
      leader_epoch=0,
      mutation_id=0,
    )
    let bytes = encode_or_fail(header, b"")
    match @metadata.decode_mmml_record(bytes[:]) {
      Ok(decoded) => {
        assert_eq(decoded.header, header)
        assert_eq(decoded.payload, b"")
      }
      Err(_) => fail("record decoding failed")
    }
  }
}

///|
test "mmml record round-trips flag bits and empty payload" {
  let header = @metadata.MmmlHeader::new(
    format_version=1,
    header_version=1,
    flags=3,
    record_type=@metadata.MmmlRecordType::TopicDelete,
    leader_epoch=0x0102030405060708UL,
    mutation_id=0x1112131415161718UL,
  )
  let bytes = encode_or_fail(header, b"")
  assert_eq(bytes.length(), @metadata.MMML_HEADER_BYTES)
  match @metadata.decode_mmml_record(bytes[:]) {
    Ok(decoded) => assert_eq(decoded.header, header)
    Err(_) => fail("record decoding failed")
  }
}

///|
test "mmml record layout matches the frozen 34-byte contract" {
  let header = @metadata.MmmlHeader::new(
    format_version=1,
    header_version=1,
    flags=3,
    record_type=@metadata.MmmlRecordType::GroupUpdate,
    leader_epoch=0x0102030405060708UL,
    mutation_id=0x1112131415161718UL,
  )
  let data = encode_or_fail(header, b"xy")
  assert_eq(data.length(), @metadata.MMML_HEADER_BYTES + 2)
  assert_eq(data[:4].to_owned(), b"MMML")
  assert_eq(data[4].to_uint(), 1U)
  assert_eq(data[5].to_uint(), 1U)
  assert_eq(data[6].to_uint(), 0U)
  assert_eq(data[7].to_uint(), 3U)
  for i in 12..<15 {
    assert_eq(data[i].to_uint(), 0U)
  }
  assert_eq(data[15].to_uint(), 2U)
  assert_eq(data[16].to_uint(), 0U)
  assert_eq(data[17].to_uint(), 0x11U)
  for i in 0..<8 {
    assert_eq(data[18 + i].to_uint(), (i + 1).reinterpret_as_uint())
    assert_eq(data[26 + i].to_uint(), (0x11 + i).reinterpret_as_uint())
  }
  assert_eq(data[34:36].to_owned(), b"xy")
}

///|
test "mmml encoder matches the frozen golden record" {
  let expected = Buffer()
  expected.write_bytes(b"MMML")
  expected.write_byte(1)
  expected.write_byte(1)
  expected.write_uint16_be(0)
  expected.write_uint_be(0x866967BDU)
  expected.write_uint_be(2U)
  expected.write_uint16_be(1)
  expected.write_uint64_be(0UL)
  expected.write_uint64_be(1UL)
  expected.write_bytes(b"hi")
  let header = @metadata.MmmlHeader::new(
    format_version=1,
    header_version=1,
    flags=0,
    record_type=@metadata.MmmlRecordType::TopicCreate,
    leader_epoch=0,
    mutation_id=1,
  )
  assert_eq(encode_or_fail(header, b"hi"), expected.contents())
}

///|
test "mmml decoder rejects unregistered record types with a valid CRC" {
  let crafted = Buffer()
  crafted.write_bytes(b"MMML")
  crafted.write_byte(1)
  crafted.write_byte(1)
  crafted.write_uint16_be(0)
  crafted.write_uint_be(0x919198F0U)
  crafted.write_uint_be(0U)
  crafted.write_uint16_be(0x1234U.to_uint16())
  crafted.write_uint64_be(0UL)
  crafted.write_uint64_be(0UL)
  expect_malformed(crafted.contents()[:])
}

///|
test "mmml record rejects CRC corruption everywhere it covers" {
  let bytes = sample_bytes()
  expect_malformed(flip_byte(bytes, 8)[:])
  expect_malformed(flip_byte(bytes, 12)[:])
  expect_malformed(flip_byte(bytes, 17)[:])
  expect_malformed(flip_byte(bytes, 26)[:])
  expect_malformed(flip_byte(bytes, 31)[:])
  expect_malformed(flip_byte(bytes, 34)[:])
}

///|
test "mmml record rejects truncation and trailing bytes" {
  let bytes = sample_bytes()
  expect_malformed(bytes[:0])
  expect_malformed(bytes[:33])
  expect_malformed(bytes[:35])
  expect_malformed((bytes + b"\x00")[:])
}

///|
test "mmml record rejects foreign magic versions and reserved flags" {
  let bytes = sample_bytes()
  expect_malformed(flip_byte(bytes, 0)[:])
  expect_malformed(flip_byte(bytes, 4)[:])
  expect_malformed(flip_byte(bytes, 5)[:])
  expect_malformed(flip_byte(bytes, 7)[:])
}

///|
test "mmml encoder refuses writer-side contract violations" {
  let bad_version = @metadata.MmmlHeader::new(
    format_version=2,
    header_version=1,
    flags=0,
    record_type=@metadata.MmmlRecordType::TopicCreate,
    leader_epoch=0,
    mutation_id=0,
  )
  assert_eq(@metadata.encode_mmml_record(bad_version, b"") is Err(_), true)
  let bad_header_version = @metadata.MmmlHeader::new(
    format_version=1,
    header_version=2,
    flags=0,
    record_type=@metadata.MmmlRecordType::TopicCreate,
    leader_epoch=0,
    mutation_id=0,
  )
  assert_eq(
    @metadata.encode_mmml_record(bad_header_version, b"") is Err(_),
    true,
  )
  let reserved_flags = @metadata.MmmlHeader::new(
    format_version=1,
    header_version=1,
    flags=0x0004,
    record_type=@metadata.MmmlRecordType::TopicCreate,
    leader_epoch=0,
    mutation_id=0,
  )
  assert_eq(@metadata.encode_mmml_record(reserved_flags, b"") is Err(_), true)
}

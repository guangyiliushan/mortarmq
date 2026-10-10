/// Exercise the frozen v0 MMML metadata-log record boundary.

///|
fn sampleHeader() -> @metadata.MmmlHeader {
  @metadata.MmmlHeader::new(
    formatVersion=1,
    headerVersion=1,
    flags=0,
    recordType=@metadata.MmmlRecordType::TopicCreate,
    leaderEpoch=2,
    mutationId=7,
  )
}

///|
fn encodeOrFail(header : @metadata.MmmlHeader, payload : Bytes) -> Bytes raise {
  match @metadata.encodeMmmlRecord(header, payload[:]) {
    Ok(bytes) => bytes
    Err(_) => fail("record encoding failed")
  }
}

///|
fn sampleBytes() -> Bytes raise {
  encodeOrFail(sampleHeader(), b"ab")
}

///|
fn expectMalformed(data : BytesView) -> Unit raise {
  match @metadata.decodeMmmlRecord(data) {
    Err(@metadata.Malformed) => ()
    _ => fail("expected malformed rejection")
  }
}

///|
fn flipByte(data : Bytes, index : Int) -> Bytes {
  let flipped = (data[index].to_uint() ^ 0xFFU).to_byte()
  let out = Buffer()
  out.write_bytes(data[:index])
  out.write_byte(flipped)
  out.write_bytes(data[index + 1:])
  out.contents()
}

///|
test "mmml record round-trips every frozen header field" {
  let bytes = sampleBytes()
  assert_eq(bytes.length(), @metadata.MMML_HEADER_BYTES + 2)
  match @metadata.decodeMmmlRecord(bytes[:]) {
    Ok(decoded) => {
      assert_eq(decoded.header, sampleHeader())
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
  for recordType in types {
    let header = @metadata.MmmlHeader::new(
      formatVersion=1,
      headerVersion=1,
      flags=0,
      recordType~,
      leaderEpoch=0,
      mutationId=0,
    )
    let bytes = encodeOrFail(header, b"")
    match @metadata.decodeMmmlRecord(bytes[:]) {
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
    formatVersion=1,
    headerVersion=1,
    flags=3,
    recordType=@metadata.MmmlRecordType::TopicDelete,
    leaderEpoch=0x0102030405060708UL,
    mutationId=0x1112131415161718UL,
  )
  let bytes = encodeOrFail(header, b"")
  assert_eq(bytes.length(), @metadata.MMML_HEADER_BYTES)
  match @metadata.decodeMmmlRecord(bytes[:]) {
    Ok(decoded) => assert_eq(decoded.header, header)
    Err(_) => fail("record decoding failed")
  }
}

///|
test "mmml record layout matches the frozen 34-byte contract" {
  let header = @metadata.MmmlHeader::new(
    formatVersion=1,
    headerVersion=1,
    flags=3,
    recordType=@metadata.MmmlRecordType::GroupUpdate,
    leaderEpoch=0x0102030405060708UL,
    mutationId=0x1112131415161718UL,
  )
  let data = encodeOrFail(header, b"xy")
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
    formatVersion=1,
    headerVersion=1,
    flags=0,
    recordType=@metadata.MmmlRecordType::TopicCreate,
    leaderEpoch=0,
    mutationId=1,
  )
  assert_eq(encodeOrFail(header, b"hi"), expected.contents())
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
  expectMalformed(crafted.contents()[:])
}

///|
test "mmml record rejects CRC corruption everywhere it covers" {
  let bytes = sampleBytes()
  expectMalformed(flipByte(bytes, 8)[:])
  expectMalformed(flipByte(bytes, 12)[:])
  expectMalformed(flipByte(bytes, 17)[:])
  expectMalformed(flipByte(bytes, 26)[:])
  expectMalformed(flipByte(bytes, 31)[:])
  expectMalformed(flipByte(bytes, 34)[:])
}

///|
test "mmml record rejects truncation and trailing bytes" {
  let bytes = sampleBytes()
  expectMalformed(bytes[:0])
  expectMalformed(bytes[:33])
  expectMalformed(bytes[:35])
  expectMalformed((bytes + b"\x00")[:])
}

///|
test "mmml record rejects foreign magic versions and reserved flags" {
  let bytes = sampleBytes()
  expectMalformed(flipByte(bytes, 0)[:])
  expectMalformed(flipByte(bytes, 4)[:])
  expectMalformed(flipByte(bytes, 5)[:])
  expectMalformed(flipByte(bytes, 7)[:])
}

///|
test "mmml encoder refuses writer-side contract violations" {
  let badVersion = @metadata.MmmlHeader::new(
    formatVersion=2,
    headerVersion=1,
    flags=0,
    recordType=@metadata.MmmlRecordType::TopicCreate,
    leaderEpoch=0,
    mutationId=0,
  )
  assert_eq(@metadata.encodeMmmlRecord(badVersion, b"") is Err(_), true)
  let badHeaderVersion = @metadata.MmmlHeader::new(
    formatVersion=1,
    headerVersion=2,
    flags=0,
    recordType=@metadata.MmmlRecordType::TopicCreate,
    leaderEpoch=0,
    mutationId=0,
  )
  assert_eq(@metadata.encodeMmmlRecord(badHeaderVersion, b"") is Err(_), true)
  let reservedFlags = @metadata.MmmlHeader::new(
    formatVersion=1,
    headerVersion=1,
    flags=0x0004,
    recordType=@metadata.MmmlRecordType::TopicCreate,
    leaderEpoch=0,
    mutationId=0,
  )
  assert_eq(@metadata.encodeMmmlRecord(reservedFlags, b"") is Err(_), true)
}

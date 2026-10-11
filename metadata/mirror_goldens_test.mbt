/// Mirror the metadata goldens as literal byte vectors, independent of
/// any encoder: literal byte arrays, implementation-neutral, never
/// self-attested by encode.
///
/// Each golden asserts both directions: the literal decodes to the
/// expected record, and the encoder reproduces the literal exactly.
/// The literals were produced once against the frozen v0 layout (CRC32C
/// of "123456789" checked as 0xE3069283) and are the authority now --
/// the encoder is the suspect.

///|
test "mmml golden record mirrors in both directions from literal bytes" {
  let golden : Bytes = b"MMML\x01\x01\x00\x00\x86\x69\x67\xbd\x00\x00\x00\x02\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01hi"
  let header = @metadata.MmmlHeader::new(
    format_version=1,
    header_version=1,
    flags=0,
    record_type=@metadata.MmmlRecordType::TopicCreate,
    leader_epoch=0,
    mutation_id=1,
  )
  match @metadata.encode_mmml_record(header, b"hi") {
    Ok(encoded) => assert_eq(encoded, golden)
    Err(_) => fail("golden encode failed")
  }
  match @metadata.decode_mmml_record(golden[:]) {
    Ok(record) => {
      assert_eq(record.header, header)
      assert_eq(record.payload, b"hi")
    }
    Err(_) => fail("golden decode failed")
  }
}

///|
test "declare payload goldens mirror in both directions from literal bytes" {
  let source = @metadata.DeclareBody::Create("orders", 3)
  let twin = @metadata.DeclareBody::Create("orders.dlq", 3)
  let single_golden : Bytes = b"\x00\x06orders\x00\x00\x00\x03"
  let pair_golden : Bytes = b"\x00\x06orders\x00\x00\x00\x03\x00\x0aorders.dlq\x00\x00\x00\x03"
  assert_eq(source.to_payload(), single_golden)
  assert_eq(@metadata.encode_declare_bodies([source]), single_golden)
  assert_eq(@metadata.encode_declare_bodies([source, twin]), pair_golden)
  assert_eq(
    @metadata.decode_declare_bodies(
      @metadata.MmmlRecordType::TopicCreate,
      single_golden[:],
    ),
    Some([source]),
  )
  assert_eq(
    @metadata.decode_declare_bodies(
      @metadata.MmmlRecordType::TopicCreate,
      pair_golden[:],
    ),
    Some([source, twin]),
  )
}

///|
test "the unregistered-type golden stays refused from literal bytes" {
  let crafted : Bytes = b"MMML\x01\x01\x00\x00\x91\x91\x98\xf0\x00\x00\x00\x00\x12\x34\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"
  assert_eq(@metadata.decode_mmml_record(crafted[:]) is Err(_), true)
}

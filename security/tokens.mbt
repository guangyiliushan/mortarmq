/// The frozen tokens-file format.
///
/// One entry per line: `digest<TAB>role`. `digest` is exactly 64 lowercase
/// hex bytes of the token's SHA-256 (32 raw bytes); `role` is a non-empty
/// run of printable ASCII without spaces. The file stores digests only --
/// the token plaintext never lands on disk.
///
/// Line discipline: a malformed line is treated exactly as if
/// the entry did not exist -- it is skipped without a distinct error -- so a
/// verification failure never distinguishes "no such token" from "corrupt
/// line". Generate lines with `hash-token` / `token_line` so they cannot be
/// malformed in the first place.

///|
/// A tokens-file problem that carries no token or digest material.
pub(all) suberror TokensError {
  /// A digest that is not exactly 32 bytes.
  BadDigest
  /// A role that is empty or contains bytes outside printable ASCII minus space.
  BadRole
} derive(Eq, Debug)

///|
pub extend TokensError with Eq::{not_equal, equal}

///|
pub extend TokensError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One `digest<TAB>role` entry: the SHA-256 digest of a token plus its role.
pub(all) struct TokenEntry {
  digest : Bytes
  role : Bytes
} derive(Eq, Debug)

///|
pub extend TokenEntry with Eq::{not_equal, equal}

///|
pub extend TokenEntry with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The well-formed entries of a tokens file, in file order.
pub(all) struct TokenStore {
  entries : Array[TokenEntry]
} derive(Eq, Debug)

///|
pub extend TokenStore with Eq::{not_equal, equal}

///|
pub extend TokenStore with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Whether `role` is non-empty printable ASCII minus space (0x21..=0x7E).
fn role_ok(role : BytesView) -> Bool {
  if role.length() == 0 {
    return false
  }
  for index in 0..<role.length() {
    let byte = role[index].to_uint()
    if byte < 0x21U || byte > 0x7EU {
      return false
    }
  }
  true
}

///|
/// Decode one lowercase hex nibble; -1 when the byte is not `[0-9a-f]`.
fn hex_value(byte : Byte) -> Int {
  let value = byte.to_uint()
  if value >= 0x30U && value <= 0x39U {
    (value - 0x30U).reinterpret_as_int()
  } else if value >= 0x61U && value <= 0x66U {
    (value - 0x57U).reinterpret_as_int()
  } else {
    -1
  }
}

///|
/// Decode exactly 64 lowercase hex bytes into 32 raw bytes.
fn decode_digest(hex : BytesView) -> Bytes {
  let buf = Buffer()
  for index in 0..<32 {
    let high = hex_value(hex[index * 2])
    let low = hex_value(hex[index * 2 + 1])
    let byte = (((high.reinterpret_as_uint() << 4) | low.reinterpret_as_uint()) &
      0xFFU)
      .reinterpret_as_int()
      .to_byte()
    buf.write_byte(byte)
  }
  buf.contents()
}

///|
/// Format one tokens-file line from a raw 32-byte digest and a role.
pub fn token_line(digest : Bytes, role : Bytes) -> Result[Bytes, TokensError] {
  if digest.length() != 32 {
    return Err(BadDigest)
  }
  if !role_ok(role[:]) {
    return Err(BadRole)
  }
  Ok(digest_hex(digest) + b"\t" + role)
}

///|
/// Parse one `digest<TAB>role` line; `None` means "treat as absent".
fn parse_line(line : BytesView) -> TokenEntry? {
  let length = line.length()
  // 64 hex bytes + TAB + at least one role byte.
  if length < 66 {
    return None
  }
  for index in 0..<64 {
    if hex_value(line[index]) < 0 {
      return None
    }
  }
  if line[64] != b'\t' {
    return None
  }
  let role = line[65:length].to_owned()
  if !role_ok(role[:]) {
    return None
  }
  Some({ digest: decode_digest(line[0:64]), role, })
}

///|
/// Parse a whole tokens-file body. Empty and malformed lines are skipped:
/// only well-formed entries exist in the returned store.
pub fn parse_tokens(text : BytesView) -> TokenStore {
  let entries : Array[TokenEntry] = []
  let length = text.length()
  let mut start = 0
  for index in 0..<(length + 1) {
    let at_end = index == length
    if at_end || text[index] == b'\n' {
      let mut end = index
      if end > start && text[end - 1] == b'\r' {
        end = end - 1
      }
      match parse_line(text[start:end]) {
        Some(entry) => entries.push(entry)
        None => ()
      }
      start = index + 1
    }
  }
  { entries, }
}

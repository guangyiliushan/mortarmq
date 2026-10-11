/// The admin-face bind policy: the admin HTTP endpoints (`/metrics`,
/// `/healthz`, `/stats`) live on the loopback face only.
///
/// Contract: the effective bind is a loopback literal -- 127.0.0.1 by
/// default -- and every non-loopback or unclassifiable value is refused
/// with a distinct error, so the misoperation surface stays minimal and a
/// CLI maps each refusal to its own exit code. The same rule covers the
/// connection side: the admin accept path admits only peers whose
/// address passes `is_loopback`, so a connection whose address is not on
/// the loopback face is rejected before any endpoint runs. Binding only
/// the loopback face is what keeps that rejection true at the socket
/// level: the OS accepts nothing else on that listener.
///
/// Why literals only: name resolution is a transport concern, and a
/// poisoned resolver could point a name anywhere -- the admin face
/// therefore refuses hostnames. The IPv6 loopback literal `::1` is
/// loopback like any 127.x.x.x literal and is admitted.

///|
/// The default admin bind: the IPv4 loopback literal.
pub const ADMIN_DEFAULT_BIND : Bytes = b"127.0.0.1"

///|
/// A refused admin bind or peer address, in two shapes so a CLI maps
/// each refusal to its own exit code.
pub(all) suberror AdminBindError {
  /// The value is not an address literal the policy can classify.
  Malformed
  /// The value is a well-formed address literal that is not loopback.
  NonLoopback
} derive(Eq, Debug)

///|
pub extend AdminBindError with Eq::{not_equal, equal}

///|
pub extend AdminBindError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Parse `host` as a strict dotted quad (four decimal octets); the first
/// octet when it parses, `None` otherwise.
fn parse_v4_first(host : BytesView) -> Int? {
  let length = host.length()
  if length < 7 || length > 15 {
    return None
  }
  let mut part = 0
  let mut value = -1
  let mut digits = 0
  let mut first = -1
  for index in 0..<length {
    let byte = host[index].to_uint()
    if byte >= 0x30U && byte <= 0x39U {
      value = (if value < 0 { 0 } else { value }) * 10 +
        (byte - 0x30U).reinterpret_as_int()
      digits = digits + 1
      if digits > 3 || value > 255 {
        return None
      }
    } else if byte == 0x2EU && digits > 0 {
      // A dot after at least one digit: one octet complete.
      if part == 0 {
        first = value
      }
      part = part + 1
      if part > 3 {
        return None
      }
      value = -1
      digits = 0
    } else {
      return None
    }
  }
  if part != 3 || digits == 0 {
    return None
  }
  Some(first)
}

///|
/// Whether `host` is exactly the canonical IPv6 loopback literal `::1`.
fn is_v6_loopback(host : BytesView) -> Bool {
  host.length() == 3 && host[0] == b':' && host[1] == b':' && host[2] == b'1'
}

///|
/// Whether `host` is shaped like an address literal (a dotted quad or a
/// colon-bearing IPv6 form) as opposed to a hostname or noise.
fn is_address_shaped(host : BytesView) -> Bool {
  if parse_v4_first(host) != None {
    return true
  }
  for index in 0..<host.length() {
    if host[index] == b':' {
      return true
    }
  }
  false
}

///|
/// Whether `host` is a loopback address literal: any 127.x.x.x dotted
/// quad or the canonical IPv6 loopback `::1`. Hostnames are never
/// loopback here -- resolution is not this policy's to trust.
pub fn is_loopback(host : BytesView) -> Bool {
  if is_v6_loopback(host) {
    return true
  }
  match parse_v4_first(host) {
    Some(first) => first == 127
    None => false
  }
}

///|
/// Resolve the admin bind target: the default loopback literal when
/// `listen_admin` is empty, the configured loopback literal when it is
/// one, and a refusal otherwise. A non-loopback literal refuses as
/// `NonLoopback`; anything that is not an address literal refuses as
/// `Malformed`.
pub fn admin_bind(listen_admin : BytesView) -> Result[Bytes, AdminBindError] {
  if listen_admin.length() == 0 {
    return Ok(ADMIN_DEFAULT_BIND)
  }
  if is_loopback(listen_admin) {
    return Ok(listen_admin.to_owned())
  }
  if is_address_shaped(listen_admin) {
    return Err(NonLoopback)
  }
  Err(Malformed)
}

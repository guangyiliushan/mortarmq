/// Sanitize and escape the text surfaces of the `/metrics` exposition.
///
/// Double insurance: label values are sanitized on the write side to
/// the identifier allowlist `[A-Za-z0-9_-]` -- every other character
/// becomes `_` -- so dirty topic and group names cannot carry reserved
/// characters into label semantics; as defense in depth the output side
/// then escapes the characters the Prometheus text format reserves in
/// label values (backslash, double quote, newline). Help text escapes
/// backslash and newline only; double quotes are not reserved in help
/// text and pass through. The type line only ever carries the lowercase
/// kind literals, so it needs no escaping.
///
/// # Stability
///
/// * Sanitizing maps characters many-to-one by design; the allowlist is
///   the documented contract, not a bug.
/// * The output-side escapes are a defensive layer that the write-side
///   allowlist makes unreachable for label values; they stay because a
///   future caller may feed this layer unsanitized text.

///|
/// Sanitize one label value to the identifier allowlist: letters,
/// digits, underscore and hyphen survive, every other character
/// becomes `_`.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@metrics.sanitize_label_value("orders/eu"), "orders_eu")
/// }
/// ```
pub fn sanitize_label_value(value : String) -> String {
  let mut out = ""
  for c in value {
    if is_label_char(c) {
      out = out + c.to_string()
    } else {
      out = out + "_"
    }
  }
  out
}

///|
/// Escape one label value for output: backslash, double quote and
/// newline.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@metrics.escape_label_value("a\"b"), "a\\\"b")
/// }
/// ```
pub fn escape_label_value(value : String) -> String {
  let mut out = ""
  for c in value {
    if c == '\\' {
      out = out + "\\\\"
    } else if c == '"' {
      out = out + "\\\""
    } else if c == '\n' {
      out = out + "\\n"
    } else {
      out = out + c.to_string()
    }
  }
  out
}

///|
/// Escape one help text for output: backslash and newline. Double
/// quotes are not reserved in help text and pass through unchanged.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@metrics.escape_help_text("say \"hi\""), "say \"hi\"")
/// }
/// ```
pub fn escape_help_text(help : String) -> String {
  let mut out = ""
  for c in help {
    if c == '\\' {
      out = out + "\\\\"
    } else if c == '\n' {
      out = out + "\\n"
    } else {
      out = out + c.to_string()
    }
  }
  out
}

///|
/// Whether one character is in the label allowlist.
fn is_label_char(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') ||
  (c >= 'A' && c <= 'Z') ||
  (c >= '0' && c <= '9') ||
  c == '_' ||
  c == '-'
}

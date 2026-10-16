/// Load the static broker configuration from its JSON text.
///
/// The loader owns the frozen 19-key whitelist of the configuration
/// reference: a key outside it fails the load and names the key, a key
/// inside it must carry a value of the frozen type, and a missing key
/// falls back to its frozen default (or fails when the table gives it
/// none). Exact names only -- a case or hyphen variant is a different,
/// unknown name and is refused like any other extra key.
///
/// The file is read once at startup: v0 has no hot reload, and every
/// fault message says the fix requires a restart. Hot reload stays
/// reserved for a later release.

///|
/// One row of the static peer table: a node id and its dial address.
pub(all) struct ConfigPeer {
  node_id : UInt16
  addr : String
} derive(Eq, Debug)

///|
pub extend ConfigPeer with Eq::{not_equal, equal}

///|
pub extend ConfigPeer with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The logging verbosity the broker runs at.
pub(all) enum LogLevel {
  Debug
  Info
  Warn
  Error
} derive(Eq, Debug)

///|
pub extend LogLevel with Eq::{not_equal, equal}

///|
pub extend LogLevel with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The node-to-node shared secret read from the configuration file.
///
/// Held behind its own type so no debug rendering can print it: the
/// bytes leave only through `reveal`, on the wiring path into the peer
/// handshake.
pub struct ConfigSecret {
  priv value : String
} derive(Eq)

///|
pub fn ConfigSecret::wrap(value : String) -> ConfigSecret {
  { value, }
}

///|
/// Read the secret on the peer-handshake wiring path only.
pub fn ConfigSecret::reveal(self : ConfigSecret) -> String {
  self.value
}

///|
/// Report whether the secret is the empty default, under which the peer
/// handshake refuses to open a link.
pub fn ConfigSecret::is_empty(self : ConfigSecret) -> Bool {
  self.value == ""
}

///|
pub extend ConfigSecret with Eq::{not_equal, equal}

///|
/// The validated static configuration.
///
/// No `Debug` rendering: the struct carries the peer secret, and a debug
/// print must never be able to leak it.
pub(all) struct Config {
  node_id : UInt16
  peers : Array[ConfigPeer]
  leader_priority : Array[UInt16]
  listen_client : String
  listen_peer : String
  data_dir : String
  segment_max_bytes : UInt64
  partition_default_count : UInt16
  delivery_max_attempts : UInt32
  delivery_lease_ms : UInt32
  poll_max_wait_ms : UInt32
  credit_initial_count : UInt32
  metadata_snapshot_records : UInt32
  metrics_enabled : Bool
  log_level : LogLevel
  listen_ws : String?
  listen_admin : String
  ws_origins : Array[String]
  peer_secret : ConfigSecret
} derive(Eq)

///|
pub extend Config with Eq::{not_equal, equal}

///|
/// Why the configuration failed to load.
pub(all) suberror ConfigFault {
  /// The file is not a JSON object.
  Malformed
  /// A key outside the frozen whitelist; the load names it.
  UnknownKey(String)
  /// A whitelisted key carries a value of the wrong shape or range.
  BadValue(String)
  /// A key with no default is missing from the file.
  MissingKey(String)
} derive(Eq, Debug)

///|
pub extend ConfigFault with Eq::{not_equal, equal}

///|
pub extend ConfigFault with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The operator-facing text of a load fault.
///
/// Every message ends with the restart note: the file is read once at
/// startup and there is no hot reload.
pub fn ConfigFault::message(self : ConfigFault) -> String {
  let problem = match self {
    Malformed => "configuration is not a JSON object"
    UnknownKey(name) => "unknown key: " + name + " (outside the whitelist)"
    BadValue(key) => "invalid value for key: " + key
    MissingKey(key) => "missing key with no default: " + key
  }
  problem + "; configuration loads once at startup -- fix the file and restart"
}

///|
/// The frozen whitelist: exactly the keys of the configuration reference
/// table, in table order.
pub fn config_key_names() -> Array[String] {
  [
    "node_id", "peers", "leader_priority", "listen_client", "listen_peer", "data_dir",
    "segment_max_bytes", "partition_default_count", "delivery_max_attempts", "delivery_lease_ms",
    "poll_max_wait_ms", "credit_initial_count", "metadata_snapshot_records", "metrics_enabled",
    "log_level", "listen_ws", "listen_admin", "ws_origins", "peer_secret",
  ]
}

///|
/// Report whether a name is one of the frozen configuration keys.
pub fn is_config_key(name : String) -> Bool {
  for key in config_key_names() {
    if key == name {
      return true
    }
  }
  false
}

///|
fn valid_addr(addr : String) -> Bool {
  // "host:port" with a non-empty host and a numeric port in 1..65535.
  let bytes = @utf8.encode(addr)
  let length = bytes.length()
  if length < 3 {
    return false
  }
  let mut colon = -1
  let mut i = 0
  while i < length {
    if bytes[i] == b':' {
      colon = i
    }
    i = i + 1
  }
  if colon <= 0 || colon == length - 1 {
    return false
  }
  let mut port = 0
  let mut j = colon + 1
  while j < length {
    let byte = bytes[j]
    if byte < b'0' || byte > b'9' {
      return false
    }
    port = port * 10 + byte.to_uint().reinterpret_as_int() - 48
    if port > 65535 {
      return false
    }
    j = j + 1
  }
  port >= 1
}

///|
fn expect_string(
  map : Map[String, Json],
  key : String,
) -> Result[String?, ConfigFault] {
  match map.get(key) {
    None => Ok(None)
    Some(json) =>
      match json {
        String(value) => Ok(Some(value))
        _ => Err(BadValue(key))
      }
  }
}

///|
fn expect_addr(
  map : Map[String, Json],
  key : String,
) -> Result[String?, ConfigFault] {
  match expect_string(map, key) {
    Ok(None) => Ok(None)
    Ok(Some(value)) =>
      if valid_addr(value) {
        Ok(Some(value))
      } else {
        Err(BadValue(key))
      }
    Err(fault) => Err(fault)
  }
}

///|
fn integral_in(value : Double, low : Double, high : Double) -> Bool {
  value >= low && value <= high && value == value.floor()
}

///|
fn expect_u16(
  map : Map[String, Json],
  key : String,
) -> Result[UInt16?, ConfigFault] {
  match map.get(key) {
    None => Ok(None)
    Some(json) =>
      match json {
        Number(value, ..) =>
          if integral_in(value, 0.0, 65535.0) {
            Ok(Some(value.to_int().to_uint16()))
          } else {
            Err(BadValue(key))
          }
        _ => Err(BadValue(key))
      }
  }
}

///|
fn expect_u32(
  map : Map[String, Json],
  key : String,
) -> Result[UInt32?, ConfigFault] {
  match map.get(key) {
    None => Ok(None)
    Some(json) =>
      match json {
        Number(value, ..) =>
          if integral_in(value, 0.0, 4294967295.0) {
            Ok(Some(value.to_uint()))
          } else {
            Err(BadValue(key))
          }
        _ => Err(BadValue(key))
      }
  }
}

///|
fn expect_u64(
  map : Map[String, Json],
  key : String,
) -> Result[UInt64?, ConfigFault] {
  match map.get(key) {
    None => Ok(None)
    Some(json) =>
      match json {
        Number(value, ..) =>
          if integral_in(value, 0.0, 18446744073709551615.0) {
            Ok(Some(value.to_uint64()))
          } else {
            Err(BadValue(key))
          }
        _ => Err(BadValue(key))
      }
  }
}

///|
fn expect_bool(
  map : Map[String, Json],
  key : String,
) -> Result[Bool?, ConfigFault] {
  match map.get(key) {
    None => Ok(None)
    Some(json) =>
      match json {
        True => Ok(Some(true))
        False => Ok(Some(false))
        _ => Err(BadValue(key))
      }
  }
}

///|
fn expect_string_array(
  map : Map[String, Json],
  key : String,
) -> Result[Array[String]?, ConfigFault] {
  match map.get(key) {
    None => Ok(None)
    Some(json) =>
      match json {
        Array(items) => {
          let values : Array[String] = []
          for item in items {
            match item {
              String(value) => values.push(value)
              _ => return Err(BadValue(key))
            }
          }
          Ok(Some(values))
        }
        _ => Err(BadValue(key))
      }
  }
}

///|
fn expect_u16_array(
  map : Map[String, Json],
  key : String,
) -> Result[Array[UInt16]?, ConfigFault] {
  match map.get(key) {
    None => Ok(None)
    Some(json) =>
      match json {
        Array(items) => {
          let values : Array[UInt16] = []
          for item in items {
            match item {
              Number(value, ..) =>
                if integral_in(value, 0.0, 65535.0) {
                  values.push(value.to_int().to_uint16())
                } else {
                  return Err(BadValue(key))
                }
              _ => return Err(BadValue(key))
            }
          }
          Ok(Some(values))
        }
        _ => Err(BadValue(key))
      }
  }
}

///|
fn parse_peer_entry(
  item : Json,
  key : String,
) -> Result[ConfigPeer, ConfigFault] {
  match item {
    Array(parts) =>
      if parts.length() == 2 {
        match parts[0] {
          Number(id_value, ..) =>
            if integral_in(id_value, 0.0, 65535.0) {
              match parts[1] {
                String(addr) =>
                  if valid_addr(addr) {
                    Ok({ node_id: id_value.to_int().to_uint16(), addr, })
                  } else {
                    Err(BadValue(key))
                  }
                _ => Err(BadValue(key))
              }
            } else {
              Err(BadValue(key))
            }
          _ => Err(BadValue(key))
        }
      } else {
        Err(BadValue(key))
      }
    _ => Err(BadValue(key))
  }
}

///|
fn expect_peers(
  map : Map[String, Json],
  key : String,
) -> Result[Array[ConfigPeer]?, ConfigFault] {
  match map.get(key) {
    None => Ok(None)
    Some(json) =>
      match json {
        Array(items) => {
          let peers : Array[ConfigPeer] = []
          for item in items {
            match parse_peer_entry(item, key) {
              Ok(peer) => peers.push(peer)
              Err(fault) => return Err(fault)
            }
          }
          Ok(Some(peers))
        }
        _ => Err(BadValue(key))
      }
  }
}

///|
fn parse_log_level(json : Json, key : String) -> Result[LogLevel, ConfigFault] {
  match json {
    String(value) =>
      match value {
        "debug" => Ok(Debug)
        "info" => Ok(Info)
        "warn" => Ok(Warn)
        "error" => Ok(Error)
        _ => Err(BadValue(key))
      }
    _ => Err(BadValue(key))
  }
}

///|
/// Load and validate the static configuration from its JSON text.
///
/// Returns the validated configuration, or the fault that names what the
/// file got wrong: an unknown key (outside the frozen whitelist), a value
/// of the wrong shape or range, a missing key that has no default, or a
/// file that is not a JSON object at all.
pub fn load_config(text : String) -> Result[Config, ConfigFault] {
  let parsed = @json.parse(text) catch { _ => return Err(Malformed) }
  let map = match parsed {
    Object(map) => map
    _ => return Err(Malformed)
  }
  for key, _value in map {
    if is_config_key(key) == false {
      return Err(UnknownKey(key))
    }
  }
  let node_id = match expect_u16(map, "node_id") {
    Ok(Some(value)) => value
    Ok(None) => return Err(MissingKey("node_id"))
    Err(fault) => return Err(fault)
  }
  let peers = match expect_peers(map, "peers") {
    Ok(Some(value)) => value
    Ok(None) => return Err(MissingKey("peers"))
    Err(fault) => return Err(fault)
  }
  let leader_priority = match expect_u16_array(map, "leader_priority") {
    Ok(Some(value)) => value
    Ok(None) => {
      let derived : Array[UInt16] = []
      for peer in peers {
        derived.push(peer.node_id)
      }
      derived
    }
    Err(fault) => return Err(fault)
  }
  let listen_client = match expect_addr(map, "listen_client") {
    Ok(Some(value)) => value
    Ok(None) => "0.0.0.0:7188"
    Err(fault) => return Err(fault)
  }
  let listen_peer = match expect_addr(map, "listen_peer") {
    Ok(Some(value)) => value
    Ok(None) => "0.0.0.0:7189"
    Err(fault) => return Err(fault)
  }
  let data_dir = match expect_string(map, "data_dir") {
    Ok(Some(value)) =>
      if value == "" {
        return Err(BadValue("data_dir"))
      } else {
        value
      }
    Ok(None) => "./data"
    Err(fault) => return Err(fault)
  }
  let segment_max_bytes = match expect_u64(map, "segment_max_bytes") {
    Ok(Some(value)) => value
    Ok(None) => 67108864UL
    Err(fault) => return Err(fault)
  }
  let partition_default_count = match
    expect_u16(map, "partition_default_count") {
    Ok(Some(value)) => value
    Ok(None) => 4
    Err(fault) => return Err(fault)
  }
  let delivery_max_attempts = match expect_u32(map, "delivery_max_attempts") {
    Ok(Some(value)) => value
    Ok(None) => 5U
    Err(fault) => return Err(fault)
  }
  let delivery_lease_ms = match expect_u32(map, "delivery_lease_ms") {
    Ok(Some(value)) => value
    Ok(None) => 30000U
    Err(fault) => return Err(fault)
  }
  let poll_max_wait_ms = match expect_u32(map, "poll_max_wait_ms") {
    Ok(Some(value)) => value
    Ok(None) => 5000U
    Err(fault) => return Err(fault)
  }
  let credit_initial_count = match expect_u32(map, "credit_initial_count") {
    Ok(Some(value)) => value
    Ok(None) => 256U
    Err(fault) => return Err(fault)
  }
  let metadata_snapshot_records = match
    expect_u32(map, "metadata_snapshot_records") {
    Ok(Some(value)) => value
    Ok(None) => 8192U
    Err(fault) => return Err(fault)
  }
  let metrics_enabled = match expect_bool(map, "metrics_enabled") {
    Ok(Some(value)) => value
    Ok(None) => true
    Err(fault) => return Err(fault)
  }
  let log_level = match map.get("log_level") {
    Some(json) =>
      match parse_log_level(json, "log_level") {
        Ok(value) => value
        Err(fault) => return Err(fault)
      }
    None => Info
  }
  let listen_ws = match expect_addr(map, "listen_ws") {
    Ok(value) => value
    Err(fault) => return Err(fault)
  }
  let listen_admin = match expect_addr(map, "listen_admin") {
    Ok(Some(value)) => value
    Ok(None) => "127.0.0.1:7190"
    Err(fault) => return Err(fault)
  }
  let ws_origins = match expect_string_array(map, "ws_origins") {
    Ok(Some(value)) => value
    Ok(None) => ["localhost", "127.0.0.1"]
    Err(fault) => return Err(fault)
  }
  let peer_secret = match expect_string(map, "peer_secret") {
    Ok(Some(value)) => ConfigSecret::wrap(value)
    Ok(None) => ConfigSecret::wrap("")
    Err(fault) => return Err(fault)
  }
  Ok({
    node_id,
    peers,
    leader_priority,
    listen_client,
    listen_peer,
    data_dir,
    segment_max_bytes,
    partition_default_count,
    delivery_max_attempts,
    delivery_lease_ms,
    poll_max_wait_ms,
    credit_initial_count,
    metadata_snapshot_records,
    metrics_enabled,
    log_level,
    listen_ws,
    listen_admin,
    ws_origins,
    peer_secret,
  })
}

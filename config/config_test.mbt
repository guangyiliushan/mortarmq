/// Exercise the static configuration loader: the frozen nineteen-key
/// whitelist, exact-match acceptance, extra-key refusal, frozen defaults,
/// and type validation. Every secret-shaped value in these tests is a
/// fake placeholder by design.

///|
fn peers_fragment() -> String {
  "[[1, \"0.0.0.0:7188\"], [2, \"0.0.0.0:7189\"], [3, \"0.0.0.0:7190\"]]"
}

///|
fn base_json() -> String {
  "{\"node_id\": 1, \"peers\": " + peers_fragment() + "}"
}

///|
fn load_ok(text : String) -> @config.Config raise {
  match @config.load_config(text) {
    Ok(config) => config
    Err(_) => fail("load failed")
  }
}

///|
fn load_fault(text : String) -> @config.ConfigFault raise {
  match @config.load_config(text) {
    Ok(_) => fail("load unexpectedly succeeded")
    Err(fault) => fault
  }
}

///|
test "the whitelist names exactly the nineteen frozen keys" {
  let keys = @config.config_key_names()
  assert_eq(keys.length(), 19)
  for key in keys {
    assert_eq(@config.is_config_key(key), true)
  }
  assert_eq(@config.is_config_key("listen_https"), false)
  assert_eq(@config.is_config_key(""), false)
}

///|
test "every whitelisted key loads one at a time" {
  let keys = @config.config_key_names()
  let values : Array[String] = [
    "1", "[[1, \"0.0.0.0:7188\"], [2, \"0.0.0.0:7189\"], [3, \"0.0.0.0:7190\"]]",
    "[3, 2, 1]", "\"0.0.0.0:7188\"", "\"0.0.0.0:7189\"", "\"./data\"", "67108864",
    "4", "5", "30000", "5000", "256", "8192", "true", "\"debug\"", "\"127.0.0.1:7191\"",
    "\"127.0.0.1:7190\"", "[\"localhost\", \"127.0.0.1\"]", "\"test-only-fake-secret-not-real\"",
  ]
  assert_eq(values.length(), 19)
  let mut i = 0
  while i < keys.length() {
    let key = keys[i]
    let value = values[i]
    let text = if key == "node_id" {
      "{\"node_id\": " + value + ", \"peers\": " + peers_fragment() + "}"
    } else if key == "peers" {
      "{\"node_id\": 1, \"peers\": " + value + "}"
    } else {
      "{\"node_id\": 1, \"peers\": " +
      peers_fragment() +
      ", \"" +
      key +
      "\": " +
      value +
      "}"
    }
    if @config.load_config(text) is Err(_) {
      fail("whitelisted key did not load")
    }
    i = i + 1
  }
}

///|
test "an extra key outside the whitelist fails the load naming it" {
  let text = "{\"node_id\": 1, \"peers\": " +
    peers_fragment() +
    ", \"listen_https\": \"x\"}"
  let fault = load_fault(text)
  assert_eq(fault, @config.UnknownKey("listen_https"))
  assert_eq(fault.message().contains("unknown key: listen_https"), true)
  assert_eq(fault.message().contains("restart"), true)
}

///|
test "case and hyphen variants of whitelisted names are refused" {
  let variants : Array[String] = [
    "Listen_Client", "listen-client", "LISTEN_WS", "peer-secret", "node id",
  ]
  for name in variants {
    let text = "{\"node_id\": 1, \"peers\": " +
      peers_fragment() +
      ", \"" +
      name +
      "\": 1}"
    let fault = load_fault(text)
    assert_eq(fault, @config.UnknownKey(name))
  }
}

///|
test "frozen defaults fill every omitted key" {
  let config = load_ok(base_json())
  assert_eq(config.node_id, 1)
  assert_eq(config.listen_client, "0.0.0.0:7188")
  assert_eq(config.listen_peer, "0.0.0.0:7189")
  assert_eq(config.data_dir, "./data")
  assert_eq(config.segment_max_bytes, 67108864UL)
  assert_eq(config.partition_default_count, 4)
  assert_eq(config.delivery_max_attempts, 5U)
  assert_eq(config.delivery_lease_ms, 30000U)
  assert_eq(config.poll_max_wait_ms, 5000U)
  assert_eq(config.credit_initial_count, 256U)
  assert_eq(config.metadata_snapshot_records, 8192U)
  assert_eq(config.metrics_enabled, true)
  assert_eq(config.log_level, @config.Info)
  assert_eq(config.listen_ws, None)
  assert_eq(config.listen_admin, "127.0.0.1:7190")
  assert_eq(config.ws_origins, ["localhost", "127.0.0.1"])
  assert_eq(config.peer_secret.is_empty(), true)
  // The leader priority defaults to the peers order.
  assert_eq(config.leader_priority, [1, 2, 3])
  assert_eq(config.peers.length(), 3)
  assert_eq(config.peers[0].node_id, 1)
  assert_eq(config.peers[0].addr, "0.0.0.0:7188")
}

///|
test "keys with no default must be present" {
  assert_eq(load_fault("{}"), @config.MissingKey("node_id"))
  let only_node = "{\"node_id\": 1}"
  assert_eq(load_fault(only_node), @config.MissingKey("peers"))
}

///|
test "type and range violations fail naming the key" {
  let bad : Array[String] = [
    "{\"node_id\": 70000, \"peers\": " + peers_fragment() + "}",
    "{\"node_id\": 1.5, \"peers\": " + peers_fragment() + "}",
    "{\"node_id\": 1, \"peers\": " +
    peers_fragment() +
    ", \"metrics_enabled\": 1}",
    "{\"node_id\": 1, \"peers\": " +
    peers_fragment() +
    ", \"segment_max_bytes\": \"big\"}",
    "{\"node_id\": 1, \"peers\": " +
    peers_fragment() +
    ", \"log_level\": \"trace\"}",
    "{\"node_id\": 1, \"peers\": " +
    peers_fragment() +
    ", \"listen_client\": \"nope\"}",
    "{\"node_id\": 1, \"peers\": " +
    peers_fragment() +
    ", \"ws_origins\": [\"ok\", 5]}",
    "{\"node_id\": 1, \"peers\": [[1, \"x\"]]}",
    "{\"node_id\": 1, \"peers\": " +
    peers_fragment() +
    ", \"leader_priority\": [1, \"a\"]}",
    "{\"node_id\": 1, \"peers\": " + peers_fragment() + ", \"data_dir\": \"\"}",
  ]
  let keys : Array[String] = [
    "node_id", "node_id", "metrics_enabled", "segment_max_bytes", "log_level", "listen_client",
    "ws_origins", "peers", "leader_priority", "data_dir",
  ]
  assert_eq(bad.length(), keys.length())
  let mut i = 0
  while i < bad.length() {
    assert_eq(load_fault(bad[i]), @config.BadValue(keys[i]))
    i = i + 1
  }
}

///|
test "a file that is not a JSON object fails closed" {
  assert_eq(load_fault("[]"), @config.Malformed)
  assert_eq(load_fault("42"), @config.Malformed)
  assert_eq(load_fault("{oops"), @config.Malformed)
}

///|
test "every fault message points at a restart" {
  let faults : Array[@config.ConfigFault] = [
    @config.Malformed,
    @config.UnknownKey("listen_https"),
    @config.BadValue("node_id"),
    @config.MissingKey("peers"),
  ]
  for fault in faults {
    assert_eq(fault.message().contains("restart"), true)
  }
}

///|
test "the peer secret stays behind its wrapper" {
  let text = "{\"node_id\": 1, \"peers\": " +
    peers_fragment() +
    ", \"peer_secret\": \"test-only-fake-secret-not-real\"}"
  let config = load_ok(text)
  assert_eq(config.peer_secret.reveal(), "test-only-fake-secret-not-real")
  assert_eq(config.peer_secret.is_empty(), false)
  assert_eq(
    @config.ConfigSecret::wrap("a") == @config.ConfigSecret::wrap("a"),
    true,
  )
}

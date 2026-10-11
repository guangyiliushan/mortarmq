/// Lock the CLI output contract: seven commands, their frozen TSV column
/// orders, the pinned api version, and the four exit codes. Every
/// expectation here is a hand-written literal taken from the CLI
/// reference table -- never a value derived from the renderer -- so a
/// column-order change turns these goldens red until the new order is
/// written down and the api version is bumped.

///|
fn base_config() -> @config.Config raise {
  let result = @config.load_config(
    "{\"node_id\": 1, \"peers\": [[1, \"0.0.0.0:7188\"]]}",
  )
  match result {
    Ok(config) => config
    Err(_) => fail("base config failed to load")
  }
}

///|
test "topics create freezes its two-column order" {
  // result word, then topic_id.
  assert_eq(@cli.topic_create_row(@cli.Created, 5), "created\t5\n")
  assert_eq(@cli.topic_create_row(@cli.Existed, 0), "existed\t0\n")
  assert_eq(@cli.topic_create_row(@cli.Mismatch, 7), "mismatch\t7\n")
}

///|
test "topics delete freezes its single-column order" {
  assert_eq(@cli.topic_delete_row(@cli.Deleted), "deleted\n")
  assert_eq(@cli.topic_delete_row(@cli.NotFound), "not_found\n")
}

///|
test "topics list freezes its four-column order" {
  // name, partitions, state, created_epoch.
  let rows : Array[@cli.TopicListRow] = [
    { name: "orders", partitions: 4, state: "active", created_epoch: 7UL, },
    { name: "billing", partitions: 2, state: "active", created_epoch: 9UL, },
  ]
  assert_eq(
    @cli.topic_list_rows(rows),
    "orders\t4\tactive\t7\nbilling\t2\tactive\t9\n",
  )
}

///|
test "groups list freezes its four-column order" {
  // group, topic, lag, state.
  let rows : Array[@cli.GroupListRow] = [
    { group: "billing", topic: "orders", lag: 12UL, state: "stable", },
  ]
  assert_eq(@cli.group_list_rows(rows), "billing\torders\t12\tstable\n")
}

///|
test "groups describe freezes its four-column order" {
  // member_id, assignment_epoch, ownership_epoch, lag.
  let rows : Array[@cli.GroupDescribeRow] = [
    { member_id: 17UL, assignment_epoch: 3UL, ownership_epoch: 5UL, lag: 9UL, },
  ]
  assert_eq(@cli.group_describe_rows(rows), "17\t3\t5\t9\n")
}

///|
test "leader get freezes its three-column order" {
  // leader_id, leader_epoch, quorum_state.
  let row : @cli.LeaderRow = {
    leader_id: 2,
    leader_epoch: 41UL,
    quorum_state: "healthy",
  }
  assert_eq(@cli.leader_row(row), "2\t41\thealthy\n")
}

///|
test "broker status freezes its four-column order" {
  // node_id, uptime_s, connections, version.
  let row : @cli.BrokerStatusRow = {
    node_id: 3,
    uptime_s: 86400UL,
    connections: 12UL,
    version: "0.1.0",
  }
  assert_eq(@cli.broker_status_row(row), "3\t86400\t12\t0.1.0\n")
}

///|
test "the api version and exit codes are pinned" {
  assert_eq(@cli.API_VERSION, 1)
  assert_eq(@cli.EXIT_OK, 0)
  assert_eq(@cli.EXIT_USAGE, 2)
  assert_eq(@cli.EXIT_UNREACHABLE, 3)
  assert_eq(@cli.EXIT_REFUSED, 4)
}

///|
test "create and delete outcomes map to the frozen exit codes" {
  // The idempotent replay of topics create succeeds like a fresh create.
  assert_eq(@cli.topic_create_exit_code(@cli.Created), 0)
  assert_eq(@cli.topic_create_exit_code(@cli.Existed), 0)
  assert_eq(@cli.topic_create_exit_code(@cli.Mismatch), 4)
  assert_eq(@cli.topic_delete_exit_code(@cli.Deleted), 0)
  assert_eq(@cli.topic_delete_exit_code(@cli.NotFound), 4)
}

///|
test "an omitted --partitions falls back to the loaded configuration" {
  let config = base_config()
  assert_eq(@cli.resolve_partitions(None, config), 4)
  assert_eq(@cli.resolve_partitions(Some(8), config), 8)
}

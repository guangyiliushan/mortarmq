/// Golden baselines for the CLI help texts and for the exit code, stdout,
/// and stderr of every invocation class. Each expectation is a
/// hand-written literal from the CLI reference and the output contract --
/// never a value derived from the implementation -- so a change to the
/// contract surface turns these goldens red.

///|
test "topics create help is frozen" {
  assert_eq(
    @cli.help_text(@cli.TopicsCreate),
    "usage: mortarmq topics create <name> [--partitions N]\n" +
    "Create a topic; replaying an existing topic is idempotent.\n" +
    "options:\n" +
    "  --partitions N  partition count (default: from configuration)\n" +
    "output (TSV): result topic_id\n" +
    "  result is one of: created existed mismatch\n" +
    "exit codes: 0 created or existed, 4 mismatch\n",
  )
}

///|
test "topics delete help is frozen" {
  assert_eq(
    @cli.help_text(@cli.TopicsDelete),
    "usage: mortarmq topics delete <name>\n" +
    "Delete a topic by tombstone.\n" +
    "output (TSV): result\n" +
    "  result is one of: deleted not_found\n" +
    "exit codes: 0 deleted, 4 not_found\n",
  )
}

///|
test "topics list help is frozen" {
  assert_eq(
    @cli.help_text(@cli.TopicsList),
    "usage: mortarmq topics list\n" +
    "List every topic.\n" +
    "output (TSV): name partitions state created_epoch\n" +
    "exit codes: 0 ok, 3 service unreachable\n",
  )
}

///|
test "groups list help is frozen" {
  assert_eq(
    @cli.help_text(@cli.GroupsList),
    "usage: mortarmq groups list [--topic T]\n" +
    "List consumer groups, optionally filtered by topic.\n" +
    "options:\n" +
    "  --topic T  only groups consuming T\n" +
    "output (TSV): group topic lag state\n" +
    "exit codes: 0 ok, 3 service unreachable\n",
  )
}

///|
test "groups describe help is frozen" {
  assert_eq(
    @cli.help_text(@cli.GroupsDescribe),
    "usage: mortarmq groups describe <group>\n" +
    "Show the members, assignment and ownership epochs, and lag of one group.\n" +
    "output (TSV): member assignment_epoch ownership_epoch lag\n" +
    "exit codes: 0 ok, 3 service unreachable, 4 refused\n",
  )
}

///|
test "leader get help is frozen" {
  assert_eq(
    @cli.help_text(@cli.LeaderGet),
    "usage: mortarmq leader get\n" +
    "Show the current leader and quorum state.\n" +
    "output (TSV): leader_id leader_epoch quorum_state\n" +
    "exit codes: 0 ok, 3 service unreachable\n",
  )
}

///|
test "broker status help is frozen" {
  assert_eq(
    @cli.help_text(@cli.BrokerStatus),
    "usage: mortarmq broker status\n" +
    "Show node id, uptime, connections and version.\n" +
    "output (TSV): node_id uptime_s connections version\n" +
    "exit codes: 0 ok, 3 service unreachable\n",
  )
}

///|
test "the idempotent replay outcome is exit zero with its row" {
  assert_eq(@cli.topic_create_outcome(@cli.Existed, 3), {
    exit_code: 0,
    stdout: "existed\t3\n",
    stderr: "",
  })
  assert_eq(@cli.topic_create_outcome(@cli.Created, 3), {
    exit_code: 0,
    stdout: "created\t3\n",
    stderr: "",
  })
}

///|
test "refusals keep their result row on stdout and explain on stderr" {
  assert_eq(@cli.topic_create_outcome(@cli.Mismatch, 7), {
    exit_code: 4,
    stdout: "mismatch\t7\n",
    stderr: "topic exists with different attributes\n",
  })
  assert_eq(@cli.topic_delete_outcome(@cli.NotFound), {
    exit_code: 4,
    stdout: "not_found\n",
    stderr: "topic not found\n",
  })
}

///|
test "successful reads put every row on stdout and nothing on stderr" {
  let rows : Array[@cli.TopicListRow] = [
    { name: "orders", partitions: 4, state: "active", created_epoch: 7UL, },
  ]
  assert_eq(@cli.topic_list_outcome(rows), {
    exit_code: 0,
    stdout: "orders\t4\tactive\t7\n",
    stderr: "",
  })
  let leader : @cli.LeaderRow = {
    leader_id: 2,
    leader_epoch: 41UL,
    quorum_state: "healthy",
  }
  assert_eq(@cli.leader_outcome(leader), {
    exit_code: 0,
    stdout: "2\t41\thealthy\n",
    stderr: "",
  })
}

///|
test "usage errors and unreachable services write nothing to stdout" {
  assert_eq(@cli.usage_outcome("unknown command: frobnicate"), {
    exit_code: 2,
    stdout: "",
    stderr: "unknown command: frobnicate\n",
  })
  assert_eq(@cli.unreachable_outcome("admin"), {
    exit_code: 3,
    stdout: "",
    stderr: "service unreachable: admin\n",
  })
}

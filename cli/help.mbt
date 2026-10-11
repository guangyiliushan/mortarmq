/// The help surface of the seven CLI commands.
///
/// Each help text is a frozen literal: usage synopsis, purpose, options,
/// the TSV column order the renderer uses, and the exit codes the command
/// can return. The golden baselines pin the literals, so a change to the
/// output contract must change the help text in the same commit.

///|
/// One of the seven commands of the CLI.
pub(all) enum Command {
  TopicsCreate
  TopicsDelete
  TopicsList
  GroupsList
  GroupsDescribe
  LeaderGet
  BrokerStatus
} derive(Eq, Debug)

///|
pub extend Command with Eq::{not_equal, equal}

///|
pub extend Command with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The frozen help text of one command, as `-h` prints it.
pub fn help_text(command : Command) -> String {
  match command {
    TopicsCreate =>
      "usage: mortarmq topics create <name> [--partitions N]\n" +
      "Create a topic; replaying an existing topic is idempotent.\n" +
      "options:\n" +
      "  --partitions N  partition count (default: from configuration)\n" +
      "output (TSV): result topic_id\n" +
      "  result is one of: created existed mismatch\n" +
      "exit codes: 0 created or existed, 4 mismatch\n"
    TopicsDelete =>
      "usage: mortarmq topics delete <name>\n" +
      "Delete a topic by tombstone.\n" +
      "output (TSV): result\n" +
      "  result is one of: deleted not_found\n" +
      "exit codes: 0 deleted, 4 not_found\n"
    TopicsList =>
      "usage: mortarmq topics list\n" +
      "List every topic.\n" +
      "output (TSV): name partitions state created_epoch\n" +
      "exit codes: 0 ok, 3 service unreachable\n"
    GroupsList =>
      "usage: mortarmq groups list [--topic T]\n" +
      "List consumer groups, optionally filtered by topic.\n" +
      "options:\n" +
      "  --topic T  only groups consuming T\n" +
      "output (TSV): group topic lag state\n" +
      "exit codes: 0 ok, 3 service unreachable\n"
    GroupsDescribe =>
      "usage: mortarmq groups describe <group>\n" +
      "Show the members, assignment and ownership epochs, and lag of one group.\n" +
      "output (TSV): member assignment_epoch ownership_epoch lag\n" +
      "exit codes: 0 ok, 3 service unreachable, 4 refused\n"
    LeaderGet =>
      "usage: mortarmq leader get\n" +
      "Show the current leader and quorum state.\n" +
      "output (TSV): leader_id leader_epoch quorum_state\n" +
      "exit codes: 0 ok, 3 service unreachable\n"
    BrokerStatus =>
      "usage: mortarmq broker status\n" +
      "Show node id, uptime, connections and version.\n" +
      "output (TSV): node_id uptime_s connections version\n" +
      "exit codes: 0 ok, 3 service unreachable\n"
  }
}

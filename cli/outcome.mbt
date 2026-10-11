/// Everything one command invocation produces: the exit code, the TSV on
/// stdout, and the human text on stderr.
///
/// Scripts branch on the exit code and parse stdout by position; people
/// read stderr. The two views always agree, and every refusal keeps its
/// result row on stdout (the column contract includes the result words)
/// while the explanation goes to stderr.

///|
/// The complete result of one CLI invocation.
pub(all) struct CliOutcome {
  exit_code : Int
  stdout : String
  stderr : String
} derive(Eq, Debug)

///|
pub extend CliOutcome with Eq::{not_equal, equal}

///|
pub extend CliOutcome with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// A successful `topics create`: the result row on stdout.
pub fn topic_create_outcome(
  result : TopicCreateResult,
  topic_id : UInt16,
) -> CliOutcome {
  let stderr = match result {
    Created => ""
    Existed => ""
    Mismatch => "topic exists with different attributes\n"
  }
  {
    exit_code: topic_create_exit_code(result),
    stdout: topic_create_row(result, topic_id),
    stderr,
  }
}

///|
/// A `topics delete` run: a missing topic keeps its row on stdout and
/// explains the refusal on stderr.
pub fn topic_delete_outcome(result : TopicDeleteResult) -> CliOutcome {
  let stderr = match result {
    Deleted => ""
    NotFound => "topic not found\n"
  }
  {
    exit_code: topic_delete_exit_code(result),
    stdout: topic_delete_row(result),
    stderr,
  }
}

///|
/// A `topics list` run: every row on stdout.
pub fn topic_list_outcome(rows : Array[TopicListRow]) -> CliOutcome {
  { exit_code: EXIT_OK, stdout: topic_list_rows(rows), stderr: "", }
}

///|
/// A `groups list` run: every row on stdout.
pub fn group_list_outcome(rows : Array[GroupListRow]) -> CliOutcome {
  { exit_code: EXIT_OK, stdout: group_list_rows(rows), stderr: "", }
}

///|
/// A `groups describe` run: every row on stdout.
pub fn group_describe_outcome(rows : Array[GroupDescribeRow]) -> CliOutcome {
  { exit_code: EXIT_OK, stdout: group_describe_rows(rows), stderr: "", }
}

///|
/// A `leader get` run: the row on stdout.
pub fn leader_outcome(row : LeaderRow) -> CliOutcome {
  { exit_code: EXIT_OK, stdout: leader_row(row), stderr: "", }
}

///|
/// A `broker status` run: the row on stdout.
pub fn broker_status_outcome(row : BrokerStatusRow) -> CliOutcome {
  { exit_code: EXIT_OK, stdout: broker_status_row(row), stderr: "", }
}

///|
/// A wrong invocation: nothing on stdout, the usage text on stderr.
pub fn usage_outcome(message : String) -> CliOutcome {
  { exit_code: EXIT_USAGE, stdout: "", stderr: message + "\n", }
}

///|
/// An unreachable service: nothing on stdout, the target named on
/// stderr.
pub fn unreachable_outcome(target : String) -> CliOutcome {
  {
    exit_code: EXIT_UNREACHABLE,
    stdout: "",
    stderr: "service unreachable: " + target + "\n",
  }
}

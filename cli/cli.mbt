/// The command-line output contract: seven commands, frozen TSV column
/// orders, stable exit codes.
///
/// Every TSV row is tab-separated and newline-terminated, with columns in
/// exactly the order the CLI reference freezes. Scripts parse by position,
/// so a column-order change is a breaking change: it bumps `API_VERSION`,
/// and the golden baselines in the test suite turn red until the new order
/// is written down there too. The write commands (`topics create`,
/// `topics delete`) carry a result word in their first column; the read
/// commands carry data columns only, no header row.

///|
/// The output contract version of every TSV row this package renders.
///
/// Pinned together with the column orders: any change to a column order
/// bumps this number in the same commit that updates the golden baselines.
pub const API_VERSION : Int = 1

///|
/// The command succeeded.
pub const EXIT_OK : Int = 0

///|
/// The invocation is wrong: unknown command, bad arguments.
pub const EXIT_USAGE : Int = 2

///|
/// The broker or admin endpoint could not be reached.
pub const EXIT_UNREACHABLE : Int = 3

///|
/// The server refused the request; the error text says why.
pub const EXIT_REFUSED : Int = 4

///|
/// What `topics create` reports about the topic.
pub(all) enum TopicCreateResult {
  /// The topic did not exist and now does.
  Created
  /// The topic already existed; the replay is idempotent.
  Existed
  /// The topic exists with different attributes.
  Mismatch
} derive(Eq, Debug)

///|
pub extend TopicCreateResult with Eq::{not_equal, equal}

///|
pub extend TopicCreateResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// What `topics delete` reports about the topic.
pub(all) enum TopicDeleteResult {
  /// The tombstone was recorded.
  Deleted
  /// The topic was not there to delete.
  NotFound
} derive(Eq, Debug)

///|
pub extend TopicDeleteResult with Eq::{not_equal, equal}

///|
pub extend TopicDeleteResult with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One row of `topics list`.
pub(all) struct TopicListRow {
  name : String
  partitions : UInt16
  state : String
  created_epoch : UInt64
} derive(Eq, Debug)

///|
pub extend TopicListRow with Eq::{not_equal, equal}

///|
pub extend TopicListRow with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One row of `groups list`.
pub(all) struct GroupListRow {
  group : String
  topic : String
  lag : UInt64
  state : String
} derive(Eq, Debug)

///|
pub extend GroupListRow with Eq::{not_equal, equal}

///|
pub extend GroupListRow with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One row of `groups describe`.
pub(all) struct GroupDescribeRow {
  member_id : UInt64
  assignment_epoch : UInt64
  ownership_epoch : UInt64
  lag : UInt64
} derive(Eq, Debug)

///|
pub extend GroupDescribeRow with Eq::{not_equal, equal}

///|
pub extend GroupDescribeRow with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The single row of `leader get`.
pub(all) struct LeaderRow {
  leader_id : UInt16
  leader_epoch : UInt64
  quorum_state : String
} derive(Eq, Debug)

///|
pub extend LeaderRow with Eq::{not_equal, equal}

///|
pub extend LeaderRow with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// The single row of `broker status`.
pub(all) struct BrokerStatusRow {
  node_id : UInt16
  uptime_s : UInt64
  connections : UInt64
  version : String
} derive(Eq, Debug)

///|
pub extend BrokerStatusRow with Eq::{not_equal, equal}

///|
pub extend BrokerStatusRow with @moonbitlang/core/debug.Debug::{to_repr}

///|
fn tsv_line(fields : Array[String]) -> String {
  let mut line = ""
  let mut first = true
  for field in fields {
    if first {
      first = false
    } else {
      line = line + "\t"
    }
    line = line + field
  }
  line + "\n"
}

///|
/// The exit code a create outcome maps to: created and the idempotent
/// replay both succeed, an attribute mismatch is a refused request.
pub fn topic_create_exit_code(result : TopicCreateResult) -> Int {
  match result {
    Created => EXIT_OK
    Existed => EXIT_OK
    Mismatch => EXIT_REFUSED
  }
}

///|
/// The exit code a delete outcome maps to: a recorded tombstone succeeds,
/// a missing topic is the server-side refusal.
pub fn topic_delete_exit_code(result : TopicDeleteResult) -> Int {
  match result {
    Deleted => EXIT_OK
    NotFound => EXIT_REFUSED
  }
}

///|
/// Render `topics create`: result word, then topic id.
pub fn topic_create_row(
  result : TopicCreateResult,
  topic_id : UInt16,
) -> String {
  let word = match result {
    Created => "created"
    Existed => "existed"
    Mismatch => "mismatch"
  }
  tsv_line([word, topic_id.to_string()])
}

///|
/// Render `topics delete`: the result word alone.
pub fn topic_delete_row(result : TopicDeleteResult) -> String {
  let word = match result {
    Deleted => "deleted"
    NotFound => "not_found"
  }
  tsv_line([word])
}

///|
/// Render `topics list`: name, partitions, state, created_epoch.
pub fn topic_list_rows(rows : Array[TopicListRow]) -> String {
  let mut text = ""
  for row in rows {
    text = text +
      tsv_line([
        row.name,
        row.partitions.to_string(),
        row.state,
        row.created_epoch.to_string(),
      ])
  }
  text
}

///|
/// Render `groups list`: group, topic, lag, state.
pub fn group_list_rows(rows : Array[GroupListRow]) -> String {
  let mut text = ""
  for row in rows {
    text = text +
      tsv_line([row.group, row.topic, row.lag.to_string(), row.state])
  }
  text
}

///|
/// Render `groups describe`: member, assignment_epoch, ownership_epoch,
/// lag.
pub fn group_describe_rows(rows : Array[GroupDescribeRow]) -> String {
  let mut text = ""
  for row in rows {
    text = text +
      tsv_line([
        row.member_id.to_string(),
        row.assignment_epoch.to_string(),
        row.ownership_epoch.to_string(),
        row.lag.to_string(),
      ])
  }
  text
}

///|
/// Render `leader get`: leader_id, leader_epoch, quorum_state.
pub fn leader_row(row : LeaderRow) -> String {
  tsv_line([
    row.leader_id.to_string(),
    row.leader_epoch.to_string(),
    row.quorum_state,
  ])
}

///|
/// Render `broker status`: node_id, uptime_s, connections, version.
pub fn broker_status_row(row : BrokerStatusRow) -> String {
  tsv_line([
    row.node_id.to_string(),
    row.uptime_s.to_string(),
    row.connections.to_string(),
    row.version,
  ])
}

///|
/// Resolve `topics create --partitions`: an explicit argument wins, an
/// omitted one falls back to the configured default.
pub fn resolve_partitions(
  explicit : UInt16?,
  config : @config.Config,
) -> UInt16 {
  match explicit {
    Some(value) => value
    None => config.partition_default_count
  }
}

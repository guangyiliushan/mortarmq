/// The `/stats` response of the admin endpoint: the per-topic and
/// per-group detail a filter asks for, and nothing else.
///
/// A filter is mandatory: `topic`, `group`, or both. A request that
/// names neither is refused with an actionable parameter error and
/// returns no rows at all -- the full export is disabled by contract,
/// so the refusal is the only answer an unfiltered request can get.
/// The rows are caller-supplied detail (the counters behind the
/// metrics face), filtered here by exact name match; the JSON body is
/// built with the standard JSON encoder so names escape correctly.
///
/// # Stability
///
/// * A filter value that is empty counts as absent: `?topic=` is no
///   filter.
/// * Both filters present narrow to their intersection.
/// * Rows render in caller order; the body is deterministic for one
///   input.
/// * Count fields render as JSON numbers exact to 2^53.
/// * The detail rows come from the delivery and cursor faces through
///   the composition root, not from here.

///|
/// The `Content-Type` of a `/stats` response.
pub const STATS_CONTENT_TYPE : String = "application/json; charset=utf-8"

///|
/// One detail row: the depth of a topic and the in-flight and deferred
/// work of a group on it.
pub(all) struct StatsRow {
  topic : String
  group : String
  depth : UInt64
  in_flight : UInt64
  deferred : UInt64
}

///|
/// One `/stats` response: the HTTP status code and the JSON body.
pub(all) struct StatsResponse {
  status_code : UInt
  body : String
} derive(Eq, Debug)

///|
pub extend StatsResponse with Eq::{not_equal, equal}

///|
pub extend StatsResponse with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Build the `/stats` response for one filter pair over the detail
/// rows.
///
/// # Errors
///
/// The refusal is in the body, not in the type: a request with no
/// usable filter answers `400` with `{"error": ...}` naming the fix.
///
/// Example:
///
/// ```mbt check
/// test {
///   let res = @admin.stats_response(Some("orders"), None, [
///     { topic: "orders", group: "workers", depth: 2, in_flight: 1, deferred: 0, },
///   ])
///   assert_eq(res.status_code, 200U)
/// }
/// ```
pub fn stats_response(
  topic : String?,
  group : String?,
  rows : Array[StatsRow],
) -> StatsResponse {
  let topic_filter = non_empty(topic)
  let group_filter = non_empty(group)
  if topic_filter == None && group_filter == None {
    let body : Json = {
      "error": "a topic or group filter is required; the full export is disabled",
    }
    return { status_code: 400U, body: body.stringify(), }
  }
  let items : Array[Json] = []
  for row in rows {
    let topic_ok = match topic_filter {
      None => true
      Some(name) => row.topic == name
    }
    let group_ok = match group_filter {
      None => true
      Some(name) => row.group == name
    }
    if topic_ok && group_ok {
      items.push({
        "topic": row.topic.to_json(),
        "group": row.group.to_json(),
        "depth": Json::number(row.depth.to_double()),
        "in_flight": Json::number(row.in_flight.to_double()),
        "deferred": Json::number(row.deferred.to_double()),
      })
    }
  }
  let body : Json = { "stats": items.to_json() }
  { status_code: 200U, body: body.stringify(), }
}

///|
/// The filter value when it names something, or `None` for a missing
/// or empty parameter.
fn non_empty(value : String?) -> String? {
  match value {
    None => None
    Some(text) => if text == "" { None } else { Some(text) }
  }
}

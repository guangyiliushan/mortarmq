/// Pin the filter-mandatory `/stats` face: an unfiltered request is
/// refused with an actionable error and returns no rows, and each
/// filter narrows the detail to the matching rows with a literal body
/// baseline.

///|
/// Three detail rows across two topics and two groups.
fn fixture_rows() -> Array[@admin.StatsRow] {
  [
    { topic: "orders", group: "workers", depth: 20, in_flight: 5, deferred: 2, },
    { topic: "orders", group: "billing", depth: 7, in_flight: 0, deferred: 1, },
    {
      topic: "payments",
      group: "workers",
      depth: 3,
      in_flight: 1,
      deferred: 0,
    },
  ]
}

///|
test "a request without a filter is refused with an actionable error" {
  let res = @admin.stats_response(None, None, fixture_rows())
  assert_eq(res.status_code, 400U)
  assert_eq(
    res.body,
    "{\"error\":\"a topic or group filter is required; the full export is disabled\"}",
  )
}

///|
test "an empty filter value counts as no filter" {
  let res = @admin.stats_response(Some(""), Some(""), fixture_rows())
  assert_eq(res.status_code, 400U)
}

///|
test "the topic filter returns only its rows" {
  let res = @admin.stats_response(Some("orders"), None, fixture_rows())
  assert_eq(res.status_code, 200U)
  assert_eq(
    res.body,
    "{\"stats\":[" +
    "{\"topic\":\"orders\",\"group\":\"workers\",\"depth\":20,\"in_flight\":5,\"deferred\":2}," +
    "{\"topic\":\"orders\",\"group\":\"billing\",\"depth\":7,\"in_flight\":0,\"deferred\":1}" +
    "]}",
  )
}

///|
test "the group filter returns only its rows" {
  let res = @admin.stats_response(None, Some("workers"), fixture_rows())
  assert_eq(res.status_code, 200U)
  assert_eq(
    res.body,
    "{\"stats\":[" +
    "{\"topic\":\"orders\",\"group\":\"workers\",\"depth\":20,\"in_flight\":5,\"deferred\":2}," +
    "{\"topic\":\"payments\",\"group\":\"workers\",\"depth\":3,\"in_flight\":1,\"deferred\":0}" +
    "]}",
  )
}

///|
test "both filters narrow to their intersection" {
  let res = @admin.stats_response(
    Some("orders"),
    Some("billing"),
    fixture_rows(),
  )
  assert_eq(res.status_code, 200U)
  assert_eq(
    res.body,
    "{\"stats\":[" +
    "{\"topic\":\"orders\",\"group\":\"billing\",\"depth\":7,\"in_flight\":0,\"deferred\":1}" +
    "]}",
  )
}

///|
test "a filter that matches nothing returns the empty list, not a full dump" {
  let res = @admin.stats_response(Some("unknown"), None, fixture_rows())
  assert_eq(res.status_code, 200U)
  assert_eq(res.body, "{\"stats\":[]}")
}

/// Route-level tests for the admin face: every response comes from the
/// frozen builders, so the assertions pin the routing vocabulary (paths,
/// methods, query parsing) and never restate the bodies.

///|
test "healthz answers 200 json from the frozen builder" {
  let res = route("GET", "/healthz")
  assert_eq(res.status_code, 200U)
  assert_eq(res.reason, "OK")
  assert_eq(res.content_type, "application/json")
  assert_eq(res.body.contains("\"state\":"), true)
}

///|
test "metrics answers the registry exposition under its content type" {
  let res = route("GET", "/metrics")
  assert_eq(res.status_code, 200U)
  assert_eq(res.content_type, @metrics.METRICS_CONTENT_TYPE)
  assert_eq(res.body.has_prefix("# HELP "), true)
}

///|
test "stats without a filter keeps the export disabled" {
  let res = route("GET", "/stats")
  assert_eq(res.status_code, 400U)
  assert_eq(res.body.contains("filter"), true)
}

///|
test "stats with a filter answers an empty consumer view" {
  let res = route("GET", "/stats?topic=orders&group=workers")
  assert_eq(res.status_code, 200U)
  assert_eq(res.content_type, "application/json")
}

///|
test "non-get methods and unknown paths refuse with structured errors" {
  let post = route("POST", "/healthz")
  assert_eq(post.status_code, 405U)
  assert_eq(post.reason, "Method Not Allowed")
  let missing = route("GET", "/nope")
  assert_eq(missing.status_code, 404U)
  assert_eq(missing.reason, "Not Found")
}

///|
test "query parsing is exact-match on the whitelisted keys" {
  let (path, query) = split_query("/stats?topic=orders&group=workers")
  assert_eq(path, "/stats")
  assert_eq(query_value(query, "topic"), Some("orders"))
  assert_eq(query_value(query, "group"), Some("workers"))
  assert_eq(query_value(query, "missing"), None)
  assert_eq(query_value("", "topic"), None)
}

///|
test "the request line parses into method and target" {
  let (verb, target) = parse_request_line(
    b"GET /stats?topic=orders HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
  )
  assert_eq(verb, "GET")
  assert_eq(target, "/stats?topic=orders")
  let (verb2, target2) = parse_request_line(b"nonsense")
  assert_eq(verb2, "GET")
  assert_eq(target2, "/")
}

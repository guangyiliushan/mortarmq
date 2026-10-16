/// `mortarmq serve` -- the composition root.
///
/// v0 serves the admin HTTP face on the configured `listen_admin`
/// address: `GET /healthz` reports the quorum gauge, `GET /metrics` the
/// whitelisted exposition (empty until the counters feed it), and
/// `GET /stats?topic=..&group=..` the filtered consumer view (rows are
/// empty until the group state feeds it; the unfiltered export stays
/// disabled by contract). Every route response is built by the frozen
/// admin builders -- the server only parses the request line and picks
/// the route.
///
/// The configuration arrives as the literal JSON text in the first
/// argument (`mortarmq serve '<config json>'`); the file-loading path
/// arrives with the production disk adapter, and until then this is the
/// documented start sequence. An invalid configuration refuses to start.

///|
fn main {
  @async.run_async_main(async fn() {
    let args = @env.args()
    if args.length() < 2 {
      println("usage: mortarmq serve '<config json>'")
      return
    }
    let config = match @config.load_config(args[1]) {
      Ok(config) => config
      Err(_) => {
        println("invalid configuration")
        return
      }
    }
    let server = @socket.TcpServer(@socket.Addr::parse(config.listen_admin))
    println("mortarmq admin face listening on " + config.listen_admin)
    while true {
      let (tcp, _peer) = server.accept()
      serve_conn(tcp)
    }
  })
}

///|
/// Serve one connection: read a bounded request head, pick the route,
/// write the response, close. HTTP/1.0 simplicity -- no keep-alive, no
/// pipelining -- is the honest v0 for a loopback admin face.
async fn serve_conn(tcp : @socket.Tcp) -> Unit {
  let head = read_head(tcp)
  let (verb, path) = parse_request_line(head)
  let response = route(verb, path)
  let out = "HTTP/1.1 " +
    response.status_code.to_string() +
    " " +
    response.reason +
    "\r\nContent-Type: " +
    response.content_type +
    "\r\nContent-Length: " +
    response.body.length().to_string() +
    "\r\nConnection: close\r\n\r\n" +
    response.body
  @io.Writer::write(tcp, out) catch {
    _ => ()
  }
  tcp.close()
}

///|
/// Read up to the header terminator, byte at a time, with a hard cap so a
/// hostile client cannot grow the buffer. A connection that never
/// completes a head reads as empty and answers 400 downstream.
async fn read_head(tcp : @socket.Tcp) -> Bytes {
  let buf = Buffer()
  while buf.contents().length() < 8192 {
    let byte = @io.Reader::read_exactly(tcp, 1)
    buf.write_byte(byte[0])
    let content = buf.contents()
    if content.length() >= 4 &&
      content[content.length() - 4] == b'\r' &&
      content[content.length() - 3] == b'\n' &&
      content[content.length() - 2] == b'\r' &&
      content[content.length() - 1] == b'\n' {
      break
    }
  }
  buf.contents()
}

///|
/// Split the request line into method and target. Anything that does not
/// look like `METHOD SP TARGET` answers as GET / so the router's 404/405
/// vocabulary stays the only refusal surface.
fn parse_request_line(head : Bytes) -> (String, String) {
  let text = @utf8.decode_lossy(head[:])
  // The trailing CRLF lands on the version token, so the first two
  // space-separated tokens need no trimming.
  let parts = text.split(" ").collect()
  if parts.length() < 2 {
    return ("GET", "/")
  }
  (parts[0].to_owned(), parts[1].to_owned())
}

///|
/// Split a target into path and query at the first `?`.
fn split_query(target : String) -> (String, String) {
  let parts = target.split("?").collect()
  if parts.length() < 2 {
    return (target, "")
  }
  (parts[0].to_owned(), parts[1].to_owned())
}

///|
/// One exact-match query parameter, or `None`. v0 does not URL-decode:
/// topic and group names are whitelisted vocabulary upstream.
fn query_value(query : String, key : String) -> String? {
  if query == "" {
    return None
  }
  for pair in query.split("&") {
    let kv = pair.split("=").collect()
    if kv.length() == 2 && kv[0].to_owned() == key {
      return Some(kv[1].to_owned())
    }
  }
  None
}

///|
priv struct HttpResponse {
  status_code : UInt32
  reason : String
  content_type : String
  body : String
}

///|
fn reason_phrase(status_code : UInt32) -> String {
  match status_code {
    200U => "OK"
    400U => "Bad Request"
    404U => "Not Found"
    405U => "Method Not Allowed"
    503U => "Service Unavailable"
    _ => "Status"
  }
}

///|
fn json_error(
  status_code : UInt32,
  reason : String,
  message : String,
) -> HttpResponse {
  {
    status_code,
    reason,
    content_type: "application/json",
    body: "{\"error\":\"" + message + "\"}",
  }
}

///|
/// Pick the route: the three admin paths, each answered by its frozen
/// builder. Everything else is a structured refusal.
fn route(verb : String, target : String) -> HttpResponse {
  if verb != "GET" {
    return json_error(405U, "Method Not Allowed", "method not allowed")
  }
  let (path, query) = split_query(target)
  match path {
    "/healthz" => {
      // v0 single node: a majority of one is in sync and no election has
      // run, so the gauge reads healthy at epoch zero. The quorum face
      // reports through the same builder once replication wires in.
      let res = @admin.healthz_response(@cluster.QuorumState::Healthy, 0UL)
      {
        status_code: res.status_code,
        reason: reason_phrase(res.status_code),
        content_type: "application/json",
        body: res.body,
      }
    }
    "/metrics" =>
      match @metrics.render_metrics([]) {
        Ok(text) =>
          {
            status_code: 200U,
            reason: "OK",
            content_type: @metrics.METRICS_CONTENT_TYPE,
            body: text,
          }
        Err(_) =>
          json_error(500U, "Internal Server Error", "metric render failed")
      }
    "/stats" => {
      let topic = query_value(query, "topic")
      let group = query_value(query, "group")
      let res = @admin.stats_response(topic, group, [])
      {
        status_code: res.status_code,
        reason: reason_phrase(res.status_code),
        content_type: "application/json",
        body: res.body,
      }
    }
    _ => json_error(404U, "Not Found", "unknown path")
  }
}

/// Pin the sanitizing and escaping layer: the identifier allowlist on
/// the write side, the reserved-character escapes on the output side,
/// and the two wired into the renderer's label and help surfaces.

///|
test "help text escapes backslashes and newlines" {
  // Backslash doubles, newline becomes the two-character escape, and a
  // double quote is not reserved in help text and passes through.
  assert_eq(@metrics.escape_help_text("a\\b\nc"), "a\\\\b\\nc")
  assert_eq(@metrics.escape_help_text("say \"hi\""), "say \"hi\"")
}

///|
test "label values escape backslashes, quotes and newlines" {
  // The defensive output layer: each reserved character becomes its
  // escaped form even though the write-side allowlist removes them
  // first in the normal pipeline.
  assert_eq(@metrics.escape_label_value("x\\y"), "x\\\\y")
  assert_eq(@metrics.escape_label_value("a\"b"), "a\\\"b")
  assert_eq(@metrics.escape_label_value("l1\nl2"), "l1\\nl2")
}

///|
test "label values are sanitized to the identifier allowlist" {
  // Letters, digits, underscore and hyphen survive; everything else --
  // punctuation, spaces, brackets, non-ASCII -- becomes underscore.
  assert_eq(@metrics.sanitize_label_value("orders/eu"), "orders_eu")
  assert_eq(@metrics.sanitize_label_value("a b]c"), "a_b_c")
  assert_eq(@metrics.sanitize_label_value("ok-1_2"), "ok-1_2")
  assert_eq(@metrics.sanitize_label_value("héllo"), "h_llo")
}

///|
test "the renderer writes sanitized label values" {
  // The write side runs at the emission point: a dirty topic name
  // reaches the text only through the allowlist. The renderer always
  // emits every whitelist entry's HELP and TYPE lines; the sample line
  // carries the sanitized value.
  let out = @metrics.render_metrics([
    {
      name: "mortarmq_topic_bytes_total",
      labels: [("topic", "orders/eu")],
      value: 1UL,
    },
  ])
  assert_eq(
    out,
    Ok(
      "# HELP mortarmq_broker_uptime_seconds Process uptime in seconds.\n" +
      "# TYPE mortarmq_broker_uptime_seconds gauge\n" +
      "# HELP mortarmq_connections Active client connections.\n" +
      "# TYPE mortarmq_connections gauge\n" +
      "# HELP mortarmq_leader_epoch Current leader epoch; monotonic.\n" +
      "# TYPE mortarmq_leader_epoch gauge\n" +
      "# HELP mortarmq_quorum_state Quorum state: 0 healthy, 1 soft, 2 read-only.\n" +
      "# TYPE mortarmq_quorum_state gauge\n" +
      "# HELP mortarmq_topic_messages_produced_total Messages persisted to the topic.\n" +
      "# TYPE mortarmq_topic_messages_produced_total counter\n" +
      "# HELP mortarmq_topic_messages_delivered_total Messages acknowledged by consumers.\n" +
      "# TYPE mortarmq_topic_messages_delivered_total counter\n" +
      "# HELP mortarmq_topic_messages_dropped_total Messages dropped after exhausting delivery attempts.\n" +
      "# TYPE mortarmq_topic_messages_dropped_total counter\n" +
      "# HELP mortarmq_topic_messages_dlq_total Messages written to the DLQ.\n" +
      "# TYPE mortarmq_topic_messages_dlq_total counter\n" +
      "# HELP mortarmq_topic_bytes_total Bytes persisted to the topic.\n" +
      "# TYPE mortarmq_topic_bytes_total counter\n" +
      "mortarmq_topic_bytes_total{topic=\"orders_eu\"} 1\n" +
      "# HELP mortarmq_partition_depth Unconsumed partition depth (last_seq minus ack_floor).\n" +
      "# TYPE mortarmq_partition_depth gauge\n" +
      "# HELP mortarmq_partition_last_seq Latest durable sequence of the partition.\n" +
      "# TYPE mortarmq_partition_last_seq gauge\n" +
      "# HELP mortarmq_group_lag Consumer-group lag (max partition depth).\n" +
      "# TYPE mortarmq_group_lag gauge\n" +
      "# HELP mortarmq_group_in_flight In-flight unacknowledged messages of the consumer group.\n" +
      "# TYPE mortarmq_group_in_flight gauge\n" +
      "# HELP mortarmq_group_retries_total Redeliveries to the consumer group.\n" +
      "# TYPE mortarmq_group_retries_total counter\n" +
      "# HELP mortarmq_e2e_latency_ms End-to-end publish-to-ack latency quantile over a 60 second window.\n" +
      "# TYPE mortarmq_e2e_latency_ms gauge\n",
    ),
  )
}

///|
test "a metric name with illegal characters is refused" {
  // Names never enter the exposition unsanitized: anything outside the
  // whitelist -- including names with reserved characters -- is
  // refused before output.
  assert_eq(
    @metrics.render_metrics([
      { name: "mortarmq bad\ntype", labels: [], value: 1UL, },
    ]),
    Err(@metrics.UnknownMetric),
  )
}

///|
test "every whitelist name is a clean identifier" {
  // An independent character scan of the registry names: letters,
  // digits and underscore only, so no name ever needs escaping on the
  // help or type lines.
  for spec in @metrics.metric_whitelist() {
    for c in spec.name {
      let ok = (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') ||
        c == '_'
      assert_eq(ok, true)
    }
  }
}

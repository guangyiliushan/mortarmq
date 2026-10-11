/// Pin the `/metrics` exposition to a literal text baseline and prove
/// the whitelist refuses everything else: the fifteen documented
/// metrics render in whitelist order with their help and type lines,
/// and a sample outside the whitelist -- or one whose labels do not
/// match its schema -- never reaches the output.

///|
/// The fifteen documented metric names, in emission order, as literals.
fn expected_names() -> Array[String] {
  [
    "mortarmq_broker_uptime_seconds", "mortarmq_connections", "mortarmq_leader_epoch",
    "mortarmq_quorum_state", "mortarmq_topic_messages_produced_total", "mortarmq_topic_messages_delivered_total",
    "mortarmq_topic_messages_dropped_total", "mortarmq_topic_messages_dlq_total",
    "mortarmq_topic_bytes_total", "mortarmq_partition_depth", "mortarmq_partition_last_seq",
    "mortarmq_group_lag", "mortarmq_group_in_flight", "mortarmq_group_retries_total",
    "mortarmq_e2e_latency_ms",
  ]
}

///|
/// One scrape fixture: one instance per metric, the latency metric
/// carrying its three quantiles.
fn fixture_samples() -> Array[@metrics.MetricSample] {
  [
    { name: "mortarmq_broker_uptime_seconds", labels: [], value: 42UL, },
    { name: "mortarmq_connections", labels: [], value: 3UL, },
    { name: "mortarmq_leader_epoch", labels: [], value: 7UL, },
    { name: "mortarmq_quorum_state", labels: [], value: 0UL, },
    {
      name: "mortarmq_topic_messages_produced_total",
      labels: [("topic", "orders")],
      value: 100UL,
    },
    {
      name: "mortarmq_topic_messages_delivered_total",
      labels: [("topic", "orders")],
      value: 80UL,
    },
    {
      name: "mortarmq_topic_messages_dropped_total",
      labels: [("topic", "orders")],
      value: 2UL,
    },
    {
      name: "mortarmq_topic_messages_dlq_total",
      labels: [("topic", "orders")],
      value: 1UL,
    },
    {
      name: "mortarmq_topic_bytes_total",
      labels: [("topic", "orders")],
      value: 4096UL,
    },
    {
      name: "mortarmq_partition_depth",
      labels: [("topic", "orders"), ("partition", "0")],
      value: 20UL,
    },
    {
      name: "mortarmq_partition_last_seq",
      labels: [("topic", "orders"), ("partition", "0")],
      value: 99UL,
    },
    {
      name: "mortarmq_group_lag",
      labels: [("topic", "orders"), ("group", "workers")],
      value: 20UL,
    },
    {
      name: "mortarmq_group_in_flight",
      labels: [("topic", "orders"), ("group", "workers")],
      value: 5UL,
    },
    {
      name: "mortarmq_group_retries_total",
      labels: [("topic", "orders"), ("group", "workers")],
      value: 4UL,
    },
    {
      name: "mortarmq_e2e_latency_ms",
      labels: [("quantile", "p50")],
      value: 10UL,
    },
    {
      name: "mortarmq_e2e_latency_ms",
      labels: [("quantile", "p90")],
      value: 25UL,
    },
    {
      name: "mortarmq_e2e_latency_ms",
      labels: [("quantile", "p99")],
      value: 80UL,
    },
  ]
}

///|
/// The literal text baseline of `fixture_samples`, in whitelist order.
fn expected_snapshot() -> String {
  "# HELP mortarmq_broker_uptime_seconds Process uptime in seconds.\n" +
  "# TYPE mortarmq_broker_uptime_seconds gauge\n" +
  "mortarmq_broker_uptime_seconds 42\n" +
  "# HELP mortarmq_connections Active client connections.\n" +
  "# TYPE mortarmq_connections gauge\n" +
  "mortarmq_connections 3\n" +
  "# HELP mortarmq_leader_epoch Current leader epoch; monotonic.\n" +
  "# TYPE mortarmq_leader_epoch gauge\n" +
  "mortarmq_leader_epoch 7\n" +
  "# HELP mortarmq_quorum_state Quorum state: 0 healthy, 1 soft, 2 read-only.\n" +
  "# TYPE mortarmq_quorum_state gauge\n" +
  "mortarmq_quorum_state 0\n" +
  "# HELP mortarmq_topic_messages_produced_total Messages persisted to the topic.\n" +
  "# TYPE mortarmq_topic_messages_produced_total counter\n" +
  "mortarmq_topic_messages_produced_total{topic=\"orders\"} 100\n" +
  "# HELP mortarmq_topic_messages_delivered_total Messages acknowledged by consumers.\n" +
  "# TYPE mortarmq_topic_messages_delivered_total counter\n" +
  "mortarmq_topic_messages_delivered_total{topic=\"orders\"} 80\n" +
  "# HELP mortarmq_topic_messages_dropped_total Messages dropped after exhausting delivery attempts.\n" +
  "# TYPE mortarmq_topic_messages_dropped_total counter\n" +
  "mortarmq_topic_messages_dropped_total{topic=\"orders\"} 2\n" +
  "# HELP mortarmq_topic_messages_dlq_total Messages written to the DLQ.\n" +
  "# TYPE mortarmq_topic_messages_dlq_total counter\n" +
  "mortarmq_topic_messages_dlq_total{topic=\"orders\"} 1\n" +
  "# HELP mortarmq_topic_bytes_total Bytes persisted to the topic.\n" +
  "# TYPE mortarmq_topic_bytes_total counter\n" +
  "mortarmq_topic_bytes_total{topic=\"orders\"} 4096\n" +
  "# HELP mortarmq_partition_depth Unconsumed partition depth (last_seq minus ack_floor).\n" +
  "# TYPE mortarmq_partition_depth gauge\n" +
  "mortarmq_partition_depth{topic=\"orders\",partition=\"0\"} 20\n" +
  "# HELP mortarmq_partition_last_seq Latest durable sequence of the partition.\n" +
  "# TYPE mortarmq_partition_last_seq gauge\n" +
  "mortarmq_partition_last_seq{topic=\"orders\",partition=\"0\"} 99\n" +
  "# HELP mortarmq_group_lag Consumer-group lag (max partition depth).\n" +
  "# TYPE mortarmq_group_lag gauge\n" +
  "mortarmq_group_lag{topic=\"orders\",group=\"workers\"} 20\n" +
  "# HELP mortarmq_group_in_flight In-flight unacknowledged messages of the consumer group.\n" +
  "# TYPE mortarmq_group_in_flight gauge\n" +
  "mortarmq_group_in_flight{topic=\"orders\",group=\"workers\"} 5\n" +
  "# HELP mortarmq_group_retries_total Redeliveries to the consumer group.\n" +
  "# TYPE mortarmq_group_retries_total counter\n" +
  "mortarmq_group_retries_total{topic=\"orders\",group=\"workers\"} 4\n" +
  "# HELP mortarmq_e2e_latency_ms End-to-end publish-to-ack latency quantile over a 60 second window.\n" +
  "# TYPE mortarmq_e2e_latency_ms gauge\n" +
  "mortarmq_e2e_latency_ms{quantile=\"p50\"} 10\n" +
  "mortarmq_e2e_latency_ms{quantile=\"p90\"} 25\n" +
  "mortarmq_e2e_latency_ms{quantile=\"p99\"} 80\n"
}

///|
test "the whitelist pins the fifteen documented metrics" {
  let whitelist = @metrics.metric_whitelist()
  assert_eq(whitelist.length(), 15)
  let names = expected_names()
  for i in 0..<names.length() {
    assert_eq(whitelist[i].name, names[i])
  }
}

///|
test "every counter name carries the total suffix" {
  for spec in @metrics.metric_whitelist() {
    if spec.kind == @metrics.Counter {
      assert_eq(spec.name.has_suffix("_total"), true)
    }
  }
}

///|
test "the snapshot renders the fifteen metrics in whitelist order" {
  assert_eq(@metrics.render_metrics(fixture_samples()), Ok(expected_snapshot()))
}

///|
test "a metric outside the whitelist is refused" {
  assert_eq(
    @metrics.render_metrics([
      { name: "mortarmq_bogus", labels: [], value: 1UL, },
    ]),
    Err(@metrics.UnknownMetric),
  )
}

///|
test "labels must match the metric schema exactly" {
  // A topic metric without its topic label.
  assert_eq(
    @metrics.render_metrics([
      { name: "mortarmq_topic_bytes_total", labels: [], value: 1UL, },
    ]),
    Err(@metrics.LabelMismatch),
  )
  // A partition metric with its labels out of schema order.
  assert_eq(
    @metrics.render_metrics([
      {
        name: "mortarmq_partition_depth",
        labels: [("partition", "0"), ("topic", "orders")],
        value: 1UL,
      },
    ]),
    Err(@metrics.LabelMismatch),
  )
  // A no-label metric carrying an extra label.
  assert_eq(
    @metrics.render_metrics([
      { name: "mortarmq_connections", labels: [("client", "c1")], value: 1UL, },
    ]),
    Err(@metrics.LabelMismatch),
  )
}

///|
test "quantile labels accept only p50, p90 and p99" {
  assert_eq(
    @metrics.render_metrics([
      {
        name: "mortarmq_e2e_latency_ms",
        labels: [("quantile", "p95")],
        value: 1UL,
      },
    ]),
    Err(@metrics.LabelMismatch),
  )
}

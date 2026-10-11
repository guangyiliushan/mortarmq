/// Hold the `/metrics` whitelist: the fifteen metrics the admin endpoint
/// may expose, and nothing else.
///
/// The whitelist is the single source of truth for metric names, types,
/// label schemas and help text. The renderer walks this registry and
/// refuses every sample whose name is not in it, so an unregistered
/// metric cannot reach the output by construction -- adding a metric
/// means adding it here, and the snapshot test that pins these fifteen
/// literals then fails until the change is deliberate. That is the
/// registry-driven refusal the contract requires; the CI assertion is
/// the snapshot and the refusal tests running on every change.
///
/// # Stability
///
/// * Names, types and label schemas are frozen by the documented
///   inventory; a counter always carries the `_total` suffix so rates
///   can be rebuilt from totals after a restart.
/// * v0 knows exactly two kinds, `Counter` and `Gauge`; rates and
///   quantiles are derived at query time and hold no metric of their
///   own.
/// * Labels are level-shaped: broker metrics carry none, topic metrics
///   carry `topic`, partition metrics carry `topic, partition`, group
///   metrics carry `topic, group`, and the latency metric carries
///   `quantile` with the domain `p50|p90|p99`. Client and connection
///   identifiers never become labels.
/// * The cluster-owned gauges (`mortarmq_leader_epoch`,
///   `mortarmq_quorum_state`) keep their slots here; their values are
///   supplied by the cluster layer when it wires up.

///|
/// The two metric kinds v0 persists.
pub(all) enum MetricKind {
  Counter
  Gauge
} derive(Eq, Debug)

///|
pub extend MetricKind with Eq::{not_equal, equal}

///|
pub extend MetricKind with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// One whitelist entry: the metric name, its kind, the label keys in
/// emission order, and the help text.
pub(all) struct MetricSpec {
  name : String
  kind : MetricKind
  label_keys : Array[String]
  help : String
}

///|
/// The fifteen whitelisted metrics in their canonical emission order.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@metrics.metric_whitelist().length(), 15)
/// }
/// ```
pub fn metric_whitelist() -> Array[MetricSpec] {
  [
    {
      name: "mortarmq_broker_uptime_seconds",
      kind: Gauge,
      label_keys: [],
      help: "Process uptime in seconds.",
    },
    {
      name: "mortarmq_connections",
      kind: Gauge,
      label_keys: [],
      help: "Active client connections.",
    },
    {
      name: "mortarmq_leader_epoch",
      kind: Gauge,
      label_keys: [],
      help: "Current leader epoch; monotonic.",
    },
    {
      name: "mortarmq_quorum_state",
      kind: Gauge,
      label_keys: [],
      help: "Quorum state: 0 healthy, 1 soft, 2 read-only.",
    },
    {
      name: "mortarmq_topic_messages_produced_total",
      kind: Counter,
      label_keys: ["topic"],
      help: "Messages persisted to the topic.",
    },
    {
      name: "mortarmq_topic_messages_delivered_total",
      kind: Counter,
      label_keys: ["topic"],
      help: "Messages acknowledged by consumers.",
    },
    {
      name: "mortarmq_topic_messages_dropped_total",
      kind: Counter,
      label_keys: ["topic"],
      help: "Messages dropped after exhausting delivery attempts.",
    },
    {
      name: "mortarmq_topic_messages_dlq_total",
      kind: Counter,
      label_keys: ["topic"],
      help: "Messages written to the DLQ.",
    },
    {
      name: "mortarmq_topic_bytes_total",
      kind: Counter,
      label_keys: ["topic"],
      help: "Bytes persisted to the topic.",
    },
    {
      name: "mortarmq_partition_depth",
      kind: Gauge,
      label_keys: ["topic", "partition"],
      help: "Unconsumed partition depth (last_seq minus ack_floor).",
    },
    {
      name: "mortarmq_partition_last_seq",
      kind: Gauge,
      label_keys: ["topic", "partition"],
      help: "Latest durable sequence of the partition.",
    },
    {
      name: "mortarmq_group_lag",
      kind: Gauge,
      label_keys: ["topic", "group"],
      help: "Consumer-group lag (max partition depth).",
    },
    {
      name: "mortarmq_group_in_flight",
      kind: Gauge,
      label_keys: ["topic", "group"],
      help: "In-flight unacknowledged messages of the consumer group.",
    },
    {
      name: "mortarmq_group_retries_total",
      kind: Counter,
      label_keys: ["topic", "group"],
      help: "Redeliveries to the consumer group.",
    },
    {
      name: "mortarmq_e2e_latency_ms",
      kind: Gauge,
      label_keys: ["quantile"],
      help: "End-to-end publish-to-ack latency quantile over a 60 second window.",
    },
  ]
}

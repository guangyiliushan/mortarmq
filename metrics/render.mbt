/// Render one scrape of `/metrics` in Prometheus text format.
///
/// The renderer is registry-driven: it emits exactly the whitelisted
/// metrics, in whitelist order, each preceded by its `# HELP` and
/// `# TYPE` lines, followed by the sample lines the caller supplied for
/// it. A sample naming a metric outside the whitelist is refused before
/// anything is written, so the output cannot carry an unregistered
/// name. This is the endpoint skeleton's body builder -- the admin HTTP
/// layer serves the returned text under `METRICS_CONTENT_TYPE`; help
/// and label escaping is a separate work item on top of this renderer.
///
/// # Stability
///
/// * Output is deterministic for a given input: whitelist order for the
///   metric blocks, caller order for the samples of one metric.
/// * A sample's labels must match its metric's schema exactly, in
///   schema order; the `quantile` label admits only `p50`, `p90` and
///   `p99`. A mismatch is refused, never silently rendered.
/// * Values render as unsigned integers; v0 persists only counters and
///   gauges.

///|
/// The `Content-Type` of a `/metrics` scrape: Prometheus text format,
/// version 0.0.4.
pub const METRICS_CONTENT_TYPE : String = "text/plain; version=0.0.4; charset=utf-8"

///|
/// One sample line: the metric name, its label pairs in schema order,
/// and the value.
pub(all) struct MetricSample {
  name : String
  labels : Array[(String, String)]
  value : UInt64
}

///|
/// Refuse a sample before anything is written.
///
/// * `UnknownMetric` -- the name is not in the whitelist; the sample
///   never reaches the output.
/// * `LabelMismatch` -- the label keys do not match the metric's schema
///   exactly, or a `quantile` value is outside `p50|p90|p99`.
pub(all) enum MetricError {
  UnknownMetric
  LabelMismatch
} derive(Eq, Debug)

///|
pub extend MetricError with Eq::{not_equal, equal}

///|
pub extend MetricError with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Render one scrape of the whitelisted metrics in Prometheus text
/// format.
///
/// Every whitelist entry gets its `# HELP` and `# TYPE` lines whether or
/// not samples arrived for it; sample lines follow in caller order. All
/// samples are validated against the whitelist before the first
/// character is written, so a refused sample leaves no partial output.
///
/// # Errors
///
/// * `UnknownMetric` -- a sample names a metric outside the whitelist.
/// * `LabelMismatch` -- a sample's labels do not match its metric's
///   schema.
///
/// Example:
///
/// ```mbt check
/// test {
///   let out = @metrics.render_metrics([
///     { name: "mortarmq_connections", labels: [], value: 2UL, },
///   ])
///   assert_eq(out is Ok(_), true)
/// }
/// ```
pub fn render_metrics(
  samples : Array[MetricSample],
) -> Result[String, MetricError] {
  let whitelist = metric_whitelist()
  // Validate every sample first: a refusal must not leave partial text.
  for sample in samples {
    match find_spec(whitelist, sample.name) {
      None => return Err(UnknownMetric)
      Some(spec) =>
        if !labels_match(spec.label_keys, sample.labels) {
          return Err(LabelMismatch)
        }
    }
  }
  let mut out = ""
  for spec in whitelist {
    out = out + "# HELP " + spec.name + " " + escape_help_text(spec.help) + "\n"
    out = out + "# TYPE " + spec.name + " " + kind_text(spec.kind) + "\n"
    for sample in samples {
      if sample.name == spec.name {
        out = out +
          spec.name +
          labels_text(sample.labels) +
          " " +
          sample.value.to_string() +
          "\n"
      }
    }
  }
  Ok(out)
}

///|
/// The lowercase `# TYPE` literal of one kind.
fn kind_text(kind : MetricKind) -> String {
  match kind {
    Counter => "counter"
    Gauge => "gauge"
  }
}

///|
/// Find the whitelist entry of `name`, or `None` when the name is not
/// registered.
fn find_spec(whitelist : Array[MetricSpec], name : String) -> MetricSpec? {
  for spec in whitelist {
    if spec.name == name {
      return Some(spec)
    }
  }
  None
}

///|
/// Whether `labels` matches the schema keys exactly and in order, with
/// every `quantile` value inside its domain.
fn labels_match(keys : Array[String], labels : Array[(String, String)]) -> Bool {
  if keys.length() != labels.length() {
    return false
  }
  for i in 0..<keys.length() {
    let (label_key, label_value) = labels[i]
    if keys[i] != label_key {
      return false
    }
    if label_key == "quantile" &&
      label_value != "p50" &&
      label_value != "p90" &&
      label_value != "p99" {
      return false
    }
  }
  true
}

///|
/// The brace-enclosed label list, or the empty string when the metric
/// carries no labels. Values run through the write-side allowlist and
/// the output-side escape before they reach the text.
fn labels_text(labels : Array[(String, String)]) -> String {
  if labels.length() == 0 {
    return ""
  }
  let mut out = "{"
  for i in 0..<labels.length() {
    let (key, value) = labels[i]
    if i > 0 {
      out = out + ","
    }
    out = out +
      key +
      "=\"" +
      escape_label_value(sanitize_label_value(value)) +
      "\""
  }
  out + "}"
}

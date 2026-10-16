/// The `/healthz` response of the admin endpoint: the quorum tier, the
/// leader epoch, and why the cluster is not fully healthy.
///
/// The body and the status code are derived from the one quorum-state
/// face: the tier name and the read-only reason come from the same
/// functions the `mortarmq_quorum_state` gauge's code comes from, so a
/// health report can never disagree with the gauge an alert watches or
/// with the refusal a producer receives. The builders here contain no
/// tier logic of their own -- they render what the state face says.
///
/// # Stability
///
/// * Status: `200` for `healthy` and `soft`, `503` for `read_only`,
///   matching the degradation matrix the runbook drills.
/// * Body: `{"state":...,"leader_epoch":...,"reason":...}` with
///   `reason` populated only for `read_only` (the row of the matrix the
///   operator must act on) and `null` otherwise.
/// * Every body value comes from a closed vocabulary -- the tier names,
///   the reason names, an unsigned epoch -- so the hand-built JSON
///   needs no escaping layer.
/// * `leader_epoch` is passed in: the cluster object that owns the live
///   epoch is wired by the composition root, not here.

///|
/// The `Content-Type` of a `/healthz` response.
pub const HEALTHZ_CONTENT_TYPE : String = "application/json; charset=utf-8"

///|
/// One `/healthz` response: the HTTP status code and the JSON body.
pub(all) struct HealthzResponse {
  status_code : UInt32
  body : String
} derive(Eq, Debug)

///|
pub extend HealthzResponse with Eq::{not_equal, equal}

///|
pub extend HealthzResponse with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// Build the `/healthz` response for one quorum state.
///
/// Example:
///
/// ```mbt check
/// test {
///   let res = @admin.healthz_response(@cluster.QuorumState::Healthy, 7UL)
///   assert_eq(res.status_code, 200U)
///   assert_eq(
///     res.body,
///     "{\"state\":\"healthy\",\"leader_epoch\":7,\"reason\":null}",
///   )
/// }
/// ```
pub fn healthz_response(
  state : @cluster.QuorumState,
  leader_epoch : UInt64,
) -> HealthzResponse {
  let status_code = match state {
    @cluster.QuorumState::ReadOnly(_) => 503U
    _ => 200U
  }
  let reason = match state {
    @cluster.QuorumState::ReadOnly(row) =>
      "\"" + @cluster.ReadOnlyReason::reason_name(row) + "\""
    _ => "null"
  }
  let body = "{\"state\":\"" +
    @cluster.QuorumState::tier_name(state) +
    "\",\"leader_epoch\":" +
    leader_epoch.to_string() +
    ",\"reason\":" +
    reason +
    "}"
  { status_code, body, }
}

///|
/// The `mortarmq_quorum_state` sample of one state: the gauge code the
/// runbook alerts on, straight from the state face.
///
/// Example:
///
/// ```mbt check
/// test {
///   let sample = @admin.quorum_state_sample(@cluster.QuorumState::Soft)
///   assert_eq(sample.value, 1UL)
/// }
/// ```
pub fn quorum_state_sample(
  state : @cluster.QuorumState,
) -> @metrics.MetricSample {
  {
    name: "mortarmq_quorum_state",
    labels: [],
    value: state.code().to_uint().to_uint64(),
  }
}

///|
/// The `mortarmq_leader_epoch` sample of one epoch.
pub fn leader_epoch_sample(leader_epoch : UInt64) -> @metrics.MetricSample {
  { name: "mortarmq_leader_epoch", labels: [], value: leader_epoch, }
}

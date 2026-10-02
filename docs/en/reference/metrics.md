# Metrics

How SREs observe the broker — the 15-metric allowlist on `/metrics`, `/healthz` and `/stats`, and the conservation properties that tie them together.

> **Source of truth:** design-frozen; registry-driven — a metric outside this table is rejected at review.

## Endpoints

- `GET /metrics` — Prometheus text format, **15-metric allowlist**.
- `GET /healthz` — status enum, same source as `quorum_state`.
- `GET /stats` — filter parameter required (NSQ-style).
- Latency quantiles: NSQ-style double-buffer estimator, opt-in p50/p90/p99 (three-operation interface).

## The allowlist (15 metrics)

| Name | Type | Labels | Semantics | Conservation / derivation | Precedent |
|---|---|---|---|---|---|
| `mortarmq_broker_uptime_seconds` | gauge | — | Process uptime in seconds | — | NSQ `$SYS/broker/version+uptime` |
| `mortarmq_connections` | gauge | — | Currently active client connections | — | NATS `connz`; RocketMQ proxy-admin |
| `mortarmq_leader_epoch` | gauge | — | Current leader epoch (monotonic) | Only ever increases; a decrease means a fault | NATS `jsz` raft leader |
| `mortarmq_quorum_state` | gauge | — | `0`=healthy `1`=soft `2`=read_only | Matches the degradation matrix | — |
| `mortarmq_topic_messages_produced_total` | counter | `topic` | Messages durably appended by PUB | **Left side of the conservation identity** | Kafka `-total` rule; Mosquitto `received` |
| `mortarmq_topic_messages_delivered_total` | counter | `topic` | ACKs received for successful delivery | Conservation, right side | Kafka `records-consumed-total` |
| `mortarmq_topic_messages_dropped_total` | counter | `topic` | Messages that exceeded `max_attempts` and failed into DLQ (not counting DLQ successes) | Conservation, right side | Mosquitto `dropped` |
| `mortarmq_topic_messages_dlq_total` | counter | `topic` | Messages successfully written to the DLQ | Conservation, right side; `dlq_total <= dropped_total` | — |
| `mortarmq_topic_bytes_total` | counter | `topic` | Total bytes appended to disk | — | Kafka `BytesInPerSec`; NSQ `message_bytes` |
| `mortarmq_partition_depth` | gauge | `topic`, `partition` | Unconsumed depth = `last_seq - ack_floor` | The partition-level source of lag | NSQ `depth` / `backend_depth` |
| `mortarmq_partition_last_seq` | gauge | `topic`, `partition` | Latest durable sequence of the partition | Monotonic; a decrease is fatal | — |
| `mortarmq_group_lag` | gauge | `topic`, `group` | Group lag = max partition depth | `>= 0` and consistent with `ack_floor` | — |
| `mortarmq_group_in_flight` | gauge | `topic`, `group` | In-flight, un-ACKed messages for the group | `in_flight <= max_in_flight` | — |
| `mortarmq_group_retries_total` | counter | `topic`, `group` | Total redeliveries | — | — |
| `mortarmq_e2e_latency_ms` | gauge | `quantile=p50\|p90\|p99` | End-to-end PUB → ACK latency, 60 s window | `p50 <= p90 <= p99` | NSQ `e2e_processing_latency` |

## The conservation identity (P1)

In a quiet window — no in-flight producers, no in-flight consumers:

```
produced = delivered + dropped + dlq + Δdepth
```

Every metric on the right side is a **counter that only goes up**, and `Δdepth` is a gauge difference. That is what makes the identity checkable at scrape time rather than a claim in a document. A metric-semantics change must update this identity **in the same commit** — a divergence here means the numbers are lying.

`dlq_total <= dropped_total` is a second, tighter check: a message cannot land in the DLQ without having been counted as dropped.

::: warning Without code yet
No endpoint serves anything today. This table is the **contract**: 15 names, their types and labels are frozen, and the conservation identity above is what the property tests will assert.
:::

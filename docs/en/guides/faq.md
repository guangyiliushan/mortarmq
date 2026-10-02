# FAQ

Direct answers first, details after — grouped by what you are actually deciding.

## 1. What it is

### 1. Does MortarMQ need ZooKeeper, etcd, or any external coordinator?

**No.** Membership is a static `peers` table in the config, and metadata lives in the broker's own `MMML` log + snapshot (`data/metadata/`). There is no external process to run — and there is no dynamic membership either, which is exactly the trade that buys the "no ZooKeeper" answer. See [`peers`](../reference/configuration.md).

### 2. Is this Kafka-compatible?

**No.** The wire protocol is its own 15-op binary protocol (`[u32_be len][u8 op][payload]`), not the Kafka wire format. There is no drop-in client compatibility, and none is planned for v0.

### 3. Why build one at all?

Because the goal is a **MoonBit-native** MQ: the whole loop — codec, storage, broker, client — compiled for native *and* the browser from one codebase. The browser target is a JS backend rather than wasm-gc because `moonbitlang/async` does not support wasm-gc.

## 2. Delivery semantics

### 4. Is delivery at-least-once or exactly-once?

**At-least-once**, with a dead-letter path. Producers get idempotency through the `(producer_id, producer_seq)` dedup window; consumers get redelivery on lease timeout. After `delivery_max_attempts` (5) the message goes to the DLQ rather than being retried forever. Exactly-once across a consumer group is **not** offered.

### 5. What happens when a message fails 5 times?

It is written to the DLQ topic and counted in `mortarmq_topic_messages_dlq_total`. The invariant `dlq_total <= dropped_total` holds — a message cannot reach the DLQ without being counted as dropped.

### 6. Can I lose data on a broker crash?

The intent is no: segments are fsync'd, and quorum commit requires a majority flush before `commit_seq` advances. The delivery ledger is separate from the records, so redelivery timers survive a `kill -9`. This is exactly what the simulation injects and what [RB-3](./runbook.md#rb-3-kill-9-leader-recovery) covers.

## 3. v0 boundaries

### 7. Is TLS supported?

**No.** `wss` is a reserved slot and lands in v1. On a hostile network, tunnel MortarMQ over something that is encrypted — see the [threat model](../concepts/security.md) for what v0 does and does not defend.

### 8. Is there authentication? Authorization?

Authentication **yes**: a static token in the CONNECT frame, stored server-side only as a SHA-256 digest and compared in constant time. Authorization (per-topic ACLs) **no** — v2.

### 9. Does configuration hot-reload?

**No.** All 18 keys are `update_mode = read-only`; changing one means a restart. Hot reload is a v1 item.

### 10. Can I change a topic's partition count?

**No in v0.** Partition count is fixed at DECLARE. Plan it before creating the topic — see [Best practices §1.3](./best-practices.md#_1-3-pick-the-partition-count-once).

### 11. Do subscriptions support wildcards?

**No in v0.** Topic names are exact-match only; wildcards are an interface reservation for later.

### 12. Is the metadata layer Raft?

**No.** Metadata uses the broker's own `MMML` mutation log with `mutation_id` fencing and periodic snapshots, not a Raft implementation. A Raft-backed metadata quorum is explicitly out of scope for v0.

## 4. Using it

### 13. Does SUB create the topic?

**No.** SUB on a nonexistent topic returns `0x0008 UNKNOWN_TOPIC` — you must `DECLARE` first. This is the single most surprising behaviour if you are coming from a broker where subscribe creates the topic.

### 14. Can I use it from a browser?

**Yes** — that is the mainline target: the client library runs on a JS backend over WebSocket, with a wasm-gc pure core as a stretch goal.

### 15. What is `0x4006 NO_CREDIT` — is something wrong?

Nothing is wrong. It is normal flow control: your consumer used its credit budget without returning any. See [Troubleshooting §4](./troubleshooting.md#_4-0x4006-no-credit-or-0x4005-message-exceeds-credit).

## 5. Honest answers

### 16. Is it faster than Kafka / RocketMQ / Redpanda?

**Unknown, and no claim is made.** No benchmark has been run — the project has no executable broker yet. The [benchmark matrix and noise protocol](../develop/benchmarks.md) define how such a number *may* eventually be reported: ≥ 10 rounds, `mean±σ`, σ/mean > 3% voids the run, and differences < 5% support no conclusion.

### 17. What is definitely not in v0?

TLS/wss, dynamic tokens, authz ACLs, configuration hot reload, log truncation / automatic retention, a metadata quorum, dynamic cluster membership, topic wildcards, partition-count changes, WS compression. Every one of these has a documented upgrade path — see [Upgrade](./upgrade.md).

::: warning Without code yet
Every answer above comes from the frozen design, not from running software. When behaviour and document disagree, the document is wrong — [file it](https://github.com/guangyiliushan/mortarmq/issues).
:::

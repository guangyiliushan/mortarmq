# Best Practices

What to do on the first try, and why — producer side, consumer side, topic design, and deployment.

> Every item here is derived from a **frozen design decision**, not from a benchmark. Where a choice depends on measurement, it says so instead of guessing.

## 1. Producer

### 1.1 Make publishes idempotent

Set **both** `producer_id` and `producer_seq` on every publish. The broker deduplicates on the `(topic_id, partition, producer_id)` window, so a client retry after a timeout cannot double-write.

```text
producer_id=0 && producer_seq=0    → allowed, counted as a non-idempotent publish
producer_id=0 && producer_seq>0    → rejected, 0x0013
anything else                      → deduplicated by the window
```

Leaving both at zero works — but it moves the whole burden of retry-safety onto your own bookkeeping, and the metrics will silently count you as non-idempotent.

### 1.2 Choose keys deliberately

Partition selection is `fnv1a32(key) % partition_count`. So the key **is** the ordering guarantee: messages with the same key land on the same partition and stay ordered; keys spread evenly only if they are evenly distributed.

- Use a business identifier (`order_id`) when you need per-entity ordering.
- Leave the key empty when you do not care — round-robin spread beats a skewed key that funnels 80% of traffic into one partition.

### 1.3 Pick the partition count once

**Partition count is fixed at DECLARE and cannot change in v0.** It decides parallelism, consumer scaling headroom, and how long a rebalance takes. Undersizing means re-declaring under a new topic name (and losing history); oversizing means empty partitions you pay for in every rebalance.

Default is 4 (`partition_default_count`). Think about your peak consumer count before overriding it.

## 2. Consumer

### 2.1 Acknowledge promptly

An un-ACKed message holds **credit** and a **lease** (`delivery_lease_ms`, default 30 s). Both are finite: credit exhaustion pauses scheduling (nothing is dropped), but a lease expiry redelivers — and after `delivery_max_attempts` (5) the message goes to the DLQ.

If your handler is slow, batch the work and ACK the batch; do not hold one message open across a slow I/O.

### 2.2 Size the credit window for your message size

The default window is **256 messages / 2 MiB**. Those two numbers are not independent — `credit_bytes` is derived from `credit_count` by the same ratio. Large messages will exhaust bytes before count: a consumer pulling 64 KiB messages gets 32 in flight, not 256.

### 2.3 Expect `0x4006 NO_CREDIT` as normal flow control

It is not an error condition to alert on. The window auto-returns at 32 ACKs / 1 MiB / low watermark / 20 ms, whichever fires first. Alert on `mortarmq_group_lag` growing instead.

## 3. Topic design

- **Naming rules are enforced, not advisory**: no wildcards, no empty tokens, no `$` prefix, ≤ 255 bytes. Violations return `0x000B INVALID_TOPIC`.
- **One topic per business stream**, not per consumer. Consumers filter by group, not by proliferating topics.
- **The `$` prefix is reserved.** It marks system topics; a user topic cannot claim it.

## 4. Deployment

- **Never expose `listen_peer`.** It carries replication with an independent shared secret and no client authentication.
- **Keep `listen_admin` on `127.0.0.1`.** The metrics surface has no authentication in v0 — binding it wider is an unauthenticated read of your queue depths and topology.
- **Leave `ws_origins` explicit.** An empty list rejects all origins (the safe default); do not "fix" that by making it empty-means-all.
- **One `data_dir` per node.** They will corrupt each other's segments.

## 5. Observability

Watch the **conservation identity**, not individual counters:

```
produced = delivered + dropped + dlq + Δdepth   (quiet window)
```

Any drift means one of the counters is lying. `dropped` climbing is normal only if `dlq` climbs with it — `dlq_total <= dropped_total` must hold.

::: warning Without code yet
No code has been measured. Nothing above claims a number — the practices come from the frozen design's trade-offs, and where a real answer needs a benchmark, the [benchmarks page](../develop/benchmarks.md) says so explicitly.
:::

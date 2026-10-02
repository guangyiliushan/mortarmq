# Message Loss

Under exactly what conditions can a message be lost in MortarMQ — and how would you prove it did not happen.

> Read [Core concepts §Where a message goes](./basics.md#where-a-message-goes-the-full-path) first; every condition below names a stage on that path.

## When loss is impossible

The design closes three doors deliberately:

1. **Before `PUB_OK`.** A write is acknowledged only after a majority has fsync'd it (stage 4). A crash between the local fsync and the quorum commit means the producer **was never told it succeeded** — a retry is correct behaviour, not data loss.
2. **Consumer-side stalls.** A consumer that stops ACKing causes lease timeout and redelivery, then a DLQ. The message still exists; it moved state.
3. **Retention.** v0 has **no** log truncation or automatic retention — segments only grow. So nothing is deleted by a background policy. (The cost is that `data_dir` fills up; that is an availability problem, not a loss problem.)

## When loss is possible

| Condition | How you get there | Avoid it |
|---|---|---|
| **All replicas on one disk** | Three nodes sharing a `data_dir`, or all `data_dir`s on one physical volume | One `data_dir` per node, on separate failure domains |
| **Explicit unclean acknowledgement** | Degradation level −1: `min_in_sync=1` with degraded ack enabled | **Not implemented by default.** If you turn it on, you have chosen availability over durability — write that down |
| **Node loss with no quorum** | Two of three nodes lost | This is not loss of *acked* data — but it is a stop-the-world outage |
| **A bug in the ledger** | The delivery ledger failing to persist `DELIVER`/`ACK` | The simulation injects `kill -9` between stages 3–5 specifically to catch this |

The first two are configuration choices, not defects. The third is a durability floor. The fourth is what the test suite exists for.

## How to detect it

**The conservation identity is the loss detector.** In a quiet window:

```
produced = delivered + dropped + dlq + Δdepth
```

If `produced` exceeds the right-hand side, messages are unaccounted for — that is the definition of loss. The identity holds at scrape time because every term on the right is a monotonic counter and `Δdepth` is a gauge difference.

Two monotonicity checks catch the same failure earlier:

- `mortarmq_partition_last_seq` must never decrease — a decrease is `fatal`, not a warning.
- `mortarmq_leader_epoch` only ever increases; a decrease means a fault.

```text
# what "healthy" looks like
mortarmq_topic_messages_produced_total{topic="orders"}        1000
mortarmq_topic_messages_delivered_total{topic="orders"}        980
mortarmq_topic_messages_dropped_total{topic="orders"}           15
mortarmq_topic_messages_dlq_total{topic="orders"}               15
mortarmq_partition_depth{topic="orders",partition="0"}           5
# 980 + 15 + 15 + 5 = 1015  ← investigate: 15 messages unaccounted for
```

That arithmetic is the whole monitoring strategy. You do not need a separate "loss" metric; you need the four that already exist to add up.

::: warning Without code yet
No broker runs, so this identity has never been evaluated in production. It is the **acceptance bar**: the property suite asserts it, and a failure is a correctness bug, not a metric bug.
:::

## Related

- The path itself: [Core concepts](./basics.md)
- What to do when quorum is lost: [Runbook RB-1](../guides/runbook.md)
- The counters: [Metrics](../reference/metrics.md)

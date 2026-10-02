# Ordering

What order MortarMQ guarantees, where it stops guaranteeing it, and how to design around the boundary.

## The guarantee: one partition, append order

A partition is written by exactly one writer at a time (the broker leader for that partition) and read by exactly one consumer in a group at a time. That single-writer / single-owner pair is what makes the guarantee cheap:

> **Messages within one partition are delivered in the order they were appended.**

No sequence numbers to reconcile, no out-of-order buffer — the log *is* the order.

## What key you use decides what is ordered

Partition selection is `fnv1a32(key) % partition_count`. So:

| If your key is… | Then this is ordered |
|---|---|
| The same business id for every message in a stream (e.g. `order_id`) | All messages for that entity, **globally** — because they all land in one partition |
| Empty / absent | Round-robin spread; no ordering relationship between any two messages |
| Random or time-based | Same as empty, but skewed — worse than empty |

**The rule:** ordering is per-key, and per-key ordering only exists because a key pins a partition.

```text
order_id = "A-1001"  ─┐
order_id = "A-1001"  ─┼─▶ partition 2  ──▶ strictly ordered
order_id = "A-1001"  ─┘
order_id = "A-1002"  ───▶ partition 0  ──▶ ordered w.r.t. A-1002 only
```

## What is explicitly NOT guaranteed

| Not guaranteed | Why |
|---|---|
| **Across partitions** | Two partitions are two independent logs with independent writers |
| **Across topics** | Even further apart than partitions |
| **Between a producer's sends if it uses multiple keys** | Different keys may land in different partitions |
| **Global order at the consumer** | A group spreads partitions across consumers; each consumer sees its own partitions in order, the group sees nothing ordered overall |
| **Order across a rebalance for a given consumer** | A consumer may hold partition 0, lose it, and get it back later — the *partition's* order is intact, the *consumer's view* has a gap in the middle |

That last row is the one that surprises people: the log never reorders, but your consumer's processing sequence can have a hole where it did not own the partition.

## Designing around the boundary

1. **Pick the ordering scope first.** "Order per order-id" → put `order_id` in the key and accept that different orders interleave. "Globally ordered" → one partition, and accept that you have thrown away parallelism.
2. **Never process one partition concurrently.** Ownership guarantees one consumer per partition; if that consumer internally fans out, *it* breaks the order the log preserved. Serialize per partition.
3. **Do not expect a rebalance to be invisible to your processing logic.** On `NOTICE ASSIGN` the consumer may start mid-log — resume from `ack_floor`, not from "the last thing I happened to see".
4. **Partition count is fixed at DECLARE.** Changing it later would remap every key to a different partition and destroy all key-based ordering — which is exactly why v0 forbids it.

## How to verify your assumption

```bash
# 1) confirm your key lands in one partition
mortarmq topics list
#   name    partitions  state   created_epoch
#   orders  4           active  1

# 2) confirm a single key's messages are not spread:
#    publish 100 messages with the same key, then check depth per partition —
#    exactly one partition should show the load
```

`mortarmq_partition_depth` with the `topic,partition` labels is the observable form of this: if one key's traffic appears in more than one partition, your key is not doing what you think.

## Related

- Partition selection: [Best practices §1.2](../guides/best-practices.md#_1-2-choose-keys-deliberately)
- Ownership and fencing: [Core concepts §8](./basics.md#_8-epochs-the-fencing-family)
- Rebalance behaviour: [Core concepts §12](./basics.md#_12-rebalance)

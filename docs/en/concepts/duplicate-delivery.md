# Duplicate Delivery

Why the same message can arrive twice, when it will, and what to do about it — because "at-least-once" is only useful if you know *when* the second copy shows up.

## The contract, precisely

MortarMQ guarantees **at-least-once**. That means: a message that was accepted (`PUB_OK` returned) will be delivered **at least once** — and may be delivered more than once. Exactly-once across a consumer group is **not** offered.

The guarantee is asymmetric and that asymmetry is the whole design:

- **Producer side is deduplicated.** Retrying a publish is safe.
- **Consumer side is not.** Processing a message twice is expected; your handler must tolerate it.

## When duplicates happen

| Trigger | What happens | Is it a bug? |
|---|---|---|
| **Lease timeout before the ACK arrives** | `delivery_lease_ms` (30 s) expires; the message is redelivered even though the consumer already handled it | No — the broker cannot distinguish "slow" from "crashed" |
| **Consumer crashes after processing, before the ACK is durable** | The ledger has `DELIVER` but no `ACK`; on restart the timer is rebuilt and the message is redelivered | No — this is exactly why the ledger is separate from the records |
| **Consumer processes and ACKs, then the connection drops** | The ACK may not have reached the broker; redelivery follows | No |
| **Broker `kill -9` mid-flight** | Replay from the ledger restores timers; in-flight deliveries resume | No — this is the case the simulation injects |

The pattern: **every duplicate arises at a point where the broker cannot tell "handled" from "not yet handled".** Rather than guess, it redelivers.

## What to do about it

### Producer: make publishes idempotent

Set **both** `producer_id` and `producer_seq`. The broker deduplicates on the `(topic_id, partition, producer_id)` window, so a retry after a timeout cannot double-write.

```text
producer_id=0 && producer_seq=0    → allowed, counted as non-idempotent
producer_id=0 && producer_seq>0    → rejected, 0x0013
anything else                      → deduplicated by the window
```

### Consumer: use an idempotent handler

Key your side effects on **your business identifier** — an order id, a payment reference — never on `delivery_id`.

> `delivery_id` identifies *one delivery attempt*. It is a fencing token for the consumer side, and it **changes on every redelivery by design**. Using it as a business key guarantees duplicates will slip through.

The standard shape is an idempotent consumer with a dedup table:

1. Receive the message.
2. Check whether `business_key` has already been processed.
3. If yes → ACK and return (no side effect).
4. If no → apply the side effect, record `business_key`, then ACK.

Record the key **before** ACKing, so a crash between step 4's two halves still resolves correctly on redelivery.

## How to detect it

| Signal | What it tells you |
|---|---|
| `mortarmq_group_retries_total` climbing | Redeliveries are happening — expect duplicates downstream |
| `mortarmq_group_in_flight` staying near the window ceiling | Slow processing → lease timeouts → duplicates will follow |
| The same `producer_seq` arriving with different `delivery_id`s | **This is the signature**: same business message, two delivery attempts |

The third row is the definitive test. `delivery_id` differing while `producer_seq` matches is not a bug report — it is the system behaving exactly as specified.

## Related

- Why the ledger survives crashes: [Core concepts §Delivery ledger](./basics.md#_6-delivery-ledger-and-ack-floor)
- The producer idempotency fields: [Protocol §2.1](../reference/protocol.md)
- Handler patterns: [Best practices §1.1 and §2.1](../guides/best-practices.md)

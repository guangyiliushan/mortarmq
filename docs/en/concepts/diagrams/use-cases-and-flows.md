# Use Cases and Activity Flows

Two views of *what happens* in MortarMQ. The use-case diagram says **who** reaches **which goal**; the activity flows say **what the broker does** to get there.

> **Relationship to [Sequences](./sequences.md):** that page draws the same publish/consume link as a message exchange between named participants. This page answers *which branch is taken and what is conserved*; [Sequences](./sequences.md) answers *who speaks to whom in what order*. They are two notations over one link — neither is a subset of the other.

> UML note: mermaid has no native use-case diagram, so `([ ])` capsules stand for use cases and named nodes for actors, with include/extend as dashed edges. Likewise mermaid flowcharts carry the activity-diagram semantics (rounded = action, diamond = decision, parallelism shown as subgraphs).

## Use Cases

```mermaid
flowchart LR
    subgraph Actors["Actors"]
        DEV_PROD["Application developer (producer)"]
        DEV_CONS["Application developer (consumer)"]
        OPS["Operator"]
        JUDGE["Judge / browser user"]
        CLID["CLI user"]
    end

    subgraph MortarMQ["MortarMQ system boundary"]
        UC1(["PUB publish a message"])
        UC2(["SUB subscribe + PULL fetch"])
        UC3(["ACK / NACK acknowledge"])
        UC4(["DECLARE idempotent topic/group creation"])
        UC5(["Incremental consumer-group rebalance"])
        UC6(["View metrics /metrics"])
        UC7(["Health check /healthz"])
        UC8(["CLI management (7 commands)"])
        UC9(["kill -9 crash recovery"])
        UC10(["Browser live-subscribe demo"])
        UC11(["Continue produce/consume across leader failover"])
        UC12(["DLQ dead-letter delivery"])
    end

    DEV_PROD --> UC1
    DEV_PROD --> UC4
    DEV_CONS --> UC2
    DEV_CONS --> UC3
    DEV_CONS --> UC5
    OPS --> UC6
    OPS --> UC7
    OPS --> UC8
    OPS --> UC9
    JUDGE --> UC10
    JUDGE --> UC11
    UC2 -.include.-> UC3
    UC1 -.extend.-> UC12
    UC2 -.extend.-> UC5
```

### Actor × Goal Table (semantic baseline)

The table below, not the picture, is the source of truth for the use cases.

| Actor | Goal | Precondition | Postcondition / exceptions |
|---|---|---|---|
| Producer developer | PUB durably persisted (majority-fsync) | Valid token, healthy quorum | Quorum lost → `READ_ONLY_DEGRADED` (actionable error) |
| Producer developer | Idempotent topic creation | — | Same name + same config → IDEMPOTENT_OK; different config → MISMATCH |
| Consumer developer | Ordered pull + acknowledge | Group already DECLAREd | Credit exhausted → scheduling pauses (nothing silently dropped) |
| Consumer developer | 5 failed attempts route to DLQ | — | DLQ loop detection |
| Operator | Observe health and latency | — | 15-metric allowlist + visible read-only state |
| Operator | Recover after a node crash | — | Automatic re-election / metadata quarantine runbook |
| Judge | Real-time messages + latency in the browser within 5 minutes | `moon run` | — |
| CLI user | Scripted management | Broker reachable | Exit codes 0/2/3/4 |

### v2 Use Cases (outside the MVP boundary)

TLS-encrypted connections, ACL authorization management, dynamic configuration changes, online partition expansion, wildcard subscriptions — see the corresponding interface-reservation entries in the internal design archive.

## Activity Flow A: Publish (including persistence and degradation branches)

```mermaid
flowchart TD
    A["client issues PUB"] --> B["codec decodes the frame"]
    B --> C{"Authenticated? (checked at CONNECT)"}
    C -- "No" --> X1["ERR NOT_AUTHENTICATED (close connection; AUTH_FAILED belongs to the CONNECT stage)"]
    C -- "Yes" --> D{"mode == ReadOnly?"}
    D -- "Yes" --> X2["ERR READ_ONLY_DEGRADED (data-plane semantics; never hidden)"]
    D -- "No" --> E["Resolve topic → route to partition (FNV-1a)"]
    E --> F["storage append + local fsync"]
    F --> G["replication APPEND → followers"]
    G --> H{"quorum flushed (2/3)?"}
    H -- "Yes" --> I["commit: visible[s]=true"]
    I --> J["PUB_OK (commit_seq, leader_epoch)"]
    H -- "No (timeout)" --> K["degrade → ReadOnly + ERR QUORUM_LOST"]
    J --> L["delivery: dispatch to consumers with credit > 0"]
```

## Activity Flow B: Consume and Acknowledge (including redelivery and DLQ)

```mermaid
flowchart TD
    S0["consumer PULL (credit > 0)"] --> S1["delivery picks messages after the ACK floor"]
    S1 --> S2["MSG dispatched (consumes credit)"]
    S2 --> S3{"ACK received?"}
    S3 -- "Yes" --> S4["ledger records ACK (batched fsync) → ack_floor advances"]
    S4 --> S5{"Credit low watermark / 32 msgs / 1 MiB / 20 ms?"}
    S5 -- "Yes" --> S6["client sends CREDIT to return budget"]
    S5 -- "No" --> S0
    S3 -- "Timeout / NACK" --> S7{"retry count < 5?"}
    S7 -- "Yes" --> S8["redeliver (RetryScheduled, backoff)"]
    S8 --> S2
    S7 -- "No" --> S9["write to the DLQ topic (loop detection)"]
    S9 --> S10["dropped_total + 1; conservation P1 holds"]
```

## Key Semantic Notes

1. The conservation intersection of the two flows is CM1: `produced = delivered + dropped + dlq + Δdepth` (over a quiet window).
2. Every error exit (X1/X2/K/S9) is an **actionable error code** — silent drops are not allowed.
3. Concurrency: flows A and B run concurrently across actors; inside the broker, per-partition single-writer coroutines serialize them.

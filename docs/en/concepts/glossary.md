# Glossary

Living glossary of MortarMQ terminology and naming. The governing rule: **same meaning, same name; different meaning, different name.**

## 1. On-Disk Format Magics

Rule: `MM` prefix + a 2–3 letter category code. Every persistent file format gets its own magic; magics are never reused, and the version field immediately follows the magic. **New formats must be registered in this table before they are implemented.**

| Magic | File | Mnemonic |
|---|---|---|
| `MMQS` | Partition segment (message log segment) | **Q**ueue **S**egment |
| `MMQC` | Partition checkpoint | **Q**ueue **C**heckpoint |
| `MMML` | Metadata log (source-of-truth metadata log) | **M**eta **M**utation **L**og |
| `MMMS` | Metadata snapshot (`mmms-<offset>-<epoch>.bin`) | **M**eta Meta**s**tate |
| `MMLQ` | Delivery ledger (`delivery.mql`) | **L**edger (**Q**ueue delivery semantics) |
| `MMCU` | Cursor checkpoint (`cursor.mqc`) | **Cu**rsor |
| `MMDL` | DLQ envelope | **D**ead **L**etter |
| `MMCUP` | Follower catch-up state | **C**atch-**up** |

> Historical erratum: the object diagram once mistyped `MMRS` (corrected to `MMQS` on 2026-10-01). This table is the yardstick for catching such errors.

## 2. Epoch / Sequence Naming

The easiest naming pairs to get wrong in this project:

| Term | Semantics |
|---|---|
| `cluster_epoch` | Static membership-configuration version |
| `leader_epoch` | Replication-group leader version (increments after Prepare/Install); the fencing boundary |
| `promised_leader_epoch` | Locally persisted promise watermark |
| `membership_epoch` | Version of the **member set** (increments on join/leave/subscription change) |
| `assignment_epoch` | Target-assignment version |
| `installed_assignment_epoch` | The assignment version a **member has installed** (⚠️ formerly `member_epoch`; renamed 2026-10-01 because it differed from `membership_epoch` by only 4 characters while being semantically orthogonal. The wire field name remains `assignment_epoch`) |
| `ownership_epoch` | Single-partition ownership version (consumer-side fencing) |
| `cursor_epoch` | Cursor-checkpoint version |
| `mutation_id` | Monotonic metadata-mutation number (failover floor) |
| `commit_seq` / `visible_seq` | Quorum commit point / consumer-visible ceiling |
| `last_appended` / `flushed_seq` | Local write point / local durability point |
| `ack_floor` / `next_scan` / `first_retained_seq` | Contiguous-ack watermark / scan position / retention start |
| `delivery_id` | Id of one delivery instance (consumer-side fencing — **not** the business idempotency key) |
| `producer_id` / `producer_seq` | Producer idempotency key (use this pair for business dedup, not `delivery_id`) |

## 3. ID System Map

The numbered IDs that recur across this site. Each one is either defined on a page that ships here or labels something on a page that ships here — no ID in this documentation refers to a document outside this repository.

| Prefix | Meaning |
|---|---|
| `UC1`–`UC12` | Use cases ([diagrams](./diagrams/)) |
| `INV-001`…`INV-014` | Invariant register (single source of truth across all three methodologies) |
| CM / CB / CL / CF / CS / CQ | Property suites: metrics conservation / rebalance / clock / frame / client state machine / quorum consistency |
| Golden n | Per-component golden cases |
| `P0` / `P1` / `P2` | Priority tier: P0 blocks the work that depends on it, P1 must close before that work starts, P2 needs a probe first |
| `0x0/2/4/6xxx` | Four error-code segments (protocol / metadata / backpressure / replication) — see [Error Code Registry](../reference/errors.md) |

## 4. Backlog

To be added as they stabilize: the 18 config allowlist names, the 15 metric names, and the TSV column names for the 7 CLI commands. All three are machine-readable; this glossary only hosts abbreviations that recur in conversation.

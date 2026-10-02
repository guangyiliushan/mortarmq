# Operations Runbook

Who does what within how many steps when something breaks — start/stop, the 3-node topology, read-only/quarantine handling, backup and restore.

> **Source of truth:** RB-1's trigger table is **frozen design**, not implementation status. RB-2 / RB-3 follow the same template and are filled as their implementations land.

## How to read an entry

Every entry answers five questions in order: **what alerted me → what changed for readers → what the broker already did → what I type → how do I know it worked.** If an entry cannot answer the last one, it is not finished.

## RB-1: Quorum degraded → read-only

**Alert source:** `mortarmq_quorum_state` leaves `0` (healthy), or `mortarmq_leader_epoch` stops advancing. **Blast radius:** producers get errors; the consumer-visible ceiling (`commit_seq`) freezes — it never regresses.

### Trigger table

| Level | Condition | total | in-sync | min ISR | Producer response | Consumer visibility | Client error | Operator action |
|---|---|---:|---:|---:|---|---|---|---|
| 2 | leader + at least 1 follower flushed within hard gap | 3 | 2 | 2 | `OK durability=quorum` | `commit_seq` | none | normal |
| 1 | quorum possible but one follower lag > soft gap | 3 | 2 | 2 | `OK durability=quorum` + `FOLLOWER_LAG` warning | `commit_seq` | `FOLLOWER_LAG` | start catch-up and monitor |
| 0 (soft timeout) | quorum ack not completed in timeout | 3 | 2 | 2 | `ERR READ_ONLY_DEGRADED` | `commit_seq` frozen | `READ_ONLY_DEGRADED` | inspect follower disk / network |
| 0 (no follower) | no follower flushed within hard gap | 3 | 1 | 2 | `ERR IN_SYNC_REPLICAS_NOT_ENOUGH` | `commit_seq` frozen | `IN_SYNC_REPLICAS_NOT_ENOUGH` | **repair the follower before writes resume** |
| −1 (explicit) | operator sets `min_in_sync=1` and explicitly enables degraded ack | 3 | 1 | 1 | `OK durability=min_iris` | implementation must define; **default not implemented** | none | explicit, unclean-risk acknowledgement |
| −2 (conflict) | divergence at or below `commit_seq` | 3 | n/a | 2 | `ERR QUARANTINED` | partition quarantined | `DIVERGENT_COMMITTED` | manual reconcile from audit logs |

### What the broker already did

Levels 0 and above need **no manual intervention to protect data** — the broker stopped accepting writes rather than acknowledging something it cannot commit. That is the whole point: the failure mode is a visible error, not silent data loss.

The only level that needs a human *before* normal operation resumes is **0 (no follower)**: `min ISR` is 2 and only 1 replica is in sync, so writes are rejected until a follower is repaired.

### Manual steps

1. Confirm which level you are on — `mortarmq leader get` prints `leader_id`, `leader_epoch`, `quorum_state`.
2. If level 0 (soft timeout): inspect follower **disk and network** — fsync latency is the usual culprit, and `mortarmq_partition_last_seq` on the follower will show it stalling.
3. If level 0 (no follower): repair the follower first, wait for catch-up, **then** resume writes.
4. If level −2: do not restart anything. Reconcile manually from the audit logs; an automatic answer here is a wrong answer.

### Verify recovery

- `mortarmq leader get` → `quorum_state` back to `0`, `leader_epoch` unchanged or advanced by exactly one election.
- `mortarmq_broker_uptime_seconds` still climbing (the process was never restarted).
- `mortarmq_quorum_state` gauge = `0` on `/metrics`.

### Escalation

Manual intervention on the metadata log is required only at level −2. Anything else that does not recover within one catch-up window goes to RB-2 (metadata quarantine).

## RB-2: Metadata quarantine handling

- **Trigger:** `0x2004 METADATA_QUARANTINED`, or a `quarantine/` directory under `data/metadata/`.
- **Automatic:** the broker already isolated the partition and stopped serving it (level −2 above).
- **Manual:** `data/metadata/quarantine/` holds the rejected state for inspection, never for automatic replay.

## RB-3: `kill -9` leader recovery

- **Trigger:** the leader process disappears without a shutdown.
- **Automatic:** on restart the broker replays the segment log and the delivery ledger; redelivery timers are rebuilt from the ledger, so at-least-once survives the crash.
- **Manual:** confirm the recovered `leader_epoch` with `mortarmq leader get`.

::: warning Without code yet
No broker runs today, so no entry has been exercised. The trigger table is frozen design and the three entries are the shape each future entry must take — the `Verify recovery` step is the part that must never be left blank.
:::

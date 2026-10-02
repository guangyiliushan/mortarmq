# Production Checklist

Tick every line before a cluster carries traffic you care about. Each item names what to check, why it matters, and how to verify it.

> Most items are configuration decisions already frozen in the [allowlist](../reference/configuration.md) — this page is where they get applied together, in the order that fails cheapest first.

## 1. Network exposure

- [ ] **`listen_peer` is firewalled from the internet.** It carries replication traffic with an independent shared secret and *no client authentication*. Exposing it is the single worst mistake available.
- [ ] **`listen_admin` binds `127.0.0.1`.** The metrics surface has **no authentication in v0** — a wider bind publishes your queue depths and topology to whoever can reach the port.
- [ ] **`listen_client` binds what you intend.** `0.0.0.0` is correct only behind a firewall or a private network.
- [ ] **`ws_origins` is an explicit list**, not empty. Empty rejects *every* origin (safe, but the browser demo will not work); it is never "allow all".

```bash
# verify from outside the host
ss -tlnp | grep -E '7188|7189|7190'
# expect: 7188 client-facing, 7189 peer-only, 7190 on 127.0.0.1
```

## 2. Identity and access

- [ ] **Each node has a distinct `node_id`** and shares an identical `peers` table.
- [ ] **The token is provisioned out of band** and stored server-side only as a `SHA-256` digest.
- [ ] **You accept that v0 has no authorization.** Any client holding the token can publish to and consume from any topic. If that is not acceptable, v0 is not — see [Security](../concepts/security.md).
- [ ] **You accept that v0 has no TLS.** On an untrusted network, tunnel it.

## 3. Storage and capacity

- [ ] **One `data_dir` per node, on separate failure domains.** Shared volumes corrupt each other's segments.
- [ ] **Disk sized for the whole retention window — because there is no retention.** v0 does **not** truncate logs or run an automatic retention executor. `data_dir` grows until it fills, and a full disk is an availability outage, not a graceful degradation. Plan `expected_throughput × days` before launch and alert well before 100%.
- [ ] **The filesystem supports fsync semantics you expect.** Durability rests on `fsync`; network filesystems that acknowledge without flushing break the guarantee silently.
- [ ] **Sustained write throughput fits the fsync budget.** The design budget is `P50 ≤ 1.5 ms / P99 ≤ 5 ms` end-to-end with NVMe fsync dominating — verify against your hardware, do not assume.

## 4. Monitoring and alerting

- [ ] **`/metrics` scraped** and `metrics_enabled=true`.
- [ ] **Alert on `mortarmq_quorum_state != 0`** — this is the page-the-oncall signal. Level `1` is a warning (one follower lagging), level `2` is read-only.
- [ ] **Alert on `mortarmq_group_lag` growing monotonically** — a consumer that has stopped, not a slow one.
- [ ] **Alert on disk usage**, since nothing will reclaim it automatically.
- [ ] **Check the conservation identity daily** rather than trusting individual counters:
  `produced = delivered + dropped + dlq + Δdepth`
- [ ] **`mortarmq_partition_last_seq` decreasing is an incident**, not a blip — the design calls a decrease `fatal`.

## 5. Failure handling

- [ ] **[Runbook RB-1](./runbook.md#rb-1-quorum-degraded-→-read-only) is printed or pinned** — quorum loss is the first thing that happens at 3 a.m., and the correct response is *do not restart the leader*.
- [ ] **You know the difference between level 0 (soft timeout) and level 0 (no follower)** — the second needs a repaired follower before writes resume.
- [ ] **`data/metadata/quarantine/` is monitored.** Quarantine is deliberate and never auto-replayed; a human reconciles.
- [ ] **A `kill -9` drill has been run at least once**, and `leader get` afterwards showed an epoch bump, not data loss.

## 6. Upgrades

- [ ] **[Downgrade pre-check](./upgrade.md#downgrade-pre-check) understood** before the first upgrade — case R2 *refuses* an incompatible downgrade by design.
- [ ] **You know which tier you are in** (compatible vs incompatible). This decides whether a rollback is even possible.

## 7. Backups

- [ ] **The metadata log and its snapshots are backed up** — `data/metadata/` holds cluster truth (topics, groups, leaders).
- [ ] **Segment backups are a decision, not a default.** Backing up segments doubles write amplification; most teams instead rely on replication and accept that a full-cluster loss requires a rebuild. Choose consciously.

::: warning Without code yet
No item here has been exercised. The checklist is assembled from frozen design decisions, and every item that has a verification command is one the broker owes you when it ships.
:::

## Related

- Every key referenced above: [Configuration](../reference/configuration.md)
- What to do when an alert fires: [Runbook](./runbook.md)
- Metrics and their meaning: [Metrics](../reference/metrics.md)

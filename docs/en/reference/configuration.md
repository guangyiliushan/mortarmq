# Configuration

How operators write and validate broker configuration — every key of the allowlisted set.

> **Source of truth:** the 18-key allowlist is **frozen design**, not implementation status — a key appears here because a reason for it was written down first ("no rationale, no key"), not because a broker already reads it.

## Frozen Decisions

- Format: **JSON** (straight to `moonbitlang/core` json); a `_comment` key array at the top of the file carries human notes.
- Parsing is fail-fast: **unknown keys are rejected** (any key outside the allowlist fails CI); no hot reload (v0 boundary).
- **All 18 keys are `update_mode = read-only`** — a placeholder for a three-tier update taxonomy (read-only / hot-reload / dynamic); no key can change without a restart in v0.

## The Allowlist (18 keys)

| # | Key | Type | Default | Why it must exist | update_mode |
|---:|---|---|---|---|---|
| 1 | `node_id` | `u16` | statically assigned | Cluster identity and the primary key of the static membership table — replication and leader election cannot address a node without it | read-only |
| 2 | `peers` | `[node_id; addr]` | 3-entry static table | v0 is a static 3-node cluster; membership changes belong to v2 (Redpanda's members management has already shown how complex that gets) | read-only |
| 3 | `leader_priority` | `u16[]` | in `peers` order | Static preferred-leader choice; the deterministic source for lease-timeout demotion | read-only |
| 4 | `listen_client` | `addr` | `0.0.0.0:7188` | Entry point for the client wire protocol | read-only |
| 5 | `listen_peer` | `addr` | `0.0.0.0:7189` | Entry point for replication + heartbeat; kept separate from client traffic | read-only |
| 6 | `data_dir` | `path` | `./data` | Root of every segment / metadata / snapshot; the only persisted location | read-only |
| 7 | `segment_max_bytes` | `u64` | `67108864` (64 MiB) | Segment rotation boundary; without it segments grow without bound | read-only |
| 8 | `partition_default_count` | `u16` | `4` | Default when DECLARE does not specify one; ignored when a count is given explicitly | read-only |
| 9 | `delivery_max_attempts` | `u32` | `5` | Retry ceiling — the last chance before the DLQ | read-only |
| 10 | `delivery_lease_ms` | `u32` | `30000` | Message lease; timeout redelivery is the liveness source of at-least-once | read-only |
| 11 | `poll_max_wait_ms` | `u32` | `5000` | Long-poll upper bound; stops connections hanging idle | read-only |
| 12 | `credit_initial_count` | `u32` | `256` | Initial credit window (count); `credit_bytes` = 2 MiB is derived from the same ratio. **Post-freeze revision:** the earlier `64` and its old name are void | read-only |
| 13 | `metadata_snapshot_records` | `u32` | `8192` | Snapshot threshold; without it the metadata log replays without bound | read-only |
| 14 | `metrics_enabled` | `bool` | `true` | The `/metrics` switch; turning it off saves sampling overhead | read-only |
| 15 | `log_level` | `enum` | `info` | The minimum needed for troubleshooting — everything beyond that belongs in `/metrics` | read-only |
| 16 | `listen_ws` | `addr` | **disabled** (optional) | The browser demo needs a WebSocket listener; off by default, and `wss` is a reserved slot | read-only |
| 17 | `listen_admin` | `addr` | `127.0.0.1:7190` | Admin HTTP entry (`/metrics` `/healthz` `/stats` + CLI read paths), bound to localhost by default | read-only |
| 18 | `ws_origins` | `[str]` | `localhost` / `127.0.0.1` allowlist | WebSocket Origin allowlist (an empty list rejects everything); blocks cross-site WebSocket hijacking | read-only |

### Naming note

`listen_client` is the key's name, **not** `listen_tcp`. Both authoritative sources — this allowlist and the WebSocket minimal spec ("same process, different port") — use `listen_client`; the distinction matters because the same process also exposes `listen_peer` and `listen_admin`.

## Entry Template (every key carries all fields)

| Field | Type | Default | Rationale | update_mode |
|---|---|---|---|---|
| … | | | | read-only |

## Rejection Example

```json
{ "listen_https": "…" }
```

→ startup rejected: `unknown key: listen_https` (outside the allowlist).

::: warning Without code yet
No broker reads this file today. Every default above is a **frozen design value**; when the config parser lands, these 18 keys are the acceptance bar — a key outside this table must fail startup, and a key in this table that the parser does not know is a defect in the parser.
:::

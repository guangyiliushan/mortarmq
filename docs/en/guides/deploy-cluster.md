# Deploy a Cluster

How to stand up a 3-node MortarMQ cluster — the topology, the ports, startup order, and how to tell each step succeeded.

> **Source of truth:** ports, keys and the peer table come from the [configuration allowlist](../reference/configuration.md). Commands are marked `TODO` until the broker executable lands.

## Choose a topology first

MortarMQ v0 ships **one** supported topology. This is a deliberate cut, not an omission:

| Topology | v0 | Why |
|---|---|---|
| Single node | ✅ dev only | No quorum, so `durability=quorum` is meaningless — fine for a demo, wrong for anything you care about |
| **3-node static cluster** | ✅ **supported** | Majority-fsync quorum; the smallest size where "survive one node dying" is actually true |
| 5+ nodes | ❌ | `min ISR` grows the write path cost for no v0 benefit |
| Dynamic membership (add/remove nodes at runtime) | ❌ v2 | Redpanda's members management has already shown how complex this gets — see `peers` |

**Trade-off you are accepting:** the peer table is static. Bringing up a fourth node requires a config change and a restart, not a join request.

## Ports

| Key | Default | Bound to | Carries |
|---|---|---|---|
| `listen_client` | `0.0.0.0:7188` | all interfaces | client wire protocol (producers, consumers, CLI write paths) |
| `listen_peer` | `0.0.0.0:7189` | all interfaces | replication + heartbeat — **never** exposed to clients |
| `listen_admin` | `127.0.0.1:7190` | **localhost only** | `/metrics` `/healthz` `/stats` + CLI read paths |
| `listen_ws` | disabled | — | browser demo WebSocket; enable explicitly |

The admin listener binding to localhost is not a convenience — it is the control that keeps the observability surface off the network (see the [threat model](../concepts/security.md)). `listen_peer` being a separate port is what lets you firewall replication away from clients.

## Startup order

**1) Config each node** — distinct `node_id`, the same 3-entry `peers` table on all three, distinct `listen_*` ports if they share a host.

```bash
# TODO: one config.json per node; see reference/configuration for all 18 keys
```

**2) Start the three brokers**

```bash
# not runnable yet -- the broker package has no main.
```

**3) Verify each node came up** — this is the step people skip:

```bash
# TODO: mortarmq broker status
# expected: node_id  uptime_s  connections  version  — uptime_s > 0, version matches the binary
```

> **Verification rule:** a process that started is not a node that joined. `broker status` answers "did it come up"; only the next command answers "is it in the cluster".

**4) Verify quorum and identify the leader**

```bash
# TODO: mortarmq leader get
# expected: leader_id  leader_epoch  quorum_state=0
```

`quorum_state=0` is healthy. `1` means one follower is lagging (still serving writes) and `2` means read-only — see [RB-1](./runbook.md#rb-1-quorum-degraded-→-read-only) for what to do about each.

**5) Then create a topic and move a message** — see [Quick start](../getting-started/quickstart.md).

## Bring-down order

Stop followers first, leader last. Stopping the leader first forces an election, which works but adds an epoch bump you then have to explain in `leader get` output.

## Common deployment mistakes

- **Exposing `listen_peer` to the internet.** It carries replication traffic with an independent shared secret and no client authentication. Firewall it.
- **All three nodes sharing one `data_dir`.** They will corrupt each other's segments.
- **Skipping step 3.** `nohup` returning is not success — check `uptime_s`.
- **`listen_admin` on `0.0.0.0`** "to make the dashboard easier". The metrics surface has no authentication in v0.

::: warning Without code yet
No command above runs today. What is already fixed: the topology choice, all four ports, the bind addresses, and the verification each step must perform. The commands are the contract the broker has to satisfy.
:::

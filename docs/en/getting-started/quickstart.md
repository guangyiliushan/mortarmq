# Quick Start

Get a running MortarMQ loop. This page is a **tutorial** — read it top to bottom, do not skip steps.

> **Status:** step 1 runs today; steps 2–5 are the contract the broker must satisfy when it lands. Each unimplemented step says exactly what success will look like, so you can verify it the day it ships.

## Before you start

| Need | Why | Check |
|---|---|---|
| MoonBit toolchain `moonc >= 0.10.14` | Everything here compiles with it | `moon version --all` |
| Git | To clone | `git --version` |
| A modern browser | Only for step 5 | — |

Nothing else. There is no database, no ZooKeeper, no Docker.

## Step 1: Clone and verify the toolchain (runs today)

```bash
git clone https://github.com/guangyiliushan/mortarmq
cd mortarmq
moon check --deny-warn --target all
moon test
```

**You will see:**

```text
# moon test → all green
# the protocol package's golden suite and property tests are the entry bar:
#   - error-code registry lock (every registered code, no gaps)
#   - constant lock (MAX_FRAME_LEN and friends cannot drift)
#   - decode-injectivity property (seed=20261001)
```

If `moon test` fails here, stop — everything downstream depends on this suite being green.

## Step 2: Start a 3-node broker (contract)

```bash
# not runnable yet -- the broker package has no main.
```

**How you will know it worked:**

```bash
mortarmq broker status
# expect: node_id  uptime_s  connections  version
#         uptime_s > 0, version matches the binary you launched
```

> **A started process is not a joined node.** `broker status` answers "did it come up"; only `leader get` answers "did it join the quorum".

```bash
mortarmq leader get
# expect: leader_id  leader_epoch  quorum_state=0
```

`quorum_state=0` means healthy. `1` means a follower is lagging, `2` means read-only — both are explained in the [Runbook](../guides/runbook.md).

## Step 3: Create a topic and publish (contract)

```bash
mortarmq topics create orders --partitions 4
# expect: created | existed   + topic_id
# exit 0 on success, 4 if the server refused
```

```bash
# publish one message through the client library, then:
mortarmq topics list
# expect columns: name  partitions  state  created_epoch
#   orders  4  active  1
```

**How you will know it worked:** `state=active`, and `mortarmq_topic_messages_produced_total{topic="orders"}` reads `1`.

## Step 4: Consume it (contract)

```bash
# consumer joins group "billing", pulls, ACKs
# expect: the message arrives exactly once in the normal path;
#         if the broker restarts mid-flight, it may arrive again — that is
#         at-least-once, not a bug (see Delivery guarantees)
```

**How you will know it worked:**

```text
mortarmq_group_lag{topic="orders",group="billing"}  0   ← drained
mortarmq_topic_messages_delivered_total{topic="orders"}  1
```

`lag` returning to `0` is the signal that the loop closed.

## Step 5: Browser demo (contract)

The demo page ships with this docs site at `/demo/` and connects over `ws://`. Two config keys gate it and **both** are off by default:

```json
{ "listen_ws": "0.0.0.0:7188", "ws_origins": ["http://localhost:4173"] }
```

An empty `ws_origins` rejects **every** origin — it is not "allow all". See [Troubleshooting §6](../guides/troubleshooting.md#_6-browser-demo-cannot-connect).

## What happened

`topics create` is an idempotent `DECLARE` — running it twice returns `existed`, not an error. The publish went through the 15-op wire protocol, was fsync'd and replicated to a majority before `PUB_OK` returned, and the consumer's `ACK` advanced `ack_floor`, which is what `partition_depth` measures against.

## Common first-run problems

| Symptom | Cause | Fix |
|---|---|---|
| `moon: command not found` | Toolchain not on `PATH` | Reinstall from <https://cli.moonbitlang.com> |
| `moon test` red on step 1 | Broken local state or a real regression | `moon clean && moon test`; if still red, file an issue |
| `unknown key: listen_https` at step 2 | Config has a key outside the 18-key allowlist | [Troubleshooting §1](../guides/troubleshooting.md#_1-startup-refuses-unknown-key) |
| `0x0008 UNKNOWN_TOPIC` at step 3 | SUB does not implicitly DECLARE | Run `topics create` first — [Troubleshooting §2](../guides/troubleshooting.md#_2-0x0008-unknown-topic) |

## Where to go next

- Understand what happened → [Core concepts](../concepts/basics.md)
- Deploy it for real → [Deploy a cluster](../guides/deploy-cluster.md)
- Look up an exact value → [Reference](../reference/index.md)

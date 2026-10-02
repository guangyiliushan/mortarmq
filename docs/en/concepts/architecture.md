# Architecture

How the modules fit together, the dependency rules that keep them decoupled, and where to find the full diagram atlas.

## Which package am I in?

Read the change you want to make, then go to exactly one package:

| If you are changing… | You are in | Because |
|---|---|---|
| Frame layout, an op, an error code | `protocol/` | It is the single source of truth; every other package consumes it and nothing may define its own |
| How bytes reach disk — segments, index, checkpoints | `storage/` | Deliberately standalone and reusable, with no knowledge of topics |
| Topic names, partitions, routing, consumer groups | `broker/` | Owns the in-memory view; never writes bytes itself |
| Replication, leases, elections | `cluster/` | Talks over `listen_peer` only — a different port from clients, on purpose |
| Anything a client library does | `client/` | One library, three forms (native / JS backend / wasm-gc pure core) |
| A benchmark or a `kill -9` injection | `bench/` | Test-only; production code must not import it |
| A dev utility (`hash-token`, dump) | `tools/` | Never on a hot path |

If your change needs two of these packages, that is a signal the seam is wrong — see the dependency rules below before reaching for a new import.

## Source Package Layout

| Package | Responsibility | Key design |
|---|---|---|
| `protocol/` | Frame codec + op state machine (target: < 32 KB of logic) | Single source of truth; golden frames |
| `storage/` | Segment log engine (standalone, reusable) | 64 MiB rotation + sparse index + atomic checkpoints |
| `broker/` | Topics / partitions / consumer groups / routing | Immutable routing snapshots |
| `cluster/` | Quorum replication + static membership + leases | Majority-fsync; epoch fencing |
| `client/` | Client library, three forms | native / JS backend / wasm-gc pure core |
| `bench/` | Benchmarks + `kill -9` injection | Benchmark matrix |
| `tools/` | Dev tools: hash-token, dump, and friends | — |

## Module Dependency Rules (import assertions)

- One direction only: `storage` / `broker` / `cluster` / `client` → `protocol`. Cross-cutting abstractions (`Conn` / `Clock` / `Net` / `Disk` / `Rng`) go through traits.
- The `moon info --target …` diff gate is the import-assertion enforcer; dependencies outside the allowlist may not merge.

## Diagram Atlas (Mermaid)

Four pages grouped by what they answer — see the [atlas index](./diagrams/) for the full inventory, including which prose tables carry information no diagram shows.

1. [Use cases and flows](./diagrams/use-cases-and-flows.md) — actors × goals, publish and consume control flow
2. [Sequences](./diagrams/sequences.md) — publish→deliver, incremental rebalance, lease-timeout election
3. [States, timing and invariants](./diagrams/states-timing-invariants.md) — three state machines, latency budgets, runtime snapshot
4. [Structure](./diagrams/structure.md) — package decomposition, dependency rules, core types

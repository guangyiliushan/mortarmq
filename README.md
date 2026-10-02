# MortarMQ

[![CI](https://github.com/guangyiliushan/mortarmq/actions/workflows/ci.yml/badge.svg)](https://github.com/guangyiliushan/mortarmq/actions/workflows/ci.yml)
[![License: BSD-3-Clause](https://img.shields.io/badge/License-BSD%203--Clause-blue.svg)](./LICENSE)

**MortarMQ** is a message queue written in MoonBit: partitioned topics, at-least-once delivery with dead-letter handling, consumer groups, and a binary wire protocol, in one codebase that compiles to native, JavaScript and WebAssembly.

> **Today:** the wire protocol package has landed — frame constants and the error-code registry, tested on native, JS, wasm and wasm-gc. The broker, storage and client libraries are designed and documented but not yet written.

## Design

- **The delivery ledger is a file of its own, separate from the messages.** Redelivery timers are not derived from the log, so a `kill -9` cannot lose one; replay rebuilds them.
- **A rebalance moves only what changed.** A consumer leaving takes its partitions with it and nobody else's assignment is touched.
- **The broker coordinates itself.** Metadata lives in a mutation log with periodic snapshots — no external metadata service, no Raft. Ownership is fenced by epoch, so a stale consumer can never write.
- **Consumers pull against a credit window.** Flow control is decided next to the messages rather than queued somewhere else.
- **One client library, three targets** — native, browser over WebSocket, and a wasm-gc pure core.

v0 is a single process. Three-node clustering with a majority-fsync quorum and lease-based failover is a stretch goal, not the mainline. TLS, configuration hot reload, dynamic membership, dynamic tokens and topic wildcards are out of scope for v0; each has a recorded upgrade path in [the upgrade guide](./docs/en/guides/upgrade.md).

## Quick Start

```bash
# MoonBit toolchain, moonc >= 0.10.14: https://cli.moonbitlang.com
git clone https://github.com/guangyiliushan/mortarmq
cd mortarmq
moon check --deny-warn --target all
moon test --target all
```

The user-facing walkthrough is [Quick start](./docs/en/getting-started/quickstart.md).

## Documentation

Site: <https://guangyiliushan.github.io/mortarmq/> · 中文版 [docs/cn/](./docs/cn/) · release notes: [Releases](https://github.com/guangyiliushan/mortarmq/releases)

- **Get something running** — [Getting started](./docs/en/getting-started/)
- **Understand how it works** — [Concepts](./docs/en/concepts/)
- **Operate it** — [Guides](./docs/en/guides/)
- **Look up an exact value** — [Reference](./docs/en/reference/)
- **Change the code** — [Develop](./docs/en/develop/)

## Contributing

Read [CONTRIBUTING.md](./CONTRIBUTING.md). By contributing you agree to the [ICLA](./ICLA.md).

## License

BSD-3-Clause — [LICENSE](./LICENSE). Third-party sources and attributions: [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md).

---
layout: home

hero:
  name: MortarMQ
  text: A message queue built natively in MoonBit
  tagline: The full MQ loop — protocol access, produce/consume, partitioned topics, at-least-once delivery (DLQ), durable crash recovery
  actions:
    - theme: brand
      text: Quick Start
      link: /en/getting-started/quickstart
    - theme: alt
      text: Wire Protocol (v0)
      link: /en/reference/protocol
    - theme: alt
      text: 30-second demo
      link: /demo/

features:
  - title: 15-op wire protocol
    details: 9 core + 6 extension ops; frame [u32_be len][u8 op][payload]; four-segment error-code registry; codec golden suite green as the entry bar.
  - title: At-least-once delivery
    details: Delivery ledger separated from records; 5 retries → DLQ; kill -9 replay recovery guarded by deterministic simulation.
  - title: Incremental rebalance
    details: Broker-side coordinator; membership/assignment/member epochs; only affected partitions ever move.
  - title: Honest boundaries
    details: v0 ships without TLS / hot reload / authz / Raft metadata — every cut comes with a documented upgrade path.
---

## How this documentation is organised

The site is ordered by **what you are trying to do**, not by who you are. Each chapter is a distinct kind of document; pick the one that matches your task and skip the rest.

| Chapter | Read it when… | Start at |
|---|---|---|
| **[Getting Started](./getting-started/index.md)** | You want a running loop as fast as possible | [Quick start](./getting-started/quickstart.md) |
| **[Concepts](./concepts/index.md)** | You want to understand why the system behaves this way | [Architecture](./concepts/architecture.md) |
| **[Guides](./guides/index.md)** | You have a specific operational task — deploy, upgrade, recover | [Runbook](./guides/runbook.md) |
| **[Reference](./reference/index.md)** | You need an exact value — a frame layout, a config key, an exit code | [Protocol](./reference/protocol.md) |
| **[Develop](./develop/index.md)** | You are changing the code or opening a pull request | [Testing](./develop/testing.md) |

New here? [Quick start](./getting-started/quickstart.md) → [Architecture](./concepts/architecture.md) → come back to this table.

::: tip Translations
The two languages are first-class: [`/en/`](./index.md) and [`/cn/`](../cn/index.md) are parallel trees with identical file names, and `/` is a chooser. Code fences (mermaid, ASCII timelines, spec notation) and the `reference/` tables stay English in **both** — identifiers, config keys, CLI subcommands and error codes are English by project convention.
:::

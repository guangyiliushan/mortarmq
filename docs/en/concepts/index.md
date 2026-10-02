# Concepts

This chapter explains how MortarMQ works and why it is built that way. Read it once after the quick start, then return to individual pages when a behaviour surprises you.

Everything here is narrative — no copy-paste commands. For those, see [Guides](../guides/index.md); for exact tables and registries, see [Reference](../reference/index.md).

## In this chapter

| Page | What it answers |
|---|---|
| [Core concepts](./basics.md) | The message model — topic, partition, group, epoch, credit, quorum, DLQ: what each noun means |
| [Architecture](./architecture.md) | What the source packages do, which way dependencies point, and where the [diagram atlas](./diagrams/) lives |
| [Message loss](./message-loss.md) | Under exactly what conditions a message can be lost, and the identity that proves it did not |
| [Duplicate delivery](./duplicate-delivery.md) | When the second copy arrives, and how to make a handler tolerate it |
| [Ordering](./ordering.md) | What order is guaranteed, where it stops, and how to design around the boundary |
| [Security](./security.md) | What v0 defends against, what it explicitly does not, and how the token handshake works |
| [Glossary](./glossary.md) | The naming rules: magic bytes, the eight epoch-like counters, the ID system |

## Planned pages

These land with the corresponding implementation and will be linked from here when they do:

- **Storage internals** — segment format, sparse index, checkpoint replay (the concepts page covers the behaviour; this would cover the bytes)

## Related chapters

- The 9 mermaid diagrams that back these pages: [Diagram atlas](./diagrams/)

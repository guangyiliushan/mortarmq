# Reference

Look-up material. Nothing here is meant to be read end to end — every page is a table, a registry or a specification you consult and leave.

If you are learning the system rather than looking something up, start at [Concepts](../concepts/index.md) instead.

## In this chapter

| Page | What it specifies |
|---|---|
| [Protocol](./protocol.md) | **Single source of truth** for the v0 wire protocol: frame format, the 15-op table, field semantics, versioning rules |
| [Error codes](./errors.md) | The 49-code registry across four segments, each row with the "what the client should do" column |
| [Configuration](./configuration.md) | The JSON allowlist — type, default, rationale and update mode for every key |
| [CLI](./cli.md) | The 7 commands, TSV column order, exit codes and `--api-version` |
| [Metrics](./metrics.md) | The 15-metric allowlist on `/metrics`, `/healthz` and `/stats` |
| [API](./api/) | Generated public API reference (`moon doc`) |

## Error codes

Error codes live on their own page — [Error Code Registry](./errors.md) — as four registered segments (`0x0xxx` protocol, `0x2xxx` metadata, `0x4xxx` backpressure, `0x6xxx` replication), each row carrying the "what the client should do" column. They are split out of [Protocol](./protocol.md) because reading them is a *lookup* ("I got 0x0024, what do I do"), not a sequential read of the specification.

## Contracts that make reference pages trustworthy

- Every config key outside the allowlist is rejected at startup — the table cannot silently drift from the code.
- TSV column order is locked by golden tests; changing it requires a `--api-version` bump.
- Metrics outside the 15-name allowlist are rejected at review.

Breaking any of these means the corresponding reference page is wrong, and that is a failing test, not a documentation bug.

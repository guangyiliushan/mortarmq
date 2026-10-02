# Guides

Task-oriented instructions. Each page answers one "how do I…" question and assumes you already know what a topic, a consumer group and an epoch are — if not, read [Concepts](../concepts/index.md) first.

Unlike [Getting Started](../getting-started/index.md), these pages do not form a sequence. Find your task in the table, do it, leave.

## In this chapter

| I want to… | Page |
|---|---|
| Stand up a 3-node cluster — ports, startup order, verification | [Deploy a cluster](./deploy-cluster.md) |
| Tick every line before carrying real traffic | [Production checklist](./production-checklist.md) |
| Handle a broker failure — quorum loss, metadata quarantine, `kill -9` recovery | [Runbook](./runbook.md) |
| Turn an error code into a fix | [Troubleshooting](./troubleshooting.md) |
| Upgrade or roll back without breaking clients | [Upgrade](./upgrade.md) |
| Write a producer or consumer the right way | [Best practices](./best-practices.md) |
| Get a straight yes/no answer about behaviour | [FAQ](./faq.md) |

## Planned pages

- **Manage topics and consumer groups** — create, list, describe, delete
- **Observe** — reading the 15-metric allowlist, what to alert on
- **Back up and restore** — segment files, metadata log and snapshots

## Related chapters

- Exact command syntax and exit codes: [CLI](../reference/cli.md)
- Metric names, types and conservation properties: [Metrics](../reference/metrics.md)

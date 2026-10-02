# CLI

How operators and scripts drive the `mortarmq` CLI — the 7 commands, stable TSV column order, exit codes, and `--api-version`.

> **Source of truth:** design-frozen; no command exists until the CLI lands.

## Read the exit code, not the text

```bash
mortarmq topics list --topic orders >/dev/null 2>&1
case $? in
  0) echo "ok" ;;
  2) echo "bad arguments — fix the invocation" ;;
  3) echo "service unreachable — is the broker up?" ;;
  4) echo "server refused — see the error text" ;;
esac
```

Four codes, one meaning each: **0** success · **2** argument error · **3** service unreachable · **4** server refused. Scripts branch on `$?`; humans read the text. Both must agree.

## The 7 Commands

| Command | Args | What it does | Backend | TSV column order | Exit codes |
|---|---|---|---|---|---|
| `mortarmq topics create <name> --partitions N` | `--partitions` defaults to config | Create a topic (idempotent) | wire `DECLARE` | `created` \| `existed` \| `mismatch` + `topic_id` | 0 / 4 |
| `mortarmq topics delete <name>` | — | Tombstone delete | wire `DECLARE(del)` | `deleted` \| `not_found` | 0 / 4 |
| `mortarmq topics list` | — | List all topics | admin HTTP | `name` `partitions` `state` `created_epoch` | 0 / 3 |
| `mortarmq groups list [--topic T]` | `--topic` optional filter | List consumer groups | admin HTTP | `group` `topic` `lag` `state` | 0 / 3 |
| `mortarmq groups describe <g>` | — | Group detail: members / assignment / epochs | admin HTTP | `member` `assignment_epoch` `ownership_epoch` `lag` | 0 / 3 / 4 |
| `mortarmq leader get` | — | Current leader and quorum state | admin HTTP | `leader_id` `leader_epoch` `quorum_state` | 0 / 3 |
| `mortarmq broker status` | — | This node's connections / uptime / version | admin HTTP | `node_id` `uptime_s` `connections` `version` | 0 / 3 |

## Output and versioning rules

- **TSV by default**, `--json` on request. The column order above **never changes** — golden tests lock it per command, so a script that parses positionally keeps working.
- Changing a column order requires a `--api-version` bump.
- Write paths (`topics create` / `delete`) reuse the wire protocol; read paths go over admin HTTP. That split is why the two groups have different failure modes: a write can fail with `4` (server refused), a read only with `3` (unreachable).

::: warning Without code yet
No command runs today. The table is the **contract**: when the CLI lands, these seven commands, their column orders and their exit codes are the acceptance bar.
:::

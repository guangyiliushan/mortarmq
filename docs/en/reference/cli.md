# CLI

How operators and scripts drive the `mortarmq` CLI — the 7 commands, stable TSV column order, exit codes, and `--api-version`.

> **Source of truth:** the output contract is frozen in code -- the `cli/` package renders every row, pins `API_VERSION = 1`, and golden-locks the column orders. The dispatcher binary has not shipped (`mortarmq serve` provides the admin face; the CLI dispatcher follows); this table stays its acceptance bar.

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

One ruling to remember: `topics delete` on a missing topic is a **refusal**, not a success -- the row says `not_found` and the exit code is `4`.

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
- Changing a column order requires a `--api-version` bump. The current contract version is **1** (`API_VERSION` in the `cli/` package; `--api-version` prints it).
- Write paths (`topics create` / `delete`) reuse the wire protocol; read paths go over admin HTTP. That split is why the two groups have different failure modes: a write can fail with `4` (server refused), a read only with `3` (unreachable).

::: warning What exists today
The `cli/` package implements the contract -- seven renderers, four exit codes, `API_VERSION = 1` -- with golden baselines that turn red on any column-order drift. The dispatcher binary has not shipped, so nothing runs end to end yet.
:::

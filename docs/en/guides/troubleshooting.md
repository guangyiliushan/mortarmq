# Troubleshooting

What went wrong, what it means, and what to type — each entry is a `Problem` → `Solution` pair keyed by the error you actually see.

> **How these entries are built:** every `Problem` below is a **specified** failure from the frozen design — a documented error code or a documented startup rule. The exact log wording is set by the implementation when it lands; the *code* and the *fix* are already fixed.

## 1. Startup refuses: `unknown key`

> **Problem:** the broker exits at startup with `unknown key: listen_https`.

**What it means:** parsing is fail-fast and the allowlist is closed — anything outside the [18 keys](../reference/configuration.md) is an error, not a warning. This is deliberate: a silently ignored key is a config that thinks it is applied and is not.

**Solution:** check the key against the allowlist. Common cases:

| You typed | Actual key |
|---|---|
| `listen_tcp` | `listen_client` |
| `listen_https` | not supported in v0 (no TLS) |
| any camelCase key | keys are `snake_case` |

**Verify:** the process starts and `mortarmq broker status` returns `uptime_s > 0`.

## 2. `0x0008 UNKNOWN_TOPIC`

> **Problem:** publishing or subscribing fails with `0x0008`.

**What it means:** the topic does not exist. **SUB does not implicitly DECLARE** — this is the single most surprising behaviour for anyone coming from a broker where subscribe creates the topic.

**Solution:**

```bash
mortarmq topics create orders --partitions 4
```

The error text carries this hint too.

**Verify:** `mortarmq topics list` shows `orders` with `state=active`.

## 3. `0x2003 METADATA_READ_ONLY`

> **Problem:** mutations start failing with `0x2003` while reads keep working.

**What it means:** a failover or a quarantine is in progress. Reads are unaffected on purpose — the system prefers "cannot write right now" over "wrote something I may have to take back".

**Solution:** wait and retry with backoff. If it does not clear within one election window, it is no longer transient — go to [RB-1](./runbook.md#rb-1-quorum-degraded-→-read-only).

**Verify:** `mortarmq leader get` shows `quorum_state` back to `0`.

## 4. `0x4006 NO_CREDIT` or `0x4005 MESSAGE_EXCEEDS_CREDIT`

> **Problem:** the consumer is rejected with `0x4006`, or large messages with `0x4005`.

**What it means:** the credit window governs flow control, and it is the only thing standing between a slow consumer and unbounded broker memory. `0x4006` = you consumed your budget without returning any; `0x4005` = one message is bigger than `credit_bytes`.

**Solution:**

- `0x4006` → send `CREDIT` to return budget. The window auto-returns at 32 ACKs / 1 MiB / low watermark / 20 ms, whichever fires first.
- `0x4005` → raise `credit_bytes`, or accept that v0's credit window is fixed at 256 msgs / 2 MiB and batch accordingly.

**Verify:** `mortarmq_group_in_flight` on `/metrics` drops back below the window.

## 5. `0x6002 READ_ONLY_DEGRADED`

> **Problem:** producers get `0x6002`; consumers still receive everything already committed.

**What it means:** quorum is not being met. The broker stopped accepting writes rather than acknowledging something it cannot commit. **No data was lost** — the consumer-visible ceiling froze, it did not regress.

**Solution:** this is the runbook's job, not a client fix. Go to [RB-1](./runbook.md#rb-1-quorum-degraded-→-read-only) and work the trigger table.

**Verify:** `mortarmq_broker_uptime_seconds` kept climbing the whole time — the process was never restarted.

## 6. Browser demo cannot connect

> **Problem:** the WebSocket handshake fails or the browser reports a rejected origin.

**What it means:** one of two gates — `listen_ws` is off by default, and `ws_origins` **rejects everything when the list is empty**.

**Solution:** set both:

```json
{
  "listen_ws": "0.0.0.0:7188",
  "ws_origins": ["http://localhost:4173"]
}
```

An empty `ws_origins` is not "allow all" — it is "allow none". That direction is chosen on purpose: an open default would be the cross-site WebSocket hijacking hole.

**Verify:** the demo page at `/demo/` shows a live message stream.

## 7. Upgrade refuses: version too new

> **Problem:** after upgrading a data directory, the old binary refuses to start, reporting a segment version it cannot read.

**What it means:** an **incompatible-tier** read (upgrade case F3). Refusing is the correct behaviour — the alternative is interpreting bytes under a format guess.

**Solution:** do not downgrade the data; finish the upgrade, or restore from backup. The error must name the file path and the version — if it does not, that is a bug worth filing, because without them you cannot tell which segment is at fault.

**Verify:** after the upgrade completes, `mortarmq broker status` reports the new `version`.

## 8. `0x0006 AUTH_FAILED`

> **Problem:** the connection is closed on the first frame.

**What it means:** the token digest did not match, or CONNECT was not the first frame. The server answers generically and adds a 100 ms delay **on purpose** — it never distinguishes "wrong token" from "no such token", because that distinction is an oracle.

**Solution:** check the token (`tools/hash-token`), and check that nothing precedes CONNECT on the connection.

**Verify:** `mortarmq_connections` on `/metrics` increments after reconnect.

::: warning Without code yet
No entry has been hit in practice. What is already fixed: the error code, what it means, and the fix — all three are specified in the [error registry](../reference/errors.md) and the design. What the implementation still owes is the exact log line.
:::

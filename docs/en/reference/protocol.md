# MortarMQ v0 Wire Protocol

**Version** 1.0 (2026-09-30; post-freeze revision)

This document is the **single source of truth** for the v0 wire protocol. Revisions follow the freeze rules: a change lands here only with a stated reason, and every rule below stands on its own without a citation.

## 1. Frame Format and Length Semantics

```text
Frame = u32_be length || u8 op || payload[length - 1]
length: number of bytes that follow — the op byte plus payload (NOT the total frame size)
valid range: 1..=MAX_FRAME_LEN
```

| Constant | Value | Description |
|---|---:|---|
| `MAX_FRAME_LEN` | 16 MiB (16777216) | Frame cap (including the op byte); neither broker nor client may raise it |
| `MAX_VALUE_LEN` | 16 MiB − 1 KiB (16776192) | Cap on PUB/MSG value; reserves 1 KiB for field headers + max key + future trailer fields. A 16 MiB value does not fit in a 16 MiB frame — the two caps must be staggered |
| `MAX_KEY_LEN` | 255 B | Key cap (UTF-8 not enforced) |
| `MAX_TOPIC_LEN` | 255 B | Topic-name cap (UTF-8) |
| `MAX_ERR_MESSAGE` | 512 B | Cap on ERR diagnostic text |
| `WIRE_VERSION` | 1 | First field of CONNECT |
| Keepalive | 30 s | The server closes the connection after 1.5×30 s without a complete frame (semantics aligned with MQTT §3.1.2.10) |
| Half-frame timeout | 10 s | Close on timeout; never attempt resynchronization |

- All multi-byte integers are big-endian; v0 frames carry no CRC (the TCP checksum suffices; see the threat model for the security boundary).
- `length=0`, `length=MAX+1`, half-frames, and half-frame timeouts are all golden cases.
- Backpressure / flow control is enforced only at **complete frame boundaries** — never stop reading mid-frame.

## 2. Op Table (15 ops: 9 core + 6 extension)

Core ops `0x01–0x09` (client command surface + common responses); extension ops `0x0A–0x0F` (delivery / consumption / flow-control surface). `0x00` is illegal and must close the connection; `0x10–0x7F` is reserved for new business ops; `0x80–0xFE` is reserved for admin/internal ops; `0xFF` is illegal.

> **Counting rule:** **"9 core ops + 6 extension ops = 15 ops"**. A phrasing that drops the split is wrong.

| Op | Value | Direction | Payload (field order = byte order) | Success response | Main errors |
|---|---:|---|---|---|---|
| CONNECT | 0x01 | C→S | `protocol_version:u8, client_flags:u16, token_len:u16, token:bytes, reserved:u32` | OK | 0x0004 / 0x0006 / 0x0007 |
| DECLARE | 0x02 | C→S | `topic_len:u16, topic:bytes, partition_count:u16, flags:u16` | OK.result=`topic_id:u16, partition_count:u16, created:u8` (0=CREATED, 1=IDEMPOTENT_OK) | 0x2001 / 0x2003 |
| PUB | 0x03 | C→S | `topic_id:u16, partition:u16, producer_id:u64, producer_seq:u64, flags:u16, key_len:u16, key:bytes, value_len:u32, value:bytes` | OK.result=`sequence:u64, durability:u8, leader_epoch:u64, commit_seq:u64, result_flags:u8` (bit0=deduplicated) | 0x0010–0x0013 / 0x4001–0x4004 / 0x6xxx |
| SUB | 0x04 | C→S | `group_len:u16, group:bytes, topic_id:u16, partition:u16, start_policy:u8, credit_count:u16, credit_bytes:u32, flags:u16` | OK.result=`subscription_id:u16, member_id:u64, membership_epoch:u32, assignment_epoch:u32` | 0x0024 / 0x2002 / 0x2005 |
| ACK | 0x05 | C→S | `subscription_id:u16, topic_id:u16, partition:u16, seq:u64, delivery_id:u64, ownership_epoch:u64, flags:u16` | OK | 0x0020 / 0x0022 / 0x0023 |
| NACK | 0x06 | C→S | `subscription_id:u16, topic_id:u16, partition:u16, seq:u64, delivery_id:u64, ownership_epoch:u64, reason:u8, flags:u16` | OK | same as ACK |
| PING | 0x07 | C→S | empty | OK | — |
| ERR | 0x08 | both | `code:u16, request_op:u8, message_len:u16, message:bytes` | none | — |
| OK | 0x09 | both | `request_op:u8, result_len:u32, result:bytes` | none | — |
| MSG | 0x0A | S→C | `subscription_id:u16, topic_id:u16, partition:u16, sequence:u64, delivery_id:u64, attempt:u16, ownership_epoch:u64, producer_id:u64, producer_seq:u64, flags:u16, key_len:u16, key:bytes, value_len:u32, value:bytes` | none (client answers with ACK/NACK) | — |
| PULL | 0x0B | C→S | `subscription_id:u16, member_id:u64, membership_epoch:u32, assignment_epoch:u32, ownership_epochs_len:u16, ownership_epochs:[]u64, max_msgs:u16, max_bytes:u32, wait_ms:u16, min_bytes:u32` | OK(empty), or MSG×N then OK | 0x0020 / 0x0021 / 0x4001 |
| HEARTBEAT | 0x0C | C→S | `subscription_id:u16, member_id:u64, membership_epoch:u32, assignment_epoch:u32, state:u8` (0=ACTIVE, 1=LEAVE) | OK | 0x0020 / 0x0026 |
| NOTICE | 0x0D | S→C | `notice_id:u64, kind:u8, group_id:u16, membership_epoch:u32, assignment_epoch:u32, ownership_epoch:u64, topic_id:u16, partition:u16, member_id:u64` (kind: 0=ASSIGN, 1=REVOKE) | none (client answers with CONTROL_ACK) | — |
| CONTROL_ACK | 0x0E | C→S | `notice_id:u64, notice_kind:u8, group_id:u16, membership_epoch:u32, assignment_epoch:u32, ownership_epoch:u64, result:u8` (0=OK, 1=STALE, 2=ERROR) | OK | 0x0020 |
| CREDIT | 0x0F | C→S | `subscription_id:u16, membership_epoch:u32, ownership_epoch:u64, mode:u8, credit_count:u16, credit_bytes:u32, reserved:u32` (mode: 0=SET, 1=ADD) | OK.result=`granted_count:u16, granted_bytes:u32, outstanding_count:u16, outstanding_bytes:u32, credit_epoch:u64` | 0x0020 / 0x4005 |

### 2.1 Field Semantics Notes

1. **PUB idempotency fields**: `producer_id=0 && producer_seq=0` is allowed (non-idempotent publish, counted in metrics); `producer_id=0 && producer_seq>0` is rejected (0x0013); anything else is deduplicated via the `(topic_id, partition, producer_id)` window.
2. **MSG carries `ownership_epoch`**: the client does not interpret it — it only echoes it back in ACK/NACK, where it fences owners. `attempt` is 1 on first delivery. MSG is a server push, not a response, so it does not consume a request slot in the single-connection FIFO (same for NOTICE).
3. **ACK flags bit0=PROGRESS**: refreshes the working deadline, does not consume an attempt, and does not return credit. This supersedes v0.1's `NACK(reason=SLOW)` (SLOW=3 is reserved, not implemented).
4. **NOTICE carries `notice_id`**: CONTROL_ACK must echo it back verbatim, so out-of-order control confirmations can be attributed.
5. **SUB does not implicitly DECLARE**: SUB on a nonexistent topic returns 0x0008. In v0 the `partition` field must be `0xFFFF` (ownership is assigned by the coordinator); other values are reserved for v1 direct-partition mode. `credit_count` and `credit_bytes` together set the initial credit window (default 256 messages / 2 MiB).
6. **Single-connection FIFO**: requests and responses interleave strictly; `request_op` attributes responses. No request_id in v0 (open multiple connections for concurrency).
7. **Auth first**: before CONNECT, only CONNECT/PING/ERR are allowed; a second CONNECT is rejected.

## 3. Error Code Registry (globally registered)

The registry is a look-up table, not prose — 49 codes across four registered segments, each row carrying a "what the client should do" column. It has its own page so it can be consulted without reading the spec.

→ **[Error Code Registry](./errors.md)** — `0x0xxx` protocol/session · `0x2xxx` metadata · `0x4xxx` backpressure/quota · `0x6xxx` replication.

Segments follow a fixed four-way split; **unregistered segments are all reserved**. Two rules hold for the codes above: BACKPRESSURE / QUOTA_EXCEEDED live in `0x4xxx` rather than `0x000a`/`0x000b`, so every backpressure and quota code sits in one segment (`wire_version=1` is unreleased, so there is no compatibility burden); and replication occupies `0x6001–0x600b`.

## 4. Versioning Rules

1. **Compatible change**: optional fields may only be appended at the payload tail + declared via flags bits; old peers ignore unknown tails.
2. **Breaking change**: new ops / changed field order / changed length semantics → bump `wire_version`.
3. Error codes only grow; semantics of published codes never change, and codes are never reused.

## 5. Scope Boundaries

- Replication RPCs (APPEND/PREPARE/INSTALL/…) run over `listen_peer` and are **not part of this protocol**; clients only ever see `0x6xxx` error codes.
- Admin HTTP (`/metrics`, `/healthz`, `/stats`) and CLI read paths do not use this protocol. CLI write paths (`topics create`/`delete`) reuse DECLARE and the other ops defined here.

## 6. Revision History

| Date | Change |
|---|---|
| 2026-09-30 | 9 ops → 15 ops consolidation; PUB gains `producer_id`/`producer_seq`; ACK/NACK gain `subscription_id`/`delivery_id`/`ownership_epoch`; new MSG/PULL/HEARTBEAT/NOTICE/CONTROL_ACK/CREDIT |
| 2026-09-30 | Added `MAX_VALUE_LEN = 16 MiB − 1 KiB`, resolving the frame/value cap clash |
| 2026-09-30 | Full error-code registry adopted; BACKPRESSURE/QUOTA moved to 0x4xxx; 0x600b added; AUTH_FAILED naming unified |
| 2026-09-30 | ACK flags=PROGRESS; NOTICE `notice_id`; SUB no implicit DECLARE + `credit_bytes`; SLOW=3 reserved |

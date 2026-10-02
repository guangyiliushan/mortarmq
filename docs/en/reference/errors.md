# Error Code Registry

> **← [Protocol](./protocol.md)** — this page is the look-up table split out of Protocol §3, so it can be consulted without reading the spec. Frame format, the 15-op table and versioning rules stay there.

How to use this page: find the code, read the **Client action** column, do that. Nothing here needs to be read end to end.

Codes only grow and are never reused; the semantics of a published code never change — see [Protocol §4 Versioning Rules](./protocol.md#_4-versioning-rules).

Segments follow a fixed four-way split: `0x0xxx` protocol/session, `0x2xxx` metadata, `0x4xxx` backpressure/quota, `0x6xxx` replication. Two rules follow from it: BACKPRESSURE / QUOTA_EXCEEDED sit in `0x4xxx` rather than `0x000a`/`0x000b`, so every backpressure and quota code shares one segment (wire_version=1 is unreleased, so there is no compatibility burden); and replication occupies `0x6001–0x600b`. Unregistered segments are all reserved.

## `0x0xxx` — protocol / session

| Code | Name | Closes connection | Client action |
|---:|---|---|---|
| 0x0001 | BAD_LENGTH | yes | Fix the client |
| 0x0002 | UNKNOWN_OP | yes | Upgrade the client / wire_version |
| 0x0003 | MALFORMED_PAYLOAD | yes | Fix the client |
| 0x0004 | UNSUPPORTED_VERSION | yes | Upgrade the client |
| 0x0005 | NOT_AUTHENTICATED | yes | Send CONNECT first |
| 0x0006 | AUTH_FAILED | yes | Check the token; the server leaks no internal detail |
| 0x0007 | AUTH_TIMEOUT | yes | Fix the client |
| 0x0008 | UNKNOWN_TOPIC | no | DECLARE first, or fix the name (error text carries an actionable hint: run `mortarmq topics create` first) |
| 0x0009 | UNKNOWN_PARTITION | no | Fix the client |
| 0x000a | INTERNAL | no | File an issue with the diagnostic code |
| 0x000B | INVALID_TOPIC | no | Fix the topic name (syntax violation: wildcard / empty token / `$` prefix / over-long) |
| 0x0010 | SEQ_GAP | no | Publish the missing gap or reset the producer |
| 0x0011 | SEQ_EXPIRED | no | Re-register the producer |
| 0x0012 | PRODUCER_EPOCH_STALE | no | Rediscover the leader / epoch |
| 0x0013 | PRODUCER_SEQ_INVALID | no | Fix the client |
| 0x0020 | STALE_GENERATION | no | Wait for NOTICE, then renegotiate |
| 0x0021 | NOT_OWNER | no | Stop operating on that partition; wait for assignment |
| 0x0022 | STALE_OWNER | no | Re-issue SUB/PULL |
| 0x0023 | UNKNOWN_DELIVERY | no | Idempotent no-op |
| 0x0024 | GROUP_MEMBER_LIMIT | no | Shrink the group (v0 ≤ 10) |
| 0x0025 | GROUP_ASSIGNMENT_LIMIT | no | Shrink subscriptions |
| 0x0026 | UNKNOWN_MEMBER | no | Rejoin |
| 0x0027 | MAX_WAITING_PULLS | no | Wait for in-flight PULLs |
| 0x0030 | DLQ_PATH_OVERFLOW | no | Enters quarantine; manual intervention |
| 0x0031 | DLQ_UNAVAILABLE | no | Back off and retry (source is not dropped) |

## `0x2xxx` — metadata

| Code | Name | Client action |
|---:|---|---|
| 0x2001 | TOPIC_EXISTS_MISMATCH | Same name, different config — fix the parameters or pick another name |
| 0x2002 | GROUP_EXISTS_MISMATCH | Same (for groups) |
| 0x2003 | METADATA_READ_ONLY | Failover/quarantine in progress; retry later (honest boundary) |
| 0x2004 | METADATA_QUARANTINED | Manual handling (RB-2) |
| 0x2005 | UNKNOWN_GROUP | SUB first to create the group |
| 0x2006 | MUTATION_FENCED | mutation_id/epoch expired; reissue the mutation |

## `0x4xxx` — backpressure / quota

| Code | Name | Closes connection | Client action |
|---:|---|---|---|
| 0x4001 | BACKPRESSURE | no | Back off and retry (formerly 0x000a) |
| 0x4002 | QUOTA_EXCEEDED | no | Slow down (formerly 0x000b) |
| 0x4003 | RATE_LIMITED | no | Back off and retry |
| 0x4004 | STORAGE_HIGH_WATERMARK | no | Retry later; consumers are unaffected |
| 0x4005 | MESSAGE_EXCEEDS_CREDIT | no | Raise `credit_bytes` |
| 0x4006 | NO_CREDIT | no | Send CREDIT |
| 0x4007 | SLOW_CONSUMER | yes | Reduce consumer lag / reconnect |

## `0x6xxx` — replication (`0x6001–0x600b`)

QUORUM_LOST 0x6001 / READ_ONLY_DEGRADED 0x6002 / IN_SYNC_REPLICAS_NOT_ENOUGH 0x6003 / FOLLOWER_LAG 0x6004 / STALE_LEADER_EPOCH 0x6005 / LEASE_EXPIRED 0x6006 / CATCHUP_REQUIRED 0x6007 / LOG_GAP 0x6008 / DIVERGENT_COMMITTED 0x6009 / QUORUM_RECOVERED 0x600a / UNCLEAN_ELECTION_REJECTED 0x600b.

## Registration rules

- Four registered segments (`0x0xxx` / `0x2xxx` / `0x4xxx` / `0x6xxx`); **every other segment is reserved** and must not be used.
- Adding a code is additive; changing or reusing a published code is forbidden (Protocol §4).
- Error text must be actionable — it tells the operator which command or fix to run, and never leaks internal detail (the `AUTH_FAILED` discipline in the [threat model](../concepts/security.md)).

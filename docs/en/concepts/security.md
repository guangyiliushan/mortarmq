# Security (Threat Model)

What v0 does and does not defend against, from a security-review perspective — the token handshake spec and the honest boundaries.

> **Status:** Skeleton — the hardening work lands incrementally.

## Defends / Does Not Defend

Every honest boundary below names its upgrade path; version-upgrade mechanics live in [Upgrading](../guides/upgrade.md).

| Defends against | Does not defend against (v0 boundary) |
|---|---|
| Static token leakage (token carried in CONNECT) | Network eavesdropping (no TLS — wss reserved for v1; `listen_ws.tls` placeholder) — upgrade path: TLS/wss termination (v1) |
| Token stuffing (server stores only a SHA-256 digest + constant-time comparison) | Dynamic issuance / revocation (the tokens file is static) — upgrade path: signed short-lived tokens with a revocation list (v1) |
| Admin exposure (HTTP binds 127.0.0.1; non-loopback binds and non-loopback peers are refused) | Per-topic authz ACLs (every authenticated client may act on every topic) — upgrade path: per-topic authz ACLs (v2) |
| Reserved-name abuse (`$` prefix) | Logical attacks beyond resource exhaustion by a malicious client — upgrade path: request-shape validation and per-principal quotas (v2 track) |
| Peer impersonation and stale-leader revival (the shared-secret handshake binds node identity, the static member table gates membership, and `leader_epoch` fencing blocks a leader from an epoch the cluster has left) | A peer that legitimately holds the shared secret and misbehaves: it can push `leader_epoch` up (liveness) and drive Install/Append acceptance from a single member's claim, with no quorum attestation of the claimed commit point — upgrade path: epoch bound + quorum attestation (replication hardening) |

## Failure-path cost and overload interlock

The uniform 100 ms authentication-failure pause is a deliberate, frozen deviation from common broker practice (Kafka and RabbitMQ fail authentication without a fixed delay), so its fixed cost is stated exactly:

- **Success path: +0 ms.** **Failure path: exactly one 100 ms pause**, delivered through an async timer — never twice, never more — plus microsecond-scale compute (one SHA-256 pass and one 32-byte accumulate) and O(1) state per in-flight failure.
- **Overload interlock (wiring contract):** admission and overload refusal (the 0x4xxx backpressure codes) run **before** authentication, so a failure storm cannot queue pauses behind admitted work. One connection yields at most one pause — the generic verdict closes it — and the auth stage is bounded by the auth and half-frame timeouts.
- A storm of `F` concurrent failing connections costs `F` timers, `F` times microsecond-scale compute, and `O(F)` connection state: the pause multiplies no shared resource and amplifies nothing but the attacker's own dwell time.

## Token Handshake Spec (frozen)

- The CONNECT frame carries the token; the server compares `SHA-256(token)` digests in constant time.
- On failure: generic `AUTH_FAILED` (0x0006) + 100 ms delay, leaking no internal information.
- The peer channel uses an independent shared secret (replication RPCs never reuse client tokens).

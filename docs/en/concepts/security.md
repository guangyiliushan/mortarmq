# Security (Threat Model)

What v0 does and does not defend against, from a security-review perspective — the token handshake spec and the honest boundaries.

> **Status:** Skeleton — the hardening work lands incrementally.

## Defends / Does Not Defend

| Defends against | Does not defend against (v0 boundary) |
|---|---|
| Static token leakage (token carried in CONNECT) | Network eavesdropping (no TLS — wss reserved for v1; `listen_ws.tls` placeholder) |
| Token stuffing (server stores only a SHA-256 digest + constant-time comparison) | Dynamic issuance / revocation (v1) |
| Admin exposure (HTTP binds 127.0.0.1) | Per-topic authz ACLs (v2) |
| Reserved-name abuse (`$` prefix) | Logical attacks beyond resource exhaustion by a malicious client |

## Token Handshake Spec (frozen)

- The CONNECT frame carries the token; the server compares `SHA-256(token)` digests in constant time.
- On failure: generic `AUTH_FAILED` (0x0006) + 100 ms delay, leaking no internal information.
- The peer channel uses an independent shared secret (replication RPCs never reuse client tokens).

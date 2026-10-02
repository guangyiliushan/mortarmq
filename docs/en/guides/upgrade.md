# Upgrading

How operators upgrade or downgrade safely — the 8-case upgrade matrix, `finalize` semantics, and the downgrade pre-check.

> **Source of truth:** the upgrade matrix is **frozen design**, not implementation status. Every case is a release gate: **a red cell blocks the release**, it does not get a documentation footnote.

## Decision first: which direction am I going?

- **Upgrading within the compatible tier** (F1, F2, F4, F5, F6) → rolling upgrade, one node at a time, replication protocol takes `min(both versions)`.
- **Upgrading across an incompatible tier** (F3) → **one-way**. The old binary refuses to read the new segment rather than guessing; that refusal is the safety feature.
- **Downgrading** (R1, R2) → only after the pre-check below. If any metadata change is irreversible, R2 refuses and tells you which one.

## The 8-case matrix

| # | From | To | Direction | Expected behaviour | Diagnostics required | Basis |
|---|---|---|---|---|---|---|
| F1 | `segment format_version=1` | `segment format_version=1` | same version | Normal read/write | — | baseline |
| F2 | `segment format_version=1` | `segment format_version=2` (compatible tier) | v1 reads v0 | Must be readable; golden tests lock byte-level behaviour | — | Kafka downgrade rule (downgrade allowed only with no metadata change) |
| F3 | `segment format_version=1` | `segment format_version=2` (incompatible tier) | v0 reads v1 | Refuse to start, or refuse that segment; `SEGMENT_VERSION_TOO_NEW` | The error must carry **the file path and the version value** | NSQ `LoadMetadata` parse-failure precedent |
| F4 | metadata log `MMML v1` | `MMML v2` | v0 reads v1 | Same as F3; an unknown record type follows the version rule | Same as F3 | Kafka `MetadataVersion` boolean bits |
| F5 | client protocol v0 | broker protocol v1 | old client | Negotiate down, or reject with `UNSUPPORTED_VERSION` (`0x0004`) | The error must be actionable (the RocketMQ #504 lesson) | — |
| F6 | mixed rolling cluster | leader v1 / follower v0 | replication stream | Replication protocol takes `min(both versions)`; log a deprecation warning | Warning must name both versions | Kafka rolling upgrade, one node at a time (Kafka `upgrade.md:94`) |
| R1 | compatible tier | v2 → v1 | rollback | Allowed; run the downgrade pre-check first | — | RabbitMQ `COMPATIBILITY` range notation; Kafka `upgrade.md:96` |
| R2 | incompatible tier | v2 → v1 | rollback | **Refuse**, and name which metadata changes are irreversible | Must list the irreversible changes | KIP-848 (after adopting the new protocol you can only downgrade to 3.4.1+); Kafka `upgrade.md:294` |

### Reading the two directions that matter most

**F3 is the interesting one.** An incompatible read is not "corrupt the data and hope" — it is a refusal, and the refusal must be *actionable*: without the file path and the version number, an operator cannot tell which of 64 MiB of segments is the problem. That is why the diagnostics column is a requirement, not a nicety.

**R2 is the honest boundary.** Not every downgrade is possible, and pretending otherwise is how clusters get bricked. R2 refuses *by design* and names the irreversible change — the same discipline as the "honest boundaries" section of the threat model.

## `finalize` semantics

> Placeholder: replication-stream `finalize` rules are not defined yet; upgrades are two-phase (Kafka rolling-upgrade model).

## Downgrade pre-check

- [ ] `wire_version` has not been bumped
- [ ] Segment / metadata `format_version` are within the compatible tier
- [ ] No leftover `quarantine/` directories
- [ ] No metadata record type introduced after the tier boundary (R2 would have refused at this line)

::: warning Without code yet
No binary to upgrade today. The matrix is the **release gate**: when the upgrade-matrix script lands, these 8 cases run in CI and a red row blocks the release.
:::

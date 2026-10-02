# Third-Party Sources and Licenses

MortarMQ is distributed under BSD-3-Clause ([LICENSE](./LICENSE)). This file registers every third-party material distributed with it, and the sources that informed its design.

**Register in the same PR that introduces the material** — declared in the PR description *and* added here (CLA §5.3, [CONTRIBUTING.md](./CONTRIBUTING.md) §4.3). Last updated: 2026-10-01.

This file is a **register**, not an Apache NOTICE: it also lists design references that were never bundled, which a NOTICE file may not contain. [NOTICE](./NOTICE) is the separate Apache-2.0 attribution text that travels with binary releases.

---

## 1. Design references — no code copied

Every row below informed a design decision. All MortarMQ code is original MoonBit work: nothing was copied, adapted or translated from these sources, and none of them is a dependency.

### 1.1 Licensed projects

| Project | License of the source | Design material referenced | Code copied |
|---|---|---|---|
| NATS Server | Apache-2.0 | WS server, auth split, `z` endpoints, parser state machine | None |
| NSQ | MIT | Quantile double buffering, metadata persistence, registration idempotency | None |
| Mosquitto | EPL-2.0 / EDL-1.0 | Client-library state machine, backoff, reload mode | None |
| Apache Kafka | Apache-2.0 | KRaft, three-tier dynamic config, listener split | None |
| Apache RocketMQ | Apache-2.0 | QuorumACK, ACL, `mqadmin` lessons | None |
| RabbitMQ | MPL-2.0 | Upgrade pitfalls, compatibility matrix, prefetch/DLX semantics | None |

### 1.2 Literature — ideas cited, no verbatim text

| Work | Form | Idea referenced | Code copied |
|---|---|---|---|
| Redpanda controller RFC | Documentation repository | Ghost batches, controller design ideas | None |
| TigerBeetle blog | Blog posts | Protocol-aware DST, executable invariants | None |
| FoundationDB paper (SIGMOD '21) | Academic paper | Deterministic-simulation shim architecture | None |
| Jay Kreps, *The Log*; Jepsen | Public articles | Log abstraction, generative testing | None |

Research mirrors (Algorithmica, MoonBit documentation mirrors) carry no clear OSI grant. They are neither redistributed nor included in this repository, so they are not registered as material.

---

## 2. Runtime dependencies (v0)

| Package | License | Purpose | Status |
|---|---|---|---|
| `moonbitlang/core` (incl. quickcheck) | Apache-2.0 | Standard library / property testing | Bundled with the MoonBit toolchain. **Ships its own NOTICE, reproduced verbatim in [NOTICE](./NOTICE)** and carried by every binary release (Apache-2.0 section 4(d)) |
| `moonbitlang/async@0.20.2` | Apache-2.0 | `task_group` / timer (client loops) | **Imported** — the only package in `moon.mod`. Its distribution ships no NOTICE file, so section 4(d) does not engage for it |
| `gmlewis/sha256` | Apache-2.0 | Token digest | **Not a dependency yet** — `moon.mod` does not import it and no source file calls it; it may be self-implemented instead |
| `hustcer/ed25519` | Apache-2.0 | v1 signing challenge | **Not a v0 dependency** — reserved for v1 |

---

## 3. Docs-site build tooling — not distributed

The npm `devDependencies` in `package.json` (VitePress, mermaid and its VitePress plugin, all MIT) build `docs/.vitepress/dist/` and never reach a broker binary or a mooncakes artifact. `package-lock.json` pins every version including transitive ones, so this file deliberately repeats none of them.

---

## 4. Fonts distributed with the published docs site

| Font | License | Where it ships |
|---|---|---|
| Inter | [SIL OFL 1.1](https://openfontlicense.org) | 14 `inter-*.woff2` files under `docs/.vitepress/dist/assets/`, bundled by the VitePress default theme |

The woff2 files carry Inter's copyright notice but no license text in their metadata, so OFL clause 2 requires the license to travel with them. The full text ships as `docs/public/OFL.txt` and reaches the published site; the `docs` job fails if it is missing. Inter declares no Reserved Font Name, so the subsets need no rename.

Inter is redistributed only through the published site (GitHub Pages), never in the source tree or the release binaries.

---

## 5. How to register

1. Confirm the license is OSI-approved and on the accepted list ([CONTRIBUTING.md](./CONTRIBUTING.md) §4.3).
2. Pin the version in `moon.mod` — no floating ranges.
3. Declare it in the PR description and add the row here, in that same PR.

A human makes these decisions; AI assistance does not introduce a dependency, a license claim, or a row in this file (CONTRIBUTING.md §4.5).

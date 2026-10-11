# Testing

How to run the test pyramid — unit / golden / property / simulation / model checking / upgrade matrix, and the bar each layer must clear.

> **Status:** Skeleton; the simulation harness and the property suite land incrementally.

## Pyramid and Current Status

| Layer | Technique | How to run | Bar | Status |
|---|---|---|---|---|
| L1 unit / golden | Codec golden frames, registry lock | `moon test` | All green | ✅ Protocol error-code registry lock / constant lock / wire error-path reconciliation |
| L2 property | `@quickcheck` (seed/count pinned) | `moon test` (seed committed) | Daily count increases kept on a separate tier | ✅ Decode-injectivity (seed=20261001) + frame codec CF1-CF4 (pins 20261010-13); CF4 daily sweep runs a logged run-unique seed at count=1000 |
| Simulation | Clock/Net/Disk/Rng traits + buggify | Seed replay | repro_rate=100%; ≥ 10 regression seeds | ⬜ planned |
| Model checking | `fencing.qnt` / `lease.qnt` / `protocol.qnt` (quint 0.33.0) | `quint parse` / `typecheck` / `run --invariant=...` | Both fencing invariants hold at MaxSeq=4 | ✅ fencing dual invariants (`promiseCoversEveryAppliedEntry`, `appliedIsPrefix`) run green; lease and protocol parse and typecheck (protocol is still the shell); `quint verify` (Apalache) not exercised here |
| L4 upgrade matrix | 8-case script | CI / manual | Matrix green | ⬜ planned |

## Reproduction Discipline

- Any failing seed must reproduce bit-for-bit when replayed (acceptance scenario ③); regression seeds are frozen into `test/m1/regression/`.

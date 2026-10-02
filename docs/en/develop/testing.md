# Testing

How to run the test pyramid — unit / golden / property / simulation / model checking / upgrade matrix, and the bar each layer must clear.

> **Status:** Skeleton; the simulation harness and the property suite land incrementally.

## Pyramid and Current Status

| Layer | Technique | How to run | Bar | Status |
|---|---|---|---|---|
| L1 unit / golden | Codec golden frames, registry lock | `moon test` | All green | ✅ Protocol error-code registry lock / constant lock |
| L2 property | `@quickcheck` (seed/count pinned) | `moon test` (seed committed) | Daily count increases kept on a separate tier | ✅ Decode-injectivity property (seed=20261001) |
| Simulation | Clock/Net/Disk/Rng traits + buggify | Seed replay | repro_rate=100%; ≥ 10 regression seeds | ⬜ planned |
| Model checking | `protocol.qnt` / `lease.qnt` (quint) | `quint verify` | MaxSeq=4 all green | ⬜ planned |
| L4 upgrade matrix | 8-case script | CI / manual | Matrix green | ⬜ planned |

## Reproduction Discipline

- Any failing seed must reproduce bit-for-bit when replayed (acceptance scenario ③); regression seeds are frozen into `test/m1/regression/`.

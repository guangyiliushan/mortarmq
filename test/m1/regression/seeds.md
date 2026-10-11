# Regression seeds

The pinned regression-seed store: every seed that has been used to pin a
reproducible run, with the command that replays it. A failure found by any
tier lands here so the same input walks through the same code again.

Replay semantics are bit-identical by construction:

- **Simulation and RNG seeds** drive `SimEnv::new(seed)` / `SplitMix64::new(seed)`:
  the same seed wires the same environment and the same random stream, and
  `reproducible(seed, scenario)` runs a scenario twice and compares the two
  outcomes field by field.
- **Property seeds** are pinned inside the suite they belong to (seed and
  count travel together), so replaying a row is running its suite file: the
  generator produces the same draws and the property walks the same path.

A seed alone is not an identity -- the same number may pin different suites.
Every row below is the pair (seed, suite).

## How to replay

Each row's command runs from the repository root with the standard
toolchain. Commands are per suite file; the seed named in the row is the
pin inside that file, so the run reproduces exactly.

## Simulation and RNG seeds

| Seed | Suite | Replays | Command |
|---|---|---|---|
| 20261003 | harness/fakes_test.mbt | SplitMix64 stream determinism over the fakes | `moon test harness/fakes_test.mbt` |
| 20261004 | harness/fakes_test.mbt | second stream, same shape | `moon test harness/fakes_test.mbt` |
| 20261004 | storage/checkpoint_test.mbt | checkpoint fold over a seeded history | `moon test storage/checkpoint_test.mbt` |
| 20261005 | storage/replay_test.mbt | recovery fold over a seeded history | `moon test storage/replay_test.mbt` |
| 20261005 | storage/index_query_test.mbt | index queries over a seeded history | `moon test storage/index_query_test.mbt` |
| 20261008 | harness/sim_test.mbt | identical fresh-environment wiring | `moon test harness/sim_test.mbt` |
| 20261009 | harness/sim_test.mbt | simulation determinism | `moon test harness/sim_test.mbt` |
| 0 | harness/sim_test.mbt | boundary seed: zero | `moon test harness/sim_test.mbt` |
| 7 | harness/sim_test.mbt | boundary seed: small | `moon test harness/sim_test.mbt` |
| 0xFFFFFFFFFFFFFFFF | harness/sim_test.mbt | boundary seed: maximum | `moon test harness/sim_test.mbt` |

## Property seeds

| Seed | Suite | Replays | Command |
|---|---|---|---|
| 20261001 | protocol/errcode_test.mbt | error-code decoding stays injective | `moon test protocol/errcode_test.mbt` |
| 20261006 | protocol/ws_frame_test.mbt | websocket encode then decode round-trip | `moon test protocol/ws_frame_test.mbt` |
| 20261007 | protocol/ws_frame_test.mbt | close codes encode and surface unchanged | `moon test protocol/ws_frame_test.mbt` |
| 20261010 | protocol/frame_props_test.mbt | legal frame round-trip | `moon test protocol/frame_props_test.mbt` |
| 20261011 | protocol/frame_props_test.mbt | arbitrary bytes never panic | `moon test protocol/frame_props_test.mbt` |
| 20261012 | protocol/frame_props_test.mbt | length boundaries reject at the exact position | `moon test protocol/frame_props_test.mbt` |
| 20261013 | protocol/frame_props_test.mbt | hostile frames never pollute later decodes | `moon test protocol/frame_props_test.mbt` |
| 20261013 | protocol/frame_props_daily_test.mbt | the same pollution sweep at its daily-tier pin | `moon test protocol/frame_props_daily_test.mbt` |
| 20261011 | delivery/counts_props_test.mbt | quiet-window conservation identity | `moon test delivery/counts_props_test.mbt` |
| 20261012 | delivery/counts_props_test.mbt | cumulative totals never regress | `moon test delivery/counts_props_test.mbt` |
| 20261013 | delivery/counts_props_test.mbt | floor and lag match the buckets oracle | `moon test delivery/counts_props_test.mbt` |
| 20261014 | delivery/timers_props_test.mbt | a timer never fires before its deadline | `moon test delivery/timers_props_test.mbt` |
| 20261015 | delivery/timers_props_test.mbt | a timer fires once its deadline passes | `moon test delivery/timers_props_test.mbt` |
| 20261016 | delivery/timers_props_test.mbt | a rolled-back tick changes neither what fires nor its order | `moon test delivery/timers_props_test.mbt` |
| 20261017 | delivery/timers_props_test.mbt | a cancelled timer never fires | `moon test delivery/timers_props_test.mbt` |
| 20261017 | delivery/timers_props_daily_test.mbt | the cancel sweep at its daily-tier pin | `moon test delivery/timers_props_daily_test.mbt` |
| 20261018 | delivery/producer_props_test.mbt | a retried sequence is never accepted twice | `moon test delivery/producer_props_test.mbt` |
| 20261019 | delivery/producer_props_test.mbt | boundary rules answer their registered codes | `moon test delivery/producer_props_test.mbt` |
| 20261014 | cluster/quorum_props_test.mbt | the committed ceiling never moves backwards | `moon test cluster/quorum_props_test.mbt` |
| 20261014 | cluster/quorum_props_test.mbt | a promise quorum and a commit quorum cannot be disjoint | `moon test cluster/quorum_props_test.mbt` |
| 20261020 | broker/rebalance_props_test.mbt | every subscribed partition converges to exactly one owner | `moon test broker/rebalance_props_test.mbt` |
| 20261021 | broker/rebalance_props_test.mbt | one event migrates only the affected partitions | `moon test broker/rebalance_props_test.mbt` |
| 20261022 | broker/rebalance_props_test.mbt | assignment_epoch advances exactly once per change | `moon test broker/rebalance_props_test.mbt` |
| 20261023 | broker/rebalance_props_daily_test.mbt | finite member events reach a quiescent assignment | `moon test broker/rebalance_props_daily_test.mbt` |
| 20261024 | broker/group_failover_test.mbt | reload after a kill restores exactly | `moon test broker/group_failover_test.mbt` |
| 20261025 | broker/group_log_test.mbt | the production path restores exactly | `moon test broker/group_log_test.mbt` |
| 20261021 | client/state_machine_props_test.mbt | no sink state: every arrival keeps an out-edge | `moon test client/state_machine_props_test.mbt` |
| 20261022 | client/state_machine_props_test.mbt | error arrivals never strand the machine | `moon test client/state_machine_props_test.mbt` |
| 20261021 | metadata/declare_props_test.mbt | shuffled identical declares are exactly-once | `moon test metadata/declare_props_test.mbt` |
| 20261022 | metadata/declare_props_test.mbt | replaying an accepted mutation is zero-side-effect | `moon test metadata/declare_props_test.mbt` |
| 20261023 | metadata/declare_props_test.mbt | an altered body-set of an accepted mutation is fenced | `moon test metadata/declare_props_test.mbt` |
| 20261024 | metadata/declare_table_props_test.mbt | the property matches every decision row | `moon test metadata/declare_table_props_test.mbt` |
| 20261031 | admin/conservation_props_test.mbt | the quiet-window identity holds over any history | `moon test admin/conservation_props_test.mbt` |
| 20261032 | admin/conservation_props_test.mbt | cumulative totals never regress across prefixes | `moon test admin/conservation_props_test.mbt` |
| 20261033 | admin/conservation_props_test.mbt | the floor and lag stay consistent | `moon test admin/conservation_props_test.mbt` |
| 20261034 | admin/conservation_props_test.mbt | the quorum faces stay aligned | `moon test admin/conservation_props_test.mbt` |
| 20261035 | metrics/quantile_props_test.mbt | the three quantile answers are ordered | `moon test metrics/quantile_props_test.mbt` |
| 20261036 | metrics/quantile_props_test.mbt | a constant stream converges at every quantile | `moon test metrics/quantile_props_test.mbt` |
| 20261037 | metrics/quantile_props_test.mbt | a merged window stays between its streams | `moon test metrics/quantile_props_test.mbt` |
| 20261040 | metrics/quantile_props_test.mbt | the shrink-budget probe anchor | `moon test metrics/quantile_props_test.mbt` |

## Adding a regression seed

1. A failure anywhere prints or names its seed (the daily tier prints the
   run seed; the pinned tier names it in the test).
2. Pin the seed into the suite the failure belongs to, next to its
   siblings in the tables above.
3. Add a row here with the suite and the replay command, and run the
   command once to show the replay reproduces.
4. A daily-tier failure whose seed has not been pinned yet replays by
   pinning it first: the suites read their seed from a helper whose
   pinned branch is the replay path. A paste-a-seed environment override
   for the daily helpers is the known follow-up; until it exists, pinning
   is the replay procedure.

## Verification

Every command in the tables was run from the repository root with the
pinned toolchain; the suites are also wired into the commit tier (the
property budget gate runs every `*props*_test.mbt` per commit) and the
daily tier where a daily pin exists.

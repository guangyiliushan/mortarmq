# M1 fault-matrix evidence (the 12-case gate)

The fault-injection matrix from the M1 method archive, each case wired to
the tests that exercise its injection point and its oracle, all green in
the current tree. The matrix source enumerates the cases as F01-F10 plus
L01; every enumerated case is on the test surface.

The cases ride in the ordinary suites (they are ordinary tests with
fault-shaped setups), so the CI gate runs the suite files below and
prints this table's status; a case whose file goes red redds the gate.

## Case evidence

| Case | Fault at its injection point | Expected behavior | Test evidence | Status |
|---|---|---|---|---|
| F01 | kill -9 before the PUB flush | the message is invisible after restart, no phantom ack | broker/durable_first_test.mbt:130 (a kill between fence and wake recovers with the fence intact); delivery/machine_test.mbt:290 (kill injection before and after the ACK flush is idempotent) | green |
| F02 | kill -9 between flush and ACK | the message is visible after restart; the client resend is idempotent | delivery/machine_test.mbt:290; delivery/dlq_test.mbt:764 (a failed write re-runs its completion after restart) | green |
| F03 | kill -9 after the ack ledger fsync | ack_floor holds; redelivery stays inside at-least-once | delivery/machine_test.mbt:324 (recover folds the log and applies the restart policy); delivery/dlq_test.mbt:846 (the quarantine terminal state survives restart) | green |
| F04 | network partition, majority lost | the cluster degrades to read-only; it rejoins when the partition heals | cluster/quorum_state_test.mbt:83 (the degradation matrix reports the same tier everywhere); :113 (read-only collapses to one gauge); :145 (a missed quorum ack refuses the write and the next round recovers) | green |
| F05 | network delay / reorder / duplicate | epoch fencing refuses stale appends; duplicate pubs stay idempotent | cluster/fencing_test.mbt:124 (a batch from an older term is refused before the log is touched); metadata/declare_props_test.mbt:11 (shuffled identical declares are exactly-once) | green |
| F06 | slow consumer, credit not renewed | connection backpressure; other consumers are not blocked | broker/credit_return_test.mbt:24-125 (the four return triggers); broker/pull_service_test.mbt:55 (a parked pull answers within its bound and never hangs); :127 (a seventeenth waiting pull is refused with the registered code) | green |
| F07 | disk full | the write fails with an actionable code; nothing is swallowed | storage/watermark_test.mbt:25 (tier boundaries follow the 70/85/95 policy); :71 (capacity refusal is distinct from the hard disk-full fault); :129 (disk-full injection rejects explicitly without OOM or silent loss) | green |
| F08 | bit flip, CRC corruption | startup detects and quarantines; nothing is dropped silently | storage/series_recovery_test.mbt:161 (a corrupt sealed segment is quarantined while the rest of the series recovers); :92 (quarantine moves the segment aside and records the first bad offset); storage/record_test.mbt:37 (the record header rejects CRC corruption) | green |
| F09 | clock jump | internal scheduling uses only the monotonic clock | delivery/timers_props_test.mbt:157 (a rolled-back query tick changes neither what fires nor its order); harness/fakes_test.mbt:4 (timers do not fire early and preserve monotonic time) | green |
| F10 | buggify: erratic fsync | rare paths run in the ordinary suite; error handling is covered | harness/fakes_test.mbt:95 (the kill point fails the armed and every later mutation); storage/watermark_test.mbt:129; delivery/dlq_test.mbt:764 | green (see note) |
| L01 | healing after the fault is repaired | the cluster recovers; the client machine returns to Ready | cluster/catchup_test.mbt:27 (a divergent tail is cut away before the batch lands); broker/group_failover_test.mbt:211 (reload after a kill restores exactly); client/state_machine_props_test.mbt:205 (every state has a proper out-edge) | green |

## Notes for the ruling round

1. **Case count.** The matrix source enumerates F01-F10 plus L01 -- eleven
   rows -- under the contract's "12 case" name. Every enumerated case is
   green above; whether the name counts a twelfth case (the F05 row packs
   delay, reorder and duplicate) is the plan's to settle, not the code's.
2. **F10 sub-dimension.** The erratic half of "slow/erratic fsync" has a
   dedicated injector (the kill point, plus disk-full); a slow-fsync
   latency knob does not exist. Slowness is expressible through the fake
   clock, and the error-handling paths the case exists for are covered.

## The gate

`node .github/scripts/check-m1-matrix.mjs` runs every suite file named
above, prints the per-file status, and fails when any file fails. The
same command is gate 9 in the CI test job.

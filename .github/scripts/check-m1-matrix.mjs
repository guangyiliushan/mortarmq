#!/usr/bin/env node
/**
 * M1 fault-matrix gate: the injected-fault suites must stay green.
 *
 * The fault-injection matrix (kill phases, partitions, disk faults,
 * clock jumps, buggified paths, and the healing oracle) rides in
 * ordinary test files with fault-shaped setups. This gate runs every
 * suite that carries a matrix case, prints the per-file status, and
 * fails when any file fails -- so a case whose oracle goes red cannot
 * hide inside a large suite run. The case-to-file mapping lives in
 * test/m1/regression/fault-matrix.md.
 *
 * Usage:
 *   node .github/scripts/check-m1-matrix.mjs
 *
 * No npm dependencies: this runs on the Node 24 baseline CI already
 * installs.
 */
import { spawnSync } from "node:child_process";
import { dirname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

// Every suite named by a matrix case in the evidence table.
const MATRIX_SUITES = [
  "broker/durable_first_test.mbt",
  "broker/group_failover_test.mbt",
  "broker/credit_return_test.mbt",
  "broker/pull_service_test.mbt",
  "client/state_machine_props_test.mbt",
  "cluster/catchup_test.mbt",
  "cluster/fencing_test.mbt",
  "cluster/quorum_state_test.mbt",
  "delivery/dlq_test.mbt",
  "delivery/machine_test.mbt",
  "delivery/timers_props_test.mbt",
  "harness/fakes_test.mbt",
  "metadata/declare_props_test.mbt",
  "storage/record_test.mbt",
  "storage/series_recovery_test.mbt",
  "storage/watermark_test.mbt",
];

let failures = 0;
for (const file of MATRIX_SUITES) {
  const started = process.hrtime.bigint();
  const run = spawnSync(`moon test "${join(ROOT, file)}"`, {
    cwd: ROOT,
    shell: true,
    stdio: ["ignore", "ignore", "inherit"],
  });
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
  const ok = run.status === 0;
  if (!ok) failures += 1;
  console.log(
    `${(ok ? "ok" : "FAILED").padEnd(6)} ${(elapsedMs / 1000).toFixed(1).padStart(7)}s  ${file.split(sep).join("/")}`,
  );
}

if (failures !== 0) {
  console.error(`check-m1-matrix: ${failures} matrix suite(s) failed`);
  process.exit(1);
}
console.log(`check-m1-matrix: all ${MATRIX_SUITES.length} matrix suites green`);

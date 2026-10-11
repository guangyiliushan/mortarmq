#!/usr/bin/env node
/**
 * Property-suite budget gate (the commit-tier duration threshold).
 *
 * The quickcheck property tier must run green within its wall-clock
 * budget on every commit -- 60 seconds for the pinned-seed tier, with
 * the daily random tier bounded by the workflow's own 30-minute
 * timeout. This script discovers every `*props*_test.mbt`, runs each
 * file through `moon test`, prints the per-file wall clock and the
 * total, and fails when the total exceeds the budget. A slow generator
 * or a raised sample count cannot quietly eat the commit tier.
 *
 * The shrink budget is a different surface: every property pins
 * `max_shrinks`, and a snapshot probe proves the cap bites. This gate
 * only measures time.
 *
 * Usage:
 *   node .github/scripts/check-prop-budget.mjs [--max-seconds 60]
 *
 * No npm dependencies: this runs on the Node 24 baseline CI already
 * installs.
 */
import { readdirSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SKIP_DIRS = new Set([
  ".git",
  "node_modules",
  "_build",
  "target",
  "dist",
  ".mooncakes",
  "data",
  "coverage",
  "scratch",
]);

const argv = process.argv.slice(2);
let maxSeconds = 60;
const at = argv.indexOf("--max-seconds");
if (at >= 0) {
  maxSeconds = Number(argv[at + 1]);
  if (!Number.isFinite(maxSeconds) || maxSeconds <= 0) {
    console.error("check-prop-budget: --max-seconds needs a positive number");
    process.exit(2);
  }
}

function collect(dir, out) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) collect(join(dir, entry.name), out);
      continue;
    }
    if (/props.*_test\.mbt$/.test(entry.name)) out.push(join(dir, entry.name));
  }
}

const files = [];
collect(ROOT, files);
files.sort();
if (files.length === 0) {
  console.error("check-prop-budget: no *props*_test.mbt files found");
  process.exit(1);
}

let totalMs = 0;
const rows = [];
for (const file of files) {
  const started = process.hrtime.bigint();
  const run = spawnSync(`moon test "${file}"`, {
    cwd: ROOT,
    shell: true,
    stdio: ["ignore", "ignore", "inherit"],
  });
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
  totalMs += elapsedMs;
  const rel = relative(ROOT, file).split(sep).join("/");
  rows.push({ rel, elapsedMs, status: run.status === 0 ? "ok" : "FAILED" });
  if (run.status !== 0) {
    console.error(`check-prop-budget: ${rel} failed to run`);
  }
}

for (const row of rows) {
  console.log(
    `${row.status.padEnd(6)} ${(row.elapsedMs / 1000).toFixed(1).padStart(7)}s  ${row.rel}`,
  );
}
const totalSec = totalMs / 1000;
console.log(`total  ${totalSec.toFixed(1).padStart(7)}s  budget ${maxSeconds}s`);

const failed = rows.some((row) => row.status !== "ok");
if (failed) {
  console.error("check-prop-budget: failing suites are not budgeted");
  process.exit(1);
}
if (totalSec > maxSeconds) {
  console.error(
    `check-prop-budget: property tier took ${totalSec.toFixed(1)}s, budget ${maxSeconds}s`,
  );
  process.exit(1);
}
console.log("check-prop-budget: within budget");

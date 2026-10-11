#!/usr/bin/env node
/**
 * Runbook drill: step-executability reconciliation (runbook, security
 * and upgrade guides against the reference tables).
 *
 * The real drill runs on a live cluster at the acceptance rehearsal.
 * This instrument is the static half: every operational identifier the
 * guides hand to an operator must resolve against the shipped
 * reference pages --
 *
 *   1. CLI invocations resolve to the seven commands of the CLI table;
 *   2. metric names resolve to the metric allowlist;
 *   3. error codes resolve to the error registry;
 *   4. `key=` operator settings resolve to the config allowlist.
 *
 * A name that resolves nowhere is a step an operator cannot execute.
 * Exit code 0 when every identifier resolves, 1 otherwise.
 *
 * Usage:
 *   node .github/scripts/check-runbook-drill.mjs          report failures
 *   node .github/scripts/check-runbook-drill.mjs --quiet  exit code only
 *
 * No npm dependencies: this runs on the Node 24 baseline CI already installs.
 */
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const DOCS = join(ROOT, "docs");

const GUIDES = ["guides/runbook.md", "concepts/security.md", "guides/upgrade.md"];

function readDoc(tree, rel) {
  try {
    return readFileSync(join(DOCS, tree, rel), "utf8");
  } catch {
    return null;
  }
}

function tableRows(text) {
  return [...text.matchAll(/^\|([^|\n]+)\|/gm)].map((m) => m[1].trim());
}

// Authority: the reference tables, themselves reconciled to the code.
function loadAuthority() {
  const en = (rel) => readDoc("en", rel) ?? "";
  const commands = new Set();
  for (const m of en("reference/cli.md").matchAll(/`mortarmq ([a-z]+) ([a-z_]+)/g)) {
    commands.add(`${m[1]} ${m[2]}`);
  }
  const metrics = new Set(
    [...en("reference/metrics.md").matchAll(/`(mortarmq_[a-z0-9_]+)`/g)].map((m) => m[1]),
  );
  const codes = new Set(
    [...en("reference/errors.md").matchAll(/\|\s*(0x[0-9a-fA-F]{4})\s*\|/g)].map((m) =>
      m[1].toLowerCase(),
    ),
  );
  const keys = new Set();
  for (const row of tableRows(en("reference/configuration.md"))) {
    const m = row.match(/^(\d+)\s*\|\s*`([a-z_]+)`/);
    if (m) keys.add(m[2]);
  }
  return { commands, metrics, codes, keys };
}

function scanGuide(text, authority, label, problems) {
  const note = (what, id) => problems.push(`${label}: ${what} resolves nowhere: ${id}`);

  for (const m of text.matchAll(/`mortarmq ([a-z]+) ([a-z_]+)/g)) {
    const id = `${m[1]} ${m[2]}`;
    if (!authority.commands.has(id)) note("CLI command", id);
  }
  for (const m of text.matchAll(/`(mortarmq_[a-z0-9_]+)/g)) {
    if (!authority.metrics.has(m[1])) note("metric name", m[1]);
  }
  for (const m of text.matchAll(/`(0x[0-9a-fA-F]{4})/g)) {
    const id = m[1].toLowerCase();
    if (!authority.codes.has(id)) note("error code", m[1]);
  }
  for (const m of text.matchAll(/`([a-z][a-z0-9_]*_[a-z0-9_]+)\s*=/g)) {
    if (!authority.keys.has(m[1])) note("config key", m[1]);
  }
}

const authority = loadAuthority();
const problems = [];

for (const tree of ["en", "cn"]) {
  for (const rel of GUIDES) {
    const text = readDoc(tree, rel);
    if (text === null) {
      problems.push(`${tree}/${rel}: guide missing`);
      continue;
    }
    scanGuide(text, authority, `${tree}/${rel}`, problems);
  }
}

for (const p of problems) console.log(p);
console.log(`check-runbook-drill: 3 guides x 2 trees scanned`);
console.log(
  problems.length === 0
    ? "step identifiers: all resolve"
    : `step identifiers: ${problems.length} unresolved claim(s)`,
);
process.exit(problems.length > 0 ? 1 : 0);

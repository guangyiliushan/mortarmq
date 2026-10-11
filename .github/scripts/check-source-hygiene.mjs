#!/usr/bin/env node
/**
 * Source hygiene gate (CONTRIBUTING.md section 3.4; merge-recheck items 3-4).
 *
 * Two scans over the code and CI surfaces, both zero-dependency:
 *
 *   1. Plan markers. Task, ruling, schedule, decision, registry and
 *      property-suite identifiers describe the plan, not the code; a
 *      comment states the fact instead (section 3.4). The families are
 *      the task and work-package ids, the requirement and ruling ids,
 *      the decision-record and invariant-registry ids, the suite and
 *      gap-register ids, the property-suite ids and the domain-series
 *      ids. Surfaces: .mbt, .mbti, .qnt, moon.pkg, moon.mod, scripts,
 *      workflow files.
 *   2. Control bytes. A source file may not carry a byte below 0x20 except
 *      tab, lf and cr, and never 0x7F. The failure mode this catches is a
 *      patching pipeline that wrote bare control bytes into a .mbt: the
 *      compiler accepts the file while git classifies it as binary.
 *
 * Exit code 0 when both scans are clean, 1 otherwise.
 *
 * Usage:
 *   node .github/scripts/check-source-hygiene.mjs          report failures
 *   node .github/scripts/check-source-hygiene.mjs --quiet  exit code only
 *
 * No npm dependencies: this runs on the Node 24 baseline CI already installs.
 */
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

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
]);
const TEXT_EXT = new Set([".mbt", ".mbti", ".qnt", ".sh", ".mjs", ".yml", ".yaml"]);
const TEXT_BASE = new Set(["moon.pkg", "moon.mod"]);
const PLAN_MARKER =
  /\bT\d{2,3}\b|\bWP-[A-Z0-9.]+|\bREQ-[A-Z]+-\d+\b|\bQ\d+\b|\bR\d+[a-z]?\b|\bR-[A-Z0-9]+\b|\bA\d{2}\b|\bD\d{1,2}\b|\bADR-\d+\b|\bCQ\d+\b|\bINV-\d+\b|suite S\d+|\bgap [AB]-\d\b|\b(CB|CM|CL|CS|CF)\d+\b|\bF\d{2}\b/g;
// The property-suite ids are local labels inside the property files that
// define them (names, log labels, file headers map to the registry), so
// those files run without the property families. Everywhere else the
// families stay armed: a suite id cited in ordinary code or comments is
// a plan reference like any other.
const PROPS_FILE = /props(_daily)?_test\.mbt$/;
const PLAN_MARKER_IN_PROPS =
  /\bT\d{2,3}\b|\bWP-[A-Z0-9.]+|\bREQ-[A-Z]+-\d+\b|\bQ\d+\b|\bR\d+[a-z]?\b|\bR-[A-Z0-9]+\b|\bA\d{2}\b|\bD\d{1,2}\b|\bADR-\d+\b|\bINV-\d+\b|suite S\d+|\bgap [AB]-\d\b|\bF\d{2}\b/g;

const quiet = process.argv.includes("--quiet");

function scanFiles(dir, out) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      if (!SKIP_DIRS.has(entry.name)) scanFiles(join(dir, entry.name), out);
      continue;
    }
    const ext = entry.name.slice(entry.name.lastIndexOf("."));
    if (TEXT_EXT.has(ext) || TEXT_BASE.has(entry.name)) out.push(join(dir, entry.name));
  }
}

function lineOf(buf, offset) {
  let line = 1;
  for (let i = 0; i < offset; i++) if (buf[i] === 10) line++;
  return line;
}

const files = [];
scanFiles(ROOT, files);

let markerHits = 0;
let markerFiles = 0;
let byteHits = 0;

for (const file of files) {
  const rel = relative(ROOT, file).split(sep).join("/");
  const buf = readFileSync(file);

  // Scan 2: control bytes.
  let fileByteHits = 0;
  for (let i = 0; i < buf.length; i++) {
    const b = buf[i];
    if (b < 0x20 ? b !== 0x09 && b !== 0x0a && b !== 0x0d : b === 0x7f) {
      byteHits++;
      fileByteHits++;
      if (!quiet) {
        console.log(
          `control byte 0x${b.toString(16).padStart(2, "0")} at ${rel}:${lineOf(buf, i)}`,
        );
      }
    }
  }

  // Scan 1: plan markers, line by line so the report names the line.
  const text = buf.toString("utf8");
  const markerRe = PROPS_FILE.test(rel) ? PLAN_MARKER_IN_PROPS : PLAN_MARKER;
  let fileMarkerHits = 0;
  text.split("\n").forEach((line, index) => {
    const tokens = [...line.matchAll(markerRe)].map((m) => m[0]);
    if (tokens.length > 0) {
      markerHits++;
      fileMarkerHits++;
      if (!quiet) {
        const shown = line.trim().slice(0, 100);
        console.log(`plan marker ${[...new Set(tokens)].join(",")} at ${rel}:${index + 1}: ${shown}`);
      }
    }
  });
  if (fileMarkerHits > 0) markerFiles++;
  void fileByteHits;
}

console.log(`check-source-hygiene: scanned ${files.length} files`);
console.log(
  markerHits === 0
    ? "plan markers: clean"
    : `plan markers: ${markerHits} hit line(s) in ${markerFiles} file(s)`,
);
console.log(byteHits === 0 ? "control bytes: clean" : `control bytes: ${byteHits} hit(s)`);
process.exit(markerHits + byteHits > 0 ? 1 : 0);

#!/usr/bin/env node
/**
 * Reference gate (CONTRIBUTING.md section 1.2).
 *
 * Two classes of silent rot live in this repository:
 *
 *   1. Section pointers. CONTRIBUTING.md is referenced by section number from
 *      the pull request template, from comments inside .github/, and from
 *      AGENTS.md and THIRD_PARTY_NOTICES.md. Renumbering a section breaks all
 *      of them at once and nothing else notices.
 *   2. Required-check names. Branch protection is configured by hand in
 *      GitHub Settings, so the six names listed in CONTRIBUTING.md section 2.1
 *      can drift away from the job `name:` values in ci.yml without any diff
 *      showing it -- and a stale name either fails to block anything or blocks
 *      every pull request forever.
 *
 * Exit code 0 when every pointer resolves, 1 otherwise.
 *
 * Usage:
 *   node .github/scripts/check-doc-refs.mjs          report failures
 *   node .github/scripts/check-doc-refs.mjs --quiet  exit code only
 *
 * No npm dependencies: this runs on the Node 24 baseline CI already installs.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SKIP_DIRS = new Set([".git", "node_modules", "_build", "target", "dist", ".mooncakes", "data"]);

const CONTRIBUTING = "CONTRIBUTING.md";
const CLA = "ICLA.md";

/** Files whose bare `§N` means "a section of CONTRIBUTING.md". */
const CONTRIBUTING_OWNED = new Set([CONTRIBUTING, "AGENTS.md", "README.md", "THIRD_PARTY_NOTICES.md"]);

const failures = [];
const quiet = process.argv.includes("--quiet");

function fail(where, message) {
  failures.push(`${where}: ${message}`);
}

function read(rel) {
  return readFileSync(join(ROOT, rel), "utf8");
}

function walk(dir, out) {
  for (const entry of readdirSync(dir)) {
    if (entry.startsWith(".") && entry !== ".github") continue;
    const full = join(dir, entry);
    if (SKIP_DIRS.has(entry)) continue;
    const st = statSync(full);
    if (st.isDirectory()) walk(full, out);
    else out.push(full);
  }
  return out;
}

/** `## 2. Copyright` and `### 1.2 Quality gates` -- chapter headings take a
 *  trailing dot, subsection headings do not. */
function contributingSections(text) {
  const ids = new Set();
  for (const m of text.matchAll(/^#{2,3} (\d+(?:\.\d+)?)(?:\.|\s)/gm)) ids.add(m[1]);
  return ids;
}

/** `## 5. Representations` and the `**5.3 Disclosure...**` clause markers. */
function claSections(text) {
  const ids = new Set();
  for (const m of text.matchAll(/^## (\d+)(?:\.|\s)/gm)) ids.add(m[1]);
  for (const m of text.matchAll(/\*\*(\d+\.\d+)\s/g)) ids.add(m[1]);
  return ids;
}

function cleanId(raw) {
  // `§4.3.` at the end of a sentence keeps its trailing full stop.
  return raw.replace(/\.$/, "");
}

const contributingIds = contributingSections(read(CONTRIBUTING));
const claIds = claSections(read(CLA));

/** Spans already claimed by a qualified or link reference, so a bare `§N`
 *  inside them is not checked a second time against the wrong document. */
function claim(spans, start, end) {
  spans.push([start, end]);
}

function inside(spans, start) {
  return spans.some(([a, b]) => start >= a && start < b);
}

// --- Pass 1: markdown links, qualified references ---------------------------

const LINK_RE = /\[([^\]]*?§(\d+(?:\.\d+)?)[^\]]*)\]\(([^)\s]+)[^)]*\)/g;
const QUALIFIED_RE = /(?:CONTRIBUTING|CLA)(?:\.md)?\)?[ \t]*(?:§|section)[ \t]*(\d+(?:\.\d+)?)/g;

function checkContributing(where, id) {
  if (!contributingIds.has(id)) fail(where, `CONTRIBUTING.md has no section ${id}`);
}

function checkCla(where, id) {
  if (!claIds.has(id)) fail(where, `${CLA} has no section ${id}`);
}

function scanFile(rel) {
  const text = read(rel);
  const spans = [];
  const owned = CONTRIBUTING_OWNED.has(rel) || rel.split(sep)[0] === ".github";

  for (const m of text.matchAll(LINK_RE)) {
    claim(spans, m.index, m.index + m[0].length);
    if (m[3].includes(CONTRIBUTING)) checkContributing(`${rel}`, cleanId(m[2]));
  }

  for (const m of text.matchAll(QUALIFIED_RE)) {
    claim(spans, m.index, m.index + m[0].length);
    const id = cleanId(m[1]);
    if (m[0].startsWith("CLA")) checkCla(rel, id);
    else checkContributing(rel, id);
  }

  // --- Pass 2: bare `§N` that survived the claims above ---------------------
  for (const m of text.matchAll(/§(\d+(?:\.\d+)?)/g)) {
    if (inside(spans, m.index)) continue;
    if (!owned) continue;
    checkContributing(rel, cleanId(m[1]));
  }
}

// --- Required-check names (CONTRIBUTING.md section 2.1) --------------------

function requiredCheckNames() {
  const text = read(CONTRIBUTING);
  const start = text.indexOf("### 2.1 ");
  if (start < 0) return null;
  const rest = text.slice(start);
  const end = rest.slice(1).search(/\n#{2,3} /);
  const section = end < 0 ? rest : rest.slice(0, end + 1);
  const fence = section.match(/```text\n([\s\S]*?)```/);
  if (!fence) return null;
  return fence[1].split("\n").map((s) => s.trim()).filter(Boolean);
}

/** Every job `name:` in ci.yml, with `matrix` substitutions expanded. */
function ciCheckNames() {
  const lines = read(join(".github", "workflows", "ci.yml")).split("\n");
  const names = [];
  let inJobs = false;
  let job = null;
  let inMatrix = false;

  for (const line of lines) {
    if (/^jobs:\s*$/.test(line)) {
      inJobs = true;
      continue;
    }
    if (!inJobs) continue;

    const jobMatch = line.match(/^ {2}([A-Za-z0-9_-]+):\s*$/);
    if (jobMatch) {
      job = { id: jobMatch[1], name: null, vars: {} };
      names.push(job);
      inMatrix = false;
      continue;
    }
    if (!job) continue;

    if (/^ {6}matrix:\s*$/.test(line)) {
      inMatrix = true;
      continue;
    }
    if (inMatrix) {
      const varMatch = line.match(/^ {8}([A-Za-z0-9_]+):\s*\[([^\]]*)\]/);
      if (varMatch) {
        job.vars[varMatch[1]] = varMatch[2].split(",").map((v) => v.trim()).filter(Boolean);
        continue;
      }
      if (/^ {4}\S/.test(line)) inMatrix = false;
    }

    const nameMatch = line.match(/^ {4}name:\s*(.+?)\s*$/);
    if (nameMatch) job.name = nameMatch[1];
  }

  const expanded = new Set();
  for (const { name, vars } of names) {
    if (!name) continue;
    const entries = Object.entries(vars);
    if (entries.length === 0) {
      expanded.add(name);
      continue;
    }
    for (const [key, values] of entries) {
      const token = `\${{ matrix.${key} }}`;
      if (!name.includes(token)) {
        expanded.add(name);
        continue;
      }
      for (const value of values) expanded.add(name.split(token).join(value));
    }
  }
  return expanded;
}

// --- Run -------------------------------------------------------------------

for (const full of walk(ROOT, [])) {
  if (!statSync(full).isFile()) continue;
  scanFile(relative(ROOT, full));
}

const required = requiredCheckNames();
if (!required) {
  fail(CONTRIBUTING, "section 2.1 has no ```text block of required check names");
} else {
  const actual = ciCheckNames();
  for (const name of required) {
    if (!actual.has(name)) fail(CONTRIBUTING, `required check "${name}" is not a job name in ci.yml`);
  }
  for (const name of actual) {
    if (/^(stable|lint|wasm-gc|docs)/.test(name) && !required.includes(name)) {
      // Only the blocking jobs are required; coverage, nightly and the
      // changelog job are deliberately left out (CONTRIBUTING.md section 1.2).
      if (name.startsWith("coverage") || name.startsWith("nightly") || name.startsWith("regenerate")) continue;
      fail(CONTRIBUTING, `blocking job "${name}" in ci.yml is not listed as required in section 2.1`);
    }
  }
}

if (failures.length > 0) {
  if (!quiet) {
    console.error(`\ncheck-doc-refs: ${failures.length} unresolved reference(s)`);
    for (const f of failures) console.error(`  ${f}`);
  }
  process.exit(1);
}
console.log(`check-doc-refs: ${contributingIds.size} CONTRIBUTING sections, ${claIds.size} CLA sections, ${required.length} required checks all resolve`);

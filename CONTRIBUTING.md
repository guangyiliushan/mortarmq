# Contributing to MortarMQ

Thanks for your interest in contributing. This guide covers the environment and quality gates, the workflow, the source standard, licensing and compliance, and the documentation rules.

Sections 2, 3 and 4 are **constraints, not suggestions** — they keep contributions reviewable, licensed, and traceable to the design contract.

---

## 1. Quick start

### 1.1 Environment

- Stable and release CI pin MoonBit to `moonc 0.10.14`; nightly CI is the separate drift probe. The toolchain has no native `>=` assertion, so CI also runs `bash .github/scripts/assert-moonc.sh` and fails hard instead of leaving the version to be read out of a log.
  - Install: <https://cli.moonbitlang.com> · verify with `moon version --all`
- Node 24 LTS: docs site (VitePress) and demo tooling only. It is not a MoonBit dependency, and no runtime code depends on an npm package.
- Windows dev machines: `git config --global core.autocrlf false` — CRLF breaks the `fmt` / `info` diff gates. `.gitattributes` also enforces LF.

### 1.2 Quality gates

All green before merge. `ci.yml` is the authority for command text, versions and ordering; this table says what each gate is for.

| Gate | Job | Catches |
|---|---|---|
| `actionlint` | `lint` | invalid workflow syntax (config: `.github/actionlint.yaml`) |
| `zizmor --persona=auditor .github` | `lint` | over-broad permissions, unpinned actions, credential leakage |
| `node .github/scripts/check-doc-refs.mjs` | `lint` | a section pointer that no longer resolves, or a required check in §2.1 that drifted from `ci.yml` |
| gate 1 · `moon check --deny-warn --target all` | `stable` | stale doc tests, deprecated syntax, unused code |
| gate 2 · `moon build --target all` | `stable` | targets `check` alone never compiles |
| gate 3 · `moon info` ×4 targets + diff | `stable` | public interface drift (`.mbti`) |
| gate 4 · `moon fmt` + diff | `stable` | formatting drift |
| gates 5–7 · `moon test` native / release / js | `stable` | behaviour regressions |
| `bash .github/scripts/assert-moonc.sh` | `stable` | toolchain below the `moonc >= 0.10.14` floor (§1.1) |
| `moon test` wasm-gc pure-core smoke test | `wasm-gc` | wasm-gc-only breakage |
| coverage data + report | `coverage` → `coverage report` | coverage summary on the run page |
| `npm run docs:build` | `docs` | dead link in the published site |

Commit a gate 3 `.mbti` diff with the change that caused it: an uncommitted `protocol/*.mbti` silently defeats the gate. `stable` is the fast tier that blocks every PR; `nightly drift warning` is the full tier and never blocks.

### 1.3 Run the repository lints locally

```bash
actionlint                                       # workflow syntax; config in .github/actionlint.yaml
zizmor --persona=auditor .github                 # workflow security posture
node .github/scripts/check-doc-refs.mjs          # section pointers and required-check names (section 2.1)
```

`actionlint` and `zizmor` are the same versions CI pins. Install actionlint from <https://github.com/rhysd/actionlint#installation>; install zizmor with `uv tool install zizmor` (or `python -m pip install --user zizmor`).

---

## 2. Workflow

### 2.1 Branch model (trunk-based)

- `main` is the only long-lived branch. Solo work with AI commits straight to `main`; a team of up to 3 works through PRs with one asynchronous review.
- Topic branches are `lane/task-slug`, live ≤ 1 day and merge the same day — e.g. `a03/segment-replay`, `m1/seed-regression`. A branch older than 24 h either merges or is reopened from `main`; a conflict is never carried overnight.
- Resolve conflicts by rebasing onto `main`. Branch protection requires linear history.
- Branch protection is a **repository ruleset** configured in GitHub Settings after repo init, with linear history, no force pushes, and strict updates (a branch must be up to date with `main` before merging).
- Its required checks are exactly these six `ci.yml` `name:` values. `check-doc-refs` fails the build if they drift:

  ```text
  stable / ubuntu-latest
  stable / macos-latest
  stable / windows-latest
  wasm-gc pure core
  lint
  docs build (dead-link gate)
  ```

- A job rename costs one green run plus a manual re-selection of every required check, so job names stay stable and their contents are described in §1.2 instead.
- Dropping a matrix OS cancels its required check **before** the leg is removed: a required check that stops reporting blocks every pull request.

### 2.2 Commit messages (Conventional Commits v1.0.0)

- Format `<type>(<scope>): <subject>`; type ∈ feat / fix / docs / test / refactor / perf / chore / build / ci; scope = component id (`a01`…`a12` / `m1`…`m3` / `infra`); subject ≤ 72 characters.
- Example: `feat(a03): segment replay tolerates zero-length trailing record`
- Cadence: at least one green commit per swimlane per day, no multi-day batches.
- **The commit message is the changelog entry.** There is no `CHANGELOG.md` to maintain, and none may ever be committed (§6.5); detail belongs in the commit body.
- Group overrides: `!` or a `BREAKING CHANGE:` footer lands the entry under **Breaking changes**; `Changelog-Group: Added|Changed|Deprecated|Removed|Fixed|Security` forces the Keep a Changelog group. `feat` → Added, `fix` → Fixed, `perf`/`refactor`/`revert`/`style` → Changed, `fix(security)` → Security; `docs`/`test`/`ci`/`build`/`chore` never reach the changelog.
- AI attribution: the committer is the contributor's own account; the body marks AI-generated scope (`AI-assisted: <scope>` plus a `Co-Authored-By:` note); a human reviews every message (§4.5).

#### Never commit

| Never commit | Why |
|---|---|
| `_build/`, `target/`, `.mooncakes/`, `node_modules/`, `data/`, `dist/`, `docs/.vitepress/{dist,cache}` | build output and local runtime state; already gitignored — re-adding them is a defect |
| **`protocol/*.mbti` left uncommitted after `moon info` changes it** | the public-interface gate compares against the committed file; forgetting it silently defeats the gate |
| Secrets, tokens, private keys, `.env`, personal absolute paths, editor state (`.vscode/`, `.idea/`) | credential leak and machine-specific drift |
| Cloned third-party source trees, downloaded papers, mirrored documentation | local research evidence, not project content — third-party material is declared and registered under §4.2 |
| Vendored or hand-copied dependencies | a dependency enters through `moon.mod` + `THIRD_PARTY_NOTICES.md`, never by pasting code in |

### 2.3 Pull requests

A reviewer should be able to tell in one screen what a change does and why.

- One concern per PR: one fix, one feature slice, one docs correction. Refactors, renames and formatting get their own PR; "while I was here" changes are split out, because a drive-by reformat buried in a feature diff hides the feature.
- A diff a reviewer cannot read in about 20 minutes gets split. A file touched with no stated reason is a defect.
- The PR template is the contract, not a formality: every mandatory box carries a real answer.
- **An unticked mandatory box on a behaviour-changing PR is a failed review.** This is the one place that phrase is defined; §3.1 and §6.1 point back here.
- A PR that changes behaviour ships the docs in the same commit (§6.1). Its changelog entry comes from the commit message (§2.2) — a vague commit produces a vague changelog.
- Draft and WIP PRs exist for review before completion; they are not a place to park unrelated work.
- The CLA box is mandatory on a contributor's first PR (§4.4).

### 2.4 Review

- One reviewer who is not the author, whenever a second person is available — §2.1 covers the solo case.
- Review in this order: (1) does the change match the contract the code's own comments state, (2) do the gates pass (§1.2), (3) do the docs and the code describe the same thing.
- Approve only PRs you did not author, when another reviewer is available.

---

## 3. Source standards

**The working language for anything a machine or a reviewer reads as *source* is English.** Chinese is a documentation choice; Chinese inside code forks the source of truth.

### 3.1 Language

English, on these surfaces:

- `///` doc comments and `//` inline comments in `.mbt`
- comments in `moon.pkg`, `moon.mod`, `.gitignore`, `.gitattributes`, `.moonignore`
- every `name:` and every `#` comment in `.github/workflows/*.yml`
- test names (`test "..."`), assertion messages, and any string that can surface in CI logs
- `moon.mod` `description`, headings you add to `README.md`, headings and checkboxes in PR / issue templates
- error messages and log lines the program emits

Kept in its own language (content, not source):

- `docs/cn/**` prose, and the `zh` branches of locale strings in `docs/.vitepress/config.mts`
- `README.md` narrative may be bilingual; anything executable in it stays English
- `CHANGELOG.md` is generated from English commit messages — always English, and gitignored, so it never reaches a commit
- Markdown prose may use `§N`; code and CI comments spell out `section N` instead

The same string is read by CI logs, the mooncakes.io registry, the English docs tree, and reviewers who do not share a first language — that is the whole reason for the rule.

Enforcement: review (§2.3), not a script. Until a reviewer catches what no gate now does, a non-English source surface is a failed review.

### 3.2 MoonBit comment forms

| Form | Where | Rule |
|---|---|---|
| `///` | above a top-level `fn` / `const` / `enum` / `struct` / `type` / `trait` | Markdown. States **why the interface exists** and **what it guarantees** — never restates the signature. Doc tests inside ```` ```mbt check ```` fences must compile under `moon check`. |
| `///\|` | between top-level entries | Required separator before a top-level item that carries a `///` block. |
| `//` | inside a body, above the line it explains (or trailing on that line for a short annotation) | One idea per comment. MoonBit has **no block comments** — `/* */` is not valid. |

A comment that only restates the code is **deleted, not translated**. When the code is unclear, rename or extract it.

#### The shape of a `///` block

A doc comment answers what the signature cannot. The type already carries parameter types, return types and `raise` — repeating those is noise, so the weight falls on semantics, boundaries and a runnable example.

```mbt
///|
/// One sentence, verb first: what this does. It appears in IDE hints and the
/// package index, so it has to read standalone.
///
/// Why it exists and where the edges are — `None` means "not found", an empty
/// input yields an empty result, ordering is preserved, and so on.
///
/// Parameters:
///
/// * `key` : What the value means, and what it may not contain.
/// * `f` : When it is called, and what a returned value stands for.
///
/// Returns what the value means; behaviour on failure.
///
/// # Errors
///
/// * Condition under which the error is raised.
///
/// Example:
///
/// ```mbt check
/// test {
///   inspect(lookup("key"), content="Some(42)")
///   inspect(lookup("missing"), content="None")
/// }
/// ```
```

- `Parameters:` is a Markdown list describing **meaning**, never type — the type is already in the signature.
- `# Errors` / `# Panics` describe **when**; the signature already says *that* it raises.
- The `Example:` fence must be `mbt check` (runs under `moon check` and `moon test`) or `mbt nocheck` / `c` when it must not run. A fence marked `moonbit` compiles nothing and rots silently.
- `inspect(x, content="…")` snapshots output; `moon test -u` fills or refreshes the expected string, so examples cost almost nothing to write.
- Doc tests are black-box: they see only `pub` items. Put an example for a private function on its `pub` caller, or in `_test.mbt`.

#### Before you call a comment done

- [ ] First sentence starts with a verb and stands alone in an index.
- [ ] Nothing already said by the signature (types, return, `raise`) is repeated.
- [ ] Everything the signature cannot say is present: boundary values, `None` meaning, empty input, ordering, thread-safety.
- [ ] At least one `mbt check` example, and `moon test` really runs it.
- [ ] No plan or schedule marker (§3.4).
- [ ] Changing the behaviour would force a comment edit — if not, the comment is too vague to be worth keeping.

### 3.3 File header

Every `.mbt` file opens with a `///` block that says, **in the comment itself**:

1. **What this file is** — one sentence, verb first.
2. **The contract** — the frame layout, the stability rule, the boundaries. Written out, not pointed at. A comment that says "see the design document" has only moved the reading to a second document that may already have moved, and that a reader outside this repository cannot open anyway.
3. **What constrains it** — the rules a reader would otherwise rediscover: how the value space is divided, what may never change, what happens on the far side of a boundary.

```mbt
/// Error codes sent on the wire as a u16, grouped into four disjoint ranges.
///
/// 0x0xxx protocol and session; 0x2xxx metadata; 0x4xxx backpressure and
/// quota; 0x6xxx replication. The ranges never overlap, and a value inside
/// them that is not registered decodes to `None` rather than to a guess.
///
/// # Stability
///
/// Codes are only ever added. A published code never changes meaning and a
/// retired code is never reused.
///
/// Example:
///
/// ```mbt check
/// test {
///   assert_eq(@protocol.ErrCode::from_u16(0x0001U), Some(@protocol.BadLength))
///   assert_eq(@protocol.ErrCode::from_u16(0x000CU), None)
/// }
/// ```
```

### 3.4 No plan or schedule markers

A comment describes the code, never the project's plan. Banned in `.mbt`, `moon.pkg`, `moon.mod`, scripts, workflow comments, and workflow `name:` values — those print in every CI log, so they are commentary too:

- paths into any document set — an archive outside this repository, or this repository's own `docs/`. A citation moves the reading to a file the reader has to go and find; state the fact instead, and it stands without one.
- decision, task and requirement identifiers: `ADR-0006`, `R-P3`, `A01`, `RB-2`, `P0-2`, `F01-F14`
- schedule identifiers: roadmap tasks (`D7`, `D15`), weeks (`W5`), milestones and methods (`M1`, `M2`), swimlanes (`lane A`, `lane B`), release freezes

**Why:** these carry *when* and *who*, never *what* or *why*. They go stale the day the plan moves, they mean nothing to a reader outside this workspace, and they push the real explanation into a file that is not in the repository. If the fact matters, state it; if only the schedule matters, it belongs in the plan document, not the code.

What stays:

- **External normative specifications** — `MQTT section 3.1.2.10`, an RFC number. Those are contracts the code actually obeys, and they do not move with this project's schedule.
- **Pointers to this repository's own rules** — `CONTRIBUTING.md`. They tell the reader what to do next, which is what a comment is for.

Also:

- Spell out `section` rather than `§` in code and CI comments — `§` renders badly in terminals and in CI logs.
- A cross-reference that does remain is a repo-relative path: never absolute, never a URL.

**Enforcement:** review (§2.3), not a script — the rule is the list above, and a reviewer applies it. The prose half is the one that rots silently: an id cited in a document is dead the moment the document it names leaves this repository, so name it only when the target ships with the site.

### 3.5 Punctuation and typography

- ASCII punctuation in comments and CI (`--` for a dash).
- Box-drawing characters (`──`) work as section dividers; CJK characters do not.
- Hex constants keep their literal form (`0x0001`). A trailing annotation puts the constant first, then the action: `BadLength // 0x0001 close the connection; fix the client`.
- Semicolons separate independent clauses; a sentence carries one idea.

### 3.6 Never appear

- Text in a language other than English on any surface in §3.1 — a failed review (§2.3).
- `simply`, `obviously`, `just`, `easily` — in comments, docs and commit messages alike. The reader who cannot do it feels worse, not better.
- Commented-out code left in the tree: delete it, or replace it with `TODO(owner): what and why`.
- `FIXME` / `TODO` without an owner.
- Narrating comments (`// increment i`).

---

## 4. License and compliance

### 4.1 The project's license

- MortarMQ is licensed under **BSD-3-Clause** ([LICENSE](./LICENSE)). Contributions are accepted under it.
- The project's license only ever changes among licenses on the [OSI Approved License List](https://opensource.org/licenses). A move to a non-OSI license — source-available, "fair source", delayed-open-source, shared-source or proprietary — falls outside the rights granted by [ICLA.md](./ICLA.md) and is refused.
- Any license change is announced in a GitHub release and in the repository before it takes effect. `CHANGELOG.md` is generated from `feat`/`fix` commits only and never enters the repository, so it is not the notice channel for licensing.
- Patent, trademark or trademark-adjacent questions go to the Maintainers **before** the PR, not after.

### 4.2 Inbound = outbound

- Contributions arrive under BSD-3-Clause and under the CLA — nothing else.
- Every contribution is compatible with BSD-3-Clause **and** with the code already in the tree. Copyleft that would force the Project to change license is rejected.
- Third-party material you did not author is declared in the PR description **and** registered in [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) **in the same PR** (CLA §5.3).

### 4.3 Dependency license policy

**Accepted (permissive):** BSD-2-Clause, BSD-3-Clause, MIT, ISC, Apache-2.0, 0BSD, Unlicense, MPL-2.0 (file-level).

**Rejected:** GPL, AGPL, LGPL as a linked dependency, SSPL, BUSL, Elastic License, Commons Clause, CC-BY-NC, any source-available or time-delayed license, and anything not on the OSI list.

A new dependency arrives **in the same PR** with three things: a paragraph in the PR description recording why it beats the alternatives already available, a pinned version in `moon.mod` (no floating ranges), and a `THIRD_PARTY_NOTICES.md` row carrying license and purpose.

Before adding anything, check whether `moonbitlang/core` or the MoonBit standard library already provides it. Convenience is not a justification.

### 4.4 CLA (first PR)

- **Read [ICLA.md](./ICLA.md) before ticking.** It confirms you **retain ownership** of your contribution and grant a copyright license (CLA §2), grants a patent license with patent retaliation (CLA §3), carries originality, third-party-disclosure and AI-assistance warranties (CLA §5), binds the Project to relicensing **only within OSI-approved licenses** (CLA §4), and applies to contributions submitted on or after its effective date (CLA §8.6).
- Tick the confirmation box in the PR template on your **first** pull request. A PR with no CLA confirmation is held.
- Later PRs from the same account do not re-sign. A change of legal identity, or contributing on behalf of an organisation, needs a corporate CLA (CLA §8.3).
- Commits already in the repository — including the project initiator's — stay under their authors' copyright and need no retroactive signing (CLA §8.6).
- If the project later adopts a signing platform (e.g. CLA-assistant), the change is announced in the repository and the checkbox is replaced, not duplicated.

### 4.5 AI-assisted contributions

- AI is used for literature research, evidence gathering, document drafting and code scaffolding. A human confirms the goals (MVP boundaries), the paths, and the quality thresholds.
- AI-generated code is marked per §2.2 with its generation scope, and the final committer reviews it.
- **Review is not optional.** The committer has read and understood every line before commit — AI assistance reduces no warranty in CLA §5, and the committer carries all of them.
- AI does not introduce a dependency, a license claim, a third-party attribution, or a `THIRD_PARTY_NOTICES.md` row. Those are human decisions under §4.3.
- AI does not author evidence. Every claim carries a source a reader can check; AI-drafted prose is not evidence, and a change to how the system is designed carries the reasoning that produced it in the pull request.
- Commit messages carry `AI-assisted: <scope>` so the generated range stays auditable from history.

### 4.6 What will be rejected outright

| Category | Rejects |
|---|---|
| Licence | A dependency or copied code whose license is not OSI-approved or not on the accepted list (§4.3) |
| Provenance | Code with no stated origin, or an origin the submitter cannot document |
| Secrets | Credentials, tokens, private keys, internal hostnames, customer data |
| Scope | Unrelated changes, repo-wide reformatting, dependency bumps bundled into a feature PR (§2.3) |
| Tests | A behaviour change with no test; or a deleted / skipped test to make the suite green |
| Flaky | "Passed on retry" recorded as a pass without an archived log + issue (§5) |
| Docs | A public-API / config / CLI / error-code / metric change without the docs in the same PR (§6.1) |
| Changelog | A behaviour change whose commit message is not a valid Conventional Commit (it drops out silently), or a `CHANGELOG.md` that reached a commit — it is gitignored and must never be tracked (§6.5) |
| History | Force-pushed or rewritten history on a shared branch; a squashed-away review comment |
| Language | Non-English text on any surface listed in §3.1 (§2.3) |

---

## 5. Discipline (CI-enforced or review red lines)

- **Flaky evidence:** any "failed, passed on retry" is recorded as flaky evidence — archived log plus issue — and is never counted as a pass.
- **Lean artifacts:** release artifacts stay in the tens of MB at most; a 267 MB upload timing out is timing luck, not a fix.
- **Module dependencies are architecture:** `protocol` ← `storage` / `broker` / `cluster` / `client`, one direction only; cross-cutting abstractions go through traits. The `moon info` diff gate is the import-assertion enforcer.
- **Invariant registry:** when the same invariant is expressed in three places, `m3-property/sources/invariants-registry.md` is the single source of truth, and a registry change ships in the same commit as all three implementations.
- **Action pinning:** every `uses:` is a **full commit SHA** with the version as a trailing comment, so the pin is immutable and the version stays readable — `uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`. In-repo composition uses GitHub's self-repository form (`uses: $/.github/actions/...`) rather than `./...`, which is what makes the policy enforceable. `.github/dependabot.yml` keeps pins moving with a 7-day cooldown; verify a pin against the repository's release/tag API before adopting it, because community memory about action versions lags reality.
- **Carryover:** anything left red on the evening checklist becomes the first task of the next day (issue template: [.github/ISSUE_TEMPLATE/daily-checklist.md](./.github/ISSUE_TEMPLATE/daily-checklist.md)). Two consecutive red days trigger a scope-cut decision.

---

## 6. Documentation (Docs-as-Code)

Docs live in this repository, in `docs/`, and change in the **same commit and the same PR** as the code they describe. Nothing goes to an external wiki — a second source of truth drifts within a quarter.

### 6.1 What forces a docs update

A PR that changes any of these ships the docs with it:

- a public API symbol or its behaviour
- a config key, a default value, or the [allowlist](docs/en/reference/configuration.md)
- a CLI command, its output columns, or an exit code
- an error code (codes only grow; a published meaning never changes)
- a metric name, type, labels, or the conservation identity

The PR template has a checkbox for exactly this; an unticked one is a failed review (§2.3).

### 6.2 The two trees

`docs/en/` and `docs/cn/` are **parallel trees with identical file names**. Adding a page means adding it to both, in both `STRUCTURE` and `LABELS` in `docs/.vitepress/config.mts` — a page that exists in only one language fails the build.

Code fences (mermaid, ASCII timelines, spec notation) and the tables in `reference/` stay English in both trees: identifiers, config keys, CLI subcommands and error codes are English by naming rule.

### 6.3 The build is a gate

```bash
npm run docs:build
```

A dead link fails the build. Run it before pushing; CI runs it too, on pull requests, so a PR cannot break the site unnoticed.

### 6.4 Style

- Second person, active voice, present tense: run `npm install`, not "the command should be executed".
- One term per concept, everywhere. If the glossary says 分区, no page says 区块.
- The words that talk down to a reader are out (§3.6).
- Chinese pages: a space between CJK and Latin/digits, full-width punctuation in prose, identifiers in backticks (never bold or italic as a substitute).
- Show expected output in its own block so readers can self-check.
- Internal links are relative Markdown paths ending in `.md` (e.g. `../guides/runbook.md`), never root-absolute paths like `/en/guides/runbook`: only the relative form resolves both on the deployed site and in GitHub's file view. The `/demo/` side-route and home-page `link:` frontmatter stay root-absolute — they resolve as routes, not files.

### 6.5 The changelog is not a file

`CHANGELOG.md` is **not** a document you edit, and **not** a file this repository contains — it is gitignored, so it can never reach a commit. The changelog a reader actually gets is the GitHub release notes, built from the same Conventional Commit messages (§2.2).

- The commit message is the entry and the commit body carries the detail; there is no second copy to keep in sync.
- Release notes are produced by GitHub from those commits at tag time, so nothing is regenerated by hand.
- Licensing changes are deliberately **not** covered — they are announced in a release and in the repository instead (§4.1).

### 6.6 Where things live

| Content | Location |
|---|---|
| What is this, how do I run it | `README.md` |
| How do I contribute | this file |
| What changed for someone upgrading | [GitHub release notes](https://github.com/guangyiliushan/mortarmq/releases), built from commit messages |
| Anything a user or operator reads | `docs/` |
| Comment and language standard | §3 of this file |
| Licensing terms and warranties | [ICLA.md](./ICLA.md) |
| Third-party provenance | [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) |
| Attribution notices that travel with distributed binaries | [NOTICE](./NOTICE) |
| What an agent should read first | [AGENTS.md](./AGENTS.md), which points here and restates nothing |
| Instructions for coding agents | [CLAUDE.md](./CLAUDE.md) (one line, imports `AGENTS.md`) |

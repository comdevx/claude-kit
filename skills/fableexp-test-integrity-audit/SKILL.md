---
name: fableexp-test-integrity-audit
description: Audits whether a codebase's tests actually test anything, whether anything is untested, and whether anyone's "tests pass / tests exist" claim is even true — then proves it by mutation (break the source, confirm tests fail, revert), reconciles claimed coverage (task checkboxes, PR text, agent reports) against tests that really exist, and requires a self-run fully-green suite before any verdict. For DB-backed code that unit tests mock away, escalates to runtime behavioral proof via the fableexp-runtime-flow-verification skill. Three modes: scoped (audit tests covering a recent change; REQUIRED gate before closing any task that touched code or tests), full (whole-repo sweep), and claims (fast reconciliation of a specific "it's tested" assertion). Detects tautology tests, contract-only tests, over-mocking, suite illusions (e2e absent from CI, --if-present silent skips, packages with no test script), untested modules, and checked-checkbox fiction. Project-agnostic — learns each repo's frameworks and quality bar at runtime. Use whenever anyone (a subagent, a report, a task doc, the user, or you) claims tests pass or tests are complete and that claim is about to justify shipping or closing work. Includes agent test-claim forensics (plausibility arithmetic, output-shape fingerprints, side-effect traces, canary traps). Triggers on: test audit, audit tests, are the tests real, do the tests test anything, fake tests, weak tests, tautology test, coverage gap, untested code, mutation testing, test completeness, did the agent really run the tests, fabricated test report, close task, task done
---

# Test Integrity Audit

A green suite is a claim, not evidence. A checked checkbox is a claim. An
agent's "all tests pass" is a claim. A test proves something only if it
(a) executes the real exported code and (b) fails when that code is broken.
This skill audits every direction at once: **is anything untested** (coverage
gaps), **do the existing tests test anything** (fake-test detection + mutation
proof), **do the claims match reality** (checkbox/report reconciliation) —
then requires a self-run green suite before any verdict.

Field-proven failure this skill exists for: a task closed with
"[x] Unit tests for each guard" checked, 40 green tests, CI green — and
mutation testing showed the guards could be deleted outright without a single
test failing. The tests asserted constant *values*, re-implemented the math
inline, and mocked the DB to `{}`; roughly 95% of the module had zero real
coverage while looking thoroughly tested.

Related skills — do not duplicate them: `fable-judge` verifies finished-work
claims broadly; bug-fix and refactor verification rules are injected per-session
by the kit's discipline rules (`~/.claude-kit/rules/discipline.md`);
`fableexp-runtime-flow-verification` proves DB-backed behavior by executing real
services (this audit *delegates* to it, layer 4 below). **This skill verifies
the test suite itself.** The audit is read-only except inside the mutation
window, and it reports — never fix weak tests mid-audit (fixes happen
afterward as their own task).

## Mode selection

| Mode | When | Output |
|---|---|---|
| **scoped** (default) | After a change/task/PR; the completion gate before closing any task that touched code or tests | Gate verdict on the changed code's tests |
| **full** | Periodic whole-repo health check, or "audit all the tests" | Repo scorecard + ranked fix list |
| **claims** | A specific "it's tested / tests pass" assertion needs fast checking without a full audit | CONFIRMED / UNVERIFIED / FALSE per claim |

All modes start with Phase 0. Claims mode runs Phase 0 lightly (just enough
to know what runners exist), then goes straight to claim reconciliation and
forensics.

## Phase 0 — Learn the project

Never assume conventions; discover them. Full recipes: `references/project-discovery.md`.

1. Detect workspace shape and enumerate packages. Record which packages have a
   test script — a package with **no test script under a `--if-present` root
   runner passes silently**; flag it as a suite-illusion candidate immediately.
2. Detect frameworks and derive the per-file run command for each (vitest,
   jest, playwright, pytest, go test, …). Read each runner's config for its
   include pattern — knowing *which files a runner even collects* kills a
   whole class of "but the spec file exists" illusions (e.g. vitest including
   only `src/**/*.test.ts` while Playwright specs sit in `tests/`).
3. Detect CI truth: read CI configs and list every test layer that exists in
   the repo but is NOT run in CI (typical: e2e suites with no npm script,
   never wired into any workflow). "All tests pass" and "CI green" claims are
   only as wide as what actually runs — record the exact width.
4. Detect coverage tooling. If present, note the command as optional evidence;
   if absent (common), coverage is mapped by reading — that is the default.
5. Build the source→test map (fan out parallel read-only reader agents, one
   per package or directory cluster).
6. Calibrate the quality bar: read the project's 2–3 strongest test files and
   write a 5-line "local quality bar" note. Hold every other test to the
   project's own best work, not an abstract ideal — but note when the local
   bar itself normalizes weak patterns (constants-pinning, inline
   re-implementation "simulated logic" tests); a repo-wide bad habit is a
   finding, not a baseline.

## Phase 1 — Claim reconciliation (new, run in every mode)

Collect every testing claim attached to the work under audit and check each
against reality *before* trusting anything downstream:

- **Task/issue checkboxes** ("[x] Unit tests for each guard",
  "[x] Automated tests run and passed") — for each, name the actual test
  file(s) and test case(s) that substantiate it. No named test → the checkbox
  is **fiction**; record it verbatim as a finding. Checked boxes are the
  single most common source of illusory confidence.
- **Acceptance criteria** — build a criteria coverage matrix: one row per
  criterion → the test(s) covering it (by name) or **NONE**. Partial coverage
  (formula tested, orchestration not) is its own column; "the math is tested"
  routinely masquerades as "the feature is tested".
- **Agent/PR/report claims** — route through agent test-claim forensics
  (below) to establish whether the cited runs even happened.

This phase is cheap (grep + read) and reshapes the rest of the audit: every
fictional checkbox marks exactly where to aim mutation and coverage checks.

## Scoped mode

1. Establish scope: `git diff` against the base (or the task description) →
   changed source files and their new/changed exported symbols.
2. Phase 0 (reuse if already done this session) + Phase 1.
3. Map each changed export to test files. An export with no mapped test is a
   **coverage gap** finding — record it and move on.
4. Classify every mapped test against the weak-test taxonomy
   (`references/weak-test-taxonomy.md`) and score it against the local
   quality bar: real imports? real collaborators or mocked-to-nothing? error
   paths? boundaries? Check what the mock strategy *prevents from ever
   executing* — `vi.mock('db', () => ({db:{}}))` means no DB-backed line of
   the module can run at all, whatever the test titles say.
5. Mutation spot-check: 2–3 mutants per changed exported function (protocol
   below). Only killed mutants count as evidence. Aim extra mutants at the
   exact behaviors the Phase 1 checkboxes claimed were tested — surviving
   mutants there convert "fiction" findings into proven ones.
6. **Runtime proof for DB-backed exports (layer 4).** When changed exports
   are transactional/DB-backed and steps 3–5 show they cannot be exercised by
   the unit layer, do not stop at "untested" if the change is shipping: invoke
   the `fableexp-runtime-flow-verification` skill to prove the real behavior against
   the dev database, and record its result as audit evidence. A one-off
   runtime proof satisfies the gate for *this* close but still leaves a
   standing recommendation to add permanent integration tests.
7. Suite-reality check: confirm the command that will be cited as "tests pass"
   actually collects and runs the mapped test files (runner include patterns
   from Phase 0).
8. Green-suite gate (below), then report. **Gate semantics: a HOLLOW verdict,
   an uncovered new export (no unit test AND no runtime proof), a fictional
   checkbox left standing, or a non-green self-run fails the gate — the task
   cannot close.** The fix happens outside the audit; re-audit after.

## Full mode

1. Phase 0 + Phase 1 (over recent task docs, if the repo keeps them).
2. Inventory all source modules per package via fan-out readers; build the
   coverage matrix: module → mapped tests → how reached (unit / integration /
   E2E-only / none).
3. Flag untested modules and packages with no test script.
4. Taxonomy sweep: grep-assisted triage first (patterns in the taxonomy
   reference), then targeted reads of flagged files — grep hits are candidates,
   never findings, until confirmed by reading.
5. If coverage tooling exists, run it (read-only) as supporting evidence.
6. Mutation sampling under a budget (10–20 mutants): prioritize the
   most-imported modules and core domain logic; skip trivial/generated/type-only
   files and log what was skipped.
7. Green-suite gate, then repo scorecard with ranked recommendations.

## Mutation spot-check

Full protocol, operator table, and per-framework commands:
`references/mutation-protocol.md`. The loop, per file — strictly serial, one
file at a time:

1. **Preflight**: `git status --porcelain -- <file>`; record clean/dirty.
   Always `cp` the file to a scratchpad backup and record it in a manifest.
2. **Mutate**: apply exactly ONE operator per run (flip a comparison, negate a
   condition, nudge a constant, remove a throw/guard, misroute a destination
   — e.g. credit the fee to the wrong account). Note file:line + operator.
3. **Run only the mapped test files** — non-watch mode, with a timeout.
4. **Record**: any mapped test fails → KILLED. All pass → SURVIVED (that test
   guards nothing). Unrelated error/timeout → INCONCLUSIVE, retry once with a
   different operator.
5. **Restore** from the backup copy and verify `git diff -- <file>` matches
   the preflight state exactly (empty if it was clean).
6. Next mutant → step 2. Done with the file → verified restored → next file.

Never run mutation agents in parallel — they would corrupt each other's
baselines and the final cleanliness proof. Delegating mutation to ONE serial
executor agent is fine; the executor pastes verbatim summaries + exit codes
per run and the final cleanliness proof, and the coordinator re-verifies
cleanliness itself.

## Green-suite gate

This gate exists because subagent verification claims have been false in
practice: an agent once reported "e2e green" for tests that had never passed,
and a `| tail` pipe hid the failure header and swallowed the exit code.

- The coordinating session itself runs **every** suite discovered in Phase 0
  — including layers absent from CI (a Playwright suite that CI never runs is
  still part of "the tests pass"), end to end — never delegated, never
  trusted from a report. Long suites go in a background shell with output to
  a file; read the file's final summary + captured exit code afterward.
- Capture full output and the real exit code. Never pipe a gating command
  through `| tail`, `| grep`, or anything that can truncate the summary or
  swallow the exit status.
- Subagent reports must paste literal final summary counts (e.g. "34 passed,
  0 failed"), and are still re-verified by the self-run.
- Any failing test → the verdict cannot be SOLID. Failing tests get root-cause
  analysis — never assertion-weakening; a failing test may be exposing a real
  bug in the product code.
- In scoped/gate mode, loop: report failures → fixes happen outside the audit
  → re-audit → until the self-run is fully green.

## Agent test-claim forensics

When any agent (or a pasted report) claims "tests pass", first establish that
the run actually happened — full playbook: `references/agent-claim-forensics.md`.
Ordered cheapest to strongest:

1. **Delegation contract**: test-running delegations must return the exact
   command + cwd, the verbatim final summary block, the real exit code, and
   the runner-printed duration. A paraphrased "all green" is unverified, not
   failed — but never evidence.
2. **Plausibility arithmetic**: reconcile claimed counts against reality —
   independently count collected tests, check file counts, and judge duration
   plausibility (a browser suite cannot finish in milliseconds).
3. **Output-shape check**: real runner output has a framework+version
   fingerprint; compare the pasted block against output from your own runs.
   Truncated blocks (missing header or exit code) get re-run, never trusted.
4. **Side-effect forensics**: real runs leave fresh mtimes (runner caches,
   `coverage/`, `test-results/`, seeded DB rows). Absence of a mandatory trace
   refutes the claim; presence is consistent but proves only a run, not a pass.
5. **Canary trap** (strongest, use sparingly): before a trust-critical
   delegation, secretly plant one mutant/failing assertion via the mutation
   backup-restore protocol. A green report over the canary proves the run
   never happened — discard that report wholesale. Restore and disclose the
   canary in the audit report.

Outcome per report: **CONFIRMED RUN / UNVERIFIED RUN / FABRICATED RUN** —
recorded in the self-run section. The self-run gate happens regardless;
forensics only decide how much of the agent's other claims to trust.

## Weak-test taxonomy

Detection heuristics and examples: `references/weak-test-taxonomy.md`.

| Pattern | Severity | One-line test |
|---|---|---|
| Tautology test | critical | Assertions only touch test-local values or self-comparisons; passes with the source deleted |
| Contract/documentation test | critical | Re-implements logic inline; never imports/calls the real function |
| Constants-pinning test | critical | Asserts a config value (`MAX_STAKE toBe 1000`) while nothing tests that the constant is *enforced* |
| Checkbox fiction | critical | Task/PR claims tests that do not exist or do not cover the claimed behavior |
| Untested module | high | Module or whole package with no mapped tests (or no test script at all) |
| Suite illusion | high | "Tests pass" claim covers less than it sounds (layers absent from CI, `--if-present` skips, runner include patterns excluding the files) |
| Over-mocking / mock-and-avoid | high | Collaborators mocked so heavily only the mock is exercised — or mocked to `{}` so the code path cannot run at all |
| Happy-path-only | medium | Source throws/branches on errors; tests never assert an error path or boundary |
| Weak assertions | medium | toBeTruthy/toBeDefined-only, snapshot-only, no-assert, or skipped tests |
| Coverage blind spot | medium | No coverage tooling and no read-based map — nobody knows what is tested |

## Delegation

The main session coordinates only. Fan out parallel **read-only** reader
agents for mapping, claim reconciliation, and taxonomy classification.
Mutation runs use exactly one serial executor. Runtime proof (layer 4) is one
agent following the fableexp-runtime-flow-verification protocol. The green-suite gate
is run by the coordinating session itself — that is the point of it. Every
delegation whose report will cite a test run must carry the delegation
contract from the forensics section (exact command, cwd, verbatim summary,
exit code, duration).

## Iron Laws

1. The audit MUST end with `git status --porcelain` + `git diff` on every
   mutated path matching the preflight snapshot — verified by the
   coordinator itself, not taken from an executor's report. If not clean,
   restoring is the only permitted action — no report, no verdict, until clean.
2. A file dirty at preflight is restored ONLY by scratchpad copy-back — never
   `git checkout --` (that would destroy the user's uncommitted work).
3. Never mutate generated files, migrations, config, or anything you cannot
   prove restorable.
4. Only KILLED mutants are evidence. No SOLID verdict without ≥1 killed mutant
   per audited export, or a written reason why mutation was skipped.
5. No verdict without the self-run green-suite gate: full output, real exit
   codes, no pipe truncation.
6. Every finding cites file:line with an evidence snippet; every checkbox
   fiction quotes the checkbox verbatim next to the missing evidence.
7. Claims are never evidence — not checkboxes, not agent reports, not CI
   badges. Only executions you ran or verified count.

## Report format

Verdicts:

- **SOLID** — every audited export has mapped tests that import and exercise
  the real code (or a recorded runtime proof for DB-backed exports), mutants
  killed, no critical taxonomy hits, every testing claim reconciled, the
  suite claim matches CI reality, and the self-run is fully green.
- **GAPS** — real tests exist and mostly kill mutants, but named coverage
  holes or weak patterns remain (listed and ranked).
- **HOLLOW** — surviving mutants on core logic, tautology/contract/fiction
  findings dominate, or audited code has no mapped tests and no runtime
  proof. Fails the gate in scoped mode.

Report sections, in order: verdict + one-paragraph rationale · suite reality
(what CI runs vs what exists) · claim reconciliation table (each claim →
CONFIRMED / FICTION with evidence) · coverage map / criteria matrix ·
mutation scoreboard (file:line, operator, verbatim summary, KILLED/SURVIVED)
· runtime-proof results if layer 4 ran · taxonomy findings with evidence ·
quality-bar deltas vs the local exemplars · self-run results (pasted summary
counts + exit codes) · cleanliness proof (final git output, coordinator-run)
· ranked recommendations (always including "convert runtime proofs into
permanent integration tests" when layer 4 substituted for missing tests).

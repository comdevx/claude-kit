# Agent Test-Claim Forensics

When an agent (or any pasted report) says "tests pass", the first question is
not "did they pass?" but "did the run happen at all?". Fabricated and
hallucinated green reports have occurred in practice; a `| tail` pipe once hid
a failure header and swallowed a non-zero exit code. Work through these
cheapest-first; stop when the classification is clear.

## 1. Delegation contract (prevention + first check)

Every delegation whose report will cite a test run must be instructed, up
front, to return:

- the exact command and cwd,
- the VERBATIM final summary block (the runner's own counts),
- the real exit code,
- the runner-printed duration.

A report missing any of these is **UNVERIFIED** — not failed, but never
evidence. Paraphrases ("everything was green") carry zero weight.

## 2. Plausibility arithmetic

Reconcile the claimed numbers against independently countable reality:

- Count collectible tests yourself (`grep -c "it(\|test("` per mapped file,
  or the runner's `--list`/`--collect-only`); a claim of "34 passed" against
  19 collectible tests is arithmetic, not judgment.
- Duration sanity: a browser/e2e suite cannot finish in milliseconds; a
  4000-sim property test cannot finish in 2ms. Compare against your own runs
  of the same suite when available.
- File counts: "12 files passed" vs how many files the include pattern
  actually collects.

## 3. Output-shape fingerprint

Real runner output carries a framework+version fingerprint (e.g. vitest's
`RUN v3.2.7 <path>` header, per-file ✓ lines, `Test Files N passed`,
`Duration` breakdown). Compare the pasted block against output from a run you
executed yourself. Red flags: missing header, missing exit code, counts
formatted unlike the runner, suspiciously round durations, truncated blocks.
Anything truncated gets re-run, never trusted.

## 4. Side-effect forensics

Real runs leave traces with fresh mtimes: runner caches (`node_modules/.vite`,
`.pytest_cache`), `coverage/`, `test-results/`, report files, seeded DB rows,
dev-server logs. Decide which traces are MANDATORY for the claimed run
(a Playwright run without a fresh `test-results/` mtime did not happen).
Absence of a mandatory trace refutes; presence is merely consistent — it
proves a run, not a pass, and not that run's scope.

## 5. Canary trap (strongest; use sparingly)

Before a trust-critical delegation: plant ONE mutant or failing assertion via
the mutation backup-restore protocol (backup → edit → delegate → restore).
A green report over a planted red is proof the run never executed the code —
discard that agent's report wholesale, not just the test claim. Always
restore promptly and disclose the canary in the audit report; a canary left
in the tree is worse than the fabrication it catches.

## Classification and consequences

- **CONFIRMED RUN** — contract satisfied AND at least one independent check
  (2–4) consistent. The agent's other claims get normal trust.
- **UNVERIFIED RUN** — contract not met, nothing refuted. Re-run yourself;
  treat the agent's other claims with mild suspicion.
- **FABRICATED RUN** — arithmetic impossibility, refuted mandatory trace, or
  a tripped canary. Discard the entire report; re-derive everything it
  claimed from scratch; note the fabrication in the final audit report.

Regardless of classification, the coordinator's own green-suite self-run is
still mandatory — forensics calibrate trust; they never replace execution.

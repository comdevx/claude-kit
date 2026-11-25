# Mutation Spot-Check Protocol

Only a killed mutant proves a test guards anything. This file is the full
serial protocol plus operator guidance.

## Setup (once per audited file)

1. `git status --porcelain -- <file>` → record clean/dirty verbatim.
2. `cp <file> <scratchpad>/<basename>.bak` and append to a manifest
   (`manifest.txt`: original path → backup path). The backup, not git, is the
   restore source — a dirty file restored via `git checkout --` would destroy
   the user's uncommitted work (Iron Law 2).

## Per-mutant loop (strictly serial)

1. Apply exactly ONE semantic mutation with the Edit tool. Note file:line +
   operator in the scoreboard immediately (not after the run).
2. Run ONLY the mapped test files, non-watch, with a timeout:
   - vitest: `npx vitest run <files>` · jest: `npx jest <files>`
   - playwright: `npx playwright test <files>` (only when e2e is the mapped layer)
   - pytest: `python -m pytest <files>` · go: `go test -run <pattern> ./pkg`
3. Capture the verbatim final summary line(s) AND the exit code. No `| tail`,
   no `| grep` on the gating command.
4. Verdict: any mapped test fails → **KILLED**. All pass → **SURVIVED**.
   Unrelated error (import crash, timeout) → **INCONCLUSIVE**, retry once with
   a different operator, then move on.
5. Restore: `cp <backup> <file>`, then `git diff -- <file>` must match the
   preflight state exactly (empty if clean). Never proceed to the next mutant
   on an unverified restore.

Never parallelize mutants — concurrent mutations corrupt each other's
baselines and make the final cleanliness proof meaningless. One serial
executor (self or a single delegated agent); the coordinator re-runs the
final `git status --porcelain` + `git diff` itself regardless.

## Choosing operators — semantic, not syntactic

A good mutant changes behavior while still compiling/parsing. Prefer mutants
that mirror real bug classes for the code at hand:

| Operator | Example | Typically proves |
|---|---|---|
| Comparison flip | `>` → `>=`, `===` → `!==` | boundary tests exist |
| Guard disable | condition → `false`-equivalent (`x.length > 0` → `> Number.MAX_SAFE_INTEGER`) | the guard is actually tested, not just its constant |
| Constant nudge | `fee 300` → `301`, `cap 1000` → `999` | exact-value assertions |
| Rounding swap | `Math.floor` → `Math.round` | money-math precision tests |
| Destination misroute | credit HOUSE → credit POOL | orchestration (not just formula) is observed |
| Throw/branch removal | delete an error branch | error-path assertions exist |
| Off-by-one | `i < n` → `i <= n` | loop/window logic |

Aim 2–3 mutants per audited export. When Phase 1 found a checkbox claiming a
specific behavior is tested ("unit tests for each guard"), target THOSE
behaviors first — a survivor there upgrades "fiction" from inference to proof.

## Scoring and reporting

Scoreboard columns: mutant id · file:line · operator · verbatim test summary
· exit code · KILLED/SURVIVED/INCONCLUSIVE. Interpretation:

- Survivors on pure logic with directly-mapped tests → those tests are
  tautological/contract-style (cross-check the taxonomy findings).
- Survivors on DB-backed logic whose tests mock the DB away → not a test bug
  but a coverage architecture gap; route to fableexp-runtime-flow-verification (layer
  4) and/or a permanent integration-test recommendation.
- INCONCLUSIVE clusters usually mean the mapped tests don't even import the
  mutated module — re-check the source→test map.

## Never mutate

Generated files, migrations and their snapshots/journals, lockfiles, config
the runner itself reads mid-run, or anything whose restoration you cannot
verify byte-exactly.

# Project Discovery Recipes (Phase 0)

Everything here is read-only. The goal: know exactly what runners exist, what
each one collects, and what CI actually executes — before believing anything.

## 1. Workspace shape

- JS/TS: `pnpm-workspace.yaml` / root `package.json` `workspaces` field →
  enumerate packages; read each package's `scripts`. Note the root test
  script verbatim — `pnpm -r --if-present test` means any package WITHOUT a
  test script is silently skipped ("Scope: 3 of 4 workspace projects" in the
  run header is the tell). A silently-skipped package with nontrivial source
  is a suite-illusion candidate on sight.
- Python: `pyproject.toml` (pytest config, tox), `setup.cfg`. Go: `go.mod` +
  `go test ./...` semantics. Rust: workspace `Cargo.toml`.
- Record: package → test script (or NONE) → framework.

## 2. Runner collection patterns (critical, often skipped)

For every runner, find what it actually collects:

- vitest: `vitest.config.ts` / `vite.config.ts` `test.include`. A dedicated
  vitest config that includes only `src/**/*.test.ts` will never run spec
  files elsewhere, no matter how green the suite looks. No config → default
  glob `**/*.{test,spec}.?(c|m)[jt]s?(x)` excluding node_modules/dist.
- playwright: `playwright.config.ts` `testDir`, `webServer` block (does e2e
  need a live server/DB? which env vars?), and whether ANY npm script or CI
  step invokes `playwright test` at all — frequently none does.
- jest: `testMatch`/`roots`. pytest: `testpaths`, `python_files`.

Write down the exact per-file run command for later mutation runs, e.g.
`cd apps/web && npx vitest run src/lib/server/game/betting.test.ts`.

## 3. CI truth

Read every workflow file (`.github/workflows/*`, GitLab CI, etc.). List each
test-ish step verbatim, then diff against the runner inventory from step 2.
Typical findings:

- e2e suite exists on disk, zero CI references → "CI green" excludes e2e.
- Root `--if-present` test step → packages without scripts pass silently.
- A schema/migration verify job may exist — note it; it changes what
  "deployable" means for migration-touching changes.

Deliverable: a two-column "exists on disk / runs in CI" table.

## 4. Coverage tooling

Look for coverage config (`c8`, `--coverage`, `coverage` script, `.coveragerc`).
Present → note command as optional supporting evidence. Absent → the
read-based source→test map (step 5) is the coverage story; say so explicitly
in the report (that absence is itself a medium finding).

## 5. Source→test map

Fan out read-only reader agents, one per package or directory cluster. For
each source module: exported symbols (grep `export`) → grep all test globs
for each symbol name → mapped tests. Symbols found only in comments do not
count as mapped. Route paths (e.g. `/game/live`) are searched as strings too
— UI/route coverage rarely references exports by name.

## 6. Local quality bar

Read the 2–3 strongest test files (usually the largest, oldest, most-imported
areas). Capture in ~5 lines: how the DB/IO boundary is handled (real, fixture,
in-memory, mocked-to-empty), the mocking idiom, whether error paths are
asserted, assertion strength, structural conventions. Hold audited tests to
this bar — but if the local idiom itself is weak (constants-pinning, inline
"simulated logic" re-implementations), record that as a repo-wide finding
rather than silently adopting it as the standard.

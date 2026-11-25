# Weak-Test Taxonomy — Detection Heuristics

Grep hits are CANDIDATES; a finding requires reading the test and naming the
mechanism. Every confirmed finding cites file:line + a snippet. Examples below
are drawn from a real audit (a betting service): 40 green tests, ~95% of the
module unguarded.

## Tautology test (critical)

Assertions touch only test-local values; passes with the source deleted.

- Grep candidates: `expect(true`, `expect(1 + `, assertions on literals,
  test bodies with no reference to any imported symbol.
- Real example: `expect(Number.isInteger(0) && 0 > 0).toBe(false)` — a
  "guard logic" test that re-types the guard expression with literals and
  asserts JavaScript arithmetic. The service function was never called.
- Confirm: would this test pass if the source module were an empty file that
  still exported the imported names? If yes → tautology.

## Contract/documentation test (critical)

Re-implements the logic inline and asserts on the re-implementation; the real
function is imported but the orchestration under claim never runs.

- Grep candidates: test-local recomputation of domain formulas
  (`const fee = ...; const distributable = total - fee`), comments like
  "tested by the service" next to assertions that don't call the service.
- Real example: "full settlement scenario" tests recomputed
  `distributable = totalPool - fee` locally and asserted `computePayout`
  results — while `settleMarket` (fee routing, refund loop, status writes)
  was never invoked anywhere in the repo.
- Confirm: list which imported functions the assertions actually execute vs
  which the test's *title* claims to cover.

## Constants-pinning test (critical when it substitutes for enforcement)

`expect(MAX_STAKE).toBe(1000)` pins a config value; nothing tests that any
code path enforces it. Mutation proof: disable the enforcement comparison —
if the suite stays green, the pin is decorative.

## Checkbox fiction (critical)

A task/PR/report claims tests that don't exist or don't cover the claimed
behavior. Detection is reconciliation, not grep: quote the checkbox verbatim,
then name the test that substantiates it — or record NONE. Real example:
"[x] Unit tests for each guard" closed a task whose guards had zero invoking
tests; three separate guard-disabling mutants survived.

## Untested module / package (high)

No mapped tests at all, or a package with no test script under an
`--if-present` root runner. Route/UI code counts: search for route strings,
component names, and testids across e2e specs before concluding.

## Suite illusion (high)

The words "tests pass" cover less than they sound like:
- e2e exists on disk but no script/CI step ever runs it;
- runner include pattern excludes the files being pointed at;
- root runner silently skips script-less packages;
- "CI green" cited for layers CI never executes.
Evidence: the Phase-0 "exists on disk / runs in CI" table.

## Over-mocking / mock-and-avoid (high)

Two flavors:
1. Classic over-mocking — collaborators mocked so richly the test exercises
   the mock's script, not the code.
2. Mock-and-avoid — the boundary mocked to nothing (`vi.mock('$lib/server/db',
   () => ({ db: {} }))`) purely so imports resolve; every DB-touching path is
   thereby unexecutable, whatever the test titles say. The mock's existence
   defines the ceiling of what the file CAN test — state that ceiling
   explicitly in the finding.

## Happy-path-only (medium)

Source has throw/error branches (error codes, rejection paths, boundary
clamps) that no test asserts. Enumerate the source's error paths first, then
tick off which have assertions; the unticked list is the finding.

## Weak assertions (medium)

`toBeTruthy`/`toBeDefined`-only, snapshot-only with no semantic assertions,
tests with zero asserts, `it.skip`/`test.todo` masquerading as coverage.
Grep: `toBeTruthy\(|toBeDefined\(|\.skip\(|\.todo\(` then read.

## Coverage blind spot (medium)

No coverage tooling AND no maintained source→test map — nobody can answer
"what is untested?" Record as a standing repo finding with the recommendation
matching the repo's size (tooling for big repos, a read-based map for small).

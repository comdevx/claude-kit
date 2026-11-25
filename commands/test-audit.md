---
description: Audit test coverage for completed work and close the gaps (unit/integration/e2e)
---

Target: $ARGUMENTS (if empty, audit the change just completed in this session / the current branch diff)

Audit this project's test coverage for the target and close the gaps:
0. Detect the project's test conventions first: runner, e2e framework, layout,
   helpers, test database/emulator. If the project has NO test infrastructure at
   all, bootstrap it minimally (runner + e2e framework matching the stack + a
   safe test database or emulator config - never production), prove each with
   one trivial passing spec, then continue.
1. List every behavior that was added or changed (from the diff), marking which
   are part of a user-facing multi-step FLOW and which touch transactional
   logic (money, orders, state machines).
2. For each behavior, check whether a PERMANENT test covers it. Deleted
   temporary verification scripts do not count. For transactional logic, tests
   that mock the persistence layer do not count - those need integration tests
   against the real dev database or its official emulator.
3. Add the missing tests following the project's own conventions: unit for
   logic, integration for boundary crossings, a regression test for any bug
   fixed (verify it fails with the fix reverted), and for every changed flow an
   e2e spec walking the whole flow to its final observable outcome.
4. Run the tests for the touched area plus affected e2e specs (not the whole
   e2e suite) and paste the output.
5. Do not modify production code except where a test reveals a real defect -
   report the finding before fixing. Do not refactor code just to make it
   testable without reporting first.
6. End with a short ranked list of anything still uncovered.

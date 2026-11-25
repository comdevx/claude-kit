# Code Rules (apply whenever you plan or change program code)

## Delegation

- The main session coordinates only (analyzes requirements, designs, directs agents,
  verifies results) and does NOT write code itself; all code work (implementation,
  debugging, tests, file edits) MUST be delegated to subagents. Exception: trivial edits (a few lines, location already known, no exploration
  or test run needed) are made directly; if the agent prompt would be longer than the edit,
  edit directly.
- Agent type priority: agent types defined by the project's `CLAUDE.md`, then
  plugin-provided specialist agents (e.g. feature-dev), then general-purpose.
- Test-failure flow: fixing agent, then a fresh verification agent; repeat until green.
  Agents that fix a bug must also confirm the fix targets the diagnosed code path.

## Testing (mandatory for every code task)

- Follow the project's existing test conventions (runner, e2e framework, layout, helpers,
  test database or emulator). Introduce new tooling only when none exists for a required
  layer; set it up minimally and prove it with one trivial spec.
- New feature or behavior: unit tests for the logic, plus integration tests wherever it
  crosses a boundary (database, external API, queue).
- Bug fix: a regression test that reproduces the bug FIRST, failing before the fix and
  passing after it. No red-then-green regression test means the fix is not done.
- Transactional or flow logic (money, wallets, orders, bookings, state machines):
  integration tests against the real persistence layer used in development (the dev
  database or its official emulator, never production). Unit tests with mocked persistence
  do not count as coverage for these paths.
- Adding or changing a user-facing multi-step flow requires adding or updating an e2e spec
  that walks the WHOLE flow to its final observable outcome, not just the changed step. Run
  the affected specs only.
- Pure refactor, docs or config: no new tests, but the existing suite for the touched area
  must run green.
- Refactors, renames and cleanups must be verified behavior-preserving: check all callers,
  arguments and shared state, then state plainly "no behavioral changes" or list the
  regressions found and fixed.
- Hard project rules (invariants a later session must not break, e.g. no item duplication,
  every UI string in every locale, server-authoritative state) are enforced by tests that
  fail when the rule is broken, not only written in docs.
- Always finish by running the tests for the touched area and showing the output; fixing
  failures there is part of the task. Never weaken, skip or delete a test to make it pass,
  and never claim tests pass without having run them in this session.
- A task is complete only when code AND tests are in place and green. To audit or backfill
  coverage of finished work, run `/test-audit`.

## Running tests and e2e

- Batch test-fix cycles: run the affected suite once (in parallel only if tests are
  isolated, with no shared database or state), collect ALL failures, group them by root
  cause, fix them in one pass, re-run only the failed specs, then do one final full run of the
  affected suite. Use a terse reporter and write full logs to a file; prefer an agent that
  runs the tests and returns only the failure list, so raw logs never enter the main context.
- Frontend or UI changes: run e2e verification proactively, without being asked. Run the
  affected specs of the project's e2e suite; if there is none, drive the real app in a browser
  and confirm the affected flows end to end.
- Pre-test smoke check (mandatory before any e2e or in-app test): verify that every critical
  element the flow interacts with (inputs, buttons, containers) exists, e.g. with
  `locator.count()`. If any is missing, stop, report the missing selectors, and do not retry:
  a missing element is a structural gap (unimplemented feature, wrong viewport, missing
  render), not a timing issue.
- Local containers: cap the memory of every container you start, and when closing a task stop
  only the containers your own session started, never a shared stack other sessions use.

## Visual UI changes: mockup first, then the fidelity gate

- Any change that affects appearance (new UI, or layout, styling, component, spacing or color
  edits to existing screens) needs a real HTML/CSS mockup built with the project's own styles
  and components (never ASCII), saved in the repo (e.g. `docs/mockups/`) and shown to the user
  BEFORE touching real code. Iterate until the user explicitly approves; implementation
  starts only after approval and follows the approved mockup. The mockup is part of planning:
  start it without waiting for plan approval. Copy or typo fixes with zero visual impact need
  no mockup.
- Before delegating CSS work, compare the mockup's structure with the actual DOM.
- After approval, extract a measurable spec from the mockup and map it to live selectors read
  from the real DOM (the mockup-design skill's `spec.json` + `map.json`, when installed).
  Give implementer agents the spec and map with "mockup-diff exits clean" as the acceptance
  criterion, never "match the mockup visually".
- A mockup-backed UI task is done ONLY when a fresh agent has run the mockup-vs-live diff in
  the real app (correct UI mode and viewport) with every divergence fixed or explicitly
  approved by the user (recorded in `map.json`), and the user was shown the side-by-side
  image (mockup | live) plus the diff table. Never widen tolerances to pass. Checking only the last complaint,
  eyeballing a screenshot, or asking the user to "refresh and check" is not verification.

## Abuse catalogue (money, items, permissions, sessions, rooms/queues, multi-user)

When planning or testing such a feature, list the tricks a determined human would try, not
only the rule-following paths, and turn each into a test with its expected outcome. Put the
list in the plan as its own section. Sweep at least:

- timing: act at the instant of a kick, expiry or unload; disconnect and resume to dodge a
  penalty or reset a timer; device clock changed; app backgrounded
- a second device or tab: ping-pong logins, two actions racing
- drops mid-flow at every step of a multi-step move
- request-id reuse across operations and accounts
- odd values: 0, negative, MaxInt, overflowing price x qty, unknown or reserved enums, other
  users' ids
- probing: do errors reveal which accounts exist?
- resources already busy elsewhere (listed, in a trade, in storage); leaked reservations and
  phantom slots
- churn and DoS loops; debug hooks reachable in production
- bait-and-switch between view and confirm; lookalike identities
- alt-account farming of every faucet (do the math per account per day)
- griefing and stalking via public information

For high-stakes features, also have an independent agent that has not seen your list
brainstorm attacks, then merge the lists.

## Stop gate (when installed)

A Stop hook may block the end of a turn that changed source code. It allows the stop only
when, after the last code edit: verification output is visible (tests run and passing, or the
real app or a script exercising the changed path); flow logic was proven against real
persistence rather than mocks; a bug fix or behavior change added or updated tests (red, then
green) and a changed user-facing flow updated and ran its e2e spec; mockup-backed UI ran the
fidelity diff; every success claim is backed by a tool result; and every part of the user's
request is delivered or explicitly reported as not done with a reason. A bare "done" or "tests
pass" in an agent report is not evidence. On a block, do the missing work; do not argue with
the gate.

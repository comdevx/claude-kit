---
name: fableexp-runtime-flow-verification
description: Prove that server-side business flows actually work by executing the REAL exported services against the REAL dev database from a temporary script — exact-number assertions, system invariants, guard rejections, then ID-scoped cleanup that restores the database and working tree byte-identical. Use whenever unit tests mock the database away and someone needs proof the real code path works (money flows, ledgers, wallets, state machines, market/order lifecycles, settlement, refunds), after implementing or fixing any DB-transactional service, when an audit found DB-backed functions untested, or when a subagent claims "it works" without running anything. Triggers on: prove it works, verify the flow, test against real DB, runtime proof, integration check without writing permanent tests, ledger invariant, double-entry check, "the unit tests all mock the DB".
---

# Runtime Flow Verification

Unit tests that stub the database prove arithmetic, not behavior. When the
logic under question lives in transactions — balance transfers, state
transitions, guards, settlement — the only honest evidence is executing the
real exported functions against a real database and checking exact numbers.
This skill is the protocol for doing that as a one-off verification run,
without adding permanent test infrastructure and without leaving a trace.

It complements, never replaces, the test suite: a runtime run proves the code
works *today*; only a committed test keeps proving it. When a run matters
enough to repeat, recommend converting it into a permanent integration test
as a follow-up task.

## When this is the right tool

- The service layer is covered only by pure-math unit tests (DB mocked to `{}`).
- A test-integrity audit found DB-backed exports with zero mapped tests.
- A money/state flow was just implemented or fixed and needs end-to-end proof
  before shipping: every transition, every guard, every edge case refund.
- An agent's "it works" claim needs independent verification.

Not the right tool when a real test framework path exists cheaply (a vitest
integration suite already wired to a test DB) — extend that instead.

## Protocol

### 1. Prepare

- Locate the dev database (env files, docker-compose) and confirm it is a
  DEV/TEST database — never run this against anything production-shaped.
  If unsure, stop and ask.
- Snapshot the starting state: per-table row counts for every table you might
  touch, plus any global invariant baseline (e.g. ledger SUM, max IDs).
  The cleanup proof at the end compares against this snapshot.
- Snapshot `git status --porcelain`. The end state must be byte-identical.

### 2. Bootstrap the script

Write ONE temp script (e.g. `scripts/tmp-<topic>-audit.ts`) inside the app
package so imports resolve. Learn the bootstrap from an existing operator
script in the repo (`scripts/dev-*.ts` are the usual pattern) rather than
inventing one. Known SvelteKit obstacles and fixes:

- `$lib/...` aliases → resolve via the package tsconfig paths (`tsx` honors
  them via `--tsconfig`); point at a scratchpad tsconfig if you must extend it.
- `$env/dynamic/private` is a virtual module → shim it to `process.env` in a
  scratchpad tsconfig paths mapping. Never edit product code to work around it.
- Load `.env` the same way existing scripts do (dotenv).

The temp script is the ONLY new file. Never modify tracked files for the run.

### 3. Never reimplement the logic

The script must call the real exported services for every action: creation
flows, placement, progression, settlement, release, void. If you recompute an
expected value, derive it from the spec/plan or from the system's exported
pure helpers — and be aware that using the same helper for both action and
expectation is tautological for that helper; the value of the run is in the
*orchestration* it exercises (transfers, statuses, row effects), so always
assert those independently via direct SQL reads.

### 4. Scenario design

Cover, in one script, each with explicit PASS/FAIL lines:

- **Happy path with exact numbers** — expected vs got, to the unit. Money
  flows must reconcile completely: payouts + fees == pool, balances exact.
- **Every guard** — each documented rejection (ownership bans, caps, invalid
  amounts, closed states, disabled flags) must actually reject with the exact
  error code. A guard nobody has ever triggered is a guard that may not exist.
- **Edge/degenerate cases** — empty pools, no-winner refunds, aborts, voids,
  idempotency (call the same mutation twice; assert no double effect).
- **System invariants after everything** — e.g. double-entry: total debits ==
  total credits; every cached balance == ledger-derived balance; escrow
  accounts drained to expected dust; delta vs baseline attributable solely to
  rows this run created.
- **Regression guard for the fix's neighborhood** — when verifying a fix,
  also prove the adjacent behavior it could have broken still works.

To force rare states (review flags, stuck lineups, past deadlines), direct
SQL surgery on rows *this run created* is legitimate — note each such
simulation in the report so nobody mistakes it for organic behavior.

### 4b. Obstacles between you and the behavior — the boundary protocol

Real systems put barriers in front of the behavior you need to prove: auth,
wall-clock time, third-party APIs, webhooks, payment gateways, emails,
schedulers, randomness, rate limits, human-approval steps. The specific
barrier is never the point — the method is. Work it yourself, from the
repo's own affordances; bouncing the problem back to the user ("can you log
in for me / click this / wait 10 minutes") means the protocol failed. Asking
the user is reserved for genuinely missing secrets or a prod-vs-dev safety
doubt — never for method.

For each barrier, in order:

1. **Classify its role.** Is the barrier the SUBJECT of the verification, or
   just a GATEKEEPER in front of it? A gatekeeper may be bypassed through a
   seam; a subject must be exercised for real (its smallest real slice).
   Most barriers are gatekeepers: auth only establishes *who*, the scheduler
   only establishes *when*, the gateway only establishes *that money moved*.
2. **Find the seam the project already has.** Someone hit this barrier
   before you. Read, in this order: existing tests and their setup/fixtures,
   `scripts/` and dev tooling, env flags and config (`*_FAST`, `*_MOCK`,
   `*_ENABLED`, injectable URLs), the code just inside the barrier (an
   exported function that takes as a parameter what the barrier would have
   established — a userId, a timestamp, a payload). The best seam is the one
   the codebase already uses; inventing a new one is the last resort.
3. **Enter through the seam.** The recurring shapes:
   - *Enter below the boundary*: call the service with the barrier's output
     as plain data (auth → pass userId; webhook → call the handler with a
     crafted payload; scheduler → call the job function directly).
   - *Use the knob*: speed/mock/disable flags that scale constants without
     changing the code path.
   - *Set the data*: when the barrier's effect lives in rows (deadlines,
     statuses, flags), set those fields directly on rows this run owns —
     keeping RELATED fields consistent (move a kickoff back → move its
     market's lock time with it, or you test an impossible state).
   - *Observe instead of receive*: for outbound effects (email, push,
     payout), assert the system's own record (outbox row, ledger entry,
     queued job) rather than the external delivery.
4. **State the equivalence argument.** The report must say WHY the shortcut
   result equals the real result — same code path, deterministic inputs, the
   barrier only gates entry rather than shaping the outcome. If you cannot
   articulate that argument, the shortcut is not valid evidence: the barrier
   was the subject after all, so test its smallest real slice instead.
5. **Leave nothing behind.** Whatever the seam, the rules stand: no product
   code edits to create a bypass, no new permanent hooks, simulated states
   disclosed in the report.

Two worked examples of the same method (from a real audit): a Google-OAuth
app was verified with zero logins by creating users through the real signup
service and passing their IDs (auth = gatekeeper, seam = enter below); a
10-minute deterministic match was verified instantly because the engine
simulates the full match at kickoff and the 10 minutes is playback (time =
presentation → equivalence by construction), with lobby timing compressed
via the project's own `MATCH_FAST` flag and deadline rows moved in the DB —
the equivalence argument for each shortcut stated in the report. When
duration itself is the behavior (accrual, timeout semantics), time is the
subject, not a gatekeeper — clock injection or a real-time run of the
smallest slice is the only honest evidence.

### 5. Output contract

Every check prints one line: `PASS|FAIL  (scenario) description  (expected=X got=Y)`.
End with a summary count and a real exit code. Capture the FULL verbatim
output — never pipe the run through `tail`/`grep` in a way that can hide a
failure or swallow the exit status.

A FAIL is recorded and reported, never "fixed" mid-run — the run is evidence
gathering; fixes are their own task afterward.

### 6. Cleanup (mandatory, part of the deliverable)

- Delete ONLY rows whose IDs this run recorded, in FK-safe order. Never bulk
  delete by table, never truncate — the dev DB belongs to the user.
- System/singleton rows (system accounts, seasons): delete only if this run
  created them.
- Delete the temp script.
- Prove it: post-run table counts == pre-run snapshot, and
  `git status --porcelain` == the pre-run snapshot. Paste both in the report.
  If an aborted earlier attempt left rows, clean those up ID-scoped first and
  say so.

### 7. Report

Outcome first: `N/N checks passed` or the list of failures with numbers.
Then: scenario table (expected vs actual), verbatim output tail + exit code,
cleanup proof, and any simulated states (SQL surgery) disclosed. If gaps in
the permanent test suite made this run necessary, end with the recommendation
to convert the scenarios into committed integration tests.

## Graduating a proof into a committed integration suite

A runtime proof establishes the code works today; only a committed test
keeps proving it. When the scenarios matter enough to repeat (money paths,
release gates), convert them — these conventions came out of doing exactly
that and are each load-bearing:

- **Separate suffix + runner config** (e.g. `*.itest.ts` with its own vitest
  config) so the unit runner never collects DB tests and the DB suite never
  runs without meaning to. Serial file execution — the files share one
  database.
- **Fail loudly without a database.** A missing `DATABASE_URL` must throw
  with a clear message in setup — a conditional skip turns the suite into a
  silent illusion the first time an environment forgets the variable.
- **Same cleanup discipline as one-off runs**, plus prove it: the whole
  suite must pass twice in a row against the same database. Run-twice is the
  cheapest idempotency proof there is.
- **Nondeterministic engines**: don't fight the randomness with reruns —
  place bets/inputs so every possible outcome branch is exhaustively
  asserted, or branch the test on the actual result with both branches fully
  asserted.
- **Forced failures must respect FK reality**: you often cannot DELETE a row
  other rows reference — rename/patch a discriminator on rows the run owns
  to hit the identical error path, restorable byte-for-byte.
- **Wire it as a required CI gate**: fresh database service → migrate from
  zero → seed whatever data pools the real services draw from (squad
  generators, catalogs — a fresh DB is emptier than any dev DB, and this is
  where rehearsal finds surprises) → run the suite; make release/deploy
  depend on the job.
- If the suite's helpers live outside the app's tsconfig include, give the
  directory its own tsconfig extending the app's so the IDE typechecks them
  with the same aliases the runner resolves.

After graduation, retire the scratch scripts — two sources of truth for the
same scenarios will drift.

## Iron rules

1. Dev database only; confirm before connecting.
2. One temp script; zero edits to tracked files; deleted at the end.
3. Real services only; SQL is for setup, assertions, and forced rare states.
4. Cleanup is ID-scoped and proven by snapshot comparison — silence is not proof.
5. Full output + real exit code; failures reported, not patched mid-run.

---
name: fableexp-ci-gates
description: Author new CI test/deploy gates that pass on the first push, and diagnose failures that happen only in CI — the two halves of the same discipline. Use when adding any CI job (e2e, integration, lint, schema checks), wiring a job as a release/deploy prerequisite, or whenever a test passes locally but fails in CI (or vice versa) — flaky spec, timeout on slow runners, works-on-my-machine, missing env, empty fresh database. Triggers on: add CI job, e2e in CI, integration tests in CI, gate the deploy, CI only failure, fails in CI passes locally, flaky test, flaky e2e, GitHub Actions job, pipeline red, works locally.
---

# CI Gates

A CI gate earns its keep twice: by catching real regressions, and by never
crying wolf. Both halves below come from the same day of real incidents —
a new e2e job that passed first-push only because the entire job was
rehearsed locally beforehand, and a spec that had passed every local run for
weeks then failed on its very first CI run.

## Authoring a new gate (pass on the first push)

The GitHub runner is the worst machine your suite will ever meet: slower,
emptier, and configured only with what you explicitly gave it. Author for
that machine, not yours.

1. **Rehearse the ENTIRE job locally before writing the YAML.** Create a
   scratch database, then execute the job's steps in order by hand: install
   → build deps → migrate from zero → seed → run. The rehearsal is where you
   discover the surprises — the classic one being fresh-DB data assumptions:
   a suite that ran for months against a dev DB full of accumulated rows
   (player pools, catalogs, lookup data) breaks on a zero-migrated database.
   Whatever the rehearsal forced you to seed becomes a seed step in the job.
2. **Boot with ONLY the job's env.** Hide local .env files and start the app
   with exactly the variables the YAML will provide (`env -i` style), then
   hit a few routes. This is the only reliable way to enumerate hidden env
   dependencies — grepping for env reads misses transitive ones and
   over-reports optional ones. Supply dummies only where boot actually fails.
3. **One job per test layer**, mirrored from an existing job in the same
   workflow (service containers, install steps) rather than written fresh.
   Keep fast layers in their own jobs so a slow layer doesn't stretch them.
4. **Never pipe the gating command** through tail/grep/head — pipes can
   swallow the exit code and truncate the failure header. The raw command IS
   the step.
5. **Gate the release/deploy on it** (`needs: [...]`). A test job that
   doesn't block anything is a dashboard, not a gate.
6. Pin tool installs to the project's own devDependency versions (run
   installers via the package context, e.g. `pnpm --filter app exec
   playwright install`), so CI can't drift from the lockfile.

## Diagnosing CI-only failures

A CI-only failure is a real defect in the test or the app until proven
otherwise — never blind-rerun more than once, and never widen a timeout
without naming what the time is FOR. Classify first; each class has a
distinct signature and fix:

- **Timing / speed** — the runner is slower, so races that fast machines
  always win start losing. Signature: element/state "not found" or timeout
  on an interaction that works locally. The canonical web case: a
  DOM-presence check "waits for hydration" but SSR markup satisfies it
  before hydration, and a fixed sleep sized on a fast machine expires too
  early — the click lands on a dead button. Fixed sleeps calibrate to the
  fastest machine that ever ran them. Fix with retry-action-until-observable
  (Playwright: `expect(async () => { await trigger.click(); await
  expect(popover).toBeVisible({timeout: 1000}); }).toPass()`), not a bigger
  sleep.
- **Environment** — missing/dummy env var, service not up, port mismatch,
  headless differences. Signature: failure at boot or first connection, not
  mid-test. The authoring-side boot check (above) prevents these; when one
  slips through, diff the job's env against a local boot that works.
- **Data** — fresh DB emptier than any dev DB (seed pools missing, no
  sessions, sequence/ID assumptions). Signature: "not enough X" / empty
  lists in flows that always worked locally.
- **Resources** — memory/CPU caps, parallelism the runner can't sustain.
  Signature: OOM kills, wildly stretched durations, only-under-parallelism
  failures.

After fixing an instance, **grep the whole suite for the same pattern** —
the race you just fixed was almost certainly copy-pasted; the other copies
are latent (they're "protected" by sleeps sized to your machine). Fix them
in the same change.

When a run goes red, read WHICH job and WHICH step failed before theorizing
— a red "deploy" step after green test jobs is an infra/environment problem
(often in systems the commit never touched), not a test problem; conversely
a green run proves only the layers that actually executed.

Verify the fix by re-running the affected spec locally AND letting CI run it
— a CI-flake fix is only proven by the environment that exposed it.

---
name: fableexp-migration-integrity
description: Audit and repair database migration integrity — journal/ledger drift, migrations recorded-but-never-applied, hand-edited or fabricated journal timestamps that silently skip later migrations, bookkeeping tables out of sync with actual schema, and snapshot/live-schema divergence. Drizzle-focused recipes with principles that transfer to any migration tool (Prisma, Knex, Flyway, Alembic). Use BEFORE trusting any "migrations are fine" claim and whenever: a new migration silently doesn't apply, db:migrate says success but the DDL is missing, fresh-environment deploys differ from dev, CI schema-verify fails, drizzle journal or _journal.json or __drizzle_migrations comes up, migration files were hand-edited
---

# Migration Integrity

A migration system has three sources of truth that must agree: the migration
FILES (+ journal ordering), the DATABASE BOOKKEEPING (which migrations the
runner believes are applied), and the ACTUAL SCHEMA (what DDL really ran).
Every failure mode in this skill is one of these three drifting from the
others — usually silently, usually discovered much later on a fresh
environment. Real incidents this skill is built from: a journal entry with a
hand-fabricated FUTURE timestamp that made the runner skip every later
migration on fresh DBs; bookkeeping that stopped mid-history while later
migrations were physically applied; and one migration recorded as applied
whose DDL had never executed at all.

## Why timestamps matter (drizzle specifics)

Drizzle's migrator applies journal entries whose `when` is greater than the
last applied entry's `created_at` in `__drizzle_migrations`. Consequences:

- A journal `when` set in the FUTURE (fabricated, or hand-"fixed") makes every
  entry after it invisible to the runner until that future date — locally
  things look fine because the dev DB was migrated before the edit.
- Non-monotonic `when` values reorder or skip application on fresh databases,
  so dev (incremental) and prod/CI (from scratch) end up with different schemas.
- Editing an already-shipped migration file changes nothing on DBs that
  already recorded it — the runner will never re-run it.

The same model applies to most tools: a version table + an ordered list of
files. Adapt the queries; the drift taxonomy is identical.

## Audit protocol

Run all four checks; each is cheap. Only reading — no repairs yet.

1. **Journal internal consistency.** Every entry's `when` strictly increasing,
   none in the future, tags match files on disk one-to-one (no orphan files,
   no missing files). In this repo shape: `drizzle/meta/_journal.json` vs
   `drizzle/*.sql`. If the project has a journal checker script (e.g.
   `check:journal`), run it AND still eyeball monotonicity — a checker only
   catches what it was written to catch.
2. **Bookkeeping vs journal.** Compare the runner's table
   (`SELECT * FROM drizzle.__drizzle_migrations ORDER BY created_at` — check
   which schema it lives in) against the journal: same count, same order,
   hashes present. Bookkeeping that stops early while later DDL exists in the
   schema means someone applied migrations out-of-band.
3. **Recorded vs actually applied.** For each recent migration, verify its
   DDL really exists: enums have the values, indexes exist (`\d table`),
   CHECK constraints present, columns match. "Recorded as applied" is a claim;
   the catalog is the evidence. Prioritize the migrations around any anomaly
   found in checks 1–2.
4. **From-scratch replay.** The strongest proof: run the full migration chain
   against a throwaway database (fresh container/schema), then diff the result
   against the snapshot/live expectations (use the project's verify script if
   one exists). Dev DBs migrate incrementally and hide ordering bugs; only a
   zero-to-latest replay exercises what a new environment will experience.

## Repair protocol

Repairs are surgical and each one must be re-proven by re-running the audit,
finishing with the from-scratch replay.

- **Fabricated/out-of-order timestamp**: set `when` to a value strictly
  between its neighbors — never "now" (that would leapfrog later entries) and
  never renumber/reorder shipped files.
- **DDL recorded but missing**: apply the missing statements manually AFTER
  checking existing data won't violate them (constraints against live rows).
  Apply exactly what the migration file says — don't improvise "equivalent" DDL.
- **Applied but not recorded**: backfill bookkeeping rows with the correct
  hash the runner would have computed (read how the tool hashes — for drizzle,
  sha256 of the migration file content) and timestamps consistent with the
  journal. Guessing hashes corrupts future runs.
- **Never** hand-edit snapshot files to make generation "work", and never
  `git checkout --` over a dirty migrations directory — you may be destroying
  the user's uncommitted work. Fix forward via the tool's generate command.

## Every environment carries its own copy of the poison

Repairing the journal FILE is not the end of the repair. Every long-lived
database that ever ran migrations under the bad journal recorded the bad
values into its own bookkeeping table — dev, staging, prod, each
independently. Field incident: journal timestamp fixed and dev bookkeeping
backfilled, all local + CI gates green — and the very next prod deploy
failed at schema verification, because prod's bookkeeping row still carried
the fabricated future timestamp as its high-water mark, silently skipping
the new migration while `db:migrate` reported success.

Therefore, after any journal/timestamp repair:

1. Enumerate every long-lived database (dev, staging, prod — CI is ephemeral
   and exempt). For prod behind a private network, look for the provider's
   public proxy URL (e.g. Railway's `DATABASE_PUBLIC_URL`).
2. On each, read the bookkeeping table and compare against the corrected
   journal (order, values, count). The from-scratch CI replay CANNOT catch
   this class — the drift lives only in the long-lived environment.
3. Repair is a surgical single-row UPDATE setting the poisoned value to the
   corrected journal value (never bulk rewrites), then re-run the deploy and
   confirm the pending migration actually applied (check the DDL in the
   catalog, not the migrator's success message).

A schema-assertion gate in the deploy pipeline (verify live schema against
the snapshot as a preDeploy step) is what turns this failure from silent
corruption into a blocked deploy — recommend one wherever it's missing.

## Prevention (recommend after any repair)

- Migrations come from the generator (`db:generate`), never hand-written
  snapshots or hand-edited journals; hand-edits are how every incident above
  started.
- CI runs BOTH: journal validity check AND from-scratch migrate + schema
  verify on a disposable database. Incremental-only CI cannot catch ordering
  drift.
- After generating any migration, run the audit's checks 1 and 4 before
  committing — thirty seconds now versus a broken fresh deploy later.

## Report format

Verdict first: CLEAN / DRIFTED (list each drift with file:line or table row
evidence) / REPAIRED (what was changed, exactly, and the re-audit proof).
Always state which of the three truth sources disagreed and why, and paste
the from-scratch replay result when one was run.

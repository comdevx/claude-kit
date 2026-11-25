---
name: task-management
description: >-
  Task lifecycle management with docs/task.md tracking. Use when creating tasks,
  starting work on tasks, completing tasks, finding next work, resuming context
  from a previous session, managing task files, or when a plan is approved and
  implementation is about to begin. Triggers on: create task, start task,
  complete task, task list, next task, resume work, what should I work on,
  docs/task.md, pick up where we left off, plan approved, before implementation,
  after implementation complete.
---

# Task Management

## Tracking

- **Task list**: `docs/task.md` — format: `| # | Task Title | Status | Ref |` with ⬜/✅
- **Task details**: `docs/tasks/task-X.md` (one file per task)

## Creating Tasks

**Step 0**: Check size — if too large (10+ files, vague scope, entire phase), AUTO-SPLIT without asking.

**Size guideline**: 1 session (~50-100 turns Opus, ~50-70 Sonnet, ~30-40 Haiku)

1. `git pull` (if git project)
2. Read `docs/task.md` for latest task number (create if first task)
3. Create `docs/tasks/task-X.md` using template at `references/template.md` in this skill directory
4. Add row to `docs/task.md`
5. Commit & push task files (if git project)
6. Confirm to user

## Working on Tasks

- Update checkboxes (`- [ ]` → `- [x]`) in task detail file immediately as each criterion is completed
- **After every commit**, update `## Commits` section in the task detail file immediately

## Completing Tasks

1. Update ALL checkboxes in task detail file first
2. Verify `## Commits` section is complete — every commit made for this task must be listed
3. Prove the behavior, not just the suite — this step is NOT optional and NOT satisfied by green unit tests alone:
   - Run every test suite the repo has (including layers CI doesn't run, e.g. e2e) — do NOT mark complete if any fails
   - If the task touched flow/transactional/service-layer logic (money movement, state machines, multi-step DB writes, lifecycle hooks), execute the real flow end-to-end yourself: use the `fableexp-runtime-flow-verification` skill (real services against the real dev DB) or drive the app/e2e. A unit suite that mocks the boundary proves arithmetic, not behavior — checking a box on top of it is fiction.
   - Record what was executed and the result (counts, exit codes) in the task detail file
4. Verify all acceptance criteria met — each criterion must name the evidence (test or execution) that proves it
5. Report remaining items: "Remaining Items: None" or list each with reason
6. Add completion notes to task detail file
7. Update `docs/task.md` status ⬜ → ✅

## When a Planning Phase Precedes Implementation

If a design or planning phase happens before coding (e.g., brainstorming → plan → execute), adapt the task lifecycle:

1. **During planning** — use TaskCreate todos for process tracking (each planning step = one todo). Do NOT create docs/task.md entry yet — scope is still being defined.
2. **After plan is approved → Create Task** — NOW create `docs/task.md` entry + detail file:
   - Acceptance criteria = one checkbox per plan task
   - Implementation notes = key files from the plan
   - Context = links to design doc and plan file
3. **During implementation** — update task detail file as each plan task completes:
   - Mark acceptance criteria checkboxes (`- [ ]` → `- [x]`)
   - Update `## Commits` section after every commit
4. **After implementation complete → Complete Task** — follow normal completion rules above

**Key rule:** docs/task.md entry is created AFTER plan approval, not before planning begins. Before that point, scope and acceptance criteria aren't defined yet.

## Finding Next Work

Read `docs/task.md` → find first ⬜ task → read its detail file → suggest to user.

## Resuming Context (new request comes in)

Before starting new work (Task Mode), scan `docs/task.md` for tasks related to the request — **regardless of status (✅ or ⬜)**. Match by title/keyword overlap with the request. If a related task exists, read its detail file(s) first to pick up prior decisions, scope, and progress.

The SessionStart hook (`~/.claude-kit/hooks/task-status.sh`) injects the open tasks and the first open task's `## Handoff` notes automatically; still read the detail file before resuming.

## Handoff (end of session)

Before a session ends with a task still open, overwrite the task detail file's `## Handoff` section: what is done, the exact next step, blockers/open questions. Write it so a fresh session with no conversation history can continue without asking.

## Decision Log (`docs/decisions.md`)

Product and architecture decisions (what was chosen, why, date, who decided) live in `docs/decisions.md`, one entry per decision, newest last. Format:

```
## D-NNN: <decision title> (YYYY-MM-DD)
- Decision: ...
- Why: ...
- Rejected: <alternative> — <reason>
```

- Record a decision when the user settles a product/goal choice or a design choice that a later session could plausibly reverse without knowing the reason.
- Never silently reverse a recorded decision: raise it with the user first, then add a new entry that supersedes the old one (mark the old one `Superseded by D-NNN`).
- Decisions are the "why"; the design docs (GDD, architecture, plan) are the "what". Do not duplicate reasoning in both.

## Unrelated Bugs

Note in current task's completion notes → finish current task → auto-create bug fix tasks after.

## Rules (apply across all task operations)

- Never start coding without a Task (plan ≠ Task)
- Never create tasks without reading current task list first
- Never skip the detail file
- Never mark complete with failing tests or unmet criteria
- Never report complete without listing remaining/skipped items
- Never fix unrelated bugs during current task
- Never create bug tasks mid-work (wait until current task is done)

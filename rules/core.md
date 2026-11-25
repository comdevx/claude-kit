# Core Rules (every task, every model)

## Classify every request: code work or not

- Decide per request whether it is code work (source files, scripts, tests, build/CI config).
- NOT code work: chat, questions, explanations, research, writing and editing prose,
  video/audio/image/media work, file organisation.
- Code work: implementing, fixing, refactoring or testing program code, including small
  scripts written for a non-code task; and planning or designing software that will be built,
  including a new project before any code exists.
- MUST Read `~/.claude-kit/rules/code.md` (by its absolute path: expand `~` to the home
  directory) before planning, delegating, or making code changes, unless it is already in
  context.
- Code essentials, even when that file was not read:
  1. Every code change ships with tests; a bug fix needs a regression test that fails before
     the fix and passes after it (red, then green).
  2. Verify by real execution (run the tests, the app, the changed path) before claiming done.
  3. Visual UI changes need a real HTML/CSS mockup approved by the user before touching code.
  4. Delegate non-trivial code edits to subagents; edit directly only trivial changes (a few
     lines, location known, no exploration or test run).
  5. Features touching money, items, permissions, sessions or multi-user state need an
     abuse-case section in the plan.

## Deciding vs asking

- The user's ideas are suggestions, not orders: evaluate them on the evidence, then adopt,
  adapt or push back with reasons.
- Make technical decisions yourself. Ask only for genuine product or goal choices that only
  the user can make.

## Agents and model choice

- Dispatch independent subtasks (read-only research, checks of different aspects) in
  parallel; run dependent ones, or ones that write the same files, sequentially in
  dependency order.
- Delegate asynchronously: keep working while agents run, monitor them, and intervene when
  one goes off track or lacks context. Once delegated, do not duplicate or re-derive its work.
- Set `model` explicitly on every agent call, code or not; never leave it unset (that
  inherits the expensive parent model): `haiku` for mechanical or lookup work (searches,
  listings, formatting, simple renames, running a known command); `sonnet` for well-specified
  implementation, tests, docs and routine verification; `opus` only for design decisions,
  ambiguous debugging, cross-cutting refactors or adversarial review; the top-tier model
  (`fable`) only for highest-stakes architectural review.

## Browser automation

- Launch automated browsers muted (`--mute-audio`). Right after creating each browser context
  call `await context.grantPermissions(['local-network-access'])`, otherwise Chrome prompts
  for local network access on every fresh profile.
- Close browsers cleanly (`try { ... } finally { await context.close() }`); never force-kill
  the browser (`pkill`, `kill -9`) or exit the process (`process.exit()`) with a context open.
- Include these rules in every agent prompt that drives a browser.

## Fable method skills

The baseline discipline is already in effect each session (injected, or native on
Fable-class models): do NOT invoke `/fable-method` routinely. Invoke it only on demand: for
the full procedure (flowcharts, failure modes) on a hard task, or for its subcommands (`plan`: stop after the plan; `audit`: grade finished work;
`report`: rewrite an answer outcome-first).

## Plans and tasks

- Finish all research before writing a plan file, ask open questions first, then write it
  once instead of updating it repeatedly.
- Track tasks in `docs/task.md` with detail files in `docs/tasks/`, unless the
  project already uses another tracker. Create the task entry after the plan is approved,
  not before brainstorming: acceptance criteria come from the approved plan.

## Closing a task

When the user closes a task ("close task", "task done", "finished"):

1. Mark the task complete in `docs/task.md`.
2. If notable problems were encountered, save a lesson: in `docs/lessons/` when the project
   has that directory (shared with the team), otherwise in your profile's `lessons/` directory
   (default `~/.claude/lessons/`, or `$CLAUDE_CONFIG_DIR/lessons/`). Name it `YYYY-MM-DD_short-slug.md` and append a one-line entry to
   `INDEX.md` in the same directory. Skip this step when nothing notable happened.
3. Remove the task's own git worktrees once their branch is merged (including temporary,
   detached and long-running/gate worktrees whose gate passed) with `git worktree remove`,
   and delete the merged branch. Never remove a worktree that has uncommitted changes, is in
   use by another session, or whose branch is not merged; list those instead.

Lesson format:

```
# [Main problem title]
project: [project name]
date: [YYYY-MM-DD]

## Problems
### 1. [Problem title]
- Symptom: ...
- Root cause: ...
- Solution: ...
```

When a lessons index is in context and the upcoming task touches an indexed entry, Read that
lesson file before starting. Do not re-read the index itself.

## Memory

- Layers: repo `CLAUDE.md` + `docs/lessons/` (team knowledge), then your global config dir
  (personal preferences), then per-project memory (rare).
- Before saving a memory, decide: team knowledge (repo) or personal preference (global).
  Feedback that applies to all projects goes to global memory only.
- Project memory records only decisions (and why), gotchas and project-specific constraints.
  Never record the tech stack, file structure or patterns derivable from the code.
- One topic lives in exactly one place: delete duplicates, do not maintain them.

## Skill hygiene

- Before creating a skill, list existing skills and check for topic overlap; if one
  overlaps, update it instead. Use a skill-authoring skill (e.g. skill-creator) if available.
- One topic, one skill. A superseded skill is deleted or merged, never left to rot.
- When editing a skill, sweep for siblings: the same instruction duplicated across
  `CLAUDE.md`, hooks and skill descriptions must end up in one place, with pointers elsewhere.

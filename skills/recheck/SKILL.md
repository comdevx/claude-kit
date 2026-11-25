---
name: recheck
description: >-
  Re-analyze with an external AI CLI (Codex, Copilot, Cursor) using GPT frontier
  model. ONLY trigger when the user explicitly mentions "codex", "copilot",
  "cursor", or invokes /recheck. Do NOT trigger on generic phrases like
  "second opinion", "cross-check" unless a CLI name is also mentioned.
  Triggers on: /recheck, codex recheck, copilot recheck, cursor recheck,
  send to codex, send to copilot, send to cursor, codex review, copilot review,
  cursor review.
allowed-tools: Bash(codex:*), Bash(gh:*), Bash(copilot:*), Bash(cursor:*), Bash(brew:*), Bash(npm:*)
---

# Recheck — Second Opinion via External AI CLI

Send Claude's analysis to an external AI CLI (Codex / Copilot / Cursor) for a second opinion. Forces GPT frontier model with configurable reasoning effort.

## Step 1: Parse Arguments

Split `/recheck` arguments into 3 optional parts:

- **CLI**: `codex` | `copilot` | `cursor` — if omitted, auto-detect
- **Effort**: `high` | `xhigh` | `max` — if omitted, default `high`
- **Scope**: `security` | `architecture` | `performance` | etc. — if omitted, all scopes

Examples:
- `/recheck` → auto CLI, high, all scopes
- `/recheck codex xhigh` → codex, xhigh, all scopes
- `/recheck copilot security` → copilot, high, security only
- `/recheck cursor architecture xhigh` → cursor, xhigh, architecture only

## Step 2: Detect CLI + Find Frontier GPT Model

### 2a: Select CLI

If user specified a CLI, use that. Otherwise auto-detect in priority order — stop at the first one found:

```bash
if command -v codex &>/dev/null; then echo "codex"
elif command -v cursor &>/dev/null; then echo "cursor"
elif command -v copilot &>/dev/null; then echo "copilot-direct"
elif command -v gh &>/dev/null && gh copilot --version --no-auto-update &>/dev/null; then echo "copilot-gh"
else echo "none"
fi
```

Copilot has two invocation forms — use whichever is found:
- `copilot` — standalone binary (e.g. via `npm install -g @github/copilot` or `brew`)
- `gh copilot --` — via GitHub CLI wrapper (requires `--` to prevent flag interception)

Store the detected form and use it for all subsequent Copilot commands in this session.
When this document shows `<COPILOT>` in commands, substitute the detected form:
- If `copilot-direct`: use `copilot`
- If `copilot-gh`: use `gh copilot --`

If no CLI found, inform the user how to install:
- Codex: `npm install -g @openai/codex` or `brew install codex`
- Copilot: `npm install -g @github/copilot` (standalone) or install via `gh` CLI
- Cursor: install Cursor IDE and add `cursor` to PATH

Then stop.

### 2b: Find Frontier GPT Model (query every time, never hardcode)

**Codex:**
```bash
grep '^model\s*=' ~/.codex/config.toml 2>/dev/null | head -1 | sed 's/.*"\(.*\)"/\1/'
```
Uses the `model` field from user's config (not `model_reasoning_effort` or other `model_*` fields). No `-m` flag needed.

**Copilot:**
```bash
<COPILOT> -p "hi" --model gpt-5.6-sol --no-ask-user --no-auto-update --effort none 2>&1 | head -1
```
Add `--no-auto-update` to prevent Copilot from silently updating before user confirmation in Step 3.
Test from highest model down. If error, fall back one version at a time:
`gpt-5.6-sol` → `gpt-5.5` → `gpt-5.4` → if none found, inform user.

**Cursor:**
```bash
cursor agent --list-models 2>&1 | grep '^gpt-' | grep -E '\-<EFFORT>$' | sort -Vr | head -1
```
Cursor model names already include the effort suffix (e.g. `gpt-5.6-sol-high`, `gpt-5.6-sol-xhigh`).
Filter by the desired effort level directly — do NOT append effort suffix manually, or the model name will be invalid.

If no GPT model found, inform the user and stop.

## Step 3: Check for Updates (ask only when update available)

### 3a: Get current version

```bash
# Codex
codex --version 2>&1

# Copilot
<COPILOT> --version --no-auto-update 2>&1

# Cursor
cursor --version 2>&1
```

### 3b: Detect installation method and check for updates

**Codex** — detect how it was installed, then check accordingly:

```bash
# Check if installed via brew
if brew list --cask codex &>/dev/null; then
  brew outdated --cask codex 2>&1
  echo "EXIT:$?"
  echo "SOURCE:brew"
# Check if installed via npm
elif npm list -g @openai/codex &>/dev/null; then
  npm outdated -g @openai/codex 2>&1
  echo "EXIT:$?"
  echo "SOURCE:npm"
else
  echo "SOURCE:unknown"
fi
```

Interpret results — check BOTH exit status and output:
- `SOURCE:brew` + exit 0 + empty output → already latest
- `SOURCE:brew` + exit 0 + has output → update available
- `SOURCE:npm` + exit 0 + empty output → already latest
- `SOURCE:npm` + exit 0 + has output → update available
- `SOURCE:unknown` → cannot check, show version and ask user
- Non-zero exit → unable to check, show version and ask user

**Copilot / Cursor** — no dry-run check available. Show version and ask.

### 3c: Ask or skip

**If already latest** → inform user (e.g. "Codex v0.144.2 — already latest") and proceed to Step 4. Do NOT ask.

**If update available or unable to check** → ask using AskUserQuestion:
- "Update [CLI]? Current: [version]"
- Options: "Yes, update" / "No, skip"

### 3d: Run update (if approved)

```bash
# Codex (uses detected source)
codex update 2>&1

# Copilot
<COPILOT> update 2>&1

# Cursor
cursor agent update 2>&1
```

If user declines, continue with the current version.
If update fails, warn the user and continue.

## Step 4: Prepare Analysis

```bash
rm -rf /tmp/recheck && mkdir -p /tmp/recheck
```

Write a summary of Claude's analysis from this session to `/tmp/recheck/claude-analysis.md`. Cover only what was actually analyzed:

- Scope — what was analyzed (files, modules, features)
- Architecture — patterns, dependencies, data flow
- Implementation — code quality, correctness
- Security — issues found or confirmed safe
- Performance — bottlenecks, optimization opportunities
- Potential Issues — bugs, edge cases, missing error handling
- Recommendations — prioritized

If a scope argument was provided, write only the relevant sections.
Skip any section not applicable to the analysis performed.

## Step 5: Build Prompt

Write `/tmp/recheck/prompt.md` containing:

1. Instructions to analyze independently — not just agree with everything
2. For each section: state AGREE / PARTIALLY AGREE / DISAGREE with reasoning
3. Identify issues Claude missed
4. Identify false positives or overstated findings from Claude
5. Add independent findings not covered by Claude
6. Embed actual content from `/tmp/recheck/claude-analysis.md` in an `<analysis>` block at the end

Require references to file paths, line numbers, and function names as evidence.

## Step 6: Execute

Run the selected CLI with the chosen effort level:

**Codex:** (effort via `-c`, model via `-m` using value from Step 2b)
```bash
codex exec - --ephemeral --skip-git-repo-check -s read-only \
  -m <CODEX_MODEL> \
  -c model_reasoning_effort="<EFFORT>" \
  -o /tmp/recheck/response.md \
  < /tmp/recheck/prompt.md 2>&1
```
Pass the model explicitly with `-m` using the value discovered in Step 2b (e.g. `gpt-5.6-sol`).
Do NOT use `--ignore-user-config` — it blocks the model config but does NOT block repo `AGENTS.md`.

**Copilot:** (effort via `--effort` flag, prompt via stdin)
```bash
cat /tmp/recheck/prompt.md | <COPILOT> \
  --model <FRONTIER_GPT> \
  --effort <EFFORT> \
  --no-ask-user \
  --no-auto-update \
  --no-custom-instructions \
  --mode plan \
  --output-format text > /tmp/recheck/response.md 2>&1
```
- Do NOT use `-p` with piped input — Copilot ignores stdin when `-p` is present. Pipe directly without `-p`.
- `--mode plan` restricts Copilot to read-only analysis (no writes, no shell execution).
- `--no-custom-instructions` prevents repo `AGENTS.md` from altering the reviewer's behavior.
- `--no-auto-update` prevents silent updates.

**Cursor:** (effort already in model name — do NOT append suffix, prompt via stdin)
```bash
cat /tmp/recheck/prompt.md | cursor agent \
  --model <FRONTIER_GPT_WITH_EFFORT> \
  --mode plan --trust \
  --output-format text > /tmp/recheck/response.md 2>&1
```
- Do NOT use `-p` — in Cursor, `-p/--print` is a boolean flag (print mode), not a prompt argument. Piped stdin is read automatically without `-p`.
- `<FRONTIER_GPT_WITH_EFFORT>` is the full model name from Step 2b (e.g. `gpt-5.6-sol-high`).
- Do NOT manually append effort — the model name already includes it.

Run all exec commands with the Bash tool's `timeout` parameter set to 120000 (120 seconds). If it times out, inform the user and show Claude's analysis only.

## Step 7: Compare & Cleanup

Read `/tmp/recheck/response.md` and present a comparison:

- Critically analyze the external AI's response — do not just copy-paste
- Show agreements, disagreements, and unique findings from each side
- If the external AI provides information Claude believes is incorrect, state the reasoning
- Synthesize final recommendations from both perspectives

```bash
rm -rf /tmp/recheck
```

## Auto-trigger Conditions

**Trigger when:**
- User mentions codex, copilot, or cursor in a review/analysis context
- User invokes /recheck

**Do NOT trigger when:**
- No CLI name is mentioned (prevents false triggers)
- Already running a recheck (prevents loops)

## Error Handling

| Scenario | Action |
|----------|--------|
| No CLI found | Show install instructions and stop |
| Specified CLI not installed | Show install instructions for that CLI and stop |
| No GPT model found | Inform user that CLI has no GPT model and stop |
| Auth failed | Show login command for the CLI |
| Update failed | Warn and continue with current version |
| Exec timeout >120s | Show Claude analysis only |
| Exec error | Suggest diagnostic command (codex doctor / copilot --help) |
| Empty response | Inform user and show Claude analysis only |
| No prior analysis | Ask user what to analyze first |

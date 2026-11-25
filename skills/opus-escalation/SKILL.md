---
name: opus-escalation
description: >-
  Escalate debugging or analysis to an Opus subagent when the current non-Opus
  model cannot solve a problem. Use when directly asked to analyze or find root
  cause, when a fix was applied and tested but behavior is unchanged, when 3+
  fix attempts have failed, or when architectural analysis exceeds the current
  model's capability. Triggers on: analyze, find root cause,
  fix still same, still not working, stuck debugging, repeated fix failures,
  architectural uncertainty, escalate to Opus.
---

# Opus Escalation

When you hit the ceiling of your own reasoning, or your diagnosis keeps turning out wrong, dispatch an Opus subagent instead of thrashing. Opus has more reasoning depth for root-cause analysis.

## When to Escalate

| Situation | Action |
|---|---|
| Asked to analyze / find the root cause | Dispatch Opus immediately |
| A fix was applied and tested, but the behavior is unchanged | Dispatch Opus to re-diagnose |
| 3+ fix attempts have failed | Dispatch Opus |
| Fundamental uncertainty about the architecture | Dispatch Opus |

**Guard:** if the current session already runs on Opus, stop and present your findings to the user directly.

## Dispatch Pattern

```
Agent({
  description: "Opus root cause analysis",
  model: "opus",
  prompt: [escalation prompt — see template below],
  run_in_background: false
})
```

`model: "opus"` resolves to the Opus model configured for your install (the `ANTHROPIC_DEFAULT_OPUS_MODEL` env var overrides it).

**Cache note:** the Opus subagent always starts with a cold cache and shares nothing with the current session, so the prompt must be fully self-contained.

## Escalation Prompt Template

```
You are an expert debugger/analyst. Your job is root cause analysis only — do not implement fixes.

## Problem
{1-2 sentence description of what is wrong}

## Error Output
{Exact error messages, stack traces, or unexpected behavior observed}

## Reproduction
{Steps to reproduce, or test command that fails}

## Relevant Code
{Key file paths AND actual code snippets — include snippets because you cannot read files}

## What Was Tried
{For each attempt:
  - Hypothesis: what we thought was wrong
  - Change: what was modified (file:line)
  - Result: what happened after the change}

## Current Assessment
{Best current guess at root cause and where the uncertainty lies}

## Your Task
1. Identify the root cause with evidence
2. Explain why each previous fix failed (what did it miss?)
3. Propose a specific fix strategy (files, lines, changes)
4. Confidence: HIGH / MEDIUM / LOW — if LOW, specify what additional evidence is needed
```

## After Escalation

- **Opus identifies root cause** → implement the fix with the current model, then verify it by running the real thing (see the kit's discipline rules)
- **Opus identifies architectural problem** → present to human partner
- **Opus confidence LOW** → gather the additional evidence Opus specified → re-escalate or present to the user

## Integration

Use after your normal systematic-debugging steps have failed; it does not replace them. After the fix, verify by observation (run the real code path), not by assumption.

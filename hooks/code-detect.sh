#!/bin/bash
# Usage: code-detect.sh <pretool|prompt>
#  pretool (PreToolUse Edit|Write|MultiEdit|NotebookEdit|Bash): logs every source-code edit (and every
#          Bash command that writes a source file) to
#          <state>/sessions/<sid>.edits (read by stop-gate.sh); the first one of a session (and of each
#          subagent) also injects rules/code.md once.
#  posttool (PostToolUse Agent|Task): gives the main session code.md after a subagent got it first.
#  prompt  (UserPromptSubmit): one-line testing reminder, only while the session is in code mode.
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$KIT_ROOT/hooks/lib.sh" 2>/dev/null || exit 0

mode="${1:-}"
input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0
sid=$(kit_json_get "$input" session_id)
[ -n "$sid" ] || exit 0
s=$(kit_safe "$sid")

case "$mode" in
  pretool)
    if [ "$(kit_json_get "$input" tool_name)" = Bash ]; then
      # a shell command that writes a source file counts as a source edit
      if [ "$(kit_byte_len "$input")" -gt "${KIT_BASH_MAX:-131072}" ]; then   # bytes, not characters
        p="bash:large"   # too big to decode and parse within the hook timeout: log it, fail safe
      else
        cmd=$(kit_json_get "$input" tool_input.command)
        [ -n "$cmd" ] || exit 0
        p=$(kit_bash_source_write "$cmd") || exit 0
      fi
    else
      p=$(kit_json_get "$input" tool_input.file_path)
      [ -n "$p" ] || p=$(kit_json_get "$input" tool_input.notebook_path)
      [ -n "$p" ] || p=$(kit_json_get "$input" tool_input.path)
      [ -n "$p" ] || exit 0
      p=$(kit_norm_path "$p")
      kit_is_source_path "$p" || exit 0
    fi
    agent=$(kit_json_get "$input" agent_id)
    [ -n "$agent" ] || agent=main
    sd=$(kit_sess_dir)
    # Edit log for the stop gate: one line per source edit (main session or subagent), written
    # BEFORE the once-only injection check so every edit is recorded. Format: epoch agent path.
    printf '%s %s %s\n' "$(date +%s)" "$(kit_safe "$agent")" "$p" >> "$sd/$s.edits" 2>/dev/null
    mark="$sd/$s.inj.$(kit_safe "$agent")"
    [ -f "$mark" ] && exit 0
    text=$(kit_rules_text "$KIT_ROOT/rules/code.md")
    [ -n "$text" ] || exit 0
    : > "$mark"; : > "$sd/$s.code"
    # A subagent got the rules while the main session has not: remember it so the main
    # session receives them on its next Agent/Task PostToolUse or prompt.
    if [ "$agent" != main ] && [ ! -f "$sd/$s.inj.main" ]; then : > "$sd/$s.pending-main"; fi
    kit_emit PreToolUse "$text" "rules/code.md"
    ;;
  posttool)
    # Main-session tool that spawns subagents (matcher Agent|Task).
    [ -z "$(kit_json_get "$input" agent_id)" ] || exit 0
    sd=$(kit_sess_dir)
    [ -f "$sd/$s.pending-main" ] && [ ! -f "$sd/$s.inj.main" ] || exit 0
    text=$(kit_rules_text "$KIT_ROOT/rules/code.md")
    [ -n "$text" ] || exit 0
    : > "$sd/$s.inj.main"; : > "$sd/$s.code"; rm -f "$sd/$s.pending-main"
    kit_emit PostToolUse "$text" "rules/code.md"
    ;;
  prompt)
    sd=$(kit_sess_dir)
    if [ -f "$sd/$s.pending-main" ] && [ ! -f "$sd/$s.inj.main" ]; then
      text=$(kit_rules_text "$KIT_ROOT/rules/code.md")
      if [ -n "$text" ]; then
        : > "$sd/$s.inj.main"; : > "$sd/$s.code"; rm -f "$sd/$s.pending-main"
        kit_emit UserPromptSubmit "$text" "rules/code.md"
        exit 0
      fi
    fi
    [ -f "$sd/$s.code" ] || exit 0
    kit_emit UserPromptSubmit "Code session reminder: a bug fix needs a regression test that fails before the fix and passes after; new behaviour needs tests; a changed user flow needs an e2e run; verify by really running the code and show the output before saying done." "reminder"
    ;;
esac
exit 0

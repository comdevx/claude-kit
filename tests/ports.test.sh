#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
mk_kit; mk_projects
H="$KIT/hooks"
for mode in $MODES; do
  # lessons-index
  prof="$T/profile"; rm -rf "$prof"; mkdir -p "$prof/lessons"
  PAYLOAD='{"session_id":"l1"}'; EXTRA_ENV="CLAUDE_CONFIG_DIR=$prof" run_hook $mode "$H/lessons-index.sh"
  assert_empty "[$mode] lessons: no index -> nothing" "$OUT"
  printf -- '- 2026-01-01 first lesson\n- 2026-01-02 second lesson "quoted"\n' > "$prof/lessons/INDEX.md"
  EXTRA_ENV="CLAUDE_CONFIG_DIR=$prof" run_hook $mode "$H/lessons-index.sh"
  assert_has "[$mode] lessons: index injected" "$OUT" "second lesson"
  valid_json "$OUT" && pass "[$mode] lessons valid JSON" || fail "[$mode] lessons valid JSON" "$OUT"
  assert_not_has "[$mode] lessons: header uses profile path" "$OUT" "~/.claude/lessons"
  awk 'BEGIN{for(i=0;i<600;i++) printf "- entry %04d some lesson text here\n", i}' > "$prof/lessons/INDEX.md"
  EXTRA_ENV="CLAUDE_CONFIG_DIR=$prof" run_hook $mode "$H/lessons-index.sh"
  assert_has "[$mode] lessons: newest kept" "$OUT" "entry 0599"
  assert_not_has "[$mode] lessons: oldest dropped" "$OUT" "entry 0000"
  # default profile = $HOME/.claude
  mkdir -p "$HOME_T/.claude/lessons"; echo "- home lesson" > "$HOME_T/.claude/lessons/INDEX.md"
  PAYLOAD='{}'; run_hook $mode "$H/lessons-index.sh"
  assert_has "[$mode] lessons: default ~/.claude" "$OUT" "home lesson"

  # task-status
  P="$T/proj"; rm -rf "$P"; mkdir -p "$P/docs/tasks" "$P/src"
  cat > "$P/docs/task.md" <<'EOT'
| # | Task | Status | Ref |
|---|------|--------|-----|
| 1 | Done thing | ✅ | x |
| 2 | Open thing | in progress | y |
| 3 | Another | todo | z |
EOT
  printf '# Task 2\n\n## Handoff\n- Next step: wire the thing\n\n## Commits\n' > "$P/docs/tasks/task-2.md"
  echo "decision" > "$P/docs/decisions.md"
  PAYLOAD='{"session_id":"t1","cwd":"'"$P/src"'"}'; run_hook $mode "$H/task-status.sh"
  assert_has "[$mode] task-status lists open" "$OUT" "#2 Open thing"
  assert_not_has "[$mode] task-status hides done" "$OUT" "Done thing"
  assert_has "[$mode] task-status handoff" "$OUT" "wire the thing"
  assert_has "[$mode] task-status decisions pointer" "$OUT" "docs/decisions.md"
  valid_json "$OUT" && pass "[$mode] task-status valid JSON" || fail "[$mode] task-status valid JSON" "$OUT"
  PAYLOAD='{"cwd":"'"$T/work/nogit"'"}'; run_hook $mode "$H/task-status.sh"
  assert_empty "[$mode] task-status silent without docs/task.md" "$OUT"
  mkdir -p "$HOME_T/docs"; cp "$P/docs/task.md" "$HOME_T/docs/task.md"
  PAYLOAD='{"cwd":"'"$HOME_T"'"}'; run_hook $mode "$H/task-status.sh"
  assert_empty "[$mode] task-status ignores docs/task.md in \$HOME" "$OUT"

  # stop-gate (fake claude)
  FB="$T/fb"; rm -rf "$FB"; mkdir -p "$FB"
  TR_NOEDIT="$T/tr-noedit.jsonl"; TR_EDIT="$T/tr-edit.jsonl"
  echo '{"type":"user","message":{"content":"hi"}}' > "$TR_NOEDIT"
  echo '{"type":"assistant","message":{"model":"claude-opus-4-5","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/a.ts"}}]}}' > "$TR_EDIT"
  PAYLOAD='{"session_id":"g1","transcript_path":"'"$TR_NOEDIT"'"}'; run_hook $mode "$H/stop-gate.sh"
  assert_has "[$mode] stop-gate: no source changes -> ALLOW" "$OUT" "no source changes"
  assert_not_has "[$mode] stop-gate: no block" "$OUT" '"decision"'
  PAYLOAD='{"session_id":"g1","transcript_path":"/nonexistent"}'; run_hook $mode "$H/stop-gate.sh"
  assert_has "[$mode] stop-gate: no transcript -> ALLOW" "$OUT" "no transcript"
  PAYLOAD='{"session_id":"g1","transcript_path":"'"$TR_EDIT"'"}'; run_hook $mode "$H/stop-gate.sh"
  assert_has "[$mode] stop-gate: edit but no claude CLI -> fail-open" "$OUT" "fail-open"
  printf '#!/bin/sh\ncat >/dev/null\necho "DENY: tests were not run"\n' > "$FB/claude"; chmod +x "$FB/claude"
  rm -f "$STATE/stop-gate.log"
  mp="$FB:$([ $mode = nojq ] && echo "$NOJQ_BIN" || echo "$PATH")"
  OUT=$(printf '%s' "$PAYLOAD" | env PATH="$mp" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$H/stop-gate.sh" 2>/dev/null)
  assert_has "[$mode] stop-gate: DENY blocks" "$OUT" '"decision":"block"'
  assert_has "[$mode] stop-gate: DENY reason" "$OUT" "tests were not run"
  valid_json "$OUT" && pass "[$mode] stop-gate DENY valid JSON" || fail "[$mode] stop-gate DENY valid JSON" "$OUT"
  for i in 1 2 3 4; do
    OUT=$(printf '%s' "$PAYLOAD" | env PATH="$mp" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$H/stop-gate.sh" 2>/dev/null)
  done
  assert_has "[$mode] stop-gate: loop guard after repeated denies" "$OUT" "loop guard"
  printf '#!/bin/sh\ncat >/dev/null\necho "ALLOW: verified"\n' > "$FB/claude"
  rm -f "$STATE/stop-gate.log" "$STATE"/sessions/stopgate-*   # the deny counter is per session now
  OUT=$(printf '%s' "$PAYLOAD" | env PATH="$mp" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$H/stop-gate.sh" 2>/dev/null)
  assert_has "[$mode] stop-gate: ALLOW verdict" "$OUT" "verified"
  OUT=$(printf '%s' "$PAYLOAD" | env PATH="$mp" CLAUDE_STOP_GATE_CHILD=1 HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$H/stop-gate.sh" 2>/dev/null)
  assert_empty "[$mode] stop-gate: child recursion guard" "$OUT"

  # cursor
  C="$KIT/cursor/hooks"
  PAYLOAD='{"conversation_id":"cv1","file_path":"/a/x.ts"}'; run_hook $mode "$C/record-edit.sh"
  assert_eq "[$mode] cursor record-edit prints {}" '{}' "$OUT"
  PAYLOAD='{"conversation_id":"cv1","command":"npm test","output":"3 passed"}'; run_hook $mode "$C/record-shell.sh"
  [ -s "$STATE/cursor/cv1.log" ] && pass "[$mode] cursor log written in state dir" || fail "[$mode] cursor log written in state dir" "missing"
  assert_has "[$mode] cursor log has EDIT and SHELL" "$(cat "$STATE/cursor/cv1.log")" "SHELL"
  PAYLOAD='{"conversation_id":"cv1","status":"completed","loop_count":0}'
  OUT=$(printf '%s' "$PAYLOAD" | env PATH="$mp" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$C/stop-gate.sh" 2>/dev/null)
  assert_eq "[$mode] cursor gate ALLOW -> {}" '{}' "$OUT"
  printf '#!/bin/sh\ncat >/dev/null\necho "DENY: run the tests"\n' > "$FB/claude"
  PAYLOAD='{"conversation_id":"cv2","status":"completed","loop_count":0}'
  printf '{"conversation_id":"cv2","file_path":"/a/y.py"}' | env PATH="$mp" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$C/record-edit.sh" >/dev/null
  OUT=$(printf '%s' "$PAYLOAD" | env PATH="$mp" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$C/stop-gate.sh" 2>/dev/null)
  assert_has "[$mode] cursor gate DENY -> followup_message" "$OUT" '"followup_message"'
  valid_json "$OUT" && pass "[$mode] cursor DENY valid JSON" || fail "[$mode] cursor DENY valid JSON" "$OUT"
  PAYLOAD='{"conversation_id":"cv2","status":"completed","loop_count":2}'
  OUT=$(printf '%s' "$PAYLOAD" | env PATH="$mp" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$C/stop-gate.sh" 2>/dev/null)
  assert_eq "[$mode] cursor gate loop guard" '{}' "$OUT"
  PAYLOAD='{}'; run_hook $mode "$C/session-context.sh"
  assert_has "[$mode] cursor session-context has rules" "$OUT" "DISC-RULES"
  assert_has "[$mode] cursor session-context has core" "$OUT" "CORE-RULES"
  valid_json "$OUT" && pass "[$mode] cursor session-context valid JSON" || fail "[$mode] cursor session-context valid JSON" "$OUT"
done
finish

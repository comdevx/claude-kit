#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
mk_kit; mk_projects
CD="$KIT/hooks/code-detect.sh"
pre() { printf '{"session_id":"%s","cwd":"/w","hook_event_name":"PreToolUse","tool_name":"%s","tool_input":{"file_path":"%s","content":"x"}}' "$1" "${3:-Edit}" "$2"; }
for mode in $MODES; do
  PAYLOAD=$(pre s1 /w/app.ts); run_hook $mode "$CD" pretool
  assert_has "[$mode] pretool .ts injects" "$OUT" CODE-RULES
  assert_has "[$mode] pretool event name" "$OUT" '"hookEventName":"PreToolUse"'
  valid_json "$OUT" && pass "[$mode] pretool valid JSON" || fail "[$mode] pretool valid JSON" "$OUT"
  run_hook $mode "$CD" pretool
  assert_empty "[$mode] pretool once per session" "$OUT"
  PAYLOAD=$(pre s1 /w/other.py); run_hook $mode "$CD" pretool
  assert_empty "[$mode] second source edit same session -> nothing" "$OUT"
  for f in notes.md data.json cfg.yaml a.toml t.csv s.srt c.vtt v.mp4 README.txt; do
    PAYLOAD=$(pre ns_$mode "/w/$f"); run_hook $mode "$CD" pretool
    assert_empty "[$mode] pretool $f -> nothing" "$OUT"
  done
  [ ! -f "$STATE/sessions/ns_$mode.code" ] && pass "[$mode] non-source edit leaves no code mode" || fail "[$mode] non-source edit leaves no code mode" "marked"
  PAYLOAD=$(pre w1 'C:\\Proj\\x\\proj\\main.rs' Write); run_hook $mode "$CD" pretool
  assert_has "[$mode] Windows backslash path" "$OUT" CODE-RULES
  PAYLOAD='{"session_id":"nb","tool_name":"NotebookEdit","tool_input":{"notebook_path":"/w/a.py"}}'; run_hook $mode "$CD" pretool
  assert_has "[$mode] notebook_path with source ext" "$OUT" CODE-RULES

  # subagent: same session id, agent_id differs -> gets its own injection once
  PAYLOAD=$(pre sa1 /w/a.ts); run_hook $mode "$CD" pretool
  PAYLOAD='{"session_id":"sa1","agent_id":"agent-42","agent_type":"general-purpose","tool_name":"Edit","tool_input":{"file_path":"/w/b.ts"}}'
  run_hook $mode "$CD" pretool
  assert_has "[$mode] subagent gets rules though parent already did" "$OUT" CODE-RULES
  run_hook $mode "$CD" pretool
  assert_empty "[$mode] subagent once" "$OUT"
  PAYLOAD='{"session_id":"sa1","agent_id":"agent-43","tool_name":"Write","tool_input":{"file_path":"/w/c.go"}}'; run_hook $mode "$CD" pretool
  assert_has "[$mode] second subagent gets its own" "$OUT" CODE-RULES

  # session-start marks main as injected: pretool does not duplicate
  PAYLOAD='{"session_id":"ss1","cwd":"'"$T/work/gitnode"'","source":"startup"}'; run_hook $mode "$KIT/hooks/session-start.sh" code
  PAYLOAD=$(pre ss1 /w/a.ts); run_hook $mode "$CD" pretool
  assert_empty "[$mode] no double injection after session-start code" "$OUT"

  # prompt reminder
  PAYLOAD='{"session_id":"s1","prompt":"fix it"}'; run_hook $mode "$CD" prompt
  assert_has "[$mode] prompt reminder in code mode" "$OUT" "regression test"
  assert_has "[$mode] prompt event name" "$OUT" '"hookEventName":"UserPromptSubmit"'
  valid_json "$OUT" && pass "[$mode] prompt valid JSON" || fail "[$mode] prompt valid JSON" "$OUT"
  PAYLOAD='{"session_id":"never-code","prompt":"hello"}'; run_hook $mode "$CD" prompt
  assert_empty "[$mode] prompt silent outside code mode" "$OUT"
  PAYLOAD='{"session_id":"ns_'$mode'","prompt":"hello"}'; run_hook $mode "$CD" prompt
  assert_empty "[$mode] prompt silent after only non-source edits" "$OUT"
  rm -rf "$STATE/sessions"
done
# --- main session gets code.md after subagent-only edits (pending-main) ---
sub() { printf '{"session_id":"%s","agent_id":"ag1","tool_name":"Edit","tool_input":{"file_path":"/w/a.ts"}}' "$1"; }
for mode in $MODES; do
  rm -rf "$STATE/sessions"
  PAYLOAD=$(sub pm1); run_hook $mode "$CD" pretool
  assert_has "[$mode] pending: subagent got rules" "$OUT" CODE-RULES
  [ -f "$STATE/sessions/pm1.pending-main" ] && pass "[$mode] pending-main created by subagent injection" || fail "[$mode] pending-main created by subagent injection" "missing"
  PAYLOAD='{"session_id":"pm1","tool_name":"Agent","tool_input":{"prompt":"x"},"tool_response":{}}'; run_hook $mode "$CD" posttool
  assert_has "[$mode] posttool injects code.md to main" "$OUT" CODE-RULES
  assert_has "[$mode] posttool event name" "$OUT" '"hookEventName":"PostToolUse"'
  valid_json "$OUT" && pass "[$mode] posttool valid JSON" || fail "[$mode] posttool valid JSON" "$OUT"
  [ -f "$STATE/sessions/pm1.inj.main" ] && [ -f "$STATE/sessions/pm1.code" ] && [ ! -f "$STATE/sessions/pm1.pending-main" ] && pass "[$mode] posttool marks main, clears pending" || fail "[$mode] posttool marks main, clears pending" "state wrong"
  run_hook $mode "$CD" posttool
  assert_empty "[$mode] posttool exactly once" "$OUT"
  PAYLOAD='{"session_id":"pm1","prompt":"go"}'; run_hook $mode "$CD" prompt
  assert_not_has "[$mode] prompt after posttool: reminder only, no full rules" "$OUT" CODE-RULES
  assert_has "[$mode] prompt after posttool: reminder" "$OUT" "regression test"

  # no PostToolUse happened: next prompt injects full rules once
  PAYLOAD=$(sub pm2); run_hook $mode "$CD" pretool
  PAYLOAD='{"session_id":"pm2","prompt":"go"}'; run_hook $mode "$CD" prompt
  assert_has "[$mode] prompt injects full code.md when pending" "$OUT" CODE-RULES
  assert_has "[$mode] prompt injection event name" "$OUT" '"hookEventName":"UserPromptSubmit"'
  run_hook $mode "$CD" prompt
  assert_not_has "[$mode] prompt second time: no full rules" "$OUT" CODE-RULES
  PAYLOAD='{"session_id":"pm2","tool_name":"Task"}'; run_hook $mode "$CD" posttool
  assert_empty "[$mode] posttool after prompt injection: never twice" "$OUT"

  # session-start code injection counts as inj.main
  PAYLOAD='{"session_id":"pm3","cwd":"'"$T/work/gitnode"'","source":"startup"}'; run_hook $mode "$KIT/hooks/session-start.sh" code
  PAYLOAD=$(sub pm3); run_hook $mode "$CD" pretool
  [ ! -f "$STATE/sessions/pm3.pending-main" ] && pass "[$mode] no pending-main when session-start injected" || fail "[$mode] no pending-main when session-start injected" "created"
  PAYLOAD='{"session_id":"pm3","tool_name":"Agent"}'; run_hook $mode "$CD" posttool
  assert_empty "[$mode] posttool silent when session-start injected" "$OUT"

  # main edits itself: no pending, posttool silent
  PAYLOAD=$(pre pm4 /w/a.ts); run_hook $mode "$CD" pretool
  PAYLOAD='{"session_id":"pm4","tool_name":"Agent"}'; run_hook $mode "$CD" posttool
  assert_empty "[$mode] posttool silent when main already injected" "$OUT"
  # posttool without pending / without session
  PAYLOAD='{"session_id":"pm9","tool_name":"Agent"}'; run_hook $mode "$CD" posttool
  assert_empty "[$mode] posttool silent without pending" "$OUT"
  PAYLOAD='garbage'; run_hook $mode "$CD" posttool
  assert_empty "[$mode] posttool silent on garbage" "$OUT"; assert_eq "[$mode] posttool garbage rc" 0 "$RC"
done
# truncation via pretool
awk 'BEGIN{for(i=0;i<1500;i++) print "line number " i " of a very long rules file"}' > "$KIT/rules/code.md"
PAYLOAD=$(pre big /w/a.ts); run_hook nojq "$CD" pretool
assert_has "pretool oversized: stderr warning" "$ERR" truncated
valid_json "$OUT" && pass "pretool oversized: valid JSON" || fail "pretool oversized: valid JSON" "bad"
finish

#!/bin/bash
# Regression tests for the adversarial review of the hooks: stop-gate (#8, #16 deny framing)
# and the Cursor session-context cap (#16). The verifier is a fake `claude` that logs its calls.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
mk_kit
SG="$KIT/hooks/stop-gate.sh"
FB="$T/fake-claude"; mkdir -p "$FB"; CALLS="$T/calls"
fake_verdict() { printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\necho "%s"\n' "$CALLS" "$1" > "$FB/claude"; chmod +x "$FB/claude"; }
u() { # text [iso-timestamp]
  if [ -n "${2:-}" ]; then printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"%s"}}\n' "$2" "$1"
  else printf '{"type":"user","message":{"role":"user","content":"%s"}}\n' "$1"; fi
}
stamp() { # seconds offset from now -> ISO-8601 UTC with milliseconds, like Claude Code transcripts
  local e=$(( $(date -u +%s) + $1 ))
  date -u -r "$e" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%S.000Z
}
a_text() { printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$1"; }
a_tool() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"%s","input":%s}]}}\n' "$1" "$2"; }
t_res() { printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"%s"}]}}\n' "$1"; }

for mode in $MODES; do
  mp="$FB:$([ "$mode" = nojq ] && echo "$NOJQ_BIN" || echo "$PATH")"
  gate() { # transcript session [stop_hook_active]
    local extra=""; [ -n "${3:-}" ] && extra=",\"stop_hook_active\":$3"
    OUT=$(printf '{"session_id":"%s","transcript_path":"%s"%s}' "$2" "$1" "$extra" \
      | env PATH="$mp" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$SG" 2>/dev/null)
  }
  ncalls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }

  # #8 fast path sees only the current turn (an Edit in an EARLIER turn must not trigger the verifier)
  rm -rf "$STATE"; mkdir -p "$STATE"; rm -f "$CALLS"; fake_verdict "ALLOW: ok"
  TR="$T/old-edit.jsonl"
  { u "fix the bug"; a_tool Edit '{"file_path":"/w/a.ts","old_string":"a","new_string":"b"}'; t_res "ok"; a_text "fixed"
    i=0; while [ $i -lt 40 ]; do u "what is 2+2?"; a_text "4"; i=$((i + 1)); done; } > "$TR"
  gate "$TR" s1
  assert_has "[$mode] #8 earlier-turn edit, chat-only current turn: fast ALLOW" "$OUT" "no source changes"
  assert_eq "[$mode] #8 earlier-turn edit: verifier not called" 0 "$(ncalls)"

  # #8 docs-only edit in the current turn: no verifier
  TR="$T/doc-edit.jsonl"; { u "update the readme"; a_tool Edit '{"file_path":"/w/README.md","old_string":"a","new_string":"b"}'; t_res "ok"; a_text "done"; } > "$TR"
  gate "$TR" s1
  assert_has "[$mode] #8 docs-only edit: fast ALLOW" "$OUT" "no source changes"
  assert_eq "[$mode] #8 docs-only edit: verifier not called" 0 "$(ncalls)"

  # #8 research-only Agent call: no verifier
  TR="$T/research.jsonl"
  { u "where is the config loaded?"
    a_tool Agent '{"description":"Find config loader","prompt":"Search the repo for where the config is loaded and report the file and line.","subagent_type":"Explore"}'
    t_res "The config is loaded in src/config.ts line 10 by loadConfig()."
    a_text "It is loaded in src/config.ts:10."; } > "$TR"
  gate "$TR" s1
  assert_has "[$mode] #8 research-only Agent call: fast ALLOW" "$OUT" "no source changes"
  assert_eq "[$mode] #8 research-only Agent call: verifier not called" 0 "$(ncalls)"

  # source edit in the current turn (after tool_result user entries) -> verifier runs
  TR="$T/src-edit.jsonl"; { u "add retry"; a_tool Edit '{"file_path":"/w/client.ts","old_string":"a","new_string":"b"}'; t_res "ok"; a_text "done"; } > "$TR"
  gate "$TR" s1
  assert_eq "[$mode] #8 source edit in the current turn: verifier called" 1 "$(ncalls)"
  # (round 3) Bash writes are detected by code-detect.sh pretool (Bash matcher), not by grepping the transcript
  c0=$(ncalls)
  PAYLOAD='{"session_id":"bsh","tool_name":"Bash","tool_input":{"command":"cat gen.txt > src/out.ts"}}'
  run_hook "$mode" "$KIT/hooks/code-detect.sh" pretool
  TR="$T/bash-src.jsonl"; { u "regenerate"; a_tool Bash '{"command":"cat gen.txt > src/out.ts"}'; t_res "ok"; a_text "done"; } > "$TR"
  gate "$TR" bsh false
  assert_eq "[$mode] #8 Bash redirect into a source file (logged by code-detect): verifier called" $((c0 + 1)) "$(ncalls)"
  c0=$(ncalls)
  PAYLOAD='{"session_id":"bdoc","tool_name":"Bash","tool_input":{"command":"echo hi > notes.md"}}'
  run_hook "$mode" "$KIT/hooks/code-detect.sh" pretool
  TR="$T/bash-doc.jsonl"; { u "notes"; a_tool Bash '{"command":"echo hi > notes.md"}'; t_res "ok"; a_text "done"; } > "$TR"
  gate "$TR" bdoc false
  assert_eq "[$mode] #8 Bash redirect into a .md file: verifier not called" "$c0" "$(ncalls)"
  # #8 (round 2) delegated work is detected from the edit log written by code-detect.sh, never from
  # keywords in agent prompts/reports. Research-only agents -> no verifier, whatever words they use.
  for prm in "Find where authentication is implemented and report the file paths." \
             "Investigate why test_login fails. Do not fix anything, only report the cause." \
             "Read src/api and summarize how errors are handled; do not edit files."; do
    c0=$(ncalls); TR="$T/r.jsonl"
    { u "how does auth work?"; a_tool Agent "{\"description\":\"research\",\"prompt\":\"$prm\",\"subagent_type\":\"Explore\"}"
      t_res "Summary: see src/auth.ts"; a_text "see src/auth.ts"; } > "$TR"
    gate "$TR" rs false
    assert_eq "[$mode] #8 research agent [$prm]: verifier not called" "$c0" "$(ncalls)"
  done
  c0=$(ncalls); TR="$T/r2.jsonl"
  { u "where is config"; a_tool Agent '{"description":"Find config","prompt":"Search for config loading.","subagent_type":"Explore"}'
    t_res "Config loading is implemented in src/config.ts; I made no changes."; a_text "ok"; } > "$TR"
  gate "$TR" rs2 false
  assert_eq "[$mode] #8 report saying 'implemented', no edits: verifier not called" "$c0" "$(ncalls)"
  # a subagent that really edits a .py file: code-detect pretool logs it, the gate then runs the verifier
  c0=$(ncalls); TR="$T/sub.jsonl"
  { u "add retry to the client" "$(stamp -60)"; a_tool Agent '{"description":"do it","prompt":"Make the change."}'
    t_res "Done."; a_text "Done."; } > "$TR"
  PAYLOAD='{"session_id":"subS","agent_id":"ag9","tool_name":"Edit","tool_input":{"file_path":"/w/pkg/x.py"}}'
  run_hook "$mode" "$KIT/hooks/code-detect.sh" pretool
  PAYLOAD='{"session_id":"subS","agent_id":"ag9","tool_name":"Write","tool_input":{"file_path":"/w/pkg/y.py"}}'
  run_hook "$mode" "$KIT/hooks/code-detect.sh" pretool
  ed="$STATE/sessions/subS.edits"
  assert_eq "[$mode] #8 code-detect logs every source edit, also after the once-only injection" 2 "$(wc -l < "$ed" 2>/dev/null | tr -d ' ')"
  case "$(head -n 1 "$ed" 2>/dev/null)" in [0-9]*" ag9 /w/pkg/x.py") pass "[$mode] #8 edit log line = epoch agent path" ;; *) fail "[$mode] #8 edit log format" "$(cat "$ed" 2>/dev/null)" ;; esac
  PAYLOAD='{"session_id":"subS","tool_name":"Edit","tool_input":{"file_path":"/w/README.md"}}'
  run_hook "$mode" "$KIT/hooks/code-detect.sh" pretool
  assert_eq "[$mode] #8 non-source edits are not logged" 2 "$(wc -l < "$ed" | tr -d ' ')"
  gate "$TR" subS false
  assert_eq "[$mode] #8 subagent edited a .py file this turn: verifier called" $((c0 + 1)) "$(ncalls)"
  # the same log entries are older than a NEW turn -> not this turn's work
  c0=$(ncalls); TR="$T/sub2.jsonl"
  { u "thanks, what next?" "$(stamp 120)"; a_text "Nothing."; } > "$TR"
  gate "$TR" subS false
  assert_eq "[$mode] #8 edits from an earlier turn: verifier not called" "$c0" "$(ncalls)"

  # #16 DENY reason framed as untrusted verifier output; #8 per-session deny counter + stop_hook_active
  rm -rf "$STATE"; mkdir -p "$STATE"; rm -f "$CALLS"; fake_verdict "DENY: run the tests"
  TR="$T/src-edit.jsonl"
  gate "$TR" sessA false
  assert_has "[$mode] #16 DENY reason is quoted verifier output" "$OUT" 'Verifier (untrusted transcript analysis) says: \"run the tests\"'
  valid_json "$OUT" && pass "[$mode] #16 DENY output valid JSON" || fail "[$mode] #16 DENY JSON" "$OUT"
  gate "$TR" sessA true; gate "$TR" sessA true
  gate "$TR" sessA true
  assert_has "[$mode] #8 loop guard after 3 denies in the same stop chain" "$OUT" "loop guard"
  ls "$STATE"/sessions/*sessA* >/dev/null 2>&1 && pass "[$mode] #8 deny counter kept per session under state/sessions/" || fail "[$mode] #8 counter file" "$(ls -R "$STATE")"
  c0=$(ncalls)
  gate "$TR" sessB false
  assert_has "[$mode] #8 another session is not loop-guarded by sessA's denies" "$OUT" '"decision":"block"'
  gate "$TR" sessA false
  assert_has "[$mode] #8 stop_hook_active=false (new user turn) resets the counter" "$OUT" '"decision":"block"'
  assert_eq "[$mode] #8 verifier called for both" $((c0 + 2)) "$(ncalls)"
done

# #16 Cursor session-context output is capped
mk_kit
head -c 30000 /dev/zero | tr '\0' 'y' > "$KIT/rules/discipline.md"
PAYLOAD='{"conversation_id":"c1"}'
run_hook jq "$KIT/cursor/hooks/session-context.sh"
n=$(printf '%s' "$OUT" | wc -c | tr -d ' ')
[ "$n" -le 10200 ] && pass "#16 cursor session-context output capped ($n bytes)" || fail "#16 cursor session-context capped" "$n bytes"
valid_json "$OUT" && pass "#16 cursor session-context capped output valid JSON" || fail "#16 cursor JSON" "$(printf '%s' "$OUT" | head -c 200)"

# ---------------------------------------------------------------- round 3: watermark + Bash detection
for mode in $MODES; do
  mp="$FB:$([ "$mode" = nojq ] && echo "$NOJQ_BIN" || echo "$PATH")"
  gate() { local extra=""; [ -n "${3:-}" ] && extra=",\"stop_hook_active\":$3"
    OUT=$(printf '{"session_id":"%s","transcript_path":"%s"%s}' "$2" "$1" "$extra" \
      | env PATH="$mp" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$SG" 2>/dev/null); }
  ncalls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
  cdet() { PAYLOAD="$1"; run_hook "$mode" "$KIT/hooks/code-detect.sh" pretool; }
  rm -rf "$STATE"; mkdir -p "$STATE"; rm -f "$CALLS"; fake_verdict "ALLOW: ok"
  # A: a background agent's edit followed by a task-notification "user" entry must still be gated
  TR="$T/tn.jsonl"; { u "start the background job" "$(stamp -30)"; a_text "started"; } > "$TR"
  gate "$TR" tn false
  assert_eq "[$mode] A: no edits yet -> no verifier" 0 "$(ncalls)"
  cdet '{"session_id":"tn","agent_id":"bg1","tool_name":"Edit","tool_input":{"file_path":"/w/job.py"}}'
  printf '{"type":"user","origin":{"kind":"task-notification"},"timestamp":"%s","message":{"role":"user","content":"<task-notification>job finished</task-notification>"}}\n' "$(stamp 60)" >> "$TR"
  a_text "The job finished." >> "$TR"
  gate "$TR" tn false
  assert_eq "[$mode] A: background-agent edit before a task-notification turn: verifier called" 1 "$(ncalls)"
  ls "$STATE"/sessions/tn.gate >/dev/null 2>&1 && pass "[$mode] A: watermark kept in <state>/sessions/<sid>.gate" || fail "[$mode] A: watermark file" "$(ls "$STATE/sessions")"
  gate "$TR" tn false
  assert_eq "[$mode] A: verifier ALLOW advances the watermark (no new edits -> no verifier)" 1 "$(ncalls)"
  fake_verdict "DENY: verify it"
  cdet '{"session_id":"tn","tool_name":"Write","tool_input":{"file_path":"/w/b.ts"}}'
  gate "$TR" tn false; gate "$TR" tn true
  assert_eq "[$mode] A: DENY does not advance the watermark (verifier runs again)" 3 "$(ncalls)"
  gate "$TR" tn true; gate "$TR" tn true
  assert_has "[$mode] A: loop guard ALLOW" "$OUT" "loop guard"
  c0=$(ncalls); gate "$TR" tn false
  assert_eq "[$mode] A: loop-guard ALLOW advanced the watermark" "$c0" "$(ncalls)"
  # Bash writes of source files are logged by code-detect.sh (main session and subagents)
  rm -rf "$STATE"; mkdir -p "$STATE"
  n=0
  for c in 'echo x > src/a.ts' 'echo x>>b.PY' 'cat <<EOF > c.go\nx\nEOF' 'printf x | tee d.rs' 'printf x | tee -a d2.rs' \
           'sed -i s/a/b/ e.js' "sed -i '' s/a/b/ e2.js" 'perl -pi -e s/a/b/ f.rb' 'cp /tmp/x g.ts' 'mv /tmp/x h.tsx' 'install -m 644 /tmp/x i.sh' \
           "python3 -c \\\"open('j.py','w').write('x')\\\"" "node -e \\\"require('fs').writeFileSync('k.js','x')\\\""; do
    n=$((n + 1))
    cdet "{\"session_id\":\"bw\",\"agent_id\":\"ag$n\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}"
    got=$(wc -l < "$STATE/sessions/bw.edits" 2>/dev/null | tr -d ' ')
    assert_eq "[$mode] A: Bash write logged: $c" "$n" "${got:-0}"
  done
  for c in 'cat a.ts' 'grep -n foo b.py' 'ls > out.txt' 'echo hi > notes.md' 'python3 script.py' 'node app.js' 'cp a.ts /tmp/backup.txt' 'git diff > changes.patch' 'echo x 2>&1'; do
    cdet "{\"session_id\":\"bw\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}"
    got=$(wc -l < "$STATE/sessions/bw.edits" 2>/dev/null | tr -d ' ')
    assert_eq "[$mode] A: Bash non-write not logged: $c" "$n" "${got:-0}"
  done
  rm -rf "$STATE"; mkdir -p "$STATE"
  cdet '{"session_id":"bi","tool_name":"Bash","tool_input":{"command":"echo x > src/a.ts"}}'
  assert_has "[$mode] A: first Bash source write injects code.md once" "$(ctx_of "$OUT")" "CODE-RULES"
  cdet '{"session_id":"bi","tool_name":"Bash","tool_input":{"command":"echo y > src/b.ts"}}'
  assert_empty "[$mode] A: second Bash source write: no second injection" "$OUT"
done
assert_eq "A: PreToolUse matcher for code-detect pretool includes Bash" "Edit|Write|MultiEdit|NotebookEdit|Bash" \
  "$("$REAL_JQ" -r '.PreToolUse[] | select(.hooks[].command | contains("code-detect.sh\" pretool")) | .matcher' "$REPO/hooks/settings.fragment.json")"
assert_not_has "A: stop-gate no longer parses turn-start timestamps" "$(cat "$REPO/hooks/stop-gate.sh")" "iso_to_epoch"

# ---------------------------------------------------------------- round 4: stale watermark (B), fail-open (D)
for mode in $MODES; do
  mp="$FB:$([ "$mode" = nojq ] && echo "$NOJQ_BIN" || echo "$PATH")"
  gate() { OUT=$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$2" "$1" \
      | env PATH="$mp" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$SG" 2>/dev/null); }
  ncalls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
  TR="$T/r4.jsonl"; { u "go"; a_text "ok"; } > "$TR"
  rm -rf "$STATE"; mkdir -p "$STATE/sessions"; rm -f "$CALLS"; fake_verdict "ALLOW: ok"
  # B: watermark from an older edit log (more lines than the fresh log) -> judged again
  printf '1700000000 5\n' > "$STATE/sessions/g5.gate"; printf '1795000000 main /w/a.py\n' > "$STATE/sessions/g5.edits"
  gate "$TR" g5
  assert_eq "[$mode] B: gate at 5 lines + fresh 1-line .edits: verifier runs" 1 "$(ncalls)"
  # B: same line count, but the edit log was re-created (different first entry) -> judged again
  printf '1700000000 1\n' > "$STATE/sessions/g1.gate"; printf '1795000001 main /w/new.py\n' > "$STATE/sessions/g1.edits"
  gate "$TR" g1
  assert_eq "[$mode] B: legacy gate (no log fingerprint) with an equal-length fresh log: verifier runs" 2 "$(ncalls)"
  gate "$TR" g1
  assert_eq "[$mode] B: after that ALLOW the new watermark holds (no re-run)" 2 "$(ncalls)"
  printf '1795000002 main /w/other.py\n' > "$STATE/sessions/g1.edits"   # log replaced, same length
  gate "$TR" g1
  assert_eq "[$mode] B: log replaced with the same length: fingerprint mismatch -> verifier runs" 3 "$(ncalls)"
  # B: pruning removes the watermark together with an old edit log
  printf 'x\n' > "$STATE/sessions/old.edits"; touch -t 202001010000 "$STATE/sessions/old.edits"
  printf '1 1 x\n' > "$STATE/sessions/old.gate"
  ( CLAUDE_KIT_STATE="$STATE"; . "$KIT/hooks/lib.sh"; kit_prune 7 )
  [ ! -e "$STATE/sessions/old.gate" ] && pass "[$mode] B: kit_prune removes the .gate of a pruned .edits" || fail "[$mode] B: prune .gate" "still there"
  # D: fail-open ALLOW does not advance the watermark
  rm -rf "$STATE"; mkdir -p "$STATE/sessions"; rm -f "$CALLS"
  printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\necho "ALLOW: looks fine"\nexit 1\n' "$CALLS" > "$FB/claude"; chmod +x "$FB/claude"
  printf '1795000000 main /w/a.py\n' > "$STATE/sessions/fo.edits"
  gate "$TR" fo
  assert_has "[$mode] D: verifier exiting non-zero -> fail-open ALLOW" "$OUT" "fail-open"
  [ ! -s "$STATE/sessions/fo.gate" ] && pass "[$mode] D: fail-open ALLOW leaves the watermark alone" || fail "[$mode] D: watermark" "$(cat "$STATE/sessions/fo.gate")"
  grep -q 'ALLOW(fail-open)' "$STATE/stop-gate.log" && pass "[$mode] D: logged as ALLOW(fail-open)" || fail "[$mode] D: log" "$(tail -n 2 "$STATE/stop-gate.log")"
  fake_verdict "ALLOW: verified"
  gate "$TR" fo
  assert_eq "[$mode] D: next stop re-checks with the verifier" 2 "$(ncalls)"
  assert_has "[$mode] D: verified ALLOW" "$OUT" "verified"
  gate "$TR" fo
  assert_eq "[$mode] D: verified ALLOW advanced the watermark" 2 "$(ncalls)"
  printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\necho "not a verdict"\n' "$CALLS" > "$FB/claude"
  printf '1795000000 main /w/a.py\n' > "$STATE/sessions/fo2.edits"
  gate "$TR" fo2
  assert_has "[$mode] D: unparsable verifier output -> fail-open" "$OUT" "fail-open"
  [ ! -s "$STATE/sessions/fo2.gate" ] && pass "[$mode] D: unparsable output leaves the watermark alone" || fail "[$mode] D: unparsable watermark" "$(cat "$STATE/sessions/fo2.gate")"
done

# ---------------------------------------------------------------- round 5: fail-open cap, verifier timeout, hook timeouts
for mode in $MODES; do
  mp="$FB:$([ "$mode" = nojq ] && echo "$NOJQ_BIN" || echo "$PATH")"
  gate() { OUT=$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$2" "$1" \
      | env PATH="$mp" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" CLAUDE_KIT_VERIFIER_TIMEOUT="${VTO:-150}" "$BASH_BIN" "$SG" 2>/dev/null); }
  ncalls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
  TR="$T/r5.jsonl"; { u "go"; a_text "ok"; } > "$TR"
  rm -rf "$STATE"; mkdir -p "$STATE/sessions"; rm -f "$CALLS"
  printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\nexit 1\n' "$CALLS" > "$FB/claude"; chmod +x "$FB/claude"
  printf '1795000000 main /w/a.py\n' > "$STATE/sessions/cap.edits"
  gate "$TR" cap; gate "$TR" cap; gate "$TR" cap
  assert_eq "[$mode] 2: verifier failing 3 times for the same edits -> exactly 2 verifier calls" 2 "$(ncalls)"
  assert_has "[$mode] 2: third stop is ALLOW(fail-open-cap)" "$OUT" "fail-open-cap"
  grep -q 'ALLOW(fail-open-cap)' "$STATE/stop-gate.log" && pass "[$mode] 2: logged as ALLOW(fail-open-cap)" || fail "[$mode] 2: cap log" "$(tail -n 1 "$STATE/stop-gate.log")"
  gate "$TR" cap
  assert_eq "[$mode] 2: after the cap the watermark moved (no further calls)" 2 "$(ncalls)"
  printf '1795000100 main /w/b.py\n' >> "$STATE/sessions/cap.edits"
  gate "$TR" cap
  assert_eq "[$mode] 2: a new edit runs the verifier again" 3 "$(ncalls)"
  # a verifier that hangs past CLAUDE_KIT_VERIFIER_TIMEOUT is killed, fails open, and counts as an attempt
  rm -rf "$STATE"; mkdir -p "$STATE/sessions"; rm -f "$CALLS"
  printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\nsleep 30\necho "ALLOW: late"\n' "$CALLS" > "$FB/claude"
  printf '1795000000 main /w/a.py\n' > "$STATE/sessions/slow.edits"
  VTO=10 with_timeout 25 gate "$TR" slow
  [ "$WD_RC" != 124 ] && pass "[$mode] 2: hung verifier is killed by the gate's own timeout" || fail "[$mode] 2: verifier timeout" "gate itself hung"
  VTO=10 gate "$TR" slow
  assert_has "[$mode] 2: verifier timeout -> fail-open" "$OUT" "fail-open"
  VTO=10 gate "$TR" slow
  assert_eq "[$mode] 2: timed-out runs count as attempts (2 calls, then the cap)" 2 "$(ncalls)"
  assert_has "[$mode] 2: cap reached after two timeouts" "$OUT" "fail-open-cap"
done
F="$REPO/hooks/settings.fragment.json"
assert_eq "1: every kit hook command has an explicit timeout" 0 "$("$REAL_JQ" '[.[][] | .hooks[] | select(has("timeout") | not)] | length' "$F")"
assert_eq "1: non-Stop hooks time out within 10 s" 0 "$("$REAL_JQ" '[to_entries[] | select(.key != "Stop") | .value[].hooks[] | select(.timeout > 10)] | length' "$F")"
stop_to=$("$REAL_JQ" '.Stop[0].hooks[0].timeout' "$F")
vdef=$(sed -n 's/.*CLAUDE_KIT_VERIFIER_TIMEOUT:-\([0-9]*\).*/\1/p' "$REPO/hooks/stop-gate.sh" | head -n 1)
[ -n "$vdef" ] && [ "$vdef" -lt "$stop_to" ] && pass "1: verifier timeout ($vdef s) is below the Stop hook timeout ($stop_to s)" || fail "1: verifier timeout below Stop timeout" "verifier=[$vdef] stop=[$stop_to]"
assert_eq "1: every Cursor hook has a timeout" 0 "$("$REAL_JQ" '[.hooks[][] | select(has("timeout") | not)] | length' "$REPO/cursor/hooks.json")"

# Cursor session-context order: core -> platform -> discipline -> code -> lessons, capped
mk_kit
printf 'CODE-RULES\n' > "$KIT/rules/code.md"
mkdir -p "$HOME_T/.claude/lessons"; printf '# idx\nLESSON-ONE\n' > "$HOME_T/.claude/lessons/INDEX.md"
PAYLOAD='{"conversation_id":"c2"}'; CLAUDE_KIT_OS=linux run_hook jq "$KIT/cursor/hooks/session-context.sh"
ctx=$(printf '%s' "$OUT" | "$REAL_JQ" -r .additional_context)
order=$(printf '%s\n' "$ctx" | grep -nE 'CORE-RULES|PLAT-LINUX|DISC-RULES|CODE-RULES|LESSON-ONE' | cut -d: -f2 | tr '\n' ' ')
assert_eq "#7 cursor session-context order core -> platform -> discipline -> code -> lessons" "CORE-RULES PLAT-LINUX DISC-RULES CODE-RULES LESSON-ONE " "$order"
head -c 30000 /dev/zero | tr '\0' 'y' > "$KIT/rules/discipline.md"
PAYLOAD='{"conversation_id":"c3"}'; CLAUDE_KIT_OS=linux run_hook jq "$KIT/cursor/hooks/session-context.sh"
ctx=$(printf '%s' "$OUT" | "$REAL_JQ" -r .additional_context)
assert_has "#7 capped cursor context still starts with core + platform" "$ctx" "CORE-RULES

PLAT-LINUX"
assert_has "README documents that Cursor gets capped content without code detection" "$(cat "$REPO/README.md")" "Cursor has no code/non-code detection"

finish

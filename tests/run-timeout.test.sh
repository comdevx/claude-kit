#!/bin/bash
# Verifier timeout (kit_run_timeout) and the stop gate around it: wall-clock deadline, whole process
# tree killed (with and without pgrep, including a parent that keeps re-spawning children), validation
# of CLAUDE_KIT_VERIFIER_TIMEOUT, and the attempts file being removed. Orphans are detected by a
# unique marker in the stub's argv, never by a generic "sleep".
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$REPO/hooks/lib.sh"
mk_kit
MARK="kitrt$$x"
REAL_SLEEP=$(command -v sleep)
orphans() { pgrep -f "$1" 2>/dev/null | wc -l | tr -d ' '; }
cleanup_marks() { pkill -9 -f "$MARK" 2>/dev/null; return 0; }
trap 'cleanup_marks; rm -rf "$T"' EXIT
: > "$T/in"

# PATH without pgrep/pkill (Git for Windows, slim Linux images)
NP="$T/nopgrep-bin"; mkdir -p "$NP"
for f in "$NOJQ_BIN"/*; do n="${f##*/}"; case "$n" in pgrep|pkill) continue ;; esac; ln -s "$f" "$NP/$n" 2>/dev/null; done
# a wrapper, not a link: Git Bash copies on `ln -s`, and a copied Chocolatey jq shim cannot find its jq.exe
[ -n "$JQ_EXE" ] && { printf '#!/bin/sh\nexec "%s" "$@"\n' "$JQ_EXE" > "$NP/jq"; chmod +x "$NP/jq"; }

# ---------------------------------------------------------------- 1. wall-clock deadline
SLOW="$T/slow-sleep"; mkdir -p "$SLOW"
printf '#!/bin/sh\n%s 0.6\nexec %s "$@"\n' "$REAL_SLEEP" "$REAL_SLEEP" > "$SLOW/sleep"; chmod +x "$SLOW/sleep"
start=$SECONDS
( PATH="$SLOW:$PATH"; kit_run_timeout 2 "$T/in" "$T/out" bash -c "$REAL_SLEEP 1000; :" "$MARK-1" ); rc=$?
el=$((SECONDS - start))
assert_eq "1: timed out (124)" 124 "$rc"
# Budget: 2 s deadline + 1 s of $SECONDS rounding + one slow tick (0.7 s) + the kill walk, whose own
# `sleep 0.2` also goes through the slow stub (0.8 s), + forks on a loaded CI runner. A deadline that
# counted ticks instead of wall-clock time would need 20 slow ticks (~14 s), so 6 s still catches it.
[ "$el" -le 6 ] && pass "1: returns near the deadline even when each tick is slow (${el}s for 2s)" || fail "1: wall-clock deadline" "took ${el}s for a 2s timeout"
sleep 0.3; assert_eq "1: nothing left running" 0 "$(orphans "$MARK-1")"

# ---------------------------------------------------------------- 2a. no pgrep: children are killed too
( PATH="$NP"; kit_run_timeout 1 "$T/in" "$T/out" bash -c "bash -c '$REAL_SLEEP 1000; :' $MARK-2a & wait" ); rc=$?
sleep 0.3
assert_eq "2a: no pgrep on PATH: timed out" 124 "$rc"
assert_eq "2a: no pgrep on PATH: the grandchild is killed as well (0 orphans)" 0 "$(orphans "$MARK-2a")"

# ---------------------------------------------------------------- 2b. a parent that keeps spawning children
bad=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  ( kit_run_timeout 1 "$T/in" "$T/out" bash -c "while :; do bash -c '$REAL_SLEEP 1000; :' $MARK-2b & $REAL_SLEEP 0.02; done" )
  sleep 0.3; n=$(orphans "$MARK-2b"); [ "$n" -eq 0 ] || { bad=$((bad + n)); cleanup_marks; }
done
assert_eq "2b: re-spawning parent killed at timeout 1, 10 runs: 0 orphans" 0 "$bad"
bad=0
for i in 1 2 3; do
  ( PATH="$NP"; kit_run_timeout 1 "$T/in" "$T/out" bash -c "while :; do bash -c '$REAL_SLEEP 1000; :' $MARK-2c & $REAL_SLEEP 0.02; done" )
  sleep 0.3; n=$(orphans "$MARK-2c"); [ "$n" -eq 0 ] || { bad=$((bad + n)); cleanup_marks; }
done
assert_eq "2b: re-spawning parent without pgrep, 3 runs: 0 orphans" 0 "$bad"

# ---------------------------------------------------------------- through the stop gate (no pgrep, timeout 2)
SG="$KIT/hooks/stop-gate.sh"; FB="$T/fb"; mkdir -p "$FB"; CALLS="$T/calls"
TR="$T/tr.jsonl"; printf '{"type":"user","message":{"role":"user","content":"go"}}\n' > "$TR"
gate() { # session [env...]
  local sid="$1"; shift
  OUT=$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$sid" "$TR" \
    | env PATH="$FB:${GPATH:-$PATH}" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$@" "$BASH_BIN" "$SG" 2>/dev/null)
}
edit_log() { mkdir -p "$STATE/sessions"; printf '1795000000 main /w/a.py\n' > "$STATE/sessions/$1.edits"; }
printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\nbash -c "%s 1000; :" %s-gate &\nwait\n' "$CALLS" "$REAL_SLEEP" "$MARK" > "$FB/claude"; chmod +x "$FB/claude"
rm -rf "$STATE"; mkdir -p "$STATE"; edit_log ng
start=$SECONDS; GPATH="$NP" gate ng CLAUDE_KIT_VERIFIER_TIMEOUT=10; el=$((SECONDS - start))
sleep 0.3
assert_has "2: stop gate without pgrep: verifier timeout -> fail-open" "$OUT" "fail-open"
# the verifier sleeps 1000 s, so a gate that ignored its timeout would hang far beyond 16 s
[ "$el" -le 16 ] && pass "2: stop gate returned in ${el}s for a 10s verifier timeout" || fail "2: stop gate duration" "${el}s"
assert_eq "2: stop gate without pgrep: the verifier's child is not orphaned" 0 "$(orphans "$MARK-gate")"

# ---------------------------------------------------------------- 3. CLAUDE_KIT_VERIFIER_TIMEOUT validation
printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\n%s 2\necho "ALLOW: verified"\n' "$CALLS" "$REAL_SLEEP" > "$FB/claude"
for v in 1.5 abc 0 -1 1 9 999 171; do
  rm -rf "$STATE"; mkdir -p "$STATE"; edit_log "v$$"
  gate "v$$" CLAUDE_KIT_VERIFIER_TIMEOUT="$v"
  assert_has "3: CLAUDE_KIT_VERIFIER_TIMEOUT=$v falls back to the default (the 2 s verifier finishes)" "$OUT" "verified"
  assert_eq "3: CLAUDE_KIT_VERIFIER_TIMEOUT=$v is reported once in the gate log" 1 "$(grep -c 'invalid CLAUDE_KIT_VERIFIER_TIMEOUT' "$STATE/stop-gate.log" 2>/dev/null)"
done
rm -rf "$STATE"; mkdir -p "$STATE"; edit_log ok
gate ok CLAUDE_KIT_VERIFIER_TIMEOUT=170
assert_eq "3: 170 is accepted (nothing logged)" 0 "$(grep -c 'invalid CLAUDE_KIT_VERIFIER_TIMEOUT' "$STATE/stop-gate.log" 2>/dev/null)"
rm -rf "$STATE"; mkdir -p "$STATE"; edit_log ok10
gate ok10 CLAUDE_KIT_VERIFIER_TIMEOUT=10
assert_eq "4: 10 (the new minimum) is accepted (nothing logged)" 0 "$(grep -c 'invalid CLAUDE_KIT_VERIFIER_TIMEOUT' "$STATE/stop-gate.log" 2>/dev/null)"

# ---------------------------------------------------------------- 6. the attempts file goes away
rm -rf "$STATE"; mkdir -p "$STATE"; edit_log at
printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\nexit 1\n' "$CALLS" > "$FB/claude"
gate at; gate at
[ -f "$STATE/sessions/at.attempts" ] && pass "6: attempts recorded while failing" || fail "6: attempts file" "missing"
gate at
assert_has "6: cap fires" "$OUT" "fail-open-cap"
[ ! -e "$STATE/sessions/at.attempts" ] && pass "6: attempts file removed when the cap fires" || fail "6: attempts after cap" "$(cat "$STATE/sessions/at.attempts")"
for verdict in "ALLOW: verified" "DENY: run it"; do
  rm -rf "$STATE"; mkdir -p "$STATE"; edit_log vd
  printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\necho "%s"\n' "$CALLS" "$verdict" > "$FB/claude"
  gate vd
  [ ! -e "$STATE/sessions/vd.attempts" ] && pass "6: attempts file removed after a verdict ($verdict)" || fail "6: attempts after $verdict" "present"
done

# transcript-fallback mode (no code-detect, no .edits): the attempts count survives the cap, so the
# cost stays bounded at 2 verifier calls however many Stops follow
rm -rf "$STATE"; mkdir -p "$STATE"; rm -f "$CALLS"
TRF="$T/fallback.jsonl"
{ printf '{"type":"user","message":{"role":"user","content":"add retry"}}\n'
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/w/client.ts"}}]}}\n'; } > "$TRF"
printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\nexit 1\n' "$CALLS" > "$FB/claude"
for i in 1 2 3 4 5; do
  OUT=$(printf '{"session_id":"fb1","transcript_path":"%s","stop_hook_active":false}' "$TRF" \
    | env PATH="$FB:$PATH" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$SG" 2>/dev/null)
done
[ ! -e "$STATE/sessions/fb1.edits" ] && pass "6: fallback mode really has no edit log" || fail "6: fallback setup" "edit log exists"
assert_eq "6: fallback mode, failing verifier, 5 Stops -> exactly 2 verifier calls" 2 "$(wc -l < "$CALLS" | tr -d ' ')"
assert_has "6: fallback mode keeps answering with the cap" "$OUT" "fail-open-cap"

# 1: in fallback mode the cap covers one turn only: a new user turn gets a fresh count
TRN="$T/fallback-turns.jsonl"; rm -rf "$STATE"; mkdir -p "$STATE"; rm -f "$CALLS"
{ printf '{"type":"user","message":{"role":"user","content":"add retry"}}\n'
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/w/client.ts"}}]}}\n'; } > "$TRN"
printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\nexit 1\n' "$CALLS" > "$FB/claude"
fgate() { OUT=$(printf '{"session_id":"fb2","transcript_path":"%s","stop_hook_active":false}' "$TRN" \
    | env PATH="$FB:$PATH" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$SG" 2>/dev/null); }
fgate; fgate; fgate; fgate
assert_eq "1: fallback turn 1: two failing calls, then capped" 2 "$(wc -l < "$CALLS" | tr -d ' ')"
{ printf '{"type":"user","message":{"role":"user","content":"now fix f2"}}\n'
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"/w/f2.ts"}}]}}\n'; } >> "$TRN"
printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\necho "DENY: verify f2"\n' "$CALLS" > "$FB/claude"
fgate
assert_eq "1: fallback mode, new turn: the verifier is called again" 3 "$(wc -l < "$CALLS" | tr -d ' ')"
assert_has "1: fallback mode, new turn: its DENY reaches the user" "$OUT" '"decision":"block"'
fgate
assert_has "1: fallback mode, next Stop of the new turn: verifier still consulted" "$OUT" '"decision":"block"'

# 3: with a controlling terminal the verifier is NOT put in a background process group (it would be
#    stopped by SIGTTOU when it touches the terminal and burn the whole timeout)
run_pty() { # cmd... (runs under a pseudo-terminal; 77 = no way to get one)
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import pty' 2>/dev/null; then
    python3 -c 'import pty, sys; pty.spawn(sys.argv[1:])' "$@" < /dev/null > /dev/null 2>&1; return 0
  elif script --version 2>/dev/null | grep -q util-linux; then
    script -qec "$*" /dev/null < /dev/null > /dev/null 2>&1; return 0
  elif command -v script >/dev/null 2>&1; then
    script -q /dev/null "$@" < /dev/null > /dev/null 2>&1; return 0
  fi
  return 77
}
TTYS="$T/tty-stub"; mkdir -p "$TTYS"
printf '#!/bin/sh\ncat >/dev/null\nstty -echo < /dev/tty 2>/dev/null; stty echo < /dev/tty 2>/dev/null\necho "ALLOW: tty touched"\n' > "$TTYS/claude"; chmod +x "$TTYS/claude"
cat > "$T/tty-run.sh" <<EOS
. "$KIT/hooks/lib.sh"
: > "$T/tty-in"
start=\$SECONDS
kit_run_timeout 10 "$T/tty-in" "$T/tty-out" "$TTYS/claude" "$MARK-tty"
echo "rc=\$? el=\$((SECONDS - start))" > "$T/tty-res"
EOS
if run_pty "$BASH_BIN" "$T/tty-run.sh"; then
  res=$(cat "$T/tty-res" 2>/dev/null)
  # a stopped verifier shows as rc=124 at the 10 s deadline; slack below that is for slow runners
  case "$res" in "rc=0 el="[0-6]) pass "3: under a tty, a verifier that sets terminal modes is not job-control stopped ($res)" ;;
    *) fail "3: tty verifier" "got [$res] (rc=124 = stopped by SIGTTOU until the deadline)" ;; esac
  assert_eq "3: under a tty, its output arrives" "ALLOW: tty touched" "$(cat "$T/tty-out" 2>/dev/null)"
  # the whole stop gate under a tty: one JSON object on stdout, no orphans
  rm -rf "$STATE"; mkdir -p "$STATE"; edit_log ttyg
  cp "$TTYS/claude" "$FB/claude"
  cat > "$T/tty-gate.sh" <<EOS
printf '{"session_id":"ttyg","transcript_path":"%s","stop_hook_active":false}' "$TR" \
  | env PATH="$FB:$PATH" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$SG" > "$T/tty-gate.out" 2>/dev/null
EOS
  run_pty "$BASH_BIN" "$T/tty-gate.sh"
  valid_json "$(cat "$T/tty-gate.out")" && [ "$(grep -c . "$T/tty-gate.out")" = 1 ] \
    && pass "3: stop gate under a tty prints one JSON object" || fail "3: stop gate under a tty" "$(cat "$T/tty-gate.out")"
  assert_has "3: stop gate under a tty gets the verifier's verdict" "$(cat "$T/tty-gate.out")" "tty touched"
  sleep 0.3; assert_eq "3: no orphans after the tty runs" 0 "$(orphans "$MARK-tty")"
else
  echo "SKIP 3: no pseudo-terminal available (python3 pty or script)"
fi

# ---------------------------------------------------------------- round 8 / 1: fallback key on transcripts over 4 MB
# Realistic JSONL: top-level "type":"user" text lines carry a uuid and promptId; tool results are user
# lines with tool_result content; task notifications and attachments appear between them.
GID=0
nid() { GID=$((GID + 1)); NID=$(printf '%08d' "$GID"); }   # sets NID (no subshell, so the counter advances)
gen_prefix() { # MB -> old turns (user + long assistant text), ~2.2 KB each
  awk -v mb="$1" 'BEGIN { pad = sprintf("%2000s", ""); gsub(/ /, "x", pad); n = 0; i = 0
    while (n < mb * 1000000) { i++
      printf "{\"type\":\"user\",\"uuid\":\"old-u%08d\",\"promptId\":\"old-p%08d\",\"message\":{\"role\":\"user\",\"content\":\"old question %d\"}}\n", i, i, i
      printf "{\"type\":\"assistant\",\"uuid\":\"old-a%08d\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"%s\"}]}}\n", i, pad
      n += 2200 } }'
}
user_turn() { # text file.ts -> a real user message, an Edit of a source file and its tool result
  local u; nid; u="$NID"
  printf '{"type":"user","uuid":"u-%s","promptId":"p-%s","message":{"role":"user","content":"%s"}}\n' "$u" "$u" "$1"
  printf '{"type":"assistant","uuid":"a-%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu-%s","name":"Edit","input":{"file_path":"/w/%s"}}]}}\n' "$u" "$u" "$2"
  printf '{"type":"user","uuid":"r-%s","message":{"role":"user","content":[{"tool_use_id":"tu-%s","type":"tool_result","content":"ok"}]},"toolUseResult":{"stdout":"ok"}}\n' "$u" "$u"
}
work_step() { # bytes -> more work in the same turn: notification, attachment, Bash call, big tool result, text
  local u big; nid; u="$NID"; big=$(head -c "$1" /dev/zero | tr '\0' 'y')
  printf '{"type":"user","uuid":"n-%s","origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>agent done</task-notification>"}}\n' "$u"
  printf '{"type":"attachment","uuid":"at-%s","attachment":{"type":"file","content":"x"}}\n' "$u"
  printf '{"type":"assistant","uuid":"b-%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"tb-%s","name":"Bash","input":{"command":"npm test"}}]}}\n' "$u" "$u"
  printf '{"type":"user","uuid":"rb-%s","message":{"role":"user","content":[{"tool_use_id":"tb-%s","type":"tool_result","content":"%s"}]}}\n' "$u" "$u" "$big"
  printf '{"type":"assistant","uuid":"c-%s","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}\n' "$u"
}
bgate() { OUT=$(printf '{"session_id":"%s","transcript_path":"%s","stop_hook_active":false}' "$1" "$2" \
    | env PATH="$FB:$PATH" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" "$SG" 2>/dev/null); }
calls() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
printf '#!/bin/sh\necho call >> "%s"\ncat >/dev/null\nexit 1\n' "$CALLS" > "$FB/claude"
rm -rf "$STATE"; mkdir -p "$STATE"; rm -f "$CALLS"
BIG="$T/big.jsonl"; gen_prefix 4.5 > "$BIG"; user_turn "fix the client" client.ts >> "$BIG"
for i in 1 2 3 4 5 6 7 8 9 10; do work_step 20000 >> "$BIG"; bgate bigs "$BIG"; done
assert_eq "1: transcript > 4 MB growing ~20 KB per Stop, failing verifier, 10 Stops -> exactly 2 calls" 2 "$(calls)"
user_turn "now fix the server" server.ts >> "$BIG"
bgate bigs "$BIG"
assert_eq "1: > 4 MB transcript: a new real user turn resets the count" 3 "$(calls)"
for i in 1 2 3 4; do work_step 20000 >> "$BIG"; bgate bigs "$BIG"; done
assert_eq "1: tool results, task notifications and attachments never reset it (still 4 calls)" 4 "$(calls)"
# a single turn larger than the window: no user line in view -> one stable overflow key, bounded
rm -rf "$STATE"; mkdir -p "$STATE"; rm -f "$CALLS"
HUGE="$T/huge.jsonl"; gen_prefix 0.1 > "$HUGE"; user_turn "migrate everything" all.ts >> "$HUGE"
work_step 4100000 >> "$HUGE"
for i in 1 2 3 4 5; do
  work_step 20000 >> "$HUGE"
  printf '{"type":"assistant","uuid":"e-%s","message":{"role":"assistant","content":[{"type":"tool_use","id":"te-%s","name":"Edit","input":{"file_path":"/w/more.ts"}}]}}\n' "$i" "$i" >> "$HUGE"
  bgate huge "$HUGE"
done
assert_eq "1: a turn bigger than the 4 MB window: 5 Stops -> at most 2 calls (single overflow key)" 2 "$(calls)"
rm -f "$BIG" "$HUGE"

# ---------------------------------------------------------------- round 8 / 2: tty path, a child that keeps forking
FORKS="$T/fork-stub"; mkdir -p "$FORKS"
# bounded: at most 400 children per run, one every 10 ms; each child carries the marker in its argv
printf '#!/bin/bash\ncat >/dev/null\nbash -c '"'"'n=0; while [ $n -lt 400 ]; do bash -c "sleep 1000; :" %s-fork & n=$((n + 1)); sleep 0.01; done; wait'"'"' %s-forker &\nwait\n' "$MARK" "$MARK" > "$FORKS/claude"
chmod +x "$FORKS/claude"
cat > "$T/fork-run.sh" <<EOS
. "$KIT/hooks/lib.sh"
: > "$T/fork-in"; : > "$T/fork-res"
for i in 1 2 3 4 5 6 7 8 9 10; do
  kit_run_timeout 1 "$T/fork-in" "$T/fork-out" "$FORKS/claude"
  sleep 0.4
  echo "\$(pgrep -f "$MARK-fork" | wc -l | tr -d ' ')" >> "$T/fork-res"
  pkill -9 -f "$MARK-fork" 2>/dev/null
done
EOS
if run_pty "$BASH_BIN" "$T/fork-run.sh"; then
  tot=$(awk '{ s += $1 } END { print s + 0 }' "$T/fork-res" 2>/dev/null)
  runs=$(grep -c . "$T/fork-res" 2>/dev/null)
  assert_eq "2: under a tty, a child forking every 10 ms, 10 runs: all runs completed" 10 "$runs"
  assert_eq "2: under a tty, a child forking every 10 ms, 10 runs: 0 orphans" 0 "$tot"
else
  echo "SKIP 2: no pseudo-terminal available (python3 pty or script)"
fi
cleanup_marks

# ---------------------------------------------------------------- round 9 / 2: TERM during the kill walk
# A bounded 46-level process chain; the walker is TERMed 0.3 s in. Nothing may be left stopped (state T).
CHAIN="$T/chain.sh"
printf '#!/bin/bash\nif [ "$1" -gt 0 ]; then bash "$0" $(( $1 - 1 )) "$2" & fi\nsleep 1000\n:\n' > "$CHAIN"; chmod +x "$CHAIN"
cat > "$T/walk-run.sh" <<EOS
. "$KIT/hooks/lib.sh"
bash "$CHAIN" 46 "$MARK-chain" &
root=\$!
sleep 1
( kit_kill_tree "\$root" ) &
walker=\$!
sleep 0.3
kill -TERM "\$walker" 2>/dev/null
wait "\$walker" 2>/dev/null
sleep 0.5
st=""
for p in \$(pgrep -f "$MARK-chain"); do st="\$st\$(ps -o stat= -p "\$p" 2>/dev/null | cut -c1)"; done
echo "\$st" > "$T/walk-res"
for p in \$(pgrep -f "$MARK-chain"); do kill -9 "\$p" 2>/dev/null; kill -CONT "\$p" 2>/dev/null; done
EOS
if run_pty "$BASH_BIN" "$T/walk-run.sh"; then
  st=$(cat "$T/walk-res" 2>/dev/null)
  case "$st" in *T*) fail "2: walker TERMed mid-walk leaves no stopped processes" "states [$st]" ;; *) pass "2: walker TERMed mid-walk leaves no stopped processes (states [$st])" ;; esac
else
  echo "SKIP round 9 / 2: no pseudo-terminal available"
fi
cleanup_marks

# ---------------------------------------------------------------- round 8 / 3: wording
assert_not_has "3: stop-gate no longer says 1..170" "$(cat "$REPO/hooks/stop-gate.sh")" "1..170"
for lim in "shares the user's terminal" "fire up to 1 s early" "bigger than the transcript window"; do
  assert_has "3: known limit documented: $lim" "$(cat "$REPO/hooks/stop-gate.sh")" "$lim"
done

cleanup_marks
finish

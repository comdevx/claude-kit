#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
mk_kit; mk_projects
SS="$KIT/hooks/session-start.sh"
pl() { printf '{"session_id":"%s","cwd":"%s","source":"%s","model":%s}' "$1" "$2" "$3" "${4:-\"claude-opus-4-5\"}"; }

for mode in $MODES; do
  # discipline
  PAYLOAD=$(pl d1 "$T/work/nogit" startup); run_hook $mode "$SS" discipline
  assert_has "[$mode] discipline injected" "$OUT" DISC-RULES
  valid_json "$OUT" && pass "[$mode] discipline output valid JSON" || fail "[$mode] discipline output valid JSON" "$OUT"
  assert_has "[$mode] discipline event name" "$OUT" '"hookEventName":"SessionStart"'
  PAYLOAD=$(pl d2 "$T/work/nogit" startup '"claude-fable-5"'); run_hook $mode "$SS" discipline
  assert_empty "[$mode] discipline skipped for fable id" "$OUT"
  PAYLOAD=$(pl d3 "$T/work/nogit" startup '{"id":"claude-x","display_name":"Claude Mythos"}'); run_hook $mode "$SS" discipline
  assert_empty "[$mode] discipline skipped for mythos display name" "$OUT"
  PAYLOAD='{"session_id":"d4","cwd":"/x","source":"startup"}'; run_hook $mode "$SS" discipline
  assert_has "[$mode] discipline injected when model absent" "$OUT" DISC-RULES

  # code gating
  PAYLOAD=$(pl c1 "$T/work/gitnode" startup); run_hook $mode "$SS" code
  assert_has "[$mode] code: git+manifest -> injected" "$OUT" CODE-RULES
  [ -f "$STATE/sessions/c1.code" ] && pass "[$mode] code mode marked" || fail "[$mode] code mode marked" "no marker"
  PAYLOAD=$(pl c2 "$T/work/gitnode/pkg/sub" startup); run_hook $mode "$SS" code
  assert_has "[$mode] code: subdir of git repo with root manifest" "$OUT" CODE-RULES
  PAYLOAD=$(pl c3 "$T/work/gitsrc" startup); run_hook $mode "$SS" code
  assert_has "[$mode] code: git + top-level source file" "$OUT" CODE-RULES
  PAYLOAD=$(pl c4 "$HOME_T" startup); run_hook $mode "$SS" code
  assert_empty "[$mode] code: \$HOME (even with .git+package.json) -> nothing" "$OUT"
  PAYLOAD=$(pl c5 "/" startup); run_hook $mode "$SS" code
  assert_empty "[$mode] code: / -> nothing" "$OUT"
  PAYLOAD=$(pl c6 "$T/work/media" startup); run_hook $mode "$SS" code
  assert_empty "[$mode] code: media folder -> nothing" "$OUT"
  PAYLOAD=$(pl c7 "$T/work/nogit" startup); run_hook $mode "$SS" code
  assert_empty "[$mode] code: non-git folder with package.json -> nothing" "$OUT"
  PAYLOAD=$(pl c8 "$T/work/gitplain" startup); run_hook $mode "$SS" code
  assert_empty "[$mode] code: git repo with only README -> nothing" "$OUT"
  [ ! -f "$STATE/sessions/c6.code" ] && pass "[$mode] non-code folder not marked" || fail "[$mode] non-code folder not marked" "marked"

  # compact / resume
  PAYLOAD=$(pl k1 "$T/work/gitnode" startup); run_hook $mode "$SS" code
  PAYLOAD=$(pl k1 "$HOME_T" compact); run_hook $mode "$SS" code
  assert_has "[$mode] compact re-injects when code mode was active (even in non-code cwd)" "$OUT" CODE-RULES
  PAYLOAD=$(pl k2 "$HOME_T" compact); run_hook $mode "$SS" code
  assert_empty "[$mode] compact without code mode -> nothing" "$OUT"
  PAYLOAD=$(pl k1 "$HOME_T" resume); run_hook $mode "$SS" code
  assert_has "[$mode] resume re-injects when code mode was active" "$OUT" CODE-RULES
  PAYLOAD=$(pl k1 "$HOME_T" clear); run_hook $mode "$SS" code
  assert_empty "[$mode] clear in non-code cwd resets code mode" "$OUT"
  [ ! -f "$STATE/sessions/k1.code" ] && pass "[$mode] clear removes marker" || fail "[$mode] clear removes marker" "still marked"

  # platform per OS
  for os in macos linux windows; do
    PAYLOAD=$(pl p1 "$T/work/nogit" startup); CLAUDE_KIT_OS=$os run_hook $mode "$SS" platform
    up=$(printf '%s' "$os" | tr a-z A-Z)
    assert_has "[$mode] platform $os" "$OUT" "PLAT-$up"
  done
  unset CLAUDE_KIT_OS
  : > "$KIT/rules/platform-linux.md"
  PAYLOAD=$(pl p2 "/x" startup); CLAUDE_KIT_OS=linux run_hook $mode "$SS" platform
  assert_empty "[$mode] empty platform file -> nothing" "$OUT"
  printf 'PLAT-LINUX\n' > "$KIT/rules/platform-linux.md"

  # state pruning through the hook
  mkdir -p "$STATE/sessions"; : > "$STATE/sessions/stale.code"; touch -t 202001010000 "$STATE/sessions/stale.code"
  PAYLOAD=$(pl pr1 "$T/work/gitnode" startup); run_hook $mode "$SS" code
  [ ! -e "$STATE/sessions/stale.code" ] && pass "[$mode] session-start prunes old state" || fail "[$mode] session-start prunes old state" "kept"

  # truncation
  awk 'BEGIN{for(i=0;i<1500;i++) print "line number " i " of a very long rules file"}' > "$KIT/rules/code.md"
  PAYLOAD=$(pl t1 "$T/work/gitnode" startup); run_hook $mode "$SS" code
  assert_has "[$mode] oversized rules: stderr warning" "$ERR" "truncated"
  assert_has "[$mode] oversized rules: marker in output" "$OUT" "truncated"
  valid_json "$OUT" && pass "[$mode] oversized rules: valid JSON" || fail "[$mode] oversized rules: valid JSON" "invalid"
  if [ -n "$REAL_JQ" ]; then
    n=$(ctx_of "$OUT" | wc -c | tr -d ' ')
    [ "$n" -le 10000 ] && pass "[$mode] oversized rules: context <= 10000 ($n)" || fail "[$mode] oversized rules: context <= 10000" "$n"
  fi
  printf 'CODE-RULES\n' > "$KIT/rules/code.md"
done
# no rules file at all -> silent
rm -f "$KIT/rules/code.md"; PAYLOAD=$(pl m1 "$T/work/gitnode" startup); run_hook nojq "$SS" code
assert_empty "missing code.md -> nothing" "$OUT"; assert_eq "missing code.md rc" 0 "$RC"
finish

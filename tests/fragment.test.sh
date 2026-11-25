#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
F="$REPO/hooks/settings.fragment.json"
if [ -z "$REAL_JQ" ]; then echo "SKIP fragment tests need jq"; finish; exit $?; fi
"$REAL_JQ" -e . "$F" >/dev/null 2>&1 && pass "settings.fragment.json valid JSON" || fail "settings.fragment.json valid JSON" "invalid"
"$REAL_JQ" -e . "$REPO/cursor/hooks.json" >/dev/null 2>&1 && pass "cursor/hooks.json valid JSON" || fail "cursor/hooks.json valid JSON" "invalid"
cmds=$("$REAL_JQ" -r '.. | objects | select(has("command")) | .command' "$F" "$REPO/cursor/hooks.json")
n=0
while IFS= read -r c; do
  [ -n "$c" ] || continue
  n=$((n + 1))
  case "$c" in "bash \"__KIT_HOME__/"*) pass "command form: $c" ;; *) fail "command form" "$c" ;; esac
  rel=$(printf '%s' "$c" | sed -E 's/^bash "__KIT_HOME__\/([^"]*)".*/\1/')
  [ -f "$REPO/$rel" ] && pass "script exists: $rel" || fail "script exists: $rel" "missing"
  args=$(printf '%s' "$c" | sed -E 's/^bash "[^"]*" ?//')
  case "$rel" in
    hooks/session-start.sh|hooks/code-detect.sh) case "$args" in discipline|code|platform|pretool|posttool|prompt) pass "valid arg: $args" ;; *) fail "valid arg" "$args" ;; esac ;;
  esac
done <<EOT
$cmds
EOT
[ "$n" -ge 9 ] && pass "fragment lists >= 9 commands ($n)" || fail "fragment lists >= 9 commands" "$n"
m=$("$REAL_JQ" -r '.SessionStart[0].matcher' "$F")
assert_eq "SessionStart matcher covers compact" "startup|resume|clear|compact" "$m"
m=$("$REAL_JQ" -r '.PreToolUse[0].matcher' "$F")
assert_eq "PreToolUse matcher (Bash too: code-detect logs shell writes of source files)" "Edit|Write|MultiEdit|NotebookEdit|Bash" "$m"
# every hook script is executable-or-bash-runnable and uses no absolute owner path (covered in robust)
finish

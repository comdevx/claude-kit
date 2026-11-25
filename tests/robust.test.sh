#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
mk_kit; mk_projects
H="$KIT/hooks"
cases="session-start.sh:discipline session-start.sh:code session-start.sh:platform code-detect.sh:pretool code-detect.sh:posttool code-detect.sh:prompt lessons-index.sh: task-status.sh: stop-gate.sh:"
for mode in $MODES; do
  for c in $cases; do
    s="${c%%:*}"; a="${c#*:}"
    for p in '' '   ' 'not json at all' '{"session_id":' '{' '[1,2,3]' '{"unrelated":"field"}' '{"session_id":"","cwd":"","tool_input":{}}' '{"session_id":"x","tool_input":{"file_path":null}}'; do
      PAYLOAD="$p"; run_hook $mode "$H/$s" $a
      if [ "$RC" -eq 0 ]; then pass "[$mode] $s $a rc=0 for [$p]"; else fail "[$mode] $s $a rc=0 for [$p]" "rc=$RC"; fi
      # stdout must be empty or one valid JSON doc (never anything else)
      if [ -n "$OUT" ]; then valid_json "$OUT" && pass "[$mode] $s $a output is JSON for [$p]" || fail "[$mode] $s $a output is JSON for [$p]" "$OUT"; fi
    done
  done
  # truly nothing for junk on the injectors that need fields
  for c in code-detect.sh:pretool code-detect.sh:posttool code-detect.sh:prompt; do
    PAYLOAD='garbage'; run_hook $mode "$H/${c%%:*}" ${c#*:}
    assert_empty "[$mode] $c silent on garbage" "$OUT"
  done
  # the cursor scripts too
  for s in record-edit.sh record-shell.sh session-context.sh stop-gate.sh; do
    PAYLOAD='garbage'; run_hook $mode "$KIT/cursor/hooks/$s"
    assert_eq "[$mode] cursor $s rc=0 on garbage" 0 "$RC"
    valid_json "$OUT" && pass "[$mode] cursor $s output JSON on garbage" || fail "[$mode] cursor $s output JSON on garbage" "$OUT"
  done
done
# no script may hardcode an owner path
bad=$(grep -rnE '/Us''ers/|/home/[a-z]+/|~/\.claude/|\$HOME/\.claude/' "$REPO/hooks" "$REPO/cursor" 2>/dev/null | grep -v 'CLAUDE_CONFIG_DIR' | grep -v '^[^:]*:[0-9]*:#' | head -3)
assert_empty "no hardcoded owner paths" "$bad"
# every script parses under the running bash
for f in "$REPO"/hooks/*.sh "$REPO"/cursor/hooks/*.sh; do
  "$BASH_BIN" -n "$f" 2>/dev/null && pass "syntax $(basename "$f")" || fail "syntax $(basename "$f")" "bash -n failed"
done
finish

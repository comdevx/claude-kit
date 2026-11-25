#!/bin/bash
# SessionStart hook: inject the tail of <profile>/lessons/INDEX.md when it exists.
# Profile dir = $CLAUDE_CONFIG_DIR or ~/.claude. Silent when there is no index.
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$KIT_ROOT/hooks/lib.sh" 2>/dev/null || exit 0
cat >/dev/null 2>&1 || true

profile="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
idx="$profile/lessons/INDEX.md"
[ -s "$idx" ] || exit 0

size=$(wc -c < "$idx" | tr -d ' ')
if [ "$size" -gt 8000 ]; then
  body="(index truncated to newest entries)
$(tail -c 8000 "$idx" | sed 1d)"
else
  body=$(cat "$idx")
fi
header="# Lessons Learned index ($profile/lessons/)
Before starting work, scan this index. If the upcoming task touches any entry below
(same service, same library, same class of problem), Read that lesson file first -
these are verified gotchas that cost real debugging time before."
kit_emit SessionStart "$header

$body" "lessons index"
exit 0

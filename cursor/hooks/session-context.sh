#!/bin/bash
# Cursor sessionStart hook: inject the kit rules (core, discipline, code) and the lessons
# index. Reads live from the kit home so Claude Code and Cursor share one source of truth.
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/hooks/lib.sh" 2>/dev/null || { echo '{}'; exit 0; }
cat >/dev/null 2>&1 || true
ctx=""
# Order matters: the result is capped and cut from the end, so the most important parts come first.
for f in core "platform-$(kit_os)" discipline code; do
  t=$(kit_rules_text "$KIT_ROOT/rules/$f.md")
  [ -n "$t" ] && ctx="$ctx${ctx:+

}$t"
done
idx="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/lessons/INDEX.md"
if [ -s "$idx" ]; then
  ctx="$ctx${ctx:+

}# Lessons Learned index
If the upcoming task touches any entry below, read that lesson file first.

$(tail -c 6000 "$idx" | sed 1d)"
fi
[ -n "$ctx" ] || { echo '{}'; exit 0; }
ctx=$(kit_cap_text "$ctx" "Cursor session context" 2>/dev/null)
printf '{"additional_context":%s}\n' "$(printf '%s' "$ctx" | kit_json_string)"

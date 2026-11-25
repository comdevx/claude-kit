#!/bin/bash
# SessionStart hook: summarise docs/task.md of the project (open tasks, first open task's
# Handoff, pointer to docs/decisions.md). Silent when there is no docs/task.md.
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$KIT_ROOT/hooks/lib.sh" 2>/dev/null || exit 0
input=$(cat 2>/dev/null || true)

dir=$(kit_json_get "$input" cwd)
[ -n "$dir" ] || dir="${CLAUDE_PROJECT_DIR:-$PWD}"
dir=$(kit_norm_path "$dir")

# Walk up to the nearest ancestor with docs/task.md; never accept $HOME or a parent above it.
root="$dir"
while [ "$root" != "/" ] && [ "$root" != "." ] && [ "$root" != "$HOME" ] && [ ! -f "$root/docs/task.md" ]; do
  p=$(dirname "$root"); [ "$p" = "$root" ] && break; root="$p"
done
[ "$root" != "$HOME" ] || exit 0
tasks="$root/docs/task.md"
[ -f "$tasks" ] || exit 0

open=$(awk -F'|' '
  $2 ~ /^[[:space:]]*[0-9]+[[:space:]]*$/ && $4 !~ /✅/ {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4)
    print $2 "\t" $3 "\t" $4
  }' "$tasks")
open_count=$(printf '%s' "$open" | grep -c .)

body="# Project status (from docs/task.md, injected by SessionStart hook)
Project root: $root"
if [ "$open_count" -eq 0 ]; then
  body="$body
Open tasks: none."
else
  list=$(printf '%s\n' "$open" | head -5 | awk -F'\t' '{ printf "- #%s %s [%s]\n", $1, $2, $3 }')
  body="$body
Open tasks ($open_count, first 5):
$list"
  [ "$open_count" -gt 5 ] && body="$body
- ... $((open_count - 5)) more in docs/task.md"
  first=$(printf '%s\n' "$open" | head -1 | cut -f1)
  detail="$root/docs/tasks/task-$first.md"
  if [ -f "$detail" ]; then
    handoff=$(awk '/^## Handoff/{f=1; next} /^## /{f=0} f' "$detail" | sed '/^[[:space:]]*$/d' | head -15)
    [ -n "$handoff" ] && body="$body

Handoff notes for task #$first (docs/tasks/task-$first.md):
$handoff"
  fi
fi
body="$body

Before starting work: read the detail file of the task you are resuming."
if [ -f "$root/docs/decisions.md" ]; then
  body="$body
This project keeps a decision log: docs/decisions.md. Read it before designing or changing behavior.
Never silently reverse a recorded decision - raise it with the owner, then record the new decision."
fi
kit_emit SessionStart "$body" "task status"
exit 0

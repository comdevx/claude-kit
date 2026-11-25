#!/bin/bash
# Cursor afterShellExecution hook: record the command + output for the stop gate.
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$KIT_ROOT/hooks/lib.sh" 2>/dev/null || { echo '{}'; exit 0; }
input=$(head -c 6000 2>/dev/null || true)
cid=$(kit_safe "$(kit_json_get "$input" conversation_id)")
[ -n "$cid" ] || cid=unknown
d="$(kit_state_dir)/cursor"; mkdir -p "$d" 2>/dev/null
printf 'SHELL %s\n' "$(printf '%s' "$input" | tr -d '\n')" >> "$d/$cid.log" 2>/dev/null
echo '{}'

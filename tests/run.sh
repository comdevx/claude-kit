#!/bin/bash
# Runs every tests/*.test.sh under bash (use `/bin/bash tests/run.sh` for macOS bash 3.2).
# Counts both `PASS name` and `PASS: name` lines. -v prints PASS lines too. Non-zero exit when any test fails.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
verbose=0; [ "${1:-}" = "-v" ] && verbose=1
total_p=0; total_f=0; files=0; failed_files=""
for t in "$here"/*.test.sh; do
  [ -f "$t" ] || continue
  files=$((files + 1))
  out=$(KIT_TEST_REPO="$(cd "$here/.." && pwd)" "${BASH:-bash}" "$t" 2>&1); rc=$?
  p=$(printf '%s\n' "$out" | grep -cE '^PASS[: ]')
  f=$(printf '%s\n' "$out" | grep -cE '^FAIL[: ]')
  total_p=$((total_p + p)); total_f=$((total_f + f))
  if [ "$verbose" = 1 ]; then printf '%s\n' "$out"; else printf '%s\n' "$out" | grep -vE '^PASS[: ]' ; fi
  if [ "$rc" -ne 0 ] || [ "$f" -gt 0 ]; then failed_files="$failed_files $(basename "$t")"; [ "$f" -eq 0 ] && total_f=$((total_f + 1)); fi
  printf '== %s: %s passed, %s failed (rc=%s)\n' "$(basename "$t")" "$p" "$f" "$rc"
done
printf 'SUMMARY: %s files, %s passed, %s failed (bash %s)\n' "$files" "$total_p" "$total_f" "${BASH_VERSION:-?}"
[ "$total_f" -eq 0 ] && [ -z "$failed_files" ]

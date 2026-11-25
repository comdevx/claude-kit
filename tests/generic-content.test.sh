#!/usr/bin/env bash
# Fails when the kit tree contains personal data: owner/project names, personal
# absolute paths, or email addresses. Run from anywhere; scans the repo root.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="tests/generic-content.test.sh"
fail=0

scan() { # name, regex
  local name="$1" re="$2" hits
  hits=$(cd "$ROOT" && grep -rnIiE "$re" . \
    --exclude-dir=.git --exclude=.git --exclude-dir=node_modules --exclude-dir=dist --exclude="$(basename "$SELF")" \
    --exclude=.DS_Store 2>/dev/null | grep -vE "^\./${SELF}:" || true)
  if [ -n "$hits" ]; then
    echo "FAIL: $name"
    echo "$hits" | head -20 | sed 's/^/    /'
    fail=1
  else
    echo "PASS: $name"
  fi
}

scan "no personal home paths (/Users/<name>, /home/<name>)" '/Users/[a-z]|/home/[a-z]'
scan "no personal mail domains" '@(gmail|googlemail|outlook|hotmail|yahoo|icloud|proton(mail)?)\.'
# Private terms (owner and project names) never live in this public repo. A maintainer keeps them in a
# local file, one extended regex per line ('#' comments and blank lines ignored), and points
# CLAUDE_KIT_PRIVATE_DENYLIST at it. Without the variable (e.g. in CI) this part is skipped.
if [ -n "${CLAUDE_KIT_PRIVATE_DENYLIST:-}" ]; then
  if [ -r "$CLAUDE_KIT_PRIVATE_DENYLIST" ]; then
    terms=$(grep -v '^[[:space:]]*#' "$CLAUDE_KIT_PRIVATE_DENYLIST" | grep -v '^[[:space:]]*$' | paste -sd '|' -)
    [ -n "$terms" ] && scan "no terms from the private denylist" "$terms"
  else
    echo "FAIL: private denylist $CLAUDE_KIT_PRIVATE_DENYLIST is not readable"; fail=1
  fi
fi
scan "no email addresses" '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'

exit "$fail"

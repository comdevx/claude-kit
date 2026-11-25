# Shared test helpers (sourced by *.test.sh). Bash 3.2 compatible.
REPO="${KIT_TEST_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
BASH_BIN="${BASH:-/bin/bash}"
REAL_JQ="$(command -v jq 2>/dev/null)"
PASSES=0; FAILS=0

T=$(mktemp -d "${TMPDIR:-/tmp}/kit-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
KIT="$T/kit"; STATE="$T/state"; HOME_T="$T/home"; mkdir -p "$HOME_T" "$STATE"
unset CLAUDE_CONFIG_DIR CLAUDE_KIT_OS CLAUDE_STOP_GATE_CHILD

pass() { PASSES=$((PASSES + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL %s -- %s\n' "$1" "$2"; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
assert_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing [$3] in [$(printf '%s' "$2" | head -c 200)]" ;; esac; }
assert_not_has() { case "$2" in *"$3"*) fail "$1" "unexpected [$3]" ;; *) pass "$1" ;; esac; }
assert_empty() { if [ -z "$2" ]; then pass "$1"; else fail "$1" "expected empty, got [$(printf '%s' "$2" | head -c 200)]"; fi; }
finish() { printf '# %s passed, %s failed\n' "$PASSES" "$FAILS"; [ "$FAILS" -eq 0 ]; }

# Kit fixture: copies the real scripts, writes FAKE rules (the real rules are never used).
mk_kit() {
  rm -rf "$KIT"; mkdir -p "$KIT/hooks" "$KIT/rules" "$KIT/cursor/hooks"
  cp "$REPO"/hooks/*.sh "$REPO"/hooks/*.json "$KIT/hooks/"
  cp "$REPO"/cursor/hooks/*.sh "$KIT/cursor/hooks/"
  printf 'CORE-RULES\n' > "$KIT/rules/core.md"
  printf 'DISC-RULES\n' > "$KIT/rules/discipline.md"
  printf 'CODE-RULES\n' > "$KIT/rules/code.md"
  printf 'PLAT-MACOS\n' > "$KIT/rules/platform-macos.md"
  printf 'PLAT-LINUX\n' > "$KIT/rules/platform-linux.md"
  printf 'PLAT-WINDOWS\n' > "$KIT/rules/platform-windows.md"
  rm -rf "$STATE"; mkdir -p "$STATE"
}

# PATH without jq: symlink every system tool except jq into one dir.
NOJQ_BIN="$T/nojq-bin"; mkdir -p "$NOJQ_BIN"
for d in /usr/bin /bin /usr/sbin /sbin; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    n="${f##*/}"; [ "$n" = jq ] && continue
    [ -e "$NOJQ_BIN/$n" ] || ln -s "$f" "$NOJQ_BIN/$n" 2>/dev/null
  done
done

MODES="jq nojq"; [ -n "$REAL_JQ" ] || MODES="nojq"

# run_hook <jq|nojq> <script-path> [args...]   payload in $PAYLOAD -> OUT ERR RC
run_hook() {
  local mode="$1" p="$PATH"; shift
  [ "$mode" = nojq ] && p="$NOJQ_BIN"
  OUT=$(printf '%s' "$PAYLOAD" | env PATH="$p" HOME="$HOME_T" CLAUDE_KIT_STATE="$STATE" ${CLAUDE_KIT_OS:+CLAUDE_KIT_OS="$CLAUDE_KIT_OS"} ${EXTRA_ENV:-} "$BASH_BIN" "$@" 2>"$T/err")
  RC=$?
  ERR=$(cat "$T/err")
}

# valid_json <text> -> 0 when valid (needs real jq; otherwise returns 0 = unchecked)
valid_json() { [ -n "$REAL_JQ" ] || return 0; printf '%s' "$1" | "$REAL_JQ" -e . >/dev/null 2>&1; }
ctx_of() { [ -n "$REAL_JQ" ] && printf '%s' "$1" | "$REAL_JQ" -r '.hookSpecificOutput.additionalContext // empty'; }

# Project fixtures under $T/work
mk_projects() {
  W="$T/work"; rm -rf "$W"; mkdir -p "$W"
  mkdir -p "$W/gitnode/.git" "$W/media/.git" "$W/nogit" "$W/gitsrc/.git" "$W/gitplain/.git" "$HOME_T/.git"
  echo '{}' > "$W/gitnode/package.json"
  echo '{}' > "$W/nogit/package.json"
  : > "$W/media/clip.mp4"; : > "$W/media/subs.srt"; : > "$W/media/notes.md"
  echo 'print(1)' > "$W/gitsrc/main.py"
  echo 'hi' > "$W/gitplain/README.md"
  echo '{}' > "$HOME_T/package.json"
  mkdir -p "$W/gitnode/pkg/sub"
}

# with_timeout <seconds> <cmd...>: run cmd in the background with a watchdog (bash 3.2, no `timeout`
# binary needed). Output -> WD_OUT, status -> WD_RC (124 = killed by the watchdog). A hang fails the
# calling test instead of hanging the suite; the whole process tree is killed (pgrep -P when present).
kill_tree() {
  local c
  if command -v pgrep >/dev/null 2>&1; then for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; fi
  kill -9 "$1" 2>/dev/null
}
with_timeout() {
  local s="$1" pid n=0 lim; shift
  lim=$((s * 20))
  ( "$@" ) > "$T/wd.out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge "$lim" ]; then kill_tree "$pid"; wait "$pid" 2>/dev/null; WD_RC=124; WD_OUT=$(cat "$T/wd.out"); return 124; fi
    sleep 0.05; n=$((n + 1))
  done
  wait "$pid"; WD_RC=$?; WD_OUT=$(cat "$T/wd.out")
  return "$WD_RC"
}

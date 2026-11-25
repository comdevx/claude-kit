# Installer e2e helpers (sourced after helpers.sh). Bash 3.2 compatible.
# Every installer test runs the BUILT dist/install.sh in a throw-away HOME under $T; the real HOME,
# ~/.claude*, ~/.cursor and ~/.claude-kit are never touched (env -i drops every inherited variable).

[ -n "$REAL_JQ" ] || { echo "SKIP installer tests need jq on the build machine"; exit 0; }
T=$(cd "$T" && pwd)   # same dir, without the "//" a TMPDIR ending in "/" leaves (the installer normalizes paths)
mkdir -p "$T/tmp" "$T/jq-bin"
ln -s "$REAL_JQ" "$T/jq-bin/jq"
JQ_PATH="$NOJQ_BIN:$T/jq-bin"
DIST="$T/dist"
TAB=$(printf '\t')
KIT_N=$("$REAL_JQ" '[.. | objects | select(has("command"))] | length' "$REPO/hooks/settings.fragment.json")   # kit hook commands
KIT_ITEMS=$(( $(find "$REPO/skills" -mindepth 1 -maxdepth 1 -type d | wc -l) + $(ls "$REPO"/commands/*.md | wc -l) ))   # kit skills + commands

build_dist() {
  if "$BASH_BIN" "$REPO/build-release.sh" --worktree --version "${1:-9.9.9-test}" --out "$DIST" > "$T/build.log" 2>&1; then
    pass "build-release.sh --worktree builds the installers"
  else
    fail "build-release.sh --worktree" "$(cat "$T/build.log")"; finish; exit 1
  fi
}

# new_home <name>: H = fresh HOME dir (name may contain spaces), KH = its kit home
new_home() {
  H="$T/$1"; rm -rf "$H"; mkdir -p "$H"; KH="$H/.claude-kit"
  case "$H" in "$T"/*) ;; *) echo "refusing: test HOME outside the temp dir"; exit 1 ;; esac
}

# run_in <cmd...>: runs a command with the test environment -> OUT RC
#   HOME_ARG (default $H), INST_PATH (default: system tools + jq), TTYF (default none), RUNNING (default 0), XENV (extra VAR=val words)
run_in() {
  OUT=$(cd "${RUN_CWD:-$T}" && env -i HOME="${HOME_ARG:-$H}" PATH="${INST_PATH:-$JQ_PATH}" TMPDIR="$T/tmp" LANG=C \
    CLAUDE_KIT_HOME="$KH" CLAUDE_KIT_TTY="${TTYF:-none}" CLAUDE_KIT_ASSUME_RUNNING="${RUNNING:-0}" ${XENV:-} \
    "$@" 2>&1 < /dev/null)
  RC=$?
}
run_inst() { run_in "$BASH_BIN" "${INSTALLER:-$DIST/install.sh}" "$@"; }
run_cli() { run_in "$BASH_BIN" "$KH/bin/claude-kit" "$@"; }

# tree <dir> [skip]: listing (skip = leave out the kit's .claude-kit-backups dirs); of every path with type, link target and content checksum
tree() {
  (cd "$1" && {
    if [ -n "${2:-}" ]; then find . -name .claude-kit-backups -prune -o -print
    else find . -print; fi
  } | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
    elif [ -f "$p" ]; then printf 'F %s %s\n' "$p" "$(cksum < "$p")"
    elif [ -d "$p" ]; then printf 'D %s\n' "$p"
    fi
  done)
}
assert_tree_same() { # name before after
  if [ "$2" = "$3" ]; then pass "$1"
  else fail "$1" "trees differ: $(diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | head -20 | tr '\n' '|')"; fi
}

kit_cmd_count() { # settings file -> number of kit hook commands
  "$REAL_JQ" '[.. | objects | select(has("command")) | .command | select(contains("/.claude-kit/hooks/"))] | length' "$1"
}
count_of() { printf '%s' "$1" | grep -c -- "$2"; }

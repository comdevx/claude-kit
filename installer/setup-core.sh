#!/bin/bash
# claude-kit installer core: all install / uninstall / status / doctor logic.
# Bash 3.2 compatible (macOS /bin/bash), Linux bash, Git Bash on Windows.
# Runs from an extracted payload dir (CLAUDE_KIT_PAYLOAD_DIR, default: the dir above this script).
# Usage: setup-core.sh --help

NL='
'
TAB=$(printf '\t')
US=$(printf '\037')   # field separator that keeps empty fields (tab is IFS whitespace)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="${CLAUDE_KIT_PAYLOAD_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# Items a Shared-mode secondary links to the primary.
CONFIG_ITEMS="CLAUDE.md settings.json skills commands agents output-styles hooks lessons"
HISTORY_ITEMS="projects history.jsonl plans todos file-history sessions plugins shell-snapshots paste-cache image-cache"
# Per-account identity: never linked, whatever the share level.
NEVER_SHARE=".claude.json .credentials.json settings.local.json mcp.json statsig telemetry"
PROFILE_MARKERS="settings.json .claude.json projects history.jsonl sessions"
BEGIN_MARK='<!-- claude-kit:begin -->'
END_MARK='<!-- claude-kit:end -->'
RULE_CAP=9500

# ---------------------------------------------------------------- output helpers
say() { printf '%s\n' "$*"; }
warn() { printf 'claude-kit: warning: %s\n' "$*" >&2; }
die() { printf 'claude-kit: error: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat <<'EOF'
claude-kit installer

Usage: bash install.sh [options]          (Windows: powershell -ExecutionPolicy Bypass -File install.ps1 [options])
       curl -fsSL <url>/install.sh | bash -s -- [options]

Without options it shows a menu (read from the terminal). With no terminal you must pass
--profile or --all.

  --profile <dir>     install into this Claude Code config dir (repeatable)
  --all               install into every detected profile
  --mode <m>          independent (default) | shared
  --primary <dir>     Shared mode: the profile the others link to (default ~/.claude or the first)
  --share <level>     Shared mode: config (default) | config+history
  --kit-home <dir>    where the kit files live (default ~/.claude-kit, or $CLAUDE_KIT_HOME)
  --no-cursor         do not touch Cursor at all            (env CLAUDE_KIT_NO_CURSOR=1)
  --cursor-dir <dir>  Cursor config dir instead of ~/.cursor (env CLAUDE_KIT_CURSOR_DIR)
  --no-cli            do not link the claude-kit CLI anywhere (env CLAUDE_KIT_NO_CLI=1)
  --bin-dir <dir>     link the claude-kit CLI into this dir  (env CLAUDE_KIT_BIN_DIR)
                      (default: ~/.local/bin or ~/bin when on PATH)
  --yes, -y           answer yes to every question (installing jq, restoring backups, ...)
  --dry-run, -n       print every planned change and touch nothing
  --list-profiles     print the detected profiles and exit
  --uninstall         remove everything the kit created (asks before restoring backups)
  --help, -h          this help
EOF
}

# ---------------------------------------------------------------- path helpers
kit_os() {
  case "${CLAUDE_KIT_OS:-}" in macos|linux|windows) printf '%s' "$CLAUDE_KIT_OS"; return 0 ;; esac
  case "$(uname -s 2>/dev/null)" in
    Darwin*) printf 'macos' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *) printf 'linux' ;;
  esac
}
real_windows() { case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac; return 1; }
# win_paths: backslash and drive-letter forms are path syntax only on Windows (elsewhere "\" is an
# ordinary file-name character)
win_paths() { [ "$(kit_os)" = windows ] || real_windows; }

# norm_path <p>: on Windows backslashes -> slashes and C:/x -> /c/x (cygpath); repeated slashes
# collapsed; trailing slashes dropped
norm_path() {
  local p="$1"
  if win_paths; then p=$(printf '%s' "$p" | tr '\\' '/'); fi
  p=$(printf '%s' "$p" | sed 's#//*#/#g')
  case "$p" in
    [A-Za-z]:/*|[A-Za-z]:)
      if command -v cygpath >/dev/null 2>&1; then p=$(cygpath -u "$p" 2>/dev/null || printf '%s' "$p"); fi ;;
  esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s' "$p"
}

# expand_path <raw>: strip quotes, expand ~ $HOME ${HOME} %USERPROFILE% $env:USERPROFILE $env:HOME,
# make absolute. Returns 1 (prints nothing) when an unresolvable variable remains.
expand_path() {
  local v="$1" pre winsyn=0
  v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
  [ -n "$v" ] || return 1
  case "$v" in [A-Za-z]:\\*|[A-Za-z]:/*) winsyn=1 ;; esac
  for pre in '${HOME}' '$HOME' '%USERPROFILE%' '%HOME%' '${env:USERPROFILE}' '$env:USERPROFILE' '$env:HOME' '~'; do
    case "$v" in
      "$pre"|"$pre"/*|"$pre"\\*)
        case "$pre" in %*|*env:*) winsyn=1 ;; esac      # PowerShell / cmd syntax: "\" separates
        v="$HOME${v#"$pre"}"; break ;;
    esac
  done
  [ "$winsyn" = 1 ] && v=$(printf '%s' "$v" | tr '\\' '/')
  case "$v" in *'$'*|*%*%*) return 1 ;; esac
  v=$(norm_path "$v")
  case "$v" in /*) ;; *) v="$PWD/$v" ;; esac
  dot_norm "$v"
}

# dot_norm <absolute path>: resolve "." and ".." segments lexically (./b, sub/../b -> b)
dot_norm() {
  local IFS=/ part out=""
  set -f
  for part in $1; do
    case "$part" in
      ""|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$part" ;;
    esac
  done
  set +f
  printf '%s' "${out:-/}"
}

# realpath_of <path>: canonical path, following symlinks (dirs via cd -P, files via a readlink loop).
# Works for a missing leaf (prints the canonical parent + name). Portable: no readlink -f.
realpath_of() {
  local p="$1" d b t n=0
  while :; do
    if [ -d "$p" ]; then (cd -P "$p" 2>/dev/null && pwd -P) && return 0; printf '%s' "$p"; return 1; fi
    d=$(dirname "$p"); b=$(basename "$p")
    d=$(cd -P "$d" 2>/dev/null && pwd -P) || { printf '%s' "$p"; return 1; }
    [ "$d" = / ] && d=""
    p="$d/$b"
    if [ -L "$p" ]; then
      t=$(readlink "$p")
      case "$t" in /*) p="$t" ;; *) p="$d/$t" ;; esac
      n=$((n + 1)); [ "$n" -gt 40 ] && { printf '%s' "$p"; return 1; }
    else
      printf '%s' "$p"; return 0
    fi
  done
}

# disp <path>: ~/ form when under HOME
# disp <path>: ~/ form when under HOME; in --dry-run the absolute path follows in brackets, so a reader
# can see exactly which directory a planned change would touch
disp() {
  local p="$1" d
  case "$p" in
    "$HOME") d='~' ;;
    "$HOME"/*) d="~/${p#"$HOME"/}" ;;
    *)
      d="$p"
      if [ -n "$HOME_REAL" ] && [ "$HOME_REAL" != "$HOME" ]; then
        case "$p" in "$HOME_REAL"/*) d="~/${p#"$HOME_REAL"/}" ;; esac
      fi ;;
  esac
  if [ "${DRY:-0}" = 1 ] && [ "$d" != "$p" ]; then printf '%s [%s]' "$d" "$p"; else printf '%s' "$d"; fi
}

# home_rel <path>: path relative to HOME (also when only the real paths match); returns 1 when outside
home_rel() {
  local r
  case "$1" in "$HOME"/*) printf '%s' "${1#"$HOME"/}"; return 0 ;; esac
  r=$(realpath_of "$1")
  case "$r" in "$HOME_REAL"/*) printf '%s' "${r#"$HOME_REAL"/}"; return 0 ;; esac
  return 1
}

# home_form <path>: "$HOME/rel" literal when under HOME (portable in hook commands), else the path
home_form() {
  local rel
  if rel=$(home_rel "$1"); then printf '$HOME/%s' "$rel"; else printf '%s' "$1"; fi
}

in_list() { case "$NL$2$NL" in *"$NL$1$NL"*) return 0 ;; esac; return 1; }
add_line() { if [ -z "$1" ]; then printf '%s' "$2"; else printf '%s\n%s' "$1" "$2"; fi; }

ends_with_newline() { [ -s "$1" ] && [ "$(tail -c 1 "$1" | od -An -tx1 | tr -d ' \n')" = "0a" ]; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}

# ---------------------------------------------------------------- terminal / questions
TTY_OK=0
setup_tty() {
  local t="${CLAUDE_KIT_TTY:-}"
  [ "$t" = none ] && return 0
  if [ -n "$t" ]; then
    if (exec 3<"$t") 2>/dev/null; then exec 3<"$t"; TTY_OK=1; fi
    return 0
  fi
  if (exec 3</dev/tty) 2>/dev/null; then exec 3</dev/tty; TTY_OK=1
  elif [ -t 0 ]; then exec 3<&0; TTY_OK=1; fi
}

# read_answer <prompt> -> ANSWER; returns 1 without a terminal / on EOF
read_answer() {
  ANSWER=""
  [ "$TTY_OK" = 1 ] || return 1
  printf '%s ' "$1" >&2
  IFS= read -r ANSWER <&3 || { printf '\n' >&2; return 1; }
  ANSWER=$(printf '%s' "$ANSWER" | tr -d '\r')
  return 0
}

# ask <question> <default y|n>: --yes -> yes; no terminal -> no
ask() {
  if [ "$YES" = 1 ]; then say "$1 yes (--yes)"; return 0; fi
  read_answer "$1 [$( [ "$2" = y ] && echo Y/n || echo y/N )]" || return 1
  case "$ANSWER" in
    "") [ "$2" = y ] ;;
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# act <description>: prints the change; returns 0 when it should really be done (not --dry-run)
act() {
  if [ "$DRY" = 1 ]; then say "  [dry-run] would $1"; return 1; fi
  say "  $1"; return 0
}

# ---------------------------------------------------------------- symlink capability
can_symlink() {
  [ "${CLAUDE_KIT_FORCE_NO_SYMLINK:-}" = 1 ] && return 1
  if [ -z "$SYMLINK_OK" ]; then
    SYMLINK_OK=no
    if real_windows; then
      local d; d=$(mktemp -d "${TMPDIR:-/tmp}/ck-ln.XXXXXX")
      mkdir "$d/t" && ln -s "$d/t" "$d/l" 2>/dev/null && [ -L "$d/l" ] && SYMLINK_OK=yes
      rm -rf "$d"
    else
      SYMLINK_OK=yes
    fi
  fi
  [ "$SYMLINK_OK" = yes ]
}

# make_junction <target-dir> <link>: Windows directory junction (no admin needed).
# Off Windows (tests with CLAUDE_KIT_FORCE_NO_SYMLINK=1) it is emulated with a symlink.
make_junction() {
  if real_windows; then
    cmd //c mklink //J "$(cygpath -w "$2")" "$(cygpath -w "$1")" >/dev/null 2>&1   # "//" keeps MSYS from rewriting the flag into a path
  else
    ln -s "$1" "$2"
  fi
}
# remove_junction <link>: removes the junction itself. `rmdir` without /s never touches the target's
# contents, and it refuses a real non-empty directory, so a replaced junction is left alone.
remove_junction() {
  if real_windows; then cmd //c rmdir "$(cygpath -w "$1")" >/dev/null 2>&1
  else rm -f "$1"; fi
}

claude_running() {
  case "${CLAUDE_KIT_ASSUME_RUNNING:-}" in 1) return 0 ;; 0) return 1 ;; esac
  if real_windows; then
    tasklist //FI "IMAGENAME eq claude.exe" //NH 2>/dev/null | grep -qi 'claude.exe'
    return $?
  fi
  pgrep -x claude >/dev/null 2>&1 && return 0
  pgrep -f '(^|/)claude( |$)' >/dev/null 2>&1
}

# ---------------------------------------------------------------- jq programs
JQ_LIB='
def iskit($m): if type == "object" then ((.command // "") | tostring) as $c | any($m[]; . as $x | $c | contains($x)) else false end;
def strip_groups($m; $prune):
  if type == "object" and (.hooks | type) == "object" then
    (.hooks | length) as $n0
    | .hooks |= (reduce keys[] as $k (.;
        if (.[$k] | type) == "array" then
          (.[$k] | map(
              if type == "object" and (.hooks | type) == "array" and any(.hooks[]; iskit($m))
              then (.hooks |= map(select(iskit($m) | not))) | select((.hooks | length) > 0)
              else . end)) as $new
          | if $prune and ($new | length) == 0 and (.[$k] | length) > 0 then del(.[$k]) else .[$k] = $new end
        else . end))
    | if $prune and $n0 > 0 and (.hooks | length) == 0 then del(.hooks) else . end
  else . end;
def strip_flat($m; $prune):
  if type == "object" and (.hooks | type) == "object" then
    (.hooks | length) as $n0
    | .hooks |= (reduce keys[] as $k (.;
        if (.[$k] | type) == "array" then
          (.[$k] | map(select(iskit($m) | not))) as $new
          | if $prune and ($new | length) == 0 and (.[$k] | length) > 0 then del(.[$k]) else .[$k] = $new end
        else . end))
    | if $prune and $n0 > 0 and (.hooks | length) == 0 then del(.hooks) else . end
  else . end;
def subst($kh): (.. | strings) |= (split("__KIT_HOME__") | join($kh));
def add_hooks($frag): .hooks = (reduce ($frag | keys_unsorted[]) as $e ((.hooks // {}); .[$e] = ((.[$e] // []) + $frag[$e])));
def has_kit_groups($m): [.hooks? // {} | .[]? | arrays | .[] | objects | .hooks? | arrays | .[] | select(iskit($m))] | length > 0;
def prune_added($o):
  (($o | type) == "object" and ($o | has("hooks"))) as $ohas
  | (if $ohas and ($o.hooks | type) == "object" then $o.hooks else {} end) as $oh
  | (if type == "object" and (.hooks | type) == "object" then
       .hooks |= with_entries(select(.key as $k | (((.value | type) == "array") and ((.value | length) == 0) and (($oh | has($k)) | not)) | not))
     else . end)
  | (if type == "object" and .hooks == {} and ($ohas | not) then del(.hooks) else . end);
def has_kit_flat($m): [.hooks? // {} | .[]? | arrays | .[] | select(iskit($m))] | length > 0;
'

settings_marks() { # JSON array of substrings that identify kit hook commands
  jq -cn --arg a "/.claude-kit/hooks/" --arg b "$KH_CMD/hooks/" --arg c "$KH/hooks/" '[$a, $b, $c] | unique'
}
cursor_marks() {
  jq -cn --arg a "/.claude-kit/cursor/hooks/" --arg b "$KH_CURSOR/cursor/hooks/" --arg c "$KH/cursor/hooks/" '[$a, $b, $c] | unique'
}

# ---------------------------------------------------------------- arguments
YES=0; DRY=0; ALL=0; MODE=""; PRIMARY_ARG=""; SHARE=""; ACTION=install; PROFILE_ARGS=""; KH_ARG=""
# Isolation (e.g. a test run that must use the real HOME). --no-cursor / --no-cli always win over a
# --cursor-dir / --bin-dir given in any order or through the environment.
NO_CURSOR="${CLAUDE_KIT_NO_CURSOR:-}"; CURSOR_DIR_ARG="${CLAUDE_KIT_CURSOR_DIR:-}"
NO_CLI="${CLAUDE_KIT_NO_CLI:-}"; BIN_DIR_ARG="${CLAUDE_KIT_BIN_DIR:-}"
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile) [ $# -ge 2 ] || die "--profile needs a directory" 2; PROFILE_ARGS=$(add_line "$PROFILE_ARGS" "$2"); shift ;;
      --profile=*) PROFILE_ARGS=$(add_line "$PROFILE_ARGS" "${1#*=}") ;;
      --all) ALL=1 ;;
      --mode) [ $# -ge 2 ] || die "--mode needs a value" 2; MODE="$2"; shift ;;
      --mode=*) MODE="${1#*=}" ;;
      --primary) [ $# -ge 2 ] || die "--primary needs a directory" 2; PRIMARY_ARG="$2"; shift ;;
      --primary=*) PRIMARY_ARG="${1#*=}" ;;
      --share) [ $# -ge 2 ] || die "--share needs a value" 2; SHARE="$2"; shift ;;
      --share=*) SHARE="${1#*=}" ;;
      --kit-home) [ $# -ge 2 ] || die "--kit-home needs a directory" 2; KH_ARG="$2"; shift ;;
      --kit-home=*) KH_ARG="${1#*=}" ;;
      --no-cursor) NO_CURSOR=1 ;;
      --cursor-dir) [ $# -ge 2 ] || die "--cursor-dir needs a directory" 2; CURSOR_DIR_ARG="$2"; shift ;;
      --cursor-dir=*) CURSOR_DIR_ARG="${1#*=}" ;;
      --no-cli) NO_CLI=1 ;;
      --bin-dir) [ $# -ge 2 ] || die "--bin-dir needs a directory" 2; BIN_DIR_ARG="$2"; shift ;;
      --bin-dir=*) BIN_DIR_ARG="${1#*=}" ;;
      --yes|-y) YES=1 ;;
      --dry-run|-n) DRY=1 ;;
      --uninstall) ACTION=uninstall ;;
      --list-profiles) ACTION=list ;;
      --status) ACTION=status ;;
      --doctor) ACTION=doctor ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown option: $1" 2 ;;
    esac
    shift
  done
  case "$MODE" in ""|independent|shared) ;; *) die "--mode must be independent or shared" 2 ;; esac
  case "$SHARE" in ""|config|config+history) ;; *) die "--share must be config or config+history" 2 ;; esac
}

setup_paths() {
  local rel
  case "${HOME:-}" in
    /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;;
    *) die "HOME must be an absolute path (got: ${HOME:-<unset>}). Nothing was changed." ;;
  esac
  HOME=$(norm_path "$HOME")
  [ -n "$HOME" ] && [ -d "$HOME" ] || die "HOME is not set to a directory"
  HOME_REAL=$(realpath_of "$HOME")
  local kh="${KH_ARG:-${CLAUDE_KIT_HOME:-$HOME/.claude-kit}}"
  KH=$(expand_path "$kh") || die "cannot resolve kit home: $kh"
  case "$KH" in *'"'*|*"$NL"*) die "kit home path must not contain quotes or newlines: $KH" ;; esac
  KH_CMD=$(home_form "$KH")            # used in Claude Code hook commands ($HOME stays literal)
  if real_windows && command -v cygpath >/dev/null 2>&1; then KH_CURSOR=$(cygpath -m "$KH"); else KH_CURSOR="$KH"; fi
  if rel=$(home_rel "$KH"); then KH_IMPORT="~/$rel"; else KH_IMPORT="$KH"; fi
  MANIFEST="$KH/state/install.json"
  TS="$(date +%Y%m%d-%H%M%S)-$$"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/claude-kit-work.XXXXXX") || die "cannot create a temp dir"
  trap on_exit EXIT
  trap 'warn "interrupted"; exit 130' INT
  trap 'warn "terminated"; exit 143' TERM
  if real_windows; then export MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict"; fi
  KIT_VERSION="${CLAUDE_KIT_VERSION:-$(cat "$PAYLOAD/VERSION" 2>/dev/null || echo unknown)}"
  [ "$NO_CURSOR" = 1 ] || NO_CURSOR=""; [ "$NO_CLI" = 1 ] || NO_CLI=""
  if [ -n "$CURSOR_DIR_ARG" ]; then CURSOR_DIR=$(expand_path "$CURSOR_DIR_ARG") || die "cannot resolve --cursor-dir"; else CURSOR_DIR="$HOME/.cursor"; fi
  BIN_DIR=""; if [ -n "$BIN_DIR_ARG" ]; then BIN_DIR=$(expand_path "$BIN_DIR_ARG") || die "cannot resolve --bin-dir"; fi
}

# ---------------------------------------------------------------- prerequisites
jq_install_cmd() {
  local sudo=""
  [ "$(id -u 2>/dev/null)" = 0 ] || sudo="sudo "
  if command -v brew >/dev/null 2>&1; then echo "brew install jq"
  elif command -v apt-get >/dev/null 2>&1; then echo "${sudo}apt-get install -y jq"
  elif command -v dnf >/dev/null 2>&1; then echo "${sudo}dnf install -y jq"
  elif command -v pacman >/dev/null 2>&1; then echo "${sudo}pacman -S --noconfirm jq"
  elif command -v winget >/dev/null 2>&1 || command -v winget.exe >/dev/null 2>&1; then
    echo "winget install --id jqlang.jq -e --accept-source-agreements --accept-package-agreements"
  fi
}

ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  local cmd; cmd=$(jq_install_cmd)
  if [ -z "$cmd" ]; then
    die "jq is required but not installed, and no supported package manager was found.
  Install jq (https://jqlang.org/download/), e.g. one of:
    brew install jq | sudo apt-get install -y jq | sudo dnf install -y jq | winget install jqlang.jq
  then run the installer again. Nothing was changed." 3
  fi
  if [ "$DRY" != 1 ] && ask "jq is required. Install it now with: $cmd ?" n; then
    sh -c "$cmd" || true
    if ! command -v jq >/dev/null 2>&1 && [ -n "${LOCALAPPDATA:-}" ]; then
      PATH="$PATH:$(norm_path "$LOCALAPPDATA")/Microsoft/WinGet/Links"
    fi
    command -v jq >/dev/null 2>&1 && return 0
    die "jq is still not available after: $cmd
  Install it manually, open a new terminal and run the installer again. Nothing was changed." 3
  fi
  die "jq is required. Install it with:
    $cmd
  then run the installer again. Nothing was changed." 3
}

# ---------------------------------------------------------------- profile detection
is_profile() {
  local d="$1" m
  [ -d "$d" ] || return 1
  for m in $PROFILE_MARKERS; do [ -e "$d/$m" ] && return 0; done
  return 1
}

rc_files() {
  local f
  for f in .zshrc .zprofile .zshenv .bashrc .bash_profile .profile .config/fish/config.fish \
           Documents/PowerShell/Microsoft.PowerShell_profile.ps1 \
           Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1 \
           OneDrive/Documents/PowerShell/Microsoft.PowerShell_profile.ps1 \
           OneDrive/Documents/WindowsPowerShell/Microsoft.PowerShell_profile.ps1 \
           .config/powershell/Microsoft.PowerShell_profile.ps1; do
    [ -f "$HOME/$f" ] && printf '%s\n' "$HOME/$f"
  done
}

# rc_values <file>: raw values assigned to CLAUDE_CONFIG_DIR (sh/zsh/bash/PowerShell "=" form, fish "set" form)
rc_values() {
  local q="'" body
  body=$(grep -v '^[[:space:]]*#' "$1" 2>/dev/null)
  printf '%s\n' "$body" | grep -oE "CLAUDE_CONFIG_DIR[[:space:]]*=[[:space:]]*(\"[^\"]*\"|$q[^$q]*$q|[^[:space:];$q\"\`)|&]+)" \
    | sed -E 's/^CLAUDE_CONFIG_DIR[[:space:]]*=[[:space:]]*//'
  printf '%s\n' "$body" | grep -oE "set[[:space:]]+(-[A-Za-z]+[[:space:]]+)*CLAUDE_CONFIG_DIR[[:space:]]+(\"[^\"]*\"|$q[^$q]*$q|[^[:space:];$q\"]+)" \
    | sed -E 's/.*CLAUDE_CONFIG_DIR[[:space:]]+//'
}

candidates() {
  local d f v
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then expand_path "$CLAUDE_CONFIG_DIR" && echo; fi
  printf '%s\n' "$HOME/.claude"
  for d in "$HOME"/.claude-* "$HOME"/.config/claude*; do [ -d "$d" ] && printf '%s\n' "$d"; done
  rc_files | while IFS= read -r f; do
    rc_values "$f" | while IFS= read -r v; do
      [ -n "$v" ] || continue
      expand_path "$v" && echo
    done
  done
}

# detect_profiles -> PROFILES (newline list, display order, deduped by real path)
detect_profiles() {
  local c r seen="" khr
  PROFILES=""
  khr=$(realpath_of "$KH")
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    is_profile "$c" || continue
    r=$(realpath_of "$c")
    [ "$r" = "$khr" ] && continue
    in_list "$r" "$seen" && continue
    seen=$(add_line "$seen" "$r")
    PROFILES=$(add_line "$PROFILES" "$c")
  done <<EOF
$(candidates)
EOF
}

# share_info <profile>: "owner<TAB>item item ..." lines for items that resolve into another profile
share_info() {
  local p="$1" pr item r q qr owners="" o items
  pr=$(realpath_of "$p")
  for item in $CONFIG_ITEMS $HISTORY_ITEMS; do
    [ -e "$p/$item" ] || continue
    r=$(realpath_of "$p/$item")
    [ "$r" = "$pr/$item" ] && continue
    while IFS= read -r q; do
      [ -n "$q" ] && [ "$q" != "$p" ] || continue
      qr=$(realpath_of "$q")
      if [ "$r" = "$qr/$item" ]; then
        eval "items=\${SI_$(printf '%s' "$q" | cksum | cut -d' ' -f1):-}"
        eval "SI_$(printf '%s' "$q" | cksum | cut -d' ' -f1)=\"\$items \$item\""
        in_list "$q" "$owners" || owners=$(add_line "$owners" "$q")
        break
      fi
    done <<EOF
$PROFILES
EOF
  done
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    eval "items=\${SI_$(printf '%s' "$o" | cksum | cut -d' ' -f1):-}"
    eval "unset SI_$(printf '%s' "$o" | cksum | cut -d' ' -f1)"
    printf '%s\t%s\n' "$o" "${items# }"
  done <<EOF
$owners
EOF
}

share_text() { # profile -> " (shares a, b with ~/.x)" or ""
  local out="" o items
  while IFS="$TAB" read -r o items; do
    [ -n "$o" ] || continue
    items=$(printf '%s' "$items" | sed 's/ /, /g')
    out="${out:+$out; }shares $items with $(disp "$o")"
  done <<EOF
$(share_info "$1")
EOF
  [ -n "$out" ] && printf ' (%s)' "$out"
}

print_profiles() {
  local p i=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    i=$((i + 1))
    printf '  %d) %s%s\n' "$i" "$(disp "$p")" "$(share_text "$p")"
  done <<EOF
$PROFILES
EOF
}

nth_profile() { printf '%s\n' "$PROFILES" | sed -n "${1}p"; }
count_lines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

# ---------------------------------------------------------------- selection
select_profiles() {
  local p n tok
  SELECTED=""
  if [ -n "$PROFILE_ARGS" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      p=$(expand_path "$p") || die "cannot resolve profile path"
      in_list "$p" "$SELECTED" || SELECTED=$(add_line "$SELECTED" "$p")
    done <<EOF
$PROFILE_ARGS
EOF
  fi
  if [ "$ALL" = 1 ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      in_list "$p" "$SELECTED" || SELECTED=$(add_line "$SELECTED" "$p")
    done <<EOF
$PROFILES
EOF
  fi
  if [ -z "$PROFILE_ARGS" ] && [ "$ALL" != 1 ]; then
    # interactive menu
    if [ -z "$PROFILES" ]; then
      say "No Claude Code profile found."
      if ask "Create ~/.claude and install there?" y; then SELECTED="$HOME/.claude"; else die "nothing selected; nothing changed"; fi
    else
      read_answer "Select profiles: numbers separated by spaces, a = all, p = type a path, q = quit [1]:" || die "no answer; nothing changed"
      [ -n "$ANSWER" ] || ANSWER=1
      n=$(count_lines "$PROFILES")
      for tok in $ANSWER; do
        case "$tok" in
          q|Q) die "cancelled; nothing changed" ;;
          a|A) SELECTED="$PROFILES" ;;
          p|P)
            read_answer "Profile path:" || die "no answer; nothing changed"
            p=$(expand_path "$ANSWER") || die "cannot resolve: $ANSWER"
            in_list "$p" "$SELECTED" || SELECTED=$(add_line "$SELECTED" "$p") ;;
          *[!0-9]*|"") die "invalid choice: $tok" 2 ;;
          *)
            [ "$tok" -ge 1 ] && [ "$tok" -le "$n" ] || die "invalid choice: $tok" 2
            p=$(nth_profile "$tok")
            in_list "$p" "$SELECTED" || SELECTED=$(add_line "$SELECTED" "$p") ;;
        esac
      done
    fi
  fi
  if [ -z "$SELECTED" ]; then
    # --all with nothing detected
    say "No Claude Code profile found."
    if ask "Create ~/.claude and install there?" n; then SELECTED="$HOME/.claude"
    else die "no profile found. Pass --profile ~/.claude (or --yes to create it). Nothing changed." 2; fi
  fi
}

select_mode() {
  local n; n=$(count_lines "$SELECTED")
  if [ -z "$MODE" ]; then
    if [ "$n" -gt 1 ] && [ -z "$PROFILE_ARGS" ] && [ "$ALL" != 1 ]; then
      say "Mode:"
      say "  1) Independent - each profile gets its own settings merge (default)"
      say "  2) Shared - the other profiles link their config to one primary profile"
      read_answer "Choose mode [1]:" || ANSWER=1
      case "$ANSWER" in 2|s|shared) MODE=shared ;; *) MODE=independent ;; esac
    else
      MODE=independent
    fi
  fi
  [ "$MODE" = shared ] || return 0
  local p i
  if [ -n "$PRIMARY_ARG" ]; then
    PRIMARY=$(expand_path "$PRIMARY_ARG") || die "cannot resolve --primary"
  elif [ "$TTY_OK" = 1 ] && [ "$YES" != 1 ] && [ "$n" -gt 1 ]; then
    say "Primary profile (the others will link to it):"
    i=0
    while IFS= read -r p; do i=$((i + 1)); say "  $i) $(disp "$p")"; done <<EOF
$SELECTED
EOF
    read_answer "Choose primary [1]:" || ANSWER=1
    [ -n "$ANSWER" ] || ANSWER=1
    PRIMARY=$(printf '%s\n' "$SELECTED" | sed -n "${ANSWER}p")
    [ -n "$PRIMARY" ] || die "invalid primary choice" 2
  else
    if in_list "$HOME/.claude" "$SELECTED"; then PRIMARY="$HOME/.claude"; else PRIMARY=$(printf '%s\n' "$SELECTED" | sed -n 1p); fi
  fi
  in_list "$PRIMARY" "$SELECTED" || SELECTED=$(printf '%s\n%s' "$PRIMARY" "$SELECTED")
  if [ -z "$SHARE" ]; then
    if [ "$TTY_OK" = 1 ] && [ "$YES" != 1 ] && [ -z "$PROFILE_ARGS" ] && [ "$ALL" != 1 ]; then
      say "Share level:"
      say "  1) config - CLAUDE.md, settings.json, skills, commands, agents, output-styles, hooks, lessons (default)"
      say "  2) config+history - also projects (memory), history, plans, todos, sessions, plugins and caches"
      read_answer "Choose share level [1]:" || ANSWER=1
      case "$ANSWER" in 2) SHARE=config+history ;; *) SHARE=config ;; esac
    else
      SHARE=config
    fi
  fi
}

share_items() { if [ "$SHARE" = config+history ]; then echo "$CONFIG_ITEMS $HISTORY_ITEMS"; else echo "$CONFIG_ITEMS"; fi; }

# ---------------------------------------------------------------- journal and manifest records
# Every change is journaled to $KH/state/journal.jsonl BEFORE it is made. The journal is folded into
# the manifest at the end of the run and by the EXIT/INT/TERM trap, so an interrupted run can still be
# uninstalled; uninstall also folds a journal that was never folded.
JOURNAL=""; LEFTOVER_MANIFEST=""
journal_start() {
  [ "$DRY" = 1 ] && return 0
  mkdir -p "$KH/state" || die "cannot create $KH/state"
  JOURNAL="$KH/state/journal.jsonl"
  if [ -n "$LEFTOVER_MANIFEST" ] && jq -e . "$LEFTOVER_MANIFEST" >/dev/null 2>&1; then
    # the declined leftover's records go first: newer records of this run win per path, while the
    # leftover's original backups (the true pre-kit originals) win for originals
    jq -c '{rec: "run", version, kit_home, mode, primary, share, profiles: (.profiles // []),
            cursor_dirs: (.cursor_dirs // []), bin_dirs: (.bin_dirs // [])},
           ((.created // [])[] | {rec: "created"} + .), ((.originals // [])[] | {rec: "original"} + .),
           ((.backups // [])[] | {rec: "backup", path: .})' "$LEFTOVER_MANIFEST" >> "$JOURNAL" || die "cannot merge $LEFTOVER_MANIFEST"
  fi
  jq -cn --arg v "$KIT_VERSION" --arg kh "$KH" --arg mode "$MODE" --arg primary "${PRIMARY:-}" --arg share "${SHARE:-}" \
    --arg nc "$NO_CURSOR" --arg cdir "$( [ "$NO_CURSOR" = 1 ] || [ -z "$CURSOR_DIR_ARG" ] || printf '%s' "$CURSOR_DIR")" --arg ncli "$NO_CLI" --arg bdir "$( [ "$NO_CLI" = 1 ] || printf '%s' "$BIN_DIR")" \
    --arg profiles "$SELECTED" '{rec: "run", version: $v, kit_home: $kh, mode: $mode, primary: $primary, share: $share,
      no_cursor: ($nc == "1"), cursor_dir: $cdir, no_cli: ($ncli == "1"), bin_dir: $bdir,
      profiles: ($profiles | split("\n") | map(select(length > 0)))}' >> "$JOURNAL" || die "cannot write $JOURNAL"
}
jrec() { # one JSON object line
  [ -n "$JOURNAL" ] && [ "$DRY" != 1 ] || return 0
  printf '%s\n' "$1" >> "$JOURNAL" || die "cannot write the journal $JOURNAL"
}
rec_created() { # type path target backup [hash]
  jrec "$(jq -cn --arg t "$1" --arg p "$2" --arg g "$3" --arg b "$4" --arg h "${5:-}" \
    '{rec: "created", type: $t, path: $p} + (if $g != "" then {target: $g} else {} end) + (if $b != "" then {backup: $b} else {} end) + (if $h != "" then {hash: $h} else {} end)')"
}
rec_original() { # path backup-or-empty kind
  jrec "$(jq -cn --arg p "$1" --arg b "$2" --arg k "$3" '{rec: "original", path: $p, backup: (if $b == "" then null else $b end), kind: $k}')"
}
rec_backup() { jrec "$(jq -cn --arg p "$1" '{rec: "backup", path: $p}')"; }
known_manifests() { [ -f "$MANIFEST" ] && printf '%s\n' "$MANIFEST"; [ -n "$LEFTOVER_MANIFEST" ] && [ -f "$LEFTOVER_MANIFEST" ] && printf '%s\n' "$LEFTOVER_MANIFEST"; return 0; }
old_has_original() {
  local m
  while IFS= read -r m; do
    [ -n "$m" ] && jq -e --arg p "$1" '(.originals // []) | any(.path == $p)' "$m" >/dev/null 2>&1 && return 0
  done <<EOF
$(known_manifests)
EOF
  return 1
}
# oldest_clean_backup <real-file> <kind>: the oldest kit-made backup of that file without kit content
# (the pre-kit original), for kit content found in place without any record
oldest_clean_backup() {
  local f="$1" kind="$2" d c
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    c="$d/$(basename "$f")"
    [ -f "$c" ] || continue
    case "$kind" in
      claude-md) [ "$(block_state "$c")" = none ] || continue ;;
      settings) [ -s "$c" ] && jq -e --argjson m "$(settings_marks)" "$JQ_LIB has_kit_groups(\$m)" "$c" >/dev/null 2>&1 && continue ;;
      cursor) [ -s "$c" ] && jq -e --argjson m "$(cursor_marks)" "$JQ_LIB has_kit_flat(\$m)" "$c" >/dev/null 2>&1 && continue ;;
    esac
    printf '%s' "$c"; return 0
  done <<EOF
$(ls -1d "$(dirname "$f")"/.claude-kit-backups/*/ 2>/dev/null | sed 's#/$##' | LC_ALL=C sort)
EOF
  return 1
}
has_kit_content() { # real-file kind
  [ -f "$1" ] || return 1
  case "$2" in
    claude-md) [ "$(block_state "$1")" = ok ] ;;
    settings) [ -s "$1" ] && jq -e --argjson m "$(settings_marks)" "$JQ_LIB has_kit_groups(\$m)" "$1" >/dev/null 2>&1 ;;
    cursor) [ -s "$1" ] && jq -e --argjson m "$(cursor_marks)" "$JQ_LIB has_kit_flat(\$m)" "$1" >/dev/null 2>&1 ;;
  esac
}
# record_original <real-file> <fresh-backup-or-empty> <kind>: once per file; kit content found in place
# without a record points at the oldest clean kit-made backup instead
record_original() {
  local o="$2"
  old_has_original "$1" && return 0
  if has_kit_content "$1" "$3"; then o=$(oldest_clean_backup "$1" "$3") || o=""; fi
  rec_original "$1" "$o" "$3"
}
# old_copy_hash <path>: prints the recorded content hash when the newest manifest record says "copy"
old_copy_hash() {
  local m
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    jq -e -r --arg p "$1" '[(.created // [])[] | select(.path == $p)] | last | select(.type == "copy") | (.hash // "")' "$m" 2>/dev/null && return 0
  done <<EOF
$(known_manifests)
EOF
  return 1
}

# copy_hash <path>: content hash of a file or a directory tree
copy_hash() {
  if [ -d "$1" ]; then
    (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done) | cksum | awk '{print $1 "-" $2}'
  elif [ -f "$1" ]; then cksum < "$1" | awk '{print $1 "-" $2}'; fi
}

# fold_journal: merge $KH/state/journal.jsonl into the manifest (newest record per path wins for
# created entries, the oldest original backup wins), then remove the journal.
fold_journal() {
  local j="$KH/state/journal.jsonl"
  [ -f "$j" ] || return 0
  if [ -f "$MANIFEST" ] && jq -e . "$MANIFEST" >/dev/null 2>&1; then cp "$MANIFEST" "$WORK/old.json"; else echo '{}' > "$WORK/old.json"; fi
  jq -nR --slurpfile old "$WORK/old.json" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    def uniq: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);
    def first_per_path: reduce .[] as $x ([]; if any(.[]; .path == $x.path) then . else . + [$x] end);
    def newest_per_path: reverse | first_per_path | reverse;
    [inputs | (try fromjson catch empty) | objects] as $J
    | ($old[0] // {}) as $o
    | ([$J[] | select(.rec == "run")] | last // {}) as $r
    | { version: ($r.version // $o.version), kit_home: ($r.kit_home // $o.kit_home), mode: ($r.mode // $o.mode),
        primary: ($r.primary // $o.primary), share: ($r.share // $o.share),
        profiles: ((($o.profiles // []) + [$J[] | select(.rec == "run") | (.profiles // [])[]]) | uniq),
        cursor_dirs: ((($o.cursor_dirs // []) + [$J[] | select(.rec == "run") | ((.cursor_dirs // [])[]), (.cursor_dir // empty)] | map(select(. != ""))) | uniq),
        bin_dirs: ((($o.bin_dirs // []) + [$J[] | select(.rec == "run") | ((.bin_dirs // [])[]), (.bin_dir // empty)] | map(select(. != ""))) | uniq),
        no_cursor: (if ($r | has("no_cursor")) then $r.no_cursor else ($o.no_cursor // false) end),
        cursor_dir: (if ($r | has("cursor_dir")) then $r.cursor_dir else ($o.cursor_dir // "") end),
        no_cli: (if ($r | has("no_cli")) then $r.no_cli else ($o.no_cli // false) end),
        bin_dir: (if ($r | has("bin_dir")) then $r.bin_dir else ($o.bin_dir // "") end),
        created: ((($o.created // []) + [$J[] | select(.rec == "created") | del(.rec)]) | newest_per_path),
        originals: ((($o.originals // []) + [$J[] | select(.rec == "original") | del(.rec)]) | first_per_path),
        backups: ((($o.backups // []) + [$J[] | select(.rec == "backup") | .path]) | uniq),
        updated_at: $now }' "$j" > "$WORK/manifest.json" || { warn "cannot fold $j into the manifest; it is kept for the next run"; return 1; }
  write_atomic "$MANIFEST" "$WORK/manifest.json" && rm -f "$j"
}

on_exit() {
  local rc=$?
  if [ -n "$JOURNAL" ] && [ -f "$JOURNAL" ]; then fold_journal; fi
  rm -rf "$WORK"
  exit "$rc"
}

# backup_file <real-file> -> prints backup path (timestamped dir next to the file)
backup_file() {
  local f="$1" dir bdir
  dir=$(dirname "$f")
  bdir="$dir/.claude-kit-backups/$TS"
  if [ "$DRY" = 1 ]; then printf '%s' "$bdir/$(basename "$f")"; return 0; fi
  mkdir -p "$bdir" && cp -p "$f" "$bdir/$(basename "$f")" || die "cannot back up $f"
  rec_backup "$bdir/$(basename "$f")"
  printf '%s' "$bdir/$(basename "$f")"
}

# write_atomic <dst> <src>: temp file in the same dir, then rename (keeps the dst's mode)
write_atomic() {
  local dst="$1" src="$2" tmp
  local ro=0
  tmp="$(dirname "$dst")/.claude-kit.tmp.$$"
  if [ -f "$dst" ]; then
    cp -p "$dst" "$tmp" || return 1
    [ -w "$dst" ] || { ro=1; chmod u+w "$tmp"; }
  fi
  cat "$src" > "$tmp" || { rm -f "$tmp"; return 1; }
  [ "$ro" = 1 ] && chmod u-w "$tmp"
  mv -f "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

# DONE keys prevent merging the same physical file twice (profiles that share via symlinks)
DONE=""
claim() { # key -> 0 when first claim
  in_list "$1" "$DONE" && return 1
  DONE=$(add_line "$DONE" "$1"); return 0
}

# ---------------------------------------------------------------- CLAUDE.md block
CR=$(printf '\r')
has_crlf() { [ -f "$1" ] && grep -q "$CR\$" "$1" 2>/dev/null; }

block_text() { # [crlf]
  local e=""; [ "${1:-}" = crlf ] && e="$CR"
  printf '%s%s\n@%s/rules/core.md%s\n%s%s\n' "$BEGIN_MARK" "$e" "$KH_IMPORT" "$e" "$END_MARK" "$e"
}

block_state() { # file -> none | ok | broken   (CRLF-insensitive)
  [ -f "$1" ] || { echo none; return; }
  local b e
  b=$(tr -d '\r' < "$1" | grep -n -F -x "$BEGIN_MARK" | head -n 1 | cut -d: -f1)
  e=$(tr -d '\r' < "$1" | grep -n -F -x "$END_MARK" | head -n 1 | cut -d: -f1)
  if [ -z "$b" ] && [ -z "$e" ]; then echo none
  elif [ -n "$b" ] && [ -n "$e" ] && [ "$b" -lt "$e" ]; then echo ok
  else echo broken; fi
}

claude_md_new() { # real-file out   (keeps the file's line endings)
  local f="$1" out="$2" eol=""
  has_crlf "$f" && eol=crlf
  block_text $eol > "$WORK/block"
  case "$(block_state "$f")" in
    ok)
      awk -v bf="$WORK/block" -v b="$BEGIN_MARK" -v e="$END_MARK" '
        BEGIN { while ((getline l < bf) > 0) blk = blk l "\n" }
        { l = $0; sub(/\r$/, "", l) }
        l == b && !done { printf "%s", blk; done = 1; skip = 1; next }
        skip { if (l == e) skip = 0; next }
        { print }' "$f" > "$out" ;;
    none)
      if [ -s "$f" ]; then
        { cat "$f"; ends_with_newline "$f" || { [ -n "$eol" ] && printf '\r'; printf '\n'; }
          [ -n "$eol" ] && printf '\r'; printf '\n'; cat "$WORK/block"; } > "$out"
      else
        cat "$WORK/block" > "$out"
      fi ;;
    *) return 1 ;;
  esac
}

claude_md_strip() { # file out : remove the block and the blank line before it (CRLF-insensitive)
  awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    { l = $0; sub(/\r$/, "", l) }
    l == b { if (have && pl != "") print prev; have = 0; skip = 1; next }
    skip { if (l == e) skip = 0; next }
    { if (have) print prev; prev = $0; pl = l; have = 1 }
    END { if (have) print prev }' "$1" > "$2"
}

install_claude_md() { # profile
  local f="$1/CLAUDE.md" real bk=""
  real=$(realpath_of "$f")
  if ! claim "file:$real"; then say "  CLAUDE.md: $(disp "$f") is the same file as an earlier profile's; already handled"; return 0; fi
  [ -d "$(dirname "$real")" ] || [ "$DRY" = 1 ] || { warn "skip $(disp "$f"): it points to a missing directory"; return 0; }
  claude_md_new "$real" "$WORK/claude.md.new" || die "$(disp "$real") has a broken claude-kit block (begin/end markers); fix it and re-run"
  if [ -f "$real" ] && cmp -s "$WORK/claude.md.new" "$real"; then record_original "$real" "" claude-md; say "  CLAUDE.md: $(disp "$real") already up to date"; return 0; fi
  if [ -f "$real" ]; then bk=$(backup_file "$real") || die "cannot back up $(disp "$real"); stopped before editing it"; fi
  record_original "$real" "$bk" claude-md
  if act "add the claude-kit block to $(disp "$real")${bk:+ (backup: $(disp "$bk"))}"; then
    write_atomic "$real" "$WORK/claude.md.new" || die "cannot write $real"
  fi
}

# ---------------------------------------------------------------- settings.json merge
fragment_json() { jq -c --arg kh "$KH_CMD" "$JQ_LIB subst(\$kh)" "$PAYLOAD/hooks/settings.fragment.json"; }

validate_settings() { # real-file -> dies on invalid JSON
  [ -f "$1" ] || return 0
  [ -s "$1" ] || return 0
  jq -e 'type == "object" and ((.hooks // {}) | type) == "object"' "$1" >/dev/null 2>&1 \
    || die "$(disp "$1") is not a valid settings JSON object (or its \"hooks\" is not an object). Fix it and re-run. Nothing was changed."
}

# merge_settings_to <real-file> <out>: the kit merge, without writing the file
merge_settings_to() {
  local src="$1"
  [ -s "$src" ] || { echo '{}' > "$WORK/empty.json"; src="$WORK/empty.json"; }
  jq --argjson m "$(settings_marks)" --argjson f "$(fragment_json)" "$JQ_LIB strip_groups(\$m; false) | add_hooks(\$f)" "$src" > "$2" 2>/dev/null
}

install_settings() { # profile
  local f="$1/settings.json" real bk="" cnt
  real=$(realpath_of "$f")
  if ! claim "file:$real"; then say "  settings.json: $(disp "$f") is the same file as an earlier profile's; merged once"; return 0; fi
  [ -d "$(dirname "$real")" ] || [ "$DRY" = 1 ] || { warn "skip $(disp "$f"): it points to a missing directory"; return 0; }
  merge_settings_to "$real" "$WORK/settings.new" || die "cannot merge $(disp "$real")"
  if [ -f "$real" ] && cmp -s "$WORK/settings.new" "$real"; then record_original "$real" "" settings; say "  settings.json: $(disp "$real") already up to date"; return 0; fi
  if [ -f "$real" ]; then bk=$(backup_file "$real") || die "cannot back up $(disp "$real"); stopped before editing it"; fi
  record_original "$real" "$bk" settings
  cnt=$(fragment_json | jq '[.. | objects | select(has("command"))] | length')
  if act "merge $cnt kit hook entries into $(disp "$real") (other keys and hooks kept${bk:+; backup: $(disp "$bk")})"; then
    write_atomic "$real" "$WORK/settings.new" || die "cannot write $real"
  fi
}

# Keys that carry a profile's provider, credentials or account; settings.json is linked across
# profiles only when these agree.
IDENTITY_KEYS='["env","apiKeyHelper","awsAuthRefresh","awsCredentialExport","forceLoginMethod","forceLoginOrgUUID","model","otelHeadersHelper"]'
identity_of() { # settings file -> canonical JSON of its identity keys ({} when none / missing)
  if [ -s "$1" ] && jq -e 'type == "object"' "$1" >/dev/null 2>&1; then
    jq -cS --argjson k "$IDENTITY_KEYS" '. as $o | reduce $k[] as $x ({}; if ($o | has($x)) then .[$x] = $o[$x] else . end)' "$1"
  else echo '{}'; fi
}
# identity_conflict <primary-settings> <secondary-settings>: 0 unless the identity-bearing keys are
# identical on both sides (both absent counts as identical). Prints the differing key names.
identity_conflict() {
  local si pi
  si=$(identity_of "$2"); pi=$(identity_of "$1")
  [ "$si" = "$pi" ] && return 1
  jq -rn --argjson a "$si" --argjson b "$pi" '[($a + $b) | keys[] | . as $k | select((($a | has($k)) != ($b | has($k))) or ($a[$k] != $b[$k]))] | join(", ")'
  return 0
}

# ---------------------------------------------------------------- skills / commands
# kit_item_owned <link>: 0 when the symlink points into THIS install's kit home. The kit-home forms are
# computed once per run; the common case (a link the kit made, exact path) needs no tr/sed/realpath.
KIT_OWN_A=""; KIT_OWN_B=""; KIT_OWN_CA=""; KIT_OWN_CB=""
kit_own_init() {
  [ -n "$KIT_OWN_A" ] && return 0
  dot_norm_v "$KH"; slashes_v "$DN"; KIT_OWN_A="$SV"
  dot_norm_v "$(realpath_of "$KH")"; slashes_v "$DN"; KIT_OWN_B="$SV"
  KIT_OWN_CA=$(canon_cmp "$KIT_OWN_A"); KIT_OWN_CB=$(canon_cmp "$KIT_OWN_B")
}
kit_item_owned() {
  local t
  t=$(readlink "$1" 2>/dev/null)
  case "$t" in /*) ;; *) return 1 ;; esac          # the kit only makes absolute links; relative ones are never ours
  kit_own_init
  dot_norm_v "$t"; slashes_v "$DN"; t="$SV"       # $KH/../other must not look like $KH/...
  case "$t/" in "$KIT_OWN_A/"*|"$KIT_OWN_B/"*) return 0 ;; esac
  if case_insensitive; then                        # slow path only for case variants
    t=$(canon_cmp "$t")
    case "$t/" in "$KIT_OWN_CA/"*|"$KIT_OWN_CB/"*) return 0 ;; esac
  fi
  return 1
}
# dot_norm_v / slashes_v: in-shell variants (no subshell) -> DN / SV
dot_norm_v() {
  local IFS=/ part out=""
  set -f
  for part in $1; do
    case "$part" in ""|.) ;; ..) out="${out%/*}" ;; *) out="$out/$part" ;; esac
  done
  set +f
  DN="${out:-/}"
}
slashes_v() { local two=// one=/; SV="$1"; while case "$SV" in *//*) true ;; *) false ;; esac; do SV="${SV//$two/$one}"; done; }

# case_insensitive: macOS and Windows file systems ignore letter case. Folding happens when EITHER
# CLAUDE_KIT_OS (a test fake) OR the real uname says so: a fake can only add refusals, never remove them.
KIT_FOLD=""
case_insensitive() {
  if [ -z "$KIT_FOLD" ]; then
    KIT_FOLD=no
    case "$(kit_os)" in macos|windows) KIT_FOLD=yes ;; esac
    case "$(uname -s 2>/dev/null)" in Darwin*|MINGW*|MSYS*|CYGWIN*) KIT_FOLD=yes ;; esac
  fi
  [ "$KIT_FOLD" = yes ]
}

# canon_cmp <path>: the form used for path COMPARISONS: backslashes to slashes, C:/x and C:\x to /c/x,
# repeated slashes collapsed (also a leading // that pwd -P may keep), no trailing slash, and lower-cased
# on case-insensitive systems (APFS keeps the typed case even through pwd -P).
canon_cmp() {
  local p="$1"
  if win_paths; then
    p=$(printf '%s' "$p" | tr '\\' '/')
    case "$p" in [A-Za-z]:|[A-Za-z]:/*) p="/$(printf '%s' "${p%%:*}" | tr '[:upper:]' '[:lower:]')${p#?:}" ;; esac
  fi
  p=$(printf '%s' "$p" | sed 's#//*#/#g')
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  if case_insensitive; then p=$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]'); fi
  printf '%s' "$p"
}
# canon_real <path>: canon_cmp of the path resolved through the file system (where it exists)
canon_real() { canon_cmp "$(realpath_of "$(canon_cmp_slashes "$1")")"; }
canon_cmp_slashes() { if win_paths; then printf '%s' "$1" | tr '\\' '/' | sed 's#//*#/#g'; else printf '%s' "$1" | sed 's#//*#/#g'; fi; }

# kit_devino_lines: paths on stdin (one per line) -> one "device:inode" per line, "-" for a missing path;
# a single stat process for all existing paths
kit_devino_lines() {
  local p ids line out="" n=0
  kit_devino / >/dev/null || return 1
  set --
  while IFS= read -r p; do
    n=$((n + 1))
    if [ -e "$p" ]; then set -- "$@" "$p"; eval "KIT_DV_$n=1"; else eval "KIT_DV_$n=0"; fi
  done
  if [ $# -gt 0 ]; then
    case "$KIT_STAT" in
      bsd) ids=$(stat -L -f %d:%i "$@" 2>/dev/null) ;;
      gnu) ids=$(stat -L -c %d:%i "$@" 2>/dev/null) ;;
    esac
  fi
  local i=1
  while [ "$i" -le "$n" ]; do
    eval "line=\$KIT_DV_$i"
    if [ "$line" = 1 ]; then out="$out${ids%%
*}
"; case "$ids" in *"
"*) ids="${ids#*
}" ;; *) ids="" ;; esac
    else out="$out-
"; fi
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# kit_devino <path>: "device:inode" of an existing path (symlinks followed); stat -f (BSD/macOS) or
# stat -c (GNU, MSYS, busybox), detected once
KIT_STAT=""
kit_devino() {
  [ -e "$1" ] || return 1
  if [ -z "$KIT_STAT" ]; then
    if stat -f %d:%i / >/dev/null 2>&1; then KIT_STAT=bsd
    elif stat -c %d:%i / >/dev/null 2>&1; then KIT_STAT=gnu
    else KIT_STAT=none; fi
  fi
  case "$KIT_STAT" in
    bsd) stat -L -f %d:%i "$1" 2>/dev/null ;;
    gnu) stat -L -c %d:%i "$1" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# is_system_dir <canonical path>: 0 for / or a system directory (the list is shared by both guards)
is_system_dir() {
  case "$1" in ""|/) return 0 ;; esac
  case "$1" in
    /etc|/etc/*|/private/etc|/private/etc/*|/system|/system/*|/library|/library/*|/bin|/bin/*|/sbin|/sbin/*| \
    /usr|/usr/bin|/usr/bin/*|/usr/sbin|/usr/sbin/*|/usr/lib|/usr/lib/*|/usr/libexec|/usr/libexec/*|/usr/share|/usr/share/*| \
    /dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/boot|/boot/*|/var|/private|/private/var|/opt|/applications|/users|/home| \
    /System|/System/*|/Library|/Library/*|/Applications|/Users| \
    /[a-z]/windows|/[a-z]/windows/*|/[a-z]/programdata|/[a-z]/programdata/*|/[a-z]/users| \
    "/"[a-z]"/program files"|"/"[a-z]"/program files/"*|"/"[a-z]"/program files (x86)"|"/"[a-z]"/program files (x86)/"*)
      return 0 ;;
  esac
  return 1
}

# hooks_target_guard <resolved hooks.json target> <profiles>: the file the kit merges Cursor hooks into
# when ~/.cursor/hooks.json is a (dotfiles) symlink. Prints why and returns 1 when it must not be used:
#   (a) its directory is / or a system directory;
#   (b) its directory IS a profile root or the kit home root, or is inside the kit home;
#   (c) its name is a Claude Code / kit config file (settings.json, settings.local.json, .claude.json,
#       CLAUDE.md, install.json, *.md);
#   (d) it is not a .json file.
# Allowed: HOME itself (~/cursor-hooks.json), subfolders of a profile (~/.claude/cursor/hooks.json),
# dotfiles directories.
hooks_target_guard() {
  local t="$1" b d r id p k list np
  b="${t##*/}"; d=$(dirname "$t")
  case "$b" in settings.json|settings.local.json|.claude.json|install.json|CLAUDE.md|*.md)
    echo "it is a Claude Code or claude-kit configuration file ($b)"; return 1 ;; esac
  case "$b" in *.json) ;; *) echo "it is not a .json file ($b)"; return 1 ;; esac
  r=$(canon_real "$d")
  is_system_dir "$r" && { echo "its directory is / or a system directory ($r)"; return 1; }
  [ "$r" = "$(canon_real "$KH")" ] && { echo "its directory is the kit home"; return 1; }
  case "$r/" in "$(canon_real "$KH")/"*) echo "it is inside the kit home"; return 1 ;; esac
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ "$r" = "$(canon_real "$p")" ] && { echo "its directory is the profile root $(disp "$p")"; return 1; }
  done <<EOF
$2
EOF
  # the same by identity, for aliases (case, Unicode, symlinks): / and profile roots equal to the
  # directory; the kit home equal to the directory or one of its ancestors
  if [ -d "$d" ] && d=$(cd -P "$d" 2>/dev/null && pwd -P) && [ -n "$d" ]; then
    list=$(printf '%s\n%s' / "$KH")
    while IFS= read -r p; do [ -n "$p" ] && list=$(printf '%s\n%s' "$list" "$p"); done <<EOF
$2
EOF
    np=$(printf '%s\n' "$list" | grep -c .)
    k=0
    while [ -n "$d" ] && [ "$k" -lt 64 ]; do list=$(printf '%s\n%s' "$list" "$d"); [ "$d" = / ] && break; d="${d%/*}"; [ -n "$d" ] || d=/; k=$((k + 1)); done
    r=$(printf '%s\n' "$list" | kit_devino_lines | awk -v np="$np" '
      NR <= np { id[NR] = $0; next }
      { if ($0 == "-") next
        if (NR == np + 1) { if ($0 == id[1]) { print "its directory is /"; exit }
                            for (i = 3; i <= np; i++) if (id[i] != "-" && $0 == id[i]) { print "its directory is a profile root"; exit } }
        if (id[2] != "-" && $0 == id[2]) { print "it is inside the kit home"; exit } }')
    [ -n "$r" ] && { echo "$r"; return 1; }
  fi
  return 0
}

# dir_guard <dir> <profiles (newline list)>: prints why the dir must never be used as a Cursor or CLI
# dir and returns 1 - /, a system directory, HOME, a profile (or inside one), or the kit home (or inside).
# Comparisons use canon_real on both sides, so letter case (macOS, Windows), drive-letter forms and
# repeated slashes cannot slip past it.
dir_guard() {
  local r p pr c d n k ex=0 list np
  # 1) an existing directory is compared by device:inode, which no spelling can fool (Unicode NFC/NFD,
  #    non-ASCII case, a backslash-named or other symlink alias, macOS firmlinks). One stat call covers
  #    /, HOME, the kit home, every profile and every ancestor of the candidate (walked in pure bash).
  c="$1"; if win_paths; then c=$(printf '%s' "$c" | tr '\\' '/'); fi
  if [ -d "$c" ] && d=$(cd -P "$c" 2>/dev/null && pwd -P) && [ -n "$d" ]; then
    ex=1
    list=$(printf '%s\n%s\n%s' / "$HOME" "$KH")       # roles: 1 = /, 2 = HOME, 3 = kit home
    while IFS= read -r p; do [ -n "$p" ] && list=$(printf '%s\n%s' "$list" "$p"); done <<EOF
$2
EOF
    np=$(printf '%s\n' "$list" | grep -c .)
    n=0; k=0
    while [ -n "$d" ] && [ "$n" -lt 64 ]; do list=$(printf '%s\n%s' "$list" "$d"); [ "$d" = / ] && { k=1; break; }; d="${d%/*}"; [ -n "$d" ] || d=/; n=$((n + 1)); done
    # deeper than the bound: its ancestors cannot all be checked, so refuse rather than guess
    [ "$k" = 1 ] || { echo "it is nested more than 64 directory levels deep, too deep to check safely"; return 1; }
    k=$(printf '%s\n' "$list" | kit_devino_lines) || k=""
    if [ -n "$k" ]; then
      r=$(printf '%s\n' "$k" | awk -v np="$np" '
        NR <= np { id[NR] = $0; next }
        { if ($0 == "-") next
          if (NR == np + 1) { if ($0 == id[1]) { print "it is / (the same directory under another name)"; exit }
                              if ($0 == id[2]) { print "it is your HOME directory (the same directory under another name)"; exit } }
          if (id[3] != "-" && $0 == id[3]) { print "it is the kit home or inside it"; exit }
          for (i = 4; i <= np; i++) if (id[i] != "-" && $0 == id[i]) { print "PROFILE " i; exit } }')
      case "$r" in
        "") ;;
        "PROFILE "*) p=$(printf '%s\n' "$list" | sed -n "${r#PROFILE }p"); echo "it is the profile $(disp "$p") or inside it"; return 1 ;;
        *) echo "$r"; return 1 ;;
      esac
    else
      ex=0   # no usable stat: fall back to the string comparisons below
    fi
  fi
  # 2) string comparisons: paths that do not exist yet, and the system-directory list
  r=$(canon_real "$1")
  case "$r" in ""|/) echo "it is /"; return 1 ;; esac
  is_system_dir "$r" && { echo "it is a system directory ($r)"; return 1; }
  [ "$ex" = 1 ] && return 0   # existing dir: HOME / kit home / profiles were already compared by identity
  [ "$r" = "$(canon_cmp "$HOME_REAL")" ] && { echo "it is your HOME directory"; return 1; }
  case "$r/" in "$(canon_real "$KH")/"*) echo "it is the kit home or inside it"; return 1 ;; esac
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    pr=$(canon_real "$p")
    case "$r/" in "$pr/"*) echo "it is the profile $(disp "$p") or inside it"; return 1 ;; esac
  done <<EOF
$2
EOF
  return 0
}

# keep_edited <path> <profile> <label>: move a kit copy the user edited into the profile's backups
keep_edited() {
  local b="$2/.claude-kit-backups/$TS/$3"
  if act "keep your edited copy of $3 as $(disp "$b") (a kit copy you edited is never deleted)"; then
    mkdir -p "$(dirname "$b")" && mv "$1" "$b" || die "cannot move $1 to $b"
    rec_backup "$b"
  fi
}

only_kit_links() { # dir -> 0 when it is non-empty and every entry is a symlink into the kit home
  local e n=0
  for e in "$1"/* "$1"/.[!.]*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    [ -L "$e" ] && kit_item_owned "$e" || return 1
    n=$((n + 1))
  done
  [ "$n" -gt 0 ]
}
dir_recorded() {
  local m
  while IFS= read -r m; do
    [ -n "$m" ] && jq -e --arg p "$1" '(.created // []) | any(.path == $p and .type == "dir")' "$m" >/dev/null 2>&1 && return 0
  done <<EOF
$(known_manifests)
EOF
  return 1
}

link_kit_items() { # profile kind(skills|commands)
  local p="$1" kind="$2" dir real src name dst target made=0 linked=0 h oldh
  dir="$p/$kind"
  real=$(realpath_of "$dir")
  if ! claim "dir:$real"; then say "  $kind: $(disp "$dir") is shared with an earlier profile; already handled"; return 0; fi
  if [ -d "$dir" ] && [ ! -L "$dir" ] && ! dir_recorded "$dir" && only_kit_links "$dir"; then
    rec_created dir "$dir" "" ""   # a dir holding nothing but kit links was made by the kit (record lost)
  fi
  if [ ! -d "$dir" ]; then
    if [ -e "$dir" ] || [ -L "$dir" ]; then warn "skip $kind: $(disp "$dir") exists but is not a directory"; return 0; fi
    rec_created dir "$dir" "" ""
    act "create $(disp "$dir")/" && { mkdir -p "$dir" || die "cannot create $dir"; }
  fi
  for src in "$PAYLOAD/$kind"/*; do
    name=$(basename "$src")
    case "$kind" in
      skills) [ -d "$src" ] || continue ;;
      commands) [ -f "$src" ] || continue; case "$name" in *.md) ;; *) continue ;; esac ;;
    esac
    dst="$dir/$name"; target="$KH/$kind/$name"
    if [ -L "$dst" ]; then
      if [ "$(readlink "$dst")" = "$target" ] && can_symlink; then
        rec_created link "$dst" "$target" ""   # (re)record: also covers kit links found without a record
        linked=$((linked + 1)); continue
      fi
      if kit_item_owned "$dst"; then act "replace old kit link $(disp "$dst")" && rm -f "$dst"
      else say "  SKIP $kind/$name: $(disp "$dst") already exists and is not from the kit (left untouched)"; SKIPPED=$((SKIPPED + 1)); continue; fi
    elif [ -e "$dst" ]; then
      if oldh=$(old_copy_hash "$dst"); then
        h=$(copy_hash "$dst")
        if [ -n "$oldh" ] && [ "$h" = "$oldh" ]; then
          if ! can_symlink && [ "$h" = "$(copy_hash "$src")" ]; then linked=$((linked + 1)); continue; fi
          act "refresh kit copy $(disp "$dst")" && rm -rf "$dst"
        else
          keep_edited "$dst" "$p" "$kind/$name"
        fi
      else
        say "  SKIP $kind/$name: $(disp "$dst") already exists and is not from the kit (left untouched)"; SKIPPED=$((SKIPPED + 1)); continue
      fi
    fi
    if can_symlink; then
      rec_created link "$dst" "$target" ""
      if [ "$DRY" != 1 ]; then ln -s "$target" "$dst" || die "cannot link $dst"; fi
    else
      rec_created copy "$dst" "" "" "$(copy_hash "$src")"
      if [ "$DRY" != 1 ]; then cp -R "$src" "$dst" || die "cannot copy $dst"; fi
    fi
    made=$((made + 1))
  done
  if [ "$made" -gt 0 ]; then
    local verb=link done_verb=linked note=""
    can_symlink || { verb=copy; done_verb=copied; note=" (symlinks unavailable)"; }
    if [ "$DRY" = 1 ]; then say "  [dry-run] would $verb $made kit $kind into $(disp "$dir")/$note"
    else say "  $done_verb $made kit $kind into $(disp "$dir")/$note"; fi
  fi
  [ "$linked" -gt 0 ] && say "  $kind: $linked kit $kind already in place in $(disp "$dir")/"
  return 0
}

# ---------------------------------------------------------------- Cursor
install_cursor() {
  local cd="$CURSOR_DIR" f real bk="" marks frag src
  [ "$NO_CURSOR" = 1 ] && return 0
  [ -d "$cd" ] || return 0
  [ -f "$PAYLOAD/cursor/hooks.json" ] || return 0
  f="$cd/hooks.json"; real=$(realpath_of "$f")
  claim "file:$real" || return 0
  marks=$(cursor_marks)
  frag=$(jq -c --arg kh "$KH_CURSOR" "$JQ_LIB subst(\$kh) | .hooks" "$PAYLOAD/cursor/hooks.json")
  src="$real"; [ -s "$real" ] || { echo '{"version":1}' > "$WORK/cempty.json"; src="$WORK/cempty.json"; }
  if ! { jq -e 'type == "object" and ((.hooks // {}) | type) == "object"' "$src" >/dev/null 2>&1 \
         && jq --argjson m "$marks" --argjson f "$frag" "$JQ_LIB strip_flat(\$m; false) | add_hooks(\$f)" "$src" > "$WORK/cursor.new" 2>/dev/null; }; then
    say "  SKIP Cursor: $(disp "$real") is not hooks JSON the kit can merge into; left untouched (fix it and re-run to add the kit hooks)"
    SKIPPED=$((SKIPPED + 1)); return 0
  fi
  if [ -f "$real" ] && cmp -s "$WORK/cursor.new" "$real"; then record_original "$real" "" cursor; say "  Cursor: $(disp "$real") already up to date"; return 0; fi
  if [ -f "$real" ]; then bk=$(backup_file "$real") || die "cannot back up $(disp "$real"); stopped before editing it"; fi
  record_original "$real" "$bk" cursor
  if act "merge the kit Cursor hooks into $(disp "$real") (your Cursor hooks kept${bk:+; backup: $(disp "$bk")})"; then
    write_atomic "$real" "$WORK/cursor.new" || die "cannot write $real"
  fi
}

# ---------------------------------------------------------------- Shared mode
backup_name() { local b="$1.backup"; [ -e "$b" ] || [ -L "$b" ] && b="$1.backup.$TS"; printf '%s' "$b"; }

# primary_will_have <item>: the primary install creates these
primary_will_have() { case "$1" in CLAUDE.md|settings.json|skills|commands) return 0 ;; esac; return 1; }

# plan_relinks -> RELINK_COUNT (items that would be replaced), used for the running-session check
plan_relinks() {
  local s item src dst
  RELINK_COUNT=0
  while IFS= read -r s; do
    [ -n "$s" ] && [ "$s" != "$PRIMARY" ] || continue
    identity_conflict "$(realpath_of "$PRIMARY/settings.json")" "$(realpath_of "$s/settings.json")" >/dev/null && continue
    for item in $(share_items); do
      src="$PRIMARY/$item"; dst="$s/$item"
      [ -e "$src" ] || primary_will_have "$item" || continue
      if [ -e "$dst" ] && [ "$(realpath_of "$dst")" = "$(realpath_of "$src")" ]; then continue; fi
      if [ "$item" = CLAUDE.md ] && [ -f "$dst" ] && [ "$(cat "$dst")" = "@$(disp "$PRIMARY")/CLAUDE.md" ]; then continue; fi
      [ "$item" = settings.json ] && ! can_symlink && continue
      RELINK_COUNT=$((RELINK_COUNT + 1))
    done
  done <<EOF
$SELECTED
EOF
}

share_profile() { # secondary
  local s="$1" item src dst bk n
  say "Profile $(disp "$s") -> shares with primary $(disp "$PRIMARY") ($SHARE):"
  for item in $(share_items); do
    for n in $NEVER_SHARE; do [ "$item" = "$n" ] && die "internal error: identity item $item in share list"; done
    case "$item" in security*) die "internal error: identity item $item in share list" ;; esac
    src="$PRIMARY/$item"; dst="$s/$item"
    if [ ! -e "$src" ] && ! { [ "$DRY" = 1 ] && primary_will_have "$item"; }; then
      [ -e "$dst" ] && say "  $item: not present in the primary; $(disp "$s") keeps its own"
      continue
    fi
    if [ -e "$dst" ] && [ "$(realpath_of "$dst")" = "$(realpath_of "$src")" ]; then
      say "  $item: already shared"; continue
    fi
    if [ "$item" = CLAUDE.md ] && [ -f "$dst" ] && [ ! -L "$dst" ] && [ "$(cat "$dst")" = "@$(disp "$PRIMARY")/CLAUDE.md" ]; then
      say "  $item: already shared (import of the primary)"; continue
    fi
    if can_symlink; then
      bk=""
      if [ -e "$dst" ] || [ -L "$dst" ]; then bk=$(backup_name "$dst"); fi
      rec_created share-link "$dst" "$src" "$bk"
      if act "link $(disp "$dst") -> $(disp "$src")${bk:+ (original kept as $(disp "$bk"))}"; then
        if [ -n "$bk" ]; then mv "$dst" "$bk" || die "cannot move $dst"; fi
        ln -s "$src" "$dst" || { [ -n "$bk" ] && mv "$bk" "$dst"; die "cannot link $dst"; }
      fi
      continue
    fi
    # ---- Windows fallback: no native symlinks
    if [ -d "$src" ]; then
      bk=""
      if [ -e "$dst" ] || [ -L "$dst" ]; then bk=$(backup_name "$dst"); fi
      rec_created junction "$dst" "$src" "$bk"
      if act "junction $(disp "$dst") -> $(disp "$src")${bk:+ (original kept as $(disp "$bk"))}"; then
        if [ -n "$bk" ]; then mv "$dst" "$bk" || die "cannot move $dst"; fi
        make_junction "$src" "$dst" || { [ -n "$bk" ] && mv "$bk" "$dst"; die "cannot create a junction at $dst"; }
      fi
    elif [ "$item" = CLAUDE.md ]; then
      bk=""
      if [ -e "$dst" ] || [ -L "$dst" ]; then bk=$(backup_name "$dst"); fi
      printf '@%s/CLAUDE.md\n' "$(disp "$PRIMARY")" > "$WORK/import.md"
      rec_created import-file "$dst" "@$(disp "$PRIMARY")/CLAUDE.md" "$bk"
      if act "make $(disp "$dst") a one-line import of $(disp "$src")${bk:+ (original kept as $(disp "$bk"))}"; then
        if [ -n "$bk" ]; then mv "$dst" "$bk" || die "cannot move $dst"; fi
        cp "$WORK/import.md" "$dst" || die "cannot write $dst"
      fi
    elif [ "$item" = settings.json ]; then
      say "  settings.json: symlinks are unavailable, so $(disp "$s") gets its own merge instead of a shared file."
      say "    For true sharing enable Windows Developer Mode (Settings > System > For developers) and re-run."
      install_settings "$s"
    else
      say "  $item: cannot share a file without symlinks; $(disp "$s") keeps its own (enable Developer Mode to share it)"
    fi
  done
}

# ---------------------------------------------------------------- kit home
SENTINEL=".claude-kit-home"
is_kit_home() { # dir -> 0 when the kit created it (sentinel, or a pre-sentinel install)
  [ -f "$1/$SENTINEL" ] && return 0
  [ -f "$1/installer/setup-core.sh" ] && [ -f "$1/state/install.json" ]
}

# kh_safety: refuse a kit home that could destroy data it does not own
kh_safety() {
  local khr p pr
  khr=$(canon_real "$KH")
  { [ "$KH" = / ] || [ "$khr" = / ]; } && die "refusing to use / as the kit home. Nothing was changed."
  case "$(canon_cmp "$HOME_REAL")/" in "$khr/"*) die "the kit home $(disp "$KH") is your HOME or contains it; use a dedicated directory such as ~/.claude-kit. Nothing was changed." ;; esac
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    pr=$(canon_real "$p")
    case "$pr/" in "$khr/"*) die "the kit home $(disp "$KH") is or contains the profile $(disp "$p"); use a dedicated directory such as ~/.claude-kit. Nothing was changed." ;; esac
    case "$khr/" in "$pr/"*) die "the kit home $(disp "$KH") is inside the profile $(disp "$p"); use a dedicated directory such as ~/.claude-kit. Nothing was changed." ;; esac
  done <<EOF
$SELECTED
EOF
  if [ -e "$KH" ] || [ -L "$KH" ]; then
    [ -d "$KH" ] || die "$(disp "$KH") exists and is not a directory; refusing to use it as the kit home. Nothing was changed."
    is_kit_home "$KH" && return 0
    [ -z "$(ls -A "$KH" 2>/dev/null)" ] && return 0
    die "$(disp "$KH") exists, is not empty and was not created by claude-kit (no $SENTINEL marker); refusing to replace it. Choose another --kit-home or empty that directory. Nothing was changed."
  fi
}

# restore_leftover_kit_home: an interrupted swap leaves $KH.old.N holding the install record. Offer
# to put it back instead of starting a fresh manifest.
restore_leftover_kit_home() {
  local o found=""
  for o in "$KH".old.*; do
    [ -d "$o" ] && is_kit_home "$o" && [ -f "$o/state/install.json" ] && found="$o"
  done
  [ -n "$found" ] || return 0
  if [ -f "$MANIFEST" ]; then
    say "Note: an interrupted update left an older kit home at $(disp "$found"); $(disp "$KH") has its own install record, so it is used. Delete the old one when you no longer need it."
    return 0
  fi
  if [ -e "$KH" ] && ! { [ -d "$KH" ] && { [ -z "$(ls -A "$KH" 2>/dev/null)" ] || is_kit_home "$KH"; }; }; then
    die "an interrupted update left your previous kit home at $(disp "$found"), but $(disp "$KH") is now a different directory. Move $(disp "$KH") aside and re-run to restore it. Nothing was changed."
  fi
  if ask "An interrupted update left your previous kit home (with its install record) at $(disp "$found"). Restore it?" y; then
    act "restore the previous kit home from $(disp "$found")" || return 0
    if [ -d "$KH" ]; then
      if [ -z "$(ls -A "$KH" 2>/dev/null)" ]; then rmdir "$KH"; else mv "$KH" "$KH.partial.$TS" || die "cannot move $KH aside"; say "  kept the partial kit home as $(disp "$KH.partial.$TS")"; fi
    fi
    mv "$found" "$KH" || die "cannot restore $found to $KH"
    say "  restored the previous kit home from $(disp "$found")"
  else
    LEFTOVER_MANIFEST="$found/state/install.json"
    say "  not restoring it; its install record is merged into the new one (the old directory stays at $(disp "$found"); delete it when you no longer need it)"
  fi
}

install_kit_home() {
  local pr kr new old nested
  pr=$(realpath_of "$PAYLOAD"); kr=$(realpath_of "$KH")
  if [ "$pr" = "$kr" ]; then say "Kit home $(disp "$KH") (reconfiguring in place)"; return 0; fi
  act "install kit files ($KIT_VERSION) into $(disp "$KH")" || return 0
  mkdir -p "$(dirname "$KH")" || die "cannot create $(dirname "$KH")"
  new="$KH.new.$$"; old="$KH.old.$$"
  rm -rf "$new"; mkdir -p "$new" || die "cannot create $new"
  cp -R "$PAYLOAD/." "$new/" || { rm -rf "$new"; die "cannot copy the kit into $new"; }
  printf '%s\n' "$KIT_VERSION" > "$new/VERSION"
  printf 'claude-kit home: managed by claude-kit and replaced on every update.\nrun %s\n' "$TS" > "$new/$SENTINEL"
  chmod +x "$new/bin/claude-kit" "$new/installer/setup-core.sh" "$new"/hooks/*.sh "$new"/cursor/hooks/*.sh 2>/dev/null
  if [ -d "$KH/state" ]; then mv "$KH/state" "$new/state" || { rm -rf "$new"; die "cannot carry over $KH/state"; }; fi
  if [ -e "$KH" ]; then mv "$KH" "$old" || { [ -d "$new/state" ] && mv "$new/state" "$KH/state"; rm -rf "$new"; die "cannot replace $KH"; }; fi
  mv "$new" "$KH" || { [ -d "$new/state" ] && [ -e "$old" ] && mv "$new/state" "$old/state"; [ -e "$old" ] && mv "$old" "$KH"; rm -rf "$new"; die "cannot move the new kit into $KH"; }
  # Another process may have re-created $KH between the two renames; then mv nested the new kit inside it.
  nested="$KH/$(basename "$new")"
  if [ -e "$nested" ] || [ ! -f "$KH/installer/setup-core.sh" ] || ! grep -q "^run $TS\$" "$KH/$SENTINEL" 2>/dev/null; then
    if [ -d "$nested" ]; then
      [ -d "$nested/state" ] && [ -d "$old" ] && [ ! -e "$old/state" ] && mv "$nested/state" "$old/state"
      rm -rf "$nested"
    fi
    die "kit home swap failed: $(disp "$KH") was re-created by another process during the update. The previous kit (with your install record) is kept at $(disp "$old"); no profile was changed. To restore it: move the stray $(disp "$KH") aside and rename $(disp "$old") back to $(disp "$KH") - or simply remove the stray directory and re-run the installer, which offers to restore it."
  fi
  rm -rf "$old"
}

link_cli() {
  local d dst t
  CLI_HINT="Run the CLI as: \"$(home_form "$KH")/bin/claude-kit\" (or add $(home_form "$KH")/bin to your PATH)"
  [ "$NO_CLI" = 1 ] && return 0
  for d in ${BIN_DIR:+"$BIN_DIR"} "$HOME/.local/bin" "$HOME/bin"; do
    if [ -n "$BIN_DIR" ]; then [ "$d" = "$BIN_DIR" ] || continue   # an explicit --bin-dir is the only candidate
    else case ":$PATH:" in *":$d:"*) ;; *) continue ;; esac; fi
    [ -d "$d" ] || continue
    dst="$d/claude-kit"; t="$KH/bin/claude-kit"
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$t" ]; then CLI_HINT=""; return 0; fi
    [ -w "$d" ] || { say "  SKIP $(disp "$dst"): $(disp "$d") is not writable"; continue; }
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      kit_item_owned "$dst" || { say "  SKIP $(disp "$dst"): exists and is not from the kit"; continue; }
      act "replace old kit link $(disp "$dst")" && rm -f "$dst"
    fi
    rec_created link "$dst" "$t" ""
    if act "link $(disp "$dst") -> $(disp "$t")"; then
      ln -s "$t" "$dst" 2>/dev/null || { warn "could not link $(disp "$dst")"; continue; }
    fi
    CLI_HINT=""; return 0
  done
}

# ---------------------------------------------------------------- install
preflight() {
  local p real kh_parent kind d
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in *"$NL"*) die "profile paths must not contain newlines" ;; esac
    if [ -d "$p" ]; then [ -w "$p" ] || die "no write permission to $(disp "$p"). Nothing was changed."
    else
      [ -e "$p" ] && die "$(disp "$p") exists but is not a directory. Nothing was changed."
      kh_parent=$(dirname "$p"); while [ ! -d "$kh_parent" ]; do kh_parent=$(dirname "$kh_parent"); done
      [ -w "$kh_parent" ] || die "cannot create $(disp "$p") (no write permission). Nothing was changed."
    fi
    real=$(realpath_of "$p/settings.json"); validate_settings "$real"
    if [ -s "$real" ]; then
      merge_settings_to "$real" "$WORK/preflight.json" \
        || die "the kit hooks cannot be merged into $(disp "$real"): its \"hooks\" layout is not the one Claude Code uses (each event must be a list). Fix it and re-run. Nothing was changed."
      [ -w "$(dirname "$real")" ] || die "no write permission to $(disp "$(dirname "$real")"). Nothing was changed."
    fi
    real=$(realpath_of "$p/CLAUDE.md")
    [ "$(block_state "$real")" = broken ] && die "$(disp "$real") has a broken claude-kit block (begin/end markers). Fix it and re-run. Nothing was changed."
    [ -f "$real" ] && { [ -w "$(dirname "$real")" ] || die "no write permission to $(disp "$(dirname "$real")"). Nothing was changed."; }
    for d in "$p" "$(dirname "$(realpath_of "$p/settings.json")")" "$(dirname "$(realpath_of "$p/CLAUDE.md")")"; do
      check_backup_dir "$d"
    done
    for kind in skills commands; do
      d="$p/$kind"
      if [ -d "$d" ]; then [ -w "$(realpath_of "$d")" ] || die "no write permission to $(disp "$d"). Nothing was changed."
      fi
    done
  done <<EOF
$SELECTED
EOF
  local why
  if [ -n "$CURSOR_DIR_ARG" ] && [ "$NO_CURSOR" != 1 ]; then
    why=$(dir_guard "$CURSOR_DIR" "$SELECTED") || die "refusing --cursor-dir $(disp "$CURSOR_DIR"): $why. Nothing was changed."
  fi
  if [ -n "$BIN_DIR" ] && [ "$NO_CLI" != 1 ]; then
    why=$(dir_guard "$BIN_DIR" "$SELECTED") || die "refusing --bin-dir $(disp "$BIN_DIR"): $why. Nothing was changed."
  fi
  if [ -n "$CURSOR_DIR_ARG" ] && [ "$NO_CURSOR" != 1 ] && [ ! -d "$CURSOR_DIR" ]; then
    die "--cursor-dir $(disp "$CURSOR_DIR") does not exist. Nothing was changed."
  fi
  if [ -n "$BIN_DIR" ] && [ "$NO_CLI" != 1 ] && [ ! -d "$BIN_DIR" ]; then
    die "--bin-dir $(disp "$BIN_DIR") does not exist. Nothing was changed."
  fi
  if [ "$NO_CURSOR" != 1 ] && [ -d "$CURSOR_DIR" ] && [ -f "$PAYLOAD/cursor/hooks.json" ]; then
    [ -w "$CURSOR_DIR" ] || die "no write permission to $(disp "$CURSOR_DIR") (the kit merges its Cursor hooks there; --no-cursor skips Cursor). Nothing was changed."
    check_backup_dir "$CURSOR_DIR"
    d=$(dirname "$(realpath_of "$CURSOR_DIR/hooks.json")")    # the target of a dotfiles symlink
    if [ "$d" != "$(realpath_of "$CURSOR_DIR")" ]; then
      why=$(hooks_target_guard "$(realpath_of "$CURSOR_DIR/hooks.json")" "$SELECTED") || die "refusing: $(disp "$CURSOR_DIR/hooks.json") points to $(disp "$(realpath_of "$CURSOR_DIR/hooks.json")"), and $why. Nothing was changed. (--no-cursor skips Cursor.)"
      [ -w "$d" ] || die "no write permission to $(disp "$d") (where ~/.cursor/hooks.json points). Nothing was changed."
      check_backup_dir "$d"
    fi
  fi
  kh_safety
  kh_parent=$(dirname "$KH"); while [ ! -d "$kh_parent" ]; do kh_parent=$(dirname "$kh_parent"); done
  [ -w "$kh_parent" ] || die "no write permission for the kit home $(disp "$KH"). Nothing was changed."
  [ -f "$PAYLOAD/hooks/settings.fragment.json" ] || die "payload incomplete: hooks/settings.fragment.json missing ($PAYLOAD)"
  if [ "$MODE" = shared ]; then
    local pr sr
    pr=$(realpath_of "$PRIMARY")
    while IFS= read -r p; do
      [ -n "$p" ] && [ "$p" != "$PRIMARY" ] || continue
      sr=$(realpath_of "$p")
      [ "$sr" = "$pr" ] && die "$(disp "$p") is the primary itself (same directory via a symlink); refusing to link it to itself. Nothing was changed."
      case "$sr/" in "$pr/"*) die "$(disp "$p") is inside the primary $(disp "$PRIMARY"); refusing (symlink loop). Nothing was changed." ;; esac
      case "$pr/" in "$sr/"*) die "the primary $(disp "$PRIMARY") is inside $(disp "$p"); refusing (symlink loop). Nothing was changed." ;; esac
    done <<EOF
$SELECTED
EOF
  fi
}

check_backup_dir() { # dir: its .claude-kit-backups must be creatable / writable
  local b="$1/.claude-kit-backups"
  if [ -e "$b" ] || [ -L "$b" ]; then
    [ -d "$b" ] || die "$(disp "$b") exists but is not a directory, so the kit cannot keep backups there. Move it aside and re-run. Nothing was changed."
    [ -w "$b" ] || die "$(disp "$b") is not writable, so the kit cannot keep backups there. Fix its permissions and re-run. Nothing was changed."
  fi
}

mk_profile_dir() { # dir
  [ -d "$1" ] && return 0
  rec_created dir "$1" "" ""
  act "create $(disp "$1")/" && { mkdir -p "$1" || die "cannot create $1"; }
}

do_install() {
  local p n keys
  [ -n "$PROFILE_ARGS" ] || [ "$ALL" = 1 ] || [ "$TTY_OK" = 1 ] || { usage >&2; die "no terminal for the menu: pass --profile <dir> or --all (see above). Nothing was changed." 2; }
  ensure_jq
  detect_profiles
  say "claude-kit $KIT_VERSION installer"
  if [ -n "$PROFILES" ]; then say "Claude Code profiles found:"; print_profiles; else say "No Claude Code profile found."; fi
  select_profiles
  select_mode
  preflight
  n=$(count_lines "$SELECTED")
  say ""
  say "Plan: mode=$MODE${PRIMARY:+, primary=$(disp "$PRIMARY")}${SHARE:+, share=$SHARE}, kit home=$(disp "$KH")$( [ "$DRY" = 1 ] && echo ', DRY RUN')"
  while IFS= read -r p; do say "  - $(disp "$p")"; done <<EOF
$SELECTED
EOF
  if [ "$MODE" = shared ]; then
    plan_relinks
    if [ "$RELINK_COUNT" -gt 0 ] && claude_running; then
      warn "Claude Code appears to be running. Replacing shared files under a running session can confuse it; close it first."
      if [ "$DRY" != 1 ]; then ask "Continue anyway?" n || die "stopped before relinking; nothing was changed. Close Claude Code and re-run (or pass --yes)."; fi
    fi
  fi
  if [ "$TTY_OK" = 1 ] && [ "$YES" != 1 ] && [ "$DRY" != 1 ]; then
    ask "Apply these changes?" y || die "cancelled; nothing changed"
  fi
  say ""
  SKIPPED=0
  restore_leftover_kit_home
  install_kit_home
  journal_start
  if [ "$MODE" = shared ]; then
    say "Primary $(disp "$PRIMARY"):"
    mk_profile_dir "$PRIMARY"
    install_claude_md "$PRIMARY"; install_settings "$PRIMARY"
    link_kit_items "$PRIMARY" skills; link_kit_items "$PRIMARY" commands
    while IFS= read -r p; do
      [ -n "$p" ] && [ "$p" != "$PRIMARY" ] || continue
      mk_profile_dir "$p"
      if keys=$(identity_conflict "$(realpath_of "$PRIMARY/settings.json")" "$(realpath_of "$p/settings.json")"); then
        say "Profile $(disp "$p"): installed in Independent mode instead of sharing, because its settings.json identity/provider keys are not identical to the primary's ($keys); none of its items are linked to the primary."
        install_claude_md "$p"; install_settings "$p"
        link_kit_items "$p" skills; link_kit_items "$p" commands
        continue
      fi
      share_profile "$p"
    done <<EOF
$SELECTED
EOF
  else
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      say "Profile $(disp "$p"):"
      mk_profile_dir "$p"
      install_claude_md "$p"; install_settings "$p"
      link_kit_items "$p" skills; link_kit_items "$p" commands
    done <<EOF
$SELECTED
EOF
  fi
  install_cursor
  link_cli
  if [ "$DRY" = 1 ]; then
    say ""; say "Dry run: nothing was changed."; return 0
  fi
  fold_journal || die "the install finished but the manifest could not be written; the journal $(disp "$JOURNAL") keeps the record"
  JOURNAL=""
  say ""
  say "Done. claude-kit $KIT_VERSION is installed ($MODE mode, $n profile(s)). Start a new Claude Code session to load it."
  [ "$SKIPPED" -gt 0 ] && say "$SKIPPED item(s) were skipped because your own files use the same name (see SKIP lines above)."
  [ -n "$CLI_HINT" ] && say "$CLI_HINT"
  return 0
}

# ---------------------------------------------------------------- uninstall
# Manifest entries are only acted on under a recorded profile, the kit home, ~/.cursor or the CLI link dirs.
bad_root() { # real path -> 0 when it must never be an allowed root (/, HOME, or above HOME)
  [ -z "$1" ] || [ "$1" = / ] && return 0
  case "$HOME_REAL/" in "$1/"*) return 0 ;; esac
  return 1
}
has_dot_segment() { case "$1/" in */../*|*/./*) return 0 ;; esac; return 1; }
build_allowed() { # -> ALLOWED (general real roots), BIN_REALS, CURSOR_REAL, $WORK/profiles.ok (filtered)
  local p r d
  ALLOWED=""; : > "$WORK/profiles.ok"
  r=$(realpath_of "$KH"); bad_root "$r" || ALLOWED=$(add_line "$ALLOWED" "$r")
  # Cursor and CLI dirs come from install.json (what the install really used), never from flags; the
  # defaults stay allowed for records written before these fields existed. Only the roles below apply
  # there (a claude-kit link pointing into the kit home; the hooks.json the kit merged and its backups).
  local cdirs bdirs cd
  cdirs=$(jq -r '(.cursor_dirs // [])[] | select(type == "string" and (test("\n") | not))' "$MANIFEST" 2>/dev/null)
  bdirs=$(jq -r '(.bin_dirs // [])[] | select(type == "string" and (test("\n") | not))' "$MANIFEST" 2>/dev/null)
  BIN_REALS=""
  while IFS= read -r d; do [ -n "$d" ] && BIN_REALS=$(add_line "$BIN_REALS" "$(realpath_of "$d")"); done <<EOF
$(printf '%s\n%s\n%s' "$bdirs" "$HOME/.local/bin" "$HOME/bin")
EOF
  CURSOR_REALS=""; CURSOR_HOOKS_REALS=""
  while IFS= read -r cd; do
    [ -n "$cd" ] || continue
    CURSOR_REALS=$(add_line "$CURSOR_REALS" "$(realpath_of "$cd")")
    CURSOR_HOOKS_REALS=$(add_line "$CURSOR_HOOKS_REALS" "$(realpath_of "$cd/hooks.json")")   # a dotfiles symlink resolves elsewhere
  done <<EOF
$(printf '%s\n%s' "$cdirs" "$HOME/.cursor")
EOF
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in /*) ;; *) say "  SKIP recorded profile $p: not an absolute path"; continue ;; esac
    has_dot_segment "$p" && { say "  SKIP recorded profile $p: contains . or .. segments"; continue; }
    r=$(realpath_of "$p")
    bad_root "$r" && { say "  SKIP recorded profile $(disp "$p"): it is /, HOME or contains HOME, so it is never treated as a profile"; continue; }
    printf '%s\n' "$p" >> "$WORK/profiles.ok"
    ALLOWED=$(add_line "$ALLOWED" "$r")
    for d in "$(dirname "$(realpath_of "$p/CLAUDE.md")")" "$(dirname "$(realpath_of "$p/settings.json")")"; do
      bad_root "$d" || ALLOWED=$(add_line "$ALLOWED" "$d")
    done
  done < "$WORK/profiles.txt"
}
real_of_entry() { # path -> real parent + name (the entry itself is not followed); 1 when unusable
  local x="$1" dr
  case "$x" in /*) ;; *) return 1 ;; esac
  has_dot_segment "$x" && return 1
  dr=$(realpath_of "$(dirname "$x")") || return 1
  printf '%s/%s' "${dr%/}" "$(basename "$x")"
}
# path_ok <path> [role]: general = under the kit home or a filtered recorded profile (real paths only);
#   cli-link = the claude-kit link in ~/.local/bin or ~/bin; cursor = ~/.cursor/hooks.json;
#   cursor-backup = inside ~/.cursor/.claude-kit-backups/
path_ok() {
  local r a
  r=$(real_of_entry "$1") || return 1
  case "${2:-general}" in
    cli-link)
      [ "$(basename "$r")" = claude-kit ] || return 1
      while IFS= read -r a; do [ -n "$a" ] && [ "$(dirname "$r")" = "$a" ] && return 0; done <<EOF
$BIN_REALS
EOF
      return 1 ;;
    cursor)
      while IFS= read -r a; do [ -n "$a" ] && [ "$r" = "$a/hooks.json" ] && return 0; done <<EOF
$CURSOR_REALS
EOF
      while IFS= read -r a; do [ -n "$a" ] && [ "$r" = "$a" ] && return 0; done <<EOF
$CURSOR_HOOKS_REALS
EOF
      return 1 ;;
    cursor-backup)
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        case "$r" in "$a/.claude-kit-backups/"*) return 0 ;; esac
      done <<EOF
$CURSOR_REALS
$(printf '%s\n' "$CURSOR_HOOKS_REALS" | while IFS= read -r x; do [ -n "$x" ] && dirname "$x"; done)
EOF
      return 1 ;;
  esac
  while IFS= read -r a; do
    [ -n "$a" ] && [ "$a" != / ] || continue
    case "$r/" in "$a/"*) return 0 ;; esac
  done <<EOF
$ALLOWED
EOF
  return 1
}
refuse_path() { say "  SKIP $(disp "$1"): outside every recorded profile and the kit home; manifest entry ignored"; }

restore_backup() { # path backup
  [ -n "$2" ] || return 0
  path_ok "$2" || { refuse_path "$2"; return 0; }   # a share-link / junction / import backup
  if [ ! -e "$2" ] && [ ! -L "$2" ]; then say "  backup $(disp "$2") is gone; nothing to restore"; return 0; fi
  if [ -e "$1" ] || [ -L "$1" ]; then say "  kept $(disp "$2"): $(disp "$1") exists again"; return 0; fi
  if ask "Restore $(disp "$2") -> $(disp "$1")?" y; then
    act "restore $(disp "$1") from $(disp "$2")" && mv "$2" "$1"
  else
    say "  left $(disp "$2") in place"
  fi
}

# unmerge_original <path> <backup> <kind> [strip-only]
#   Removes the kit content. When the result equals the pre-install original, the original BYTES are
#   restored; when the kit created the file and nothing else is left, the file is removed. Only hook
#   containers the kit added are pruned (empty containers the user had stay).
unmerge_original() {
  local f="$1" bk="$2" kind="$3" only="${4:-}" m cur orig prog chk ofile
  [ -f "$f" ] || return 0
  case "$kind" in
    claude-md)
      [ "$(block_state "$f")" = ok ] || return 0
      claude_md_strip "$f" "$WORK/u.out"
      if [ -n "$only" ]; then
        act "remove the claude-kit block from $(disp "$f")" && write_atomic "$f" "$WORK/u.out"
      elif [ -n "$bk" ] && [ -f "$bk" ] && [ "$(block_state "$bk")" = none ] && \
         { cmp -s "$WORK/u.out" "$bk" || { cp "$bk" "$WORK/u.bk"; ends_with_newline "$WORK/u.bk" || { has_crlf "$bk" && printf '\r'; printf '\n'; } >> "$WORK/u.bk"; cmp -s "$WORK/u.out" "$WORK/u.bk"; }; }; then
        act "restore $(disp "$f") (original bytes)" && write_atomic "$f" "$bk"
      elif [ -z "$bk" ] && [ -z "$(tr -d '\r\n' < "$WORK/u.out")" ]; then
        act "remove $(disp "$f") (the kit created it)" && rm -f "$f"
      else
        act "remove the claude-kit block from $(disp "$f")" && write_atomic "$f" "$WORK/u.out"
      fi ;;
    settings|cursor)
      if [ "$kind" = settings ]; then m=$(settings_marks); prog="strip_groups(\$m; false)"; chk="has_kit_groups(\$m)"
      else m=$(cursor_marks); prog="strip_flat(\$m; false)"; chk="has_kit_flat(\$m)"; fi
      jq -e . "$f" >/dev/null 2>&1 || { warn "$(disp "$f") is not valid JSON; left as is (remove the claude-kit hook entries by hand)"; return 0; }
      jq -e --argjson m "$m" "$JQ_LIB $chk" "$f" >/dev/null 2>&1 || return 0
      # the original the kit started from: the backup, {} when the kit created the file, the file itself for strip-only
      ofile="$WORK/u.orig"
      if [ -n "$only" ]; then cp "$f" "$ofile"
      elif [ -n "$bk" ] && [ -f "$bk" ] && [ -s "$bk" ] && jq -e 'type == "object"' "$bk" >/dev/null 2>&1; then cp "$bk" "$ofile"
      else echo '{}' > "$ofile"; fi
      jq --argjson m "$m" --slurpfile o "$ofile" "$JQ_LIB $prog | prune_added(\$o[0])" "$f" > "$WORK/u.json" || return 0
      cur=$(jq -cS . "$WORK/u.json")
      orig=""
      if [ -n "$bk" ] && [ -f "$bk" ] && ! jq -e --argjson m "$m" "$JQ_LIB $chk" "$bk" >/dev/null 2>&1; then
        if [ -s "$bk" ]; then orig=$(jq -cS . "$bk" 2>/dev/null); else orig='{}'; fi
      fi
      if [ -n "$only" ]; then
        act "remove the claude-kit hook entries from $(disp "$f")" && write_atomic "$f" "$WORK/u.json"
      elif [ -n "$orig" ] && [ "$cur" = "$orig" ]; then
        act "restore $(disp "$f") (original bytes)" && write_atomic "$f" "$bk"
      elif [ -z "$bk" ] && { [ "$cur" = '{}' ] || { [ "$kind" = cursor ] && [ "$cur" = '{"version":1}' ]; }; }; then
        act "remove $(disp "$f") (the kit created it)" && rm -f "$f"
      else
        act "remove the claude-kit hook entries from $(disp "$f")" && write_atomic "$f" "$WORK/u.json"
      fi ;;
  esac
}

# owner_profile <path> -> the recorded profile that contains it (for backups of edited copies)
owner_profile() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$1" in "$p"/*) printf '%s' "$p"; return 0 ;; esac
  done < "$WORK/profiles.ok"
  dirname "$(dirname "$1")"
}

do_uninstall() {
  ensure_jq
  if [ -f "$KH/state/journal.jsonl" ] && [ "$DRY" != 1 ]; then
    say "Folding the journal of an unfinished run into the manifest first."
    fold_journal || die "cannot read $(disp "$KH/state/journal.jsonl"). Nothing was changed."
  fi
  [ -f "$MANIFEST" ] || die "no claude-kit install found ($(disp "$MANIFEST") is missing). Nothing was changed."
  jq -e . "$MANIFEST" >/dev/null 2>&1 || die "$(disp "$MANIFEST") is not valid JSON. Nothing was changed."
  local n t p g b k h NOTNL NOTNLREC why rprofiles
  # recorded Cursor / CLI dirs are checked before anything is touched: a tampered record must not
  # aim the uninstall at /, a system dir, HOME, a profile or the kit home
  rprofiles=$(jq -r '.profiles[]? | select(type == "string" and (test("\n") | not))' "$MANIFEST")
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    why=$(dir_guard "$p" "$rprofiles") || die "refusing to uninstall: $(disp "$MANIFEST") records the Cursor/CLI directory $(disp "$p"), and $why. Fix or remove that entry. Nothing was changed."
  done <<EOF
$(jq -r '[(.cursor_dirs // [])[], (.bin_dirs // [])[], (.cursor_dir // ""), (.bin_dir // "")] | .[] | select(type == "string" and . != "" and (test("\n") | not))' "$MANIFEST")
EOF
  # the files the kit merges Cursor hooks into: each recorded Cursor dir's hooks.json target, and every
  # recorded Cursor original - their directories must pass the same guard
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    why=$(hooks_target_guard "$p" "$rprofiles") || die "refusing to uninstall: $(disp "$MANIFEST") makes the kit edit the Cursor hooks file $(disp "$p"), and $why. Fix or remove that entry. Nothing was changed."
  done <<EOF
$(jq -r '[(.originals // [])[] | select(.kind == "cursor") | .path] | .[] | select(type == "string" and . != "" and (test("\n") | not))' "$MANIFEST")
$(jq -r '[(.cursor_dirs // [])[], (.cursor_dir // "")] | .[] | select(type == "string" and . != "" and (test("\n") | not))' "$MANIFEST" | while IFS= read -r c; do [ -e "$c/hooks.json" ] && realpath_of "$c/hooks.json" && echo; done)
EOF
  # Entries whose paths contain a newline would be split into several paths: never use them.
  NOTNL='select(type == "string" and (test("\n") | not))'
  jq -r ".profiles[]? | $NOTNL" "$MANIFEST" > "$WORK/profiles.txt"
  k=$(jq '[(.profiles[]?), ((.created // [])[] | .path, .target, .backup), ((.originals // [])[] | .path, .backup)] | map(select(type == "string" and test("\n"))) | length' "$MANIFEST")
  [ "${k:-0}" -gt 0 ] && say "  SKIP $k manifest path(s) containing a newline (ignored)"
  n=$(wc -l < "$WORK/profiles.txt" | tr -d ' ')
  say "claude-kit uninstall: $n profile(s), kit home $(disp "$KH")$( [ "$DRY" = 1 ] && echo ' (DRY RUN)')"
  while IFS= read -r p; do say "  - $(disp "$p")"; done < "$WORK/profiles.txt"
  if [ "$DRY" != 1 ] && [ "$YES" != 1 ]; then
    [ "$TTY_OK" = 1 ] || die "no terminal to confirm: pass --yes to uninstall. Nothing was changed." 2
    ask "Remove claude-kit (managed blocks, kit hooks, kit links) from these profiles?" n || die "cancelled; nothing changed"
  fi
  build_allowed
  # 1. links / copies / share links / import files (newest first; one record per path)
  NOTNLREC='select(([.path, .target, .backup, .hash] | map(select(type == "string" and test("\n"))) | length) == 0) | select((.path | type) == "string")'
  jq -r "(.created // []) | reverse | .[] | $NOTNLREC | select(.type != \"dir\") | [.type, .path, (.target // \"\"), (.backup // \"\"), (.hash // \"\")] | join(\"\\u001f\")" "$MANIFEST" > "$WORK/created.tsv"
  while IFS="$US" read -r t p g b h; do
    [ -n "$p" ] || continue
    if ! path_ok "$p"; then
      if [ "$t" = link ] && path_ok "$p" cli-link; then :; else refuse_path "$p"; continue; fi
    fi
    case "$t" in
      link|copy)
        if [ -L "$p" ]; then
          if [ "$(readlink "$p")" = "$g" ] || kit_item_owned "$p"; then act "remove kit link $(disp "$p")" && rm -f "$p"; fi
        elif [ "$t" = copy ] && [ -e "$p" ]; then
          if [ -n "$h" ] && [ "$(copy_hash "$p")" = "$h" ]; then act "remove kit copy $(disp "$p")" && rm -rf "$p"
          else keep_edited "$p" "$(owner_profile "$p")" "$(basename "$(dirname "$p")")/$(basename "$p")"; fi
        fi ;;
      share-link)
        if [ -L "$p" ] && [ "$(readlink "$p")" = "$g" ]; then act "remove shared link $(disp "$p")" && rm -f "$p"; restore_backup "$p" "$b"; fi ;;
      junction)
        if [ -L "$p" ] || [ -d "$p" ]; then act "remove junction $(disp "$p")" && remove_junction "$p"; restore_backup "$p" "$b"; fi ;;
      import-file)
        if [ -f "$p" ] && [ "$(cat "$p")" = "$g" ]; then act "remove import file $(disp "$p")" && rm -f "$p"; restore_backup "$p" "$b"; fi ;;
    esac
  done < "$WORK/created.tsv"
  # 2. files the kit merged into
  jq -r "(.originals // []) | .[] | $NOTNLREC | [.path, (.backup // \"\"), (.kind // \"\")] | join(\"\\u001f\")" "$MANIFEST" > "$WORK/orig.tsv"
  while IFS="$US" read -r p b k; do
    [ -n "$p" ] || continue
    if [ "$k" = cursor ]; then
      path_ok "$p" cursor || { refuse_path "$p"; continue; }
      [ -z "$b" ] || path_ok "$b" cursor-backup || b=""
    else
      path_ok "$p" || { refuse_path "$p"; continue; }
      [ -z "$b" ] || path_ok "$b" || b=""
    fi
    unmerge_original "$p" "$b" "$k"
  done < "$WORK/orig.tsv"
  # 3. kit content left in profile files the manifest did not record (e.g. restored backups)
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    [ -L "$p/CLAUDE.md" ] || unmerge_original "$p/CLAUDE.md" "" claude-md only
    [ -L "$p/settings.json" ] || unmerge_original "$p/settings.json" "" settings only
  done < "$WORK/profiles.ok"
  # 4. directories the kit created (only when empty), deepest first
  jq -r "(.created // []) | map($NOTNLREC | select(.type == \"dir\")) | sort_by(.path | length) | reverse | .[].path" "$MANIFEST" > "$WORK/dirs.txt"
  while IFS= read -r p; do
    [ -n "$p" ] && [ -d "$p" ] || continue
    path_ok "$p" || { refuse_path "$p"; continue; }
    if [ -z "$(ls -A "$p" 2>/dev/null)" ]; then act "remove empty $(disp "$p")/" && rmdir "$p"; else say "  kept $(disp "$p")/ (not empty)"; fi
  done < "$WORK/dirs.txt"
  # 5. the kit home itself, last - only a directory the kit created, never HOME or above it
  case "$HOME_REAL/" in "$(realpath_of "$KH")/"*) die "refusing to remove $(disp "$KH"): it is HOME or contains it" ;; esac
  if is_kit_home "$KH"; then
    act "remove the kit home $(disp "$KH")" && rm -rf "$KH"
  else
    say "  kept $(disp "$KH"): no $SENTINEL marker, so it was not created by claude-kit"
  fi
  [ "$DRY" = 1 ] && { say "Dry run: nothing was changed."; return 0; }
  say "claude-kit was removed. Backups made by the kit stay in each profile's .claude-kit-backups/ (safe to delete)."
}

# ---------------------------------------------------------------- status / doctor
do_status() {
  if [ ! -f "$MANIFEST" ]; then say "claude-kit: not installed (no $(disp "$MANIFEST"))"; return 1; fi
  command -v jq >/dev/null 2>&1 || die "jq is required"
  say "claude-kit $(cat "$KH/VERSION" 2>/dev/null || jq -r .version "$MANIFEST")"
  say "kit home: $(disp "$KH")"
  if [ "$(jq -r .mode "$MANIFEST")" = shared ]; then
    say "mode: shared (primary $(disp "$(jq -r .primary "$MANIFEST")"), share $(jq -r .share "$MANIFEST"))"
  else
    say "mode: $(jq -r .mode "$MANIFEST")"
  fi
  say "profiles:"
  jq -r '.profiles[]' "$MANIFEST" | while IFS= read -r p; do
    local st="installed"
    if [ -L "$p/CLAUDE.md" ]; then st="shared (CLAUDE.md -> $(disp "$(readlink "$p/CLAUDE.md")"))"
    elif [ "$(block_state "$p/CLAUDE.md")" != ok ]; then
      if [ -f "$p/CLAUDE.md" ] && grep -q '^@.*CLAUDE.md$' "$p/CLAUDE.md"; then st="shared (CLAUDE.md import)"; else st="CLAUDE.md block missing"; fi
    fi
    say "  $(disp "$p"): $st"
  done
  say "updated: $(jq -r .updated_at "$MANIFEST")"
}

char_count() {
  local n; n=$(wc -c < "$1" | tr -d ' ')
  if [ "$n" -gt "$RULE_CAP" ]; then
    local c; c=$(LC_ALL=en_US.UTF-8 wc -m < "$1" 2>/dev/null | tr -d ' ')
    [ -n "$c" ] && [ "$c" -lt "$n" ] && n="$c"
  fi
  printf '%s' "$n"
}

do_doctor() {
  local problems=0 p f real cmds c path ok n t g
  prob() { problems=$((problems + 1)); say "  FAIL $1"; [ -n "${2:-}" ] && say "       fix: $2"; }
  okk() { say "  ok   $1"; }
  say "claude-kit doctor ($(disp "$KH"))"
  okk "bash $BASH_VERSION"
  if command -v jq >/dev/null 2>&1; then okk "jq $(jq --version 2>/dev/null)"; else prob "jq missing" "$(jq_install_cmd || true)"; say "  (stopping: the remaining checks need jq)"; return 1; fi
  if [ ! -f "$MANIFEST" ]; then prob "no install manifest at $(disp "$MANIFEST")" "run the installer"; return 1; fi
  for f in "$KH"/hooks/*.sh; do [ -f "$f" ] || { prob "kit hooks missing in $(disp "$KH")/hooks" "re-run the installer"; break; }; done
  for f in "$KH"/rules/*.md; do
    [ -f "$f" ] || continue
    n=$(char_count "$f")
    if [ "$n" -le "$RULE_CAP" ]; then okk "rules/$(basename "$f") $n chars (cap $RULE_CAP)"; else prob "rules/$(basename "$f") is $n chars, over the $RULE_CAP cap (hook output is truncated past 10000)" "the kit home is managed and replaced on every update, so do not edit it: run claude-kit update to restore the shipped rules, and put your own additions in your own CLAUDE.md (outside the claude-kit block)"; fi
  done
  jq -r '.profiles[]' "$MANIFEST" > "$WORK/dp.txt"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    say " profile $(disp "$p")"
    [ -d "$p" ] || { prob "profile dir missing" "re-run the installer or claude-kit uninstall"; continue; }
    real=$(realpath_of "$p/settings.json")
    if [ ! -f "$real" ]; then prob "settings.json missing" "re-run the installer"
    elif ! jq -e . "$real" >/dev/null 2>&1; then prob "settings.json is not valid JSON ($(disp "$real"))" "fix the JSON syntax"
    else
      okk "settings.json valid JSON"
      cmds=$(jq -r --argjson m "$(settings_marks)" "$JQ_LIB [.hooks? // {} | .[]? | arrays | .[] | objects | .hooks? | arrays | .[] | select(iskit(\$m)) | .command] | .[]" "$real")
      n=0; ok=1
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        n=$((n + 1))
        path=$(printf '%s' "$c" | sed -E 's/^bash "([^"]*)".*/\1/')
        case "$path" in '$HOME'/*) path="$HOME/${path#\$HOME/}" ;; esac
        [ -f "$path" ] || { ok=0; prob "hook path does not resolve: $c" "re-run the installer (claude-kit update)"; }
      done <<EOF
$cmds
EOF
      want=$(jq '[.. | objects | select(has("command"))] | length' "$PAYLOAD/hooks/settings.fragment.json" 2>/dev/null || echo 0)
      [ "$n" -ge "$want" ] && [ "$ok" = 1 ] && okk "$n kit hooks registered and resolving"
      [ "$n" -lt "$want" ] && prob "only $n of $want kit hooks registered" "re-run the installer (claude-kit update)"
    fi
    f="$p/CLAUDE.md"
    if [ "$(block_state "$f")" = ok ] && grep -q '/rules/core.md' "$f"; then okk "CLAUDE.md block present"
    elif [ -f "$f" ] && grep -q '^@.*CLAUDE.md$' "$f"; then okk "CLAUDE.md imports $(grep -m1 '^@' "$f")"
    else prob "CLAUDE.md claude-kit block missing ($(disp "$f"))" "re-run the installer"; fi
  done < "$WORK/dp.txt"
  jq -r '(.created // [])[] | [.type, .path, (.target // "")] | join("\u001f")' "$MANIFEST" > "$WORK/dc.tsv"
  while IFS="$US" read -r t p g; do
    case "$t" in
      link|share-link)
        if [ ! -L "$p" ]; then prob "$(disp "$p") is no longer a link" "move it aside and re-run the installer"
        elif [ ! -e "$p" ]; then prob "$(disp "$p") is a broken link (target $(disp "$g") missing)" "re-run the installer"
        elif [ "$t" = share-link ]; then okk "shared link $(disp "$p")"; fi ;;
      junction) { [ -L "$p" ] || [ -d "$p" ]; } && okk "junction $(disp "$p")" || prob "junction $(disp "$p") missing" "re-run the installer" ;;
      copy) [ -e "$p" ] || prob "kit copy $(disp "$p") missing" "re-run the installer" ;;
    esac
  done < "$WORK/dc.tsv"
  if [ "$problems" -eq 0 ]; then say "doctor: all checks passed"; return 0; fi
  say "doctor: $problems problem(s) found"; return 1
}

do_list() {
  local p
  detect_profiles
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\t%s\n' "$p" "$(disp "$p")$(share_text "$p")"
  done <<EOF
$PROFILES
EOF
}

# ---------------------------------------------------------------- main
[ -n "${CLAUDE_KIT_LIB_ONLY:-}" ] && return 0 2>/dev/null

main() {
  parse_args "$@"
  setup_tty
  setup_paths
  case "$ACTION" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    list) do_list ;;
    status) do_status ;;
    doctor) do_doctor ;;
  esac
}
main "$@"

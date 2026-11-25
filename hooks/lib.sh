#!/bin/bash
# claude-kit shared helpers. Sourced by every hook. Bash 3.2 compatible (macOS /bin/bash).
# Never prints anything by itself.

KIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${KIT_ROOT:=$(cd "$KIT_LIB_DIR/.." && pwd)}"

KIT_CAP=10000

kit_has_jq() { command -v jq >/dev/null 2>&1; }

# kit_json_get <json> <dotted.path>  -> value on stdout (empty when absent / null / not scalar)
# jq path is exact. The fallback only supports scalar fields and looks up the LAST path
# segment as a key (first occurrence), which is good enough for the flat hook payloads.
kit_json_get() {
  local json="$1" path="$2" key m v
  if kit_has_jq; then
    printf '%s' "$json" | jq -r --arg p "$path" \
      'try (getpath($p | split(".")) | if type == "string" or type == "number" or type == "boolean" then tostring else empty end) catch empty' 2>/dev/null
    return 0
  fi
  key="${path##*.}"
  m=$(printf '%s' "$json" | LC_ALL=C grep -o -E '"'"$key"'"[[:space:]]*:[[:space:]]*("([^"\\]|\\.)*"|[-A-Za-z0-9_.+]+)' 2>/dev/null | head -n 1)
  [ -n "$m" ] || return 0
  v="${m#*:}"
  v=$(printf '%s' "$v" | sed -E 's/^[[:space:]]+//')
  case "$v" in
    \"*)
      v="${v#\"}"; v="${v%\"}"
      # JSON string escapes, decoded left to right (\\ \" \/ \n \t \r; \uXXXX is kept as is)
      # LC_ALL=C: byte-wise (fast); UTF-8 sequences pass through unchanged
      v=$(printf '%s' "$v" | LC_ALL=C awk 'BEGIN { RS = "\001" } { s = s $0 } END {
        n = length(s); o = ""
        for (i = 1; i <= n; i++) {
          c = substr(s, i, 1)
          if (c == "\\" && i < n) {
            d = substr(s, ++i, 1)
            if (d == "n") o = o "\n"; else if (d == "t") o = o "\t"; else if (d == "r") o = o "\r"
            else if (d == "u") o = o "\\u"; else o = o d
          } else o = o c
        }
        printf "%s", o }')
      ;;
    null) v="" ;;
  esac
  printf '%s' "$v"
}

# kit_model_text <json> -> lower-cased "id display_name" (or the model string)
kit_model_text() {
  local json="$1" t
  if kit_has_jq; then
    t=$(printf '%s' "$json" | jq -r 'try (.model | if type == "object" then ((.id // "") + " " + (.display_name // "")) elif type == "string" then . else "" end) catch ""' 2>/dev/null)
  else
    t=$(printf '%s' "$json" | grep -o -E '"model"[[:space:]]*:[[:space:]]*("[^"]*"|\{[^}]*\})' 2>/dev/null | head -n 1)
  fi
  printf '%s' "$t" | tr '[:upper:]' '[:lower:]'
}

# kit_model_id <json> -> model id (string model, or model.id)
kit_model_id() {
  local json="$1" v
  v=$(kit_json_get "$json" model)
  [ -n "$v" ] || v=$(kit_json_get "$json" model.id)
  printf '%s' "$v"
}

# stdin text -> quoted JSON string (no trailing newline in the input is added/removed)
kit_json_string() {
  if kit_has_jq; then
    jq -Rs .
  else
    local tab; tab=$(printf '\t')
    printf '"'
    tr -d '\000-\010\013-\037' \
      | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$tab/\\\\t/g" \
      | awk 'NR > 1 { printf "%s", "\\n" } { printf "%s", $0 }'
    printf '"'
  fi
}

# kit_cap_text <text> [label] -> text capped to KIT_CAP bytes (bytes >= chars, so safe); warns on stderr
kit_cap_text() {
  local text="$1" label="${2:-context}" n marker keep
  n=$(printf '%s' "$text" | wc -c | tr -d ' ')
  if [ "$n" -le "$KIT_CAP" ]; then
    printf '%s' "$text"
    return 0
  fi
  echo "claude-kit: $label is $n bytes, over the $KIT_CAP-char hook limit; truncated" >&2
  marker="
[... claude-kit: truncated, $label exceeds $KIT_CAP chars; shorten the rules file ...]"
  keep=$((KIT_CAP - ${#marker} - 8))
  if command -v iconv >/dev/null 2>&1; then
    printf '%s' "$text" | head -c "$keep" | iconv -c -f UTF-8 -t UTF-8 2>/dev/null
  else
    printf '%s' "$text" | head -c "$keep"
  fi
  printf '%s' "$marker"
}

# kit_emit <HookEvent> <text> [label] -> hookSpecificOutput JSON on stdout (nothing if text empty)
kit_emit() {
  local event="$1" text="$2" label="${3:-context}"
  [ -n "$text" ] || return 0
  text=$(kit_cap_text "$text" "$label")
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":%s}}\n' \
    "$event" "$(printf '%s' "$text" | kit_json_string)"
}

# kit_rules_text <file> -> file contents (empty when missing/empty)
kit_rules_text() {
  [ -s "$1" ] || return 0
  cat "$1"
}

# kit_os -> macos | linux | windows   (CLAUDE_KIT_OS overrides, for tests)
kit_os() {
  case "${CLAUDE_KIT_OS:-}" in macos|linux|windows) printf '%s' "$CLAUDE_KIT_OS"; return 0 ;; esac
  case "$(uname -s 2>/dev/null)" in
    Darwin*) printf 'macos' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *) printf 'linux' ;;
  esac
}

# kit_norm_path <path> -> backslashes to slashes; C:/x to /c/x when cygpath exists
kit_norm_path() {
  local p
  p=$(printf '%s' "$1" | tr '\\' '/')
  if command -v cygpath >/dev/null 2>&1; then
    case "$p" in [A-Za-z]:/*) p=$(cygpath -u "$p" 2>/dev/null || printf '%s' "$p") ;; esac
  fi
  printf '%s' "$p"
}

kit_state_dir() { printf '%s' "${CLAUDE_KIT_STATE:-$KIT_ROOT/state}"; }

# kit_sess_dir -> per-session state dir (created)
kit_sess_dir() {
  local d; d="$(kit_state_dir)/sessions"
  mkdir -p "$d" 2>/dev/null
  printf '%s' "$d"
}

# kit_safe <id> -> filename-safe token
kit_safe() { printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-80; }

# kit_prune [days] -> delete session state files older than N days (default 7)
kit_prune() {
  local d; d="$(kit_state_dir)/sessions"
  [ -d "$d" ] || return 0
  find "$d" -type f -mtime +"${1:-7}" -exec rm -f {} + 2>/dev/null
  # a stop-gate watermark is meaningless without its edit log: drop it with the log
  local g
  for g in "$d"/*.gate; do
    [ -f "$g" ] || continue
    [ -f "${g%.gate}.edits" ] || rm -f "$g"
  done
  return 0
}

# kit_is_source_path <path> -> 0 when the extension is a source-code one
kit_is_source_path() {
  local base ext
  # no real path is longer than 4096 bytes (PATH_MAX); decide before any pattern expansion, because
  # ${var##*/} is quadratic in bash on a very long word and the hooks have a 10 s timeout
  [ "$(kit_byte_len "$1")" -le 4096 ] || return 1
  base="${1##*/}"
  case "$base" in *.*) ;; *) return 1 ;; esac
  ext=$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')
  case "$ext" in
    ts|tsx|mts|cts|js|jsx|mjs|cjs|svelte|vue|astro|py|pyi|go|rs|java|kt|kts|swift|m|mm|\
c|cc|cpp|cxx|h|hh|hpp|cs|fs|php|rb|sh|bash|zsh|ps1|psm1|sql|dart|scala|lua|ex|exs|erl|\
hs|ml|clj|jl|zig|nim|groovy|gradle|pl|pm|css|scss|sass|less|html|htm) return 0 ;;
  esac
  return 1
}

# kit_descendants <pid>: all descendant pids (pgrep -P, or `ps -A -o pid= -o ppid=` without pgrep)
kit_descendants() {
  local c t
  if command -v pgrep >/dev/null 2>&1; then
    for c in $(pgrep -P "$1" 2>/dev/null); do printf '%s\n' "$c"; kit_descendants "$c"; done
    return 0
  fi
  t=$(ps -A -o pid= -o ppid= 2>/dev/null) || return 0
  printf '%s\n' "$t" | awk -v root="$1" '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { kids[$2] = kids[$2] " " $1 }
    END { n = 1; q[1] = root
          while (n > 0) { p = q[n]; n--; m = split(kids[p], ks, " "); for (i = 1; i <= m; i++) { print ks[i]; q[++n] = ks[i] } } }'
}

# kit_kill_tree <pid>: kill a process and all its descendants without relying on a process group
# (the tty path). Freeze-as-you-walk: STOP the root, then repeatedly STOP every newly found child of
# any frozen process, until a full pass finds nothing new (at most 50 passes); then KILL them all.
# A frozen process cannot fork any more. Limit: a chain deeper than the pass cap, or one that grows
# faster than one level per pass (a pass takes ~16 ms), can still leave running orphans.
# If the hook itself is TERMed / INTed / HUPed mid-walk, the trap KILLs the set frozen so far (and
# CONTs it so pending signals are delivered), so nothing is left stopped (state T) forever.
kit__walk_abort() {
  local p
  for p in $KIT_FROZEN; do kill -KILL "$p" 2>/dev/null; done
  for p in $KIT_FROZEN; do kill -CONT "$p" 2>/dev/null; done
  exit 143
}
kit_kill_tree() {
  local found p c pass=0 kids
  KIT_FROZEN=" $1 "
  trap kit__walk_abort TERM INT HUP
  kill -STOP "$1" 2>/dev/null
  while [ "$pass" -lt 50 ]; do
    found=""
    if command -v pgrep >/dev/null 2>&1; then
      kids=$(pgrep -P "$(printf '%s' "$KIT_FROZEN" | tr -s ' ' ',' | sed 's/^,//; s/,$//')" 2>/dev/null)
    else
      kids=$(ps -A -o pid= -o ppid= 2>/dev/null | awk -v set="$KIT_FROZEN" '$1 ~ /^[0-9]+$/ && index(set, " " $2 " ") { print $1 }')
    fi
    for c in $kids; do
      case "$KIT_FROZEN$found " in *" $c "*) ;; *) kill -STOP "$c" 2>/dev/null; found="$found $c " ;; esac
    done
    [ -n "$found" ] || break
    KIT_FROZEN="$KIT_FROZEN$found"; pass=$((pass + 1))
  done
  for p in $KIT_FROZEN; do kill -KILL "$p" 2>/dev/null; done
  trap - TERM INT HUP
  KIT_FROZEN=""
  return 0
}

# kit_kill_group <pid>: <pid> leads its own process group (started under set -m). Freeze the leader,
# TERM the whole group, then KILL the group plus any descendant that left it. Children spawned in the
# grace period are in the group too, so a parent that keeps re-spawning cannot leave orphans behind.
kit__group_abort() {   # TERM/INT/HUP while killing a group: finish the kill, leave nothing stopped
  kill -KILL -- "-$KIT_GROUP" 2>/dev/null; kill -KILL "$KIT_GROUP" 2>/dev/null
  kill -CONT -- "-$KIT_GROUP" 2>/dev/null
  exit 143
}
kit_kill_group() {
  local p="$1" k early
  KIT_GROUP="$p"
  trap kit__group_abort TERM INT HUP
  early=$(kit_descendants "$p")
  kill -STOP "$p" 2>/dev/null
  kill -TERM -- "-$p" 2>/dev/null; kill -CONT -- "-$p" 2>/dev/null
  sleep 0.2 2>/dev/null || sleep 1
  kill -KILL -- "-$p" 2>/dev/null
  for k in $early $(kit_descendants "$p"); do kill -KILL "$k" 2>/dev/null; done
  kill -KILL "$p" 2>/dev/null
  trap - TERM INT HUP
  return 0
}

# kit_run_timeout <seconds> <stdin-file> <stdout-file> <cmd...>: run cmd with a WALL-CLOCK deadline
# ($SECONDS, so slow ticks or slow forks cannot stretch it) and kill it with all its children when the
# deadline passes. No `timeout` binary needed (bash 3.2, Git Bash). stdin always comes from <stdin-file>.
#   - no controlling terminal (the normal hook case): the command gets its own process group (set -m)
#     and the whole group is killed - a parent that keeps re-spawning children leaves no orphans;
#   - with a controlling terminal: NO separate group (a background group touching the terminal would be
#     stopped by SIGTTIN/SIGTTOU, and it would survive a terminal hangup); then the parent is frozen,
#     its descendants killed (pgrep -P or ps), and the parent killed.
# Returns the command's status, or 124 when it was killed.
kit_run_timeout() {
  local s="$1" in="$2" out="$3" pid start grp=1
  shift 3
  start=$SECONDS
  ( : < /dev/tty ) 2>/dev/null && grp=0
  [ "$grp" = 1 ] && set -m
  "$@" < "$in" > "$out" 2>/dev/null &
  pid=$!
  [ "$grp" = 1 ] && set +m
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$s" ]; then
      if [ "$grp" = 1 ]; then { kit_kill_group "$pid"; wait "$pid"; } 2>/dev/null
      else { kit_kill_tree "$pid"; wait "$pid"; } 2>/dev/null; fi
      return 124
    fi
    sleep 0.1 2>/dev/null || sleep 1
  done
  wait "$pid" 2>/dev/null
}

# kit_verifier_timeout: sets KIT_VTO to CLAUDE_KIT_VERIFIER_TIMEOUT when it is an integer 10..170 (a
# useful minimum, below the 180 s Stop hook timeout), else 150; KIT_VTO_INVALID holds a rejected value. Call it directly (not
# in $(...)), so both variables reach the caller.
kit_verifier_timeout() {
  local v="${CLAUDE_KIT_VERIFIER_TIMEOUT:-}"
  KIT_VTO=150; KIT_VTO_INVALID=""
  case "$v" in
    "") return 0 ;;
    *[!0-9]*) ;;
    ?????*) ;;   # more than 4 digits: never valid (and no arithmetic overflow)
    *) v=$((10#$v)); if [ "$v" -ge 10 ] && [ "$v" -le 170 ]; then KIT_VTO="$v"; return 0; fi ;;
  esac
  KIT_VTO_INVALID="$CLAUDE_KIT_VERIFIER_TIMEOUT"
}

# Source-code extensions as an ERE alternation (same list as kit_is_source_path; match case-insensitively).
KIT_SRC_EXT='ts|tsx|mts|cts|js|jsx|mjs|cjs|svelte|vue|astro|py|pyi|go|rs|java|kt|kts|swift|m|mm|c|cc|cpp|cxx|h|hh|hpp|cs|fs|php|rb|sh|bash|zsh|ps1|psm1|sql|dart|scala|lua|ex|exs|erl|hs|ml|clj|jl|zig|nim|groovy|gradle|pl|pm|css|scss|sass|less|html|htm'

# kit_bash_source_write <command> -> prints a source file the shell command writes (exit 1 when none).
#
# A small quote-aware tokenizer (awk, POSIX) splits the command into words, operators and redirections,
# with single/double quotes, backslashes, $(...) and backticks kept inside words, comments dropped and
# heredoc bodies attached to their << redirection. Then each simple command is checked:
#   - redirections >, >>, >|, &>, &>>, <>, >&file onto a source path (the extension is the final suffix);
#   - tee FILE...; cp/mv/install whose DESTINATION (last word of that command) is a source path;
#   - sed/perl with in-place editing anywhere in the options (-i, -i.bak, -Ei, -0pi, --in-place) and a
#     source file among the FILE arguments (not words inside the script);
#   - python/node/ruby/deno/bun/perl code given with -c/-e/eval, or fed by a heredoc / here-string /
#     "-", that contains a write call on a source path: open(p, 'w'|'a'|'x'|'+'|mode=...),
#     Path(p).write_text/bytes, shutil copy/move, fs.writeFile*/appendFile*/createWriteStream/
#     copyFileSync/renameSync, File.write / File.open(p, 'w'), Deno.writeTextFile, Bun.write, perl open '>';
#   - bash/sh/zsh/dash/ksh code given with -c or fed by a heredoc is classified recursively (3 levels).
#   - bash/sh/... with combined flags (-lc, -ec, -xc) are treated like -c;
#   - git apply / git am / patch log "patch:<file or stdin>" (any patch counts, even a docs-only one);
#     patch -o FILE logs FILE when it is a source file.
#   - commands over KIT_BASH_MAX (128 KB) are not parsed: they log "bash:large" (fail safe: the stop gate
#     verifies). Below that the tokenizer stays well inside the 10 s hook timeout even with macOS awk,
#     whose string handling is not linear on long quoted strings.
# Known limits (accepted, documented): variables and globs are not expanded ($F > "$OUT.ts" with a
# variable target is missed); scripts that write files themselves (python gen.py) are not seen; the
# interpreter write-call patterns are heuristics; xargs/find -exec/dd/ln/touch/git checkout/git merge
# and other git commands that rewrite files are ignored.
read -r -d '' KIT_BASH_AWK <<'AWK' || true
# base/isext are linear (split), never sub(/.*\//) or an end-anchored match on long words.
function base(w,   n, parts) { n = split(w, parts, "/"); return n ? parts[n] : "" }
function isext(w,   b, n, xs) {
  b = base(w); n = split(b, xs, ".")
  if (n < 2 || xs[n] == "") return 0
  if (n == 2 && xs[1] == "") return 0
  return (tolower(xs[n]) in EXTS)
}
function pathin(t, which,   n, parts, q, r) {
  gsub(/[^A-Za-z0-9_.\/~+-]/, " ", t)
  n = split(t, parts, " "); r = ""
  for (q = 1; q <= n; q++) if (isext(parts[q])) { if (which == "first") return parts[q]; r = parts[q] }
  return r
}
# RSTART/RLENGTH are globals: copy them right after match(), before any helper that may call match()
# again, and stop when the rest did not shrink (defence in depth against an endless loop).
function firstmatch(c, re, which,   rest, t, s0, l0, len0) {
  rest = c
  while (match(rest, re)) {
    s0 = RSTART; l0 = RLENGTH
    t = pathin(substr(rest, s0, l0), which)
    if (t != "") return t
    len0 = length(rest)
    rest = substr(rest, s0 + (l0 > 0 ? l0 : 1))
    if (length(rest) >= len0) break
  }
  return ""
}
function codewrite(c,   t, q) {
  if (c == "") return ""
  q = "[\"'`]"
  if ((t = firstmatch(c, "open\\([[:space:]]*" q "[^\"'`]+" q "[[:space:]]*,[[:space:]]*(mode[[:space:]]*=[[:space:]]*)?" q "[rbtU]*[wax+]", "first")) != "") return t
  if ((t = firstmatch(c, "Path\\([[:space:]]*" q "[^\"'`]+" q "[[:space:]]*\\)\\.write_(text|bytes)", "first")) != "") return t
  if ((t = firstmatch(c, "shutil\\.(copy|copy2|copyfile|move)\\([^)]*\\)", "last")) != "") return t
  if ((t = firstmatch(c, "(writeFileSync|writeFile|appendFileSync|appendFile|createWriteStream|outputFile)\\([[:space:]]*" q "[^\"'`]+" q, "first")) != "") return t
  if ((t = firstmatch(c, "(copyFileSync|copyFile|renameSync|rename)\\([^)]*\\)", "last")) != "") return t
  if ((t = firstmatch(c, "(File|IO)\\.write\\([[:space:]]*" q "[^\"'`]+" q, "first")) != "") return t
  if ((t = firstmatch(c, "File\\.open\\([[:space:]]*" q "[^\"'`]+" q "[[:space:]]*,[[:space:]]*" q "[wa]", "first")) != "") return t
  if ((t = firstmatch(c, "Deno\\.write(Text)?File(Sync)?\\([[:space:]]*" q "[^\"'`]+" q, "first")) != "") return t
  if ((t = firstmatch(c, "Bun\\.write\\([[:space:]]*" q "[^\"'`]+" q, "first")) != "") return t
  if ((t = firstmatch(c, "open[^;]*" q "\\+?>>?[^;]*", "first")) != "") return t
  return ""
}
function flushw() {
  if (!INW) return
  NT++; TT[NT] = "W"; TV[NT] = CUR
  if (WANTD) { HDEL[WANTD] = CUR; NP++; PD[NP] = WANTD; WANTD = 0 }
  CUR = ""; INW = 0
}
function tok(t, v) { flushw(); NT++; TT[NT] = t; TV[NT] = v }
function tokenize(s,   n, i, c, d, j, depth, q, k, delim, strip, body, e, line, l2) {
  NT = 0; NP = 0; WANTD = 0; CUR = ""; INW = 0
  n = length(s); i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == " " || c == "\t" || c == "\r") { flushw(); i++; continue }
    if (c == "\n") {
      tok("O", ";"); i++
      for (q = 1; q <= NP; q++) {
        k = PD[q]; delim = HDEL[k]; strip = (TV[k] == "<<-"); body = ""
        while (i <= n) {
          e = index(substr(s, i), "\n")
          if (e == 0) { line = substr(s, i); i = n + 1 } else { line = substr(s, i, e - 1); i += e }
          l2 = line; sub(/\r$/, "", l2); if (strip) sub(/^\t+/, "", l2)
          if (l2 == delim) break
          body = body line "\n"
        }
        HD[k] = body
      }
      NP = 0; continue
    }
    if (c == "#" && !INW) { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
    if (c == "\\") { d = substr(s, i + 1, 1); if (d == "\n") { i += 2; continue }; CUR = CUR d; INW = 1; i += 2; continue }
    if (c == "'") {
      j = index(substr(s, i + 1), "'")
      if (j == 0) { CUR = CUR substr(s, i + 1); i = n + 1 } else { CUR = CUR substr(s, i + 1, j - 1); i += j + 1 }
      INW = 1; continue
    }
    if (c == "\"") {
      i++; INW = 1
      while (i <= n) {
        d = substr(s, i, 1)
        if (d == "\\" && i < n) { e = substr(s, i + 1, 1); if (e == "\"" || e == "\\" || e == "$" || e == "`") { CUR = CUR e; i += 2; continue } }
        if (d == "\"") { i++; break }
        CUR = CUR d; i++
      }
      continue
    }
    if (c == "$" && substr(s, i + 1, 1) == "(") {
      depth = 0; j = i
      while (j <= n) { d = substr(s, j, 1); if (d == "(") depth++; else if (d == ")") { depth--; if (depth == 0) break }; j++ }
      CUR = CUR substr(s, i, j - i + 1); INW = 1; i = j + 1; continue
    }
    if (c == "`") {
      j = index(substr(s, i + 1), "`"); if (j == 0) j = n - i
      CUR = CUR substr(s, i, j + 1); INW = 1; i += j + 1; continue
    }
    if (c == "&" && substr(s, i + 1, 1) == ">") {
      i += 2; if (substr(s, i, 1) == ">") { i++; tok("R", "&>>") } else tok("R", "&>"); continue
    }
    if (c == "|" || c == "&" || c == ";" || c == "(" || c == ")") {
      d = substr(s, i + 1, 1)
      if ((c == "|" || c == "&" || c == ";") && d == c) i += 2; else i++
      tok("O", ";"); continue
    }
    if (c == ">" || c == "<") {
      if (CUR ~ /^[0-9]+$/) { CUR = ""; INW = 0 }   # an fd number (2>file)
      i++; d = substr(s, i, 1)
      if (c == ">") {
        if (d == ">") { i++; tok("R", ">>") } else if (d == "|") { i++; tok("R", ">|") } else if (d == "&") { i++; tok("R", ">&") } else tok("R", ">")
      } else {
        if (d == "<") {
          i++
          if (substr(s, i, 1) == "<") { i++; tok("R", "<<<") }
          else { if (substr(s, i, 1) == "-") { i++; tok("R", "<<-") } else tok("R", "<<"); WANTD = NT }
        } else if (d == ">") { i++; tok("R", "<>") } else if (d == "&") { i++; tok("R", "<&") } else tok("R", "<")
      }
      continue
    }
    CUR = CUR c; INW = 1; i++
  }
  flushw()
}
function seg(   a, cmd, q, q2, w, inpl, scr, nf, start, i2, ch, code, flag, arg) {
  a = 1
  while (a <= NW && (W[a] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || W[a] == "sudo" || W[a] == "env" || W[a] == "command" || W[a] == "nohup" || W[a] == "time" || W[a] == "exec")) a++
  if (a > NW) return ""
  cmd = base(W[a])
  if (cmd == "tee") { for (q = a + 1; q <= NW; q++) if (W[q] !~ /^-/ && isext(W[q])) return W[q]; return "" }
  if (cmd == "cp" || cmd == "mv" || cmd == "install") {
    for (q = a + 1; q <= NW; q++) if (W[q] == "-t" || W[q] ~ /^--target-directory/) return ""
    if (NW >= a + 2 && W[NW] !~ /^-/ && isext(W[NW])) return W[NW]
    return ""
  }
  if (cmd == "git") {
    for (q = a + 1; q <= NW; q++) {
      w = W[q]
      if (w == "-C" || w == "-c" || w == "--git-dir" || w == "--work-tree" || w == "--namespace") { q++; continue }
      if (w ~ /^-/) continue
      break
    }
    if (q > NW || (W[q] != "apply" && W[q] != "am")) return ""
    arg = ""; flag = 0; ch = 0
    for (q2 = q + 1; q2 <= NW; q2++) {
      w = W[q2]
      if (w == "--apply") { flag = 1; continue }
      if (w == "--check" || w == "--stat" || w == "--numstat" || w == "--summary") { ch = 1; continue }
      if (w == "--abort" || w == "--skip" || w == "--quit") return ""
      if (w ~ /^-/) continue
      if (arg == "") arg = w
    }
    if (ch && !flag) return ""   # report-only, unless --apply is given too
    if (arg == "") arg = (SIN != "" ? SIN : "stdin")
    return "patch:" arg
  }
  if (cmd == "patch") {
    arg = ""; flag = ""; code = "-"
    for (q = a + 1; q <= NW; q++) {
      w = W[q]
      if (w == "--dry-run" || w == "-C" || w == "--check") return ""
      if (w == "-i" || w == "--input") { q++; if (flag == "") flag = W[q]; continue }
      if (w ~ /^--input=/) { if (flag == "") flag = substr(w, 9); continue }
      if (w == "-o" || w == "--output") { q++; code = W[q]; continue }
      if (w ~ /^--output=/) { code = substr(w, 10); continue }
      if (w ~ /^-[dorBzDFVYg]$/) { q++; continue }
      if (w ~ /^-/) continue
      if (arg == "") arg = w
    }
    if (code != "-") return isext(code) ? code : ""   # -o: only the output file is written
    if (flag != "") return "patch:" flag              # label with the patch file when it is named
    if (arg == "") arg = (SIN != "" ? SIN : "stdin")
    return "patch:" arg
  }
  if (cmd == "sed" || cmd == "gsed") {
    inpl = 0; scr = 0; nf = 0
    for (q = a + 1; q <= NW; q++) {
      w = W[q]
      if (w == "-e" || w == "-f" || w == "--expression" || w == "--file") { q++; scr = 1; continue }
      if (w ~ /^--(expression|file)=/) { scr = 1; continue }
      if (w == "--in-place" || w ~ /^--in-place=/) { inpl = 1; continue }
      if (w ~ /^--/) continue
      if (w ~ /^-[A-Za-z]/) {
        for (i2 = 2; i2 <= length(w); i2++) {
          ch = substr(w, i2, 1)
          if (ch == "i") { inpl = 1; if (i2 == length(w) && q < NW && W[q + 1] == "") q++; break }
          if (ch == "e" || ch == "f") { scr = 1; if (i2 == length(w)) q++; break }
        }
        continue
      }
      nf++; F[nf] = w
    }
    if (!inpl) return ""
    start = scr ? 1 : 2
    for (q = start; q <= nf; q++) if (isext(F[q])) return F[q]
    return ""
  }
  if (cmd == "perl") {
    inpl = 0; code = ""; flag = 0; nf = 0
    for (q = a + 1; q <= NW; q++) {
      w = W[q]
      if (w ~ /^-[A-Za-z0-9]/) {
        for (i2 = 2; i2 <= length(w); i2++) {
          ch = substr(w, i2, 1)
          if (ch == "i") { inpl = 1; break }
          if (ch == "e" || ch == "E") { flag = 1; if (i2 < length(w)) code = code substr(w, i2 + 1) "\n"; else { q++; code = code W[q] "\n" }; break }
          if (ch == "0") { while (substr(w, i2 + 1, 1) ~ /[0-9a-fA-Fx]/) i2++; continue }
          if (ch ~ /[IMmxCdD]/) break
        }
        continue
      }
      nf++; F[nf] = w
    }
    if (inpl) { start = flag ? 1 : 2; for (q = start; q <= nf; q++) if (isext(F[q])) return F[q]; return "" }
    if (flag) return codewrite(code)
    if (nf == 0 || F[1] == "-") return codewrite(SH)
    return ""
  }
  if (cmd ~ /^python[0-9.]*$/ || cmd == "node" || cmd == "nodejs" || cmd == "ruby" || cmd == "deno" || cmd == "bun") {
    code = ""; flag = 0; nf = 0
    for (q = a + 1; q <= NW; q++) {
      w = W[q]
      if (w == "-c" || w == "-e" || w == "--eval" || w == "eval" || ((cmd == "node" || cmd == "nodejs") && w == "-p")) { q++; code = code W[q] "\n"; flag = 1; continue }
      if (w ~ /^-./) continue
      nf++; F[nf] = w; break
    }
    if (flag) return codewrite(code)
    if (nf == 0 || F[1] == "-") return codewrite(SH)
    return ""
  }
  if (cmd == "bash" || cmd == "sh" || cmd == "zsh" || cmd == "dash" || cmd == "ksh") {
    nf = 0
    for (q = a + 1; q <= NW; q++) {
      w = W[q]
      if (w == "-c" || w ~ /^-[A-Za-z]*c[A-Za-z]*$/) {   # -c, -lc, -ec, -xc (and -c -- CODE)
        if (W[q + 1] == "--") q++
        RECUR = RECUR "R\t" W[q + 1] "\001"; return ""
      }
      if (w == "-o" || w == "+o") { q++; continue }
      if (w ~ /^[-+]./) continue
      nf++; break
    }
    if (nf == 0 && SH != "") RECUR = RECUR "R\t" SH "\001"
    return ""
  }
  return ""
}
function classify(s,   k, op, tgt, r) {
  tokenize(s)
  NW = 0; SH = ""; SIN = ""
  for (k = 1; k <= NT + 1; k++) {
    if (k > NT || TT[k] == "O") {
      r = seg(); if (r != "") return r
      NW = 0; SH = ""; SIN = ""; continue
    }
    if (TT[k] == "R") {
      op = TV[k]; tgt = ""
      if (op == "<<" || op == "<<-") { SH = SH HD[k]; if (k < NT && TT[k + 1] == "W") k++; continue }
      if (k < NT && TT[k + 1] == "W") { tgt = TV[k + 1]; k++ }
      if (op == ">" || op == ">>" || op == ">|" || op == "&>" || op == "&>>" || op == "<>") { if (isext(tgt)) return tgt }
      else if (op == ">&") { if (tgt !~ /^[0-9]+$/ && tgt != "-" && isext(tgt)) return tgt }
      else if (op == "<<<") SH = SH tgt "\n"
      else if (op == "<") SIN = tgt
      continue
    }
    NW++; W[NW] = TV[k]
  }
  return ""
}
BEGIN { RS = "\001"; n = split(EXT, xs, "|"); for (q = 1; q <= n; q++) EXTS[xs[q]] = 1 }
{ SRC = SRC $0 }
END { r = classify(SRC); if (r != "") printf "W\t%s\001", r; else printf "%s", RECUR }
AWK

KIT_BASH_MAX=131072   # BYTES; commands above this are not parsed (awk string handling is not linear everywhere)

# kit_byte_len <string> -> length in bytes (${#var} counts characters under a UTF-8 locale)
kit_byte_len() { local LC_ALL=C; printf '%s' "${#1}"; }

kit_bash_source_write() {
  local out depth="${2:-0}" rec p
  [ "$depth" -le 3 ] || return 1
  # fail safe: a huge command is logged conservatively so the stop gate still verifies
  if [ "$(kit_byte_len "$1")" -gt "$KIT_BASH_MAX" ]; then printf 'bash:large'; return 0; fi
  out=$(printf '%s' "$1" | LC_ALL=C awk -v EXT="$KIT_SRC_EXT" "$KIT_BASH_AWK" 2>/dev/null) || return 1
  case "$out" in
    W"	"*)
      p="${out#W?}"; p="${p%$'\001'*}"
      case "$p" in patch:?*|bash:large) printf '%s' "$p"; return 0 ;; esac   # git apply / git am / patch
      kit_is_source_path "$p" || return 1
      printf '%s' "$p"; return 0 ;;
  esac
  while IFS= read -r -d $'\001' rec; do
    case "$rec" in R"	"*) kit_bash_source_write "${rec#R?}" $((depth + 1)) && return 0 ;; esac
  done <<EOF
$out
EOF
  return 1
}

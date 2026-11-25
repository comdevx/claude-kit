#!/bin/bash
# Shared mode on fresh profiles, loop refusal, running-session warning, the Windows no-symlink
# fallback (forced with CLAUDE_KIT_FORCE_NO_SYMLINK=1 so it runs here too), and unit checks of
# setup-core.sh helpers.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$(dirname "${BASH_SOURCE[0]}")/installer-lib.sh"
build_dist

IDENTITY=".claude.json .credentials.json settings.local.json mcp.json statsig security_state"

mk_pair() { # fresh primary ~/.claude + secondary ~/.claude-two, each with its own files
  new_home "$1"
  P="$H/.claude"; S="$H/.claude-two"
  mkdir -p "$P/agents" "$P/projects/p" "$S/agents" "$S/projects/q" "$S/statsig"
  printf '{"theme":"p"}\n' > "$P/settings.json"   # no identity keys on either side: linkable; printf 'primary\n' > "$P/CLAUDE.md"
  printf 'a1\n' > "$P/agents/a1.md"; printf 'h1\n' > "$P/history.jsonl"
  printf '{"theme":"two"}\n' > "$S/settings.json"; printf 'two\n' > "$S/CLAUDE.md"
  printf 'a2\n' > "$S/agents/a2.md"; printf 'h2\n' > "$S/history.jsonl"
  printf '{"account":"two"}\n' > "$S/.claude.json"; printf 'secret\n' > "$S/.credentials.json"
  printf '{"local":1}\n' > "$S/settings.local.json"; printf '{"mcp":1}\n' > "$S/mcp.json"
  printf 's\n' > "$S/statsig/x"; printf 'sec\n' > "$S/security_state"
  mkdir -p "$S/lessons"; printf 'my lesson\n' > "$S/lessons/one.md"
}
identity_ok() { # label
  local f ok=1
  for f in $IDENTITY; do [ -L "$S/$f" ] && ok=0; [ -e "$S/$f" ] || ok=0; done
  [ "$(cat "$S/.claude.json")" = '{"account":"two"}' ] || ok=0
  [ "$ok" = 1 ] && pass "$1: identity files untouched and not linked" || fail "$1: identity files" "$(ls -la "$S")"
}

# ---------------------------------------------------------------- shared, share=config
mk_pair "shared home"
before=$(tree "$H")
run_inst --all --mode shared --primary "~/.claude" --share config --yes
assert_eq "shared config: exit 0" 0 "$RC"
for item in CLAUDE.md settings.json skills commands agents; do
  assert_eq "shared config: $item linked to the primary" "$P/$item" "$(readlink "$S/$item")"
done
assert_eq "shared config: original settings kept as .backup" '{"theme":"two"}' "$(cat "$S/settings.json.backup")"
assert_eq "shared config: original CLAUDE.md kept as .backup" "two" "$(cat "$S/CLAUDE.md.backup")"
assert_eq "shared config: original agents dir kept as .backup" "a2" "$(cat "$S/agents.backup/a2.md")"
identity_ok "shared config"
[ ! -L "$S/projects" ] && [ ! -L "$S/history.jsonl" ] && pass "shared config: history items not linked" || fail "shared config: history not linked" "linked"
[ ! -L "$S/lessons" ] && [ "$(cat "$S/lessons/one.md")" = "my lesson" ] && pass "shared config: item missing in the primary is kept as is" || fail "lessons kept" "changed"
assert_eq "shared config: kit merged once into the primary" "$KIT_N" "$(kit_cmd_count "$P/settings.json")"
assert_eq "shared config: secondary sees the kit hooks through the link" "$KIT_N" "$(kit_cmd_count "$S/settings.json")"
assert_eq "shared config: manifest share links" 5 "$("$REAL_JQ" '[.created[] | select(.type == "share-link")] | length' "$KH/state/install.json")"
run_inst --all --mode shared --primary "~/.claude" --share config --yes
assert_eq "shared re-run: exit 0" 0 "$RC"
assert_eq "shared re-run: reports already shared" 5 "$(count_of "$OUT" 'already shared')"
ls -d "$S"/*.backup.* >/dev/null 2>&1 && fail "shared re-run: no extra backups" "$(ls "$S")" || pass "shared re-run: no extra .backup.<ts>"
run_inst --uninstall --yes
assert_eq "shared uninstall: exit 0" 0 "$RC"
assert_tree_same "shared uninstall: restores the kit-made .backup files, HOME byte-identical" "$before" "$(tree "$H" skip)"

# ---------------------------------------------------------------- uninstall without --yes on a terminal: backups only on request
mk_pair "shared ask home"
run_inst --all --mode shared --primary "~/.claude" --yes
printf 'mine\n' > "$S/notes.backup"          # a backup the kit did NOT make
printf 'y\nn\nn\nn\nn\nn\n' > "$T/answers"
TTYF="$T/answers" run_inst --uninstall
assert_eq "uninstall (answers): exit 0" 0 "$RC"
assert_has "uninstall offers to restore kit-made backups" "$OUT" "Restore ~/.claude-two/"
assert_not_has "uninstall never offers backups it did not make" "$OUT" "notes.backup"
[ -f "$S/notes.backup" ] && pass "foreign backup left alone" || fail "foreign backup" "gone"
left=$(ls -d "$S"/*.backup 2>/dev/null | grep -vc notes.backup)
assert_eq "declined restores stay as .backup (CLAUDE.md, settings.json, agents)" 3 "$left"

# ---------------------------------------------------------------- shared, share=config+history
mk_pair "history home"
run_inst --all --mode shared --share config+history --yes
assert_eq "config+history: exit 0" 0 "$RC"
assert_eq "config+history: projects linked" "$P/projects" "$(readlink "$S/projects")"
assert_eq "config+history: history.jsonl linked" "$P/history.jsonl" "$(readlink "$S/history.jsonl")"
assert_eq "config+history: original history kept" "h2" "$(cat "$S/history.jsonl.backup")"
identity_ok "config+history"

# ---------------------------------------------------------------- loop refusal
new_home "loop home"
mkdir -p "$H/.claude"; printf '{}\n' > "$H/.claude/settings.json"; ln -s "$H/.claude" "$H/.claude-loop"
mkdir -p "$H/.claude/inner"; printf '{}\n' > "$H/.claude/inner/settings.json"
before=$(tree "$H")
run_inst --profile "~/.claude" --profile "~/.claude-loop" --mode shared --primary "~/.claude" --yes
[ "$RC" -ne 0 ] && pass "secondary that is the primary via symlink: refused" || fail "loop refused" "rc=0"
assert_has "loop refusal explains why" "$OUT" "is the primary itself"
run_inst --profile "~/.claude" --profile "~/.claude/inner" --mode shared --primary "~/.claude" --yes
[ "$RC" -ne 0 ] && pass "secondary inside the primary: refused" || fail "nested refused" "rc=0"
assert_tree_same "loop refusals change nothing" "$before" "$(tree "$H")"
run_inst --list-profiles
assert_eq "symlinked duplicate profile listed once" 1 "$(printf '%s\n' "$OUT" | grep -c '/\.claude')"

# ---------------------------------------------------------------- Claude Code running
mk_pair "running home"
before=$(tree "$H")
RUNNING=1 run_inst --all --mode shared
[ "$RC" -ne 0 ] && pass "running session, no --yes: stops before relinking" || fail "running stop" "rc=0"
assert_has "running session: warns" "$OUT" "Claude Code appears to be running"
assert_tree_same "running session, no --yes: nothing changed" "$before" "$(tree "$H")"
RUNNING=1 run_inst --all --mode shared --yes
assert_eq "running session with --yes: continues after the warning" 0 "$RC"

# ---------------------------------------------------------------- Windows fallback (no native symlinks)
mk_pair "nosymlink home"
before=$(tree "$H")
XENV="CLAUDE_KIT_FORCE_NO_SYMLINK=1" run_inst --all --mode shared --yes
assert_eq "no-symlink shared: exit 0" 0 "$RC"
M="$KH/state/install.json"
[ -d "$P/skills/fable-method" ] && [ ! -L "$P/skills/fable-method" ] && pass "no-symlink: kit skills copied into the primary" || fail "skills copied" "$(ls -la "$P/skills" | head -3)"
assert_eq "no-symlink: copies recorded in the manifest" "$KIT_ITEMS" "$("$REAL_JQ" '[.created[] | select(.type == "copy")] | length' "$M")"
for item in skills commands agents; do
  assert_eq "no-symlink: $item becomes a junction" "junction" "$("$REAL_JQ" -r --arg p "$S/$item" '.created[] | select(.path == $p) | .type' "$M")"
done
assert_eq "no-symlink: CLAUDE.md is a one-line import of the primary" "@~/.claude/CLAUDE.md" "$(cat "$S/CLAUDE.md")"
[ ! -L "$S/CLAUDE.md" ] && [ ! -L "$S/settings.json" ] && pass "no-symlink: CLAUDE.md and settings.json are regular files" || fail "regular files" "links"
assert_eq "no-symlink: settings.json falls back to its own merge" "\"two\"|$KIT_N" "$("$REAL_JQ" -c .theme "$S/settings.json")|$(kit_cmd_count "$S/settings.json")"
assert_has "no-symlink: Developer Mode note printed" "$OUT" "Developer Mode"
nl() { ls -l "$1" | awk '{print $2}'; }
assert_eq "no-symlink: no hard links (link count 1)" "1 1 1 1" "$(nl "$S/CLAUDE.md") $(nl "$S/settings.json") $(nl "$P/CLAUDE.md") $(nl "$P/settings.json")"
assert_eq "no-symlink: original CLAUDE.md kept as .backup" "two" "$(cat "$S/CLAUDE.md.backup")"
identity_ok "no-symlink"
XENV="CLAUDE_KIT_FORCE_NO_SYMLINK=1" run_inst --all --mode shared --yes
assert_eq "no-symlink re-run: exit 0" 0 "$RC"
assert_eq "no-symlink re-run: still 9 kit hooks in the secondary" "$KIT_N" "$(kit_cmd_count "$S/settings.json")"
XENV="CLAUDE_KIT_FORCE_NO_SYMLINK=1" run_inst --uninstall --yes
assert_eq "no-symlink uninstall: exit 0" 0 "$RC"
assert_tree_same "no-symlink uninstall: HOME byte-identical" "$before" "$(tree "$H" skip)"

# ---------------------------------------------------------------- unit checks of setup-core.sh helpers
mkdir -p "$T/u home"
cat > "$T/u home/rc" <<'EOF'
alias a='CLAUDE_CONFIG_DIR=$HOME/.p1 claude'
export CLAUDE_CONFIG_DIR="/opt/p 2"
set -gx CLAUDE_CONFIG_DIR ~/.p3
  # CLAUDE_CONFIG_DIR=/nope
EOF
U=$(cd "$T" && env -i HOME="$T/u home" PATH="$JQ_PATH" CLAUDE_KIT_LIB_ONLY=1 "$BASH_BIN" -c '
  . "$1"
  for i in $CONFIG_ITEMS $HISTORY_ITEMS; do
    for n in $NEVER_SHARE; do [ "$i" = "$n" ] && echo "LEAK $i"; done
    case "$i" in security*|.credentials*) echo "LEAK $i" ;; esac
  done
  echo "E1=$(expand_path "\$HOME/x")"
  echo "E2=$(expand_path "~/y")"
  echo "E3=$(expand_path "%USERPROFILE%\\a\\b")"
  echo "E4=$(expand_path "\$env:USERPROFILE\\c")"
  echo "E5=$(expand_path "\${HOME}/d/")"
  expand_path "\$OTHER/z" >/dev/null || echo "E6=refused"
  mkdir -p "$HOME/r/real" && cd "$HOME/r" && ln -s real l1 && ln -s l1 l2 && : > real/f && ln -s ../real/f real/g && ln -s g real/h
  echo "R1=$(realpath_of "$HOME/r/l2")"
  echo "R2=$(realpath_of "$HOME/r/real/h")"
  rc_values "$HOME/rc" | sed "s/^/V=/"
 ' _ "$REPO/installer/setup-core.sh" 2>&1)
assert_not_has "unit: no identity item in any share list" "$U" "LEAK"
assert_has "unit: expand \$HOME" "$U" "E1=$T/u home/x"
assert_has "unit: expand ~" "$U" "E2=$T/u home/y"
assert_has "unit: expand %USERPROFILE% with backslashes" "$U" "E3=$T/u home/a/b"
assert_has "unit: expand \$env:USERPROFILE" "$U" "E4=$T/u home/c"
assert_has "unit: expand \${HOME} and drop trailing slash" "$U" "E5=$T/u home/d"
assert_has "unit: unresolvable variable refused" "$U" "E6=refused"
rp=$(cd "$T" && pwd -P)
assert_has "unit: realpath follows a dir symlink chain" "$U" "R1=$rp/u home/r/real"
assert_has "unit: realpath follows relative file symlink chains" "$U" "R2=$rp/u home/r/real/f"
assert_has "unit: rc alias value" "$U" 'V=$HOME/.p1'
assert_has "unit: rc quoted value with a space" "$U" 'V="/opt/p 2"'
assert_has "unit: fish set value" "$U" 'V=~/.p3'
assert_not_has "unit: commented rc line ignored" "$U" "/nope"

finish

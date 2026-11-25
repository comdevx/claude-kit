#!/bin/bash
# Installer isolation (round 9): a test run that has to use the real HOME (e.g. to stay logged in to
# claude) must be able to keep the installer away from ~/.cursor and the CLI link dirs.
# Here the "real HOME" is a fake HOME that has a .cursor/ (with a dotfiles-style hooks.json symlink)
# and a .local/bin/ on PATH; both must stay byte-untouched.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$(dirname "${BASH_SOURCE[0]}")/installer-lib.sh"
build_dist

real_like_home() {
  new_home "$1"; P="$H/.claude"; mkdir -p "$P" "$H/.cursor" "$H/.local/bin" "$H/dotfiles"
  printf '{"theme":"m"}\n' > "$P/settings.json"
  printf '{\n  "version": 1,\n  "hooks": { "stop": [ { "command": "echo mine" } ] }\n}\n' > "$H/dotfiles/cursor-hooks.json"
  ln -s "$H/dotfiles/cursor-hooks.json" "$H/.cursor/hooks.json"
  printf 'mine\n' > "$H/.local/bin/other-tool"
}
guarded() { printf '%s\n%s\n%s\n' "$(tree "$H/.cursor")" "$(tree "$H/.local/bin")" "$(tree "$H/dotfiles")"; }

# ---------------------------------------------------------------- --no-cursor --no-cli
real_like_home "iso flags home"; g0=$(guarded)
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --no-cli
assert_eq "1: --no-cursor --no-cli: install ok" 0 "$RC"
assert_tree_same "1: --no-cursor --no-cli: ~/.cursor, ~/.local/bin and the dotfiles target byte-untouched after install" "$g0" "$(guarded)"
assert_has "1: --no-cli: the CLI hint is printed instead" "$OUT" "Run the CLI as"
assert_eq "1: the profile itself is installed" "$KIT_N" "$(kit_cmd_count "$P/settings.json")"
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes
assert_eq "1: uninstall ok" 0 "$RC"
assert_tree_same "1: --no-cursor --no-cli: still byte-untouched after uninstall" "$g0" "$(guarded)"

# ---------------------------------------------------------------- the same through environment variables
real_like_home "iso env home"; g0=$(guarded)
XENV="CLAUDE_KIT_NO_CURSOR=1 CLAUDE_KIT_NO_CLI=1" INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes
assert_eq "1: CLAUDE_KIT_NO_CURSOR=1 CLAUDE_KIT_NO_CLI=1: install ok" 0 "$RC"
assert_tree_same "1: env opt-outs: ~/.cursor and ~/.local/bin byte-untouched" "$g0" "$(guarded)"

# ---------------------------------------------------------------- update replays the recorded opt-outs
REL="$T/release"; "$BASH_BIN" "$REPO/build-release.sh" --worktree --version 9.9.12-test --out "$REL" > "$T/rel.log" 2>&1 || fail "release build" "$(cat "$T/rel.log")"
INST_PATH="$JQ_PATH:$H/.local/bin" XENV="CLAUDE_KIT_RELEASE_URL=$(file_url "$REL")" run_cli update
assert_eq "1: update after an isolated install: ok" 0 "$RC"
assert_tree_same "1: update replays --no-cursor/--no-cli (still untouched)" "$g0" "$(guarded)"

# ---------------------------------------------------------------- --cursor-dir / --bin-dir
real_like_home "iso dirs home"; g0=$(guarded)
mkdir -p "$H/alt-cursor" "$H/alt-bin"
printf '{\n  "version": 1,\n  "hooks": { "stop": [ { "command": "echo alt" } ] }\n}\n' > "$H/alt-cursor/hooks.json"
alt0=$(tree "$H/alt-cursor"); bin0=$(tree "$H/alt-bin")
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --cursor-dir "$H/alt-cursor" --bin-dir "$H/alt-bin"
assert_eq "1: --cursor-dir/--bin-dir: install ok" 0 "$RC"
assert_eq "1: --cursor-dir: the kit Cursor hooks land in the given dir" 4 "$("$REAL_JQ" '[.hooks[][] | select(.command | contains("/cursor/hooks/"))] | length' "$H/alt-cursor/hooks.json")"
assert_eq "1: --bin-dir: the CLI link lands in the given dir" "$KH/bin/claude-kit" "$(readlink "$H/alt-bin/claude-kit")"
assert_tree_same "1: --cursor-dir/--bin-dir: ~/.cursor and ~/.local/bin byte-untouched" "$g0" "$(guarded)"
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes
assert_tree_same "1: uninstall restores the --cursor-dir hooks.json byte-identical" "$alt0" "$(tree "$H/alt-cursor" skip)"
assert_tree_same "1: uninstall removes the CLI link from --bin-dir" "$bin0" "$(tree "$H/alt-bin")"
assert_tree_same "1: after uninstall ~/.cursor and ~/.local/bin are still untouched" "$g0" "$(guarded)"

# ---------------------------------------------------------------- uninstall honours the record, not flags
real_like_home "iso record home"; mkdir -p "$H/alt-cursor"; printf '{"version":1}\n' > "$H/alt-cursor/hooks.json"
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --cursor-dir "$H/alt-cursor" --no-cli
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes --no-cursor
assert_eq "1: uninstall ignores flags and uses install.json (kit hooks removed from the recorded cursor dir)" '{"version":1}' "$(cat "$H/alt-cursor/hooks.json")"

# ---------------------------------------------------------------- --dry-run shows absolute paths
real_like_home "iso dry home"
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --dry-run
assert_has "1: --dry-run prints the absolute path of the Cursor target next to ~" "$OUT" "$(cd "$H/dotfiles" && pwd -P)/cursor-hooks.json"
assert_has "1: --dry-run prints the absolute path of the CLI link" "$OUT" "$H/.local/bin/claude-kit"
assert_has "1: README has an isolated-install note" "$(cat "$REPO/README.md")" "--no-cursor"

# ================================================================ round 10
rec() { "$REAL_JQ" -r "$1" "$KH/state/install.json"; }
tamper() { "$REAL_JQ" "$1" "$KH/state/install.json" > "$T/m.tmp" && cat "$T/m.tmp" > "$KH/state/install.json"; }
upd() { INST_PATH="$JQ_PATH:$H/.local/bin" XENV="CLAUDE_KIT_RELEASE_URL=$(file_url "$REL") ${UPD_ENV:-}" run_cli update; }

# ---------------------------------------------------------------- 1. update never undoes --no-cli
for order in "--bin-dir XB --no-cli" "--no-cli --bin-dir XB" "env"; do
  real_like_home "r10-nocli-home"; mkdir -p "$H/xb"
  if [ "$order" = env ]; then
    XENV="CLAUDE_KIT_NO_CLI=1 CLAUDE_KIT_BIN_DIR=$H/xb" INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor
  else
    set -- $order; a1="$1"; a2="$2"; a3="${3:-}"
    [ "$a1" = "--bin-dir" ] && args="--bin-dir $H/xb --no-cli" || args="--no-cli --bin-dir $H/xb"
    if [ "$a1" = "--bin-dir" ]; then INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --bin-dir "$H/xb" --no-cli
    else INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --no-cli --bin-dir "$H/xb"; fi
  fi
  [ -z "$(ls -A "$H/xb")" ] && pass "1 [$order]: --no-cli wins at install (no link in the bin dir)" || fail "1 [$order]: install link" "$(ls -A "$H/xb")"
  assert_eq "1 [$order]: record says no_cli and no bin_dir" "true|" "$(rec .no_cli)|$(rec .bin_dir)"
  upd
  assert_eq "1 [$order]: update ok" 0 "$RC"
  [ -z "$(ls -A "$H/xb")" ] && pass "1 [$order]: update does not create the CLI link" || fail "1 [$order]: update link" "$(ls -A "$H/xb")"
  assert_eq "1 [$order]: record still says no_cli:true after update" true "$(rec .no_cli)"
done

# ---------------------------------------------------------------- 2. relative --bin-dir / --cursor-dir
for spec in ./b sub/../b; do
  real_like_home "r10 rel home"; mkdir -p "$H/b" "$H/sub" "$H/mycur"; printf '{"version":1}\n' > "$H/mycur/hooks.json"
  before=$(tree "$H")
  RUN_CWD="$H" INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --bin-dir "$spec" --cursor-dir "./sub/../mycur"
  assert_eq "2 [$spec]: install ok" 0 "$RC"
  assert_eq "2 [$spec]: link landed in ~/b" "$KH/bin/claude-kit" "$(readlink "$H/b/claude-kit")"
  assert_eq "2 [$spec]: recorded dirs are normalized (no . or .. left)" "$(cd "$H/b" && pwd -P)|$(cd "$H/mycur" && pwd -P)" \
    "$(cd "$(rec '.bin_dirs[0]')" 2>/dev/null && pwd -P)|$(cd "$(rec '.cursor_dirs[0]')" 2>/dev/null && pwd -P)"
  case "$(rec '.bin_dirs[0]')$(rec '.cursor_dirs[0]')" in */./*|*/../*) fail "2 [$spec]: dot segments recorded" "$(rec '.bin_dirs[0]')" ;; *) pass "2 [$spec]: no dot segments in the record" ;; esac
  RUN_CWD="$H" INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes
  dangling=$(find "$H" -type l ! -exec test -e {} \; -print 2>/dev/null)
  assert_empty "2 [$spec]: no dangling link after uninstall" "$dangling"
  assert_tree_same "2 [$spec]: uninstall restores HOME" "$before" "$(tree "$H" skip)"
done

# ---------------------------------------------------------------- 3. guard recorded / flagged dirs
real_like_home "r10 flags home"; before=$(tree "$H")
for bad in "--cursor-dir $H" "--cursor-dir $H/.claude" "--bin-dir $H" "--bin-dir $KH/bin" "--cursor-dir /etc" "--bin-dir /usr/bin"; do
  set -- $bad
  INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes "$1" "$2"
  [ "$RC" -ne 0 ] && pass "3: install refuses $1 $(printf '%s' "$2" | sed "s#$H#~#")" || fail "3: install refuses $1 $2" "rc=0"
done
assert_tree_same "3: refused flags changed nothing" "$before" "$(tree "$H")"
for target in /etc HOME PROFILE; do
  for kind in cursor bin; do
    real_like_home "r10 guard home"; INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cli
    case "$target" in HOME) d="$H" ;; PROFILE) d="$H/.claude" ;; *) d="$target" ;; esac
    if [ "$kind" = cursor ]; then tamper ".cursor_dirs = [\"$d\"] | .cursor_dir = \"$d\" | .no_cursor = false"
    else tamper ".bin_dirs = [\"$d\"] | .bin_dir = \"$d\" | .no_cli = false"; fi
    snap=$(tree "$H"); m0=$(cksum < "$KH/state/install.json")
    INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes
    [ "$RC" -ne 0 ] && pass "3: uninstall refuses a recorded $kind dir = $target" || fail "3: uninstall refuses $kind=$target" "rc=0"
    assert_has "3: uninstall says why ($kind=$target)" "$OUT" "refusing"
    assert_tree_same "3: refused uninstall ($kind=$target) changed nothing" "$snap" "$(tree "$H")"
    upd
    [ "$RC" -ne 0 ] && pass "3: update refuses a recorded $kind dir = $target" || fail "3: update refuses $kind=$target" "rc=0"
    assert_tree_same "3: refused update ($kind=$target) changed nothing" "$snap" "$(tree "$H")"
  done
done

# ---------------------------------------------------------------- 4. kit-link ownership is per kit home
real_like_home "r10 two kits home"; mkdir -p "$H/b" "$H/.claude-b" "$H/kitb"; printf '{}\n' > "$H/.claude-b/settings.json"
KHA="$KH"; KHB="$H/kitb/.claude-kit"
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --profile "$H/.claude" --yes --no-cursor --bin-dir "$H/b"
KH="$KHB" INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --profile "$H/.claude-b" --yes --no-cursor --bin-dir "$H/b"
assert_eq "4: a second kit home does not take over the first kit's CLI link" "$KHA/bin/claude-kit" "$(readlink "$H/b/claude-kit")"
KH="$KHB" INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes
assert_eq "4: uninstalling the second kit keeps the first kit's link" "$KHA/bin/claude-kit" "$(readlink "$H/b/claude-kit")"
KH="$KHA"

# ---------------------------------------------------------------- 5. update ignores leaked isolation env vars
real_like_home "r10-env-home"; mkdir -p "$H/leak"; printf '{"version":1}\n' > "$H/leak/hooks.json"; l0=$(tree "$H/leak")
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes
UPD_ENV="CLAUDE_KIT_CURSOR_DIR=$H/leak CLAUDE_KIT_BIN_DIR=$H/leak CLAUDE_KIT_NO_CURSOR=1 CLAUDE_KIT_NO_CLI=1" upd
assert_eq "5: update with leaked env vars: ok" 0 "$RC"
assert_tree_same "5: update ignores CLAUDE_KIT_CURSOR_DIR / BIN_DIR (nothing written there)" "$l0" "$(tree "$H/leak")"
assert_eq "5: update ignores CLAUDE_KIT_NO_CURSOR / NO_CLI (record unchanged)" "false|false" "$(rec .no_cursor)|$(rec .no_cli)"
assert_eq "5: the recorded default CLI link is still in place" "$KH/bin/claude-kit" "$(readlink "$H/.local/bin/claude-kit")"

# ---------------------------------------------------------------- 6. generic-content scan: private terms only from an external file
SC="$T/scan-copy"; mkdir -p "$SC/tests" "$SC/docs"
cp "$REPO/tests/generic-content.test.sh" "$SC/tests/"
printf 'An ordinary sentence about the zzfakeprojectqq service.\n' > "$SC/docs/note.md"
printf 'zzfakeprojectqq\n' > "$T/denylist"
out=$(env -u CLAUDE_KIT_PRIVATE_DENYLIST "$BASH_BIN" "$SC/tests/generic-content.test.sh" 2>&1); rc=$?
assert_eq "6: without CLAUDE_KIT_PRIVATE_DENYLIST the scan passes" 0 "$rc"
out=$(env CLAUDE_KIT_PRIVATE_DENYLIST="$T/denylist" "$BASH_BIN" "$SC/tests/generic-content.test.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] && pass "6: a term from the private denylist file makes the scan fail" || fail "6: private denylist" "$out"
assert_has "6: the hit is reported" "$out" "note.md"
printf 'reach me at someone@%s\n' "gmail.com" > "$SC/docs/mail.md"   # assembled at runtime: no literal address in the repo
out=$(env -u CLAUDE_KIT_PRIVATE_DENYLIST "$BASH_BIN" "$SC/tests/generic-content.test.sh" 2>&1); rc=$?
[ "$rc" -ne 0 ] && pass "6: generic checks (e-mail) still run without the denylist" || fail "6: generic email" "$out"

# ================================================================ round 11: guard bypasses
up() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
CORE="$REPO/installer/setup-core.sh"
# guard <os> <dir> -> "ok" or "refused: <why>" (dir_guard called directly, OS faked via CLAUDE_KIT_OS)
guard() {
  env -i HOME="$H" PATH="$JQ_PATH" CLAUDE_KIT_OS="$1" CLAUDE_KIT_LIB_ONLY=1 KHX="$KH" "$BASH_BIN" -c '
    . "$1"; HOME_REAL=$(realpath_of "$HOME"); KH="$KHX"
    if why=$(dir_guard "$2" "$HOME/.claude"); then echo ok; else echo "refused: $why"; fi' _ "$CORE" "$2" 2>&1
}

# ---------------------------------------------------------------- 1. case variants on a case-insensitive OS
real_like_home "r11 case home"; mkdir -p "$H/MyBin"
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --no-cli    # the kit home now exists
snap=$(tree "$H")
for bad in "--cursor-dir|/APPLICATIONS" "--cursor-dir|$(up "$H")" "--cursor-dir|$H/.CLAUDE" "--cursor-dir|$H/.CLAUDE-KIT" \
           "--bin-dir|$(up "$H")" "--bin-dir|$H/.CLAUDE" "--bin-dir|$H/.CLAUDE-KIT/bin"; do
  f="${bad%%|*}"; d="${bad#*|}"
  if [ "$f" = --cursor-dir ]; then INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cli --cursor-dir "$d"
  else INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --bin-dir "$d"; fi
  [ "$RC" -ne 0 ] && pass "1: install refuses $f $(printf '%s' "$d" | sed "s#$H#~#")" || fail "1: install refuses $f $d" "rc=0"
done
assert_tree_same "1: refused case-variant flags changed nothing" "$snap" "$(tree "$H")"
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --bin-dir "$H/MyBin"
assert_eq "1: control: a legitimate mixed-case dir (~/MyBin) is accepted" "$KH/bin/claude-kit" "$(readlink "$H/MyBin/claude-kit")"
assert_eq "1: guard folds case on macOS (fake OS): /APPLICATIONS refused" "refused" "$(guard macos /APPLICATIONS | cut -d: -f1)"
assert_eq "1: guard folds case on Windows (fake OS): /c/WINDOWS refused" "refused" "$(guard windows /c/WINDOWS | cut -d: -f1)"
case "$(uname -s)" in
  Darwin*|MINGW*|MSYS*|CYGWIN*) # round 12: a faked OS can only add refusals, never remove them
    assert_eq "1: on a case-insensitive OS a faked Linux still folds case: /APPLICATIONS refused" "refused" "$(guard linux /APPLICATIONS | cut -d: -f1)" ;;
  *) assert_eq "1: guard does not fold case on Linux: /APPLICATIONS is just a dir" "ok" "$(guard linux /APPLICATIONS)" ;;
esac
if [ -d "$(up "$H")" ]; then   # case-insensitive filesystem: an upper-cased HOME is the same directory
  for kind in cursor bin; do
    real_like_home "r11 rec home"; INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cli
    d=$(up "$H")
    if [ "$kind" = cursor ]; then tamper ".cursor_dirs = [\"$d\"] | .cursor_dir = \"$d\" | .no_cursor = false"
    else tamper ".bin_dirs = [\"$d\"] | .bin_dir = \"$d\" | .no_cli = false"; fi
    snap=$(tree "$H")
    INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes
    [ "$RC" -ne 0 ] && pass "1: uninstall refuses a recorded $kind dir = upper-cased HOME" || fail "1: uninstall upper HOME ($kind)" "rc=0"
    upd
    [ "$RC" -ne 0 ] && pass "1: update refuses a recorded $kind dir = upper-cased HOME" || fail "1: update upper HOME ($kind)" "rc=0"
    assert_tree_same "1: refused upper-cased HOME record ($kind): nothing changed" "$snap" "$(tree "$H")"
  done
else
  echo "SKIP 1: record case tests need a case-insensitive filesystem"
fi

# ---------------------------------------------------------------- 2. repeated slashes in a record
for d in //etc ///etc/; do
  real_like_home "r11 slash home"; INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cli --no-cursor
  tamper ".bin_dirs = [\"$d\"]"; snap=$(tree "$H")
  INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes
  [ "$RC" -ne 0 ] && pass "2: uninstall refuses a recorded bin dir $d" || fail "2: uninstall refuses $d" "rc=0"
  assert_tree_same "2: refused $d record: nothing changed" "$snap" "$(tree "$H")"
done

# ---------------------------------------------------------------- 3. Windows system dirs (fake OS, guard directly)
for d in /c/windows /c/Windows/System32 "/c/Program Files" "/c/Program Files (x86)" "/c/program files (x86)/Git" /c/ProgramData /c/Users /d/USERS \
         "C:/Windows" 'C:\Windows' 'C:\Program Files (x86)' 'c:\programdata'; do
  assert_eq "3: windows guard refuses $d" "refused" "$(guard windows "$d" | cut -d: -f1)"
done
assert_eq "3: windows guard accepts a user's own dir under /c/Users" "ok" "$(guard windows /c/Users/0kit-user/bin)"

# ---------------------------------------------------------------- 4. a link target with .. is not owned
real_like_home "r11 dotdot home"; mkdir -p "$H/xb" "$H/.claude-b"; printf '{}\n' > "$H/.claude-b/settings.json"
KA="$H/kitA/.claude-kit"; KB="$H/kitB/.claude-kit"
KH="$KB" INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --profile "$H/.claude-b" --yes --no-cursor --no-cli
KH="$KA" INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --profile "$H/.claude" --yes --no-cursor --bin-dir "$H/xb"
rm -f "$H/xb/claude-kit"; ln -s "$KA/../../kitB/.claude-kit/bin/claude-kit" "$H/xb/claude-kit"
KH="$KA" INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes
[ -L "$H/xb/claude-kit" ] && pass "4: kit A's uninstall keeps a link whose target only looks inside A (\$KA/../..)" || fail "4: .. link" "deleted"
KH="$H/.claude-kit"

# ================================================================ round 12: dev:inode guard, OS fake cannot weaken, speed
NFC=$(printf 'jos\303\251 home'); NFD=$(printf 'jose\314\201 home')
# ---------------------------------------------------------------- 1. same directory under another name
real_like_home "$NFC"; mkdir -p "$H/bin"; HN="$T/$NFD"
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --no-cli; snap=$(tree "$H")
XENV="LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8" INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --bin-dir "$HN"
[ "$RC" -ne 0 ] && pass "1: install refuses HOME typed in NFD (stored NFC) as --bin-dir" || fail "1: NFD HOME flag" "rc=0"
XENV="LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8" INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cli --cursor-dir "$HN/.claude"
[ "$RC" -ne 0 ] && pass "1: install refuses the profile typed in NFD as --cursor-dir" || fail "1: NFD profile flag" "rc=0"
assert_tree_same "1: refused NFD flags changed nothing" "$snap" "$(tree "$H")"
if [ -d "$HN" ]; then   # a normalization-insensitive file system (APFS): the NFD name is the same directory
  tamper ".bin_dirs = [\"$HN\"]"; snap=$(tree "$H")
  INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes
  [ "$RC" -ne 0 ] && pass "1: uninstall refuses a record naming HOME in NFD" || fail "1: NFD HOME record" "rc=0"
  assert_tree_same "1: refused NFD record changed nothing" "$snap" "$(tree "$H")"
else
  echo "SKIP 1: NFD record test needs a normalization-insensitive file system"
fi
real_like_home "r12 bs home"; mkdir -p "$H/bin"
ln -s "$H/.claude" "$H/a\\b" 2>/dev/null; ln -s "$H" "$H/c\\d" 2>/dev/null
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --no-cli
[ -L "$H/a\\b" ] || echo "SKIP 1: backslash records need a file system where \\ is a file-name character (on Windows it is a path separator)"
[ -L "$H/a\\b" ] && for v in "a\\b" "c\\d"; do
  "$REAL_JQ" --arg d "$H/$v" '.bin_dirs = [$d]' "$KH/state/install.json" > "$T/m.tmp" && cat "$T/m.tmp" > "$KH/state/install.json"; snap=$(tree "$H")
  INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes
  [ "$RC" -ne 0 ] && pass "1: uninstall refuses a record naming a backslash symlink to $( [ "$v" = "a\\b" ] && echo the profile || echo HOME)" || fail "1: backslash record $v" "rc=0"
  assert_tree_same "1: refused backslash record changed nothing ($v)" "$snap" "$(tree "$H")"
done
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --bin-dir "$H/a\\b"
[ "$RC" -ne 0 ] && pass "1: install refuses --bin-dir naming a backslash symlink to the profile" || fail "1: backslash flag" "rc=0"
ln -s "$H" "$H/home-alias"
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --bin-dir "$H/home-alias"
[ "$RC" -ne 0 ] && pass "1: install refuses a symlinked alias of HOME" || fail "1: HOME alias" "rc=0"
fl="/System/Volumes/Data$(cd -P "$H" && pwd -P)"
if [ -d "$fl" ]; then
  INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --bin-dir "$fl"
  [ "$RC" -ne 0 ] && pass "1: install refuses HOME reached through the macOS data-volume firmlink" || fail "1: firmlink" "rc=0"
fi
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --bin-dir "$H/bin"
assert_eq "1: control: a legitimate ~/bin is accepted" "$KH/bin/claude-kit" "$(readlink "$H/bin/claude-kit")"

# ---------------------------------------------------------------- 2. CLAUDE_KIT_OS cannot weaken the guard
real_like_home "r12 os home"; snap=$(tree "$H")
XENV="CLAUDE_KIT_OS=linux" INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --bin-dir "$H/.CLAUDE"
[ "$RC" -ne 0 ] && pass "2: CLAUDE_KIT_OS=linux still refuses --bin-dir ~/.CLAUDE" || fail "2: OS fake weakens guard" "rc=0"
assert_tree_same "2: nothing changed" "$snap" "$(tree "$H")"

# ---------------------------------------------------------------- 3. kit_item_owned runs no tr/sed per call
SHIM="$T/count-shim"; mkdir -p "$SHIM"; CNT3="$T/tr-sed-count"; : > "$CNT3"
for tool in tr sed; do
  real=$(command -v "$tool")
  printf '#!/bin/sh\necho %s >> "%s"\nexec %s "$@"\n' "$tool" "$CNT3" "$real" > "$SHIM/$tool"; chmod +x "$SHIM/$tool"
done
real_like_home "r12 perf home"; mkdir -p "$KH/bin" "$H/l"; : > "$KH/bin/claude-kit"
for i in 1 2 3 4 5 6 7 8 9 10; do ln -s "$KH/bin/claude-kit" "$H/l/k$i"; done
out=$(env -i HOME="$H" PATH="$JQ_PATH" CLAUDE_KIT_LIB_ONLY=1 KHX="$KH" SHIM="$SHIM" CNT="$CNT3" "$BASH_BIN" -c '
  . "$1"; HOME_REAL=$(realpath_of "$HOME"); KH="$KHX"
  kit_item_owned "$HOME/l/k1" >/dev/null   # warm-up: per-run setup may use tools once
  : > "$CNT"; PATH="$SHIM:$PATH"; n=0
  for i in 1 2 3 4 5 6 7 8 9 10; do kit_item_owned "$HOME/l/k$i" && n=$((n + 1)); done
  c=$(wc -l < "$CNT")   # read the count BEFORE any other tool runs: a "| tr" here would race the shim and count itself
  echo "owned=$n calls=$((c))"' _ "$REPO/installer/setup-core.sh" 2>&1)
assert_eq "3: kit_item_owned: 10 owned links checked with zero tr/sed processes" "owned=10 calls=0" "$out"

# ================================================================ round 13
# ---------------------------------------------------------------- 1. a candidate deeper than the walk bound
real_like_home "r13 deep home"; INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --no-cli
deep="$H/.claude"; i=0; while [ $i -lt 64 ]; do deep="$deep/a"; i=$((i + 1)); done; mkdir -p "$deep"
snap=$(tree "$H")
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --bin-dir "$deep"
[ "$RC" -ne 0 ] && pass "1: a --bin-dir 64 levels inside the profile is refused" || fail "1: deep bin dir" "rc=0"
[ ! -e "$deep/claude-kit" ] && pass "1: no link created deep inside the profile" || fail "1: deep link" "created"
assert_tree_same "1: refused deep dir changed nothing" "$snap" "$(tree "$H")"
ok10="$H/bin"; i=0; while [ $i -lt 10 ]; do ok10="$ok10/b"; i=$((i + 1)); done; mkdir -p "$ok10"
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --bin-dir "$ok10"
assert_eq "1: control: a dir 10 levels under ~/bin is accepted" "$KH/bin/claude-kit" "$(readlink "$ok10/claude-kit")"

# ---------------------------------------------------------------- 2. hooks.json pointing into a profile
real_like_home "r13 hooks home"; mkdir -p "$H/xc"; ln -s "$H/.claude/settings.json" "$H/xc/hooks.json"
snap=$(tree "$H")
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cli --cursor-dir "$H/xc"
[ "$RC" -ne 0 ] && pass "2: --cursor-dir whose hooks.json links to the profile's settings.json is refused" || fail "2: hooks.json -> settings.json" "rc=0"
assert_has "2: the refusal names the hooks.json target" "$OUT" "hooks.json"
assert_tree_same "2: refused hooks.json target: nothing changed" "$snap" "$(tree "$H")"
rm -f "$H/.cursor/hooks.json"; ln -s "$H/.claude/settings.json" "$H/.cursor/hooks.json"; snap=$(tree "$H")
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cli
[ "$RC" -ne 0 ] && pass "2: the default ~/.cursor/hooks.json linking into the profile is refused too" || fail "2: default cursor -> settings" "rc=0"
assert_tree_same "2: nothing changed (default Cursor dir)" "$snap" "$(tree "$H")"
real_like_home "r13 hooks rec home"; mkdir -p "$H/xc"; printf '{"version":1}\n' > "$H/xc/hooks.json"
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cli --cursor-dir "$H/xc"
tamper ".originals += [{\"path\": \"$H/.claude/settings.json\", \"backup\": null, \"kind\": \"cursor\"}]"; snap=$(tree "$H")
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes
[ "$RC" -ne 0 ] && pass "2: uninstall refuses a recorded Cursor hooks file inside a profile" || fail "2: record cursor original in profile" "rc=0"
assert_tree_same "2: refused record: nothing changed" "$snap" "$(tree "$H")"
tamper 'del(.originals[-1])'
rm -f "$H/xc/hooks.json"; ln -s "$H/.claude/settings.json" "$H/xc/hooks.json"; snap=$(tree "$H")
upd
[ "$RC" -ne 0 ] && pass "2: update refuses when the recorded Cursor dir's hooks.json now links into the profile" || fail "2: update hooks -> profile" "rc=0"
assert_tree_same "2: refused update: nothing changed" "$snap" "$(tree "$H")"
real_like_home "r13 dotfiles home"; d0=$(cksum < "$H/dotfiles/cursor-hooks.json")
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cli
assert_eq "2: control: hooks.json -> ~/dotfiles/cursor-hooks.json is still accepted" 0 "$RC"
[ "$(cksum < "$H/dotfiles/cursor-hooks.json")" != "$d0" ] && pass "2: control: the dotfiles target got the kit hooks" || fail "2: dotfiles merge" "unchanged"

# ================================================================ round 13b: rule for the resolved hooks.json target
cursor_target_case() { # label target-path -> sets H; ~/.cursor/hooks.json -> target
  real_like_home "$1"; rm -f "$H/.cursor/hooks.json"
  mkdir -p "$(dirname "$2")"
  [ -e "$2" ] || printf '{\n  "version": 1,\n  "hooks": { "stop": [ { "command": "echo owner" } ] }\n}\n' > "$2"
  ln -s "$2" "$H/.cursor/hooks.json"
}
# allowed: a subfolder of a profile (the owner's dotfiles layout) and HOME itself
for spec in "r13b owner home|.claude/cursor/hooks.json" "r13b homefile home|cursor-hooks.json"; do
  label="${spec%%|*}"; rel="${spec#*|}"
  real_like_home "$label"; tgt="$H/$rel"; cursor_target_case "$label" "$tgt"
  t0=$(cksum < "$tgt")
  INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cli
  assert_eq "13b: hooks.json -> ~/$rel: install ok" 0 "$RC"
  assert_eq "13b: hooks.json -> ~/$rel: the kit hooks are merged into the target" 4 \
    "$("$REAL_JQ" '[.hooks[][] | select(.command | contains("/cursor/hooks/"))] | length' "$tgt" 2>/dev/null)"
  INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --uninstall --yes
  assert_eq "13b: hooks.json -> ~/$rel: uninstall restores the target byte-identical" "$t0" "$(cksum < "$tgt")"
  [ -L "$H/.cursor/hooks.json" ] && pass "13b: hooks.json -> ~/$rel: the symlink survives" || fail "13b: symlink kept ($rel)" "replaced"
done
# still refused, nothing changed
for spec in ".claude/settings.json" ".claude/CLAUDE.md" "KH/anything.json" "/etc/x.json"; do
  real_like_home "r13b refuse home"; INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cursor --no-cli
  case "$spec" in
    KH/*) tgt="$KH/${spec#KH/}"; printf '{"version":1}\n' > "$tgt" ;;
    /*) tgt="$spec" ;;
    *) tgt="$H/$spec"; [ -e "$tgt" ] || printf '# x\n' > "$tgt" ;;
  esac
  rm -f "$H/.cursor/hooks.json"; ln -s "$tgt" "$H/.cursor/hooks.json"
  snap=$(tree "$H")
  INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes --no-cli
  [ "$RC" -ne 0 ] && pass "13b: hooks.json -> $spec is refused" || fail "13b: refuse $spec" "rc=0"
  assert_tree_same "13b: hooks.json -> $spec: nothing changed" "$snap" "$(tree "$H")"
done

finish

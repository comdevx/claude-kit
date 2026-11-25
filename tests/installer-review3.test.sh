#!/bin/bash
# Regression tests for the third verifier round (B): manifest robustness - newline paths, narrowed
# special roots, filtered profile list in cleanup, preflight backup dirs (incl. ~/.cursor), merging a
# declined leftover kit home, recording kit content found in place, identity messages for null keys.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$(dirname "${BASH_SOURCE[0]}")/installer-lib.sh"
build_dist
basic_home() { new_home "$1"; P="$H/.claude"; mkdir -p "$P"; printf '{"theme":"m"}\n' > "$P/settings.json"; }
craft() { "$REAL_JQ" "$@" "$KH/state/install.json" > "$T/m.tmp" && cat "$T/m.tmp" > "$KH/state/install.json"; }

# ---------------------------------------------------------------- B1 newline in manifest paths
basic_home "b1 home"; run_inst --all --yes
mkdir -p "$H/victimprof/data"; printf 'v\n' > "$H/victimprof/data/f"
craft --arg pp "$P
$H/victimprof" --arg c "$H/victimprof/data" '.profiles += [$pp] | .created += [{type: "copy", path: $c}]'
run_inst --uninstall --yes
[ -f "$H/victimprof/data/f" ] && pass "B1 a profile path with a newline cannot smuggle in an allowed root" || fail "B1 newline profile" "deleted"
assert_has "B1 skipped newline entries are reported" "$OUT" "newline"

# ---------------------------------------------------------------- B2 narrowed special roots
basic_home "b2 home"; mkdir -p "$H/.local/bin" "$H/bin" "$H/.cursor"
run_inst --all --yes
mkdir -p "$H/.local/bin/other" "$H/bin/tool" "$H/.cursor/precious"
printf 'x\n' > "$H/.local/bin/other/f"; printf 'x\n' > "$H/bin/tool/f"; printf 'x\n' > "$H/.cursor/precious/f"
ln -s "$KH/bin/claude-kit" "$H/.local/bin/not-claude-kit"
craft --arg a "$H/.local/bin/other" --arg b "$H/bin/tool" --arg c "$H/.cursor/precious" --arg l "$H/.local/bin/not-claude-kit" --arg t "$KH/bin/claude-kit" \
  '.created += [{type: "copy", path: $a}, {type: "copy", path: $b}, {type: "copy", path: $c}, {type: "link", path: $l, target: $t}]'
run_inst --uninstall --yes
[ -f "$H/.local/bin/other/f" ] && pass "B2 ~/.local/bin: crafted copy entry deletes nothing" || fail "B2 .local/bin copy" "deleted"
[ -f "$H/bin/tool/f" ] && pass "B2 ~/bin: crafted copy entry deletes nothing" || fail "B2 bin copy" "deleted"
[ -f "$H/.cursor/precious/f" ] && pass "B2 ~/.cursor: crafted copy entry deletes nothing" || fail "B2 cursor copy" "deleted"
[ -L "$H/.local/bin/not-claude-kit" ] && pass "B2 ~/.local/bin: only a link named claude-kit may be removed" || fail "B2 other link" "removed"

# ---------------------------------------------------------------- B3 cleanup uses the filtered profile list
basic_home "b3 home"; run_inst --all --yes
mkdir -p "$H/sub" "$H/rel/prof"; printf 'mine\n\n<!-- claude-kit:begin -->\n@x/rules/core.md\n<!-- claude-kit:end -->\n' > "$H/rel/prof/CLAUDE.md"
mkdir -p "$H/dots/prof"; cp "$H/rel/prof/CLAUDE.md" "$H/dots/prof/CLAUDE.md"
c_rel=$(cksum < "$H/rel/prof/CLAUDE.md")
craft --arg d "$H/dots/x/../prof" '.profiles += ["rel/prof", $d]'
RUN_CWD="$H" run_inst --uninstall --yes
assert_eq "B3 relative recorded profile: its CLAUDE.md is not touched" "$c_rel" "$(cksum < "$H/rel/prof/CLAUDE.md")"
assert_eq "B3 recorded profile with .. segments: its CLAUDE.md is not touched" "$c_rel" "$(cksum < "$H/dots/prof/CLAUDE.md")"

# ---------------------------------------------------------------- B4 preflight backup dirs (incl. ~/.cursor)
basic_home "b4 home"; mkdir -p "$H/.cursor"; printf '{"version":1}\n' > "$H/.cursor/hooks.json"; printf 'file\n' > "$H/.cursor/.claude-kit-backups"
before=$(tree "$H")
run_inst --all --yes
[ "$RC" -ne 0 ] && pass "B4 ~/.cursor/.claude-kit-backups is a file: refused up front" || fail "B4 cursor backups file" "rc=0"
assert_tree_same "B4 ~/.cursor backups blocked: nothing changed" "$before" "$(tree "$H")"
basic_home "b4b home"; mkdir -p "$P/.claude-kit-backups"; chmod 555 "$P/.claude-kit-backups"; before=$(tree "$H")
if [ -w "$P/.claude-kit-backups" ]; then
  echo "SKIP B4 unwritable .claude-kit-backups: permissions are not enforced here (root or Windows)"
else
  run_inst --all --yes
  [ "$RC" -ne 0 ] && pass "B4 existing but unwritable .claude-kit-backups: refused up front" || fail "B4 unwritable backups" "rc=0"
  assert_tree_same "B4 unwritable backups: nothing changed" "$before" "$(tree "$H")"
fi
chmod 755 "$P/.claude-kit-backups"

# ---------------------------------------------------------------- B5 declined / non-interactive leftover restore
basic_home "b5 home"; mkdir -p "$H/.claude-two"; printf '{}\n' > "$H/.claude-two/settings.json"; printf '# two\n' > "$H/.claude-two/CLAUDE.md"
before=$(tree "$H")
run_inst --all --yes
MVS="$T/shim-mv"; mkdir -p "$MVS"
cat > "$MVS/mv" <<SH
#!/bin/bash
last=""; for a in "\$@"; do last="\$a"; done
case "\$1" in *.new.*) [ "\$last" = "$KH" ] && /bin/mkdir -p "$KH/intruder" ;; esac
exec /bin/mv "\$@"
SH
chmod +x "$MVS/mv"
INST_PATH="$MVS:$JQ_PATH" run_inst --all --yes
rm -rf "$KH"
run_inst --all                       # no terminal, no --yes: the restore question is answered "no"
assert_eq "B5 leftover declined (no TTY): install still ok" 0 "$RC"
assert_has "B5 leftover declined: its install record is merged" "$OUT" "merged"
run_inst --uninstall --yes
dangling=$(find "$H" -type l ! -exec test -e {} \; -print 2>/dev/null | grep -v '\.claude-kit\.old\.' )
assert_empty "B5 no dangling links after uninstall" "$dangling"
after=$(tree "$H" skip | grep -v '\.claude-kit\.old\.')
assert_tree_same "B5 leftover merged: uninstall byte-identical (backups and the old kit dir aside)" "$before" "$after"

# kit content found in place without any record (kit home deleted by hand) is recorded on install
basic_home "b5b home"; printf '# mine\n' > "$P/CLAUDE.md"; before=$(tree "$H")
run_inst --all --yes
rm -rf "$KH"
run_inst --all --yes
run_inst --uninstall --yes
dangling=$(find "$H" -type l ! -exec test -e {} \; -print 2>/dev/null)
assert_empty "B5 kit links found in place are recorded and removed (no dangling links)" "$dangling"
assert_tree_same "B5 kit content found in place: uninstall restores the oldest kit-made backup" "$before" "$(tree "$H" skip)"

# ---------------------------------------------------------------- B6 identity message names null-vs-absent keys
new_home "b6 home"; mkdir -p "$H/.claude" "$H/.claude-b"
printf '{"model":null}\n' > "$H/.claude/settings.json"; printf '{}\n' > "$H/.claude-b/settings.json"
run_inst --all --mode shared --yes
assert_has "B6 identity message names a key that is null on one side and absent on the other" "$OUT" "keys are not identical to the primary's (model)"

# ---------------------------------------------------------------- round 4 C: ~/.cursor/hooks.json is a symlink (dotfiles)
basic_home "c4 home"; mkdir -p "$H/.cursor" "$H/dotfiles"
printf '{\n  "version": 1,\n  "hooks": { "stop": [ { "command": "echo dotfiles" } ] }\n}\n' > "$H/dotfiles/cursor-hooks.json"
ln -s "$H/dotfiles/cursor-hooks.json" "$H/.cursor/hooks.json"
orig=$(cksum < "$H/dotfiles/cursor-hooks.json")
run_inst --all --yes
assert_eq "C: install merges into the symlink target" 4 "$("$REAL_JQ" '[.hooks[][] | select(.command | contains("/cursor/hooks/"))] | length' "$H/dotfiles/cursor-hooks.json")"
run_inst --uninstall --yes
assert_eq "C: uninstall restores the dotfiles target byte-identical" "$orig" "$(cksum < "$H/dotfiles/cursor-hooks.json")"
[ -L "$H/.cursor/hooks.json" ] && pass "C: ~/.cursor/hooks.json is still a symlink" || fail "C: symlink kept" "replaced"
basic_home "c4b home"; mkdir -p "$H/.cursor" "$H/dotfiles"; printf '{"version":1}\n' > "$H/dotfiles/h.json"
ln -s "$H/dotfiles/h.json" "$H/.cursor/hooks.json"; printf 'file\n' > "$H/dotfiles/.claude-kit-backups"; before=$(tree "$H")
run_inst --all --yes
[ "$RC" -ne 0 ] && pass "C: preflight checks the backups dir next to the symlink target" || fail "C: preflight target backups" "rc=0"
assert_tree_same "C: blocked target backups dir: nothing changed" "$before" "$(tree "$H")"

# ---------------------------------------------------------------- round 5 item 5: build without zip, Python 3 named `python`
PYREAL=$(command -v python3 2>/dev/null)
if [ -n "$PYREAL" ] && "$PYREAL" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then
  NB="$T/nozip-bin"; mkdir -p "$NB"
  for f in "$NOJQ_BIN"/*; do n="${f##*/}"; case "$n" in zip|python|python3|python3.*) continue ;; esac; ln -s "$f" "$NB/$n" 2>/dev/null; done
  ln -s "$PYREAL" "$NB/python"
  out=$(env -i HOME="$T" PATH="$NB" TMPDIR="$T/tmp" "$BASH_BIN" "$REPO/build-release.sh" --worktree --version 0-nozip --out "$T/dist-nozip" 2>&1); rc=$?
  assert_eq "5: build-release works with no zip and Python 3 named python (exit 0)" 0 "$rc"
  [ -s "$T/dist-nozip/install.ps1" ] && pass "5: install.ps1 built through the python fallback" || fail "5: install.ps1 via python" "$out"
else
  echo "SKIP 5: no Python 3 on this machine"
fi

finish

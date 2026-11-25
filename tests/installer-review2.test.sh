#!/bin/bash
# Regression tests for the second verifier round: #2 policy, NEW-B (whole profile Independent when its
# settings.json cannot be linked), #17 path hardening, NEW-A (update never rewrites the manifest),
# backup_file failures, CRLF without final newline, #13 leftover kit home, #14 iex exit handling.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$(dirname "${BASH_SOURCE[0]}")/installer-lib.sh"
build_dist
PSTMPL="$REPO/installer/install.ps1.tmpl"
basic_home() { new_home "$1"; P="$H/.claude"; mkdir -p "$P"; printf '{"model":"m"}\n' > "$P/settings.json"; }

# ---------------------------------------------------------------- #2 policy + NEW-B
new_home "p2 home"; P="$H/.claude"; S="$H/.claude-b"; mkdir -p "$P/hooks" "$P/agents" "$S"
printf '{"env":{"ANTHROPIC_BASE_URL":"https://gw.example"}}\n' > "$P/settings.json"
printf '{"theme":"light"}\n' > "$S/settings.json"
run_inst --all --mode shared --yes
assert_eq "#2 primary has identity keys, secondary none: install ok" 0 "$RC"
[ ! -L "$S/settings.json" ] && pass "#2 identity key sets differ (primary only): settings.json NOT linked" || fail "#2 not linked" "linked"
for item in CLAUDE.md skills commands agents hooks; do
  [ ! -L "$S/$item" ] && pass "NEW-B profile with unlinked settings: $item not linked to the primary" || fail "NEW-B $item not linked" "$(readlink "$S/$item")"
done
assert_eq "NEW-B secondary gets the Independent install (own block + own kit merge)" "1|$KIT_N" \
  "$(grep -c 'claude-kit:begin' "$S/CLAUDE.md" 2>/dev/null)|$(kit_cmd_count "$S/settings.json")"
assert_has "NEW-B prints one line why" "$OUT" "installed in Independent mode instead"

new_home "p2b home"; P="$H/.claude"; S="$H/.claude-b"; mkdir -p "$P/hooks" "$S/hooks"
printf '{}\n' > "$P/settings.json"; printf 'echo primary\n' > "$P/hooks/p.sh"
printf '#!/bin/bash\necho my-guard-ran\n' > "$S/hooks/my-guard.sh"
cat > "$S/settings.json" <<'J'
{"env":{"ANTHROPIC_API_KEY_HELPER":"x"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash ~/.claude-b/hooks/my-guard.sh"}]}]}}
J
run_inst --all --mode shared --yes
assert_eq "NEW-B repro: install ok" 0 "$RC"
[ -d "$S/hooks" ] && [ ! -L "$S/hooks" ] && pass "NEW-B repro: the secondary's own hooks dir is kept (not linked)" || fail "NEW-B hooks kept" "$(readlink "$S/hooks")"
cmd=$("$REAL_JQ" -r '.hooks.PreToolUse[] | .hooks[] | select(.command | contains("my-guard")) | .command' "$S/settings.json")
hout=$(env -i HOME="$H" PATH="$JQ_PATH" "$BASH_BIN" -c "$cmd" 2>&1)
assert_eq "NEW-B repro: the user's hook command still runs" "my-guard-ran" "$hout"
before=$(tree "$H"); run_inst --uninstall --yes
assert_eq "NEW-B repro: uninstall ok" 0 "$RC"

new_home "p2c home"; P="$H/.claude"; S="$H/.claude-b"; mkdir -p "$P" "$S"
printf '{}\n' > "$P/settings.json"; printf '{"theme":"x"}\n' > "$S/settings.json"
run_inst --all --mode shared --yes
assert_eq "#2 both identity key sets empty: settings.json linked" "$P/settings.json" "$(readlink "$S/settings.json")"
assert_has "#2 README states the identical-key-set rule" "$(cat "$REPO/README.md")" "identical on both sides"

# ---------------------------------------------------------------- #17 path hardening
basic_home "p17 home"
mkdir -p "$H/sub"
run_inst --all --yes
mkdir -p "$H/victim/data"; printf 'v1\n' > "$H/victim/data/f"
printf 'v2\n' > "$H/victim2.txt"; mkdir -p "$H/victim3"; printf 'v3\n' > "$H/victim3/f"
PARENT=$(dirname "$H"); printf 'pv\n' > "$PARENT/parent-victim-$$"
printf 'hv\n' > "$H/home-victim"
M="$KH/state/install.json"
"$REAL_JQ" --arg a "$P/../victim/data" --arg par "$PARENT" --arg pv "$PARENT/parent-victim-$$" --arg h "$H" --arg hv "$H/home-victim" \
  '.created += [{type: "copy", path: $a}, {type: "copy", path: "../victim2.txt"}, {type: "dir", path: "../victim3"},
                {type: "copy", path: $pv}, {type: "copy", path: $hv}]
   | .profiles += [$par, $h]' "$M" > "$T/m3" && cat "$T/m3" > "$M"
RUN_CWD="$H/sub" run_inst --uninstall --yes
[ -f "$H/victim/data/f" ] && pass "#17 ~/.claude/../victim/data: nothing deleted" || fail "#17 /../ path" "deleted"
[ -f "$H/victim2.txt" ] && pass "#17 relative ../victim2.txt: nothing deleted" || fail "#17 relative file" "deleted"
[ -f "$H/victim3/f" ] && pass "#17 relative ../victim3: nothing deleted" || fail "#17 relative dir" "deleted"
[ -f "$PARENT/parent-victim-$$" ] && pass "#17 profile = parent of HOME is not an allowed root" || fail "#17 parent-of-HOME" "deleted"
[ -f "$H/home-victim" ] && pass "#17 profile = HOME is not an allowed root" || fail "#17 HOME profile" "deleted"
rm -f "$PARENT/parent-victim-$$"

# ---------------------------------------------------------------- NEW-A update never rewrites the manifest
REL="$T/release"; "$BASH_BIN" "$REPO/build-release.sh" --worktree --version 9.9.11-test --out "$REL" > "$T/rel.log" 2>&1 || fail "release build" "$(cat "$T/rel.log")"
new_home "pA home"; mkdir -p "$H/.claude" "$H/.claude-old"; printf '{}\n' > "$H/.claude/settings.json"; printf '{"theme":"o"}\n' > "$H/.claude-old/settings.json"
before_old=$(tree "$H/.claude-old")
run_inst --all --yes
mv "$H/.claude-old" "$H/.claude-old.away"
XENV="CLAUDE_KIT_RELEASE_URL=file://$REL" run_cli update --dry-run
assert_eq "NEW-A update --dry-run with a missing profile: exit 0" 0 "$RC"
XENV="CLAUDE_KIT_RELEASE_URL=file://$REL" run_cli update
assert_eq "NEW-A update with a missing profile: exit 0" 0 "$RC"
[ ! -e "$H/.claude-old" ] && pass "NEW-A update does not recreate the missing profile" || fail "NEW-A recreated" "exists"
assert_has "NEW-A missing profile stays recorded" "$("$REAL_JQ" -r '.profiles | join(",")' "$KH/state/install.json")" "$H/.claude-old"
mv "$H/.claude-old.away" "$H/.claude-old"
run_inst --uninstall --yes
assert_eq "NEW-A uninstall after the profile came back: kit hooks removed" 0 "$(kit_cmd_count "$H/.claude-old/settings.json")"
assert_tree_same "NEW-A uninstall after the profile came back: profile byte-identical" "$before_old" "$(tree "$H/.claude-old" skip)"

# ---------------------------------------------------------------- backup_file failure stops before editing
basic_home "pB home"; printf 'not a dir\n' > "$P/.claude-kit-backups"; printf '# mine\n' > "$P/CLAUDE.md"
before=$(tree "$H")
run_inst --all --yes
[ "$RC" -ne 0 ] && pass "backup dir blocked by a plain file: install refused" || fail "backup blocked refused" "rc=0"
assert_tree_same "backup dir blocked by a plain file: nothing edited" "$before" "$(tree "$H")"

# ---------------------------------------------------------------- #5 CRLF without a final newline
basic_home "p5 home"; printf '# Mine\r\nkeep' > "$P/CLAUDE.md"; before=$(tree "$H")
run_inst --all --yes; run_inst --all --yes
assert_eq "#5 CRLF, no final newline: one block" 1 "$(grep -c 'claude-kit:begin' "$P/CLAUDE.md")"
run_inst --uninstall --yes
assert_tree_same "#5 CRLF, no final newline: uninstall byte-identical" "$before" "$(tree "$H" skip)"

# ---------------------------------------------------------------- #13 leftover .old.N after a failed swap
basic_home "p13 home"; before=$(tree "$H")
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
[ "$RC" -ne 0 ] && pass "#13 swap race still detected" || fail "#13 race" "rc=0"
assert_has "#13 failure message says how to restore" "$OUT" "rename"
rm -rf "$KH"                      # the user removes the stray directory, as the message says
run_inst --all --yes
assert_eq "#13 next run: exit 0" 0 "$RC"
assert_has "#13 next run restores the leftover previous kit home" "$OUT" "restored the previous kit home"
[ -z "$(ls -d "$H"/.claude-kit.old.* 2>/dev/null)" ] && pass "#13 no .old.N left after restoring" || fail "#13 leftover" "$(ls -d "$H"/.claude-kit.old.*)"
run_inst --uninstall --yes
assert_tree_same "#13 uninstall after the restore: HOME byte-identical (first-run records kept)" "$before" "$(tree "$H" skip)"

# ---------------------------------------------------------------- #14 iex inside a caller script (static: no pwsh here)
assert_has "#14 install.ps1 sets \$global:LASTEXITCODE instead of exiting under iex" "$(cat "$PSTMPL")" '$global:LASTEXITCODE = $kitCode'
assert_not_has "#14 install.ps1 does not decide on \$PSCommandPath (inherited from a caller script under iex)" "$(cat "$PSTMPL")" 'if ($PSCommandPath) { exit'

finish

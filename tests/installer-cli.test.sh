#!/bin/bash
# The installed claude-kit CLI: status, profiles --list, doctor (healthy and broken), update
# against a local fake release (good and bad checksum), uninstall guard.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$(dirname "${BASH_SOURCE[0]}")/installer-lib.sh"
build_dist 1.0.0-test

new_home "cli home"
mkdir -p "$H/.claude" "$H/.claude-two"; printf '{"theme":"m"}\n' > "$H/.claude/settings.json"; printf '{}\n' > "$H/.claude-two/settings.json"
run_inst --all --mode shared --yes
assert_eq "setup: shared install ok" 0 "$RC"

run_cli status
assert_eq "status: exit 0" 0 "$RC"
assert_has "status: version" "$OUT" "claude-kit 1.0.0-test"
assert_has "status: mode and primary" "$OUT" "mode: shared (primary ~/.claude, share config)"
assert_has "status: secondary shown as shared" "$OUT" "~/.claude-two: shared"

run_cli profiles --list
assert_eq "profiles --list: both profiles" "$(printf '%s\n%s' "$H/.claude" "$H/.claude-two")" "$(printf '%s\n' "$OUT" | cut -f1)"

s0=$(tree "$H")
run_cli profiles --all --mode shared --dry-run
assert_eq "profiles (reconfigure, dry-run): exit 0" 0 "$RC"
assert_has "profiles reconfigures from the kit home in place" "$OUT" "reconfiguring in place"
assert_tree_same "profiles --dry-run changes nothing" "$s0" "$(tree "$H")"

run_cli doctor
assert_eq "doctor after install: exit 0" 0 "$RC"
assert_has "doctor after install: all checks passed" "$OUT" "doctor: all checks passed"
assert_has "doctor checks the rules cap" "$OUT" "rules/code.md"
assert_has "doctor checks hook paths" "$OUT" "$KIT_N kit hooks registered and resolving"

# broken: a shared link replaced by a regular file, a kit skill link left dangling, a hook script gone
mv "$H/.claude-two/settings.json" "$T/link.bak"; printf '{}\n' > "$H/.claude-two/settings.json"
run_cli doctor
[ "$RC" -ne 0 ] && pass "doctor flags a shared link that is no longer a link" || fail "doctor flags replaced link" "$OUT"
assert_has "doctor: names the broken shared link" "$OUT" "~/.claude-two/settings.json is no longer a link"
rm -f "$H/.claude-two/settings.json"; mv "$T/link.bak" "$H/.claude-two/settings.json"
mv "$KH/skills/recheck" "$T/recheck.bak"
run_cli doctor
[ "$RC" -ne 0 ] && pass "doctor flags a dangling kit skill link" || fail "doctor flags dangling link" "$OUT"
assert_has "doctor: names the dangling link" "$OUT" "skills/recheck is a broken link"
mv "$T/recheck.bak" "$KH/skills/recheck"
mv "$KH/hooks/stop-gate.sh" "$T/sg.bak"
run_cli doctor
assert_has "doctor flags a hook path that does not resolve" "$OUT" "hook path does not resolve"
mv "$T/sg.bak" "$KH/hooks/stop-gate.sh"
run_cli doctor
assert_eq "doctor healthy again after repair" 0 "$RC"

# ---------------------------------------------------------------- update
REL="$T/release"
"$BASH_BIN" "$REPO/build-release.sh" --worktree --version 2.0.0-test --out "$REL" > "$T/rel.log" 2>&1 || fail "build fake release" "$(cat "$T/rel.log")"
s1=$(cksum < "$H/.claude/settings.json")

cp "$REL/install.sh" "$T/good.sh"; printf 'echo tampered\n' >> "$REL/install.sh"
XENV="CLAUDE_KIT_RELEASE_URL=$(file_url "$REL")" run_cli update
[ "$RC" -ne 0 ] && pass "update with a bad checksum: refused" || fail "update bad checksum refused" "$OUT"
assert_has "update with a bad checksum: says why" "$OUT" "checksum mismatch"
assert_eq "update with a bad checksum: version unchanged" "1.0.0-test" "$(cat "$KH/VERSION")"
cp "$T/good.sh" "$REL/install.sh"

# HOME spelled with a "//" (a TMPDIR ending in "/" does that) while the CLI finds its kit home via pwd:
# the hook commands must keep the portable $HOME form (regression: they turned absolute on update).
HOME_ARG="$T//cli home" XENV="CLAUDE_KIT_RELEASE_URL=$(file_url "$REL")" run_cli update
assert_eq "update with a good checksum: exit 0" 0 "$RC"
assert_has "update: checksum verified" "$OUT" "checksum verified"
assert_eq "update: new version installed" "2.0.0-test" "$(cat "$KH/VERSION")"
assert_eq "update: recorded mode re-applied" "shared" "$("$REAL_JQ" -r .mode "$KH/state/install.json")"
assert_eq "update: settings unchanged (same kit hooks, no duplicates)" "$s1" "$(cksum < "$H/.claude/settings.json")"
assert_eq "update: hook commands keep the \$HOME form" 0 "$(grep -c "$T" "$H/.claude/settings.json")"
assert_eq "update: secondary still linked" "$H/.claude/settings.json" "$(readlink "$H/.claude-two/settings.json")"

run_cli update
[ "$RC" -ne 0 ] && pass "update without a configured release URL: refused" || fail "unconfigured URL refused" "$OUT"
assert_has "update without a configured release URL: explains" "$OUT" "CLAUDE_KIT_RELEASE_URL"

# ---------------------------------------------------------------- uninstall guard and run
before=$(tree "$H")
run_cli uninstall
assert_eq "uninstall without --yes and no terminal: exit 2" 2 "$RC"
assert_tree_same "uninstall without --yes: nothing changed" "$before" "$(tree "$H")"
run_cli uninstall --yes
assert_eq "claude-kit uninstall --yes: exit 0" 0 "$RC"
[ ! -e "$KH" ] && pass "uninstall removes the kit home last" || fail "kit home removed" "$(ls "$KH")"
assert_eq "uninstall restores the secondary's original settings" "{}" "$(cat "$H/.claude-two/settings.json")"
assert_eq "uninstall restores the primary's original settings" '{"theme":"m"}' "$(cat "$H/.claude/settings.json")"

finish

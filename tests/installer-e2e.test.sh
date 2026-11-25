#!/bin/bash
# Installer e2e: runs the BUILT dist/install.sh in temp HOMEs (one with a space in its path).
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$(dirname "${BASH_SOURCE[0]}")/installer-lib.sh"
build_dist

# ---------------------------------------------------------------- refusals change nothing
new_home "refuse home"
mkdir -p "$H/.claude"; printf '{"model":"m"}\n' > "$H/.claude/settings.json"
before=$(tree "$H")

run_inst
assert_eq "no TTY + no flags: exit 2" 2 "$RC"
assert_has "no TTY + no flags: prints usage" "$OUT" "Usage: bash install.sh"
assert_tree_same "no TTY + no flags: nothing changed" "$before" "$(tree "$H")"

INST_PATH="$NOJQ_BIN" run_inst --all
assert_eq "missing jq: exit 3" 3 "$RC"
assert_has "missing jq: says jq is required" "$OUT" "jq is required"
assert_tree_same "missing jq: nothing changed" "$before" "$(tree "$H")"

cp "$DIST/install.sh" "$T/tampered.sh"
line=$(( $(wc -l < "$T/tampered.sh") - 40 ))
awk -v n="$line" 'NR == n { c = substr($0, 10, 1); r = (c == "A") ? "B" : "A"; $0 = substr($0, 1, 9) r substr($0, 11) } { print }' "$T/tampered.sh" > "$T/t2" && mv "$T/t2" "$T/tampered.sh"
if cmp -s "$DIST/install.sh" "$T/tampered.sh"; then fail "tamper fixture" "file unchanged"; fi
INSTALLER="$T/tampered.sh" run_inst --all --yes
assert_eq "corrupted payload: exit 3" 3 "$RC"
assert_has "corrupted payload: refuses with checksum message" "$OUT" "checksum mismatch"
assert_tree_same "corrupted payload: nothing changed" "$before" "$(tree "$H")"

head -n 100 "$DIST/install.sh" > "$T/truncated.sh"
INSTALLER="$T/truncated.sh" run_inst --all --yes
[ "$RC" -ne 0 ] && pass "truncated installer: refused (rc=$RC)" || fail "truncated installer: refused" "rc=0"
assert_tree_same "truncated installer: nothing changed" "$before" "$(tree "$H")"

printf '{"model": broken\n' > "$H/.claude/settings.json"; before=$(tree "$H")
run_inst --all --yes
[ "$RC" -ne 0 ] && pass "invalid settings.json: refused" || fail "invalid settings.json: refused" "rc=0"
assert_has "invalid settings.json: names the file" "$OUT" "settings.json is not a valid settings JSON"
assert_tree_same "invalid settings.json: nothing changed (no kit home either)" "$before" "$(tree "$H")"

printf '{}\n' > "$H/.claude/settings.json"; printf 'mine\n<!-- claude-kit:begin -->\nhalf\n' > "$H/.claude/CLAUDE.md"; before=$(tree "$H")
run_inst --all --yes
[ "$RC" -ne 0 ] && pass "broken CLAUDE.md block: refused" || fail "broken CLAUDE.md block: refused" "rc=0"
assert_tree_same "broken CLAUDE.md block: nothing changed" "$before" "$(tree "$H")"

# ---------------------------------------------------------------- fresh install (HOME with a space)
new_home "fresh home"
run_inst --all --yes
assert_eq "fresh install: exit 0" 0 "$RC"
P="$H/.claude"
[ -d "$P" ] && pass "fresh install: created ~/.claude when no profile existed" || fail "fresh install: created ~/.claude" "$OUT"
assert_eq "fresh install: VERSION in kit home" "9.9.9-test" "$(cat "$KH/VERSION" 2>/dev/null)"
assert_eq "fresh install: CLAUDE.md is exactly the managed block" \
  "$(printf '<!-- claude-kit:begin -->\n@~/.claude-kit/rules/core.md\n<!-- claude-kit:end -->')" "$(cat "$P/CLAUDE.md")"
valid_json "$(cat "$P/settings.json")" && pass "fresh install: settings.json valid" || fail "fresh install: settings.json valid" "$(cat "$P/settings.json")"
assert_eq "fresh install: 9 kit hook commands" "$KIT_N" "$(kit_cmd_count "$P/settings.json")"
assert_has "fresh install: hook commands use the portable \$HOME form" "$(cat "$P/settings.json")" 'bash \"$HOME/.claude-kit/hooks/session-start.sh\" discipline'
assert_eq "fresh install: skill symlink into the kit" "$KH/skills/fable-method" "$(readlink "$P/skills/fable-method")"
assert_eq "fresh install: command symlink into the kit" "$KH/commands/test-audit.md" "$(readlink "$P/commands/test-audit.md")"
[ ! -e "$P/skills/MANIFEST.md" ] && pass "fresh install: skills/MANIFEST.md is not linked as a skill" || fail "MANIFEST.md not a skill" "linked"
assert_eq "fresh install: manifest records the profile" "$P" "$("$REAL_JQ" -r '.profiles[0]' "$KH/state/install.json")"
for f in tests build-release.sh installer/install.sh.tmpl; do
  [ ! -e "$KH/$f" ] && pass "payload excludes $f" || fail "payload excludes $f" "present"
done
[ -x "$KH/bin/claude-kit" ] && [ -f "$KH/installer/setup-core.sh" ] && pass "payload includes bin/claude-kit and setup-core.sh" || fail "payload includes CLI" "missing"

# The registered hook command really runs (through bash, with this HOME containing a space).
cmd=$("$REAL_JQ" -r '.hooks.SessionStart[0].hooks[0].command' "$P/settings.json")
hook_out=$(printf '{"session_id":"e2e","source":"startup","cwd":"%s","model":"claude-sonnet-x"}' "$T" \
  | env -i HOME="$H" PATH="$JQ_PATH" "$BASH_BIN" -c "$cmd" 2>&1)
ctx=$(ctx_of "$hook_out")
[ -n "$ctx" ] && pass "registered SessionStart hook runs and injects the discipline rules" || fail "registered hook runs" "$hook_out"

s1=$(cksum < "$P/settings.json"); c1=$(cksum < "$P/CLAUDE.md"); t1=$(tree "$P")
run_inst --all --yes
assert_eq "re-run: exit 0" 0 "$RC"
assert_eq "re-run: settings.json byte-identical" "$s1" "$(cksum < "$P/settings.json")"
assert_eq "re-run: CLAUDE.md byte-identical" "$c1" "$(cksum < "$P/CLAUDE.md")"
assert_eq "re-run: still 9 kit hooks (no duplicates)" "$KIT_N" "$(kit_cmd_count "$P/settings.json")"
assert_eq "re-run: one managed block" 1 "$(grep -c 'claude-kit:begin' "$P/CLAUDE.md")"
assert_tree_same "re-run: profile tree identical (no new backups or links)" "$t1" "$(tree "$P")"
assert_eq "re-run: manifest has no duplicate entries" \
  "$("$REAL_JQ" '.created | length' "$KH/state/install.json")" "$("$REAL_JQ" '.created | unique_by(.path) | length' "$KH/state/install.json")"

run_inst --uninstall --yes
assert_eq "fresh uninstall: exit 0" 0 "$RC"
assert_eq "fresh uninstall: HOME is empty again" "D ." "$(tree "$H")"

# ---------------------------------------------------------------- existing user content is preserved
new_home "user home"
P="$H/.claude"; mkdir -p "$P/skills/fable-method" "$P/commands"
printf '# My rules\nAlways be nice.' > "$P/CLAUDE.md"   # no trailing newline on purpose
cat > "$P/settings.json" <<'EOF'
{
  "model": "opus",
  "permissions": { "allow": ["Bash(ls:*)"] },
  "env": { "FOO": "bar" },
  "hooks": {
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "echo user-pre" } ] } ],
    "Stop": [ { "hooks": [ { "type": "command", "command": "echo user-stop" } ] } ]
  }
}
EOF
printf 'my own skill\n' > "$P/skills/fable-method/SKILL.md"
printf 'my own command\n' > "$P/commands/test-audit.md"
before=$(tree "$H")

run_inst --all --dry-run
assert_eq "dry-run: exit 0" 0 "$RC"
assert_has "dry-run: prints planned changes" "$OUT" "[dry-run] would merge $KIT_N kit hook entries"
assert_has "dry-run: plans the CLAUDE.md block" "$OUT" "[dry-run] would add the claude-kit block"
assert_tree_same "dry-run: whole HOME tree unchanged (no kit home, no backups)" "$before" "$(tree "$H")"

run_inst --profile "~/.claude"
assert_eq "user install: exit 0" 0 "$RC"
case "$(cat "$P/CLAUDE.md")" in "# My rules
Always be nice.
"*) pass "user CLAUDE.md content kept above the block" ;; *) fail "user CLAUDE.md content kept" "$(cat "$P/CLAUDE.md")" ;; esac
assert_eq "user CLAUDE.md: one block" 1 "$(grep -c 'claude-kit:begin' "$P/CLAUDE.md")"
assert_eq "user settings: other keys kept" '"opus"|["Bash(ls:*)"]|"bar"' \
  "$("$REAL_JQ" -c '.model' "$P/settings.json")|$("$REAL_JQ" -c '.permissions.allow' "$P/settings.json")|$("$REAL_JQ" -c '.env.FOO' "$P/settings.json")"
assert_eq "user settings: user hooks kept" "echo user-pre|echo user-stop" \
  "$("$REAL_JQ" -r '.hooks.PreToolUse[0].hooks[0].command' "$P/settings.json")|$("$REAL_JQ" -r '.hooks.Stop[0].hooks[0].command' "$P/settings.json")"
assert_eq "user settings: kit hooks added" "$KIT_N" "$(kit_cmd_count "$P/settings.json")"
[ ! -L "$P/skills/fable-method" ] && [ "$(cat "$P/skills/fable-method/SKILL.md")" = "my own skill" ] \
  && pass "same-name user skill untouched" || fail "same-name user skill untouched" "$(ls -la "$P/skills")"
assert_has "same-name user skill: reported as skipped" "$OUT" "SKIP skills/fable-method"
assert_eq "same-name user command untouched" "my own command" "$(cat "$P/commands/test-audit.md")"
[ -L "$P/skills/fable-judge" ] && pass "other kit skills linked next to the user's" || fail "other kit skills linked" "missing"
ls "$P/.claude-kit-backups"/*/settings.json >/dev/null 2>&1 && pass "timestamped settings backup written" || fail "settings backup" "none"
s1=$(cksum < "$P/settings.json")
run_inst --profile "~/.claude"
assert_eq "user re-run: settings byte-identical" "$s1" "$(cksum < "$P/settings.json")"
assert_eq "user re-run: user hooks not duplicated" 1 "$("$REAL_JQ" '[.. | objects | select(.command? == "echo user-stop")] | length' "$P/settings.json")"

run_inst --uninstall --yes
assert_eq "user uninstall: exit 0" 0 "$RC"
assert_tree_same "user uninstall: HOME byte-identical to before install (backups aside)" "$before" "$(tree "$H" skip)"

# ---------------------------------------------------------------- interactive menu (answers on the terminal)
new_home "menu home"
mkdir -p "$H/.claude" "$H/.claude-work"; printf '{}\n' > "$H/.claude/settings.json"; printf '{}\n' > "$H/.claude-work/settings.json"
printf '2\ny\n' > "$T/answers"
TTYF="$T/answers" run_inst
assert_eq "menu: exit 0" 0 "$RC"
assert_has "menu: lists both profiles" "$OUT" "2) ~/.claude-work"
assert_eq "menu: picked profile 2 only" "0|$KIT_N" "$(kit_cmd_count "$H/.claude/settings.json")|$(kit_cmd_count "$H/.claude-work/settings.json")"
printf 'q\n' > "$T/answers"; before=$(tree "$H")
TTYF="$T/answers" run_inst
[ "$RC" -ne 0 ] && pass "menu: q cancels" || fail "menu: q cancels" "rc=0"
assert_tree_same "menu: cancel changes nothing" "$before" "$(tree "$H")"

# ---------------------------------------------------------------- piped (curl | bash) mode
new_home "pipe home"
mkdir -p "$H/.claude"; printf '{}\n' > "$H/.claude/settings.json"; before=$(tree "$H")
OUT=$(cd "$T" && env -i HOME="$H" PATH="$JQ_PATH" TMPDIR="$T/tmp" CLAUDE_KIT_HOME="$KH" CLAUDE_KIT_TTY=none "$BASH_BIN" < "$DIST/install.sh" 2>&1); RC=$?
assert_eq "piped, no flags: exit 2 (usage)" 2 "$RC"
assert_tree_same "piped, no flags: nothing changed" "$before" "$(tree "$H")"
OUT=$(cat "$DIST/install.sh" | (cd "$T" && env -i HOME="$H" PATH="$JQ_PATH" TMPDIR="$T/tmp" CLAUDE_KIT_HOME="$KH" CLAUDE_KIT_TTY=none "$BASH_BIN" -s -- --all --yes) 2>&1); RC=$?
assert_eq "piped with flags (cat | bash -s -- --all --yes): exit 0" 0 "$RC"
assert_eq "piped with flags: installed" "$KIT_N" "$(kit_cmd_count "$H/.claude/settings.json" 2>/dev/null)"

if [ -x /bin/dash ]; then
  new_home "dash home"; mkdir -p "$H/.claude"; printf '{}\n' > "$H/.claude/settings.json"; before=$(tree "$H")
  OUT=$(cat "$DIST/install.sh" | (cd "$T" && env -i HOME="$H" PATH="$JQ_PATH" TMPDIR="$T/tmp" CLAUDE_KIT_HOME="$KH" CLAUDE_KIT_TTY=none /bin/dash -s -- --all --yes) 2>&1); RC=$?
  [ "$RC" -ne 0 ] && pass "piped into dash (reads ahead): refused (rc=$RC)" || fail "piped into dash refused" "rc=0"
  assert_has "piped into dash: tells the user to pipe into bash" "$OUT" "Pipe into bash instead"
  assert_tree_same "piped into dash: nothing changed" "$before" "$(tree "$H")"
fi

# ---------------------------------------------------------------- Cursor wiring + CLI link on PATH
new_home "cursor home"
mkdir -p "$H/.claude" "$H/.cursor" "$H/.local/bin"; printf '{}\n' > "$H/.claude/settings.json"
printf '{\n  "version": 1,\n  "hooks": { "stop": [ { "command": "echo mine" } ] }\n}\n' > "$H/.cursor/hooks.json"
before=$(tree "$H")
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes
assert_eq "cursor: exit 0" 0 "$RC"
assert_eq "cursor: user hook kept" "echo mine" "$("$REAL_JQ" -r '.hooks.stop[0].command' "$H/.cursor/hooks.json")"
assert_eq "cursor: kit hooks added for 4 events" 4 "$("$REAL_JQ" '[.hooks[][] | select(.command | contains("/.claude-kit/cursor/hooks/"))] | length' "$H/.cursor/hooks.json")"
assert_has "cursor: absolute kit path substituted" "$(cat "$H/.cursor/hooks.json")" "$KH/cursor/hooks/stop-gate.sh"
assert_eq "CLI linked into ~/.local/bin (on PATH)" "$KH/bin/claude-kit" "$(readlink "$H/.local/bin/claude-kit")"
c1=$(cksum < "$H/.cursor/hooks.json")
INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes
assert_eq "cursor: re-run byte-identical" "$c1" "$(cksum < "$H/.cursor/hooks.json")"
run_inst --uninstall --yes
assert_tree_same "cursor: uninstall restores HOME byte-identical" "$before" "$(tree "$H" skip)"

new_home "bad cursor home"
mkdir -p "$H/.claude" "$H/.cursor"; printf '{}\n' > "$H/.claude/settings.json"; printf 'not json' > "$H/.cursor/hooks.json"
run_inst --all --yes
assert_eq "invalid Cursor hooks.json: install still succeeds" 0 "$RC"
assert_has "invalid Cursor hooks.json: skipped and reported" "$OUT" "SKIP Cursor"
assert_eq "invalid Cursor hooks.json: left untouched" "not json" "$(cat "$H/.cursor/hooks.json")"

finish

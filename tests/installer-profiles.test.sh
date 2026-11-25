#!/bin/bash
# Profile detection on a fake HOME shaped like a real multi-profile machine:
#   ~/.claude (primary), ~/.claude-a and ~/.claude-b whose config is symlinked into ~/.claude
#   (originals kept as *.backup), look-alike dirs that are not profiles, rc-file aliases (one
#   pointing outside HOME), a PowerShell profile assignment and ~/.config/claude.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$(dirname "${BASH_SOURCE[0]}")/installer-lib.sh"
build_dist

new_home "owner home"
P="$H/.claude"
mkdir -p "$P/hooks" "$P/skills/my-skill" "$P/projects/p1"
cat > "$P/settings.json" <<'EOF'
{
  "theme": "dark",
  "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "bash ~/.claude/hooks/mine.sh" } ] } ] }
}
EOF
printf 'primary rules\n' > "$P/CLAUDE.md"
printf 'echo mine\n' > "$P/hooks/mine.sh"
printf 'mine\n' > "$P/skills/my-skill/SKILL.md"
printf 'x\n' > "$P/projects/p1/memory.md"
printf '{"q":1}\n' > "$P/history.jsonl"
for x in a b; do
  S="$H/.claude-$x"; mkdir -p "$S"
  printf '{"account":"%s"}\n' "$x" > "$S/.claude.json"
  for item in CLAUDE.md settings.json; do printf 'old %s\n' "$item" > "$S/$item.backup"; ln -s "$P/$item" "$S/$item"; done
  for item in hooks skills projects; do mkdir -p "$S/$item.backup"; ln -s "$P/$item" "$S/$item"; done
done
mkdir -p "$H/.claude-code-router" "$H/.claude-profiles" "$H/.claude-providers" "$H/.config/claude" "$H/.config/claude-notes" "$H/work/cc-profile/sessions"
printf '{"Providers":[]}\n' > "$H/.claude-code-router/config.json"
printf 'export X=1\n' > "$H/.claude-profiles/one.sh"; printf 'export Y=1\n' > "$H/.claude-profiles/two.sh"
printf 'KEY=v\n' > "$H/.claude-providers/p.env"
printf '' > "$H/.config/claude/history.jsonl"
printf 'notes\n' > "$H/.config/claude-notes/readme.txt"
OUTSIDE="$T/outside profile"; mkdir -p "$OUTSIDE"; printf '{}\n' > "$OUTSIDE/settings.json"
cat > "$H/.zshrc" <<EOF
alias ca='CLAUDE_CONFIG_DIR=\$HOME/.claude-a claude'
alias cb="CLAUDE_CONFIG_DIR=~/.claude-b claude"
alias co='CLAUDE_CONFIG_DIR="$OUTSIDE" claude'
# alias old='CLAUDE_CONFIG_DIR=\$HOME/.claude-old claude'
alias gone='CLAUDE_CONFIG_DIR=\$HOME/.claude-gone claude'
EOF
mkdir -p "$H/Documents/PowerShell"
printf '$env:CLAUDE_CONFIG_DIR = "$env:USERPROFILE\\work\\cc-profile"\n' > "$H/Documents/PowerShell/Microsoft.PowerShell_profile.ps1"
mkdir -p "$H/.claude-old-but-commented"   # no markers either
before=$(tree "$H"); before_out=$(tree "$OUTSIDE")

# ---------------------------------------------------------------- detection
run_inst --list-profiles
assert_eq "list-profiles: exit 0" 0 "$RC"
paths=$(printf '%s\n' "$OUT" | cut -f1)
expected=$(printf '%s\n' "$H/.claude" "$H/.claude-a" "$H/.claude-b" "$H/.config/claude" "$OUTSIDE" "$H/work/cc-profile")
assert_eq "exactly the real profiles are detected, in order" "$expected" "$paths"
for look in .claude-code-router .claude-profiles .claude-providers .config/claude-notes .claude-gone .claude-old; do
  assert_not_has "look-alike excluded: $look" "$paths" "$H/$look"$'\n'
done
line_a=$(printf '%s\n' "$OUT" | grep "^$H/.claude-a$TAB")
assert_has "~/.claude-a grouped with the primary" "$line_a" "~/.claude-a (shares CLAUDE.md, settings.json, skills, hooks, projects with ~/.claude)"
line_p=$(printf '%s\n' "$OUT" | grep "^$H/.claude$TAB")
assert_eq "primary shown without a group note" "~/.claude" "$(printf '%s' "$line_p" | cut -f2)"
assert_has "rc alias outside HOME shown with its absolute path" "$OUT" "$OUTSIDE"
assert_tree_same "detection changes nothing" "$before" "$(tree "$H")"

XENV="CLAUDE_CONFIG_DIR=$T/envprof" run_inst --list-profiles
mkdir -p "$T/envprof/projects"
XENV="CLAUDE_CONFIG_DIR=$T/envprof" run_inst --list-profiles
assert_eq "\$CLAUDE_CONFIG_DIR profile listed first" "$T/envprof" "$(printf '%s\n' "$OUT" | head -n 1 | cut -f1)"
rm -rf "$T/envprof"

# ---------------------------------------------------------------- Independent install over shared profiles
run_inst --all --yes
assert_eq "independent --all: exit 0" 0 "$RC"
assert_eq "shared settings.json merged once (9 kit hooks, not 27)" "$KIT_N" "$(kit_cmd_count "$P/settings.json")"
assert_eq "primary user hook kept" "bash ~/.claude/hooks/mine.sh" "$("$REAL_JQ" -r '.hooks.Stop[0].hooks[0].command' "$P/settings.json")"
assert_eq "one managed block in the shared CLAUDE.md" 1 "$(grep -c 'claude-kit:begin' "$P/CLAUDE.md")"
assert_eq "secondary settings.json is still a symlink to the primary" "$P/settings.json" "$(readlink "$H/.claude-a/settings.json")"
assert_eq "secondary CLAUDE.md is still a symlink" "$P/CLAUDE.md" "$(readlink "$H/.claude-b/CLAUDE.md")"
assert_eq "reported as merged once for both secondaries" 2 "$(count_of "$OUT" 'settings.json: .* merged once')"
assert_eq "secondary identity file untouched" '{"account":"a"}' "$(cat "$H/.claude-a/.claude.json")"
assert_eq "secondary *.backup untouched" "old settings.json" "$(cat "$H/.claude-a/settings.json.backup")"
assert_eq "outside-HOME profile got its own merge" "$KIT_N" "$(kit_cmd_count "$OUTSIDE/settings.json")"
assert_eq "one settings backup only (the shared file was backed up once)" 1 "$(ls "$P"/.claude-kit-backups/*/settings.json | wc -l | tr -d ' ')"
[ -L "$H/.claude-a/commands/test-audit.md" ] && pass "secondary without its own commands dir gets kit command links" || fail "secondary commands" "$(ls -la "$H/.claude-a")"

run_inst --uninstall --yes
assert_eq "fixture uninstall: exit 0" 0 "$RC"
assert_tree_same "fixture uninstall: HOME byte-identical (backups aside)" "$before" "$(tree "$H" skip)"
assert_tree_same "fixture uninstall: outside profile byte-identical" "$before_out" "$(tree "$OUTSIDE" skip)"

finish

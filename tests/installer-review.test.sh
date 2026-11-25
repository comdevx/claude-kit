#!/bin/bash
# Regression tests for the adversarial installer review (findings #1-#17 + build extras).
# Each block names the finding it pins down. All runs use the BUILT dist/install.sh in temp HOMEs.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$(dirname "${BASH_SOURCE[0]}")/installer-lib.sh"
build_dist
CORE="$REPO/installer/setup-core.sh"
SHTMPL="$REPO/installer/install.sh.tmpl"
PSTMPL="$REPO/installer/install.ps1.tmpl"

basic_home() { new_home "$1"; P="$H/.claude"; mkdir -p "$P"; printf '{"model":"m"}\n' > "$P/settings.json"; }

# ---------------------------------------------------------------- #1 kit home must never wipe foreign data
basic_home "r1 home"
mkdir -p "$H/mydata"; printf 'precious\n' > "$H/mydata/notes.txt"
KH="$H/mydata" run_inst --all --yes
[ "$RC" -ne 0 ] && pass "#1 existing non-kit dir as kit home: refused" || fail "#1 non-kit kit home refused" "rc=0"
assert_eq "#1 existing non-kit dir as kit home: its files survive" "precious" "$(cat "$H/mydata/notes.txt" 2>/dev/null)"
KH="$H" run_inst --all --yes
[ "$RC" -ne 0 ] && pass "#1 kit home == HOME: refused" || fail "#1 kit home == HOME refused" "rc=0"
[ -f "$H/mydata/notes.txt" ] && [ -f "$P/settings.json" ] && pass "#1 kit home == HOME: HOME intact" || fail "#1 HOME intact" "$(ls -A "$H")"
mkdir -p "$T/outer/home/.claude"; printf '{}\n' > "$T/outer/home/.claude/settings.json"; printf 'keep\n' > "$T/outer/sibling.txt"
H0="$H"; H="$T/outer/home"; KH="$T/outer" run_inst --all --yes; rc_outer=$RC; H="$H0"
[ "$rc_outer" -ne 0 ] && pass "#1 kit home containing HOME: refused" || fail "#1 kit home containing HOME refused" "rc=0"
assert_eq "#1 kit home containing HOME: nothing wiped" "keep" "$(cat "$T/outer/sibling.txt" 2>/dev/null)"
KH="$P" run_inst --all --yes
[ "$RC" -ne 0 ] && pass "#1 kit home == a selected profile: refused" || fail "#1 kit home == profile refused" "rc=0"
KH="$P/kit" run_inst --all --yes
[ "$RC" -ne 0 ] && pass "#1 kit home inside a selected profile: refused" || fail "#1 kit home inside profile refused" "rc=0"
KH="/" run_inst --all --yes
[ "$RC" -ne 0 ] && pass "#1 kit home / : refused" || fail "#1 kit home / refused" "rc=0"
mkdir -p "$H/emptykit"
KH="$H/emptykit" run_inst --all --yes
assert_eq "#1 empty existing dir is accepted as kit home" 0 "$RC"
[ -f "$H/emptykit/.claude-kit-home" ] && pass "#1 kit home carries the sentinel" || fail "#1 sentinel" "missing"
KH="$H/emptykit" run_inst --all --yes
assert_eq "#1 kit home with sentinel is replaced on re-run" 0 "$RC"

# ---------------------------------------------------------------- #2 identity-bearing settings are not linked
new_home "r2 home"
P="$H/.claude"; S="$H/.claude-work"; mkdir -p "$P" "$S"
printf '{"model":"opus"}\n' > "$P/settings.json"
printf '{"env":{"ANTHROPIC_BASE_URL":"https://proxy.example"},"apiKeyHelper":"/x/key.sh"}\n' > "$S/settings.json"
run_inst --all --mode shared --yes
assert_eq "#2 shared: install ok" 0 "$RC"
[ ! -L "$S/settings.json" ] && pass "#2 secondary settings with a different provider/env are NOT linked" || fail "#2 not linked" "$(readlink "$S/settings.json")"
assert_eq "#2 secondary keeps its env and gets its own kit merge" '"https://proxy.example"|'"$KIT_N" \
  "$("$REAL_JQ" -c .env.ANTHROPIC_BASE_URL "$S/settings.json")|$(kit_cmd_count "$S/settings.json")"
assert_has "#2 reports why settings.json was not linked" "$OUT" "identity"
[ ! -L "$S/CLAUDE.md" ] && pass "#2/NEW-B a profile whose settings.json is not linked links nothing else either" || fail "#2 CLAUDE.md not linked" "linked"
new_home "r2b home"
P="$H/.claude"; S="$H/.claude-work"; mkdir -p "$P" "$S"
printf '{"model":"opus","env":{"A":"1"}}\n' > "$P/settings.json"; printf '{"model":"opus","env":{"A":"1"},"theme":"x"}\n' > "$S/settings.json"
run_inst --all --mode shared --yes
assert_eq "#2 identical identity keys: settings.json linked as before" "$P/settings.json" "$(readlink "$S/settings.json")"

# ---------------------------------------------------------------- #3 preflight before any write
new_home "r3 home"
P="$H/.claude"; S="$H/.claude-b"; mkdir -p "$P" "$S"
printf '{"model":"m"}\n' > "$P/settings.json"; printf '{"hooks":{"Stop":{"oops":1}}}\n' > "$S/settings.json"
before=$(tree "$H")
run_inst --all --yes
[ "$RC" -ne 0 ] && pass "#3 un-mergeable hooks shape in a later profile: refused" || fail "#3 refused" "rc=0"
assert_tree_same "#3 un-mergeable settings: nothing changed in ANY profile, no kit home" "$before" "$(tree "$H")"
printf '{}\n' > "$S/settings.json"; mkdir -p "$S/skills"; chmod 555 "$S/skills"; before=$(tree "$H")
if [ -w "$S/skills" ]; then
  echo "SKIP #3 unwritable skills dir: permissions are not enforced here (root or Windows)"
else
  run_inst --all --yes
  [ "$RC" -ne 0 ] && pass "#3 unwritable skills dir: refused up front" || fail "#3 unwritable skills refused" "rc=0"
  assert_tree_same "#3 unwritable skills dir: nothing changed" "$before" "$(tree "$H")"
fi
chmod 755 "$S/skills"

# ---------------------------------------------------------------- #3 interrupted run is journaled and uninstallable
basic_home "r3j home"
SHIM="$T/shim-ln"; mkdir -p "$SHIM"; CNT="$T/ln-count"; rm -f "$CNT"
cat > "$SHIM/ln" <<EOF
#!/bin/bash
n=\$(cat "$CNT" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "$CNT"
if [ "\$n" -eq 5 ]; then kill -TERM \$PPID; exit 1; fi
exec /bin/ln "\$@"
EOF
chmod +x "$SHIM/ln"
before=$(tree "$H")
INST_PATH="$SHIM:$JQ_PATH" run_inst --all --yes
[ "$RC" -ne 0 ] && pass "#3 run killed by SIGTERM mid-way exits non-zero" || fail "#3 killed run rc" "rc=0"
[ -f "$KH/state/install.json" ] && pass "#3 journal folded into the manifest on SIGTERM" || fail "#3 manifest after SIGTERM" "$(ls "$KH/state" 2>&1)"
run_inst --uninstall --yes
assert_eq "#3 uninstall after an interrupted run: exit 0" 0 "$RC"
assert_tree_same "#3 uninstall after an interrupted run restores HOME" "$before" "$(tree "$H" skip)"
# an un-folded journal (no manifest at all) is still read by uninstall
basic_home "r3u home"; before=$(tree "$H")
run_inst --all --yes
mv "$KH/state/install.json" "$T/m.json"
"$REAL_JQ" -c '.created[] | {rec: "created"} + .' "$T/m.json" > "$KH/state/journal.jsonl"
"$REAL_JQ" -c '.originals[] | {rec: "original"} + .' "$T/m.json" >> "$KH/state/journal.jsonl"
"$REAL_JQ" -c '{rec: "run", version: .version, mode: .mode, primary: .primary, share: .share, profiles: .profiles}' "$T/m.json" >> "$KH/state/journal.jsonl"
run_inst --uninstall --yes
assert_eq "#3 uninstall with only a journal: exit 0" 0 "$RC"
assert_tree_same "#3 uninstall with only a journal restores HOME" "$before" "$(tree "$H" skip)"

# ---------------------------------------------------------------- #4 Windows junction commands (static contract, faked cmd)
rm -f "$T/cmd.log"
(cd "$T" && env -i HOME="$T" PATH="$JQ_PATH" CLAUDE_KIT_LIB_ONLY=1 LOG="$T/cmd.log" "$BASH_BIN" -c '
  . "$1"
  real_windows() { return 0; }
  cygpath() { printf "W:%s" "$2"; }
  cmd() { { printf "CMD"; for a in "$@"; do printf " [%s]" "$a"; done; echo; } >> "$LOG"; }
  tasklist() { { printf "TASKLIST"; for a in "$@"; do printf " [%s]" "$a"; done; echo; } >> "$LOG"; }
  make_junction "/t/target dir" "/t/link"
  remove_junction "/t/link"
  CLAUDE_KIT_ASSUME_RUNNING= claude_running
' _ "$CORE" >/dev/null 2>&1)
J=$(cat "$T/cmd.log" 2>/dev/null)
assert_has "#4 mklink uses //J (MSYS would mangle /J)" "$J" "CMD [//c] [mklink] [//J] [W:/t/link] [W:/t/target dir]"
assert_has "#4 junction removal is rmdir on the link only (no /s, no rm -rf)" "$J" "CMD [//c] [rmdir] [W:/t/link]"
assert_not_has "#4 junction removal never recursive" "$J" "[//s]"
assert_has "#4 tasklist flags use //" "$J" "TASKLIST [//FI] [IMAGENAME eq claude.exe] [//NH]"

# ---------------------------------------------------------------- #5 CRLF CLAUDE.md
basic_home "r5 home"
printf '# Mine\r\nkeep this\r\n' > "$P/CLAUDE.md"; before=$(tree "$H")
run_inst --all --yes; run_inst --all --yes
assert_eq "#5 CRLF CLAUDE.md: one block after two runs" 1 "$(grep -c 'claude-kit:begin' "$P/CLAUDE.md")"
run_inst --uninstall --yes
assert_tree_same "#5 CRLF CLAUDE.md: uninstall byte-identical" "$before" "$(tree "$H" skip)"

# ---------------------------------------------------------------- #6 user edits inside kit copies survive
basic_home "r6 home"
XENV="CLAUDE_KIT_FORCE_NO_SYMLINK=1" run_inst --all --yes
printf 'my edit\n' >> "$P/skills/recheck/SKILL.md"
XENV="CLAUDE_KIT_FORCE_NO_SYMLINK=1" run_inst --all --yes
saved=$(find "$P/.claude-kit-backups" -path '*recheck/SKILL.md' 2>/dev/null | head -n 1)
[ -n "$saved" ] && grep -q 'my edit' "$saved" && pass "#6 update keeps an edited kit copy in .claude-kit-backups" || fail "#6 edited copy kept on update" "$(find "$P/.claude-kit-backups" 2>/dev/null | head)"
cmp -s "$P/skills/recheck/SKILL.md" "$REPO/skills/recheck/SKILL.md" && pass "#6 update puts a fresh kit copy in place" || fail "#6 fresh copy" "differs"
assert_has "#6 update reports the kept edit" "$OUT" "edited"
printf 'second edit\n' >> "$P/skills/recheck/SKILL.md"
run_inst --uninstall --yes
n=$(grep -rl 'second edit' "$P/.claude-kit-backups" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "#6 uninstall keeps an edited kit copy in .claude-kit-backups" 1 "$n"

# ---------------------------------------------------------------- #7 copy -> link switch leaves no dangling links
basic_home "r7 home"; before=$(tree "$H")
XENV="CLAUDE_KIT_FORCE_NO_SYMLINK=1" run_inst --all --yes
run_inst --all --yes
[ -L "$P/skills/recheck" ] && pass "#7 re-run with symlinks replaces copies with links" || fail "#7 link now" "not a link"
run_inst --uninstall --yes
assert_tree_same "#7 uninstall after copy->link switch: HOME byte-identical (no dangling links)" "$before" "$(tree "$H" skip)"

# ---------------------------------------------------------------- #9 #14 #15 install.ps1 / wording (static: no pwsh here)
grep -q 'Test-KitDryRun' "$PSTMPL" && awk '/function Invoke-KitWinget/,/^}/' "$PSTMPL" | grep -q 'Test-KitDryRun' \
  && pass "#9 install.ps1: winget is never called under --dry-run (guard inside Invoke-KitWinget)" || fail "#9 dry-run guard" "missing"
head -n 40 "$PSTMPL" | grep -q '^& {' && tail -n 3 "$PSTMPL" | grep -q '^} @args' \
  && pass "#14 install.ps1 body wrapped in & { ... } @args (safe under irm | iex)" || fail "#14 scriptblock wrapper" "missing"
grep -q 'ErrorActionPreference = \$kitOldEap' "$PSTMPL" && grep -q 'Remove-Item Env:CLAUDE_KIT_PAYLOAD_DIR' "$PSTMPL" \
  && pass "#14 install.ps1 restores ErrorActionPreference and env vars in finally" || fail "#14 restore" "missing"
assert_not_has "#14 install.ps1 never overwrites the session PATH" "$(cat "$PSTMPL")" '$env:Path = ($machine'
for f in "$SHTMPL" "$PSTMPL" "$REPO/README.md"; do
  assert_not_has "#15 no tamper-proof claim in $(basename "$f")" "$(cat "$f")" "tampered"
done
assert_has "#15 README recommends verifying SHA256SUMS from the release page over HTTPS" "$(cat "$REPO/README.md")" "release page over HTTPS"

# ---------------------------------------------------------------- #10 update skips deleted profiles
REL="$T/release"; "$BASH_BIN" "$REPO/build-release.sh" --worktree --version 9.9.10-test --out "$REL" > "$T/rel.log" 2>&1 || fail "release build" "$(cat "$T/rel.log")"
new_home "r10 home"; mkdir -p "$H/.claude" "$H/.claude-old"; printf '{}\n' > "$H/.claude/settings.json"; printf '{}\n' > "$H/.claude-old/settings.json"
run_inst --all --yes
rm -rf "$H/.claude-old"
XENV="CLAUDE_KIT_RELEASE_URL=file://$REL" run_cli update
assert_eq "#10 update with a deleted profile: exit 0" 0 "$RC"
[ ! -e "$H/.claude-old" ] && pass "#10 update does not recreate a deleted profile" || fail "#10 not recreated" "$(ls -A "$H/.claude-old")"
assert_has "#10 update warns about the missing profile" "$OUT" "does not exist right now"
# coordinator decision (round 2): a missing profile stays recorded so uninstall can still clean it
assert_has "#10 missing profile stays recorded in the manifest" "$("$REAL_JQ" -r '.profiles | join(",")' "$KH/state/install.json")" "$H/.claude-old"

# ---------------------------------------------------------------- #11 empty hook containers survive uninstall
for orig in '{"hooks":{}}' '{"hooks":{"Stop":[]},"x":1}' '{"hooks":{"Stop":[],"PreToolUse":[]}}'; do
  new_home "r11 home"; mkdir -p "$H/.claude"; printf '%s\n' "$orig" > "$H/.claude/settings.json"; before=$(tree "$H")
  run_inst --all --yes; run_inst --uninstall --yes
  assert_tree_same "#11 uninstall byte-identical for $orig" "$before" "$(tree "$H" skip)"
done

# ---------------------------------------------------------------- #12 HOME must be absolute
new_home "r12 home"; mkdir -p "$T/relative/home/.claude"; printf '{}\n' > "$T/relative/home/.claude/settings.json"
HOME_ARG="relative/home" KH="relative/home/.claude-kit" run_inst --all --yes
[ "$RC" -ne 0 ] && pass "#12 relative HOME: refused" || fail "#12 relative HOME refused" "rc=0"
assert_has "#12 relative HOME: says why" "$OUT" "HOME must be an absolute path"
[ ! -e "$T/relative/home/.claude-kit" ] && [ "$(cat "$T/relative/home/.claude/settings.json")" = "{}" ] && pass "#12 relative HOME: nothing created relative to cwd" || fail "#12 nothing created" "$(ls -A "$T/relative/home")"

# ---------------------------------------------------------------- #13 kit-home swap race
basic_home "r13 home"
run_inst --all --yes; v1=$(cat "$KH/VERSION")
MVS="$T/shim-mv"; mkdir -p "$MVS"
cat > "$MVS/mv" <<EOF
#!/bin/bash
last=""; for a in "\$@"; do last="\$a"; done
case "\$1" in *.new.*) [ "\$last" = "$KH" ] && /bin/mkdir -p "$KH/intruder" ;; esac
exec /bin/mv "\$@"
EOF
chmod +x "$MVS/mv"
INST_PATH="$MVS:$JQ_PATH" run_inst --all --yes
[ "$RC" -ne 0 ] && pass "#13 racing kit-home swap detected (exit non-zero)" || fail "#13 race detected" "rc=0"
assert_has "#13 racing swap: explains" "$OUT" "kit home swap"
nested=$(find "$KH" -maxdepth 1 -name '.claude-kit.new.*' 2>/dev/null)
assert_empty "#13 racing swap: no nested kit copy left inside the kit home" "$nested"
prev=$(ls -d "$H"/.claude-kit.old.* 2>/dev/null | head -n 1)
[ -n "$prev" ] && [ -f "$prev/state/install.json" ] && pass "#13 racing swap: previous kit (with its state) preserved" || fail "#13 previous kit kept" "$(ls -A "$H")"

# ---------------------------------------------------------------- #16 CLI link failure keeps the hint; doctor wording
basic_home "r16 home"; mkdir -p "$H/.local/bin"; chmod 555 "$H/.local/bin"
if [ -w "$H/.local/bin" ]; then
  chmod 755 "$H/.local/bin"; run_inst --all --yes
  echo "SKIP #16 unwritable ~/.local/bin: permissions are not enforced here (root or Windows)"
else
  INST_PATH="$JQ_PATH:$H/.local/bin" run_inst --all --yes
  chmod 755 "$H/.local/bin"
  assert_eq "#16 unwritable ~/.local/bin: install still succeeds" 0 "$RC"
  assert_has "#16 unwritable ~/.local/bin: prints the CLI hint" "$OUT" "Run the CLI as"
  assert_eq "#16 unwritable ~/.local/bin: no CLI link recorded" 0 "$("$REAL_JQ" '[.created[] | select(.path | endswith("/.local/bin/claude-kit"))] | length' "$KH/state/install.json")"
fi
head -c 12000 /dev/zero | tr '\0' 'x' > "$KH/rules/code.md"
run_cli doctor
assert_not_has "#16 doctor never tells users to edit the managed kit home" "$OUT" "shorten the file"
assert_has "#16 doctor points customisation to the user's own CLAUDE.md" "$OUT" "your own CLAUDE.md"

# ---------------------------------------------------------------- #17 uninstall acts only under recorded profiles / kit home
basic_home "r17 home"
run_inst --all --yes
mkdir -p "$H/precious"; printf 'x\n' > "$H/precious/a"; ln -s "$KH/skills/recheck" "$H/victim-link"
M="$KH/state/install.json"
"$REAL_JQ" --arg p "$H/precious" --arg l "$H/victim-link" --arg t "$KH/skills/recheck" \
  '.created += [{type: "copy", path: $p}, {type: "link", path: $l, target: $t}]' "$M" > "$T/m2" && cat "$T/m2" > "$M"
run_inst --uninstall --yes
[ -f "$H/precious/a" ] && pass "#17 manifest entry outside every profile: copy NOT deleted" || fail "#17 precious kept" "deleted"
[ -L "$H/victim-link" ] && pass "#17 manifest entry outside every profile: link NOT removed" || fail "#17 link kept" "removed"
assert_has "#17 reports the refused path" "$OUT" "outside"

# ---------------------------------------------------------------- build extras: no macOS xattrs, LF attributes
mkdir -p "$T/px" && awk 'f { print } $0 == "__CLAUDE_KIT_PAYLOAD_BELOW__" { f = 1 }' "$DIST/install.sh" | base64 -d > "$T/px/p.tgz"
gzip -dc "$T/px/p.tgz" > "$T/px/p.tar"
if grep -a -q -E 'LIBARCHIVE\.xattr|com\.apple\.|SCHILY\.xattr' "$T/px/p.tar"; then fail "build: payload tar has no macOS xattr/metadata headers" "found"; else pass "build: payload tar has no macOS xattr/metadata headers"; fi
[ -z "$(tar -tf "$T/px/p.tar" | grep '/\._\|^\._')" ] && pass "build: no AppleDouble ._ files" || fail "build: ._ files" "present"
GA="$REPO/.gitattributes"
for pat in '*.sh' '*.md' '*.json' '*.tmpl' 'bin/claude-kit' '*.ps1'; do
  grep -q -F "$pat" "$GA" 2>/dev/null && grep -F "$pat" "$GA" | grep -q 'eol=lf' && pass ".gitattributes: $pat eol=lf" || fail ".gitattributes: $pat eol=lf" "missing"
done

finish

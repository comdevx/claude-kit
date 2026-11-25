#!/bin/bash
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
mk_kit
for mode in $MODES; do
  chk() { # name expected json path
    local got; got=$(env PATH="$([ $mode = nojq ] && echo "$NOJQ_BIN" || echo "$PATH")" "$BASH_BIN" -c '. "$1"; kit_json_get "$2" "$3"' x "$KIT/hooks/lib.sh" "$3" "$4")
    assert_eq "lib[$mode] json_get $1" "$2" "$got"
  }
  chk "session_id" "abc-1" '{"session_id":"abc-1","cwd":"/x"}' session_id
  chk "pretty-printed" "/x y" '{
  "session_id": "s",
  "cwd" : "/x y"
}' cwd
  chk "nested tool_input.file_path" "/a/b.ts" '{"tool_name":"Edit","tool_input":{"file_path":"/a/b.ts","old_string":"x"}}' tool_input.file_path
  chk "windows backslashes" 'C:\Proj\x\f.ts' '{"tool_input":{"file_path":"C:\\Proj\\x\\f.ts"}}' tool_input.file_path
  chk "escaped quote" 'a"b' '{"cwd":"a\"b"}' cwd
  chk "number" "3" '{"loop_count": 3}' loop_count
  chk "null is empty" "" '{"source":null}' source
  chk "absent is empty" "" '{"a":"b"}' source
  chk "model string" "claude-opus-4" '{"model":"claude-opus-4"}' model
  chk "model object id" "claude-fable-1" '{"model":{"id":"claude-fable-1","display_name":"Fable"}}' model.id
  # json_string round trip
  s=$(printf 'a"b\\c\td\nline2 \xe2\x9c\x85' | env PATH="$([ $mode = nojq ] && echo "$NOJQ_BIN" || echo "$PATH")" "$BASH_BIN" -c '. "$1"; kit_json_string' x "$KIT/hooks/lib.sh")
  if [ -n "$REAL_JQ" ]; then
    back=$(printf '%s' "$s" | "$REAL_JQ" -r .)
    assert_eq "lib[$mode] json_string round trip" "$(printf 'a"b\\c\td\nline2 \xe2\x9c\x85')" "$back"
  fi
done
# OS detection
for os in macos linux windows; do
  got=$(CLAUDE_KIT_OS=$os "$BASH_BIN" -c '. "$1"; kit_os' x "$KIT/hooks/lib.sh")
  assert_eq "lib os override $os" "$os" "$got"
done
fake="$T/fakebin"; mkdir -p "$fake"
for u in MINGW64_NT-10.0 MSYS_NT-10.0 CYGWIN_NT-10.0 Linux Darwin; do
  printf '#!/bin/sh\necho %s\n' "$u" > "$fake/uname"; chmod +x "$fake/uname"
  got=$(PATH="$fake:$PATH" "$BASH_BIN" -c '. "$1"; kit_os' x "$KIT/hooks/lib.sh")
  case "$u" in MINGW*|MSYS*|CYGWIN*) want=windows ;; Linux) want=linux ;; Darwin) want=macos ;; esac
  assert_eq "lib uname $u -> $want" "$want" "$got"
done
want='C:/Proj/x/a.ts'; command -v cygpath >/dev/null 2>&1 && want='/c/Proj/x/a.ts'   # documented: C:/x -> /c/x when cygpath exists (Git Bash)
assert_eq "lib norm_path" "$want" "$("$BASH_BIN" -c '. "$1"; kit_norm_path "$2"' x "$KIT/hooks/lib.sh" 'C:\Proj\x\a.ts')"
# source extension list
for e in ts tsx js jsx mjs cjs svelte vue py go rs java kt swift c cc cpp h hpp cs php rb sh bash ps1 sql dart scala lua ex exs zig TS; do
  "$BASH_BIN" -c '. "$1"; kit_is_source_path "$2"' x "$KIT/hooks/lib.sh" "/p/f.$e" && pass "ext .$e is source" || fail "ext .$e is source" "not detected"
done
for e in md txt json yaml yml toml csv srt vtt mp4 png wav ""; do
  "$BASH_BIN" -c '. "$1"; kit_is_source_path "$2"' x "$KIT/hooks/lib.sh" "/p/f.$e" && fail "ext .$e not source" "wrongly source" || pass "ext .$e not source"
done
# cap
big=$(awk 'BEGIN{for(i=0;i<1200;i++) printf "0123456789\n"}')
out=$("$BASH_BIN" -c '. "$1"; kit_cap_text "$2" f' x "$KIT/hooks/lib.sh" "$big" 2>"$T/e")
n=$(printf '%s' "$out" | wc -c | tr -d ' ')
[ "$n" -le 10000 ] && pass "cap output <= 10000" || fail "cap output <= 10000" "$n"
assert_has "cap marker" "$out" "truncated"
assert_has "cap stderr warning" "$(cat "$T/e")" "over the 10000"
small=$("$BASH_BIN" -c '. "$1"; kit_cap_text "$2" f' x "$KIT/hooks/lib.sh" "hello" 2>&1)
assert_eq "cap passes small text" hello "$small"
# prune
mkdir -p "$STATE/sessions"; : > "$STATE/sessions/old.code"; : > "$STATE/sessions/new.code"; : > "$STATE/install.json"
touch -t 202001010000 "$STATE/sessions/old.code" "$STATE/install.json"
CLAUDE_KIT_STATE="$STATE" "$BASH_BIN" -c '. "$1"; kit_prune' x "$KIT/hooks/lib.sh"
[ ! -e "$STATE/sessions/old.code" ] && pass "prune removes >7d session file" || fail "prune removes >7d session file" "still there"
[ -e "$STATE/sessions/new.code" ] && pass "prune keeps fresh file" || fail "prune keeps fresh file" "deleted"
[ -e "$STATE/install.json" ] && pass "prune never touches state/install.json" || fail "prune never touches state/install.json" "deleted"
finish

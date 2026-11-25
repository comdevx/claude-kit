#!/bin/bash
# Table-driven tests for kit_bash_source_write (hooks/lib.sh): command -> source path written, or "-".
# <NL> in a row stands for a newline (heredocs). Also run through code-detect.sh pretool with and
# without jq, so the JSON-decoded command (real newlines) is what gets classified.
. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
. "$REPO/hooks/lib.sh"
NLC='
'
TABLE=$(cat <<'ROWS'
src/a.ts	echo x > src/a.ts
b.PY	echo x>>b.PY
c.go	cat <<EOF > c.go<NL>x<NL>EOF
d.rs	printf x | tee d.rs
d2.rs	printf x | tee -a d2.rs
e.js	sed -i s/a/b/ e.js
e2.js	sed -i '' s/a/b/ e2.js
f.rb	perl -pi -e s/a/b/ f.rb
g.ts	cp /tmp/x g.ts
h.tsx	mv /tmp/x h.tsx
i.sh	install -m 644 /tmp/x i.sh
j.py	python3 -c "open('j.py','w').write('x')"
k.js	node -e "require('fs').writeFileSync('k.js','x')"
src/a.ts	echo x > "src/a.ts"
a.py	echo y > 'a.py'
a.rs	printf x | tee "a.rs"
b.go	printf x | tee -a 'b.go'
a.ts	cp x "a.ts"
b.py	mv y 'b.py'
x.py	python3 - <<EOF<NL>open('x.py','w').write('1')<NL>EOF
x.py	python3 <<'EOF'<NL>with open("x.py", "w") as f: f.write("1")<NL>EOF
a.ts	node <<EOF<NL>require('fs').writeFileSync('a.ts', 'x')<NL>EOF
c.rb	ruby <<EOF<NL>File.write('c.rb', 'x')<NL>EOF
a.go	bash <<EOF<NL>echo x > a.go<NL>EOF
a.go	bash -c 'echo x > a.go'
a.ts	sed -E -i 's/a/b/' a.ts
a.ts	sed -e 's/a/b/' -i a.ts
a.py	sed -i.bak 's/x/y/' a.py
a.rs	perl -0pi -e 's/a/b/' a.rs
a.py	perl -p -i -e 's/a/b/' a.py
a.go	perl -i -pe 's/a/b/' a.go
b.ts	cp a.txt b.ts
app.py	python3 -c "open('app.py','w').write('x')"
a.py	python3 -c 'open("a.py", "a").write("x")'
a.py	python3 -c "open('a.py', mode='x')"
z.ts	cd src && echo x > z.ts
-	cat a.ts
-	grep -n foo b.py
-	ls > out.txt
-	echo hi > notes.md
-	python3 script.py
-	node app.js
-	cp a.ts /tmp/backup.txt
-	cp -f a.ts /tmp/x.txt
-	git diff > changes.patch
-	echo x 2>&1
-	python3 -c "print(open('app.py').read())"
-	git commit -m "rename a.ts -> b.ts"
-	echo "x => y.js"
-	cat > README.md <<EOF<NL>a.ts -> b.ts<NL>EOF
-	sed -i 's/foo.js/bar.js/' config.json
-	echo x > notes.ts.bak
-	node -e "console.log(require('fs').readFileSync('a.ts','utf8'))"
-	python3 -c "open('out.txt','w')"
-	python3 -c "open('notes.md','w').write('x')"
-	python3 -c "import json; json.dump({}, open('out.json','w'))"
-	python3 -c "with open('data.csv','w') as f: f.write('x')"
-	python3 - <<EOF<NL>with open("report.md","w") as f: f.write("x")<NL>EOF
-	python3 -c "open('.py','w')"
-	python3 -c "from pathlib import Path; Path('x.md').write_text('x')"
-	ruby -e "File.open('x.txt','w') { |f| f.puts 1 }"
-	perl -e "open(my \$fh,'>','x') or die"
out.py	python3 -c "open('out.py','w')"
notes.ts	python3 -c "open('notes.ts','w').write('x')"
out.js	python3 -c "import json; json.dump({}, open('out.js','w'))"
data.go	python3 -c "with open('data.go','w') as f: f.write('x')"
report.rs	python3 - <<EOF<NL>with open("report.rs","w") as f: f.write("x")<NL>EOF
x.py	python3 -c "from pathlib import Path; Path('x.py').write_text('x')"
x.rb	ruby -e "File.open('x.rb','w') { |f| f.puts 1 }"
x.pl	perl -e "open(my \$fh,'>','x.pl') or die"
a.ts	bash -lc 'echo x > a.ts'
a.ts	bash -ec 'echo x > a.ts'
a.ts	sh -xc 'echo x > a.ts'
patch:x.diff	git apply x.diff
patch:0001.patch	git am 0001.patch
patch:x.diff	patch -p1 < x.diff
patch:a.ts	patch a.ts x.diff
-	git apply --check x.diff
-	git status
a.ts	bash -c -- 'echo x > a.ts'
patch:x.diff	git apply --stat --apply x.diff
out.ts	patch -o out.ts a.ts x.diff
patch:x.diff	patch --input=x.diff
patch:x.diff	patch -i x.diff
patch:x.diff	patch -i x.diff a.ts
ROWS
)
while IFS="$(printf '\t')" read -r want cmd; do
  [ -n "$cmd" ] || continue
  cmd=${cmd//<NL>/$NLC}
  # every call runs under a watchdog: a classifier hang FAILS the row instead of hanging the suite
  if with_timeout 5 kit_bash_source_write "$cmd"; then got="$WD_OUT"; elif [ "$WD_RC" = 124 ]; then got="HANG (killed after 5s)"; else got=-; fi
  assert_eq "A classify: $(printf '%s' "$cmd" | tr '\n' '|')" "$want" "$got"
done <<EOF2
$TABLE
EOF2

# Huge single words. Two separate questions, neither tied to absolute machine speed:
# (a) HANG: a generous watchdog (Windows Git Bash starts processes slowly; a real hang never ends).
big=$(head -c 40000 /dev/zero | tr '\0' 'a')
with_timeout 15 kit_bash_source_write "echo $big > out.txt"
[ "$WD_RC" != 124 ] && pass "4: a 40 KB word terminates (no hang)" || fail "4: 40 KB word" "hung: killed after 15 s"
HUNG=$WD_RC
with_timeout 15 kit_bash_source_write "echo hi > $big.ts"
[ "$WD_RC" != 124 ] && pass "4: a 40 KB target name terminates (no hang)" || fail "4: 40 KB target" "hung: killed after 15 s"
[ "$WD_RC" = 124 ] && HUNG=124

# (b) SCALING: the tokenizer and the path check must stay near-linear. Time a 5 KB and an 80 KB word (best of 5 each, which
# cuts scheduler noise) and compare the ratio for 16x the input: linear is <= ~16x (less, because process
# start is a fixed cost; macOS awk string append adds a bit, measured ~40x), quadratic ~140x. The limit
# sits between them, so a slow or loaded machine scales both sizes alike.
now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then local t=${EPOCHREALTIME/[.,]/}; printf '%s' "$((t / 1000))"; return; fi
  perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null && return
  python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null && return
  date +%s%3N 2>/dev/null
}
best_ms() {   # best_ms <command> -> fastest of 5 runs, in ms
  local i s e best=
  for i in 1 2 3 4 5; do
    s=$(now_ms); kit_bash_source_write "$1" > /dev/null; e=$(( $(now_ms) - s ))
    if [ -z "$best" ] || [ "$e" -lt "$best" ]; then best=$e; fi
  done
  printf '%s' "$best"
}
SCALE_LIMIT=80   # ratio of the 80 KB time to the 5 KB time that FAILS (measured: linear-ish ~40x on macOS awk, quadratic ~140x)
if [ "$HUNG" = 124 ]; then
  fail "4: scaling" "skipped, the classifier hung above"
elif ! case "$(now_ms)" in ''|*[!0-9]*) false ;; esac; then
  pass "4: scaling check skipped (no millisecond clock: need bash 5, perl, python3 or GNU date)"
else
  big80=$(head -c 80000 /dev/zero | tr '\0' 'a')
  small=$(head -c 5000 /dev/zero | tr '\0' 'a')
  # a long word (awk tokenizer) and a long redirect target (bash kit_is_source_path: ${x##*/} is quadratic)
  for kind in word target; do
    if [ "$kind" = word ]; then c_small="echo $small > out.txt"; c_big="echo $big80 > out.txt"
    else c_small="echo hi > $small.ts"; c_big="echo hi > $big80.ts"; fi
    t_small=$(best_ms "$c_small"); t_big=$(best_ms "$c_big")
    [ "$t_small" -ge 1 ] || t_small=1
    ratio=$(( t_big * 10 / t_small ))   # tenths: 45 = 4.5x
    [ "$ratio" -lt $((SCALE_LIMIT * 10)) ] && pass "4: $kind: classifier time scales near-linearly (5 KB ${t_small} ms, 80 KB ${t_big} ms, ratio $((ratio / 10)).$((ratio % 10))x < ${SCALE_LIMIT}x)" \
      || fail "4: $kind: classifier scaling" "5 KB ${t_small} ms, 80 KB ${t_big} ms, ratio $((ratio / 10)).$((ratio % 10))x >= ${SCALE_LIMIT}x (quadratic?)"
  done
fi

# a target longer than PATH_MAX (4096 bytes) cannot be a real file: not a source path, decided up front
p4k=$(head -c 4000 /dev/zero | tr '\0' 'a')
kit_is_source_path "$p4k.ts" && pass "4: a 4003-byte .ts path is still a source path" || fail "4: 4003-byte path" "rejected"
kit_is_source_path "$p4k$p4k.ts" && fail "4: a 8003-byte .ts path" "accepted as source" || pass "4: a path over 4096 bytes is not a source path"

# 4: a 400 KB double-quoted command must not approach the 10 s PreToolUse timeout
big4=$(head -c 400000 /dev/zero | tr '\0' 'x')
start=$SECONDS
with_timeout 6 kit_bash_source_write "python3 -c \"print('$big4')\""
el=$((SECONDS - start))
[ "$WD_RC" != 124 ] && [ "$el" -le 3 ] && pass "4: 400 KB double-quoted command handled in under 3 s (${el}s)" || fail "4: 400 KB quoted command" "rc=$WD_RC after ${el}s"
case "$WD_OUT" in ""|bash:large) pass "4: 400 KB command: no write, or logged conservatively as bash:large" ;; *) fail "4: 400 KB result" "$WD_OUT" ;; esac
mid=$(head -c 60000 /dev/zero | tr '\0' 'y')
with_timeout 6 kit_bash_source_write "python3 -c \"open('out.py','w').write('$mid')\""
assert_eq "4: a 60 KB command is still classified precisely" "out.py" "$WD_OUT"

# through the hook, as Claude Code sends it (JSON, newlines escaped), with and without jq
mk_kit
for mode in $MODES; do
  rm -rf "$STATE"; mkdir -p "$STATE"
  PAYLOAD='{"session_id":"bw4","tool_name":"Bash","tool_input":{"command":"python3 - <<EOF\nopen(\"x.py\",\"w\").write(\"1\")\nEOF"}}'
  run_hook "$mode" "$KIT/hooks/code-detect.sh" pretool
  assert_has "[$mode] A heredoc-fed python via code-detect (JSON \\n decoded): logged" "$(cat "$STATE/sessions/bw4.edits" 2>/dev/null)" " x.py"
  PAYLOAD='{"session_id":"bw5","tool_name":"Bash","tool_input":{"command":"cat > README.md <<EOF\na.ts -> b.ts\nEOF"}}'
  run_hook "$mode" "$KIT/hooks/code-detect.sh" pretool
  PAYLOAD='{"session_id":"bw6","tool_name":"Bash","tool_input":{"command":"python3 -c \"open('"'"'out.txt'"'"','"'"'w'"'"')\""}}'
  if with_timeout 5 run_hook "$mode" "$KIT/hooks/code-detect.sh" pretool; then pass "[$mode] 1: code-detect on python open('out.txt','w') returns"
  else fail "[$mode] 1: code-detect on python open('out.txt','w')" "rc=$WD_RC (124 = hung, killed)"; fi
  rm -f "$STATE/sessions/bw8.edits"
  PAYLOAD=$(printf '{"session_id":"bw8","tool_name":"Bash","tool_input":{"command":"python3 -c \\"print(%s)\\""}}' "'$big4'")
  start=$SECONDS
  with_timeout 8 run_hook "$mode" "$KIT/hooks/code-detect.sh" pretool
  el=$((SECONDS - start))
  [ "$WD_RC" != 124 ] && [ "$el" -le 3 ] && pass "[$mode] 4: code-detect on a 400 KB Bash payload finishes in under 3 s (${el}s)" || fail "[$mode] 4: code-detect 400 KB" "rc=$WD_RC ${el}s"
  case "$(cat "$STATE/sessions/bw8.edits" 2>/dev/null)" in ""|*" bash:large") pass "[$mode] 4: 400 KB payload: nothing or bash:large logged" ;; *) fail "[$mode] 4: 400 KB log" "$(cat "$STATE/sessions/bw8.edits")" ;; esac
  # 2: the size guard counts BYTES: a Thai payload just under 131072 characters is ~390 KB
  rm -f "$STATE/sessions/bw9.edits"
  thai=$(awk 'BEGIN { for (i = 0; i < 130000; i++) printf "\340\270\201" }')
  PAYLOAD=$(printf '{"session_id":"bw9","tool_name":"Bash","tool_input":{"command":"python3 -c \\"print(%s)\\""}}' "'$thai'")
  start=$SECONDS
  EXTRA_ENV="LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8" with_timeout 8 run_hook "$mode" "$KIT/hooks/code-detect.sh" pretool
  el=$((SECONDS - start))
  [ "$WD_RC" != 124 ] && [ "$el" -le 3 ] && pass "[$mode] 2: ~390 KB Thai payload (UTF-8 locale) handled in under 3 s (${el}s)" || fail "[$mode] 2: Thai payload" "rc=$WD_RC ${el}s"
  case "$(cat "$STATE/sessions/bw9.edits" 2>/dev/null)" in ""|*" bash:large") pass "[$mode] 2: Thai payload: nothing or bash:large logged" ;; *) fail "[$mode] 2: Thai log" "$(cat "$STATE/sessions/bw9.edits")" ;; esac
  PAYLOAD='{"session_id":"bw7","tool_name":"Bash","tool_input":{"command":"python3 -c \"open('"'"'.py'"'"','"'"'w'"'"')\""}}'
  if with_timeout 5 run_hook "$mode" "$KIT/hooks/code-detect.sh" pretool; then pass "[$mode] 1: code-detect on open('.py','w') returns"
  else fail "[$mode] 1: code-detect on open('.py','w')" "rc=$WD_RC (124 = hung, killed)"; fi
  [ ! -f "$STATE/sessions/bw5.edits" ] && pass "[$mode] A heredoc into README.md via code-detect: not logged" || fail "[$mode] A README heredoc" "$(cat "$STATE/sessions/bw5.edits")"
done
finish

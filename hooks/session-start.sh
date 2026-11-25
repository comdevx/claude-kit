#!/bin/bash
# SessionStart hook. Usage: session-start.sh <discipline|code|platform>
# Emits additionalContext for the session. Never blocks; silent on any problem.
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$KIT_ROOT/hooks/lib.sh" 2>/dev/null || exit 0

mode="${1:-}"
input=$(cat 2>/dev/null || true)
[ -n "$input" ] || exit 0

sid=$(kit_json_get "$input" session_id)
source_kind=$(kit_json_get "$input" source)
cwd=$(kit_json_get "$input" cwd)
[ -n "$cwd" ] || cwd="$PWD"
cwd=$(kit_norm_path "$cwd")

has_manifest() { # dir
  local d="$1" f n=0
  for f in package.json pyproject.toml go.mod Cargo.toml pom.xml Gemfile composer.json CMakeLists.txt Makefile \
           build.gradle build.gradle.kts setup.py requirements.txt deno.json; do
    [ -f "$d/$f" ] && return 0
  done
  for f in "$d"/*.csproj "$d"/*.sln "$d"/build.gradle*; do
    [ -f "$f" ] && return 0
  done
  for f in "$d"/*; do
    n=$((n + 1)); [ "$n" -gt 400 ] && break
    [ -f "$f" ] && kit_is_source_path "$f" && return 0
  done
  return 1
}

is_code_project() { # dir
  local d h r p
  d=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  h=$(cd "$HOME" 2>/dev/null && pwd -P)
  [ "$d" = "/" ] && return 1
  [ -n "$h" ] && [ "$d" = "$h" ] && return 1
  r="$d"
  while :; do
    [ -e "$r/.git" ] && break
    p=$(dirname "$r")
    [ "$p" = "$r" ] && return 1
    r="$p"
  done
  has_manifest "$d" && return 0
  if [ "$r" != "$d" ] && [ "$r" != "$h" ] && has_manifest "$r"; then return 0; fi
  return 1
}

case "$mode" in
  discipline)
    models=$(kit_model_text "$input")
    case "$models" in *fable*|*mythos*) exit 0 ;; esac
    kit_emit SessionStart "$(kit_rules_text "$KIT_ROOT/rules/discipline.md")" "rules/discipline.md"
    ;;
  platform)
    f="$KIT_ROOT/rules/platform-$(kit_os).md"
    kit_emit SessionStart "$(kit_rules_text "$f")" "rules/platform-$(kit_os).md"
    ;;
  code)
    sd=""; s=""
    if [ -n "$sid" ]; then
      sd=$(kit_sess_dir); s=$(kit_safe "$sid")
      kit_prune
      case "$source_kind" in
        compact|resume|fork) ;;
        *) rm -f "$sd/$s.code" "$sd/$s".inj.* 2>/dev/null ;;   # startup / clear: fresh context
      esac
    fi
    inject=0
    case "$source_kind" in
      compact|resume|fork) [ -n "$sid" ] && [ -f "$sd/$s.code" ] && inject=1 ;;
    esac
    [ "$inject" = 1 ] || { is_code_project "$cwd" && inject=1; }
    [ "$inject" = 1 ] || exit 0
    text=$(kit_rules_text "$KIT_ROOT/rules/code.md")
    [ -n "$text" ] || exit 0
    if [ -n "$sid" ]; then
      : > "$sd/$s.code"
      : > "$sd/$s.inj.main"
    fi
    kit_emit SessionStart "$text" "rules/code.md"
    ;;
esac
exit 0

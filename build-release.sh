#!/bin/bash
# Build the single-file installers: dist/install.sh, dist/install.ps1 and dist/SHA256SUMS.
#
#   bash build-release.sh [--worktree] [--version X] [--repo owner/name] [--out DIR]
#
#   --worktree   build from the working tree (tracked + untracked-not-ignored files) for local testing;
#                default: the committed tree of HEAD (git archive)
#   --version X  version string to embed (default: git describe --tags --always --dirty)
#   --repo R     GitHub repo the installed `claude-kit update` downloads from (replaces <owner>/claude-kit)
#   --out DIR    output dir (default: dist/)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
worktree=0; version=""; repo=""; out="$ROOT/dist"
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) worktree=1 ;;
    --version) version="$2"; shift ;;
    --repo) repo="$2"; shift ;;
    --out) out="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "build-release: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
die() { echo "build-release: $*" >&2; exit 1; }
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}

cd "$ROOT" || die "cannot cd to $ROOT"
git rev-parse --git-dir >/dev/null 2>&1 || die "$ROOT is not a git checkout. build-release.sh packs the files git tracks (git ls-files / git archive), so it (and the test suite, which builds the installers) must run inside a clone of the repository."
[ -n "$version" ] || version=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
case "$version" in *[!A-Za-z0-9._+-]*) die "version may only contain A-Z a-z 0-9 . _ + -" ;; esac

work=$(mktemp -d "${TMPDIR:-/tmp}/claude-kit-build.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$work"' EXIT
stage="$work/stage"; mkdir -p "$stage"

# Files that are not part of the installed kit.
excluded() {
  case "$1" in
    tests/*|dist/*|.github/*|installer/*.tmpl|build-release.sh|.gitignore|.gitattributes) return 0 ;;
  esac
  return 1
}

if [ "$worktree" = 1 ]; then
  git ls-files -z --cached --others --exclude-standard > "$work/files" || die "git ls-files failed"
  while IFS= read -r -d '' f; do
    excluded "$f" && continue
    [ -f "$f" ] || continue   # deleted in the working tree
    mkdir -p "$stage/$(dirname "$f")" && cp -p "$f" "$stage/$f" || die "copy failed: $f"
  done < "$work/files"
else
  git archive --format=tar HEAD > "$work/head.tar" || die "git archive failed (is there a commit?)"
  mkdir -p "$work/head" && (cd "$work/head" && tar -xf ../head.tar) || die "cannot unpack HEAD"
  (cd "$work/head" && find . -type f | sed 's#^\./##') > "$work/files"
  while IFS= read -r f; do
    excluded "$f" && continue
    mkdir -p "$stage/$(dirname "$f")" && cp -p "$work/head/$f" "$stage/$f" || die "copy failed: $f"
  done < "$work/files"
fi

for need in installer/setup-core.sh bin/claude-kit hooks/settings.fragment.json rules/core.md; do
  [ -f "$stage/$need" ] || die "payload is missing $need"
done
printf '%s\n' "$version" > "$stage/VERSION"
if [ -n "$repo" ]; then
  case "$repo" in */*) ;; *) die "--repo must look like owner/name" ;; esac
  sed "s#^KIT_GITHUB_REPO=.*#KIT_GITHUB_REPO=\"$repo\"#" "$stage/bin/claude-kit" > "$work/ck" && cat "$work/ck" > "$stage/bin/claude-kit"
fi
chmod +x "$stage/bin/claude-kit" "$stage/installer/setup-core.sh" "$stage"/hooks/*.sh 2>/dev/null

# Payloads: tar.gz for install.sh, zip for install.ps1.
# No macOS extended attributes / resource forks in the payload (GNU tar on Linux warns about the
# LIBARCHIVE.xattr headers bsdtar would otherwise add): COPYFILE_DISABLE plus bsdtar's own switches.
tarflags=""
if tar --version 2>/dev/null | grep -qi bsdtar; then tarflags="--no-xattrs --no-mac-metadata --no-acls"; fi
(cd "$stage" && COPYFILE_DISABLE=1 tar $tarflags -cf - . | gzip -9 -n > "$work/payload.tar.gz") || die "tar failed"
# Python 3 as python3, or as python (Windows / Git Bash usually only has `python`)
PY3=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then PY3="$c"; break; fi
done
if command -v zip >/dev/null 2>&1; then
  (cd "$stage" && zip -qr -X "$work/payload.zip" .) || die "zip failed"
elif [ -n "$PY3" ]; then
  "$PY3" -I -c 'import os, sys, zipfile
src, dst = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as z:
    for d, _, fs in os.walk(src):
        for f in fs:
            p = os.path.join(d, f); z.write(p, os.path.relpath(p, src))' "$stage" "$work/payload.zip" || die "zip (python) failed"
else
  die "zip or Python 3 (python3 or python) is required to build install.ps1"
fi

b64() { base64 < "$1" | tr -d '\r\n' | fold -w 64; echo; }
mkdir -p "$out" || die "cannot create $out"

sh_sum=$(sha256_of "$work/payload.tar.gz")
sed -e "s/__KIT_VERSION__/$version/g" -e "s/__PAYLOAD_SHA256__/$sh_sum/" "$ROOT/installer/install.sh.tmpl" > "$work/install.sh"
grep -qx '__CLAUDE_KIT_PAYLOAD_BELOW__' "$work/install.sh" || die "install.sh.tmpl must end with the marker line"
b64 "$work/payload.tar.gz" >> "$work/install.sh"

ps_sum=$(sha256_of "$work/payload.zip")
b64 "$work/payload.zip" > "$work/payload.zip.b64"
awk -v b64file="$work/payload.zip.b64" -v ver="$version" -v sum="$ps_sum" '
  $0 == "__PAYLOAD_B64__" { while ((getline l < b64file) > 0) if (l != "") print l; next }
  { gsub(/__KIT_VERSION__/, ver); gsub(/__PAYLOAD_SHA256__/, sum); print }' "$ROOT/installer/install.ps1.tmpl" > "$work/install.ps1"

cp "$work/install.sh" "$out/install.sh" && chmod +x "$out/install.sh"
cp "$work/install.ps1" "$out/install.ps1"
(cd "$out" && printf '%s  install.sh\n%s  install.ps1\n' "$(sha256_of install.sh)" "$(sha256_of install.ps1)" > SHA256SUMS)
n=$(cd "$stage" && find . -type f | wc -l | tr -d ' ')
echo "build-release: version $version, $n payload files"
echo "  $out/install.sh  ($(wc -c < "$out/install.sh" | tr -d ' ') bytes)"
echo "  $out/install.ps1 ($(wc -c < "$out/install.ps1" | tr -d ' ') bytes)"
echo "  $out/SHA256SUMS"

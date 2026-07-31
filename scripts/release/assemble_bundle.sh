#!/usr/bin/env bash
# assemble_bundle.sh -- stage, verify, and zip the Maldita Castilla MiSTer
# release bundle from a built RBF + engine plus the repo's pinned sources.
#
# Usage: assemble_bundle.sh <rbf> <engine> <out_dir> <version>
#   rbf      built _Other/MalditaCastilla_YYYYMMDD.rbf
#   engine   built armhf gmloader binary
#   out_dir  output dir (created); zip + sha256sums.txt + bundle/ land here
#   version  release version string (e.g. v1.0.0)
#
# The manifest check is exhaustive: any file missing from -- or unexpected
# in -- the staged tree fails the assembly. Run locally with stub inputs to
# test (see docs/superpowers/plans/2026-07-30-release-ci.md Task 4).
set -euo pipefail

[ $# -eq 4 ] || { echo "usage: $0 <rbf> <engine> <out_dir> <version>" >&2; exit 2; }
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RBF="$1"; ENGINE="$2"; OUT="$3"; VERSION="$4"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

# This repo now owns _handler.sh directly; the engine and its whole runtime
# closure (including Mesa) come from the one submodule.
GMNEXT="$REPO/external/gmloader-next"
MALDITA="$REPO"

fail() { echo "ASSEMBLE FAIL: $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# --- input gates -------------------------------------------------------------
[ -f "$RBF" ]    || fail "RBF not found: $RBF"
[ -f "$ENGINE" ] || fail "engine not found: $ENGINE"
RBF_SIZE=$(wc -c < "$RBF")
[ "$RBF_SIZE" -ge 1000000 ] || fail "RBF implausibly small ($RBF_SIZE bytes)"
file "$ENGINE" | grep "ELF 32-bit" | grep -q "ARM" \
    || fail "engine is not a 32-bit ARM ELF: $(file "$ENGINE")"

# --- stage the SD-card tree --------------------------------------------------
BUNDLE="$OUT/bundle"
rm -rf "$BUNDLE"
GMDIR="$BUNDLE/games/gmloader"
mkdir -p "$BUNDLE/_Other" "$BUNDLE/games/Maldita Castilla" \
         "$GMDIR/mesa" "$GMDIR/lib/armeabi-v7a" "$GMDIR/APKs"

cp "$RBF" "$BUNDLE/_Other/"
cp "$MALDITA/games/Maldita Castilla/_handler.sh" "$BUNDLE/games/Maldita Castilla/"
cp "$ENGINE" "$GMDIR/gmloader"; chmod +x "$GMDIR/gmloader"
cp "$GMNEXT/gmloader.json" "$GMDIR/"
cp "$GMNEXT/3rdparty/gles2-sw/libGLES_sw.so" "$GMDIR/"
cp "$GMNEXT/runtime/mesa/"*.so* "$GMDIR/mesa/"
cp "$GMNEXT/lib/armeabi-v7a/libstdc++.so" "$GMDIR/lib/armeabi-v7a/"
cp "$REPO/release/APKs-README.txt" "$GMDIR/APKs/README.txt"
cp "$REPO/release/README.md" "$BUNDLE/README.md"

# --- exhaustive manifest check ----------------------------------------------
RBF_NAME=$(basename "$RBF")
EXPECTED=$(cat <<EOF
README.md
_Other/$RBF_NAME
games/Maldita Castilla/_handler.sh
games/gmloader/APKs/README.txt
games/gmloader/gmloader
games/gmloader/gmloader.json
games/gmloader/lib/armeabi-v7a/libstdc++.so
games/gmloader/libGLES_sw.so
games/gmloader/mesa/libEGL.so.1
games/gmloader/mesa/libGLESv2.so.2
games/gmloader/mesa/libdrm.so.2
games/gmloader/mesa/libglapi.so.0
games/gmloader/mesa/swrast_dri.so
EOF
)
ACTUAL=$(cd "$BUNDLE" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
if [ "$ACTUAL" != "$(printf '%s\n' "$EXPECTED" | LC_ALL=C sort)" ]; then
    echo "--- expected ---" >&2; printf '%s\n' "$EXPECTED" | LC_ALL=C sort >&2
    echo "--- actual ---" >&2;   printf '%s\n' "$ACTUAL" >&2
    fail "bundle manifest mismatch"
fi

# --- zip + checksums ---------------------------------------------------------
ZIP="$OUT/MalditaCastilla-MiSTer-$VERSION.zip"
rm -f "$ZIP"
(cd "$BUNDLE" && zip -r -q "$ZIP" .)
(cd "$BUNDLE" && find . -type f | sed 's|^\./||' | LC_ALL=C sort \
    | while IFS= read -r f; do sha "$f"; done) > "$OUT/sha256sums.txt"
(cd "$OUT" && sha "$(basename "$ZIP")") >> "$OUT/sha256sums.txt"

echo "OK: $ZIP ($(wc -c < "$ZIP") bytes, $(printf '%s\n' "$ACTUAL" | wc -l | tr -d ' ') files)"

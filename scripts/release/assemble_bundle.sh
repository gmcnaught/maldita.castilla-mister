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
# The game data comes from release/gamedata/ in this checkout -- see
# release/gamedata/SOURCE.txt for its origin and licence.
#
# The manifest check is exhaustive: any file missing from -- or unexpected
# in -- the staged tree fails the assembly. Run locally with stub inputs to
# test (see docs/superpowers/plans/2026-07-30-release-ci.md Task 4).
set -euo pipefail

[ $# -eq 4 ] || { echo "usage: $0 <rbf> <engine> <out_dir> <version>" >&2; exit 2; }
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RBF="$1"; ENGINE="$2"; OUT="$3"; VERSION="$4"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
GAMEDATA="$REPO/release/gamedata"

# This repo now owns launch.sh directly; the engine and its whole runtime
# closure (including Mesa) come from the one submodule.
GMNEXT="$REPO/external/gmloader-next"
MALDITA="$REPO"

fail() { echo "ASSEMBLE FAIL: $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# --- input gates -------------------------------------------------------------
[ -f "$RBF" ]    || fail "RBF not found: $RBF"
[ -f "$ENGINE" ] || fail "engine not found: $ENGINE"
[ -d "$GAMEDATA" ] || fail "game data not found: $GAMEDATA"
RBF_SIZE=$(wc -c < "$RBF")
[ "$RBF_SIZE" -ge 1000000 ] || fail "RBF implausibly small ($RBF_SIZE bytes)"
file "$ENGINE" | grep "ELF 32-bit" | grep -q "ARM" \
    || fail "engine is not a 32-bit ARM ELF: $(file "$ENGINE")"

# gmloader-next/CLAUDE.md: a bookworm base image produces GLIBC_2.34+ symbols
# that MiSTer's Buildroot ld.so cannot resolve -- an unloadable engine with
# every OTHER gate (ELF arch, MISTER_BUILD symbol) still green. The engine's
# validated bullseye cross-build ("Max GLIBC 2.29 (ok)", CLAUDE.md line 109)
# is the ceiling actually exercised on-device; assert it here so a future
# base-image bump fails loudly instead of shipping a dead engine.
GLIBC_CEILING="2.29"
command -v strings >/dev/null 2>&1 \
    || fail "strings not available -- cannot verify the engine's GLIBC ceiling"
ENGINE_MAX_GLIBC=$(strings "$ENGINE" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' \
    | sed 's/^GLIBC_//' | sort -V | tail -1)
[ -n "$ENGINE_MAX_GLIBC" ] \
    || fail "no GLIBC_* symbol versions found in $ENGINE -- cannot verify glibc ceiling"
if [ "$(printf '%s\n%s\n' "$GLIBC_CEILING" "$ENGINE_MAX_GLIBC" | sort -V | tail -1)" != "$GLIBC_CEILING" ]; then
    fail "engine requires GLIBC_$ENGINE_MAX_GLIBC > ceiling GLIBC_$GLIBC_CEILING -- " \
         "MiSTer's Buildroot cannot load this (see gmloader-next/CLAUDE.md 'Mesa (soft GL for MISTER_NATIVE_VIDEO)')"
fi

# --- stage the SD-card tree --------------------------------------------------
BUNDLE="$OUT/bundle"
rm -rf "$BUNDLE"
GMDIR="$BUNDLE/games/gmloader"
mkdir -p "$BUNDLE/_Other" "$BUNDLE/games/Maldita Castilla" "$BUNDLE/Scripts" \
         "$GMDIR/mesa" "$GMDIR/lib/armeabi-v7a" "$GMDIR/APKs" "$GMDIR/saves"

cp "$RBF" "$BUNDLE/_Other/"
# launch.sh, NOT _handler.sh: that name is Master_Daemon's discovery predicate,
# and a daemon that also spawns it puts a second engine on the fabric control
# block. The Scripts entry ships with it because it is now the only thing that
# invokes it — without it a bundle install loads the core and starts nothing.
cp "$MALDITA/games/Maldita Castilla/launch.sh" "$BUNDLE/games/Maldita Castilla/"
cp "$MALDITA/Scripts/MalditaCastilla.sh" "$BUNDLE/Scripts/"
chmod +x "$BUNDLE/games/Maldita Castilla/launch.sh" "$BUNDLE/Scripts/MalditaCastilla.sh"

# The write-combining mapping (mem_wc): the loader plus every prebuilt module
# object we have. deploy.py picks the object by the device's `uname -r` and
# installs the winner as plain mem_wc.ko; a bundle is assembled once for every
# device, so it ships them all under their vermagic names and mem_wc_load.sh
# does the match on-device.
#
# Both halves are needed or neither does anything: without this the bundle's
# engine maps the fabric window strongly-ordered (~80 MB/s vs ~814).
# Not shipping the objects is safe but slow, so the count is asserted below
# rather than left to a glob that can quietly match nothing.
MEMWC_KOS=()
while IFS= read -r ko; do MEMWC_KOS+=("$ko"); done < <(
    find "$REPO/tools/mister-mem-wc/prebuilt" -maxdepth 1 -name 'mem_wc-*.ko' \
        | LC_ALL=C sort)
[ "${#MEMWC_KOS[@]}" -ge 1 ] \
    || fail "no tools/mister-mem-wc/prebuilt/mem_wc-*.ko to ship -- the bundle's engine would map DDR strongly-ordered"
cp "$MALDITA/games/Maldita Castilla/mem_wc_load.sh" "$BUNDLE/games/Maldita Castilla/"
cp "${MEMWC_KOS[@]}" "$BUNDLE/games/Maldita Castilla/"
# Sourced, not executed; insmod'd, not run. 644 on both, matching deploy.py.
chmod 644 "$BUNDLE/games/Maldita Castilla/mem_wc_load.sh" \
          "$BUNDLE/games/Maldita Castilla/"mem_wc-*.ko
cp "$ENGINE" "$GMDIR/gmloader"; chmod +x "$GMDIR/gmloader"
cp "$GMNEXT/gmloader.json" "$GMDIR/"
cp "$GMNEXT/3rdparty/gles2-sw/libGLES_sw.so" "$GMDIR/"
cp "$GMNEXT/runtime/mesa/"*.so* "$GMDIR/mesa/"
cp "$GMNEXT/lib/armeabi-v7a/libstdc++.so" "$GMDIR/lib/armeabi-v7a/"
cp "$REPO/release/APKs-README.txt" "$GMDIR/APKs/README.txt"
cp "$REPO/release/README.md" "$BUNDLE/README.md"

# The game data. Maldita Castilla is CC BY-NC-ND 4.0 (Locomalito / Gryzor87),
# so it ships unmodified with the game's own licence text and credits readme
# beside it -- that is what the attribution and no-derivatives terms ask of us.
# SOURCE.txt is deliberately not copied: it documents the files for anyone
# reading the repo, and has no business on an SD card.
cp "$GAMEDATA/mygame.apk"                  "$GMDIR/mygame.apk"
cp "$GAMEDATA/game.droid"                  "$GMDIR/saves/game.droid"
cp "$GAMEDATA/options.ini"                 "$GMDIR/saves/options.ini"
cp "$GAMEDATA/LICENSE.malditacastilla.txt" "$GMDIR/LICENSE.malditacastilla.txt"
cp "$GAMEDATA/maldita-castilla-readme.txt" "$GMDIR/maldita-castilla-readme.txt"

# --- exhaustive manifest check ----------------------------------------------
RBF_NAME=$(basename "$RBF")
EXPECTED=$(cat <<EOF
README.md
_Other/$RBF_NAME
Scripts/MalditaCastilla.sh
games/Maldita Castilla/launch.sh
games/Maldita Castilla/mem_wc_load.sh
games/gmloader/APKs/README.txt
games/gmloader/LICENSE.malditacastilla.txt
games/gmloader/gmloader
games/gmloader/gmloader.json
games/gmloader/lib/armeabi-v7a/libstdc++.so
games/gmloader/libGLES_sw.so
games/gmloader/maldita-castilla-readme.txt
games/gmloader/mesa/libEGL.so.1
games/gmloader/mesa/libGLESv2.so.2
games/gmloader/mesa/libdrm.so.2
games/gmloader/mesa/libglapi.so.0
games/gmloader/mesa/swrast_dri.so
games/gmloader/mygame.apk
games/gmloader/saves/game.droid
games/gmloader/saves/options.ini
EOF
)
# The module objects are the one part of the manifest that is not a fixed list:
# it grows a line per MiSTer kernel we have a prebuilt for. Derived from the
# same glob that staged them, so an object added to prebuilt/ ships and is
# accounted for without touching this list, while anything else appearing in
# the tree still fails the comparison.
for ko in "${MEMWC_KOS[@]}"; do
    EXPECTED="$EXPECTED
games/Maldita Castilla/$(basename "$ko")"
done
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

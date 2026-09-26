#!/usr/bin/env bash
# assemble_bundle.sh -- stage, verify, and zip the Maldita Castilla MiSTer
# release bundle from a built RBF + engine plus the repo's pinned sources.
#
# Usage: assemble_bundle.sh <rbf> <engine> <hook> <out_dir> <version>
#   rbf      built _Other/MalditaCastilla_YYYYMMDD.rbf
#   engine   built armhf gmloader binary
#   hook     built armhf MiSTer_hybrid (external/mister-hybrid-platform
#            device/main-hook/build-hps.sh) -- MiSTer.ini's `main=` target, what
#            makes the Cores-browser entry start the engine. REQUIRED: releases up
#            to v0.2.1 shipped without a main= binary, so selecting the core from
#            Cores -> _Other loaded the bitstream and started nothing.
#
# The launch path (games/Maldita Castilla/launch.sh + platform/, Scripts entries,
# linux/hybrid.d registry entry, MGL, mem_wc modules) is rendered from
# mister-port.toml by external/mister-hybrid-platform.
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

[ $# -eq 5 ] || { echo "usage: $0 <rbf> <engine> <hook> <out_dir> <version>" >&2; exit 2; }
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RBF="$1"; ENGINE="$2"; WRAPPER="$3"; OUT="$4"; VERSION="$5"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
GAMEDATA="$REPO/release/gamedata"

# The engine and its whole runtime closure (including Mesa) come from gmloader-next.
GMNEXT="$REPO/external/gmloader-next"
PLAT="$REPO/external/mister-hybrid-platform"

fail() { echo "ASSEMBLE FAIL: $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# --- input gates -------------------------------------------------------------
[ -f "$RBF" ]     || fail "RBF not found: $RBF"
[ -f "$ENGINE" ]  || fail "engine not found: $ENGINE"
[ -f "$WRAPPER" ] || fail "MiSTer_hybrid not found: $WRAPPER (build it with $PLAT/device/main-hook/build-hps.sh)"
[ -d "$GAMEDATA" ] || fail "game data not found: $GAMEDATA"
RBF_SIZE=$(wc -c < "$RBF")
[ "$RBF_SIZE" -ge 1000000 ] || fail "RBF implausibly small ($RBF_SIZE bytes)"
file "$ENGINE" | grep "ELF 32-bit" | grep -q "ARM" \
    || fail "engine is not a 32-bit ARM ELF: $(file "$ENGINE")"
file "$WRAPPER" | grep "ELF 32-bit" | grep -q "ARM" \
    || fail "wrapper is not a 32-bit ARM ELF: $(file "$WRAPPER")"

# gmloader-next/CLAUDE.md: a bookworm base image produces GLIBC_2.34+ symbols
# that MiSTer's Buildroot ld.so cannot resolve -- an unloadable binary with
# every OTHER gate (ELF arch, MISTER_BUILD symbol) still green. The engine's
# validated bullseye cross-build ("Max GLIBC 2.29 (ok)", CLAUDE.md line 109)
# is the ceiling actually exercised on-device; assert it here so a future
# base-image bump fails loudly instead of shipping something dead.
#
# Applied to the wrapper too, and there it is worse than a dead binary: MiSTer
# only execs `main=` if FileExists() (user_io.cpp:1436), not if it LOADS, so an
# unloadable MiSTer_hybrid is exec'd and dies, taking the OSD with it. It is
# built from the platform's cross image -- a different bullseye image from the
# engine's, and therefore a second thing that can be bumped.
GLIBC_CEILING="2.29"
command -v strings >/dev/null 2>&1 \
    || fail "strings not available -- cannot verify GLIBC ceilings"
check_glibc_ceiling() {
    local what="$1" bin="$2" max
    max=$(strings "$bin" | grep -oE 'GLIBC_[0-9]+\.[0-9]+' \
        | sed 's/^GLIBC_//' | sort -V | tail -1)
    [ -n "$max" ] \
        || fail "no GLIBC_* symbol versions found in $bin -- cannot verify $what's glibc ceiling"
    if [ "$(printf '%s\n%s\n' "$GLIBC_CEILING" "$max" | sort -V | tail -1)" != "$GLIBC_CEILING" ]; then
        fail "$what requires GLIBC_$max > ceiling GLIBC_$GLIBC_CEILING -- " \
             "MiSTer's Buildroot cannot load this (see gmloader-next/CLAUDE.md 'Mesa (soft GL for MISTER_NATIVE_VIDEO)')"
    fi
}
check_glibc_ceiling engine  "$ENGINE"
check_glibc_ceiling wrapper "$WRAPPER"

# The hook is a Main_MiSTer build, so "an armhf ELF called MiSTer_hybrid" is
# satisfied by a STOCK MiSTer renamed -- which would exec fine, show the OSD, and
# never start the engine. Gate on the registry path and the OSD Reset string
# (.rodata, survives stripping): this core's entry opts in to the Reset restart.
# Process substitution, not `strings ... | grep -q`: -q exits on the first match
# and SIGPIPEs strings, which under `set -o pipefail` fails the whole pipeline.
for s in "/media/fat/linux/hybrid.d" "OSD Reset armed on status bit %d"; do
    grep -qF "$s" <(strings "$WRAPPER") \
        || fail "hook has no '$s' string -- not the MiSTer_hybrid build with OSD Reset (stock Main_MiSTer renamed, or a platform older than feat/osd-reset?)"
done

# --- stage the SD-card tree --------------------------------------------------
BUNDLE="$OUT/bundle"
rm -rf "$BUNDLE"
GMDIR="$BUNDLE/games/gmloader"
mkdir -p "$BUNDLE/_Other" "$GMDIR/mesa" "$GMDIR/lib/armeabi-v7a" "$GMDIR/APKs" "$GMDIR/saves"

cp "$RBF" "$BUNDLE/_Other/"
# Launcher, platform/ (launch_lib, mem_wc loader + every prebuilt module, DDR map),
# Scripts/MalditaCastilla.sh (starts the game; also migrates a pre-platform
# [Maldita Castilla] main=MiSTer_Maldita to MiSTer_hybrid), the CoresMenu toggle,
# linux/hybrid.d/Maldita Castilla.conf, linux/MiSTer_hybrid and the MGL. The
# launcher is launch.sh, NOT _handler.sh: that name is Master_Daemon's discovery
# predicate and would put a second engine on the fabric control block.
python3 "$PLAT/tools/mister_platform.py" render "$REPO/mister-port.toml" --out "$BUNDLE" --hook-binary "$WRAPPER" \
    || fail "mister-platform render failed"
MEMWC_KOS=()
while IFS= read -r ko; do MEMWC_KOS+=("$ko"); done < <(
    find "$BUNDLE/games/Maldita Castilla/platform/mem_wc" -maxdepth 1 -name 'mem_wc-*.ko' | LC_ALL=C sort)
[ "${#MEMWC_KOS[@]}" -ge 1 ] \
    || fail "no platform/mem_wc/mem_wc-*.ko rendered -- the bundle's engine would map DDR strongly-ordered"
cp "$ENGINE" "$GMDIR/gmloader"; chmod +x "$GMDIR/gmloader"
cp "$GMNEXT/gmloader.json" "$GMDIR/"
cp "$GMNEXT/runtime/mesa/"*.so* "$GMDIR/mesa/"
# libGLES_sw.so is a COPY of the vendored Mesa libGLESv2.so.2, not a separate
# artifact. The engine dlopens ./libGLES_sw.so as its bundled GLES library, and
# the only build that works is this Mesa one, whose sole NEEDED is libglapi.so.0
# (gmloader-next runtime/README.md).
#
# It used to come from 3rdparty/gles2-sw/. That build NEEDs libGLdispatch.so.0,
# which is not in the closure, so every release from v0.1.0 to v0.2.0 died at
# `Cannot load libGLES_sw.so`. Supplying libGLdispatch.so.0 as well does not
# rescue it -- on device it then reports `OpenGL: version string (null)` and
# SIGSEGVs inside the runner's GR_D3D_Init. Only the Mesa GLESv2 works.
#
# Copied from the staged mesa/ rather than from GMNEXT a second time, so the two
# destinations are the same bytes by construction; the gate below is what makes
# a future edit that reintroduces a separate source fail here instead of on a
# user's SD card.
cp "$GMDIR/mesa/libGLESv2.so.2" "$GMDIR/libGLES_sw.so"
cmp -s "$GMDIR/libGLES_sw.so" "$GMDIR/mesa/libGLESv2.so.2" \
    || fail "libGLES_sw.so must be byte-identical to mesa/libGLESv2.so.2"
# The static-LLVM swrast_dri.so has libtinfo.so.6 as a direct NEEDED and MiSTer
# does not ship one. Without it Mesa gets as far as an EGL context and then
# `MESA-LOADER: failed to open swrast` -> `eglInitialize failed` -> dead engine,
# so its absence is a silent-black-screen bug, not a degraded mode.
[ -f "$GMDIR/mesa/libtinfo.so.6" ] \
    || fail "runtime/mesa is missing libtinfo.so.6 -- swrast_dri.so cannot load without it"
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
_Other/Maldita Castilla.mgl
Scripts/MalditaCastilla.sh
Scripts/MalditaCastilla_CoresMenu.sh
games/Maldita Castilla/launch.sh
games/Maldita Castilla/platform/ini_main.sh
games/Maldita Castilla/platform/launch_lib.sh
games/Maldita Castilla/platform/mem_wc_load.sh
games/Maldita Castilla/platform/mister_cores.tsv
games/Maldita Castilla/platform/mister_map_gm_fabric.env
games/Maldita Castilla/platform/mister_mem_wc.env
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
games/gmloader/mesa/libtinfo.so.6
games/gmloader/mesa/swrast_dri.so
games/gmloader/mygame.apk
games/gmloader/saves/game.droid
games/gmloader/saves/options.ini
linux/MiSTer_hybrid
linux/hybrid.d/Maldita Castilla.conf
EOF
)
# The module objects are the one part of the manifest that is not a fixed list:
# it grows a line per MiSTer kernel we have a prebuilt for. Derived from the
# same glob that staged them, so an object added to prebuilt/ ships and is
# accounted for without touching this list, while anything else appearing in
# the tree still fails the comparison.
for ko in "${MEMWC_KOS[@]}"; do
    EXPECTED="$EXPECTED
games/Maldita Castilla/platform/mem_wc/$(basename "$ko")"
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

#!/usr/bin/env bash
# Stages a bundle from stub inputs and asserts the manifest is exactly the
# expected paths. The manifest is the release's contract -- this is the
# regression test for the mister-gmloader -> maldita path rebase.
#
# The fixed list below is the whole bundle except the mem_wc module objects,
# which are one line per prebuilt kernel; those are appended from the same
# prebuilt/ directory the assembler globs, so adding a kernel does not require
# editing two lists. The count assertion is what keeps that from degenerating
# into "expect whatever was staged".
#
# The game data comes from release/gamedata/ in the checkout, so it is exercised
# for real here (the 49 MB game.droid is copied, not stubbed).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ASSEMBLE="$REPO/scripts/release/assemble_bundle.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A stub RBF must clear the script's 1 MB plausibility check.
dd if=/dev/zero of="$TMP/MalditaCastilla_test.rbf" bs=1024 count=1200 2>/dev/null

# A stub engine must pass `file ... | grep 'ELF 32-bit' | grep ARM`, so use the
# real thing if a build exists; otherwise skip -- a fake ELF header is not
# worth maintaining.
ENGINE="$REPO/external/gmloader-next/games/gmloader/gmloader"
if [ ! -f "$ENGINE" ]; then
    echo "SKIP: no engine at $ENGINE (run build_mister_arm.sh first) -- NOT VERIFIED, exiting non-zero so a CI runner checking only the exit code cannot report green"
    exit 1
fi

bash "$ASSEMBLE" \
    "$TMP/MalditaCastilla_test.rbf" "$ENGINE" "$TMP/out" "v0.0.0-test" || {
    echo "FAIL: assemble_bundle.sh exited non-zero"; exit 1; }

PREBUILT="$REPO/tools/mister-mem-wc/prebuilt"
KOS=$(find "$PREBUILT" -maxdepth 1 -name 'mem_wc-*.ko' -exec basename {} \; \
        | sed 's|^|games/Maldita Castilla/|')
[ -n "$KOS" ] || { echo "FAIL: no mem_wc-*.ko in $PREBUILT to expect"; exit 1; }

ACTUAL=$(cd "$TMP/out/bundle" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
EXPECTED=$(cat - <(printf '%s\n' "$KOS") <<'EOF' | LC_ALL=C sort
README.md
_Other/MalditaCastilla_test.rbf
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
games/gmloader/mesa/libtinfo.so.6
games/gmloader/mesa/swrast_dri.so
games/gmloader/mygame.apk
games/gmloader/saves/game.droid
games/gmloader/saves/options.ini
EOF
)

if [ "$ACTUAL" != "$EXPECTED" ]; then
    echo "FAIL: manifest mismatch"
    diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$ACTUAL")
    exit 1
fi

[ -f "$TMP/out/MalditaCastilla-MiSTer-v0.0.0-test.zip" ] || { echo "FAIL: no zip"; exit 1; }
[ -f "$TMP/out/sha256sums.txt" ] || { echo "FAIL: no sha256sums.txt"; exit 1; }

# The game data is redistributed unmodified under CC BY-NC-ND, so assert the
# staged bytes are the checked-in bytes rather than trusting the copy.
for f in mygame.apk saves/game.droid saves/options.ini LICENSE.malditacastilla.txt \
         maldita-castilla-readme.txt; do
    src="$REPO/release/gamedata/${f#saves/}"
    cmp -s "$src" "$TMP/out/bundle/games/gmloader/$f" \
        || { echo "FAIL: staged games/gmloader/$f differs from $src"; exit 1; }
done

# mem_wc is only useful if the object insmod will accept is actually present:
# the loader resolves "mem_wc-$(uname -r).ko" beside itself, so a bundle whose
# object was renamed or truncated leaves the engine strongly-ordered with no
# symptom other than frame rate.
while IFS= read -r ko; do
    cmp -s "$PREBUILT/$(basename "$ko")" "$TMP/out/bundle/$ko" \
        || { echo "FAIL: staged $ko differs from $PREBUILT/$(basename "$ko")"; exit 1; }
done <<< "$KOS"
grep -q 'mem_wc-\$(uname -r)\.ko' "$TMP/out/bundle/games/Maldita Castilla/mem_wc_load.sh" \
    || { echo "FAIL: bundled mem_wc_load.sh does not resolve the vermagic-named object"; exit 1; }

# The GL runtime is the one thing here with no on-device fallback: get it wrong
# and the engine never starts, which is exactly how v0.1.0 and v0.2.0 shipped.
# Assert the two properties that were violated, not merely that files exist.
GLDIR="$TMP/out/bundle/games/gmloader"
cmp -s "$GLDIR/libGLES_sw.so" "$GLDIR/mesa/libGLESv2.so.2" \
    || { echo "FAIL: libGLES_sw.so is not the vendored Mesa libGLESv2.so.2 (the gles2-sw build cannot run: NEEDs libGLdispatch.so.0, and SIGSEGVs even when it is supplied)"; exit 1; }
cmp -s "$GLDIR/libGLES_sw.so" "$REPO/external/gmloader-next/3rdparty/gles2-sw/libGLES_sw.so" \
    && { echo "FAIL: libGLES_sw.so is the 3rdparty/gles2-sw build -- that is the v0.1.0/v0.2.0 defect"; exit 1; }
[ -f "$GLDIR/mesa/libtinfo.so.6" ] \
    || { echo "FAIL: mesa/libtinfo.so.6 missing -- static-LLVM swrast_dri.so cannot load, engine dies at eglInitialize"; exit 1; }

echo "PASS: $(printf '%s\n' "$ACTUAL" | wc -l | tr -d ' ')-file manifest, zip and checksums present, game data + mem_wc objects staged byte-identical"

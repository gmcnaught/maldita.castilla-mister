#!/usr/bin/env bash
# Stages a bundle from stub inputs and asserts the manifest is exactly the
# 19 expected paths. The manifest is the release's contract -- this is the
# regression test for the mister-gmloader -> maldita path rebase.
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

ACTUAL=$(cd "$TMP/out/bundle" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
EXPECTED=$(LC_ALL=C sort <<'EOF'
README.md
_Other/MalditaCastilla_test.rbf
Scripts/MalditaCastilla.sh
games/Maldita Castilla/launch.sh
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

echo "PASS: 19-file manifest, zip and checksums present, game data staged byte-identical"

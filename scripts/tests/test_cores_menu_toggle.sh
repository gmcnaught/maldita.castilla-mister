#!/usr/bin/env bash
# Exercises Scripts/MalditaCastilla_CoresMenu.sh -- the release bundle's only
# way to arm MiSTer.ini's `main=`, i.e. to make selecting the core from the
# Cores browser also start the engine.
#
# WHY THIS IS TESTED AT ALL. The script edits a file it does not own: the
# user's MiSTer.ini, holding their video mode, their input config and every
# other core's settings. It runs on device, from the OSD, where the only
# feedback on a bad edit is a machine that behaves oddly afterwards. The two
# failures worth catching before that are (a) mangling or dropping unrelated
# lines and (b) accumulating a duplicate [Maldita Castilla] section on repeated
# runs -- the same defect deploy.py's un-comment-before-append logic exists to
# avoid.
#
# The script takes MC_WRAPPER / MC_INI overrides for exactly this; on the
# device neither is set and it uses the absolute /media/fat paths.
#
# No dependencies: bash + coreutils, matching the rest of scripts/tests/.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TOGGLE="$REPO/Scripts/MalditaCastilla_CoresMenu.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*"; exit 1; }

# The line the script writes follows MC_WRAPPER, so the round-trip assertions
# below use the stand-in's path. The shipped default is a separate, static
# fact -- assert it here rather than inferring it from an overridden run,
# because it is what assemble_bundle.sh cross-checks against the path the
# bundle installs the wrapper to.
grep -qxF 'WRAPPER_DEFAULT="/media/fat/games/gmloader/MiSTer_Maldita"' "$TOGGLE" \
    || fail "the shipped default wrapper path is no longer /media/fat/games/gmloader/MiSTer_Maldita"
grep -qxF 'INI_DEFAULT="/media/fat/MiSTer.ini"' "$TOGGLE" \
    || fail "the shipped default ini path is no longer /media/fat/MiSTer.ini"

# A stand-in wrapper: the gate is the maldita_hook.cpp .rodata string, so a
# text file carrying it is a faithful stand-in for the check under test (the
# real ELF gates live in assemble_bundle.sh and are tested there).
GOODWRAP="$TMP/MiSTer_Maldita"
printf 'not an elf, but it carries the marker:\n/media/fat/games/Maldita Castilla/launch.sh\n' > "$GOODWRAP"
BADWRAP="$TMP/stock_MiSTer"
printf 'a stock Main_MiSTer build has no such string\n' > "$BADWRAP"
MAIN_LINE="main=$GOODWRAP"

INI="$TMP/MiSTer.ini"
# A plausible user ini: other cores' sections, and a video mode that must
# survive every edit untouched.
cat > "$INI" <<'EOF'
[MiSTer]
video_mode=8
vsync_adjust=2
fb_terminal=1

[Minimig]
ypbpr=0
EOF
ORIG="$(cat "$INI")"

run() { MC_WRAPPER="$1" MC_INI="$INI" bash "$TOGGLE" >"$TMP/out" 2>"$TMP/err"; }

count_sections() { grep -c '^\[Maldita Castilla\]$' "$INI"; }

# --- 1. arm from a clean ini -------------------------------------------------
run "$GOODWRAP" || fail "arming exited $? -- $(cat "$TMP/err")"
grep -qxF "$MAIN_LINE" "$INI" || fail "arming did not write '$MAIN_LINE'
$(cat "$INI")"
[ "$(count_sections)" -eq 1 ] || fail "expected exactly one [Maldita Castilla] section, got $(count_sections)"
# Every pre-existing line still present, in order.
printf '%s\n' "$ORIG" | while IFS= read -r line; do
    grep -qxF "$line" "$INI" || { echo "FAIL: arming dropped or mangled '$line'"; exit 1; }
done || exit 1
ls "$INI".bak.* >/dev/null 2>&1 || fail "arming left no MiSTer.ini backup"

# --- 2. run again -> disarm --------------------------------------------------
run "$GOODWRAP" || fail "disarming exited $? -- $(cat "$TMP/err")"
grep -qxF "$MAIN_LINE" "$INI" && fail "disarming left the active main= line:
$(cat "$INI")"
grep -q "^;$MAIN_LINE" "$INI" || fail "disarming did not comment the line out:
$(cat "$INI")"

# --- 3. run again -> re-arm by un-commenting, NOT by appending ---------------
run "$GOODWRAP" || fail "re-arming exited $? -- $(cat "$TMP/err")"
grep -qxF "$MAIN_LINE" "$INI" || fail "re-arming did not restore the line"
[ "$(count_sections)" -eq 1 ] \
    || fail "re-arming duplicated the section ($(count_sections) copies) -- this is the defect the un-comment path exists to prevent:
$(cat "$INI")"

# --- 4. refuse a binary without the hook marker ------------------------------
# Disarm first so the next run takes the arming path.
run "$GOODWRAP" || fail "disarm before the negative case exited $?"
if run "$BADWRAP"; then
    fail "armed main= at a binary with no maldita_hook launch.sh string"
fi
grep -q "^main=" "$INI" && fail "a refused arm still wrote an active main= line:
$(cat "$INI")"

# --- 5. refuse a missing binary ----------------------------------------------
if run "$TMP/does-not-exist"; then
    fail "armed main= at a nonexistent path"
fi
grep -q "^main=" "$INI" && fail "a refused arm still wrote an active main= line:
$(cat "$INI")"

# --- 6. an ini that already has an EMPTY [Maldita Castilla] section ----------
# Found on .62: a device whose main= line had been removed by hand keeps the
# section header, and appending a fresh section there gives MiSTer.ini two of
# them. Arming must fill in the existing section instead.
INI="$TMP/hassection.ini"
cat > "$INI" <<'EOF'
[MiSTer]
video_mode=8

[Maldita Castilla]

[Minimig]
ypbpr=0
EOF
run "$GOODWRAP" || fail "arming into an existing section exited $? -- $(cat "$TMP/err")"
[ "$(count_sections)" -eq 1 ] \
    || fail "arming duplicated the existing [Maldita Castilla] section ($(count_sections) copies):
$(cat "$INI")"
grep -qxF "$MAIN_LINE" "$INI" || fail "arming did not write the line into the existing section"
# ...and inside that section, not somewhere later in the file.
awk -v want="$MAIN_LINE" '
    /^\[Maldita Castilla\]$/ { inseg = 1; next }
    /^\[/                    { inseg = 0 }
    inseg && $0 == want      { found = 1 }
    END { exit(found ? 0 : 1) }
' "$INI" || fail "the line landed outside the [Maldita Castilla] section:
$(cat "$INI")"

# --- 7. an ini that does not exist yet is created, not skipped ---------------
INI="$TMP/fresh.ini"
run "$GOODWRAP" || fail "arming against a missing ini exited $? -- $(cat "$TMP/err")"
grep -qxF "$MAIN_LINE" "$INI" || fail "arming did not create a usable fresh ini:
$(cat "$INI" 2>/dev/null)"

echo "PASS: arm/disarm/re-arm round trip, no duplicate section, unrelated ini lines preserved, bad and missing wrappers refused"

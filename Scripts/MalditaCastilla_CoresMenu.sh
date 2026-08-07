#!/bin/bash
#
# Maldita Castilla — Cores-browser entry toggle. Installs to /media/fat/Scripts/
# and appears in MiSTer's OSD under Scripts, next to MalditaCastilla.
#
# WHAT IT DOES: arms (or disarms) the `main=` line in MiSTer.ini that makes
# selecting the core from the Cores browser also start the game engine. Run it
# once after extracting the release; run it again to undo.
#
# WHY IT IS A SEPARATE, EXPLICIT STEP. A zip extract cannot run code, and
# MiSTer.ini is the user's file — it carries their video mode, their input
# config, every other core's settings. Nothing in this project edits it behind
# their back, so arming the hook is a gesture they make on purpose. deploy.py
# does the same edit on a development device; this is that edit, driven from
# the OSD.
#
# WHAT `main=` ACTUALLY MEANS, because it is not "also run this": it names a
# REPLACEMENT for the MiSTer binary. Whatever it points at is what runs
# INSTEAD of MiSTer for this core, inheriting the job of loading cores, driving
# the OSD and serving input. Pointing it at a shell script gives you a machine
# with no MiSTer running at all. It is pointed at MiSTer_Maldita, which is a
# normal Main_MiSTer build (upstream main() and scheduler verbatim) plus one
# call inserted AFTER scheduler_wait_fpga_ready() that forks launch.sh. That
# ordering is the whole point: an earlier build that started the engine BEFORE
# the readiness check wedged 3 launches in 5 on hardware; the current one
# measured 0 in 5.
#
# WHY ARMING IT CANNOT BRICK THE DEVICE: MiSTer only execs the replacement if
# `FileExists(main)` (user_io.cpp:1436-1441 @3380931). A missing or deleted
# MiSTer_Maldita means stock MiSTer just carries on. This script additionally
# refuses to arm anything that is not the real wrapper, and backs MiSTer.ini up
# before every edit.
#
# The Scripts → MalditaCastilla launcher needs none of this and keeps working
# either way.

CORENAME="Maldita Castilla"
# Absolute, and identical to deploy.py's MAIN_LINE and to where the release
# bundle installs the wrapper — assemble_bundle.sh asserts that agreement
# against these two lines. The MC_* overrides exist so scripts/tests/ can
# exercise the MiSTer.ini edit on a host; MiSTer never sets them.
WRAPPER_DEFAULT="/media/fat/games/gmloader/MiSTer_Maldita"
INI_DEFAULT="/media/fat/MiSTer.ini"
WRAPPER="${MC_WRAPPER:-$WRAPPER_DEFAULT}"
INI="${MC_INI:-$INI_DEFAULT}"
MAIN_LINE="main=$WRAPPER"
# The one string that distinguishes our overlay build from a stock Main_MiSTer
# of the same name: the path maldita_hook.cpp forks. Present in .rodata even
# though the binary is stripped, and it is also what the release bundle's
# assembler gates on.
WRAPPER_MARK="/media/fat/games/$CORENAME/launch.sh"

say() { echo "$*"; }
die() { echo "$*" >&2; exit 1; }

armed() { grep -q "^$MAIN_LINE" "$INI" 2>/dev/null; }

backup_ini() {
    cp "$INI" "$INI.bak.$(date +%s)" \
        || die "could not back up $INI — refusing to edit it"
}

# sed to a sibling temp file then rename, rather than `sed -i`. Busybox sed
# does exactly this internally, so nothing is lost on the device; what is
# gained is that the same code runs unmodified under BSD sed, where -i means
# something else entirely (it consumes the next argument as a backup suffix)
# and would corrupt the edit. Same directory, so the rename cannot cross
# filesystems.
ini_sed() {
    local tmp="$INI.tmp.$$"
    sed "$1" "$INI" > "$tmp" && mv "$tmp" "$INI" && return 0
    rm -f "$tmp"
    die "edit failed — $INI is unchanged except for the backup"
}

# Insert a line directly after the FIRST [Maldita Castilla] header. awk, not
# sed: `sed /re/a` appends after every match, and the first-match-only form
# (`0,/re/`) is a GNU extension the device's busybox sed does not have.
ini_insert_in_section() {
    local tmp="$INI.tmp.$$"
    awk -v line="$1" -v sec="[$CORENAME]" '
        { print }
        !ins && $0 == sec { print line; ins = 1 }
    ' "$INI" > "$tmp" && mv "$tmp" "$INI" && return 0
    rm -f "$tmp"
    die "edit failed — $INI is unchanged except for the backup"
}

if armed; then
    say "Cores-browser entry is currently ARMED."
    say "Disarming: selecting the core will load the bitstream only."
    backup_ini
    ini_sed "s|^$MAIN_LINE.*|;$MAIN_LINE  ; disabled by MalditaCastilla_CoresMenu|"
    say ""
    say "Done. Start the game with Scripts -> MalditaCastilla."
    exit 0
fi

# --- arming ------------------------------------------------------------------
[ -f "$WRAPPER" ] \
    || die "not found: $WRAPPER
This release ships it; extract the zip over /media/fat again."
grep -q "$WRAPPER_MARK" "$WRAPPER" \
    || die "$WRAPPER is not the Maldita Castilla wrapper build (no launch.sh hook in it).
Refusing to point MiSTer.ini's main= at it."
[ -x "$WRAPPER" ] || chmod +x "$WRAPPER" \
    || die "could not make $WRAPPER executable"
[ -x "$WRAPPER" ] || die "$WRAPPER is not executable"

if [ ! -f "$INI" ]; then
    say "note: $INI did not exist — creating it with just this section."
    : > "$INI" || die "could not create $INI"
fi

say "Arming the Cores-browser entry."
backup_ini
# Three cases, in this order, so no run of this script can ever leave a second
# [Maldita Castilla] section behind. The middle one is not hypothetical: a
# device that had the line removed by hand, or by an older tool, keeps the
# empty section — appending there produced a duplicate header on .62.
if grep -q "^;$MAIN_LINE" "$INI"; then
    ini_sed "s|^;$MAIN_LINE.*|$MAIN_LINE|"
elif grep -q "^\[$CORENAME\]$" "$INI"; then
    ini_insert_in_section "$MAIN_LINE"
else
    printf '\n[%s]\n%s\n' "$CORENAME" "$MAIN_LINE" >> "$INI" \
        || die "could not append to $INI"
fi

say ""
say "Done. Selecting MalditaCastilla_*.rbf from Cores -> _Other now loads the"
say "core AND starts the game. Takes effect on the next core load; no reboot."
say "Run this entry again to undo. Backups: $INI.bak.*"

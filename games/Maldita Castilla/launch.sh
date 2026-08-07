#!/bin/bash
#
# Maldita Castilla engine launcher. Sets up the engine's environment and execs
# it. Invoked by exactly one of the two entry points that own the launch:
#
#   Scripts/MalditaCastilla.sh   the Scripts-menu entry, which loads the core
#                                itself and then execs this
#   vendor/Main_MiSTer/maldita_hook.cpp   the `main=` wrapper, which forks this
#                                after scheduler_wait_fpga_ready()
#
# WHY IT IS NOT CALLED `_handler.sh` (2026-08-05). MiSTer Frontier's
# Master_Daemon discovers "hybrid cores" purely by testing for an executable
# /media/fat/games/<CORENAME>/_handler.sh — there is no config file and no
# registry (Master_Daemon.sh, discover_cores() and the dispatch loop). Under
# that name the daemon spawns this script on every /tmp/CORENAME change AND
# respawns it whenever its child exits, which collides head-on with either
# entry point above: both are triggered by the same core load, both run the
# `ps | grep` singleton check before either has exec'd, and both launch. That
# puts TWO gmloader processes on one fabric control block — the documented
# dual-engine corruption, measured on .62 2026-08-05 as C_DONE running
# BACKWARDS (0x23E -> 0x224). The daemon is a third-party script we do not own,
# so we deconflict from our side by staying out of its discovery: deploy.py
# installs this as launch.sh and DELETES any /media/fat/games/<CORENAME>/
# _handler.sh it finds.
#
# CONSEQUENCE, and it is deliberate: nothing watches /tmp/CORENAME for us any
# more. Selecting the core from the Cores browser loads the bitstream and
# starts NO engine unless the `main=` handoff is armed (deploy.py
# --main-wrapper). Nothing tears the engine down on a core change either — the
# daemon used to do that via kill_child. Under the HPS takeover that cannot
# arise (no MiSTer, no OSD to change cores from); with the takeover disarmed,
# leaving the core while the engine runs leaves it running.
#
# TRADEOFF unchanged from the daemon era: OSD Reset (feat #4), the joystick SHM
# bridge (feat #2) and crash-respawn are NOT available on this path.

GAMEDIR="/media/fat/games/gmloader"     # engine payload (gmloader, mygame.apk, saves/)
LOGDIR="/media/fat/logs/MalditaCastilla"

# This script's own directory — where mister_takeover.sh and takeover.env live.
# Resolved BEFORE the cd below, and only from $0, so it follows this script
# wherever its caller found it rather than assuming the CONF_STR path.
HANDLER_SELF="$0"
case "$HANDLER_SELF" in /*) ;; *) HANDLER_SELF="$PWD/$HANDLER_SELF" ;; esac
HANDLER_DIR="$(dirname "$HANDLER_SELF")"

cd "$GAMEDIR" || exit 1
mkdir -p "$LOGDIR"

# Singleton guard. If a previous engine is still alive, a second gmloader
# fights the first for the fabric and exits 255. Reap any survivor before
# starting ours.
#
# This is check-then-act and therefore NOT a mutual exclusion: two launchers
# started by the same core load both reach this point before either has exec'd,
# both see nothing, and both proceed. That race is why staying out of
# Master_Daemon's discovery (see the header) is the actual fix rather than a
# tighter guard here. What this still catches is the sequential case — a stale
# engine from a previous session, or a second run of the Scripts entry.
# SIGTERM FIRST, SIGKILL ONLY AS A BACKSTOP. This used to be a bare `killall -9`,
# and -9 is uncatchable: the dying engine ran no teardown, so it left the blitter's
# DDR window at 0x3B000000 exactly as it was mid-frame — a live doorbell
# (C_SUBMIT != C_DONE) over a 256 KiB command ring full of its commands and a heap
# full of its textures. None of that is cleared by load_core (which reconfigures the
# FPGA, not DDR) or by the kernel (the range is outside System RAM), so the engine
# we start next inherits a fabric already executing a batch nobody submitted. The
# engine now handles SIGTERM (raster_backend_mfgpu.cpp, mf_fabric_teardown: wait for
# the ack, zero the rings, park the control block) and its bring-up defends against
# the -9 case anyway — but only one of those two is free, so take it.
#
# 3 s is the cap, not the cost: the teardown's own budget is 250 ms, so a healthy
# engine is gone inside the first `sleep 1` — the same second the old bare -9 spent
# anyway. Whole seconds on purpose: busybox `sleep` only takes fractions when built
# with FEATURE_FANCY_SLEEP, and `killall gmloader` with no signal argument on
# purpose too — busybox killall's `-TERM` spelling is not universal, and TERM is
# already its default.
# NOTE: busybox has NO pkill — use killall.
if ps w | grep -q "[g]mloader -c"; then
    echo "maldita handler: reaping a pre-existing gmloader before relaunch" >&2
    killall gmloader 2>/dev/null
    n=0
    while [ "$n" -lt 3 ] && ps w | grep -q "[g]mloader -c"; do
        sleep 1
        n=$((n + 1))
    done
    if ps w | grep -q "[g]mloader -c"; then
        echo "maldita handler: gmloader ignored SIGTERM after 3s — SIGKILL" >&2
        killall -9 gmloader 2>/dev/null
        sleep 1
    fi
fi

# Rotate the previous log.
mv -f "$LOGDIR/maldita.log" "$LOGDIR/maldita.prev.log" 2>/dev/null

# FPGA settle after core load. Solarus uses 1s; we allow 2s because the fabric's
# first DDR read is what jams ddr_blitter_arb (G_BLT_RD has no timeout) if it is
# issued before the fabric is up — the frame-1 wedge signature (C_SUBMIT climbs,
# C_DONE stays 0 forever). Cheap insurance on a path that only runs at core load.
sleep 2

# The fabric path REQUIRES BOTH of these (see CLAUDE.md): blitter level 2 gives
# the engine ownership of rendering, and RASTER=mfgpu routes it to the FPGA
# rather than the software rasterizer. Setting only one silently falls back.
export GMLOADER_BLITTER=2
export GMLOADER_RASTER=mfgpu

# REQUIRED — matches Scripts/gmloader_diag.sh:164. Without it the surfaceless-Mesa
# closure cannot resolve its own deps and the engine dies during EGL init:
#   MESA-LOADER: failed to open swrast: libtinfo.so.6: cannot open shared object file
#   gmloader/main.cpp:652: eglInitialize failed (eglGetError=0x3001)
# which exits 255 (device-hit 2026-07-25, when Master_Daemon still respawned on
# that exit and turned it into a tight loop).
# Running this from an interactive shell MASKS the bug, because a login shell
# already has a usable LD_LIBRARY_PATH — always test through a real entry point
# (the Scripts menu or the main= handoff), not by hand over SSH.
export LD_LIBRARY_PATH="$GAMEDIR/mesa:$GAMEDIR"

# Optional bench-only override hook (perf diagnostics harness only — see
# this repo's scripts/mister_run.sh). Sourced IFF $GAMEDIR/bench.env
# exists; production launches never create that file, so this block is a
# no-op and the log line below is byte-identical to before this hook existed.
# Placed AFTER the hardcoded exports above so a staged bench.env can ADD
# diagnostic knobs (GMLOADER_MFSUBMIT_STAT, GMLOADER_BLITTER_PROF,
# GMLOADER_DRAW_TRACE, GMLOADER_JOY_SHM, ...) — but note `.` sourcing DOES
# override any variable bench.env also sets, including BLITTER/RASTER: a
# staged `--preset gl` (GMLOADER_BLITTER=0) demonstrably replaces the
# hardcoded BLITTER=2 above. That is intentional (it's how the harness runs
# non-fabric presets), but it means a leftover bench.env is not merely inert
# extra knobs — it silently overrides the required BLITTER/RASTER pair on
# the next unrelated production launch too.
# The harness removes bench.env during its own teardown; a leftover file here
# would silently steer a later, unrelated production launch, so treat one as
# a bug, not a feature.
BENCH_ENV="$GAMEDIR/bench.env"
BENCH_NOTE=""
if [ -f "$BENCH_ENV" ]; then
    . "$BENCH_ENV"
    BENCH_NOTE=" BENCH_ENV=sourced($BENCH_ENV)"
fi

# HPS takeover (opt-in, default OFF). takeover.env lives beside this script and
# is the only thing that arms it; with no such file the two `.` sources below
# are no-ops and the launch takes the same `exec` path it always did.
#
# Sourced AFTER bench.env deliberately: a bench run must be able to force
# takeover off (MALDITA_TAKEOVER=0) for a measurement, and the last assignment
# wins. Design: docs/superpowers/specs/2026-08-04-hps-takeover-launcher-design.md
TAKEOVER_NOTE=""
if [ -f "$HANDLER_DIR/mister_takeover.sh" ]; then
    [ -f "$HANDLER_DIR/takeover.env" ] && . "$HANDLER_DIR/takeover.env"
    . "$HANDLER_DIR/mister_takeover.sh"
    TAKEOVER_NOTE=" TAKEOVER=$MALDITA_TAKEOVER"
fi

echo "maldita handler: CORENAME='$(cat /tmp/CORENAME 2>/dev/null)' \
BLITTER=$GMLOADER_BLITTER RASTER=$GMLOADER_RASTER${BENCH_NOTE}${TAKEOVER_NOTE}" > "$LOGDIR/maldita.log"

# Write-combining for the fabric window (rings + SRC texture heap). Sourced
# AFTER the header echo above, which truncates the log with `>`. Entirely
# optional: the engine falls back to the strongly-ordered /dev/mem mapping on
# its own, so this can only cost frame rate. See mem_wc_load.sh.
[ -f "$HANDLER_DIR/mem_wc_load.sh" ] && . "$HANDLER_DIR/mem_wc_load.sh"

# The takeover path cannot `exec`: this shell has to outlive the engine to run
# the restore. Everything else about the launch is identical.
# The redirect on the probe (rather than an unconditional `exec >>`) keeps the
# non-takeover path's fds exactly as they were, while still capturing the
# reason a takeover was refused — which is the only place that reason is
# recorded. It is a plain function call, not a subshell, so the MiSTer pid/exe
# it discovers survive into takeover_run.
if [ -n "$TAKEOVER_NOTE" ] && tk_should_take_over >> "$LOGDIR/maldita.log" 2>&1; then
    exec >> "$LOGDIR/maldita.log" 2>&1
    takeover_run ./gmloader -c gmloader.json
    exit $?
fi

exec ./gmloader -c gmloader.json >> "$LOGDIR/maldita.log" 2>&1

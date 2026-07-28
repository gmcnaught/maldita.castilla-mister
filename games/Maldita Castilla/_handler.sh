#!/bin/bash
#
# Maldita Castilla auto-launch handler — invoked by MiSTer's Master_Daemon
# (Frontier) when the Maldita FPGA core loads. The daemon watches /tmp/CORENAME
# and routes a loaded core by name ("Maldita Castilla", from the RBF's CONF_STR
# setname, fpga/Maldita.sv:270) -> games/Maldita Castilla/_handler.sh.
#
# WHY THIS EXISTS (2026-07-25): this replaces the MiSTer.ini `main=` wrapper
# (MiSTer_Maldita) as the auto-launch mechanism. A `main=` binary REPLACES
# MiSTer's main() and therefore inherits all of its obligations to the core —
# notably the scheduler's per-iteration `while (!is_fpga_ready(1))
# fpga_wait_to_reset();` guard (scheduler.cpp scheduler_co_poll). The wrapper
# hand-rolls the `#else` branch of main(), which is DEAD CODE (USE_SCHEDULER is
# defined unconditionally in scheduler.h:4), and it spawns the engine at
# maldita_wrapper.cpp:143 BEFORE its first readiness check at :157.
#
# This handler is the pattern the sibling Solarus core uses (solarus-mister
# games/Solarus/_handler.sh) and that this project used before the wrapper:
# stock MiSTer main keeps running and keeps its FPGA-readiness contract, and the
# engine is launched as an ordinary child process. The daemon kills this child
# on a core change, so no supervise loop is needed here.
#
# TRADEOFF: features the wrapper provided are NOT available via this path —
# OSD Reset (feat #4), the joystick SHM bridge (feat #2), and crash-respawn.
# Reinstating the wrapper is deferred to a future plan; if it returns, it must
# first satisfy main()'s contract (readiness before spawn, scheduler_init).

GAMEDIR="/media/fat/games/gmloader"     # engine payload (gmloader, mygame.apk, saves/)
LOGDIR="/media/fat/logs/MalditaCastilla"

cd "$GAMEDIR" || exit 1
mkdir -p "$LOGDIR"

# Singleton guard. If a previous engine is still alive (a stale child, or — as
# seen 2026-07-25 — TWO Master_Daemon instances each spawning a handler), a
# second gmloader fights the first for the fabric and exits 255, which the
# daemon answers by respawning: a tight destructive loop that also rotates this
# log away every iteration. Reap any survivor before starting ours.
# NOTE: busybox has NO pkill — use killall.
if ps w | grep -q "[g]mloader -c"; then
    echo "maldita handler: reaping a pre-existing gmloader before relaunch" >&2
    killall -9 gmloader 2>/dev/null
    sleep 1
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
# which exits 255 -> Master_Daemon respawns -> tight loop (device-hit 2026-07-25).
# Running the handler from an interactive shell MASKS this, because a login shell
# already has a usable LD_LIBRARY_PATH — always test via the daemon, not by hand.
export LD_LIBRARY_PATH="$GAMEDIR/mesa:$GAMEDIR"

# Optional bench-only override hook (perf diagnostics harness only — see
# mister-gmloader scripts/mister_run.sh). Sourced IFF $GAMEDIR/bench.env
# exists; production launches never create that file, so this block is a
# no-op and the log line below is byte-identical to before this hook existed.
# Placed AFTER the hardcoded exports above so a staged bench.env can ADD
# knobs (GMLOADER_MFSUBMIT_STAT, GMLOADER_BLITTER_PROF, GMLOADER_DRAW_TRACE,
# GMLOADER_JOY_SHM, ...) without overriding the required BLITTER/RASTER pair.
# The harness removes bench.env during its own teardown; a leftover file here
# would silently steer a later, unrelated production launch, so treat one as
# a bug, not a feature.
BENCH_ENV="$GAMEDIR/bench.env"
BENCH_NOTE=""
if [ -f "$BENCH_ENV" ]; then
    . "$BENCH_ENV"
    BENCH_NOTE=" BENCH_ENV=sourced($BENCH_ENV)"
fi

echo "maldita handler: CORENAME='$(cat /tmp/CORENAME 2>/dev/null)' \
BLITTER=$GMLOADER_BLITTER RASTER=$GMLOADER_RASTER${BENCH_NOTE}" > "$LOGDIR/maldita.log"

exec ./gmloader -c gmloader.json >> "$LOGDIR/maldita.log" 2>&1

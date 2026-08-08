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

# Overridable only so scripts/tests/test_launch_fabric_gate.sh can run this
# script against a sandbox tree with stubbed busybox/ps/pidof. Production sets
# neither and gets the paths below verbatim.
GAMEDIR="${MALDITA_GAMEDIR:-/media/fat/games/gmloader}"   # engine payload (gmloader, mygame.apk, saves/)
LOGDIR="${MALDITA_LOGDIR:-/media/fat/logs/MalditaCastilla}"

# --- fabric bring-up recovery gate -------------------------------------------
# The frame-1 wedge (C_SUBMIT climbs forever, C_DONE never advances past the
# value it had at reconfigure) is a fabric-side arbiter jam: ddr_blitter_arb's
# G_BLT_RD exits only on ddram_dout_ready with NO timeout, so one blitter DDR
# read that never returns parks the arbiter and starves everything downstream.
# Nothing host-side can un-jam it — the engine drops frames forever and the
# user gets audio with a frozen or black picture. The only known recovery is a
# real FPGA reconfigure.
#
# Measured on .62 2026-08-07 with the v0.3.0 bundle: 1 wedge in 3 reboot->launch
# trials on this entry point. Confirmed fabric-side, not ours — fabric_probe
# (a binary predating this code) wedges identically with NO engine running.
#
# Detection takes the engine's own bring-up verdict as primary and corroborates
# it with the control block; see fabric_verdict for why the register criterion
# is "C_DONE frozen AND still short of C_SUBMIT" rather than anything phrased in
# terms of C_SUBMIT advancing.
#
# Reads are plain HPS->DDR devmem, NOT a fabric publish path. That distinction
# matters: during this wedge every DDR path the FABRIC drives is dead, which is
# why two previous in-fabric wedge probes (v3, v4) could only ever read 0. The
# control block is written by the host and read by us, so it stays readable.
# Addresses are overridable for one reason only: the recovery path is otherwise
# reachable just by winning a 1-in-3 hardware lottery. Pointing FABRIC_DONE at a
# qword nothing writes makes the gate's verdict deterministically "wedged", so
# detect -> kill -> reconfigure -> restart -> retry-cap can be tested on real
# hardware on demand. Production never sets these.
FABRIC_CTRL="${MALDITA_FABRIC_CTRL_ADDR:-0x3B000000}"   # C_SUBMIT (qword 0)
FABRIC_DONE="${MALDITA_FABRIC_DONE_ADDR:-0x3B000028}"   # C_DONE   (qword 5)
FABRIC_RETRY_MARK="${MALDITA_RETRY_MARK:-/tmp/maldita_fabric_retry}"
MISTER_CMD="${MALDITA_MISTER_CMD:-/dev/MiSTer_cmd}"
CORENAME_FILE="${MALDITA_CORENAME_FILE:-/tmp/CORENAME}"
MENU_RBF="${MALDITA_MENU_RBF:-/media/fat/menu.rbf}"
# 4, not 2. A reconfigure clears the jam but not reliably on the first try: the
# v0.3.1 bundle wedged on a reboot trial, both attempts failed, the gate gave up
# — and a single further reconfigure by hand brought it straight back
# (`bring-up ok`, C_DONE advancing). So the cap, not the remedy, was what left a
# dead picture on screen.
#
# Bounded on purpose rather than "retry until it works": each attempt reloads
# the core, so an unbounded loop on a genuinely dead fabric would keep yanking
# the machine between MENU and this core forever, with no way to reach the OSD.
# 4 attempts is ~2 minutes worst case before it gives up and leaves the engine
# running.
FABRIC_MAX_RETRIES="${MALDITA_FABRIC_RETRIES:-4}"
FABRIC_SUBMIT_WAIT_S="${MALDITA_FABRIC_SUBMIT_WAIT_S:-60}"   # engine start -> first submits
FABRIC_SAMPLE_S="${MALDITA_FABRIC_SAMPLE_S:-8}"              # C_DONE observation window
RBF_GLOB="${MALDITA_RBF_GLOB:-/media/fat/_Other/MalditaCastilla_*.rbf}"

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

# WAIT FOR THE FPGA, DO NOT GUESS AT IT.
#
# This used to be a bare `sleep 2` — a guess, and the same class of mistake that
# made the reverted `main=` wrapper wedge 3 launches in 5: it reimplemented part
# of main()'s job and skipped the readiness contract, spawning the engine before
# the FPGA was ready. The wrapper was fixed by running upstream main() and the
# scheduler verbatim and forking us only after scheduler_wait_fpga_ready().
#
# The Scripts path never got that fix. Scripts/MalditaCastilla.sh waits for
# /tmp/CORENAME, which MiSTer writes in user_io.cpp:1171 — that is "the core has
# a name", not "the FPGA is ready" — and then this slept two seconds.
#
# MEASURED, so nobody re-derives it: this wait is defence in depth, NOT the fix
# for the frame-1 wedge. Sampling gpi ~24x/s across a real MENU->core load on
# .62 (2026-08-07) shows bit 31 set for a single sample — order 40 ms — and
# clear BEFORE /tmp/CORENAME changes, so the 1 s CORENAME poll plus the settle
# below already left us ~2 s late, not early. The wedge happens on a fabric that
# reports ready. Do not read the 0/5-vs-1/3 wrapper/Scripts difference as
# evidence of a readiness gap; those are small samples taken days apart, and
# this measurement rules the mechanism out on this path.
#
# So gate on the same bit MiSTer gates on. is_fpga_ready(1) is exactly
# `fpga_gpi_read() >= 0` (fpga_io.cpp:639-644), i.e. bit 31 clear of the FPGA
# manager's gpi register at SOCFPGA_MGR_ADDRESS+0x14 = 0xFF706014
# (fpga_base_addr_ac5.h:15). Reading one documented bit is not reimplementing
# main's responsibilities — it is refusing to guess at the one thing main knows.
#
# What we deliberately do NOT copy is the scheduler's remedy. Upstream pairs the
# poll with fpga_wait_to_reset(), which calls fpga_core_reset(); doing that from
# here cost us "no signal" and a dead OSD once already, so we only ever wait.
FPGA_GPI_ADDR="${MALDITA_FPGA_GPI_ADDR:-0xFF706014}"
FPGA_READY_WAIT_S="${MALDITA_FPGA_READY_WAIT_S:-20}"

fpga_ready() {
    local v
    v="$(busybox devmem "$FPGA_GPI_ADDR" 32 2>/dev/null)" || return 0   # no instrument, don't block
    [ -n "$v" ] || return 0
    [ $(( v & 0x80000000 )) -eq 0 ]
}

waited=0
while ! fpga_ready; do
    if [ "$waited" -ge "$FPGA_READY_WAIT_S" ]; then
        echo "maldita handler: FPGA still not ready after ${FPGA_READY_WAIT_S}s — starting anyway" >&2
        break
    fi
    sleep 1; waited=$((waited + 1))
done
[ "$waited" -gt 0 ] && echo "maldita handler: waited ${waited}s for FPGA ready" >&2

# Settle after readiness. The fabric's first DDR read is what jams
# ddr_blitter_arb (G_BLT_RD has no timeout) if issued before the fabric is up.
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

echo "maldita handler: CORENAME='$(cat "$CORENAME_FILE" 2>/dev/null)' \
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

# --- fabric recovery gate ----------------------------------------------------
# Everything below replaces what used to be a bare `exec ./gmloader`. The exec
# is still the outcome in the healthy case (see engine_exec), so a good launch
# has the same process shape it always did apart from this shell surviving to
# supervise the first few seconds.

devmem_ok() { command -v busybox >/dev/null 2>&1 && busybox devmem "$FABRIC_CTRL" 32 >/dev/null 2>&1; }
ctrl_submit() { busybox devmem "$FABRIC_CTRL" 32 2>/dev/null; }
ctrl_done()   { busybox devmem "$FABRIC_DONE" 32 2>/dev/null; }

engine_exec() { exec ./gmloader -c gmloader.json >> "$LOGDIR/maldita.log" 2>&1; }

# Is a `main=` handoff what is resident? If so a core reload re-execs
# MiSTer_Maldita, which forks a FRESH launch.sh — so this instance must trigger
# the reload and then GET OUT, or the respawned launcher and this one both start
# an engine and we are back to two gmloader processes on one control block (the
# dual-engine corruption measured on .62 2026-08-05 as C_DONE running BACKWARDS).
# On the Scripts path nothing respawns us, so there we must restart in-process.
main_wrapper_resident() { pidof MiSTer_Maldita >/dev/null 2>&1; }

# Force a real reconfigure. load_core of the ALREADY-loaded RBF is a no-op in
# MiSTer, so the menu.rbf round-trip is not belt-and-braces — it is the only
# thing that makes the second load actually rewrite the bitstream.
reconfigure_fabric() {
    local rbf waited pid
    # Reload the core that is ACTUALLY loaded, read from the resident MiSTer's
    # argv — not `ls -t | head -1`. Newest-by-mtime is right for Scripts/
    # MalditaCastilla.sh, which is choosing a core to start; it is wrong here,
    # where the only correct answer is the bitstream already running. They differ
    # whenever a second MalditaCastilla_*.rbf is present with a newer mtime (an
    # older build copied over for comparison, or a new release extracted while
    # an older core is loaded), and getting it wrong silently swaps the user's
    # core mid-recovery. Hit on .62 2026-08-07: recovery reloaded a stale RBF
    # staged minutes earlier for an A/B test.
    for pid in $(pidof MiSTer_Maldita 2>/dev/null) $(pidof MiSTer 2>/dev/null); do
        rbf="$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -m1 '\.rbf$')"
        [ -n "$rbf" ] && [ -f "$rbf" ] && break
        rbf=""
    done
    if [ -z "$rbf" ]; then
        # shellcheck disable=SC2086
        rbf="$(ls -t $RBF_GLOB 2>/dev/null | head -1)"
        echo "fabric gate: no rbf in MiSTer argv — falling back to newest ($rbf)" >&2
    fi
    [ -n "$rbf" ] || { echo "fabric gate: no RBF matching $RBF_GLOB — cannot reconfigure" >&2; return 1; }
    [ -e "$MISTER_CMD" ] || { echo "fabric gate: $MISTER_CMD missing" >&2; return 1; }
    # With MiSTer dead the FIFO has no reader and open(O_WRONLY) blocks forever
    # — the same liveness check Scripts/MalditaCastilla.sh carries, for the same
    # reason, and covering both process names for the main= case.
    pidof MiSTer >/dev/null 2>&1 || pidof MiSTer_Maldita >/dev/null 2>&1 || {
        echo "fabric gate: no MiSTer process to service $MISTER_CMD" >&2; return 1; }

    echo "fabric gate: forcing reconfigure via menu.rbf round-trip" >&2
    echo "load_core $MENU_RBF" > "$MISTER_CMD"
    waited=0
    while [ "$(cat "$CORENAME_FILE" 2>/dev/null)" != "MENU" ] && [ "$waited" -lt 20 ]; do
        sleep 1; waited=$((waited + 1))
    done
    echo "load_core $rbf" > "$MISTER_CMD"
    return 0
}

# Returns 0 healthy, 1 wedged, 2 undetermined (engine died or never reported —
# neither of which a reconfigure fixes).
#
# PRIMARY signal is the engine's own bring-up verdict. mf_init_once performs a
# real handshake with the fabric (submit, poll for the matching ack, retry) and
# logs "fabric bring-up ok" or "fabric bring-up SOFT-FAILED"; that is purpose-
# built for this question and strictly better than anything inferable from two
# register reads out here.
#
# The register check is corroboration, and its criterion is NOT "C_SUBMIT is
# advancing while C_DONE is not" — that was wrong and this gate shipped nothing
# with it. A wedged engine stops submitting too, because it blocks waiting for
# an ack that never comes, so BOTH counters go static and the wedge reads as an
# idle engine (observed on .62 2026-08-07: sub 0x122C, done 0x122B, both frozen
# for the whole window, on a fabric that was definitively jammed).
#
# What actually separates the cases is whether work is outstanding: on a healthy
# fabric C_DONE catches C_SUBMIT within a frame, so a quiet engine sits at
# sub == done. Wedged, it sits at sub != done forever with C_DONE frozen. Hence:
# C_DONE unchanged across the window AND still short of C_SUBMIT at the end.
# (C_DONE reading one AHEAD of C_SUBMIT is normal and healthy — the two reads
# are not atomic and the fabric advances between them.)
fabric_verdict() {
    local s0 s1 d0 d1 waited line
    waited=0
    while [ "$waited" -lt "$FABRIC_SUBMIT_WAIT_S" ]; do
        line="$(grep -o 'fabric bring-up [A-Za-z-]*' "$LOGDIR/maldita.log" 2>/dev/null | tail -1)"
        [ -n "$line" ] && break
        ps w | grep -q "[g]mloader -c" || { echo "fabric gate: engine exited before reporting bring-up" >&2; return 2; }
        sleep 2; waited=$((waited + 2))
    done
    case "$line" in
        *SOFT-FAILED) echo "fabric gate: engine reports $line" >&2; return 1 ;;
        '')           echo "fabric gate: no bring-up line in ${FABRIC_SUBMIT_WAIT_S}s" >&2; return 2 ;;
    esac

    d0="$(ctrl_done)"
    sleep "$FABRIC_SAMPLE_S"
    d1="$(ctrl_done)"; s1="$(ctrl_submit)"
    echo "fabric gate: $line | done $d0 -> $d1 (sub $s1)" >&2
    [ "$d1" != "$d0" ] && return 0          # frames retiring
    [ "$d1" = "$s1" ] && return 0           # quiet engine, nothing outstanding
    return 1
}

# No busybox devmem => no gate. Never fail a launch because the instrument is
# missing; the pre-gate behaviour (start it and hope) is the fallback.
if ! devmem_ok; then
    echo "fabric gate: busybox devmem unavailable — starting unsupervised" >> "$LOGDIR/maldita.log"
    engine_exec
fi

attempt="$(cat "$FABRIC_RETRY_MARK" 2>/dev/null)"
case "$attempt" in ''|*[!0-9]*) attempt=0 ;; esac

./gmloader -c gmloader.json >> "$LOGDIR/maldita.log" 2>&1 &
engine_pid=$!
fabric_verdict >> "$LOGDIR/maldita.log" 2>&1
verdict=$?

if [ "$verdict" -eq 1 ] && [ "$attempt" -lt "$FABRIC_MAX_RETRIES" ]; then
    attempt=$((attempt + 1))
    echo "$attempt" > "$FABRIC_RETRY_MARK"
    {
        echo "fabric gate: WEDGED (fabric not retiring submitted work) —" \
             "recovery attempt $attempt/$FABRIC_MAX_RETRIES"
    } >> "$LOGDIR/maldita.log"
    kill "$engine_pid" 2>/dev/null
    n=0
    while [ "$n" -lt 3 ] && kill -0 "$engine_pid" 2>/dev/null; do sleep 1; n=$((n + 1)); done
    kill -9 "$engine_pid" 2>/dev/null
    wait "$engine_pid" 2>/dev/null

    if reconfigure_fabric >> "$LOGDIR/maldita.log" 2>&1; then
        if main_wrapper_resident; then
            # The reload re-execs MiSTer_Maldita, which forks a fresh launch.sh.
            # Exiting here is what keeps that from being a second engine.
            echo "fabric gate: main= resident — handing off to the respawned launcher" >> "$LOGDIR/maldita.log"
            exit 0
        fi
        waited=0
        while [ "$(cat "$CORENAME_FILE" 2>/dev/null)" != "Maldita Castilla" ] && [ "$waited" -lt 30 ]; do
            sleep 1; waited=$((waited + 1))
        done
        sleep 2
        echo "fabric gate: core back up after ${waited}s — restarting the engine" >> "$LOGDIR/maldita.log"
        # HANDLER_SELF, not $0: $0 may be relative and we cd'd to GAMEDIR long ago.
        exec "$HANDLER_SELF"
    fi
    echo "fabric gate: reconfigure failed — starting unsupervised" >> "$LOGDIR/maldita.log"
    engine_exec
fi

if [ "$verdict" -eq 1 ]; then
    echo "fabric gate: still wedged after $attempt attempt(s) — giving up and" \
         "leaving the engine running (frames will drop)" >> "$LOGDIR/maldita.log"
else
    rm -f "$FABRIC_RETRY_MARK"
fi

wait "$engine_pid"
exit $?

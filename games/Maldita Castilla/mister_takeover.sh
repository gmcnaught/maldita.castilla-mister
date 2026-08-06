#!/bin/bash
#
# HPS takeover harness — sourced by launch.sh.
#
# Moves the engine from "guest process on a machine Main_MiSTer owns" to "owner
# of the HPS", modelled on skmp/DreamSTer (Scripts/DreamSTer.sh), which kills
# the MiSTer main binary, runs its emulator, and ALWAYS restarts MiSTer on exit.
#
# Design: docs/superpowers/specs/2026-08-04-hps-takeover-launcher-design.md
# Plan:   docs/superpowers/plans/2026-08-04-hps-takeover-launcher.md
#
# THIS FILE IS INERT UNLESS EXPLICITLY ENABLED. With MALDITA_TAKEOVER unset (the
# default, and what deploy.py installs unless --takeover is passed) launch.sh
# takes the same `exec ./gmloader` path it always did. That is deliberate: the
# non-takeover path is the A/B baseline for every measurement, and it is the
# only path on which `/dev/MiSTer_cmd screenshot` works — this project's most
# reliable observable of the actual fabric scanout.
#
# THREE PROPERTIES THIS FILE EXISTS TO GUARANTEE:
#
#   1. LATE. We do not kill MiSTer until the engine is proven live on the
#      fabric. Everything MiSTer owes the core at load time — the readiness
#      contract (`while (!is_fpga_ready(1)) fpga_wait_to_reset()`), ascal/HDMI
#      config, scaler and gamma tables — is therefore already done by the
#      process that actually owes it. This is the whole reason a takeover is
#      safer than the `main=` wrapper, which took main()'s obligations and then
#      did not honour them (device-measured: wrapper 3/5 frame-1 wedges vs
#      stock main 0/5).
#
#   2. FAIL-SAFE. If the engine never proves itself live, we DO NOT take over.
#      The session degrades to exactly today's behaviour with MiSTer intact. A
#      bad engine build must not be able to cost a user their box.
#
#   3. ALWAYS RESTORE. Every exit path — clean exit, crash, Master_Daemon's
#      kill_child on a core change, a hand `kill` — runs the restore. The one
#      path that cannot is `kill -9` of this shell, which no trap survives; see
#      the plan's Task 3.2.
#
# NOT YET TRUE, and why this ships default-off (design §3): input reaches the
# game through the FABRIC, not through Linux — Main_MiSTer holds an exclusive
# evdev grab and feeds hps_io's joystick_0/1 wires, which openbor_video_reader
# writes to 0x3BF40008/0x3BF40018 for the engine to mmap. Kill MiSTer and those
# wires hold their last value forever, and the engine keeps reading a
# well-formed but FROZEN mask, because JoyDdr_Init() is just an mmap and goes on
# succeeding. Until gmloader-next lands a forced transport (GMLOADER_JOY=sdl,
# plan Phase 2), a real takeover has no working gamepad. Keep an SSH session
# open.

# ── Configuration ────────────────────────────────────────────────────────────
# All knobs come from the environment, and takeover.env (installed next to
# launch.sh by `deploy.py --takeover`) is the intended place to set them.
#
#   MALDITA_TAKEOVER=1            arm the takeover (default: off)
#   MALDITA_TAKEOVER_DRYRUN=1     run every step and log it, but kill nothing
#                                 and change no cpufreq setting
#   MALDITA_TAKEOVER_GOVERNOR=1   performance governor + 1 GHz, restored on exit
#   MALDITA_TAKEOVER_LIVENESS_S   how long to wait for the engine to prove
#                                 itself before giving up on the takeover (30)
#   MALDITA_TAKEOVER_REENTRY_S    suppress takeover for this long after a
#                                 restore, so a MiSTer that comes back up and
#                                 reloads this core cannot loop (60)
#   MALDITA_TAKEOVER_MENU_WAIT_S  how long the restore waits for the restarted
#                                 MiSTer before giving up on the menu (20)
#   MISTER_BIN                    the MiSTer main binary (/media/fat/MiSTer)
#   MISTER_CMD_FIFO               MiSTer's command FIFO (/dev/MiSTer_cmd)
#   MISTER_PROC_NAMES             process names that count as "MiSTer"
#                                 ("MiSTer MiSTer_Maldita")

: "${MALDITA_TAKEOVER:=0}"
: "${MALDITA_TAKEOVER_DRYRUN:=0}"
: "${MALDITA_TAKEOVER_GOVERNOR:=0}"
: "${MALDITA_TAKEOVER_LIVENESS_S:=30}"
: "${MALDITA_TAKEOVER_REENTRY_S:=60}"
: "${MALDITA_TAKEOVER_MENU_WAIT_S:=20}"
: "${MISTER_BIN:=/media/fat/MiSTer}"
: "${MISTER_CMD_FIFO:=/dev/MiSTer_cmd}"

# Under the `main=` entry point the resident process is NOT called "MiSTer" —
# MiSTer exec'd our wrapper build (MiSTer_Maldita), which is upstream main()
# plus one hook. Without this list `pidof MiSTer` finds nothing and the takeover
# refuses to arm with "could not identify a running MiSTer process", silently
# giving a session with no takeover at all. Both names, always: which one is
# resident depends on how the user entered the core, not on any setting we can
# read from here.
: "${MISTER_PROC_NAMES:=MiSTer MiSTer_Maldita}"

# C_DONE, low word. The blitter control block is qword-addressed from
# 0x3B000000 (C_SUBMIT=0 CMDCOUNT=1 TARGET=2 CLEAR=3 FLAGS=4 DONE=5 ...), so
# DONE lands at +0x28. This is the same ground truth the phase-2 perf work used:
# it advances only when the host submits AND the fabric retires, which is
# strictly stronger evidence than C_SUBMIT climbing (the frame-1 wedge signature
# is precisely "C_SUBMIT climbs, C_DONE stays 0 forever").
TAKEOVER_C_DONE_ADDR="0x3B000028"

CPUFREQ_DIR="/sys/devices/system/cpu/cpu0/cpufreq"
TAKEOVER_STAMP="/tmp/maldita_takeover_restore.stamp"

# ── State (set during arming, consumed by the restore) ───────────────────────
TAKEOVER_ARMED=0          # 1 once we have actually killed MiSTer
TAKEOVER_MISTER_PIDS=""
TAKEOVER_MISTER_EXE=""
TAKEOVER_PREV_GOV=""
TAKEOVER_PREV_MAXFREQ=""
TAKEOVER_ENGINE_PID=""
TAKEOVER_RESTORED=0

tk_log() { echo "takeover: $*"; }

# ── Probing ──────────────────────────────────────────────────────────────────

# Read C_DONE's low word. Empty on any failure — `dd` on /dev/mem is blocked by
# CONFIG_STRICT_DEVMEM, so devmem (which mmaps) is the only reader available.
tk_c_done() {
    busybox devmem "$TAKEOVER_C_DONE_ADDR" 32 2>/dev/null
}

tk_proc_alive() { [ -d "/proc/$1" ]; }

# Every pid matching any name in MISTER_PROC_NAMES. Empty output + status 1 when
# nothing is running.
tk_mister_pids() {
    local name pids out=""
    for name in $MISTER_PROC_NAMES; do
        pids="$(pidof "$name" 2>/dev/null)"
        [ -n "$pids" ] && out="$out $pids"
    done
    [ -n "$out" ] || return 1
    echo "$out"
}

# Find MiSTer, and verify it before trusting it. `pidof` matches on name alone;
# /proc/<pid>/exe is what tells us we are about to kill the real binary and
# gives us the path to restart it from. DreamSTer reads the same link off its
# own parent — we cannot, because our parent is Master_Daemon, not MiSTer.
tk_find_mister() {
    local pids pid exe base name
    pids="$(tk_mister_pids)" || return 1

    for pid in $pids; do
        exe="$(readlink "/proc/$pid/exe" 2>/dev/null)"
        exe="${exe% (deleted)}"
        [ -n "$exe" ] || continue
        base="$(basename "$exe")"
        for name in $MISTER_PROC_NAMES; do
            if [ "$base" = "$name" ]; then
                # Restart the exe we actually killed, not a hardcoded path: under
                # `main=` that is the wrapper, and restarting it is correct —
                # it comes up, sees the restore stamp, does NOT spawn the engine,
                # and behaves as stock MiSTer until the menu.rbf request below
                # hands off to /media/fat/MiSTer through the same main= machinery.
                TAKEOVER_MISTER_EXE="$exe"
                break 2
            fi
        done
    done
    [ -n "$TAKEOVER_MISTER_EXE" ] || return 1

    TAKEOVER_MISTER_PIDS="$pids"
    return 0
}

# ── Arming decision ──────────────────────────────────────────────────────────
#
# Refuse for any reason at all rather than half-take-over. Every `return 1` here
# lands the session on today's behaviour, which is a fine place to land.
tk_should_take_over() {
    [ "$MALDITA_TAKEOVER" = "1" ] || return 1

    # Re-entry guard. Restoring MiSTer makes MiSTer load a core; if it loads
    # THIS core, the handler fires again (via Master_Daemon, or via the `main=`
    # hook) and we would take over again — a loop that is very hard to break
    # from the couch. One degraded (but playable, and exitable) session is the
    # right answer.
    #
    # CONTRACT: vendor/Main_MiSTer/maldita_hook.cpp reads the SAME stamp with
    # the same 60 s window, and there it suppresses the engine spawn entirely
    # rather than just the takeover — which is what a restore actually needs,
    # since an engine started during one would put the user straight back in the
    # game they were leaving. Change the window here and change it there.
    if [ -f "$TAKEOVER_STAMP" ]; then
        local then_s now_s
        then_s="$(cat "$TAKEOVER_STAMP" 2>/dev/null)"
        now_s="$(date +%s 2>/dev/null)"
        case "$then_s$now_s" in
            *[!0-9]*|"") ;;   # unparseable: fall through and allow
            *)
                if [ "$((now_s - then_s))" -lt "$MALDITA_TAKEOVER_REENTRY_S" ]; then
                    tk_log "SKIP — a restore happened $((now_s - then_s))s ago" \
                           "(< ${MALDITA_TAKEOVER_REENTRY_S}s re-entry guard)"
                    return 1
                fi
                ;;
        esac
    fi

    # Never take over unless we can put things back. This is the restore
    # contract's precondition, checked before anything is touched.
    if [ ! -x "$MISTER_BIN" ]; then
        tk_log "SKIP — $MISTER_BIN is not executable; nothing to restart"
        return 1
    fi
    if ! tk_find_mister; then
        tk_log "SKIP — could not identify a running MiSTer process"
        return 1
    fi
    if ! command -v busybox >/dev/null 2>&1 || [ -z "$(tk_c_done)" ]; then
        tk_log "SKIP — cannot read C_DONE via devmem; no liveness gate available"
        return 1
    fi
    return 0
}

# ── Liveness gate ────────────────────────────────────────────────────────────
#
# Two observed advances of C_DONE. One is not enough: a single non-zero read
# could be a leftover from a previous session's control block, since nothing
# zeroes DDR between core loads.
tk_await_engine_live() {
    local deadline prev cur hits
    deadline="$(( $(date +%s) + MALDITA_TAKEOVER_LIVENESS_S ))"
    prev="$(tk_c_done)"
    hits=0

    while [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 1
        if ! tk_proc_alive "$TAKEOVER_ENGINE_PID"; then
            tk_log "liveness: engine pid $TAKEOVER_ENGINE_PID died before proving itself"
            return 1
        fi
        cur="$(tk_c_done)"
        if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then
            hits=$((hits + 1))
            tk_log "liveness: C_DONE $prev -> $cur ($hits/2)"
            [ "$hits" -ge 2 ] && return 0
        fi
        prev="$cur"
    done

    tk_log "liveness: TIMEOUT after ${MALDITA_TAKEOVER_LIVENESS_S}s (C_DONE=$prev)"
    return 1
}

# ── cpufreq ──────────────────────────────────────────────────────────────────

tk_cpufreq_read()  { cat "$CPUFREQ_DIR/$1" 2>/dev/null; }
tk_cpufreq_write() {
    echo "$2" > "$CPUFREQ_DIR/$1" 2>/dev/null \
        || tk_log "cpufreq: $1 <- $2 failed (ignored)"
}

tk_cpufreq_boost() {
    [ "$MALDITA_TAKEOVER_GOVERNOR" = "1" ] || return 0
    TAKEOVER_PREV_GOV="$(tk_cpufreq_read scaling_governor)"
    TAKEOVER_PREV_MAXFREQ="$(tk_cpufreq_read scaling_max_freq)"
    tk_log "cpufreq: governor=$TAKEOVER_PREV_GOV max=$TAKEOVER_PREV_MAXFREQ -> performance/1000000"
    if [ "$MALDITA_TAKEOVER_DRYRUN" = "1" ]; then
        tk_log "cpufreq: DRYRUN — not written"
        return 0
    fi
    tk_cpufreq_write scaling_governor performance
    tk_cpufreq_write scaling_max_freq 1000000
}

tk_cpufreq_restore() {
    [ -n "$TAKEOVER_PREV_MAXFREQ" ] && tk_cpufreq_write scaling_max_freq "$TAKEOVER_PREV_MAXFREQ"
    [ -n "$TAKEOVER_PREV_GOV" ]     && tk_cpufreq_write scaling_governor "$TAKEOVER_PREV_GOV"
    TAKEOVER_PREV_MAXFREQ=""
    TAKEOVER_PREV_GOV=""
    return 0
}

# ── The takeover itself ──────────────────────────────────────────────────────

tk_kill_mister() {
    local pid i
    tk_log "killing MiSTer pids [$TAKEOVER_MISTER_PIDS] exe=$TAKEOVER_MISTER_EXE"
    if [ "$MALDITA_TAKEOVER_DRYRUN" = "1" ]; then
        tk_log "DRYRUN — MiSTer left alive"
        TAKEOVER_ARMED=1
        return 0
    fi

    # Arm BEFORE signalling. If we die between the kill and setting this, the
    # restore must still run — a false-positive restore is harmless, a missed
    # one is a dead box.
    TAKEOVER_ARMED=1

    for pid in $TAKEOVER_MISTER_PIDS; do kill -TERM "$pid" 2>/dev/null; done

    # Whole seconds, not DreamSTer's 0.1 s polls: busybox `sleep` only accepts
    # fractions when built with FANCY_SLEEP, and this runs on whatever busybox
    # the user's MiSTer image shipped.
    local alive
    for i in 1 2 3; do
        sleep 1
        alive=0
        for pid in $TAKEOVER_MISTER_PIDS; do
            tk_proc_alive "$pid" && alive=1
        done
        if [ "$alive" = "0" ]; then
            tk_log "MiSTer exited on SIGTERM"
            return 0
        fi
    done
    tk_log "MiSTer still up after 3s — SIGKILL"
    for pid in $TAKEOVER_MISTER_PIDS; do kill -KILL "$pid" 2>/dev/null; done
    return 0
}

# Idempotent, failure-tolerant, and ordered so that the step which actually
# gives the user their box back — the MiSTer re-exec — is last and
# unconditional. Nothing above it may `exit` or `return` early.
tk_restore() {
    [ "$TAKEOVER_RESTORED" = "1" ] && return 0
    TAKEOVER_RESTORED=1

    tk_cpufreq_restore

    if [ "$TAKEOVER_ARMED" != "1" ]; then
        tk_log "restore: takeover was never armed; nothing to undo"
        return 0
    fi

    date +%s > "$TAKEOVER_STAMP" 2>/dev/null   # feeds the re-entry guard

    if [ "$MALDITA_TAKEOVER_DRYRUN" = "1" ]; then
        tk_log "restore: DRYRUN — MiSTer was never killed, not restarting it"
        return 0
    fi

    tk_log "restore: restarting MiSTer ($TAKEOVER_MISTER_EXE)"
    local dir
    dir="$(dirname "$TAKEOVER_MISTER_EXE")"
    if command -v setsid >/dev/null 2>&1; then
        ( cd "$dir" && setsid "$TAKEOVER_MISTER_EXE" </dev/null >/dev/null 2>&1 & )
    else
        ( cd "$dir" && nohup "$TAKEOVER_MISTER_EXE" </dev/null >/dev/null 2>&1 & )
    fi

    tk_restore_menu
    return 0
}

# Get the user back to the menu, not just back to a MiSTer.
#
# A fresh MiSTer does NOT load menu.rbf. main() takes whatever core is already
# in the FPGA — there is no core argument and no startup load (main.cpp:62-73)
# — and it `exit(0)`s outright with "GPI[31]==1 ... Quitting. Bye bye..." if
# is_fpga_ready(1) is false. So the process we just restarted comes up on OUR
# core, showing OUR OSD, with no engine behind it.
#
# DreamSTer solves this with its own load_fpga_bitstream binary, which it needs
# anyway because polly2 is not a framework core. We do not need one: ask the
# restarted MiSTer to load the menu the way everything else does, and it
# app_restart()s into it (fpga_io.cpp:506).
tk_restore_menu() {
    local waited=0
    while [ "$waited" -lt "$MALDITA_TAKEOVER_MENU_WAIT_S" ]; do
        sleep 1
        waited=$((waited + 1))
        tk_mister_pids >/dev/null 2>&1 || continue
        [ -p "$MISTER_CMD_FIFO" ] || continue

        # MiSTer unlinks and re-mkfifos the node, then opens it O_RDWR, during
        # input init (input.cpp:5140-5143). Between `pidof` succeeding and that
        # open there is a window in which the FIFO has no reader — and
        # open(O_WRONLY) on a readerless FIFO blocks FOREVER. This runs inside
        # an exit trap, so a block here is a hung box. Settle, then bound the
        # write if `timeout` exists.
        sleep 2
        tk_log "restore: MiSTer back after ${waited}s; requesting menu.rbf"
        if command -v timeout >/dev/null 2>&1; then
            timeout 5 sh -c "echo 'load_core menu.rbf' > '$MISTER_CMD_FIFO'" \
                || tk_log "restore: menu.rbf request timed out (core left loaded)"
        else
            echo "load_core menu.rbf" > "$MISTER_CMD_FIFO"
        fi
        return 0
    done

    tk_log "restore: MiSTer did not come back within ${MALDITA_TAKEOVER_MENU_WAIT_S}s" \
           "— core left loaded"
    return 1
}

# Signal path: stop the engine first, then restore. Master_Daemon's kill_child
# on a core change lands here, and so does a hand `kill` of the handler.
tk_on_signal() {
    tk_log "signal received — stopping engine and restoring"
    [ -n "$TAKEOVER_ENGINE_PID" ] && kill -TERM "$TAKEOVER_ENGINE_PID" 2>/dev/null
    tk_restore
    exit 143
}

# ── Entry point ──────────────────────────────────────────────────────────────
#
# Runs "$@" as the engine. Returns its exit status. Restores on every path a
# trap can reach.
takeover_run() {
    trap tk_restore EXIT
    trap tk_on_signal INT TERM HUP

    tk_log "arming: pids=[$TAKEOVER_MISTER_PIDS] exe=$TAKEOVER_MISTER_EXE" \
           "dryrun=$MALDITA_TAKEOVER_DRYRUN governor=$MALDITA_TAKEOVER_GOVERNOR"

    # MiSTer pins Scripts-menu entries to core 1 with taskset, and DreamSTer
    # widens its own mask back to {0,1} on that account. Whether Master_Daemon
    # narrows ours the same way is plan Task 0.2's question — widening is a
    # no-op if it does not, so do it unconditionally rather than find out the
    # hard way that the engine has been on one core all along.
    if command -v taskset >/dev/null 2>&1; then
        taskset -p 3 $$ >/dev/null 2>&1 \
            && tk_log "affinity: widened this process group to cpu{0,1}"
    fi

    # No-op until gmloader-next lands the forced transport (plan Phase 2). Set
    # here and not in launch.sh so it is impossible for the takeover to run
    # without it once the engine understands it.
    export GMLOADER_JOY=sdl

    "$@" &
    TAKEOVER_ENGINE_PID=$!
    tk_log "engine pid $TAKEOVER_ENGINE_PID; waiting for it to prove itself live"

    if tk_await_engine_live; then
        tk_cpufreq_boost
        tk_kill_mister
        tk_log "takeover complete — the HPS is ours"
    else
        # The fail-safe path. MiSTer is untouched, the OSD still works, and the
        # user can leave the core normally.
        tk_log "NOT taking over — engine never proved live; MiSTer left running"
    fi

    wait "$TAKEOVER_ENGINE_PID"
    local rc=$?
    tk_log "engine exited rc=$rc"
    tk_restore
    return "$rc"
}

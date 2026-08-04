#!/bin/bash
#
# Host-native tests for games/Maldita Castilla/mister_takeover.sh.
#
# Run:  tools/mister-takeover/test_takeover.sh
#
# There is no MiSTer here, so the boundary commands are stubbed — but only the
# ones that must be: `pidof`, `readlink` (for /proc/<pid>/exe), `busybox devmem`,
# `taskset`, and the MiSTer re-exec. Process liveness is NOT stubbed: the fake
# MiSTer and fake engine are real background processes, so `kill -TERM`, the
# 3-second SIGTERM wait and tk_proc_alive()'s /proc probe all exercise the real
# code against real pids. That is the part most likely to be wrong.
#
# What this cannot test: whether killing the real Main_MiSTer disturbs video,
# whether re-exec'ing it restores the menu, and whether input survives. Those
# are device questions — see the plan's Phase 0 and Task 3.2.

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SELF_DIR/../.." && pwd)"
LIB="$REPO/games/Maldita Castilla/mister_takeover.sh"

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); echo "  ok   — $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL — $1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

TMP="$(mktemp -d)"
# Guarded on BASHPID: bash runs an inherited EXIT trap when a SUBSHELL exits
# too, and this script uses both command substitution and `takeover_run … &`.
# Without the guard the first subshell to finish deletes $TMP out from under
# the rest of the run.
cleanup() {
    [ "$BASHPID" = "$$" ] || return 0
    pkill -P $$ sleep 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

# ── Stubs ────────────────────────────────────────────────────────────────────
# Shell functions shadow PATH lookups, including `command -v`.

FAKE_MISTER_PIDS=""
FAKE_C_DONE_MODE="static"
FAKE_C_DONE_N=0

pidof()   { [ "$1" = "MiSTer" ] && echo "$FAKE_MISTER_PIDS"; }
readlink() { echo "$TMP/MiSTer"; }          # /proc/<pid>/exe for any pid
taskset() { return 0; }                     # never repin the test runner
setsid()  { echo "restarted:$*" >> "$TMP/restart.log"; }
nohup()   { echo "restarted:$*" >> "$TMP/restart.log"; }

# The counter is file-backed, not a variable: tk_c_done() is always called from
# a command substitution, which is a subshell, so a variable increment here
# would be discarded and every read would return the same value — the library
# would then look like it had failed its liveness gate when it had not.
busybox() {
    [ "$1" = "devmem" ] || return 1
    case "$FAKE_C_DONE_MODE" in
        static)   echo "0x00000042" ;;      # never advances -> liveness times out
        advance)
            FAKE_C_DONE_N="$(( $(cat "$TMP/cdone" 2>/dev/null || echo 0) + 1 ))"
            echo "$FAKE_C_DONE_N" > "$TMP/cdone"
            echo "0x$FAKE_C_DONE_N"
            ;;
        dead)     return 1 ;;               # devmem unavailable
    esac
}

# A fake MiSTer: a real process that really has to be signalled to death.
spawn_fake_mister() {
    sleep 300 &
    FAKE_MISTER_PIDS="$!"
}

# Fresh state for each case. Sourcing again resets the library's globals.
reset_case() {
    rm -f "$TMP/restart.log" "$TMP/stamp" "$TMP/cdone"
    : > "$TMP/restart.log"
    touch "$TMP/MiSTer" && chmod +x "$TMP/MiSTer"

    MALDITA_TAKEOVER=1
    MALDITA_TAKEOVER_DRYRUN=0
    MALDITA_TAKEOVER_GOVERNOR=0
    MALDITA_TAKEOVER_LIVENESS_S=3
    MALDITA_TAKEOVER_REENTRY_S=60
    MISTER_BIN="$TMP/MiSTer"
    export MALDITA_TAKEOVER MALDITA_TAKEOVER_DRYRUN MALDITA_TAKEOVER_GOVERNOR
    export MALDITA_TAKEOVER_LIVENESS_S MALDITA_TAKEOVER_REENTRY_S MISTER_BIN

    # shellcheck disable=SC1090
    . "$LIB"
    TAKEOVER_STAMP="$TMP/stamp"
    CPUFREQ_DIR="$TMP/cpufreq-absent"       # writes fail and are ignored, by design
}

mister_alive() { [ -n "$FAKE_MISTER_PIDS" ] && [ -d "/proc/$FAKE_MISTER_PIDS" ]; }

echo "== arming decision =="

reset_case; spawn_fake_mister
MALDITA_TAKEOVER=0
tk_should_take_over >/dev/null 2>&1 && r=armed || r=refused
check "refuses when MALDITA_TAKEOVER is not 1" "$r" "refused"
kill "$FAKE_MISTER_PIDS" 2>/dev/null

reset_case; spawn_fake_mister
rm -f "$TMP/MiSTer"                          # nothing to restart with
tk_should_take_over >/dev/null 2>&1 && r=armed || r=refused
check "refuses when the MiSTer binary is not executable" "$r" "refused"
kill "$FAKE_MISTER_PIDS" 2>/dev/null

reset_case
FAKE_MISTER_PIDS=""                          # no MiSTer running
tk_should_take_over >/dev/null 2>&1 && r=armed || r=refused
check "refuses when no MiSTer process can be identified" "$r" "refused"

reset_case; spawn_fake_mister
FAKE_C_DONE_MODE="dead"
tk_should_take_over >/dev/null 2>&1 && r=armed || r=refused
check "refuses when C_DONE is unreadable (no liveness gate)" "$r" "refused"
FAKE_C_DONE_MODE="static"
kill "$FAKE_MISTER_PIDS" 2>/dev/null

reset_case; spawn_fake_mister
date +%s > "$TMP/stamp"                      # a restore just happened
tk_should_take_over >/dev/null 2>&1 && r=armed || r=refused
check "refuses inside the re-entry guard window" "$r" "refused"
kill "$FAKE_MISTER_PIDS" 2>/dev/null

reset_case; spawn_fake_mister
echo "$(( $(date +%s) - 3600 ))" > "$TMP/stamp"
tk_should_take_over >/dev/null 2>&1 && r=armed || r=refused
check "arms when the re-entry stamp is old" "$r" "armed"
check "  and records the MiSTer exe path" "$TAKEOVER_MISTER_EXE" "$TMP/MiSTer"
kill "$FAKE_MISTER_PIDS" 2>/dev/null

echo "== liveness gate =="

reset_case; spawn_fake_mister
FAKE_C_DONE_MODE="static"
tk_should_take_over >/dev/null 2>&1
takeover_run sleep 30 >/dev/null 2>&1 &
RUN_PID=$!
sleep 6                                      # liveness window (3 s) plus slack
mister_alive && r=alive || r=dead
check "a C_DONE that never advances leaves MiSTer ALIVE" "$r" "alive"
kill "$RUN_PID" 2>/dev/null; wait "$RUN_PID" 2>/dev/null
pkill -P $$ sleep 2>/dev/null

echo "== takeover and restore =="

reset_case; spawn_fake_mister
FAKE_C_DONE_MODE="advance"
tk_should_take_over >/dev/null 2>&1
MISTER_PID_UNDER_TEST="$FAKE_MISTER_PIDS"
takeover_run sleep 8 > "$TMP/run.log" 2>&1
r=running; [ -d "/proc/$MISTER_PID_UNDER_TEST" ] || r=killed
check "an advancing C_DONE gets MiSTer killed" "$r" "killed"
grep -q "takeover complete" "$TMP/run.log" && r=yes || r=no
check "  and logs the takeover" "$r" "yes"
grep -q "^restarted:" "$TMP/restart.log" && r=yes || r=no
check "engine exit restarts MiSTer" "$r" "yes"
[ -f "$TMP/stamp" ] && r=yes || r=no
check "  and stamps the re-entry guard" "$r" "yes"
n="$(grep -c "^restarted:" "$TMP/restart.log")"
tk_restore >/dev/null 2>&1                   # second call must do nothing
check "restore is idempotent" "$(grep -c '^restarted:' "$TMP/restart.log")" "$n"

echo "== dry run =="

reset_case; spawn_fake_mister
FAKE_C_DONE_MODE="advance"
MALDITA_TAKEOVER_DRYRUN=1
tk_should_take_over >/dev/null 2>&1
MISTER_PID_UNDER_TEST="$FAKE_MISTER_PIDS"
takeover_run sleep 5 > "$TMP/dry.log" 2>&1
grep -q "takeover complete" "$TMP/dry.log" && r=yes || r=no
check "dry run still passes the liveness gate" "$r" "yes"   # guards against a vacuous pass
r=killed; [ -d "/proc/$MISTER_PID_UNDER_TEST" ] && r=alive
check "dry run leaves MiSTer alive" "$r" "alive"
grep -q "^restarted:" "$TMP/restart.log" && r=yes || r=no
check "dry run does not restart MiSTer either" "$r" "no"
kill "$MISTER_PID_UNDER_TEST" 2>/dev/null

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

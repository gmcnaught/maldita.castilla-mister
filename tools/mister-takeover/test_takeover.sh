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

# The EXIT trap deliberately does NOT delete $TMP.
#
# This script spawns background jobs and the library under test sets its own
# EXIT trap, and an inherited EXIT trap fires when a SUBSHELL exits as well as
# when the script does. A `rm -rf "$TMP"` in here was observed deleting the
# fixture mid-run — `bash -x` caught it as `++ rm -rf /tmp/tmp.XXXX` in the
# middle of a case, after which every later assertion failed against a
# directory that no longer existed. Reaping strays is idempotent and safe to
# run from anywhere; deleting the fixture is not, so that happens exactly once,
# on the last line of the script.
cleanup() {
    pkill -P $$ sleep 2>/dev/null
    pkill -P $$ cat 2>/dev/null
}
trap cleanup EXIT

# ── Stubs ────────────────────────────────────────────────────────────────────
# Shell functions shadow PATH lookups, including `command -v`.

FAKE_MISTER_PIDS=""
FAKE_C_DONE_MODE="static"
FAKE_C_DONE_N=0

# pidof reports only pids that are genuinely alive, so a killed fake MiSTer
# really does disappear from it — the restore's "has MiSTer come back?" loop is
# then a real test rather than a stubbed constant.
FAKE_MISTER_NAME="MiSTer"

pidof() {
    [ "$1" = "$FAKE_MISTER_NAME" ] || return 1
    local p out=""
    for p in $(cat "$TMP/mister.pids" 2>/dev/null); do
        [ -d "/proc/$p" ] && out="$out $p"
    done
    [ -n "$out" ] || return 1
    echo "$out"
}
readlink() { echo "$TMP/MiSTer"; }          # /proc/<pid>/exe for any pid
taskset() { return 0; }                     # never repin the test runner

# The restart stub also brings a NEW fake MiSTer up, which is what the real
# re-exec does — without it the restore's menu.rbf step could never be reached.
fake_restart() {
    echo "restarted:$*" >> "$TMP/restart.log"
    sleep 300 &
    echo "$!" >> "$TMP/mister.pids"
}
setsid()  { fake_restart "$@"; }
nohup()   { fake_restart "$@"; }

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
    echo "$FAKE_MISTER_PIDS" >> "$TMP/mister.pids"
}

# Fresh state for each case. Sourcing again resets the library's globals.
reset_case() {
    rm -f "$TMP/restart.log" "$TMP/stamp" "$TMP/cdone" "$TMP/mister.pids" \
          "$TMP/cmd" "$TMP/cmd.out"
    : > "$TMP/restart.log"
    touch "$TMP/MiSTer" && chmod +x "$TMP/MiSTer"

    # A real FIFO with a real reader: the restore's menu.rbf request goes
    # through an actual open(O_WRONLY), which is the call that would hang the
    # box if the guard around it were wrong. The previous reader is reaped
    # first — it is blocked in open() on an inode nothing will ever write to,
    # and would otherwise pile up one per case.
    [ -n "${FIFO_READER_PID:-}" ] && kill "$FIFO_READER_PID" 2>/dev/null
    mkfifo "$TMP/cmd"
    cat "$TMP/cmd" > "$TMP/cmd.out" &
    FIFO_READER_PID=$!

    # takeover_run installs its own EXIT/INT/TERM traps in whatever shell calls
    # it, so a foreground call replaces ours. Re-arm each case.
    trap cleanup EXIT

    MALDITA_TAKEOVER=1
    MALDITA_TAKEOVER_DRYRUN=0
    MALDITA_TAKEOVER_GOVERNOR=0
    MALDITA_TAKEOVER_LIVENESS_S=3
    MALDITA_TAKEOVER_REENTRY_S=60
    MALDITA_TAKEOVER_MENU_WAIT_S=6
    MISTER_BIN="$TMP/MiSTer"
    MISTER_CMD_FIFO="$TMP/cmd"
    FAKE_MISTER_NAME="MiSTer"
    export MALDITA_TAKEOVER MALDITA_TAKEOVER_DRYRUN MALDITA_TAKEOVER_GOVERNOR
    export MALDITA_TAKEOVER_LIVENESS_S MALDITA_TAKEOVER_REENTRY_S MISTER_BIN
    export MALDITA_TAKEOVER_MENU_WAIT_S MISTER_CMD_FIFO

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

# Under the `main=` entry point the resident process is MiSTer_Maldita, not
# MiSTer. Before MISTER_PROC_NAMES existed this refused to arm and the session
# silently ran with no takeover at all.
reset_case
FAKE_MISTER_NAME="MiSTer_Maldita"
spawn_fake_mister
echo "$(( $(date +%s) - 3600 ))" > "$TMP/stamp"
tk_should_take_over >/dev/null 2>&1 && r=armed || r=refused
check "arms against the main= wrapper process name" "$r" "armed"
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
sleep 1
grep -q "load_core menu.rbf" "$TMP/cmd.out" && r=yes || r=no
check "  and asks the restarted MiSTer for menu.rbf" "$r" "yes"
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
grep -q "load_core" "$TMP/cmd.out" 2>/dev/null && r=yes || r=no
check "dry run sends no command to the FIFO" "$r" "no"
kill "$MISTER_PID_UNDER_TEST" 2>/dev/null

echo
echo "$PASS passed, $FAIL failed"
cleanup
rm -rf "$TMP"          # the one and only fixture delete — see the trap comment
[ "$FAIL" -eq 0 ]

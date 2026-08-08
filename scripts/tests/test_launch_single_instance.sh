#!/usr/bin/env bash
# Host test for launch.sh's launch mutex.
#
# THE BUG IT GUARDS, measured on .81 2026-08-08 with the v0.3.2 bundle: with
# `main=` armed -- which deploy.py and the CoresMenu entry both do by default --
# starting from Scripts -> MalditaCastilla ran BOTH entry points off one core
# load. The Scripts entry writes load_core and execs launch.sh; MiSTer execs
# MiSTer_Maldita for that same load, which forks launch.sh too. Result:
# engines=2, two gmloader processes on one fabric control block, the dual-engine
# corruption previously seen as C_DONE running BACKWARDS.
#
# The old `ps | grep` reap could not prevent it -- check-then-act means both
# racers look, both see nothing, both proceed. Only an atomic claim works.
#
# Case 1 is the regression proper. Cases 2 and 3 exist because a lock that is
# never released is a worse bug than the one being fixed: it would wedge every
# future launch.
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LAUNCH="$REPO/games/Maldita Castilla/launch.sh"
[ -f "$LAUNCH" ] || { echo "FAIL: launch.sh not found at $LAUNCH"; exit 1; }

FAILED=0
fail() { echo "FAIL: $*"; FAILED=1; }

setup() {
    SB="$(mktemp -d)"
    mkdir -p "$SB/bin" "$SB/game" "$SB/log" "$SB/rbf"
    : > "$SB/cmd"; echo "Maldita Castilla" > "$SB/corename"
    : > "$SB/rbf/MalditaCastilla_20260808.rbf"
    : > "$SB/runs"

    # Engine stub: appends a line per start, so concurrent starts are countable.
    cat > "$SB/game/gmloader" <<EOF
#!/usr/bin/env bash
echo "start \$\$" >> "$SB/runs"
/bin/sleep 1
EOF
    chmod +x "$SB/game/gmloader"

    # Healthy fabric: bring-up ok, C_DONE advancing, FPGA ready.
    cat > "$SB/bin/busybox" <<EOF
#!/usr/bin/env bash
[ "\$1" = devmem ] || exit 0
case "\$2" in
  0xFF706014) echo "0x00040000" ;;
  0x3B000028) cur=\$(cat "$SB/done" 2>/dev/null || echo 16)
              echo \$((cur+1)) > "$SB/done"; printf "0x%08X\n" "\$cur" ;;
  *) echo "0x00000010" ;;
esac
EOF
    chmod +x "$SB/bin/busybox"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/bin/ps";      chmod +x "$SB/bin/ps"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/bin/killall"; chmod +x "$SB/bin/killall"
    printf '#!/usr/bin/env bash\nexec /bin/sleep 0.05\n' > "$SB/bin/sleep"; chmod +x "$SB/bin/sleep"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$SB/bin/pidof";   chmod +x "$SB/bin/pidof"
}

run_launch() {
    PATH="$SB/bin:$PATH" \
    MALDITA_GAMEDIR="$SB/game" MALDITA_LOGDIR="$SB/log" \
    MALDITA_MISTER_CMD="$SB/cmd" MALDITA_CORENAME_FILE="$SB/corename" \
    MALDITA_RBF_GLOB="$SB/rbf/MalditaCastilla_*.rbf" \
    MALDITA_RETRY_MARK="$SB/retry" MALDITA_LOCKDIR="$SB/lock" \
    MALDITA_FABRIC_SAMPLE_S=0 MALDITA_FABRIC_SUBMIT_WAIT_S=4 \
    timeout 60 bash "$LAUNCH" >/dev/null 2>&1
}

# --- case 1: two launchers, one core load -> exactly ONE engine --------------
setup
run_launch & p1=$!
run_launch & p2=$!
wait $p1 $p2 2>/dev/null
n=$(grep -c "^start" "$SB/runs" 2>/dev/null || echo 0)
[ "$n" -eq 1 ] || fail "case 1: $n engines started from a simultaneous double launch, expected 1"
rm -rf "$SB"

# --- case 2: a later, sequential relaunch must NOT be blocked ----------------
# The lock serialises the race, not the engine's lifetime. If it leaked, every
# relaunch after the first would stand down and the game could never restart.
setup
run_launch
run_launch
n=$(grep -c "^start" "$SB/runs" 2>/dev/null || echo 0)
[ "$n" -eq 2 ] || fail "case 2: sequential relaunch blocked ($n starts, expected 2) — leaked lock"
rm -rf "$SB"

# --- case 3: stale lock from a launcher that died -> taken over --------------
setup
mkdir -p "$SB/lock"; echo 999999 > "$SB/lock/pid"   # pid that cannot be alive
run_launch
n=$(grep -c "^start" "$SB/runs" 2>/dev/null || echo 0)
[ "$n" -eq 1 ] || fail "case 3: stale lock deadlocked the launcher ($n starts, expected 1)"
rm -rf "$SB"

if [ "$FAILED" -eq 0 ]; then
    echo "PASS: concurrent double-launch yields one engine, sequential relaunch works, stale lock recovered"
fi
exit "$FAILED"

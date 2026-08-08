#!/usr/bin/env bash
# Host test for launch.sh's fabric recovery gate.
#
# Runs the real launch.sh against a sandbox tree with stubbed busybox/ps/
# killall/pidof/sleep, so the decision logic is exercised without a DE10-Nano.
# What it does NOT cover is whether a reconfigure actually clears the wedge —
# that is a fabric property and only the device can answer it. Measured on .62
# 2026-08-07 across 10 reboot trials: the gate fired on 4, and recovered 3. The
# fourth exhausted a cap of 2 and gave up, and one further reconfigure by hand
# then fixed it — which is why the shipped cap is 4 and why case 8 pins it.
#
# The idle-vs-wedged pair below is the point of this file. The gate originally
# tested "C_SUBMIT advancing while C_DONE is frozen", which scores a genuinely
# wedged fabric as an idle engine, because a wedged engine blocks on an ack that
# never arrives and stops submitting too. Both counters go static and the wedge
# is invisible. These two cases pin the corrected criterion.
set -u

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LAUNCH="$REPO/games/Maldita Castilla/launch.sh"
[ -f "$LAUNCH" ] || { echo "FAIL: launch.sh not found at $LAUNCH"; exit 1; }

FAILED=0
fail() { echo "FAIL: $*"; FAILED=1; }

# --- sandbox -----------------------------------------------------------------
# $1 bring-up verdict script: prints the line the engine writes each run, given
#    the run index on stdin ("ok" / "SOFT-FAILED")
# $2 sub value, $3 done-value generator ("frozen" | "advance")
setup() {
    SB="$(mktemp -d)"
    mkdir -p "$SB/bin" "$SB/game" "$SB/log" "$SB/rbf"
    : > "$SB/cmd"                      # stands in for /dev/MiSTer_cmd
    echo "Maldita Castilla" > "$SB/corename"
    : > "$SB/rbf/MalditaCastilla_20260807.rbf"
    echo 0 > "$SB/runs"
    echo "${1:-ok}" > "$SB/verdict"
    echo "${2:-0x10}" > "$SB/sub"
    echo "${3:-frozen}" > "$SB/donemode"
    echo "0x10" > "$SB/done"

    # Engine stub: marks itself live, records the run, writes the bring-up line,
    # then lingers briefly so the gate's poll loop sees a running engine. It has
    # to linger: fabric_verdict checks liveness on every iteration and returns
    # "undetermined" if the engine is already gone, so a stub that exits
    # instantly makes every wedge case unreachable.
    cat > "$SB/game/gmloader" <<EOF
#!/usr/bin/env bash
touch "$SB/running"
n=\$(cat "$SB/runs"); n=\$((n+1)); echo "\$n" > "$SB/runs"
v=\$(sed -n "\${n}p" "$SB/verdict"); [ -n "\$v" ] || v=\$(tail -1 "$SB/verdict")
echo "backend_mfgpu: fabric bring-up \$v — found submit=1 done=1"
/bin/sleep 2
rm -f "$SB/running"
exit 0
EOF
    chmod +x "$SB/game/gmloader"

    cat > "$SB/bin/busybox" <<EOF
#!/usr/bin/env bash
# devmem <addr> 32
[ "\$1" = devmem ] || exit 0
case "\$2" in
  0xFF706014) echo "0x00040000" ;;                 # FPGA ready
  0x3B000000) cat "$SB/sub" ;;
  0x3B000028)
      if [ "\$(cat "$SB/donemode")" = advance ]; then
          cur=\$(cat "$SB/done"); nxt=\$(printf "0x%X" \$(( cur + 1 ))); echo "\$nxt" > "$SB/done"
      fi
      cat "$SB/done" ;;
  *) echo "0x00000000" ;;
esac
EOF
    chmod +x "$SB/bin/busybox"

    # Delegate to the real ps rather than a marker file. A marker the stub
    # writes after exec loses a startup race the device does not have — there
    # the process is visible from fork, so the gate's liveness check passes
    # while the engine is still coming up. Keying on the marker made every
    # wedge case return "undetermined" instead of exercising recovery.
    cat > "$SB/bin/ps" <<'PSEOF'
#!/usr/bin/env bash
/bin/ps -Ao pid,user,command 2>/dev/null | grep "gmloader -c" | grep -v "[g]rep"
exit 0
PSEOF
    chmod +x "$SB/bin/ps"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/bin/killall"; chmod +x "$SB/bin/killall"
    # Real, but short. Stubbing sleep to a no-op spins the gate's poll loops
    # past the backgrounded engine before it has written anything, which turns
    # every wedge case into "undetermined".
    printf '#!/usr/bin/env bash\nexec /bin/sleep 0.05\n' > "$SB/bin/sleep"; chmod +x "$SB/bin/sleep"
    # No main= wrapper resident by default; MiSTer is, so the FIFO has a servicer.
    cat > "$SB/bin/pidof" <<EOF
#!/usr/bin/env bash
case "\$1" in
  MiSTer_Maldita) [ -f "$SB/main_wrapper" ] && { echo 4242; exit 0; }; exit 1 ;;
  MiSTer) echo 1234; exit 0 ;;
esac
exit 1
EOF
    chmod +x "$SB/bin/pidof"
}

run_launch() {
    PATH="$SB/bin:$PATH" \
    MALDITA_GAMEDIR="$SB/game" MALDITA_LOGDIR="$SB/log" \
    MALDITA_MISTER_CMD="$SB/cmd" MALDITA_CORENAME_FILE="$SB/corename" \
    MALDITA_MENU_RBF="$SB/rbf/menu.rbf" MALDITA_RBF_GLOB="$SB/rbf/MalditaCastilla_*.rbf" \
    MALDITA_RETRY_MARK="$SB/retry" \
    MALDITA_FABRIC_SAMPLE_S=0 MALDITA_FABRIC_SUBMIT_WAIT_S=60 \
    MALDITA_FABRIC_RETRIES="${RETRIES:-2}" \
    timeout 60 bash "$LAUNCH" >/dev/null 2>&1
}

log() { cat "$SB/log/maldita.log" "$SB/log/maldita.prev.log" 2>/dev/null; }

# --- case 1: healthy bring-up, frames retiring -> gate stays out of the way ---
setup "ok" "0x10" "advance"
run_launch
log | grep -q "WEDGED" && fail "case 1: gate fired on a healthy fabric"
[ "$(cat "$SB/runs")" = "1" ] || fail "case 1: engine ran $(cat "$SB/runs") times, expected 1"
[ -s "$SB/cmd" ] && fail "case 1: gate reconfigured a healthy fabric"
[ -f "$SB/retry" ] && fail "case 1: retry marker left behind after a healthy start"
rm -rf "$SB"

# --- case 2: bring-up ok, C_DONE frozen, nothing outstanding (sub == done) ----
# A quiet engine on a paused game. Must NOT be called a wedge, or the gate
# reboots the core out from under the player.
setup "ok" "0x10" "frozen"
echo "0x10" > "$SB/done"; echo "0x10" > "$SB/sub"
run_launch
log | grep -q "WEDGED" && fail "case 2: idle engine (sub == done) misread as wedged"
[ "$(cat "$SB/runs")" = "1" ] || fail "case 2: engine restarted on an idle fabric"
rm -rf "$SB"

# --- case 3: bring-up ok, C_DONE frozen, work outstanding (sub > done) -------
# The signature the original criterion missed entirely.
setup "ok" "0x99" "frozen"
echo "0x10" > "$SB/done"; echo "0x99" > "$SB/sub"
run_launch
log | grep -q "WEDGED" || fail "case 3: frozen C_DONE with work outstanding not detected"
grep -q "load_core" "$SB/cmd" || fail "case 3: no reconfigure issued"
rm -rf "$SB"

# --- case 4: engine reports SOFT-FAILED, then recovers -----------------------
setup "$(printf 'SOFT-FAILED\nok\n')" "0x10" "advance"
run_launch
log | grep -q "recovery attempt 1/2" || fail "case 4: no recovery attempt logged"
log | grep -q "menu.rbf round-trip" || fail "case 4: menu round-trip not taken"
# The stand-in for /dev/MiSTer_cmd is a plain file and reconfigure_fabric writes
# with `>` — correct for a FIFO, where each write is its own message, but on a
# file each write truncates. So the round-trip is asserted from the log line
# above, and the file only tells us which load_core came LAST. That it is the
# core RBF and not menu.rbf is the ordering assertion: menu first, core second.
grep -q "MalditaCastilla_20260807.rbf" "$SB/cmd" \
    || fail "case 4: last load_core was not the core RBF (got: $(cat "$SB/cmd"))"
[ "$(cat "$SB/runs")" -ge 2 ] || fail "case 4: engine not restarted after recovery"
rm -rf "$SB"

# --- case 5: never recovers -> retry cap, engine left running ----------------
setup "SOFT-FAILED" "0x99" "frozen"
echo "0x10" > "$SB/done"
RETRIES=2 run_launch
log | grep -q "giving up" || fail "case 5: retry cap not reached / no give-up line"
n=$(log | grep -c "recovery attempt")
[ "$n" -le 2 ] || fail "case 5: $n recovery attempts, cap is 2"
rm -rf "$SB"

# --- case 6: main= resident -> hand off, never start a second engine ---------
# Restarting in-process here is the dual-engine corruption (.62 2026-08-05).
setup "SOFT-FAILED" "0x99" "frozen"
echo "0x10" > "$SB/done"; touch "$SB/main_wrapper"
run_launch
log | grep -q "handing off to the respawned launcher" || fail "case 6: did not hand off under main="
[ "$(cat "$SB/runs")" = "1" ] || fail "case 6: started $(cat "$SB/runs") engines under main=, expected 1"
rm -rf "$SB"

# --- case 7: no devmem -> never block a launch on a missing instrument -------
setup "ok" "0x10" "frozen"
rm -f "$SB/bin/busybox"
run_launch
[ "$(cat "$SB/runs")" = "1" ] || fail "case 7: engine did not start without busybox"
log | grep -q "starting unsupervised" || fail "case 7: no unsupervised note logged"
rm -rf "$SB"

# --- case 8: the shipped default cap ----------------------------------------
# Every case above pins MALDITA_FABRIC_RETRIES so the cap under test is known,
# which means none of them would notice the default changing. It matters: with
# the default at 2, a v0.3.1 reboot trial exhausted both attempts and gave up on
# a fabric that a single further reconfigure fixed.
grep -qE 'MALDITA_FABRIC_RETRIES:-4\}' "$LAUNCH" \
    || fail "case 8: default retry cap is no longer 4 (2 was measured too low to recover)"

if [ "$FAILED" -eq 0 ]; then
    echo "PASS: healthy no-op, idle vs wedged C_DONE, SOFT-FAILED recovery, retry cap + default, main= handoff, missing devmem"
fi
exit "$FAILED"

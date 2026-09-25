#!/bin/bash
# fps-dip harness, device side. One capture = one fresh core load + engine start
# through the real launch path (main= -> launch.sh), scripted play, and a
# displayed-frame record from tools/fps_probe.c. Nothing polls the device over
# SSH while the capture runs (capture.sh starts this detached and waits), and
# everything is written to /tmp: /media/fat is mounted sync.
#
#   run.sh TAG SECS WARM_S SEED
#     SECS    probe duration (the measured leg)
#     WARM_S  seconds from engine start to the probe start (title -> gameplay)
#     SEED    tools/joy_play.c route seed (scripted play via /dev/shm)
#   /tmp/fpsdip/test.env, if present, is installed as the engine's bench.env
#   (launch.sh sources it) for A/B knobs.
#
# Output: /tmp/fpsdip/TAG/{fps.csv,probe.txt,proc.txt,irq0.txt,maldita.log,info.txt}
# and /tmp/fpsdip/TAG/DONE when finished.
set -u
TAG="$1"; SECS="$2"; WARM="$3"; SEED="$4"
D=/tmp/fpsdip; OUT="$D/$TAG"
GMDIR=/media/fat/games/gmloader
RBF="$(ls -1t /media/fat/_Other/MalditaCastilla_*.rbf | head -1)"
LOG=/media/fat/logs/MalditaCastilla/maldita.log
rm -rf "$OUT"; mkdir -p "$OUT"
exec > "$OUT/run.txt" 2>&1
taskset -p 2 $$ >/dev/null 2>&1

engine_pid() { for p in /proc/[0-9]*; do [ "$(readlink $p/exe 2>/dev/null)" = "$GMDIR/gmloader" ] && echo "${p#/proc/}"; done; }
kill_all() {
    for p in $(engine_pid); do kill "$p" 2>/dev/null; done
    sleep 2
    for p in $(engine_pid); do kill -9 "$p" 2>/dev/null; done
    for p in $(ps | grep '[j]oy_play' | sed -e 's/^ *//' -e 's/ .*//'); do kill "$p" 2>/dev/null; done
    sleep 1
    rm -f "$GMDIR/bench.env" /dev/shm/maldita-joy
}

# Start from the menu core so load_core really reconfigures (a load of the
# already-loaded RBF is a no-op).
kill_all
if [ "$(cat /tmp/CORENAME)" != MENU ]; then
    echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
    n=0; while [ "$(cat /tmp/CORENAME)" != MENU ] && [ $n -lt 30 ]; do sleep 1; n=$((n+1)); done
    sleep 2
fi

[ -f "$D/test.env" ] && cp "$D/test.env" "$GMDIR/bench.env"
( taskset 2 /tmp/joy_play.armhf /dev/shm/maldita-joy "$SEED" > "$OUT/joy.txt" 2>&1 & )

{ echo "tag=$TAG secs=$SECS warm=$WARM seed=$SEED"; echo "rbf=$RBF"; date
  md5sum "$GMDIR/gmloader" "$RBF" "/media/fat/games/Maldita Castilla/launch.sh"
  cat "$D/test.env" 2>/dev/null; uname -r; } > "$OUT/info.txt"

# The engine aborts during RunnerLoadGame on ~1 in 3 cold starts (malloc(): invalid
# size, pre-existing: v0.3.5 4/12 on .81). Retry the start up to 3 times; a start
# counts once the fabric bring-up is logged.
pid=""
for attempt in 1 2 3; do
    rm -f "$LOG"
    echo "load_core $RBF" > /dev/MiSTer_cmd
    n=0
    while [ $n -lt 45 ]; do
        sleep 1; n=$((n+1))
        grep -q 'fabric bring-up ok' "$LOG" 2>/dev/null && { pid="$(engine_pid | head -1)"; break; }
        grep -q -E 'malloc\(\)|SIGABRT|SIGSEGV|corrupted' "$LOG" 2>/dev/null && break
    done
    [ -n "$pid" ] && break
    echo "start attempt $attempt failed: $(grep -m1 -E 'malloc\(\)|SIGABRT|SIGSEGV|corrupted' "$LOG" 2>/dev/null)"
    echo "start_failed_attempt=$attempt" >> "$OUT/info.txt"
    # Engine only: joy_play and its shm stay up, so the next engine latches the
    # shm transport on its first input poll (its Sword presses also start the game
    # from the title after the intro window has passed).
    for p in $(engine_pid); do kill "$p" 2>/dev/null; done; sleep 2
    for p in $(engine_pid); do kill -9 "$p" 2>/dev/null; done
    echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
    n=0; while [ "$(cat /tmp/CORENAME)" != MENU ] && [ $n -lt 30 ]; do sleep 1; n=$((n+1)); done; sleep 2
done
[ -z "$pid" ] && { echo "engine did not start"; kill_all; touch "$OUT/DONE"; exit 1; }
echo "engine pid $pid after ${n}s (attempt $attempt)"
ls -1 "/media/fat/screenshots/Maldita Castilla/" 2>/dev/null > "$OUT/shots_before.txt"
sleep "$WARM"

# 1 Hz /proc sampler (builtins + cat only), on CPU1 with this script.
(
    while [ -f "$OUT/sampling" ]; do
        read -r _ u n s i w q sq _ < <(grep '^cpu0' /proc/stat)
        read -r l < <(grep -E '^ *34:' /proc/interrupts)
        echo "$(cut -d' ' -f1 /proc/uptime) cpu0 $u $n $s $i $w $q $sq irq34 $l"
        sleep 1
    done > "$OUT/proc.txt"
) &
touch "$OUT/sampling"
# Game-state witness: a screenshot every SHOT_S seconds (MiSTer does the work, on CPU1).
SHOT_S="${SHOT_S:-30}"
( while [ -f "$OUT/sampling" ]; do echo screenshot > /dev/MiSTer_cmd; sleep "$SHOT_S"; done ) &
cat /proc/interrupts > "$OUT/irq_before.txt"
for t in /proc/$pid/task/*; do echo "$(basename $t) $(cat $t/comm) $(taskset -p "$(basename "$t")" 2>/dev/null | sed 's/.*: //') $(grep -E 'ctxt' $t/status | tr '\n' ' ')"; done > "$OUT/threads_before.txt"
ps w > "$OUT/ps.txt"

/tmp/fps_probe.armhf "$SECS" "$OUT/fps.csv" 500 1 > "$OUT/probe.txt" 2>&1

rm -f "$OUT/sampling"
cat /proc/interrupts > "$OUT/irq_after.txt"
for t in /proc/$pid/task/*; do echo "$(basename $t) $(cat $t/comm) $(taskset -p "$(basename "$t")" 2>/dev/null | sed 's/.*: //') $(grep -E 'ctxt' $t/status | tr '\n' ' ')"; done > "$OUT/threads_after.txt"
echo "screenshot" > /dev/MiSTer_cmd; sleep 2
alive=0; [ -d /proc/$pid ] && alive=1
echo "engine_alive_at_end=$alive" >> "$OUT/info.txt"
ls -1 "/media/fat/screenshots/Maldita Castilla/" 2>/dev/null > "$OUT/shots_after.txt"
kill_all
tail -c 3000000 "$LOG" > "$OUT/maldita.log"
echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
touch "$OUT/DONE"

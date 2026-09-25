#!/bin/bash
# startloop.sh N [KEY=VAL ...] — device side: N cold engine starts through the real
# launch path; per start, report "ok" (fabric bring-up logged) or the crash line.
# KEY=VAL pairs become the engine's bench.env. Output: /tmp/fpsdip/startloop.txt
N="$1"; shift
GMDIR=/media/fat/games/gmloader; LOG=/media/fat/logs/MalditaCastilla/maldita.log
RBF="$(ls -1t /media/fat/_Other/MalditaCastilla_*.rbf | head -1)"
OUT=/tmp/fpsdip/startloop.txt; : > "$OUT"
taskset -p 2 $$ >/dev/null 2>&1
: > "$GMDIR/bench.env"; for kv in "$@"; do echo "export $kv" >> "$GMDIR/bench.env"; done
engine_pids() { for p in /proc/[0-9]*; do [ "$(readlink $p/exe 2>/dev/null)" = "$GMDIR/gmloader" ] && echo "${p#/proc/}"; done; }
for i in $(seq 1 "$N"); do
    for p in $(engine_pids); do kill "$p"; done; sleep 2
    for p in $(engine_pids); do kill -9 "$p"; done
    echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
    n=0; while [ "$(cat /tmp/CORENAME)" != MENU ] && [ $n -lt 30 ]; do sleep 1; n=$((n+1)); done; sleep 2
    rm -f "$LOG"
    echo "load_core $RBF" > /dev/MiSTer_cmd
    r=timeout
    for t in $(seq 1 45); do
        sleep 1
        if grep -q -E 'malloc\(\)|SIGABRT|SIGSEGV|corrupted' "$LOG" 2>/dev/null; then
            r="CRASH $(grep -m1 -E 'malloc\(\)|corrupted|SIGSEGV|SIGABRT' "$LOG")"; break; fi
        grep -q 'fabric bring-up ok' "$LOG" 2>/dev/null && { r=ok; break; }
    done
    echo "$i $r t=${t}s $(md5sum < $GMDIR/gmloader | cut -c1-8) $*" >> "$OUT"
done
for p in $(engine_pids); do kill "$p"; done
rm -f "$GMDIR/bench.env"
echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
echo DONE >> "$OUT"

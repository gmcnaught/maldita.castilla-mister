#!/bin/bash
# fps-dip harness, host side: stage, run scripts/fpsdip/run.sh detached on the
# device, stay off the device's SSH while it runs, pull, analyse.
#
#   capture.sh TAG [SECS=600] [WARM_S=90] [SEED=1] [KEY=VAL ...]
#   MISTER_HOST (default root@192.168.20.81)
# KEY=VAL pairs become `export KEY=VAL` lines of the engine's bench.env.
# GMLOADER_GODMODE=1 is always set (the scripted route needs it).
# SHOT_S (default 30): screenshot interval during the leg, pulled to shots/.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$HERE/../.."
HOST="${MISTER_HOST:-root@192.168.20.81}"
TAG="$1"; SECS="${2:-600}"; WARM="${3:-90}"; SEED="${4:-1}"
shift $(( $# < 4 ? $# : 4 ))
OUT="$ROOT/bench-results/fpsdip/$TAG"
mkdir -p "$OUT"
env_file="$(mktemp)"; echo "export GMLOADER_GODMODE=1" > "$env_file"
for kv in "$@"; do echo "export $kv" >> "$env_file"; done

ssh "$HOST" "mkdir -p /tmp/fpsdip; rm -f /tmp/fpsdip/test.env"
scp -q "$ROOT/tools/fps_probe.armhf" "$ROOT/tools/joy_play.armhf" "$HOST:/tmp/"
scp -q "$HERE/run.sh" "$env_file" "$HOST:/tmp/fpsdip/"
ssh "$HOST" "mv /tmp/fpsdip/$(basename "$env_file") /tmp/fpsdip/test.env; chmod +x /tmp/fpsdip/run.sh /tmp/fps_probe.armhf /tmp/joy_play.armhf"
rm -f "$env_file"
ssh "$HOST" "( SHOT_S='${SHOT_S:-30}' setsid /tmp/fpsdip/run.sh '$TAG' '$SECS' '$WARM' '$SEED' </dev/null >/dev/null 2>&1 & )"
echo "[fpsdip] $TAG started on $HOST: ${SECS}s leg after ${WARM}s warm-up"
sleep $(( SECS + WARM + 45 ))
while ! ssh "$HOST" "test -f /tmp/fpsdip/$TAG/DONE"; do sleep 15; done
scp -q "$HOST:/tmp/fpsdip/$TAG/*" "$OUT/"
# Screenshots taken during the leg (run.sh SHOT_S), in time order.
mkdir -p "$OUT/shots"
[ -f "$OUT/shots_before.txt" ] && comm -13 "$OUT/shots_before.txt" "$OUT/shots_after.txt" | while read -r f; do
    scp -q "$HOST:/media/fat/screenshots/Maldita Castilla/$f" "$OUT/shots/" </dev/null
    ssh "$HOST" "rm -f '/media/fat/screenshots/Maldita Castilla/$f'" </dev/null
done
python3 "$HERE/frames.py" "$OUT" | tee "$OUT/report.txt"
# A run whose engine did not latch the scripted-input transport measured the
# title / attract loop, not play.
src="$(grep -m1 -o 'JOYSRC transport=[a-z]*' "$OUT/maldita.log" 2>/dev/null)"
[ "$src" = "JOYSRC transport=shm" ] || echo "  WARNING: input transport '${src:-unknown}' — scripted play did not run; this capture is NOT gameplay" | tee -a "$OUT/report.txt"
grep -h 'start_failed_attempt' "$OUT/info.txt" 2>/dev/null | sed 's/^/  NOTE: engine start crashed, retried: /' | tee -a "$OUT/report.txt"

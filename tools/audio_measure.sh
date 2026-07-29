#!/bin/sh
# Load an RBF, wait until the engine is genuinely producing audio, then measure.
# The settle-wait is the point: a probe run 32 s after load_core samples the game's
# startup, where the ring is still empty and the numbers are meaningless.
RBF="$1"; SECS="${2:-40}"
echo "load_core /media/fat/_Other/$RBF" > /dev/MiSTer_cmd
i=0
while [ $i -lt 90 ]; do
  sleep 2; i=$((i+2))
  pidof gmloader >/dev/null 2>&1 || continue
  wr=$(busybox devmem 0x3A000030 32); rd=$(busybox devmem 0x3A000038 32)
  occ=$(( ( (wr - rd) & 0xFFFF ) / 4 ))
  # Require a well-filled ring twice in a row: the pump tops up to 4800 frames, so
  # >4000 sustained means the producer is live and steady, not mid-startup.
  if [ "$occ" -gt 4000 ]; then
    ok=$((ok+1)); [ "$ok" -ge 3 ] && { echo "settled after ${i}s (occ=$occ)"; break; }
  else ok=0; fi
done
[ "$ok" -ge 3 ] || { echo "NEVER SETTLED after ${i}s — engine not producing audio; measurement skipped"; exit 1; }
sleep 5
/tmp/audio_ring_probe.armhf "$SECS" 0.1 2>&1 | grep -E "FPGA drain|host submit|ring occupancy|underflow pops|short bursts|low-water"

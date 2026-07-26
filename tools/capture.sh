#!/bin/sh
# Healthy-frame capture: fire a screenshot every second and record the fabric
# counters alongside it, so each PNG can be tagged with the frame number it was
# taken at (and therefore placed before/after the first stall).
#
# C_SUBMIT = 0x3B000000 (qword 0), C_DONE = 0x3B000028 (qword 5).
OUT=/tmp/cap_index.txt
N=${1:-60}
: > "$OUT"
i=0
while [ "$i" -lt "$N" ]; do
    S=$(busybox devmem 0x3B000000 32)
    D=$(busybox devmem 0x3B000028 32)
    T=$(date '+%Y%m%d_%H%M%S')
    echo "$T shot=$i submit=$S done=$D" >> "$OUT"
    echo screenshot > /dev/MiSTer_cmd
    sleep 1
    i=$((i + 1))
done
echo "capture complete" >> "$OUT"

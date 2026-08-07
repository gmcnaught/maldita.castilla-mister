#!/bin/bash
#
# gmloader_diag.sh — launch the gmloader core with diag/perf-tuning knobs.
#
# Copy to /media/fat/Scripts/ on the MiSTer; it appears in the Scripts menu.
# Also runnable directly over SSH for A/B perf sessions:
#
#   ./gmloader_diag.sh --preset fabric --prof        # FPGA-fabric offload, profiled
#   ./gmloader_diag.sh -b 2 -r sw -t 4 --trace       # SW raster, 4 threads, draw trace
#   ./gmloader_diag.sh --preset gl                   # pure-GL baseline (blitter off)
#   ./gmloader_diag.sh --preset sw --dry-run         # show env + command, don't run
#
# Every knob maps to a GMLOADER_* env var the loader reads at startup; the
# active config is echoed (and logged) so each run in the log is self-labeling.
#
set -u

# ---- defaults ---------------------------------------------------------------
GMDIR="${GMDIR:-/media/fat/games/gmloader}"
CONFIG="gmloader.json"
LOG="/tmp/gmloader.log"
DRY=0

# Diag env (empty string == "leave unset, use the loader's own default").
E_BLITTER=""      # GMLOADER_BLITTER        0 off | 1 shadow+GL | 2 owns render
E_RASTER=""       # GMLOADER_RASTER         mfgpu = FPGA fabric | (unset) = software
E_PROF=""         # GMLOADER_BLITTER_PROF   per-frame tex/clear/raster/present timing
E_TRACE=""        # GMLOADER_DRAW_TRACE     per-frame draw/clear/vert counts
E_THREADS=""      # GMLOADER_BLITTER_THREADS  SW raster threads 1..4
E_CULL=""         # GMLOADER_BLITTER_CULL   backface cull 0|1
E_OPAQUE=""       # GMLOADER_BLITTER_OPAQUE assume-opaque 0|1
E_NOTEX=""        # GMLOADER_BLITTER_NOTEX  1 = disable texturing
E_TEX16=""        # GMLOADER_BLITTER_TEX16  1 = RGBA4444 texels
E_RW=""           # GMLOADER_RENDER_W       render width  (<=288, level 2 only)
E_RH=""           # GMLOADER_RENDER_H       render height (<=216, level 2 only)
E_FPS=""          # GMLOADER_FPS            frame cap; 0 = uncapped
E_TRACEVM=""      # GMLOADER_TRACE_VM       1 = YoYo VM trace
E_DUMPSH=""       # GMLOADER_DUMP_SHADERS   1 = dump shader sources
E_MFSTAT=""       # GMLOADER_MFSUBMIT_STAT  1 = read fabric perf counters (frame/tri/texwait/dpath)
E_JOYSHM=""       # GMLOADER_JOY_SHM        scripted-input shm path override
E_GODMODE=""      # GMLOADER_GODMODE        1 = skip obj_player collision events (bench)

usage() {
  cat <<'EOF'
gmloader_diag.sh — start the gmloader core with performance-tuning diag knobs.

USAGE
  gmloader_diag.sh [preset] [knobs] [options]

PRESETS  (--preset NAME, applied first; later flags override)
  gl        blitter off — pure GLES/software baseline (the ~1fps reference)
  sw        blitter=2 (owns render) + software raster + profiling
  fabric    blitter=2 + FPGA-fabric offload (GMLOADER_RASTER=mfgpu) + profiling + trace

KNOBS  (each maps to a GMLOADER_* env var)
  -b, --blitter N     blitter level: 0 off | 1 shadow+GL | 2 owns render
  -r, --raster MODE   sw | mfgpu   (mfgpu = FPGA fabric offload)
  -t, --threads N     SW raster threads (1..4)
      --cull 0|1      backface cull            (default 1)
      --opaque 0|1    assume-opaque fast path  (default 1)
      --notex         disable texturing
      --tex16         RGBA4444 texels (half texture bandwidth)
      --render WxH    render size, e.g. 320x224 (level 2 only)
  -f, --fps N         frame cap; 0 = uncapped (default 60)
      --prof          per-frame tex/clear/raster/present timing buckets
      --trace         per-frame draw/clear/vertex counts
      --trace-vm      YoYo VM trace
      --dump-shaders  dump shader sources
      --godmode       skip obj_player collision events (bench survival)

OPTIONS
      --dir DIR       gmloader install dir   (default /media/fat/games/gmloader)
  -c, --config FILE   loader config          (default gmloader.json)
      --log FILE      tee output here        (default /tmp/gmloader.log)
  -n, --dry-run       print env + command, do not launch
  -h, --help          this help

EXAMPLES
  gmloader_diag.sh --preset fabric --prof
  gmloader_diag.sh -b 2 -r sw -t 4 --trace
  gmloader_diag.sh --preset sw --render 320x224 --fps 0
  gmloader_diag.sh --preset gl --dry-run
EOF
}

apply_preset() {
  case "$1" in
    gl)     E_BLITTER=0 ;;
    sw)     E_BLITTER=2; E_RASTER=sw;    E_PROF=1 ;;
    fabric) E_BLITTER=2; E_RASTER=mfgpu; E_PROF=1; E_TRACE=1; E_MFSTAT=1 ;;
    *) echo "unknown preset: $1  (gl | sw | fabric)" >&2; exit 2 ;;
  esac
}

# ---- parse ------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --preset)        apply_preset "$2"; shift 2 ;;
    -b|--blitter)    E_BLITTER="$2"; shift 2 ;;
    -r|--raster)     E_RASTER="$2";  shift 2 ;;
    -t|--threads)    E_THREADS="$2"; shift 2 ;;
    --cull)          E_CULL="$2";    shift 2 ;;
    --opaque)        E_OPAQUE="$2";  shift 2 ;;
    --notex)         E_NOTEX=1;      shift ;;
    --tex16)         E_TEX16=1;      shift ;;
    --render)        E_RW="${2%%x*}"; E_RH="${2##*x}"; shift 2 ;;
    --joy-shm)       E_JOYSHM="$2";  shift 2 ;;
    -f|--fps)        E_FPS="$2";     shift 2 ;;
    --prof)          E_PROF=1;       shift ;;
    --trace)         E_TRACE=1;      shift ;;
    --trace-vm)      E_TRACEVM=1;    shift ;;
    --dump-shaders)  E_DUMPSH=1;     shift ;;
    --godmode)       E_GODMODE=1;    shift ;;
    --dir)           GMDIR="$2";     shift 2 ;;
    -c|--config)     CONFIG="$2";    shift 2 ;;
    --log)           LOG="$2";       shift 2 ;;
    -n|--dry-run)    DRY=1;          shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown arg: $1  (see --help)" >&2; exit 2 ;;
  esac
done

# ---- build env --------------------------------------------------------------
# Only export knobs the user actually set, so unset ones keep the loader's
# own default (e.g. blitter level from gmloader.json).
ENV=()
[ -n "$E_BLITTER" ] && ENV+=("GMLOADER_BLITTER=$E_BLITTER")
[ -n "$E_RASTER"  ] && ENV+=("GMLOADER_RASTER=$E_RASTER")
[ -n "$E_PROF"    ] && ENV+=("GMLOADER_BLITTER_PROF=$E_PROF")
[ -n "$E_TRACE"   ] && ENV+=("GMLOADER_DRAW_TRACE=$E_TRACE")
[ -n "$E_THREADS" ] && ENV+=("GMLOADER_BLITTER_THREADS=$E_THREADS")
[ -n "$E_CULL"    ] && ENV+=("GMLOADER_BLITTER_CULL=$E_CULL")
[ -n "$E_OPAQUE"  ] && ENV+=("GMLOADER_BLITTER_OPAQUE=$E_OPAQUE")
[ -n "$E_NOTEX"   ] && ENV+=("GMLOADER_BLITTER_NOTEX=$E_NOTEX")
[ -n "$E_TEX16"   ] && ENV+=("GMLOADER_BLITTER_TEX16=$E_TEX16")
[ -n "$E_RW"      ] && ENV+=("GMLOADER_RENDER_W=$E_RW")
[ -n "$E_RH"      ] && ENV+=("GMLOADER_RENDER_H=$E_RH")
[ -n "$E_FPS"     ] && ENV+=("GMLOADER_FPS=$E_FPS")
[ -n "$E_TRACEVM" ] && ENV+=("GMLOADER_TRACE_VM=$E_TRACEVM")
[ -n "$E_DUMPSH"  ] && ENV+=("GMLOADER_DUMP_SHADERS=$E_DUMPSH")
[ -n "$E_MFSTAT"  ] && ENV+=("GMLOADER_MFSUBMIT_STAT=$E_MFSTAT")
[ -n "$E_JOYSHM"  ] && ENV+=("GMLOADER_JOY_SHM=$E_JOYSHM")
[ -n "$E_GODMODE" ] && ENV+=("GMLOADER_GODMODE=$E_GODMODE")

# ---- summary ----------------------------------------------------------------
# Safe under `set -u` even when ENV is empty (old bash chokes on ${ENV[*]}).
if [ ${#ENV[@]} -eq 0 ]; then DIAG_STR="(none — loader defaults)"; else DIAG_STR="${ENV[*]}"; fi
echo "=== gmloader diag run ==="
echo "  dir    : $GMDIR"
echo "  config : $CONFIG"
echo "  log    : $LOG"
echo "  diag   : $DIAG_STR"
echo "========================="

if [ "$DRY" -eq 1 ]; then
  if [ ${#ENV[@]} -eq 0 ]; then
    echo "[dry-run] ./gmloader -c $CONFIG"
  else
    echo "[dry-run] env ${ENV[*]} ./gmloader -c $CONFIG"
  fi
  exit 0
fi

# ---- launch -----------------------------------------------------------------
cd "$GMDIR" || { echo "gmloader dir not found: $GMDIR" >&2; sleep 3; exit 1; }

# Avoid a double-launch / ETXTBSY when re-running from the menu.
# busybox has NO pkill — it fails silently and this guard would pass vacuously.
# Match "[.]/gmloader" so neither grep nor this script matches itself.
#
# SIGTERM first, -9 only as a backstop, for the reason spelled out in
# games/Maldita Castilla/launch.sh: -9 is uncatchable, so the engine runs no
# teardown and leaves the fabric's DDR window (live doorbell, full command ring,
# full texture heap) for whatever starts next — and load_core does not clear it.
gm_pids() { ps | grep "[.]/gmloader" | sed -e "s/^ *//" -e "s/ .*//"; }
for p in $(gm_pids); do kill -TERM "$p" 2>/dev/null; done
n=0
while [ "$n" -lt 3 ] && [ -n "$(gm_pids)" ]; do
    sleep 1
    n=$((n + 1))
done
for p in $(gm_pids); do
    echo "gmloader $p ignored SIGTERM after 3s — SIGKILL" >&2
    kill -9 "$p" 2>/dev/null
done
sleep 1

export LD_LIBRARY_PATH="$GMDIR/mesa:$GMDIR"

# Record the diag config as the first log line so every capture is self-labeling.
echo "# gmloader_diag $(date '+%Y-%m-%d %H:%M:%S') :: $DIAG_STR" > "$LOG"

echo "Launching gmloader... log: $LOG"
if [ ${#ENV[@]} -eq 0 ]; then
  ./gmloader -c "$CONFIG" 2>&1 | tee -a "$LOG"
else
  env "${ENV[@]}" ./gmloader -c "$CONFIG" 2>&1 | tee -a "$LOG"
fi

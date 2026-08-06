#!/bin/bash
#
# mister_run.sh — drive the gmloader core on a real MiSTer over SSH, for
# autonomous perf-tuning A/B runs from a dev machine.
#
# Launch is via launch.sh, never by hand: a hand launch measures a different
# halt point (33 vs 21) and an interactive shell masks the LD_LIBRARY_PATH
# requirement launch.sh exports. Concretely: this
# script stages diag knobs as scripts/../bench.env on the device, triggers
# `load_core` on /dev/MiSTer_cmd, then runs games/Maldita Castilla/launch.sh
# (maldita.castilla-mister) to spawn the engine and source that file. It uses
# scripts/gmloader_diag.sh on the device ONLY to resolve CLI-style diag flags
# to GMLOADER_* env vars (via --dry-run — it is never executed to launch the
# engine directly), times the run from here, tears it down, and pulls the
# handler's own log back for analysis.
#
#   ./mister_run.sh deploy                         # push gmloader_diag.sh to the MiSTer
#   ./mister_run.sh bench --secs 20 --preset sw    # timed daemon-path run, auto-collect + summarize
#   ./mister_run.sh bench --secs 20 --preset fabric --prof --trace
#   ./mister_run.sh launch --preset gl             # stream a run live (Ctrl-C stops it)
#   ./mister_run.sh stop                           # kill engine PID(s) + clear any staged bench.env
#   ./mister_run.sh pull-log                        # scp the device log here
#
# Host + paths (override via env or flags):
#   MISTER_HOST   default root@192.168.20.81
#   GMDIR         default /media/fat/games/gmloader   (must match the diag script and launch.sh)
#
set -u

HOST="${MISTER_HOST:-root@192.168.20.81}"
GMDIR="${GMDIR:-/media/fat/games/gmloader}"
REMOTE_DIAG="/media/fat/Scripts/gmloader_diag.sh"
# launch.sh logs to its own log, NOT gmloader_diag.sh's /tmp/gmloader.log
# (that path is only used by a hand launch, which this script no longer
# performs for bench/launch).
REMOTE_LOG="/media/fat/logs/MalditaCastilla/maldita.log"
REMOTE_BENCH_ENV="$GMDIR/bench.env"
RBF_GLOB="/media/fat/_Other/MalditaCastilla_*.rbf"
# Must equal the RBF's CONF_STR setname (fpga/Maldita.sv) — MiSTer writes it to
# /tmp/CORENAME, and it is the directory launch.sh lives under.
CORENAME="${CORENAME:-Maldita Castilla}"
# The engine launcher. NOT _handler.sh — see load_core_and_wait.
LAUNCHER="${LAUNCHER:-/media/fat/games/$CORENAME/launch.sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
LOCAL_DIAG="$HERE/gmloader_diag.sh"
OUTDIR="${OUTDIR:-$HERE/../bench-results}"
SECS=20

# --scene support (Task 8 procedure follow-up): joy_script + a scripted
# button-mask file drive the engine to a deterministic in-game scene instead
# of the title screen. joy_script itself is built in the SIBLING gmloader-next
# checkout (three-project layout: dev happens there, this repo only bundles
# it as a submodule) — override JOY_SCRIPT_BIN if your checkout layout differs.
JOY_SHM_PATH="/dev/shm/maldita-joy"
REMOTE_JOYSCRIPT="$GMDIR/joy_script"
REMOTE_SCENE_JOY="$GMDIR/scene.joy"
LOCAL_SCENES_DIR="$HERE/scenes"
JOY_SCRIPT_BIN="${JOY_SCRIPT_BIN:-$HERE/../../gmloader-next/tools/joy_script.armhf}"
SCENE=""

# --capture START:FRAMES (Phase 3 Stage A) — stage the engine's
# GMLOADER_MFGPU_TRACE draw-stream capture for a bounded frame window and pull
# the result back. The frame numbers are the engine's own g_frame_no (counted
# from engine start, i.e. from the launch.sh spawn, NOT from bench start), so a
# window has to be calibrated against a log/screenshot anchor for the scene of
# interest — see docs/superpowers/findings/ for the calibrated values. That
# counter is 1-based (it is incremented as each frame opens, so the first frame
# is f=1 and f=0 never appears), and it is the same counter BLITPROF `f=` and
# MFSUBMIT `n=` print — verified in lockstep on .62 2026-07-29 — which is what
# makes a log window usable as the anchor for a trace window. START=0 therefore
# yields FRAMES-1 frames; calibrated windows start at 1 or above.
REMOTE_TRACE="/tmp/mftrace.txt"
CAPTURE=""
CAP_START=""
CAP_FRAMES=""

# --env KEY=VAL (repeatable) — append raw exports to the staged bench.env for
# engine knobs that are NOT part of gmloader_diag.sh's flag->env mapping (the
# same escape hatch --capture already uses, generalised). Diag-mapped knobs
# must still go through their own flags so the mapping stays single-sourced.
EXTRA_ENV=()

# --- wedge gate (Stage B Task 3) --------------------------------------------
# Stage A hit an intermittent frame-1 fabric wedge on core load (roughly 1 in
# 2 loads, 2026-07-27/29 postmortems): the fabric never acks a submit and the
# handler's log fills with "fabric submit timeout (submit=N done=0 ...)"
# lines while the display stays black. A RETRY clears it; a REBOOT does NOT
# (see docs/superpowers/investigations/2026-07-27-fabric-startup-wedge-handoff.md).
# Stage A caught this by hand-grepping the log after every load_core; that
# doesn't scale to the many-measurement runs that follow, and a missed wedge
# silently produces plausible-looking garbage numbers. WEDGE_PATTERN matches
# both that exact line and the shorter "submit timeout" signature named in
# the task brief.
WEDGE_PATTERN='submit timeout'
MAX_WEDGE_ATTEMPTS=3
WEDGE_CHECK_SECS="${WEDGE_CHECK_SECS:-5}"

# ssh connection reuse — bench sampling makes one SSH round trip per second;
# without multiplexing that is 20+ fresh TCP/SSH handshakes per run.
SSH_CTL="${TMPDIR:-/tmp}/.mister_run_ssh_ctl_$$"
SSH() {
  ssh -o BatchMode=yes -o ConnectTimeout=6 \
      -o ControlMaster=auto -o ControlPath="$SSH_CTL" -o ControlPersist=60 \
      "$HOST" "$@"
}
cleanup_ssh_ctl() { ssh -O exit -o ControlPath="$SSH_CTL" "$HOST" >/dev/null 2>&1 || true; }
trap cleanup_ssh_ctl EXIT

. "$HERE/lib/device_pids.sh"
. "$HERE/lib/scene_provenance.sh"

usage() {
  cat <<EOF
mister_run.sh — remote-drive gmloader on a MiSTer for perf A/B, via
launch.sh (never a hand launch).

COMMANDS
  deploy                 scp gmloader_diag.sh -> $REMOTE_DIAG (chmod +x)
                          — used only to resolve diag flags to env, not to launch.
  bench [--secs N] [--scene NAME] [--capture START:FRAMES] [--env K=V] ARGS
                         timed unattended run; ARGS resolve to
                         GMLOADER_* env staged as bench.env (e.g. --preset sw
                         --prof) for launch.sh to source. Asserts exactly one
                         engine on every sample, aborting the run otherwise.
                         Collects + summarizes.
  launch [--scene NAME] ARGS
                         stream a live run (foreground); Ctrl-C ends it.
  Both bench and launch retry through the known frame-1 fabric wedge
  (log signature: "submit timeout") up to $MAX_WEDGE_ATTEMPTS total attempts before
  aborting; a retried run prints "wedge: retry K/$MAX_WEDGE_ATTEMPTS" and the summary
  notes it, so it is never mistaken for a clean first-try run.
  --scene NAME (bench|launch)
                         stage scripts/scenes/NAME.joy + the joy_script binary
                         and start the scripted-input driver BEFORE load_core,
                         so the run lands on a deterministic in-game scene
                         instead of the title screen. See stage_scene() for
                         the ordering rationale.
  --capture START:FRAMES (bench|launch)
                         stage GMLOADER_MFGPU_TRACE for engine frames
                         [START, START+FRAMES) into $REMOTE_TRACE on the
                         device. bench pulls it back next to its log, BEFORE
                         teardown (same respawn race as the log).
                         START/FRAMES are engine frame numbers (g_frame_no,
                         from engine start), not seconds.
  --env KEY=VAL (bench|launch, repeatable)
                         append a raw `export KEY=VAL` to the staged bench.env,
                         for engine knobs with no gmloader_diag.sh flag (e.g.
                         GMLOADER_FCAP_STAT=1). Knobs that DO have a flag must
                         use it, so that mapping stays single-sourced.
  stop                   kill engine PID(s) directly (busybox-safe: no killall/
                         pkill/pgrep) and clear any staged bench.env.
  pull-log [FILE]        scp $REMOTE_LOG -> FILE (default under bench-results/).
  ping                   check SSH + core + engine process count.

ENV   MISTER_HOST=$HOST   GMDIR=$GMDIR   OUTDIR=$OUTDIR   WEDGE_CHECK_SECS=$WEDGE_CHECK_SECS
EOF
}

ensure_deployed() {
  if ! SSH "test -x $REMOTE_DIAG"; then
    echo "[deploy] $REMOTE_DIAG missing — pushing it"
    do_deploy
  fi
}

do_deploy() {
  [ -f "$LOCAL_DIAG" ] || { echo "missing $LOCAL_DIAG" >&2; exit 1; }
  scp -o BatchMode=yes "$LOCAL_DIAG" "$HOST:$REMOTE_DIAG" >/dev/null
  SSH "chmod +x $REMOTE_DIAG"
  echo "[deploy] installed $REMOTE_DIAG on $HOST"
}

# teardown — kill engine PID(s) + remove any staged bench.env. Idempotent:
# safe to call more than once in a row, and safe to re-enter (e.g. a SIGINT
# landing mid-teardown, between the kill step and the rm step, re-invokes
# this via the INT trap while the outer call is still blocked on its SSH
# round trip) because devpid_kill on an empty process list and `rm -f` on an
# already-missing file are both no-ops. There is deliberately NO reentrancy
# guard here: bash only runs the trap after the currently-blocking foreground
# command returns, so a nested call can never run concurrently with the
# outer one — only strictly after it, once execution is back at a command
# boundary. A guard that skipped the nested call on the grounds of "already
# running" would report false success and skip whichever step the outer call
# hadn't reached yet (see 2026-07-27 postmortem: this let bench.env survive
# on the device). Returns non-zero if either step actually failed (most
# likely: device unreachable), so callers can report honestly instead of
# claiming success unconditionally.
teardown() {
  local kill_rc=0 rm_rc=0
  devpid_kill SSH || kill_rc=$?
  # joy_script (if a --scene run started one) — same busybox bracket trick as
  # devpid_kill: "[.]/joy_script" matches the running process, not this grep,
  # not launch.sh. Left running, it would keep the shm mapping open across
  # runs and re-latch the SAME stale mask on the next launch even after the
  # rm below, since a live writer can recreate/rewrite the path between the
  # rm and the next reader's open().
  SSH "for p in \$(ps | grep '[.]/joy_script' | sed -e 's/^ *//' -e 's/ .*//'); do kill -9 \$p 2>/dev/null; done; true" || kill_rc=$?
  # Remove bench.env AND the joy-shm file. Leaving the shm file behind is the
  # orphaned-transport hazard fixed in gmloader-next's joy_script.c: even with
  # that fix, belt-and-suspenders here means a bench session that crashed
  # joy_script before its own cleanup ran still can't leak a live-magic file
  # into the next production launch (input.cpp latches shm-vs-ddr once, on the
  # engine's first input poll, and never re-checks — see the project's
  # recorded "input death" incident, same failure class).
  SSH "rm -f $REMOTE_BENCH_ENV $JOY_SHM_PATH" || rm_rc=$?
  [ "$kill_rc" = 0 ] && [ "$rm_rc" = 0 ]
}

# on_interrupt — INT/TERM handler for do_bench/do_launch. Installed as the
# FIRST statement in each so the sampling loop's `sleep 1` (do_bench's normal
# steady state) and the pre-daemon-launch window (do_launch, before this fix)
# are both covered; a trap installed only after staging/load_core leaves an
# earlier window where Ctrl-C abandons a staged bench.env + running engine.
_interrupted=0
on_interrupt() {
  [ "$_interrupted" = 1 ] && return
  _interrupted=1
  echo
  echo "[interrupt] tearing down..." >&2
  teardown
  exit 130
}

do_stop() {
  if teardown; then
    echo "[stop] engine PID(s) killed and bench.env cleared on $HOST"
  else
    echo "[stop] WARNING: teardown incomplete on $HOST — engine kill or bench.env removal may have failed (device unreachable?)" >&2
    return 1
  fi
}

# assert_sole_engine <label> — abort the run unless exactly one engine is up.
# Called per SAMPLE, not once per run: a second engine at any point silently
# corrupts the control block (see lib/device_pids.sh). The Master_Daemon route
# that used to spawn one is gone as of 2026-08-05, but the assertion stays —
# a stale _handler.sh on the device brings it straight back, and this is the
# check that catches it. Prints "[assert] LABEL: engine
# count = N" on success — later tasks grep bench output for this per sample.
assert_sole_engine() {
  local n
  if ! n=$(devpid_assert_one SSH); then
    echo "[ABORT] $1: expected exactly 1 gmloader process, found ${n:-0}" >&2
    return 1
  fi
  echo "[assert] $1: engine count = $n"
}

# sh_quote <string> — POSIX single-quote escaping. SSH() flattens argv into
# one command string that the device's busybox ash re-parses, so any flag
# value containing a space (e.g. a future --joy-shm PATH) must survive that
# round trip; unquoted $* splits it into extra words instead. No flag value
# has a space today, but a guard that only holds by coincidence of current
# inputs is exactly the defect class this task exists to close.
sh_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# build_bench_env <outfile> [ARGS...] — resolve gmloader_diag.sh's own
# CLI-arg -> GMLOADER_* env mapping (the single source of truth for that
# mapping) via --dry-run on the device, WITHOUT launching anything, and write
# it as `export KEY=VAL` lines. Empty ARGS -> empty outfile (no bench.env
# needed; the daemon launch behaves exactly like a plain production launch).
build_bench_env() {
  local outfile="$1"; shift
  : > "$outfile"
  [ $# -eq 0 ] && return 0
  local dry cmd arg
  cmd="$REMOTE_DIAG"
  for arg in "$@"; do
    cmd="$cmd $(sh_quote "$arg")"
  done
  cmd="$cmd --dry-run"
  if ! dry=$(SSH "$cmd" 2>&1); then
    echo "[bench-env] dry-run env resolution failed:" >&2
    printf '%s\n' "$dry" >&2
    return 1
  fi
  local envline
  envline=$(printf '%s\n' "$dry" | grep '^\[dry-run\] env ' || true)
  [ -z "$envline" ] && return 0
  envline="${envline#\[dry-run\] env }"
  envline="${envline% ./gmloader*}"
  local kv
  for kv in $envline; do
    echo "export $kv" >> "$outfile"
  done
}

# stage_bench_env [ARGS...] — write the resolved diag env to the device as
# bench.env (or remove any stale copy if there is nothing to stage), so
# launch.sh's optional hook can source it on the NEXT launch. Must run
# before load_core: launch.sh reads bench.env once, at
# launch, and this harness removes it again during teardown (do_stop) so a
# stale file can never silently steer a later production run.
stage_bench_env() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/bench.env.XXXXXX")"
  build_bench_env "$tmp" "$@" || { rm -f "$tmp"; return 1; }
  # --capture knobs are NOT part of gmloader_diag.sh's flag->env mapping (they
  # are a Phase 3 Stage A capture hook, not a diag preset), so they are appended
  # here rather than resolved via --dry-run. `export` is load-bearing: the
  # handler SOURCES bench.env (`. bench.env`) and then exec's the engine, so a
  # plain KEY=VAL assignment would stay a shell variable and never reach
  # getenv() — matching build_bench_env's own `export KEY=VAL` lines.
  if [ -n "$CAPTURE" ]; then
    printf 'export GMLOADER_MFGPU_TRACE=%s\n'        "$REMOTE_TRACE" >> "$tmp"
    printf 'export GMLOADER_MFGPU_TRACE_START=%s\n'  "$CAP_START"    >> "$tmp"
    printf 'export GMLOADER_MFGPU_TRACE_FRAMES=%s\n' "$CAP_FRAMES"   >> "$tmp"
    # Remove any trace from a previous run BEFORE the launch: the engine only
    # creates the file on its first in-window draw, so without this a run whose
    # window never opened (mis-calibrated START, engine died early) would scp a
    # stale file back and pass every "the capture landed" check.
    SSH "rm -f $REMOTE_TRACE" || {
      echo "[capture] ERROR: could not clear stale $REMOTE_TRACE on $HOST" >&2
      rm -f "$tmp"; return 1; }
  fi
  local kv
  for kv in ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}; do
    printf 'export %s\n' "$kv" >> "$tmp"
  done
  if [ -s "$tmp" ]; then
    if ! scp -o BatchMode=yes "$tmp" "$HOST:$REMOTE_BENCH_ENV" >/dev/null; then
      echo "[bench-env] ERROR: scp to $HOST:$REMOTE_BENCH_ENV failed — diag knobs NOT staged; refusing to continue and silently measure production defaults" >&2
      rm -f "$tmp"
      return 1
    fi
    echo "[bench-env] staged $REMOTE_BENCH_ENV: $(tr '\n' ' ' < "$tmp")"
  else
    SSH "rm -f $REMOTE_BENCH_ENV"
  fi
  rm -f "$tmp"
}

# stage_scene <name> — deploy joy_script + scripts/scenes/<name>.joy to the
# device and start the scripted-input driver, BEFORE load_core is called.
# ORDERING IS LOAD-BEARING (see joy_script.c / input.cpp:307-319): the shm
# transport latches on the engine's FIRST input poll and is never
# re-evaluated, so the driver's magic word must already be valid the moment
# launch.sh spawns the engine. No-op (returns 0) if name is
# empty — callers always call this unconditionally so the daemon path stays
# a plain production launch when no scene is requested.
stage_scene() {
  local name="$1"
  [ -z "$name" ] && return 0
  local local_joy="$LOCAL_SCENES_DIR/$name.joy"
  [ -f "$local_joy" ] || { echo "[scene] missing $local_joy" >&2; return 1; }
  [ -x "$JOY_SCRIPT_BIN" ] || {
    echo "[scene] missing joy_script binary: $JOY_SCRIPT_BIN" >&2
    echo "[scene] build it in the sibling gmloader-next checkout first (tools/joy_script.c + tools/joy_script_parse.c, arm-linux-gnueabihf-gcc), or set JOY_SCRIPT_BIN" >&2
    return 1
  }
  scp -o BatchMode=yes "$JOY_SCRIPT_BIN" "$HOST:$REMOTE_JOYSCRIPT" >/dev/null \
    || { echo "[scene] scp joy_script -> $HOST:$REMOTE_JOYSCRIPT failed" >&2; return 1; }
  scp -o BatchMode=yes "$local_joy" "$HOST:$REMOTE_SCENE_JOY" >/dev/null \
    || { echo "[scene] scp $local_joy -> $HOST:$REMOTE_SCENE_JOY failed" >&2; return 1; }
  SSH "chmod +x $REMOTE_JOYSCRIPT"
  # Stale shm from a prior interrupted run (teardown normally removes it, but
  # belt-and-suspenders — see teardown()'s comment) would otherwise let a
  # fresh joy_script inherit a leftover generation/magic on the mmap'd file.
  # Backgrounded via `( ... & )` on the REMOTE shell so this SSH round trip
  # returns immediately instead of blocking for the run's whole duration.
  SSH "cd $GMDIR && rm -f $JOY_SHM_PATH && ( ./joy_script $JOY_SHM_PATH scene.joy >/tmp/joy_script.log 2>&1 & )" \
    || { echo "[scene] failed to start joy_script on $HOST" >&2; return 1; }
  echo "[scene] $name staged, driver started (log: /tmp/joy_script.log on device)"
}

# load_core_and_wait [timeout-secs] — discover the newest RBF under
# /media/fat/_Other on the device, trigger `load_core` on /dev/MiSTer_cmd,
# wait for the core to come up, then start the engine via launch.sh and wait
# for exactly one engine process.
#
# Until 2026-08-05 this was purely the daemon path: write load_core and let
# Master_Daemon's _handler.sh spawn the engine. That name is gone (it was the
# daemon's discovery predicate, and a daemon spawning alongside an entry point
# put two engines on one fabric control block), so nothing watches
# /tmp/CORENAME on our behalf any more and the launch has to be explicit.
#
# This mirrors Scripts/MalditaCastilla.sh rather than calling it, because the
# harness picks the RBF itself (by mtime, see below) and the Scripts entry
# picks its own. Detached with setsid + closed stdio so the SSH call returns
# instead of blocking for the whole run — the same reason stage_scene
# backgrounds joy_script.
load_core_and_wait() {
  local timeout="${1:-30}"
  local rbf
  # -t sorts by mtime (newest first); alphabetical (`ls -1 | tail -1`) breaks
  # silently the moment a build tag doesn't sort chronologically, loading a
  # stale RBF while claiming to load the newest one.
  rbf=$(SSH "ls -1t $RBF_GLOB 2>/dev/null | head -1")
  if [ -z "$rbf" ]; then
    echo "[load-core] no RBF matching $RBF_GLOB on $HOST — deploy one first (deploy.py --fetch-rbf)" >&2
    return 1
  fi
  echo "[load-core] $rbf"
  SSH "echo 'load_core $rbf' > /dev/MiSTer_cmd"

  # The core load app_restart()s MiSTer, so this waits out a process
  # replacement, not just a bitstream write.
  local core_waited=0
  while [ "$core_waited" -lt "$timeout" ]; do
    [ "$(SSH "cat /tmp/CORENAME 2>/dev/null" || true)" = "$CORENAME" ] && break
    sleep 1
    core_waited=$((core_waited + 1))
  done
  if [ "$core_waited" -ge "$timeout" ]; then
    echo "[load-core] ABORT: core '$CORENAME' did not come up within ${timeout}s" >&2
    return 1
  fi
  echo "[load-core] core up after ${core_waited}s; starting the engine via $LAUNCHER"
  SSH "test -x '$LAUNCHER'" || {
    echo "[load-core] ABORT: $LAUNCHER missing on $HOST — redeploy (./deploy.py)" >&2
    return 1
  }
  SSH "( setsid '$LAUNCHER' </dev/null >/dev/null 2>&1 & )" \
    || { echo "[load-core] ABORT: could not start $LAUNCHER on $HOST" >&2; return 1; }

  echo "[load-core] waiting up to ${timeout}s for the engine to come up..."
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if devpid_assert_one SSH >/dev/null 2>&1; then
      echo "[load-core] engine up after ${waited}s"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "[load-core] ABORT: engine did not come up under the handler within ${timeout}s" >&2
  return 1
}

# log_has_wedge <file> — true iff FILE contains the fabric wedge signature.
# Pure/local (no SSH), so it can be exercised directly against a synthetic
# log without a device — see the sourcing self-test invoked from this
# script's dispatch guard below. check_wedge() runs the SAME $WEDGE_PATTERN
# remotely via grep's identical flags, so the two are provably the same
# check, just against a local file vs. the device's live log.
log_has_wedge() {
  grep -qa -- "$WEDGE_PATTERN" "$1" 2>/dev/null
}

# check_wedge — poll the just-launched engine's remote log for the wedge
# signature for up to WEDGE_CHECK_SECS (one cheap SSH round trip per poll,
# same style as ensure_deployed's `test -x`). The wedge is a frame-1
# condition, so a short window after the engine is already confirmed up
# (load_core_and_wait) is enough; polling rather than a single shot covers
# the log needing a moment to flush the first timeout line. Returns 0 (wedge
# found) / 1 (clean after the window).
check_wedge() {
  local waited=0
  while [ "$waited" -lt "$WEDGE_CHECK_SECS" ]; do
    if SSH "grep -qa -- '$WEDGE_PATTERN' $REMOTE_LOG 2>/dev/null"; then
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# launch_with_wedge_guard [ARGS...] — the stage-env -> stage-scene ->
# load_core -> wait-for-engine sequence that do_bench/do_launch used to run
# inline, now wrapped with the wedge check and a bounded retry (max
# MAX_WEDGE_ATTEMPTS total attempts, i.e. up to MAX_WEDGE_ATTEMPTS-1 retries).
# Each retry redoes the FULL sequence, not just load_core: teardown()
# deliberately strips bench.env (see its comment — a stale bench.env must
# never survive into a later launch), so bench.env/scene have to be
# re-staged before every load_core call, wedged or not. Sets the global
# _WEDGE_ATTEMPTS_USED to the number of attempts actually taken (1 = clean
# first try) so callers can report it even when the run itself succeeded, so
# a retried run is never mistaken for a clean one downstream. Prints an
# explicit "wedge: retry K/3" line on every retry so the operator sees it in
# the live transcript, not just in a post-hoc summary.
_WEDGE_ATTEMPTS_USED=0
launch_with_wedge_guard() {
  local attempt=1
  while [ "$attempt" -le "$MAX_WEDGE_ATTEMPTS" ]; do
    _WEDGE_ATTEMPTS_USED="$attempt"
    do_stop
    # stage_bench_env's own failure paths never leave new remote state (they
    # return 1 before or without a successful scp), so the do_stop just above
    # already covers it — a second call here would be a genuine no-op, unlike
    # the two below.
    stage_bench_env "$@" || return 1
    # stage_scene/load_core_and_wait CAN fail after stage_bench_env already
    # staged a fresh bench.env (and possibly scp'd joy_script/scene.joy) —
    # do_stop here is what removes that freshly-staged state before giving
    # up, not a repeat of the do_stop above.
    stage_scene "$SCENE" || { do_stop; return 1; }
    load_core_and_wait 30 || { do_stop; return 1; }
    if check_wedge; then
      echo "[wedge] fabric submit-timeout signature seen in $REMOTE_LOG within ${WEDGE_CHECK_SECS}s of launch" >&2
      if [ "$attempt" -lt "$MAX_WEDGE_ATTEMPTS" ]; then
        echo "wedge: retry $attempt/$MAX_WEDGE_ATTEMPTS"
        attempt=$((attempt + 1))
        continue
      fi
      echo "[wedge] ABORT: fabric wedge persisted after $MAX_WEDGE_ATTEMPTS attempts — not measuring" >&2
      do_stop
      return 1
    fi
    [ "$attempt" -gt 1 ] && echo "[wedge] clear on attempt $attempt/$MAX_WEDGE_ATTEMPTS"
    return 0
  done
}

# Aggregate the DRAWTRACE / BLITTER-PROF / fps lines the loader prints to stderr.
# wedge_attempts (optional, default 1) surfaces pre-sampling retries in the
# summary too — a retried run must say so in its own output, not just in the
# scrollback "wedge: retry K/3" lines a later `less` of a saved transcript
# can miss. post_hoc (optional, default 0) flags the belt-and-braces case:
# check_wedge() only covers the WEDGE_CHECK_SECS window right after launch,
# so a wedge that manifests later (mid-sampling) would otherwise reach this
# summary looking clean; do_bench re-greps the pulled log for that before
# calling summarize and passes the result through here so it is impossible
# to miss the line in a saved transcript, not just the live run's stdout.
summarize() {
  local f="$1" wedge_attempts="${2:-1}" post_hoc="${3:-0}"
  echo "----- summary: $(basename "$f") -----"
  if [ "$post_hoc" = 1 ]; then
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  WEDGE DETECTED POST-HOC: '$WEDGE_PATTERN' found in this log AFTER"
    echo "  the pre-sampling check passed. This run's numbers are INVALID."
    echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  fi
  if [ "$wedge_attempts" -gt 1 ] 2>/dev/null; then
    echo "  wedge retries  : $((wedge_attempts - 1)) (this run needed $wedge_attempts/$MAX_WEDGE_ATTEMPTS attempts — see 'wedge: retry' lines above)"
  fi
  head -1 "$f"                                    # self-labeling diag line
  grep -aiE 'BLITTER enabled|DRAWTRACE|DRAW_TRACE|BENCH_ENV' "$f" | tail -3
  echo "  frames-of-prof : $(grep -acE 'PROF|prof|frame' "$f")"
  grep -aiE 'fps|frame .*ms|draws=|verts=|raster=|present=' "$f" | tail -6
  local errs; errs=$(grep -aciE 'error|segfault|corrupt|abort|assert' "$f")
  echo "  error-ish lines: $errs"
  echo "-------------------------------------"
}

do_bench() {
  local args=("$@")
  trap on_interrupt INT TERM
  ensure_deployed
  mkdir -p "$OUTDIR"
  local label ts local_log
  # Build a filename label from the diag args (e.g. --preset sw -> sw).
  label=$(printf '%s' "${args[*]}" | tr ' /' '__' | tr -cd 'A-Za-z0-9_.-')
  [ -n "$label" ] || label="default"
  # [Phase 4 Stage B Task 1] The scene is consumed by the arg parser and never
  # reached ${args[*]}, so two different scenes under the same --preset produced
  # identically-named logs. That is why the Stage A corpus could not be read.
  label="${label}$(sp_label_suffix "$SCENE")"
  ts=$(date '+%Y%m%d-%H%M%S')
  local_log="$OUTDIR/${ts}-${label}.log"

  echo "[bench] host=$HOST secs=$SECS scene=${SCENE:-(none)} args=[${args[*]}]"
  launch_with_wedge_guard "${args[@]+"${args[@]}"}" || exit 1
  # Retry evidence has to reach the PERSISTED artifact, not just stdout — an
  # operator auditing bench-results/*.log later has no transcript to check.
  # Rename now that _WEDGE_ATTEMPTS_USED is known (it isn't yet when
  # local_log was first built above).
  if [ "$_WEDGE_ATTEMPTS_USED" -gt 1 ]; then
    local_log="$OUTDIR/${ts}-${label}-wedgeretry$((_WEDGE_ATTEMPTS_USED - 1)).log"
  fi

  echo "[bench] running; sampling ${SECS}s (1 sample/s), asserting sole engine each sample ..."
  local i
  for ((i = 1; i <= SECS; i++)); do
    if ! assert_sole_engine "sample $i/$SECS"; then
      echo "[bench] ABORT: sole-engine assertion failed — tearing down" >&2
      do_stop
      exit 1
    fi
    sleep 1
  done

  # Pull the log BEFORE teardown. Ordering kept deliberately after the
  # 2026-08-05 daemon removal: a respawn used to rotate maldita.log ->
  # maldita.prev.log within seconds of the kill and race this scp (two runs on
  # 2026-07-29 lost their log that way). Nothing respawns now, but a device
  # with a stale _handler.sh still does, and the safe order costs nothing.
  scp -o BatchMode=yes "$HOST:$REMOTE_LOG" "$local_log" >/dev/null 2>&1 || {
    echo "[bench] no remote log at $REMOTE_LOG" >&2; do_stop; exit 1; }
  # Belt-and-braces on top of launch_with_wedge_guard's pre-sampling
  # check_wedge(): that check only covers the WEDGE_CHECK_SECS window right
  # after launch, so a wedge that manifests later (mid-sampling, after the
  # window closed) would otherwise sail through assert_sole_engine (the
  # process is still alive and singular, it's just not producing frames) and
  # land in summarize() looking like a clean run — summarize's own greps
  # don't match "submit timeout". Re-grep the just-pulled log now, while we
  # still have the whole run's log in hand, and make sure the result reaches
  # both the persisted log file and the process exit status, not just stdout.
  local post_hoc_wedge=0
  if log_has_wedge "$local_log"; then
    post_hoc_wedge=1
    echo "[wedge] WEDGE DETECTED POST-HOC: '$WEDGE_PATTERN' found in $local_log" >&2
  fi
  # Same pre-teardown rule as the log: the trace lives in the engine's own /tmp
  # and the respawned engine reopens it with mode "w" (truncate), so pulling it
  # after do_stop races the daemon respawn and can land an empty file.
  if [ -n "$CAPTURE" ]; then
    local local_trace="$OUTDIR/${ts}-${label}-mftrace-${CAP_START}_${CAP_FRAMES}.txt"
    if scp -o BatchMode=yes "$HOST:$REMOTE_TRACE" "$local_trace" >/dev/null 2>&1; then
      echo "[capture] trace -> $local_trace"
      # Distinct f= values, not group count: a window that opened but covered
      # fewer frames than requested (engine killed mid-window) is the failure
      # this line has to make visible.
      echo "[capture] frames=$(awk '/^MFTRACE G/{split($3,a,"="); f[a[2]]=1} END{print length(f)}' "$local_trace")" \
           "requested=$CAP_FRAMES groups=$(grep -ac '^MFTRACE G' "$local_trace")" \
           "verts=$(grep -ac '^MFTRACE V' "$local_trace")" \
           "f-range=$(awk '/^MFTRACE G/{split($3,a,"="); if(n++==0)lo=a[2]; hi=a[2]} END{print lo"-"hi}' "$local_trace")"
    else
      echo "[capture] WARNING: mftrace scp failed — no $REMOTE_TRACE on $HOST (window never opened?)" >&2
    fi
  fi
  do_stop
  # Teardown is not a durable idle state: bounce to the menu core so the
  # daemon stops respawning the engine, then sweep any respawn that won the
  # race with the bounce.
  SSH "echo 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd" || true
  sleep 3
  devpid_kill SSH || true
  # Persist the wedge/retry evidence INTO the log artifact itself (not just
  # stdout and the filename): an operator auditing bench-results/*.log after
  # the fact has no transcript, only this file.
  if [ "$_WEDGE_ATTEMPTS_USED" -gt 1 ] || [ "$post_hoc_wedge" = 1 ]; then
    {
      echo "----- mister_run.sh wedge gate -----"
      if [ "$_WEDGE_ATTEMPTS_USED" -gt 1 ]; then
        echo "wedge: retried $((_WEDGE_ATTEMPTS_USED - 1)) time(s) before launch succeeded ($_WEDGE_ATTEMPTS_USED/$MAX_WEDGE_ATTEMPTS attempts)"
      fi
      if [ "$post_hoc_wedge" = 1 ]; then
        echo "WEDGE DETECTED POST-HOC: '$WEDGE_PATTERN' found in this log after the pre-sampling check passed — this run's numbers are INVALID"
      fi
      echo "-------------------------------------"
    } >> "$local_log"
  fi
  # [Phase 4 Stage B Task 1] Provenance INTO the artifact, next to the wedge
  # gate block, for the same reason: an operator auditing this file later has
  # no transcript.
  sp_block "$SCENE" \
           "${SCENE:+$HERE/scenes/$SCENE.joy}" \
           "$(sp_digest "${SCENE:+$HERE/scenes/$SCENE.joy}")" \
           "$HOST" "$SECS" "${args[@]+"${args[@]}"}" >> "$local_log"
  echo "[bench] log -> $local_log"
  summarize "$local_log" "$_WEDGE_ATTEMPTS_USED" "$post_hoc_wedge"
  if [ "$post_hoc_wedge" = 1 ]; then
    echo "[bench] ABORT: wedge detected post-hoc — this run's numbers are INVALID, exiting non-zero" >&2
    exit 1
  fi
}

do_launch() {
  local args=("$@")
  trap on_interrupt INT TERM
  ensure_deployed
  launch_with_wedge_guard "${args[@]+"${args[@]}"}" || exit 1
  [ "$_WEDGE_ATTEMPTS_USED" -gt 1 ] && echo "[launch] up after $_WEDGE_ATTEMPTS_USED/$MAX_WEDGE_ATTEMPTS attempts (wedge retried — see 'wedge: retry' lines above)"

  echo "[launch] streaming $REMOTE_LOG — Ctrl-C to stop"
  ssh -t "$HOST" "tail -n +1 -f $REMOTE_LOG"
  do_stop
}

do_pull() {
  mkdir -p "$OUTDIR"
  local dst="${1:-$OUTDIR/$(date '+%Y%m%d-%H%M%S')-pull.log}"
  scp -o BatchMode=yes "$HOST:$REMOTE_LOG" "$dst" >/dev/null && echo "[pull] $dst"
}

do_ping() {
  SSH 'echo "ssh OK  host=$(hostname)"; echo "core : $(cat /tmp/CORENAME 2>/dev/null)"'
  local n
  n=$(devpid_count SSH)
  if [ "$n" != "0" ]; then
    echo "gmloader: RUNNING (pid(s) $(devpid_list SSH | tr '\n' ' ')) count=$n"
  else
    echo "gmloader: not running"
  fi
}

# ---- dispatch ---------------------------------------------------------------
# Guarded so this file can be `source`d (e.g. from a test harness that wants
# log_has_wedge()/check_wedge() without a device) without also running the
# CLI dispatch below against the sourcing shell's own argv.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  [ $# -ge 1 ] || { usage; exit 1; }
  cmd="$1"; shift
  # Pull a leading --secs N off bench args.
  if [ "$cmd" = "bench" ]; then
    rest=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --secs) SECS="$2"; shift 2 ;;
        *) rest+=("$1"); shift ;;
      esac
    done
    set -- "${rest[@]+"${rest[@]}"}"
  fi
  # Pull a leading --scene NAME off bench/launch args (both support it; ARGS
  # passed on to gmloader_diag.sh's --dry-run would otherwise choke on a flag
  # it doesn't know).
  if [ "$cmd" = "bench" ] || [ "$cmd" = "launch" ]; then
    rest=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --scene) SCENE="$2"; shift 2 ;;
        --capture) CAPTURE="$2"; shift 2 ;;   # START:FRAMES, e.g. 3200:8
        --env)
          case "$2" in
            *=*) EXTRA_ENV+=("$2") ;;
            *) echo "--env takes KEY=VAL (got '$2')" >&2; exit 2 ;;
          esac
          shift 2 ;;
        *) rest+=("$1"); shift ;;
      esac
    done
    set -- "${rest[@]+"${rest[@]}"}"
  fi
  # Validate --capture here, not at use: the engine's atol() turns a malformed
  # value into 0 silently, which would capture frames 0..7 (engine boot) while the
  # run report claimed the requested window.
  if [ -n "$CAPTURE" ]; then
    case "$CAPTURE" in
      *[!0-9:]*|*:*:*|:*|*:) CAPTURE="" ;;
      *:*) CAP_START="${CAPTURE%%:*}"; CAP_FRAMES="${CAPTURE##*:}" ;;
      *)   CAPTURE="" ;;
    esac
    if [ -z "$CAP_START" ] || [ -z "$CAP_FRAMES" ] || [ "$CAP_FRAMES" -lt 1 ] 2>/dev/null; then
      echo "--capture takes START:FRAMES with FRAMES >= 1 (e.g. --capture 3200:8)" >&2
      exit 2
    fi
  fi

  case "$cmd" in
    deploy)   do_deploy ;;
    bench)    do_bench "$@" ;;
    launch)   do_launch "$@" ;;
    stop)     do_stop ;;
    pull-log) do_pull "$@" ;;
    ping)     do_ping ;;
    -h|--help|help) usage ;;
    *) echo "unknown command: $cmd" >&2; usage; exit 2 ;;
  esac
fi

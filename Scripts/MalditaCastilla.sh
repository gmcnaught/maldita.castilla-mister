#!/bin/bash
#
# Maldita Castilla — daemon-free launcher. Installs to /media/fat/Scripts/ and
# appears in MiSTer's OSD under Scripts.
#
# WHY THIS EXISTS: the Master_Daemon (Frontier) path works, but it makes a
# third-party resident watcher part of our boot contract, and it has cost us
# real bugs — two daemon instances each spawning a handler put TWO gmloader
# processes on one fabric control block (the documented dual-engine
# corruption), and deploy.py carries a page of code to kill strays and restart
# the daemon so it re-enumerates handlers. This entry point needs none of it:
# nothing is resident, nothing polls /tmp/CORENAME on our behalf, and the whole
# lifecycle is ours from the moment the user selects it.
#
# It is also the entry point the HPS takeover wants. Once MiSTer is killed
# there is no OSD to pick a core from, so "launch an application" is a more
# honest model than "pick a core and have something notice".
#
# HOW IT WORKS, and why each step is safe (all verified against Main_MiSTer
# @3380931, the commit vendor/Main_MiSTer.UPSTREAM.md pins):
#
#   1. MiSTer runs Scripts entries WITHOUT blocking its main loop. With
#      fb_terminal=1 (the default, cfg.cpp:596) it forks agetty on tty2 and
#      polls waitpid(WNOHANG) from MENU_SCRIPTS_FB2; with fb_terminal=0 it
#      popen()s us and reads the pipe O_NONBLOCK from MENU_SCRIPTS1
#      (menu.cpp:7206-7209). Either way `input_poll()` keeps running.
#
#   2. ...which means /dev/MiSTer_cmd is still being serviced while we run
#      (input.cpp:6227-6242, the pool[NUMDEV+1] arm). So we can ask MiSTer to
#      load our core and it will actually do it. That is the whole trick.
#
#   3. MiSTer — not the daemon — is what writes /tmp/CORENAME
#      (user_io.cpp:1171). The daemon only WATCHES that file, so polling it
#      ourselves loses nothing.
#
#   4. fpga_load_rbf() ends in app_restart() (fpga_io.cpp:506), which
#      double-forks, execs a fresh MiSTer and _exit(0)s the old one. So the
#      process that launched us DIES during step 2 and we get orphaned onto
#      init. That is fine — but it is why stdout is redirected to a log below
#      BEFORE the load: under fb_terminal=0 our stdout is MiSTer's popen pipe,
#      and writing to it after MiSTer exits is SIGPIPE.
#
#   5. Then we exec the ordinary handler, which owns everything from there:
#      the singleton guard, the BLITTER/RASTER/LD_LIBRARY_PATH contract, and
#      the takeover. Deliberately NOT reimplemented here — every one of those
#      settings has a device-hit failure behind it, and one copy is enough.
#
# CAVEAT — without the daemon nobody kills the engine on a core change. That
# does not arise on the takeover path (MiSTer is dead; there is no OSD to
# change cores from), but with takeover disarmed the engine would keep running
# and fight whatever core the user loads next. This launcher is meant for the
# takeover flow; use the daemon path if you want core-change teardown.

CORENAME="Maldita Castilla"
HANDLER="/media/fat/games/$CORENAME/_handler.sh"
RBF_GLOB="/media/fat/_Other/MalditaCastilla_*.rbf"
LOGDIR="/media/fat/logs/MalditaCastilla"
CORE_WAIT_S=30

mkdir -p "$LOGDIR"

# These two lines are the only thing the OSD/console shows; everything after
# the redirect goes to the log. See note 4 above — this MUST happen before the
# load_core write, not after.
echo "Maldita Castilla: loading core and starting the engine..."
echo "log: $LOGDIR/launch.log"

exec >> "$LOGDIR/launch.log" 2>&1
echo "=== $(date) launcher start (pid $$, ppid $PPID) ==="

die() { echo "launcher: $*"; exit 1; }

[ -x "$HANDLER" ] || die "handler not found or not executable: $HANDLER"

current_core() { cat /tmp/CORENAME 2>/dev/null; }

if [ "$(current_core)" = "$CORENAME" ]; then
    # Already on our core — the user loaded it from the Cores menu and then ran
    # this. Nothing to load; fall straight through to the handler.
    echo "launcher: core already loaded, skipping load_core"
else
    # shellcheck disable=SC2086
    RBF="$(ls -t $RBF_GLOB 2>/dev/null | head -1)"
    [ -n "$RBF" ] || die "no RBF matching $RBF_GLOB"

    # MiSTer opens the FIFO O_RDWR (input.cpp:5143), so it always has a reader
    # and this write cannot block — but only while MiSTer is alive. With MiSTer
    # dead the node still exists with no reader and open(O_WRONLY) blocks
    # FOREVER, which would hang this script with no way out but a power cycle.
    # Hence the liveness check rather than a bare echo.
    [ -p /dev/MiSTer_cmd ] || die "/dev/MiSTer_cmd missing — is MiSTer running?"
    pidof MiSTer >/dev/null 2>&1 || die "no MiSTer process to service /dev/MiSTer_cmd"

    echo "launcher: load_core $RBF"
    echo "load_core $RBF" > /dev/MiSTer_cmd

    # MiSTer app_restart()s through the load, so this waits out a whole process
    # replacement, not just a bitstream write.
    waited=0
    while [ "$(current_core)" != "$CORENAME" ]; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge "$CORE_WAIT_S" ]; then
            die "core did not come up within ${CORE_WAIT_S}s (CORENAME='$(current_core)')"
        fi
    done
    echo "launcher: core up after ${waited}s"
fi

# The handler does the rest, exactly as it does on the daemon path — including
# reading takeover.env and arming the HPS takeover if it is present.
echo "launcher: exec $HANDLER"
exec "$HANDLER"

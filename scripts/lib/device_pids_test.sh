#!/bin/bash
# Host-side test for device_pids.sh. Substitutes a fake remote shell that
# replays captured busybox `ps` output, so the parsing logic is exercised
# without a MiSTer in the loop.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/device_pids.sh"

fails=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1: expected '$2' got '$3'"; fails=$((fails+1)); fi
}

# Captured busybox 1.33 `ps` output. Note the grep line itself must NOT match,
# and the harness's own script name must NOT match — only './gmloader' does.
FAKE_PS='  PID USER       VSZ STAT COMMAND
    1 root      2384 S    init
  871 root     11276 S    ./gmloader -c gmloader.json
  902 root      1200 S    grep gmloader
  915 root      1200 S    /bin/sh /tmp/bench_gmloader_wrapper.sh'

FAKE_PS_TWO='  PID USER       VSZ STAT COMMAND
  871 root     11276 S    ./gmloader -c gmloader.json
  988 root     11276 S    ./gmloader -c gmloader.json'

FAKE_PS_NONE='  PID USER       VSZ STAT COMMAND
    1 root      2384 S    init'

FAKE_OUT=""
fake_ssh() { echo "$FAKE_OUT" | eval "$(printf '%s' "$1" | sed "s|^ps|cat|")"; }

# devpid_count's contract is INTEGER on stdout (never empty, never a PID
# list). The expected value here is "0", not "" — a broken or missing
# devpid_count returns "" (or errors), which must FAIL this check. A test
# that compares "" to "" passes vacuously against an undefined function,
# which is exactly the defect class this file exists to catch (see MINOR 6
# in the Task 1 review).
FAKE_OUT="$FAKE_PS"
check "single engine -> count 1"     "1"   "$(devpid_count fake_ssh)"
FAKE_OUT="$FAKE_PS_TWO"
check "two engines -> count 2"       "2"   "$(devpid_count fake_ssh)"
FAKE_OUT="$FAKE_PS_NONE"
check "no engine -> count 0"         "0"   "$(devpid_count fake_ssh)"

# devpid_list is the separate list-returning helper.
FAKE_OUT="$FAKE_PS"
check "single engine -> one pid"     "871" "$(devpid_list fake_ssh)"
FAKE_OUT="$FAKE_PS_TWO"
check "two engines -> two pids"      "2"   "$(devpid_list fake_ssh | wc -l | tr -d ' ')"
FAKE_OUT="$FAKE_PS_NONE"
check "no engine -> empty pid list"  ""    "$(devpid_list fake_ssh)"

exit $((fails > 0))

# device_pids.sh — busybox-safe engine process discipline for MiSTer targets.
#
# WHY THIS FILE EXISTS: MiSTer busybox 1.33 has NO pkill and NO pgrep. Calls to
# them fail SILENTLY, so every "I killed the old instance" guard written with
# them passes vacuously. That produced the false "native audio wedges the
# fabric" conclusion (two engines writing one control block, 2026-07-27) and
# contaminated the fabric-park diagnosis before it.
#
# Two further traps encoded here:
#   - A pattern of plain 'gmloader' matches the *grep itself* and any harness
#     script whose argv contains the name. Only the engine invocation has the
#     './' prefix, so match "[.]/gmloader": the bracket keeps grep from
#     matching its own command line.
#   - awk '{print $1}' cannot be nested inside the single-quoted remote command
#     without escaping that differs between bash and busybox sh. sed does the
#     same field extraction with only double quotes.

# Remote snippet: prints one engine PID per line, nothing else.
DEVPID_CMD='ps | grep "[.]/gmloader" | sed -e "s/^ *//" -e "s/ .*//"'

# devpid_list <ssh-fn> -> prints the PIDs, one per line; empty if none.
# This is the list-returning helper; devpid_count (below) is the
# integer-returning one. Keep the two distinct — a caller expecting an
# integer that silently gets a PID list is exactly the class of bug this
# file exists to prevent.
devpid_list() {
  "$1" "$DEVPID_CMD"
}

# devpid_count <ssh-fn> -> prints the integer engine count on stdout (0 if
# none, never empty). Contract: INTEGER on stdout — callers (Tasks 3, 5, 6, 8)
# rely on this being directly comparable/arithmetic-safe.
devpid_count() {
  local n
  n=$("$1" "$DEVPID_CMD | wc -l" | tr -d ' ')
  # `wc -l` on empty input yields 0 on busybox; guard both spellings.
  [ -z "$n" ] && n=0
  echo "$n"
}

# devpid_kill <ssh-fn> -> SIGKILL every engine PID. Never kills the caller.
devpid_kill() {
  "$1" "for p in \$($DEVPID_CMD); do kill -9 \$p 2>/dev/null; done; true"
}

# devpid_assert_one <ssh-fn> -> exit 0 iff exactly one engine is running.
# Prints the observed count so callers can log it per sample.
devpid_assert_one() {
  local n
  n=$(devpid_count "$1")
  echo "$n"
  [ "$n" = "1" ]
}

# scene_provenance.sh — pure helpers that make a bench artifact self-describing.
#
# The Phase 4 Stage A corpus could not be interpreted because the results
# filename is built from the diag ARGS only (do_bench's `label`), and --scene is
# consumed by the argument parser before that point. Two runs of different scenes
# with the same --preset therefore produced identically-named logs with no scene
# field inside them, and the findings could not tell which workload was which.
#
# Everything here is a pure function over its arguments: no SSH, no globals from
# mister_run.sh, no side effects. That is what makes it host-testable.

# sp_digest <file> — hex digest of <file>, or the literal string "unavailable".
# Portable across macOS (md5) and Linux (md5sum); provenance is evidence, not a
# gate, so a host with neither tool degrades rather than aborting the run.
sp_digest() {
  local f="$1"
  [ -f "$f" ] || { printf 'unavailable'; return 0; }
  if command -v md5 >/dev/null 2>&1; then
    md5 -q "$f" | tr -d '\n'
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum "$f" | awk '{printf "%s", $1}'
  else
    printf 'unavailable'
  fi
}

# sp_label_suffix <scene> — filename fragment identifying the scene, or empty.
# Kept separate from sp_block so the SAME scene identity reaches both the
# filename and the file contents; the Stage A corpus had it in neither.
sp_label_suffix() {
  local scene="$1"
  [ -n "$scene" ] || { printf ''; return 0; }
  printf -- '--scene_%s' "$scene"
}

# sp_block <scene> <joy_path> <joy_digest> <host> <secs> [args...]
# The provenance block appended to the pulled log. An operator reading
# bench-results/*.log months later has no transcript -- only this.
sp_block() {
  local scene="$1" joy="$2" digest="$3" host="$4" secs="$5"
  shift 5
  echo "----- mister_run.sh scene provenance -----"
  echo "scene: ${scene:-(none)}"
  echo "scene_joy: ${joy:-(none)}"
  echo "scene_joy_digest: ${digest:-(none)}"
  echo "host: $host"
  echo "secs: $secs"
  echo "args: $*"
  echo "------------------------------------------"
}

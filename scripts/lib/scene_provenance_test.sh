#!/bin/bash
# Host-side test for scene_provenance.sh. Pure string/digest helpers, so this
# needs no MiSTer and no network.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scene_provenance.sh"

fails=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1: expected '$2' got '$3'"; fails=$((fails+1)); fi
}
contains() { # contains <desc> <needle> <haystack>
  case "$3" in *"$2"*) echo "ok   - $1" ;;
  *) echo "FAIL - $1: '$2' not found in output"; fails=$((fails+1)) ;; esac
}

# A run with no scene must still produce a label that is a valid filename
# fragment, and must say "none" rather than leaving the field blank -- a blank
# field is what made the Stage A logs unattributable.
check "no scene -> empty label suffix" "" "$(sp_label_suffix "")"
check "scene -> label suffix"          "--scene_ingame-stage1" "$(sp_label_suffix ingame-stage1)"

# The digest must be stable for identical content and differ for different
# content, whichever tool the host actually has.
tmpa="$(mktemp)"; tmpb="$(mktemp)"; tmpc="$(mktemp)"
printf 'alpha\n' > "$tmpa"; printf 'alpha\n' > "$tmpb"; printf 'beta\n' > "$tmpc"
da="$(sp_digest "$tmpa")"; db="$(sp_digest "$tmpb")"; dc="$(sp_digest "$tmpc")"
check "digest is stable for identical content" "$da" "$db"
if [ "$da" = "$dc" ]; then
  echo "FAIL - digest differs for different content"; fails=$((fails+1))
else
  echo "ok   - digest differs for different content"
fi
rm -f "$tmpa" "$tmpb" "$tmpc"

# A missing file must not abort the run; provenance is evidence, not a gate.
check "missing file -> unavailable" "unavailable" "$(sp_digest /nonexistent/scene.joy)"

# The block is the artifact an operator reads months later, so every field the
# Stage A corpus lacked has to be present by name.
blk="$(sp_block ingame-stage1-busy scripts/scenes/ingame-stage1-busy.joy abc123 192.168.20.62 30 --preset fabric)"
contains "block names the scene"  "scene: ingame-stage1-busy"   "$blk"
contains "block names the joy"    "scene_joy: scripts/scenes/ingame-stage1-busy.joy" "$blk"
contains "block names the digest" "scene_joy_digest: abc123"    "$blk"
contains "block names the host"   "host: 192.168.20.62"         "$blk"
contains "block names the secs"   "secs: 30"                    "$blk"
contains "block names the args"   "args: --preset fabric"       "$blk"

blk_none="$(sp_block "" "" "" 192.168.20.62 30 --preset fabric)"
contains "no-scene block says none" "scene: (none)" "$blk_none"

if [ "$fails" -ne 0 ]; then echo "$fails failure(s)"; exit 1; fi
echo "all scene_provenance tests passed"

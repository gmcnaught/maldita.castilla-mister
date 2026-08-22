# Input tapes

Step-indexed recordings of a play route, replayed inside the engine by
`gmloader/mister/joy_tape.cpp` (contract: `joy_tape.h`). One `NAME.tape` per
route; `scripts/mister_run.sh --replay NAME` scp's the file here to the
device's `games/gmloader/tapes/` and points `GMLOADER_JOYPLAY` at it.

## Why these and not `scripts/scenes/*.joy`

The `.joy` scenes are indexed by **wall-clock milliseconds** and driven by a
separate process (`joy_script`) through `/dev/shm`. The ms→step mapping moves
with the engine's frame rate, so they work for "mash Sword until the title
screen goes away" and fall apart over a route that takes minutes.

A tape is indexed by **input step**. `update_inputs()` runs exactly once per
`RunnerJNILib::Process()`, so one step is one game step, and the same tape
lands on the same game steps at 26 fps and at 60 fps. That is the property an
RTL A/B needs, because the build under test is precisely what changes frame
timing.

## Recording a route

```sh
scripts/mister_run.sh launch --record stage3-boss --env GMLOADER_GODMODE=1
# ...play the route with a pad, then Ctrl-C...
scp root@192.168.20.81:'/media/fat/games/gmloader/tapes/stage3-boss.tape' \
    scripts/tapes/stage3-boss.tape
```

**Godmode must match between record and replay.** It suppresses `obj_player`
collision, so a route cut with it survives hits that the same route replayed
without it does not — the run diverges at the first contact and every later
step is meaningless. The tape stamps `#godmode N` in its header and the engine
prints a loud `GODMODE MISMATCH` line when a replay disagrees; heed it, because
a diverged replay still renders a perfectly plausible-looking game.

## Format

```
#tape 1
#godmode 1
#step p0 p1 frame
0 0x000 0x000 0
137 0x010 0x000 94
...
#end steps=18422 lines=2913
```

`step` is the input-step index (0 = first step after engine setup). `p0`/`p1`
are the `mister_joy_shm.h` button masks, written only when they **change** —
replay holds the last value between entries. `frame` is the mfgpu backend's
`g_frame_no` at that step, recorded so a `--capture START:FRAMES` window can be
aimed at the frame a bug is on without guessing.

`frame` is **not** the step index: `g_frame_no` only advances on frames that
actually draw, so the two counters diverge across the ~15 s load phase. Take a
`--capture START` from the **replay's** own log rather than the recording's
when they disagree — the replay prints `max frame drift` at exit for exactly
this reason.

A tape truncated by a `kill -9` (no `#end` trailer) still replays every entry
it has; lines are flushed as they are written precisely so a ten-minute route
survives the engine being killed rather than exited.

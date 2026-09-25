# Scenario checkpoints: repeatable profiling at a named point in the game

Date: 2026-09-25. Status: design, not implemented.
Motivating case: frame-rate slowdown at the beginning of stage 2.

## Problem

Every profiling run today starts at boot and reaches gameplay by input:
`--scene ingame-stage1` (wall-clock `.joy`, drifts with fps), `scripts/fpsdip`
(`joy_play` seeded random route, `WARM_S` seconds of warm-up), or the
step-indexed tape (`--record/--replay`, uncommitted on `mem-wc-6.18` +
sibling `gmloader-next`). All three can only reach stage 1. Reaching stage 2
by input means a multi-minute route through all of stage 1, where any
divergence (a missed jump, a different enemy spawn) makes every later step
meaningless, and the measurement window is placed in seconds, not in game
state.

A profiling point needs three things to be repeatable:

1. **Same place** — the same room, entered through the game's own transition.
2. **Same game state** — same globals, same RNG stream, same inputs per step.
3. **Same window** — measured over the same game steps, not the same seconds.

## Observed facts this design relies on

From the device's `saves/game.droid` (bytecode v14, GMS 1.x, 71 rooms) and
`mygame.apk`'s `libyoyo.so`:

- **Room indices** (device build — the local `games/cursed_castilla.droid` is a
  *different*, later build with different room names; do not use it):
  `title_screen=3`, `map_1=5`, `level_1_1..1_5=6..10`, **`map_2=11`,
  `level_2_1=12`, `level_2_2=13`, `level_2_3=14`, `level_2_4=15`**, `map_3=18`, …
  `level_6_7=55`. Full table is regenerated from the ROOM chunk (see Tooling).
- **No progress save file.** `saves/` holds only `config.ini`, `hiscore.ini`,
  `options.ini`. Progress is session globals (`continue_from_room`,
  `next_room`, `lives`, `health`, `weapon`, `subweapon`, `score`, …), all
  initialised in `gml_Script_scr_initial_values`. A save-file checkpoint is
  therefore not available.
- **The game never seeds its RNG.** Its FUNC table references `random` but not
  `randomize` / `random_set_seed`. The runner exports `F_RandomSetSeed`,
  `F_RandomGetSeed`, `InitRandom(int)`.
- **Room warp primitives are exported:** `New_Room`, `Current_Room`
  (already resolved in `gmloader/libyoyo.cpp`, used by `game_end_reimpl`),
  `F_RoomGoto`, `F_RoomGotoNext`, `Variable_Global_GetVar/SetVar`.
- **The game ships a developer skip.** `obj_control` Step_0, decoded from
  bytecode: `if (global.testing_mode == 1) { if keyboard_check_pressed(8)
  game_restart(); if keyboard_check_pressed(ord('J')) && room_next(room) != -1
  { global.extra_live_activated = 1; global.blood_gem_activated = 1;
  room_goto_next(); } if keyboard_check_pressed(ord('L')) … lives … }`.
  `testing_mode` is set to 0 by the first instruction of `scr_initial_values`.
- Engine hooks already exist for this kind of work: `Code_Execute` hook
  (`bench_godmode.cpp`), `update_inputs()` once per `RunnerJNILib::Process()`
  (the step clock the tape uses), `_IO_KeyPressed[]` writes (`input.cpp`).

## Design

A **scenario** = warp target + state pins + input tape + measurement window,
all counted in game steps from the warp. One text file per scenario, one engine
module to execute it, one harness entry point.

### 1. Scenario file — `scripts/scenarios/NAME.scn`

```
# stage2-start: first screens of stage 2, standing still then walking right
game_sha1  <sha1 of saves/game.droid>   # refuse to run against another build
warp       map_2          # room name; resolved to an index by the harness
warp_after title_screen   # warp on the first step AFTER this room is left
seed       1              # random_set_seed at the warp step
godmode    1
tape       stage2-start   # optional; step 0 = the warp step
settle     120            # steps after warp before measuring
measure    1800           # steps measured (~30 s at 60 fps)
```

`warp map_2` rather than `level_2_1`: the stage-2 map screen then runs the
game's own `obj_fade_in` → `level_2_1` transition, so the level is entered
exactly as in play. `warp level_2_1` stays available when the map screen's
setup turns out to depend on state the warp skips (spike item S2).

### 2. Engine: `gmloader/mister/scenario.cpp` (gmloader-next), env-gated

Env (staged by the harness in `bench.env`, same path as godmode/tape):
`GMLOADER_SCN_WARP=<room index>`, `GMLOADER_SCN_AFTER=<room index>`,
`GMLOADER_SCN_SEED=<n>`, `GMLOADER_SCN_SETTLE=<steps>`,
`GMLOADER_SCN_MEASURE=<steps>`, `GMLOADER_SCN_DIGEST=<every N steps>`.
Unset = no hook, same contract as `bench_godmode` ("off path: bit-identical").

Called from `update_inputs()` (one call per game step), it runs a small state
machine keyed on `*Current_Room` and a local step counter:

| state | exit condition | action on exit |
|---|---|---|
| `WAIT` | `*Current_Room` leaves `SCN_AFTER` (player pressed Start; `scr_initial_values` has run) | write `*New_Room = SCN_WARP`; call `F_RandomSetSeed(SCN_SEED)`; zero the tape's step counter; log `SCN warp room=… step=…` |
| `SETTLE` | `SCN_SETTLE` steps | touch `/tmp/maldita_scn/begin` (CLOCK_MONOTONIC ns inside) |
| `MEASURE` | `SCN_MEASURE` steps | touch `/tmp/maldita_scn/end`; log per-window summary |
| `DONE` | — | — |

Writing `New_Room` is what `room_goto` does in GMS 1.x — the runner performs
the change at the end of the step, running Room End / Room Start / Create
events normally. Calling the resolved `room_goto` builtin through
`the_functions` is the equivalent fallback if the direct write misbehaves.

Markers go to `/tmp`, not the log: `maldita.log` sits on `/media/fat` (sync
mount, ~1.3 ms per line, and piped through a logger on CPU1).

**State digest** (`SCN_DIGEST`): every N steps after the warp, log one line
`SCN d step=… room=… score=… lives=… health=… px=… py=…` (globals via
`Variable_Global_GetVar`, player via the first `obj_player` instance). This is
the repeatability oracle — see §5.

**Tape coupling:** the tape's step index is re-zeroed at the warp, so a tape
recorded under a scenario is independent of how many title/intro steps
preceded it. `JoyTape_Apply` gets a `JoyTape_Rebase()` call from the warp
action; replay stays off (live transport) until the warp so the title is
driven by the harness's Start press.

### 3. Reaching the warp: the title

`WAIT` needs the game to leave `title_screen` once. Two options, both cheap:
the existing `joy_script` "press Start" `.joy` (wall-clock is fine here —
only the exit matters, not its timing), or the scenario module injecting a
Start press itself on step K of `title_screen`. Pick the in-engine injection:
it removes the separate process, and it makes the steps-before-warp count
irrelevant because the RNG is reseeded and the tape rebased at the warp.

### 4. Harness: `scripts/scenario.sh NAME [--runs N] [--record] [KEY=VAL…]`

Built on `scripts/fpsdip/{capture,run}.sh` (fresh core load via the menu.rbf
round trip, start-crash retry, CPU1 pinning, nothing polling SSH during the
leg). Differences:

- Stages `bench.env` from the `.scn` (room names → indices from
  `scripts/scenarios/rooms.tsv`; refuses if the device's `game.droid` sha1 ≠
  `game_sha1`).
- Replaces `sleep $WARM` with waiting for `/tmp/maldita_scn/begin`, then runs
  `fps_probe` until `/tmp/maldita_scn/end`. The probe window is the measure
  window in game steps; its wall-clock length is itself a result.
- `--runs N` (default 5) repeats the whole cold start N times; the report gives
  per-run and median/min/max for: displayed-fps 1-s windows < 58 (the fps-dip
  target metric), mean displayed fps, engine frame ms and fabric busy per frame
  (existing BLITPROF/`cov_px` counters, filtered to the measure window by the
  `g_frame_no` values logged at begin/end).
- Pulls a screenshot at `begin` and at `end` per run — a visual check that
  every run is in the same place.
- `--record`: runs to the warp, then records a tape from a live pad
  (`GMLOADER_JOYREC`, already implemented) with godmode per the `.scn`.
  Commit the result as `scripts/tapes/NAME.tape`.

Output: `bench-results/scenario/NAME/<timestamp>/{run1..N/, report.txt}`.

### 5. Repeatability gate

A scenario is **trusted** only after:

1. **Digest identity:** the `SCN d` lines of N runs are byte-identical across
   the measure window (same build). Any difference = nondeterminism; the first
   differing step localises it. Runs with differing digests are excluded from
   the report and flagged, never averaged.
2. **Cross-build identity:** digests match between two builds that change only
   timing (e.g. `GMLOADER_FCAP_*` on/off). This is the property an A/B needs:
   a faster build must replay the same game, not a different one.
3. **Metric spread:** run-to-run spread of the headline metric is reported next
   to every A/B delta; a delta smaller than the spread is reported as no change.

Known nondeterminism risks to watch for in (1)/(2): `audio_is_playing` /
`music_is_playing` in game logic (audio drains at wall-clock rate, so a
branch on it depends on fps), `gamepad_is_connected`, and any runner-side
delta-time use. Mitigation if one bites: pin it in the scenario module (e.g.
answer `audio_is_playing` from a step-counted model) — decide per case.

## Rejected alternatives

- **Tape from boot through stage 1.** Minutes of route; one divergence
  invalidates the rest; recording is manual and must be redone when stage 1's
  behaviour changes. Kept only as the source of an *organic* stage-2 state for
  cross-checking the warp (spike S3).
- **The game's `testing_mode` + `J` skip.** No new warp code, but it walks
  every intervening room (load and transitions each time), and sets
  `extra_live_activated` / `blood_gem_activated` as a side effect, so the
  arrival state differs from play. Useful as a zero-risk fallback for spike S1
  (set `global.testing_mode=1` via `Variable_Global_SetVar`, press `J` N times
  through `_IO_KeyPressed[74]`).
- **Savestates** (serialise the whole runner heap). `Variable_Global_Serialise`
  exists but instances, surfaces, audio and the fabric texture residency do
  not snapshot cleanly; far larger than the problem.
- **Wall-clock `.joy` scenes / `WARM_S`.** Timing-dependent by construction —
  the thing under test changes the timing.

## Spike before implementation (device `.81`, ~½ day)

- **S1** Warp works: `GMLOADER_SCN_WARP=12` from title exit lands in
  `level_2_1` with a controllable player (screenshot + a few tape steps).
- **S2** `map_2` entry: warp to 11 proceeds into `level_2_1` by itself; if it
  stalls or goes elsewhere (`next_room` dependency), default scenarios to
  direct level warps.
- **S3** State parity: compare `SCN d` globals at `level_2_1` entry after warp
  vs. after an organic stage-1 clear (godmode tape). Expected differences:
  `score`, possibly `weapon`/`subweapon`. Decide whether the scenario pins them
  (`Variable_Global_SetVar`) — they affect what the HUD and player draw, which
  is part of the frame cost.
- **S4** Determinism: 5 cold runs of an idle `stage2-start` (no tape — player
  stands still), digests identical? This scenario is also the first profiling
  deliverable: if the stage-2 slowdown is scene-driven it reproduces with no
  input at all.

## Tooling

- `scripts/scenarios/gen_rooms.py <game.droid>` → `rooms.tsv` (index, name) and
  the droid's sha1. The parser is ~20 lines over the FORM/ROOM chunks.
- Host unit test for the scenario state machine (same pattern as
  `joy_tape_test.cpp`: fake `Current_Room` / step feed, assert the warp fires
  once, on the right step, and never when env is unset).

## Deliverables in order

1. Spike S1–S4 (throwaway branch).
2. `scenario.cpp` + host test + `JoyTape_Rebase` (gmloader-next PR; depends on
   the uncommitted tape work landing first).
3. `gen_rooms.py`, `rooms.tsv`, `scenario.sh`, `stage2-start.scn` (idle)
   (maldita PR, submodule bump).
4. Record `stage2-start` walking tape; gate it with §5; baseline report of the
   current build.

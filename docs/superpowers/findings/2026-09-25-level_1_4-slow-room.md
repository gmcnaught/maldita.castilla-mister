# Slow room: level_1_4 (room index 9), 2026-09-25

Room reported by the user as the slowdown location: **`level_1_4`**, room index 9
of the device build's `game.droid` (1504x288; winery — `obj_butcher`, `obj_worm`,
`obj_barrel_rolling/bouncing`, `obj_chain_lamp(_platform)`, `obj_winery_movement`).
Reach it with the engine's dev mode (gmcnaught/gmloader-next#44):
`GMLOADER_TESTING_MODE=1 GMLOADER_DEVSKIP_TO=9` in `games/gmloader/bench.env`.

## Capture (.81, live play, no engine profiling env)

`bench-results/perf-level_1_4-20260925/` — `tools/fps_probe` (500 us poll, CPU1),
97.9 s, analysed with `scripts/fpsdip/frames.py`:

- displayed new frames per 1 s window: 49–55 (median ~50–51); **97/97 windows < 58**
- repeated scanout frames 831/5866 (14.2 %)
- engine submits per window: min 48, median 51, max 54; completions = submits in
  every window (fabric keeps up with what is submitted)

Inferred: the engine submits ~50 frames/s here and the fabric completes each one,
so the limit is on the host side of the doorbell (engine frame time), not a fabric
backlog. Unknown: split of host frame time (logic vs raster vs fabric wait) —
needs a run with `--preset fabric` (BLITPROF) in this room.
/proc CPU busy read 100 % on both cores, which is not informative (probe and pacer poll).

## Profiled run (headless, godmode, `--preset fabric`, standing at room entry)

Data: `bench-results/perf-level_1_4-prof-20260925/` (fps_probe window, engine log
window, `--capture 2000:4` draw-stream trace + analysis). Reproduces the slowdown
with no input: 51–52 displayed frames per 1 s window, all < 58.

- MFSUBMIT: fabric frame **19.24 ms** (budget 16.69), tri 18.35 / texwait 3.15 /
  dpath 15.20; cov_px **242.6k** = overdraw 3.90 of 288x216; 6.2 cyc/px; to=0.
- MFSEAM: host 7.3 ms, blocked on fabric 12.3 ms per frame. **Fabric-bound.**
- Frame 2000, 107 groups, covered 243,126 px. Three full-screen layers = 76 %:

| draw | blend | covered px | share |
|---|---|---|---|
| `bck_cellars` 96x336 room background, tiled | COPY | 62,208 | 25.6 % |
| app-surface -> screen copy (512x256, SRC_SURFACE) | COPY | 62,208 | 25.6 % |
| `tileset_town_2` (0,304) 64x32 wall tiles, depth 3000000, 79 in room | COLORKEY | 61,440 | 25.3 % |
| everything else (sprites, other tiles, HUD) | | ~57k | 23.5 % |

- The 64x32 wall tile source rect has **0 transparent texels** (checked in the
  device `game.droid` texture page), so on screen the wall layer is opaque and
  hides ~61k of `bck_cellars`' 62k px. That background draw is almost entirely
  overdrawn: ~4.8 ms/frame at the measured ~79 ns/px.
- User observation: the game speeds up right after the bouncing-barrel screen,
  consistent with the wall-tile layer no longer covering the screen there.

## What to fix (ranked by gain for this room)

1. **Cull draws hidden under opaque geometry (host, exact).** At texture staging,
   record per-quad "all texels opaque"; per frame, drop (or clip) triangles fully
   inside the union of later opaque axis-aligned quads on the same target. Here it
   removes ~61k px (~4.8 ms) -> ~14.4 ms fabric frame, under budget. Output is
   bit-identical, so the refmodel/RTL do not change.
2. **Remove the app-surface -> screen copy** (62k px, ~4.9 ms, every frame in every
   room): render/scan out the surface directly when it is presented 1:1 COPY.
   Larger change (target/scanout plumbing); general headroom.
3. **Per-pixel rate** (6.2 cyc/px, texwait 3.15 ms): RTL work, largest scope.

## Fix 1 landed: occlusion cull (gmcnaught/gmloader-next#43)

`gmloader/mister/mf_occlude.h` (+ `mf_occlude_test.cpp`, glue in `raster_backend_mfgpu.cpp`),
knob `GMLOADER_MFGPU_OCCLUDE` (default 1). Triangles whose every pixel a later opaque
screen-aligned quad on the same target overwrites (COPY, or COLORKEY whose sampled texels
have no key) are collapsed to zero area in the vertex arena before the doorbell.
Host tests: `mf-occlude-test` (vs blt_raster_tri: occluder rect subset/exact, tri bbox
superset, 300 random scenes bit-identical), `raster-backend-test` 70/70 incl. A/B cases.

Same build, level_1_4 entry, 45 s fps_probe windows (`bench-results/perf-level_1_4-occ-{off,on2}`):

| | OCCLUDE=0 | OCCLUDE=1 |
|---|---|---|
| fabric ms/frame | 19.26 | 12.76 |
| covered px/frame | 242,804 | 162,171 |
| displayed 1 s windows | 50–52 (44/44 < 58) | 60 (44/44), 0 repeats |

## Fix 2 landed: present the app surface directly

RTL: branch `perf/present-from-surface` (maldita), RBF run 36189558686 (emu setup WNS
-0.159 ns, 43 % ALMs, 46 % block bits). `fb_dma_src_mux` points the frame-end DMA at the
surface bank when the frame's END carries BLT_F_SRC_SURFACE; C_STATUS bit2 advertises it.
Sim: new `tb_present_surf` (+ mutation check), default tier 57/57.
Refmodel/emitter (gmcnaught/mister-fpga-blitter#5):
`blt_present_buffer()`, `blt_end_frame_flags()`. Host: identity composite deferred,
discharged if anything is emitted after it; knob `GMLOADER_MFGPU_PRESENT_SURF` (default 1,
only with the capability bit). Host test `present-surf` (5 variants, byte-identical).

level_1_4 entry, new RBF, cull on (`bench-results/perf-level_1_4-ps-{off,on2}`):

| | PRESENT_SURF=0 | PRESENT_SURF=1 |
|---|---|---|
| fabric ms/frame | 12.74 | 8.90 |
| frames presented from surface | 0 | 4499/4500 |
| displayed 1 s windows | 60 (44/44) | 60 (43), 59 (1; host-late) |

Cumulative for the room: 19.26 -> 8.90 ms fabric per frame (budget 16.69).
Boot -> intro -> cutscene -> stage 1 screenshots correct (`bench-results/boot-presentsurf2`).

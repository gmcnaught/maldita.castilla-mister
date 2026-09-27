# Slow room: level_2_3 (room index 14), the windmills, 2026-09-26

Windmill objects (`obj_molino` x3, `obj_molino_broken` x2) live only in **level_2_3**
(2128x216; `obj_storm`/`obj_storm_light` rain throughout). The first windmill is at
x=208, in view from the spawn point, so the slow scene is reachable headlessly:
`GMLOADER_TESTING_MODE=1 GMLOADER_DEVSKIP_TO=14 GMLOADER_GODMODE=1` +
`scripts/mister_run.sh bench --scene ingame-stage1` (device `.62`).
A scripted walk right (`scripts/scenes/walk-right.joy`) stalls at the first windmill:
progress needs jumps between platforms, which open-loop joy scripts can't time, so all
numbers below are at the first windmill.

## Baseline (device, `--preset fabric`)

- fabric frame 15.9–17.7 ms (budget 16.69), texwait 5.4–6.6 ms, cov_px ~157k;
  MFSEAM period 17.01 ms mean, 27/60 windows > 17 ms.

## Where the time goes (RTL replay of captured f=3000, real texel cache)

`tb_blitter_trilist_streamcache` over the device capture: 1,735,272 cycles = 17.6 ms
(device agrees). Cost of each draw = full minus a replay without it:

| draw | px | cycles | ms | cyc/px |
|---|---|---|---|---|
| 4 windmill sails (`spr_molino` 96x26, rotated) | 6.2k | 327,680 | 3.33 | **53** (2.9 ms texwait) |
| rain `bck_rain_light` 252x214, COLORKEY, full screen | 60.8k | 496,640 | 5.05 | 8.2 |
| tower tiles (`tileset_mountain`) | ~55k | 448,216 | 4.55 | 8.1 |
| `bck_molinos` background, COPY | 33.4k | 270,720 | 2.75 | 8.1 |

- **Sails:** rotated sampling walks across texture rows. The texel path is a 2 KB
  direct-mapped qword cache (blitter_top) in front of two 256 B SDRAM blocks (P_SRC,
  `RO_BLOCKS=2`), so nearly every pixel misses.
- **Rain:** 348 of its 53,928 texels are not the key (0.65%), but the fabric walks and
  fetches all ~61k pixels.

## Fix (engine only; refmodel/RTL unchanged) — gmcnaught/gmloader-next#46

1. **Sparse keyed quads** (`gmloader/mister/mf_sparse.h`, knob `GMLOADER_MFGPU_SPARSE`,
   default 1). At upload each keyed page >= 4096 texels gets a per-8-row-band column
   map of non-key texels; a COLORKEY 1:1 pixel-aligned quad is re-emitted as the rects
   holding non-key texels. Exact: the per-triangle biased-edge sum is checked
   (`mf_sp_tri_exact`, mirrors blt_tri.c), rects are padded until it passes, overlap is
   idempotent under COLORKEY. Cost model: ~85 cycles per triangle-row vs ~8 per pixel,
   so pad wider before taller and merge runs across <= 16 empty columns.
   First version padded taller (mean rect 2x38 px) and the replay priced the rain
   *above* the unsplit layer; the device still improved but less (13.2 ms).
2. **Transposed staging** (knob `GMLOADER_MFGPU_TRANSPOSE`, default 1). A quad whose
   texel address moves fewer bytes per screen-x step on the transposed page
   (`|2*dv/dx + 2*rh*du/dx| < |2*du/dx + 2*rw*dv/dx|`) gets its rect staged transposed
   and u/v swapped after the 12.4 conversion — exact, same weights, swapped clamps.
   Replay: sails 327,680 -> 172,104 cycles. Choosing by `|dv/dx| > |du/dx|` alone was
   worse (221,440): it ignores that the transposed sail page's rows are 56 B, not 196 B.

Host tests: `mf-sparse-test` (6000 random scenes vs blt_raster_tri, 723 split, all
bit-identical; mutation of the exactness check is caught), `raster-backend-test`
(new `sparse-identical`, `transpose-identical` A/Bs over 48 sail angles; both catch
mutations).

## Result (device `.62`, same binary, knobs off vs on, windmill at spawn)

| | off | on |
|---|---|---|
| fabric ms/frame | 15.9–17.1 | **11.1–11.8** |
| texwait ms | 5.4–6.3 | 3.2–3.9 |
| cov_px | 153–161k | 106–109k |
| MFSEAM period (60 windows) | 17.01 mean, 27 > 17 ms | 16.69 mean, 0 > 17 ms |

Regression check, level_1_4 (barrels): 8.97–9.00 ms both ways; nothing split or
transposed there. Screenshots of the windmill scene with both on render correctly.

## Two windmills on screen: the FPS overlay was the dip (.81, user play)

With two windmills in view the user still saw a dip. `.81` logged 16.2–17.5 ms fabric and
~181k covered px, and the capture held a 62,208-px `BLT_F_SRC_SURFACE` COPY — the
app-surface composite that present-from-surface removes. `MFPRES present_surf=0 ... fps=<every
frame>`: the OSD FPS overlay's fills discharged the deferred composite on every frame, so the
overlay added ~3.8 ms to the frames it was measuring. The overlay now paints into the app
surface while the frame is presented from it. Same spot after the fix: 12.5–13.5 ms, ~119k px,
period 16.69 ms; user confirmed 60 fps. Check `MFPRES` before trusting a dip seen with the
overlay on.

Merged: gmcnaught/gmloader-next#46 (8d3649e).

## Not done / next levers

- The other windmills were only measured in the user's play (two-windmill spot above), not headlessly:
  crossing the room needs timed platform jumps.
- `bck_molinos` (2.75 ms) sits mostly under opaque tower tiles; the occlusion cull only
  drops whole triangles. Clipping 1:1 COPY quads against occluders would reuse the
  mf_sparse rect machinery but needs the cull to add triangles, not just collapse them.
- Sails as screen-aligned impostors replayed at 69,624 cycles (vs 172,104 transposed),
  but need a ~58 KB texture upload per frame; not measured on device.
- RTL: `RO_BLOCKS` for P_SRC is 2; more blocks would help every rotated/scaled draw.

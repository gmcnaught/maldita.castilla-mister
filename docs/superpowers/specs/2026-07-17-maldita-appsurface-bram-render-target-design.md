# Design: Application surface as a second BRAM render target (step 1)

**Status:** approved (design; no HDL/host code written yet)
**Date:** 2026-07-17
**Target:** `fpga/rtl/blitter_top.sv` (+ `comp_fbram.sv`, texel-fetch path), and
`gmloader-next/gmloader/mister/{blitter.cpp,raster_backend_mfgpu.cpp}`
**Predecessor:** the TRILIST rasterizer + fabric-offload transport are DONE and
device-confirmed for the single-frame case (magenta triangle via
`tools/fabric_probe`). This spec fixes the first *real game frame*.

## Problem (diagnosed on device 2026-07-17 — do NOT re-derive)

Symptom: on `MalditaCastilla_20260717.rbf` + gmloader `--preset fabric`, the display
freezes on an early black frame and never reaches the title screen, while gmloader
keeps running (frame counter advancing, `C_SUBMIT`/`C_DONE` handshake live, `to=0`).

**Established facts (already verified — do not re-investigate):**

- **The FPGA is innocent.** `fabric_probe.armhf` renders a clean magenta triangle on
  blue and *replaces* the frozen frame, so fabric composite→BRAM→scanout works and is
  not latched. The MiSTer screenshot (`echo screenshot > /dev/MiSTer_cmd`, 320×224 PNG
  in `/media/fat/screenshots/Maldita Castilla/`) is a reliable observable of the
  fabric scanout.
- **The scene is software-rendered, not offloaded.** The fabric backend renders only
  to the single scanout framebuffer (`g_defSurf`); `mf_draw`
  (`raster_backend_mfgpu.cpp:467`) bails to `backend_sw` for *any* target that isn't
  that framebuffer. GameMaker renders the scene into the **application surface** (an
  FBO), so every scene draw is software-rasterized. Only the final surface→screen blit
  reaches the fabric.
- **The freeze is a stale render-target texture.** That blit samples the surface's
  color texture through the persistent resident-texture cache, invalidated ONLY on
  `glTexImage2D`/`glDeleteTexture` (`blitter.cpp:326,338`) — never when the surface is
  re-rendered (an FBO render, not a texture upload). So the fabric composites frame-1's
  surface forever.
- This is **not** a regression from the recent trilist/STA commits and **not** the
  removed SW-video DDR region (0x3A). It is a day-one gap: only the single re-submitted
  magenta triangle (no render targets) was ever validated.

**The application surface is a composited *layer*, not a 1:1 backbuffer proxy.** The
per-frame BLIT trace shows this within-frame order:

```
#1 rt=FBO tex=5 → [0,0..288,216]   sprites rendered INTO the app-surface FBO (color=tex6)
#2 rt=DEF tex=4 blend=NONE          opaque background, drawn straight to the backbuffer
#3 rt=DEF tex=4 blend=ALPHA         more background layers on the backbuffer
#5 rt=DEF tex=6 blend=ALPHA         the app surface (tex6) composited OVER the backbuffer
```

The scene is rendered into the app surface *first* but composited *last*, over
backgrounds that go directly to the backbuffer. Therefore flattening the app-surface
draws into the single WORK framebuffer at the point they are issued would reverse the
layer order (sprites under the background). Correct handling requires the app surface
to be a **real render-target surface** — rendered into, then **sampled as a texture**
to composite over the WORK framebuffer at the blit point.

## Relevant existing RTL (already built)

- `comp_fbram.sv` — the framebuffer in on-chip M10K: a WORK buffer (composite RMW,
  persists across frames) + a SCAN buffer, with a vblank snapshot copy work→scan for
  tear-free scanout (~320 M10K).
- `blitter_top.sv:264` — `target_buf` already encodes `0/1 = framebuffer, 2 =
  off-screen bg-cache`; the `==2` off-screen path (`CACHE_QW @ 0x3BF00000`) existed for
  exactly this pattern and is **currently retired / disabled** (single-buffer mode,
  lines 701–704).
- Texel fetch currently reads texture pages from **SDRAM** (`sdram_fb_cache`);
  `src_in_sdram` is hard-wired 1.

## Goal / non-goals

**Goal:** the game scene renders on the fabric and the display updates every frame
(reaches the title screen), by making the GameMaker application surface a fabric
render-target surface — rendered into and sampled — composited over the WORK
framebuffer in correct layer order. Removes both the software-scene cost and the
stale-texture freeze.

**Non-goals (deferred):**
- More than one extra render target (effect surfaces beyond the application surface) —
  those stay on the SW fallback in step 1. → step 2 (N BRAM surfaces).
- Render targets larger than the BRAM working buffer, or spilled to SDRAM, or tiled. →
  step 3 (SDRAM spill + tiling; tracked task).
- Post-process shaders on the surface→screen blit (step 1 assumes a plain
  textured/alpha blit; see Risks).

## Decision: the app-surface render target lives in BRAM

Chosen over reviving the retired DDR off-screen cache. The app surface's used region is
~288×216 (~100 M10K) and needs both fast blend-writes and fast texture reads every
frame; on-chip BRAM gives blend-in-place and sample-in-place with no DDR RMW/read-back
latency. Budget is tight (recent commits trim M10K to close STA) — reclaim from the
texel-cache trims if needed, and verify fit + STA. Revived DDR cache is the fallback
only if BRAM won't fit.

## Components

### RTL (`blitter_top.sv`, `comp_fbram.sv`, texel path)

1. **Second BRAM surface** — an off-screen render target, ~288×216 (size TBD from the
   instrumented frame; ≤320×240) RGB565, **1W1R** (composite write + texel read). No
   scan buffer / snapshot: it is never scanned out. ~100–160 M10K.
2. **Target select** — extend the existing `target_buf` / `C_TARGET` selector (reuse the
   dormant `==2` off-screen path) so the compositor's RMW write/read port addresses the
   app-surface surface when bound, the WORK framebuffer otherwise.
3. **Sample-surface-as-texture** — the primary new read path and main STA/fit risk: when
   a draw's source is the app-surface surface (selected via `C_SRCSEL`/a flag), the
   texel unit reads the second BRAM surface instead of SDRAM. Must honour the existing
   colorkey/alpha/blend semantics of the TRILIST texel path.

### Host (`gmloader-next`)

4. **Identify the app-surface FBO** — the FBO whose color-attachment texture is drawn as
   a fullscreen quad to the default framebuffer (`g_curFBO==0`, sampling a registered
   `g_fboColorTex` texture, covering the viewport). Mark it as the aliased surface.
   (First frame may be identified lazily; one imperfect boot frame is acceptable.)
5. **Route its draws to the fabric** targeting the app-surface surface (SET_TARGET),
   instead of `backend_sw`.
6. **Emit the blit as a fabric draw** — SET_TARGET=WORK, sample the app-surface surface
   as texture, fullscreen quad at the original blend → composites over the backgrounds
   already in the WORK buffer, preserving layer order.
7. **Retire, for that surface, the render-target SW path and the stale-texture-cache
   path** — the two root causes. Textures uploaded via `glTexImage2D` keep today's
   cache; render targets are fabric-owned surfaces that are never uploaded and cannot go
   stale.

### Protocol (`docs/blitter-protocol.md`, `blitter_defs.vh`)

- Define `C_TARGET` values: `0/1` WORK double-buffer (as today), a value selecting the
  app-surface surface (reuse `2`).
- Define the source-select for sampling the app-surface surface (`C_SRCSEL` or a TRILIST
  header flag). Keep the mfgpu host emitter (`3rdparty/mfgpu`) and the RTL in lockstep;
  update the C reference model so parity tests stay bit-exact.

## Per-frame data flow

1. Clear app-surface surface (from GM's application-surface clear).
2. Render scene into app-surface surface (fabric TRILIST, target = app-surface).
3. SET_TARGET WORK; clear (if GM clears the backbuffer); draw backgrounds (fabric, as
   today).
4. Draw app-surface-as-texture over WORK (fabric TRILIST, source = app-surface surface,
   original blend) — the collapsed surface→screen blit.
5. Existing work→scan snapshot at vblank → scanout.

## Correctness: coordinates and layer order

- The app-surface scene draws decode to screen-space via `mvp + viewport`
  (`blitter.cpp:466`). The surface's coordinate origin/extent and the blit's sampling
  region must be mapped consistently onto the second BRAM surface and back onto the WORK
  buffer. **The implementation's first task is to instrument one representative
  steady-state frame** (all FBO binds, per-draw target/source/blend/screen-rect, blit
  transform) to confirm the exact surface set, the app-surface size, the blit mapping,
  and that no post-process shader is applied — before touching RTL.
- Layer order is preserved by construction: backgrounds land in WORK first, then the
  app surface composites over them at the blit point (step 4).

## Testing

- **Host parity oracle** (`blitter_raster_test.cpp`): add a render-into-surface →
  sample-surface-over-framebuffer case; assert bit-exact (±1 LSB 565) vs the SW
  reference, matching the existing mfgpu oracle discipline.
- **Blitter sim** (`fpga/sim` tb): add a two-surface scene (render into surface, sample
  it over the FB) and check bit-exact vs the C reference; confirm STA/fit after the
  second BRAM surface + texel BRAM read path.
- **On-device:** screen animates and reaches the title screen; screenshot-diffs change
  over time (no longer a constant MD5); `BLITPROF`/fps improves now that the scene is
  fabric-side rather than software-rasterized.

## Risks / open items

- **Texel BRAM read path** (RTL component 3) is the main STA/fit risk on a
  budget-constrained design; may require reclaiming M10K from texel-cache trims.
- **Blit shader:** if GM applies a shader (not a plain textured/alpha quad) on the
  surface→screen draw, step 1 must detect and fall back (keep that frame on SW) rather
  than render it wrong.
- **Effect surfaces:** other FBOs remain on SW in step 1; if Cursed Castilla uses more
  than the application surface, some cost/paths remain SW until step 2.
- **App-surface identification** must be robust to the boot sequence (splash, logos)
  where the fullscreen-blit pattern may not yet be established.

## Future work (the ladder)

- **Step 2 — N BRAM surfaces:** generalize the single extra surface to N, so effect
  surfaces also render on the fabric. Bounded by M10K.
- **Step 3 — SDRAM spill + tiling:** render targets larger than the BRAM working buffer
  or more numerous than fit on-chip spill to SDRAM (VRAM), with tile binning so the
  draw-order triangle rasterizer can render surfaces bigger than one BRAM tile. (Tracked
  task. NOT `jtframe_lfbuf` — that is scanline/object-order; TRILIST is draw-order
  random-access.)

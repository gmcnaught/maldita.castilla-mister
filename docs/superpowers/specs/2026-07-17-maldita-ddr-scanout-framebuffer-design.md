# DDR3 scanout framebuffer (free BRAM for the app-surface) — Design

## Problem

The app-surface BRAM render target (step 1) is bit-exact in sim and its RTL
`surf_*` wiring is now connected in the emu top (`2a78462`), but the RBF
**fails to fit**: Quartus Error 11802, **M10K 620 / 553 (112 %), over by 67
blocks**. The overflow is `comp_fbram` instantiating **three** full 320×240
framebuffers, each 4 banks × 40 M10K = 160 M10K:

| Buffer | M10K | Role |
|---|---|---|
| WORK (`bank0-3`) | 160 | compositor render target (random-access RMW) |
| SCAN (`sbank0-3`) | 160 | tear-free double-buffer for scanout |
| SURFACE (`surf_bank0-3`) | 160 | app-surface render target (random-access RMW) |

The `7a61ec2` RBF fit only because the `surf_*` ports were dangling, so
Quartus pruned the entire surface framebuffer. With them connected the
surface is real and the design overflows. ALMs (79 %) and DSP (79 %) fit —
memory is the sole wall. Shrinking the surface to the game's real 288×216
saves only ~28 M10K (still ~39 over); there is no reclaimable dead memory
(`comp_pipeline` is the live renderer, ~9 M10K). This is an architectural
capacity limit, not a tweak.

## Insight

Scanout and render targets have opposite access patterns:

- **Render targets (WORK, SURFACE)** are written by the draw-order triangle
  rasterizer in **random access with read-modify-write blending** at
  arbitrary pixels. They need zero-latency random access → **must stay
  BRAM**. (This is why `jtframe_lfbuf` was rejected for the rasterizer.)
- **Scanout (SCAN)** is read in **strict raster order, sequentially, once
  per frame**. That is pure streaming — DDR3's variable latency is a
  non-issue when a line is prefetched ahead. → **ideal for DDR3.**

Moving the *scanout* buffer to DDR3 puts each access pattern on the memory
tier built for it and frees SCAN's 160 M10K.

## Idiom validation (MiSTer reference cores)

Confirmed against four cores (research clones in `scratchpad/research/`):

- **DDR3 is the documented home for the framebuffer/scaler** (`misterfpga`
  ref 04); the `ddram.sv` helper keeps a per-channel 1-line cache +
  auto-prefetch "for sequential streaming".
- **ao486** (decisive positive): its hi-res path puts a linear framebuffer
  in DDR3 and scans it out via the **framework `FB_EN` → `ascal`** path with
  **zero on-chip framebuffer BRAM**. The latency-hiding (2048 B bursts,
  two-burst DPRAM + full line buffer) and the DDR arbiter (`sysmem_lite`,
  `vbuf` port) are already in `sys/`. The reusable piece is the framework's,
  not custom RTL — we copy the integration recipe (`ao486.sv:502-534`), not
  the `vga.v` CRTC.
- **SNES / SMS** (negative — real-time beam-race, no resident frame) both
  point at the same framework `FB_EN`/`ascal` path they deliberately ignore.
- **Saturn** (custom-reader alternative, not chosen): proves a custom pixel
  source → `video_mixer` works with no `FB_EN`, and offers building blocks
  (`sdram1.sv` deterministic controller, `ddram.sv` line-cache) if we ever
  wanted to avoid `ascal`.

## Revision (2026-07-18): pivot from `ascal` to a custom DDR reader

The original approach — framework `FB_EN` + `ascal` (triple-buffered) — was
built (RTL Tasks 1–3) and **fit the device (M10K 415/553)**, confirming the
M10K goal. But on hardware it produced **screen noise + TV no-sync**, and a
DDR peek showed the framebuffer address held stale ARM code, not a frame:
`comp_fb_dma` was **not landing the frame in DDR**. Root cause direction: the
WORK→DDR copy was triggered off `ascal`'s **output** vblank (`FB_VBL`),
coupling the producer to the asynchronous consumer — a backwards dependency
that also stalls if `ascal` never locks. More broadly, `ascal` is an
**asynchronous scaler** (framerate conversion + triple-buffer + its own video
mode negotiation) — over-featured for a fixed-rate fabric, it changed the
HDMI mode (→ TV no-sync), added load to the fragile `pll_hdmi` clock, and
**entangled validation** (couldn't separate "frame not written" from "ascal
mis-presenting"). Decision: keep the DDR-framebuffer relocation (it frees the
M10K), but replace `ascal` with a **custom synchronous DDR reader → the
core's existing `video_mixer`/VGA path** (the timing the TV already synced
to). Everything below is the revised (current) design; the `ascal` sections
above ("Chosen approach" rationale, ao486 reference) are retained as the
decision trail.

## Chosen approach (custom DDR reader)

**Adapt the existing `openbor_video_reader`** — already a DDR3-framebuffer,
double-buffered, raster-scanout reader that outputs `VGA_R/G/B/HS/VS/DE`
directly (Genesis H40 timing, no scaling) via `openbor_video_timing`. It was
originally set aside as "designed for HPS-delivered frames" — but this pivot
*deliberately writes the frame to DDR*, so at scanout time the frame **is** in
DDR, exactly its use case. Reuse its DDR-read + double-buffer + known-good
timing; the only change is that the **fabric** (not the HPS) writes the frame
and flips `active_buffer`. Chosen over a clean-sheet reader: far less new RTL,
proven TV-syncable timing, and it drops `ascal` entirely. `openbor_video_top`'s
audio/joystick/ioctl wrapper stays **out** (deferred — see Out of scope);
re-instantiate only the reader + timing.

## Architecture & data flow

```
blitter_top (draw-order rasterizer)
  ├─ renders → comp_fbram WORK    (BRAM, 160 M10K)   unchanged
  ├─ renders → comp_fbram SURFACE (BRAM, 160 M10K)   connected (2a78462)
  └─ at COMPOSITOR vblank: comp_fb_dma bursts WORK → the DDR *inactive* buffer,
     then writes the control word (frame_counter++, active_buffer=just-written)
DDR3 framebuffer (RGB565, 2 ping-pong buffers + control word, in the 16 MB window)
  └─ openbor_video_reader reads control word → active_buffer → streams that
     buffer in raster order → openbor_video_timing → VGA_R/G/B/HS/VS/DE
     → framework video path (VGA_SCALER=0)
```

Producer (compositor-vblank writes) and consumer (reader streams) are
**decoupled** by the double buffer: `comp_fb_dma` writes the inactive buffer
and flips `active_buffer`; the reader always reads the active buffer. No
`FB_VBL`, no `ascal`, no circular trigger. DDR layout mirrors the reader's
existing map: control word @ `+0x000` (`frame_counter[31:2]`,
`active_buffer[1:0]`), Buffer 0 @ `+0x040`, Buffer 1 @ `+0x40040`.

## Components

**`comp_fbram.sv`** — (done, Task 2) SCAN banks removed; WORK + SURFACE kept.
The −160 M10K.

**`comp_fb_dma.sv`** — (Task 1 core stands) extend from single-buffer to
**double-buffer**: write the inactive buffer (`+0x040` / `+0x40040`), then the
control word; trigger off the **compositor vblank** (the blitter's existing
`fb_dma_start`/`vs` path), **not** `FB_VBL`.

**Scanout reader** — re-instantiate `openbor_video_reader` +
`openbor_video_timing` directly (skip `openbor_video_top`), repoint the base
from `0x3A…` to the fabric framebuffer, wire its `ddr_*` master onto the
arbiter `rdr_*` slot, output → `VGA_*`. Tie off its unused SDRAM `scan_*` path.

**`Maldita.sv`** — `VGA_SCALER=0`; instantiate reader + timing → `VGA_*`;
**revert** the Task-3 `FB_*`/`ascal` drives and the comp_fb_dma-as-sole-rdr-
writer wiring; wire the `rdr_*` arbiter slot to carry reader reads (active
display) and `comp_fb_dma` writes (vblank).

**`Maldita.qsf`** — drop `MISTER_FB=1` (revert Task 3). Keep
`MISTER_DISABLE_PALETTE1` as it was pre-Task-3.

## DDR framebuffer placement

Two 320×240×2 = 153,600 B buffers + a control word, in the reserved slot at
the top of the 16 MB blitter window (`0x3B000000`), above the texture heap
(host writes ≤ `0xF40000`), matching the reader's `+0x000`/`+0x040`/`+0x40040`
offsets. Fabric-internal (written by `comp_fb_dma`, read by the reader; the
host never touches it). No host change (slot sits above the heap).

## Video-path details

- `VGA_SCALER=0`; the reader + `openbor_video_timing` drive `VGA_R/G/B/HS/VS/DE`
  → the framework's normal video/HDMI path (the timing the TV already synced
  to). `video_freak` / the 320×224 crop (`status[18]`) path is preserved as it
  was before the ascal detour.
- `CLK_VIDEO`/`CE_PIXEL` = the existing Genesis H40 timing (`ce_pix_gen`),
  restored as the scanout clock.

## Verification

- **Sim:** extend `tb_fb_dma` for the **double-buffer + control-word write** —
  assert both buffers and the control word land at the right offsets/bytes for
  a known WORK image. Surface benches stay green (`tb_surfram`,
  `tb_blitter_surface_src`, `tb_blitter_system_pipe`); `tb_scanout_fbram`
  stays retired. The reader is legacy-proven; add a focused sim only if it is
  changed materially.
- **Device (directly validatable now):** peek DDR at the buffers to confirm
  `comp_fb_dma` wrote a **coherent RGB565 frame** (structure, not ARM code)
  *before* trusting the reader; then confirm the reader displays it. RBF fits
  (M10K ≤ 553); `C_SUBMIT` climbs, `C_DONE` tracks; **TV syncs** (known-good
  timing); screenshots change over time and reach the **Cursed Castilla title
  screen** (centre fills in); tear-free (double buffer).

## Known risks

- **`rdr_*` slot read/write time-sharing** — the reader's line-prefetch reads
  and `comp_fb_dma`'s vblank burst share the single f2h `rdr_*` slot.
  Double-buffering prevents same-buffer races (reader = active buffer,
  writer = inactive); the open question is arbitration/starvation on the port.
  Reader reads during active display, writer bursts during vblank — largely
  disjoint in time. Saturn's `ddram.sv` line-cache is the reference if the
  reader's prefetch depth needs tuning. Confirm on device (no stale-frame /
  underflow).
- **Latent app-surface UV bug** — once the surface displays, the app-surface
  (288×216 rendered into a 512×256 texture) vs. the RTL fixed-320×240 sample
  clamp may render scaled/offset. Host-side (`raster_backend_mfgpu.cpp`
  `src_is_appsurf` UV scale); folded into title-screen verification, likely a
  small `impl-engine` follow-up.
- **STA (emu clock)** — the custom reader adds no ascal FB-read path and no
  `pll_hdmi` load; net M10K stays low (~415–460/553). Should be **healthier**
  than the ascal build (emu −0.557). Confirm slack post-build.

## Out of scope

- N BRAM surfaces (step 2) and SDRAM-spilled/tiled render targets (step 3) —
  unchanged roadmap; this design only relocates *scanout*, not the render
  targets.
- Any change to the sub-region texture residency work (Tasks 1–3, landed and
  verified on device) or the host protocol / reference model.
- **Audio and joystick integration to the MiSTer framework output.** The pivot
  re-instantiates only `openbor_video_reader` + `openbor_video_timing` (the
  scanout), **not** `openbor_video_top`'s incidental `AUDIO_L/R` drain and
  joystick→ARM path — those stay tied off (vestigial in the `--preset fabric`
  config: the game has no FPGA audio — gmloader never writes the DDR audio
  pointers, device has only a Dummy ALSA card — and takes input via Linux SDL,
  so nothing working regresses). Proper audio/input framework integration is
  deferred future work; like `openbor` it will likely need HPS I/O, so
  `openbor_video_top`'s mechanisms (in git / still in-tree) are the reference
  starting point — not a permanent capability loss.

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

## Chosen approach

**Framework `FB_EN` + `ascal`, triple-buffered.** (Decided over a custom DDR
scanout reader — least new RTL, complete worked example in ao486, deletes the
most M10K, and the hard latency/arbitration code is shipped framework code we
don't have to bit-exact-verify. Accepted tradeoff: `ascal` owns pixel
timing/scaling — fine for a GPU-offload core that needs no beam accuracy.)

**Triple-buffering by `ascal`** (`lowlat=0`) over a self-managed
double-buffer: less core logic — `ascal` owns the 3 presentation buffers and
the swap; the core just writes its composited frame and drives `FB_*`.

**One combined RBF** (surface wired + scanout moved together), not a
sequenced two-step: the device is already non-functional (black centre), so
there is no working state to protect by isolating the changes.

## Architecture & data flow

```
blitter_top (draw-order rasterizer)
  ├─ renders → comp_fbram WORK    (BRAM, 160 M10K)   unchanged
  ├─ renders → comp_fbram SURFACE (BRAM, 160 M10K)   connected (2a78462)
  └─ at vblank: burst-DMA WORK → DDR3 framebuffer (via existing arb_ddr_* f2h)
DDR3 framebuffer (RGB565, reserved slot in the 16 MB blitter window)
  └─ ascal reads FB_BASE, triple-buffers, scales → HDMI          framework
```

The framework contract (verified in `sys/sys_top.v` + `sys/ascal.vhd`): the
core's `FB_*` outputs feed `ascal`; `ascal`'s buffering mode is `~lowlat`
(`ascal.vhd:89-90`: `lowlat=0` → triple-buffering, `RAMSIZE ×3`, `ascal`
detects end-of-frame and rotates its own 3 presentation buffers at
`RAMBASE`, separate from the core's `FB_BASE`). The core drives `FB_EN=1`,
`FB_FORMAT=5'b00100` (`[2:0]=100` 16bpp, `[3]=0` 565, `[4]=0` RGB),
`FB_WIDTH=320`, `FB_HEIGHT=240`, `FB_STRIDE=640`, `FB_BASE=<fb addr>`,
`VGA_SCALER=1`, and observes `FB_VBL`.

## Components

**`comp_fbram.sv`** — Remove SCAN banks (`sbank0-3`) and the WORK→SCAN
`snap_*` port; keep WORK + SURFACE and their ports. This is the −160 M10K.
One clear responsibility: the two on-chip render-target framebuffers.

**`blitter_top.sv`** — Retarget the existing vblank `u_snap` path (today
WORK→SCAN BRAM) into a **WORK→DDR burst-writer**: at vblank, read WORK in
raster order and burst-write it to the DDR framebuffer via the `arb_ddr_*`
arbiter, then signal frame-ready (coordinated with `FB_VBL`). No change to
the rasterizer or the surface path.

**`Maldita.sv`** — Drive the `FB_*` registers + `VGA_SCALER=1` + `lowlat=0`
path; add the FB-writer as a client on the existing DDR arbiter; **delete**
`openbor_video_top`, `fbram_scan_adapter`, the `scn_*` wiring, and the
stale-frame watchdog. Retain only the `CLK_VIDEO`/`CE_PIXEL` the framework
still requires under `FB_EN`.

## DDR framebuffer placement

Reserve a fixed framebuffer slot inside the 16 MB blitter window
(`0x3B000000`), not overlapping the control block (`+0x00`), ring (`+0x40`),
or texture heap (`+0x80000`, ~14.62 MB). One source buffer is
320×240×2 = 153,600 B (~150 KB); round up to a 512 KB reserved slot.
`ascal`'s 3 presentation buffers live in the framework's `RAMBASE`, not this
slot. The framebuffer is **fabric-internal** — written by `blitter_top`, read
by `ascal`; the host (`gmloader`) never touches it. The host texture-heap cap
(`MF_DEV_SRC_CAP`) must exclude the reserved slot (a small host-side constant
trim), or the slot is placed above the heap so no host change is needed —
lock the exact address map in the plan.

## Video-path details (locked in the plan)

- Under `VGA_SCALER=1` + `FB_EN`, the analog `VGA_R/G/B` path and
  `video_freak` are bypassed; scanout is entirely `ascal`-from-DDR.
- **320×224 crop** (`status[18]`) must be re-expressed via `FB_HEIGHT` /
  lines-DMA'd or aspect reporting. Initial approach: carry the full 320×240
  composited frame and confirm crop/aspect against the framework FB+`ascal`
  behaviour; adjust `FB_HEIGHT`/aspect if the crop regresses.
- `CLK_VIDEO`/`CE_PIXEL` custom Genesis timing is no longer the scanout
  clock; retain only what the framework still requires.

## Verification

- **Sim (bit-exact gate where it applies):** a new bench for the
  **WORK→DDR DMA byte-correctness** — the burst-writer emits the correct
  RGB565 bytes at the correct `FB_STRIDE`/layout for a known WORK image.
  Existing blitter/`comp_fbram`/surface sims updated for the SCAN removal:
  `tb_scanout_fbram` (pre-existing failure, tied to the scan path) retired or
  rewritten; surface benches (`tb_surfram`, `tb_blitter_surface_src`,
  `tb_blitter_system_pipe`) stay green.
- **Device (the real gate — `ascal` is not sim-able):** RBF **fits** (M10K
  ≤ 553); `C_SUBMIT` climbs, `C_DONE` tracks; screenshots **change over time**
  and reach the **Cursed Castilla title screen** (centre fills in, not black);
  no stale-frame blank; tear-free.

## Known risks

- **`FB_VBL`/swap handshake** — the one implementation unknown: whether
  tear-free needs the core to time writes against `FB_VBL` / rotate source
  buffers, or whether `ascal` absorbs it from a single fixed `FB_BASE`. Lock
  against `ascal.vhd` + a reference triple-buffered core during
  implementation. Architecture-neutral (a few lines of writer swap logic).
- **Latent app-surface UV bug** — once the surface displays, the app-surface
  (288×216 rendered into a 512×256 texture) vs. the RTL fixed-320×240 sample
  clamp may render scaled/offset. Host-side (`raster_backend_mfgpu.cpp`
  `src_is_appsurf` UV scale); folded into title-screen verification, likely a
  small `impl-engine` follow-up.
- **STA (emu clock)** — removing SCAN (160 M10K) + `openbor` *reduces*
  congestion on the placement-fragile emu clock; net M10K drops to ~460/553,
  which should help rather than hurt. Confirm slack post-build.

## Out of scope

- N BRAM surfaces (step 2) and SDRAM-spilled/tiled render targets (step 3) —
  unchanged roadmap; this design only relocates *scanout*, not the render
  targets.
- Any change to the sub-region texture residency work (Tasks 1–3, landed and
  verified on device) or the host protocol / reference model.
- **Audio and joystick integration to the MiSTer framework output.** Deleting
  the `openbor` scanout also removes its incidental (vestigial in the
  `--preset fabric` config) `AUDIO_L/R` drain and joystick→ARM path — tied off
  this plan. The game currently has no FPGA audio (gmloader never writes the
  DDR audio pointers; device has only a Dummy ALSA card) and takes input via
  Linux SDL, so nothing working regresses. Proper audio/input framework
  integration is deferred future work; like `openbor` it will likely need HPS
  I/O, so `openbor`'s mechanisms (preserved in git at the pre-deletion commit)
  are the reference starting point — not a permanent capability loss.

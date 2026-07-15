# Maldita Castilla — FPGA Draw Offload (Fabric GPU) Design

**Date:** 2026-07-14
**Repos:** `maldita.castilla-mister` (the core, Task-1 fork of Solarus) + `gmloader-next` (the A9 engine, branch `mister-sdl-buffer-output`)
**Status:** approved (design), pending implementation plan
**Supersedes the direction of:** `2026-07-14-maldita-core-milestone-a-design.md` (direct DDR scanout — dropped; see Context).

## Context

The direct-scanout Milestone A was abandoned after discovering that the Solarus
core's scanout does **not** read gmloader's A9-rendered DDR frames: its DDR3
`P_SCAN` channel is tied dead (`Maldita.sv:477`) and scanout reads an on-chip
BRAM framebuffer (`comp_fbram`) that the **compositor fabric** (`blitter_top`)
fills at vblank. So "scan out gmloader's frames with the fabric dormant" is
self-contradictory on this core.

The right move is to embrace what the core already does: **make the FPGA fabric
the GPU.** Feed gmloader-next's draw stream to the core's `blitter_top`, which
rasterizes into `comp_fbram` → scanout. This is the project's north star (offload
GLES to the fabric), and the Solarus core is already built for it.

### Key finding — the contract already matches (both are `mister-fpga-blitter`)

- **Core (`blitter_top.sv`)** walks a DDR **command ring**, decodes
  `OP_STAGE`/`OP_TRILIST`/`OP_FILL`/`OP_END` (`u32[0] = opcode|blend|format|flags`),
  DMAs texture sources **DDR3→SDRAM** via `BLT_OP_STAGE`, samples from SDRAM
  (`src_in_sdram=1`), composites to `comp_fbram`, and signals completion. This is
  the live path Solarus uses.
- **gmloader-next (`backend_mfgpu`)** already builds that exact ring + control
  block via `blt_emitter`, but currently writes to a **host-static** ring and runs
  `blt_execute` in **software on the A9** — it never publishes to the real DDR ring
  and never emits `STAGE`.

**DDR memory map (`blitter_defs.vh`):**
| Region | Phys addr | Purpose |
|---|---|---|
| `VCTRL` | `0x3A000000` | video control word (existing) |
| `BUF0/BUF1` | `0x3A000040` / `0x3A040040` | scanout buffers (existing) |
| `BLTCTRL` | `0x3B000000` | blitter control block (doorbell/handshake) |
| `RING` | `0x3B000040` | command ring (512 KiB, ~16382 cmds) |
| `SRC` | `0x3B080000` | DDR3 source-surface heap (textures staged from here) |

**Control block fields** (qwords from `BLTCTRL`): `C_SUBMIT` (doorbell),
`C_CMDCOUNT`, `C_TARGET`, `C_CLEAR`, `C_FLAGS`, `C_DONE`, `C_STATUS`, `C_SRCSEL`.

## Goal

gmloader-next publishes its per-frame draw ring to the real DDR command region,
staging textures DDR3→SDRAM via `BLT_OP_STAGE`, and the Maldita core's fabric
rasterizes them into `comp_fbram` → scanout — replacing the A9 software
`blt_execute`. Verified on device by a fabric-rendered Maldita frame captured via
MiSTer Remote.

## Design

### 1. gmloader-next `backend_mfgpu` — the bulk of the work

- **Wire the real DDR** (mirrors `native_video_writer`'s `/dev/mem` map of
  `0x3A000000`): map the `0x3B000000` blitter region and point the emitter's
  control block → `BLTCTRL`, ring → `RING`, source heap → `SRC`. Replaces the
  host-static `g_ring`/heap buffers on device (guard host vs device with the
  existing MiSTer build macro).
- **Stage textures into SDRAM:** for each texture page a frame references, emit
  `BLT_OP_STAGE` (DDR3 `SRC`→SDRAM) before the `OP_TRILIST` that samples it, via
  the existing `blt_stage_surface`. Extend the **persistent identity-keyed atlas
  cache** (already built) to track **SDRAM residency** (which pages are staged),
  not just DDR-heap occupancy — a page already resident in SDRAM skips re-STAGE.
  This is also what fixes Maldita's 2048² page overflow (SDRAM = 64 MB ≫ the DDR3
  heap).
- **Submit + handshake per frame:** write `C_CMDCOUNT`, bump `C_SUBMIT`
  (doorbell), then poll `C_DONE` (with a timeout guard). On done, the frame is in
  `comp_fbram` and the core scans it out at vblank. **Remove the software
  `blt_execute`** from the device present path; `present()` becomes submit-and-wait
  rather than rasterize-on-A9.
- **Selector unchanged:** `GMLOADER_RASTER=mfgpu` now means true fabric offload;
  `backend_sw` remains the A9 software fallback.

### 2. Maldita core (`maldita.castilla-mister`) — minimal

- **No source-path RTL change** — `BLT_OP_STAGE` + `src_in_sdram=1` already
  implement DDR3→SDRAM→TRILIST. Confirm the ring/`BLTCTRL` wiring in `Maldita.sv`
  is reachable by an external A9 producer (it is — libsolarus drives it today).
- **320×224 scanout timing** — fold in the parked Task-2 timing change
  (`openbor_video_timing.sv` → `V_ACTIVE=224`, `V_TOTAL` held at 262). The reader's
  DDR-offset scaffolding from parked Task 2 is **not** used here (scanout reads
  `comp_fbram`, not DDR); drop it. The compositor fills `comp_fbram` at the
  core's FB height — reconcile the visible 224 lines with `comp_fbram`'s geometry
  in the plan.

### 3. Host validation (refmodel)

The host oracle must stay meaningful: extend the vendored refmodel so `blt_execute`
models `BLT_OP_STAGE` (DDR3→SDRAM copy) and TRILIST-samples-from-SDRAM, so the
existing `raster-backend-test` battery still validates the emitted ring in
present-space RGB565 (±1 LSB). Without this, emitting `STAGE` would make the host
test diverge from the device.

### 4. Frame synchronization

One `C_SUBMIT`/`C_DONE` round per gmloader frame. The fabric composites to a work
buffer and snapshots to the scan buffer at vblank (tear-free), so gmloader submits
once per frame and lets the core+scanout present; `C_DONE` gates the next frame's
ring reuse. Define the exact submit cadence vs gmloader's frame loop in the plan.

## First vertical slice (de-risk before full residency)

Prove the pipe end-to-end with the **smallest** possible submit: gmloader maps the
DDR region, stages **one** texture to SDRAM via `BLT_OP_STAGE`, emits a single
`OP_TRILIST` referencing it, bumps the doorbell, waits `C_DONE` — and MiSTer Remote
captures that one fabric-rendered textured triangle on screen (A9 `blt_execute`
OFF). Only after that works: scale to Maldita's full per-frame draw set and LRU
SDRAM residency.

## Out of scope

- The pre-existing heap-corruption crash (gmloader-next#13).
- SDRAM residency *eviction policy* tuning beyond a working LRU (correctness first).
- Any Solarus-specific RTL cleanup (`bgplane`/CLUT) — dormant, untouched.
- Audio/input beyond what the core's IO bridge already provides.

## Success criteria

1. On device, with `GMLOADER_RASTER=mfgpu`, gmloader publishes its ring to
   `0x3B000000`, the fabric raises `C_DONE`, and **no A9 `blt_execute` runs**.
2. MiSTer Remote captures a **fabric-rendered** Maldita frame (the first-slice
   single textured triangle, then a real scene) — textures staged into SDRAM, so
   the 2048² pages no longer drop.
3. The host `raster-backend-test` battery still passes (±1 LSB) with the
   STAGE-aware refmodel.
4. `backend_sw` remains an unregressed A9 fallback.

## Open questions for the implementation plan

- Exact `blt_emitter` API to publish control-block fields to `BLTCTRL` and bump
  `C_SUBMIT` on device (confirm `blt_emitter.h`'s "control-block mirror" copy path).
- Whether `C_SRCSEL` must be set for the DDR3→SDRAM STAGE path or SDRAM is the
  default for TRILIST sources.
- `comp_fbram` geometry vs the 320×224 visible window (does the compositor render
  320×240 and the timing crop to 224, or render 224 directly?).
- Poll vs interrupt for `C_DONE`, and the timeout/fallback if the fabric stalls.
- Whether the first slice needs the core rebuilt/redeployed at all, or the existing
  Solarus/Maldita RBF already accepts an external ring producer as-is.

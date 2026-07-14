# Maldita Castilla MiSTer Core — Milestone A Design

**Date:** 2026-07-14
**Repo:** `maldita.castilla-mister` (currently empty; this is its first artifact)
**Status:** approved (design), pending implementation plan

## Context

`gmloader-next` runs Maldita Castilla (a GameMaker title) as an ARM/HPS userspace
process on the MiSTer DE10-Nano. It renders frames on the A9 and writes finished
**320×240 RGB565** frames to DDR3 at physical `0x3A000000` via
`NativeVideoWriter` — a layout **byte-identical** to the `openbor_video_reader.sv`
DDR memory map. Today there is **no dedicated Maldita core**: the frames are
scanned out by borrowing the `OpenBOR_7533` core, whose 320×224 timing does not
match gmloader's 320×240 output, producing a garbled/dark image.

This design stands up an **independent Maldita Castilla RBF**, forked from the
mature `solarus-mister` core, that scans out gmloader's frames cleanly at
**320×224** and carries the blitter fabric (dormant) for a later GPU-offload
milestone.

### The larger vision (why fork the fabric core, not a scanout-only core)

The north star is to **hook gmloader-next's GLES layer and offload draw calls to
the FPGA fabric — making the FPGA effectively the GPU.** The Solarus core already
contains a bit-exact, HW-validated triangle-blitter fabric
(`comp_*`/`blitter_top`, from the shared upstream `mister-fpga-blitter`). The
Maldita and Solarus cores are therefore both **"instances" of that shared
blitter base**. Carrying the fabric into the Maldita core now (even dormant) is
what makes the GPU-offload milestone an activation rather than a rebuild.

**This spec is scoped to Milestone A only** (below). GLES→fabric offload is
Milestone B, a separate spec.

## Milestone split

- **Milestone A (this spec):** stand up the Maldita RBF from the Solarus core —
  rebrand, retarget scanout to 320×224, IO bridge, build, deploy. Result: a
  working Maldita core that scans out gmloader's **A9-rendered** frames cleanly.
  The fabric is compiled in but **dormant** (gmloader still renders on the A9).
- **Milestone B (future spec):** wire gmloader-next's `backend_mfgpu` DDR command
  ring into the core's `blitter_top`, offload the target GLES calls, so the
  fabric rasterizes. Built on top of a known-good Milestone-A core.

## Architecture (what the Solarus core gives us)

The Solarus core cleanly separates into two independent parts, both retained:

1. **`openbor_video_top` / `openbor_video_reader` + IO bridge** — reads RGB565
   frames straight from DDR3 `0x3A000000` and scans them out 1:1 (no scaling),
   plus the joystick / audio-ring / cart bridge. Its documented DDR map matches
   `native_video_writer.h` exactly. **This is already the gmloader scanout
   contract** and is the active path in Milestone A.
2. **`comp_*` / `blitter_top`** — the on-chip triangle compositor fabric (the
   MFGPU-style GPU), plus Solarus-specific `bgplane`/CLUT/PAL8 RTL. **Carried but
   dormant** in Milestone A (not fed; nothing writes its command ring).

## Design

### 1. Repository & structure

Populate the empty `maldita.castilla-mister` by copying `solarus-mister`'s FPGA
project and scaffolding, preserving layout so the two remain recognizable as
instances of the shared base:

- `fpga/` — `rtl/` (incl. `openbor_video_*`, `comp_*`, `blitter_top`, `jtframe`,
  `pll`), `sys/`, the Quartus project (`.qpf/.qsf/.sdc`, top `.sv`),
  `build_*.sh`, `files.qip`.
- `deploy.py`, `games/`, build/CI scaffolding.

The RBF is a gitignored / CI-built + downloaded artifact, mirroring Solarus.

### 2. FPGA changes

- **Rebrand the Quartus project** `Solarus → Maldita`: project revision,
  `.qpf/.qsf/.sdc`, top-level `.sv`, and `build_*.sh` `PROJECT`/`RBF_PREFIX` →
  output `_Other/MalditaCastilla_YYYYMMDD.rbf`. Keep the MiSTer `sys_top`/`emu`
  wiring unchanged.
- **Retarget scanout to 320×224** in `openbor_video_timing.sv`: set
  `V_ACTIVE = 224` and rebalance `V_FP/V_SYNC/V_BP` to a valid 15 kHz
  NTSC-compatible total (keep H timing / Genesis H40 unchanged). Ensure
  `openbor_video_reader` presents the matching 224 visible rows (see §3).
- **Fabric dormant:** `comp_*`/`blitter_top` and Solarus-specific
  `bgplane`/CLUT/PAL8 RTL remain **instantiated but unfed**. Ripping them out is
  deliberately **out of scope** — stripping hardware-validated RTL is delicate
  and is cleanup, not Milestone-A value. They cost logic but do not affect the
  scanout path.

### 3. Frame-geometry reconciliation (320×240 producer → 320×224 display)

gmloader writes **320×240** (`MISTER_HEIGHT=240`), with Maldita's 288×216 content
letterboxed inside. Chosen approach (per user steer):

- **gmloader letterboxes content into the middle 224 rows** of the 320×240 DDR
  buffer — 8px black bars at top and bottom (8 + 224 + 8 = 240) — in the present
  path (`Blitter_ToRGB565` / the mfgpu `g_fb565` handoff, shared by both
  backends).
- **The Maldita core displays those middle 224 rows** at `320×224`
  (`openbor_video_reader` starts its per-frame line fetch at row offset 8 of the
  320-wide buffer). Net: a pixel-exact 320×224 Maldita image, no vertical crop of
  content.

Rejected alternative: changing gmloader's `MISTER_HEIGHT` to 224 directly (fewer
moving parts in the buffer, but changes a core constant and the DDR buffer size
assumptions shared with the reader's documented 320×240 map). The letterbox keeps
the existing 320×240 DDR contract intact and localizes the change to two small,
symmetric edits (producer letterbox + reader row-offset).

### 4. Build, deploy, verify

- **Build:** `fpga/build_maldita.sh` (Quartus Prime 17.0.x), output
  `_Other/MalditaCastilla_*.rbf`; mirror the Solarus `build-rbf` GitHub Actions
  workflow (`raetro/quartus:17.0`).
- **Deploy:** adapt `deploy.py` to push the RBF plus a `games/MalditaCastilla/`
  launcher that runs the **existing** gmloader engine already deployed at
  `/media/fat/games/gmloader` (the Maldita core's "engine" is gmloader-next; this
  spec does not rebuild or redeploy gmloader itself).
- **Verify (device `192.168.20.81`):**
  1. Load the Maldita RBF (`load_core /media/fat/_Other/MalditaCastilla_*.rbf`
     via `/dev/MiSTer_cmd`); confirm `/tmp/CORENAME`.
  2. Run gmloader (SW path); confirm the DDR control word at `0x3A000000`
     **increments** (frames reaching DDR) and the blitter draw log advances.
  3. Capture via MiSTer Remote (`:8182`) and confirm a **clean, recognizable
     320×224 Maldita frame** — the concrete pass/fail: the OpenBOR_7533 garbling
     is gone.
  4. Regression: the gmloader SW present path is unchanged for anyone still using
     the OpenBOR_7533 core.

## Out of scope

- **Milestone B** — GLES→fabric offload / activating the on-chip GPU.
- **The pre-existing heap-corruption crash** (gmloader-next#13) — intermittent
  startup abort; independent of this core. Runs usually survive long enough to
  capture a frame.
- **Stripping Solarus-specific RTL** (`bgplane`/CLUT/PAL8) — a later cleanup.
- **Audio/input feature work** beyond what the Solarus IO bridge already provides.
- **Rebuilding/redeploying gmloader** — the engine is reused as-is.

## Success criteria

1. `maldita.castilla-mister` builds an RBF from a rebranded Solarus fork on
   Quartus 17.0 (locally and/or in CI).
2. The core loads on the device and reports as the Maldita core.
3. With gmloader running, the DDR frame-counter increments and MiSTer Remote
   captures a **clean 320×224 Maldita frame** (garbling resolved).
4. The dormant fabric and Solarus-specific RTL compile in without affecting the
   scanout path; the gmloader SW present path is unregressed.

## Open questions for the implementation plan

- Exact `V_FP/V_SYNC/V_BP` values for a valid 320×224 15 kHz total (derive from
  the current 320×240 `V_TOTAL=262` budget; keep vsync outside active video per
  the existing `#107` clamp).
- Whether the reader's 8-row start offset is cleanest in `openbor_video_reader`
  (base-address bump) vs `openbor_video_timing` (active-window shift).
- Quartus revision-rename mechanics (revision name must track the top-level
  entity; confirm `sys_top`/`emu` naming is untouched).

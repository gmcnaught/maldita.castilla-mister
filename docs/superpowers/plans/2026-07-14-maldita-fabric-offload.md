# Maldita Fabric Draw-Offload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make gmloader-next publish its per-frame draw ring to the real DDR
command region so the Maldita core's `blitter_top` fabric rasterizes it into
`comp_fbram` → scanout, staging textures DDR3→SDRAM via `BLT_OP_STAGE`, replacing
the A9 software `blt_execute`.

**Architecture:** The core already walks the ring (`0x3B000040`), stages sources
to SDRAM, samples them, and composites to the scanned-out on-chip framebuffer. The
work is almost entirely gmloader-side: point the emitter at real DDR, emit STAGE,
bump the doorbell, poll `C_DONE`, drop `blt_execute`. A standalone probe validates
the contract before touching the production backend.

**Tech Stack:** C/C++ (`gmloader-next` `backend_mfgpu` + vendored `3rdparty/mfgpu`),
armhf cross-build (`gmloader-armhf-build:bullseye`), SystemVerilog (Maldita core,
timing only), MiSTer DE10-Nano `192.168.20.81`, MiSTer Remote `:8182`.

## Global Constraints

- **DDR command map (`blitter_defs.vh`), verbatim:** `BLTCTRL 0x3B000000`,
  `RING 0x3B000040` (512 KiB), `SRC 0x3B080000` (DDR3 source heap). Control-block
  qword fields: `C_SUBMIT=0`, `C_CMDCOUNT=1`, `C_TARGET=2`, `C_CLEAR=3`,
  `C_FLAGS=4`, `C_DONE=5`, `C_STATUS=6`, `C_SRCSEL=7` (low 32 bits each).
- **Video framebuffer map is unchanged** (`0x3A000000` region) — the fabric owns
  `comp_fbram` scanout; do not repurpose the `0x3A...` scanout buffers.
- **`src_in_sdram=1` in the core is fixed** — gmloader MUST stage textures into
  SDRAM via `BLT_OP_STAGE` before any TRILIST that samples them. No core src-path
  RTL change.
- **Host oracle stays ±1 LSB RGB565** — every gmloader-side change keeps
  `make -f Makefile.gmloader raster-backend-test` green.
- **`backend_sw` is the untouched A9 fallback** — `GMLOADER_RASTER=mfgpu` selects
  the fabric; default stays SW.
- **Device vs host split** guarded by the existing MiSTer build macro — the static
  `g_ring`/`g_srcdram` path stays for host tests; the mmap'd-DDR path is device-only.
- gmloader-next work is on branch `mister-sdl-buffer-output`; the core timing change
  is in `maldita.castilla-mister` (branch off the Task-1 fork).

---

## Task 1: Standalone contract probe — prove the RBF accepts an external ring producer

**Goal:** Before touching the production backend, prove on hardware that writing a
minimal ring + control block to `0x3B000000` and bumping `C_SUBMIT` makes the
Maldita core's fabric render one textured triangle to screen (`C_DONE` fires). This
de-risks every downstream task and answers "does the existing RBF need a core
change?" (spec open question).

**Files:**
- Create: `gmloader-next/tools/fabric_probe.c` (standalone; links the vendored
  `3rdparty/mfgpu` host + refmodel objects for `blt_emitter`/`blt_*`).
- Create: `gmloader-next/tools/Makefile.fabric_probe` (armhf cross-build of the probe).

**Interfaces:**
- Consumes: `blt_emitter_init`, `blt_begin_frame`, `blt_stage_surface`,
  `blt_push_tris`, `blt_trilist`, `blt_end_frame` (from `3rdparty/mfgpu/host`);
  the DDR map + control-block offsets (Global Constraints).
- Produces: a deployable `fabric_probe.armhf` that submits one frame to the fabric.

- [ ] **Step 1: Write the probe.** `tools/fabric_probe.c`:
  - `open("/dev/mem", O_RDWR|O_SYNC)`; `mmap` the `0x3B000000` region (size
    `0x01000000`, covering `BLTCTRL`+`RING`+`SRC`) — mirror `native_video_writer.c`'s
    open/mmap exactly.
  - Point `blt_emitter_init(&e, ring_ptr, RING_CAP, src_ptr, SRC_CAP)` at the mmap'd
    `RING` (`base+0x40`) and `SRC` (`base+0x80000`) pointers. Call `blt_sdram_init`
    with the SDRAM region (confirm base/size from `blitter_defs.vh`'s SDRAM map).
  - `blt_begin_frame(&e, 0, /*clear=*/1, /*color=*/mf_rgb565(0,0,40))`.
  - Build a tiny opaque texture (e.g. 8×8 solid magenta) in the `SRC` heap via
    `blt_upload`; `blt_stage_surface(&e, &ref)` to emit `BLT_OP_STAGE`.
  - One centered triangle: `blt_push_tris(&e, tris, 1)` → `entry_off`;
    `blt_trilist(&e, ref, BLT_BLEND_COPY, /*colorkey=*/0, /*alpha=*/255, entry_off, 1)`.
  - `blt_end_frame(&e)`. Then publish the control-block mirror to `BLTCTRL`:
    write `C_CMDCOUNT`, `C_TARGET`, `C_CLEAR`, `C_FLAGS` from `e.*`, memory-barrier,
    then write `C_SUBMIT` (the emitter's `submit_seq`) LAST (doorbell after data).
  - Poll `C_DONE` until it matches `submit_seq` (timeout ~500 ms); print
    `C_DONE`/`C_STATUS`. `munmap`/close.

- [ ] **Step 2: Cross-build.** `make -f tools/Makefile.fabric_probe` in the
  `gmloader-armhf-build:bullseye` container (reuse the CLAUDE.md docker recipe,
  compiling `fabric_probe.c` + the `3rdparty/mfgpu/host` + `refmodel` C objects).
  Expected: `fabric_probe.armhf` produced, clean link.

- [ ] **Step 3: Deploy + run on device (controller-run).** Load the Maldita RBF
  (`load_core` via `/dev/MiSTer_cmd`), scp `fabric_probe.armhf`, run it:
  `ssh root@192.168.20.81 './fabric_probe'`. Expected stdout: `C_DONE` reaches
  `submit_seq` (not a timeout), `C_STATUS` reports OK.

- [ ] **Step 4: Verify on screen.** Capture via MiSTer Remote (`POST :8182/api/screenshots`,
  fetch newest, view). **Pass condition:** the blue-cleared field with one magenta
  triangle is visible — proof the fabric rendered an externally-submitted ring to
  scanout. If `C_DONE` never fires or nothing renders, STOP and investigate the core
  ring/doorbell wiring before proceeding (this is the go/no-go for the whole plan).

- [ ] **Step 5: Commit (in gmloader-next).**
```bash
git add tools/fabric_probe.c tools/Makefile.fabric_probe
git commit -m "tools: fabric_probe — validate external ring producer -> Maldita core fabric"
```

---

## Task 2: STAGE-aware refmodel — keep the host oracle honest

**Goal:** Extend the vendored refmodel so `blt_execute` models `BLT_OP_STAGE`
(DDR3→SDRAM copy) and TRILIST-samples-from-SDRAM, so the host `raster-backend-test`
battery still validates rings that now contain STAGE commands.

**Files:**
- Modify: `gmloader-next/3rdparty/mfgpu/refmodel/blitter_ref.c` (+ its header) —
  handle `OP_STAGE` in the `blt_execute` command loop; route TRILIST texel reads
  through the modeled SDRAM region.
- Modify: `gmloader-next/gmloader/mister/raster_backend_test.cpp` — a case that
  emits STAGE+TRILIST and asserts ±1 LSB vs `backend_sw`.

**Interfaces:**
- Consumes: `OP_STAGE` opcode + control/ring layout; the modeled SDRAM buffer.
- Produces: a `blt_execute` that renders identically whether the source is read
  direct-from-heap (old) or staged-to-SDRAM-then-sampled (new).

- [ ] **Step 1: Failing test.** In `raster_backend_test.cpp`, add `case_stage_trilist`:
  stage an N×M texture via `blt_stage_surface` then draw it with `blt_trilist`,
  `blt_execute` into `fb565`, and assert `rgb565_within1` vs the `backend_sw` render
  of the same triangle+texture. Wire it into `main()`.
- [ ] **Step 2: Run to verify it fails.** `make -f Makefile.gmloader raster-backend-test`
  → the staged case mismatches (refmodel ignores STAGE / reads stale SDRAM).
- [ ] **Step 3: Model STAGE in `blitter_ref.c`.** In the `blt_execute` command walk,
  on `OP_STAGE` copy `size` bytes from `SRC_QW+ddr_off` (heap) into the modeled
  SDRAM buffer at `sdram_off`; make the TRILIST texel fetch read from that SDRAM
  buffer when `src_in_sdram`/`C_SRCSEL` indicates SDRAM. Keep the direct-heap path
  for rings without STAGE (backward compatible).
- [ ] **Step 4: Verify.** `make -f Makefile.gmloader raster-backend-test` → all cases
  pass, including `case_stage_trilist`. Then the armhf docker build — clean link.
- [ ] **Step 5: Commit.**
```bash
git add 3rdparty/mfgpu/refmodel/blitter_ref.c 3rdparty/mfgpu/refmodel/blitter_ref.h \
        gmloader/mister/raster_backend_test.cpp
git commit -m "refmodel: model BLT_OP_STAGE (DDR3->SDRAM) + SDRAM TRILIST sampling; host battery green"
```

---

## Task 3: `backend_mfgpu` emits STAGE + tracks SDRAM residency

**Goal:** The mfgpu backend stages each referenced texture page into SDRAM via
`BLT_OP_STAGE` before its TRILIST, and the persistent identity-keyed atlas cache
tracks SDRAM residency (skip re-STAGE on a hit). Host-validated by Task 2's refmodel.

**Files:**
- Modify: `gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp` — `stage_texture()`
  funnel emits `blt_stage_surface`; the cache entry records SDRAM residency;
  `blt_sdram_init`/`blt_sdram_regions_init` called once at init.
- Modify: `gmloader/mister/raster_backend_test.cpp` — a residency case (stage once,
  reuse across two draws → one STAGE emitted).

**Interfaces:**
- Consumes: `blt_stage_surface`, `blt_sdram_init`, the existing atlas cache.
- Produces: rings whose TRILISTs sample SDRAM-resident sources; `backend_mfgpu`
  behavior still ±1 LSB vs `backend_sw` under `blt_execute`.

- [ ] **Step 1: Failing test.** Add `case_sdram_residency`: draw texture K twice;
  assert exactly one `BLT_OP_STAGE` was emitted for K (add a STAGE-count test hook
  mirroring the existing `TestUploadCount()`), and both draws render ±1 LSB vs SW.
- [ ] **Step 2: Run to verify it fails.** `make -f Makefile.gmloader raster-backend-test`.
- [ ] **Step 3: Implement.** In `stage_texture()`: after ensuring the page is in the
  DDR heap, if not already SDRAM-resident, `blt_stage_surface(&g_e, &ref)` and mark
  the cache entry resident; on a resident hit, skip STAGE. Call `blt_sdram_init` (or
  `blt_sdram_regions_init`) once in `mf_init_once` with the SDRAM base/size from the
  core's map. Invalidation (Task from atlas work) also clears SDRAM residency.
- [ ] **Step 4: Verify.** `make -f Makefile.gmloader raster-backend-test` → all green
  incl. residency; armhf docker build clean.
- [ ] **Step 5: Commit.**
```bash
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_test.cpp
git commit -m "feat(mfgpu): emit BLT_OP_STAGE + track SDRAM residency in the atlas cache"
```

---

## Task 4: Device present path — publish to real DDR, doorbell, poll; drop `blt_execute`

**Goal:** On device, `backend_mfgpu` points the emitter's ring/heap at the mmap'd
`0x3B000000` DDR, and `present()` publishes the control block + doorbell and polls
`C_DONE` instead of running `blt_execute` on the A9. Host build path unchanged.

**Files:**
- Modify: `gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp` — a device DDR
  mapping (mirror `native_video_writer` open/mmap), MiSTer-macro-guarded; `present()`
  publish+doorbell+poll on device, `blt_execute`→`g_fb565` on host.
- Modify: `gmloader/main.cpp` (~575-596) — on device+mfgpu, `present()` already did
  the fabric submit; do NOT hand `g_fb565` to `NativeVideoWriter` (the core scans out
  `comp_fbram` itself). Guard so the SW path and host path are untouched.

**Interfaces:**
- Consumes: the DDR map + control-block offsets; `blt_end_frame`'s `submit_seq`.
- Produces: a device present that offloads rasterization to the fabric; `C_DONE`
  gates frame reuse.

- [ ] **Step 1: Device DDR mapping.** Add `mf_ddr_map()` (device-only): open
  `/dev/mem`, mmap `0x3B000000` size `0x01000000`; expose `ring_ptr`/`src_ptr`/
  `bltctrl_ptr`. In `mf_init_once` (device build), pass these to `blt_emitter_init`
  instead of `g_ring`/`g_srcdram`.
- [ ] **Step 2: Publish + doorbell + poll in `present()` (device).** After
  `blt_end_frame`: write `C_CMDCOUNT`/`C_TARGET`/`C_CLEAR`/`C_FLAGS` to `bltctrl_ptr`,
  barrier, write `C_SUBMIT=submit_seq` last; spin on `C_DONE==submit_seq` with a
  timeout (log + fall back to `backend_sw` for that frame on timeout). Remove the
  `blt_execute` call on the device path (keep it on host).
- [ ] **Step 3: main.cpp present branch.** On device+mfgpu, skip the
  `NativeVideoWriter_WriteFrame(fb565,…)` — the fabric already put the frame in
  `comp_fbram` and the core scans it out. Keep SW/host branches byte-identical.
- [ ] **Step 4: Host regression.** `make -f Makefile.gmloader raster-backend-test`
  (host still uses `blt_execute`) → all green. armhf docker build → clean link.
- [ ] **Step 5: On-device bring-up (controller-run).** Load Maldita RBF, deploy the
  new `gmloadernext.armhf`, run with `GMLOADER_RASTER=mfgpu`. Confirm: `C_DONE`
  advances (fabric consuming rings), no A9 `blt_execute` on the hot path, and MiSTer
  Remote shows a **fabric-rendered** frame. (#13 crash may abort ~1/5 launches —
  re-run.)
- [ ] **Step 6: Commit.**
```bash
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/main.cpp
git commit -m "feat(mfgpu): device present = publish ring + doorbell + poll C_DONE (fabric offload); drop A9 blt_execute"
```

---

## Task 5: 320×224 core timing + full-scene on-device verification

**Goal:** Fold the 320×224 scanout timing into the Maldita core and verify a real
Maldita scene renders on the fabric at the right geometry.

**Files:**
- Modify (`maldita.castilla-mister`): `fpga/rtl/openbor_video_timing.sv`
  (`V_ACTIVE=224, V_FP=2, V_SYNC=3, V_BP=33, V_TOTAL=262`; H unchanged) — the
  timing half of parked Task 2 only (NOT the reader DDR-offset; scanout reads
  `comp_fbram`). Reconcile `comp_fbram`'s render height with the visible 224 in the
  plan's Step 1 investigation.

**Interfaces:**
- Consumes: the working fabric-offload pipeline (Tasks 1-4).
- Produces: a Maldita RBF that scans out the fabric's frame at 320×224.

- [ ] **Step 1: Confirm compositor geometry.** Determine whether `comp_fbram`/the
  compositor renders 320×240 (crop to 224 in timing) or should render 224 directly;
  grep `comp_fbram`/`blitter_top` FB height (`FB_H`) and the snapshot path. Record
  the finding; if `FB_H` must change to 224, note it here (do not blindly edit).
- [ ] **Step 2: Apply the timing change** (values above). Update the header comment
  `320x240 → 320x224`.
- [ ] **Step 3: Build via CI.** Push the core branch; the self-hosted Windows Quartus
  runner builds `MalditaCastilla_*.rbf`. Confirm green build + clean STA (V_TOTAL/H
  unchanged → Fmax unaffected).
- [ ] **Step 4: Deploy + full-scene verify (controller-run).** Load the new RBF, run
  gmloader `GMLOADER_RASTER=mfgpu`, capture via MiSTer Remote. **Pass condition:** a
  recognizable Maldita scene, fabric-rendered, at 320×224 — including the 2048²
  sprite pages (SDRAM-staged, no longer dropped).
- [ ] **Step 5: Commit + bump.** Commit the core timing change; bump
  `external/gmloader-next` in `mister-gmloader` if that superproject tracks it.

---

## Self-Review

- **Spec coverage:** §1 gmloader DDR wiring → Tasks 1 (probe), 4 (production);
  §1 STAGE→SDRAM + residency → Tasks 2 (refmodel), 3 (emit+cache); §1 doorbell/poll,
  drop `blt_execute` → Task 4; §2 core minimal + 320×224 → Task 5; §3 refmodel → Task 2;
  §"first vertical slice" → Task 1. Success criteria 1-4 → Task 4 Step 5 (C_DONE, no
  blt_execute), Task 5 Step 4 (fabric scene, 2048² staged), Tasks 2-3 (±1 LSB battery),
  Global Constraint (`backend_sw` fallback).
- **Placeholder scan:** DDR addresses and control-block offsets are concrete
  (Global Constraints); the genuinely device-determined values (SDRAM base/size for
  `blt_sdram_init`, `comp_fbram` height) are called out as explicit investigation
  steps (Task 3 Step 3, Task 5 Step 1), not hand-waved into implementation code.
- **Type/name consistency:** `blt_stage_surface`, `blt_end_frame`, `submit_seq`,
  `C_SUBMIT`/`C_DONE`, `stage_texture()`, `mf_ddr_map`, `case_stage_trilist`,
  `case_sdram_residency` used consistently across tasks.
- **Risk ordering:** Task 1 (the on-hardware contract probe) is deliberately first
  and gated — if the RBF does not render an external ring, everything downstream is
  reconsidered before investment. The refmodel (Task 2) precedes the STAGE emission
  (Task 3) so that change is host-testable, not device-only.

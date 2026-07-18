# DDR3 Scanout — Custom Reader Pivot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:team-driven-development (RTL-heavy) or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Scan the fabric's composited frame out of a DDR3 double-buffer using the existing `openbor_video_reader` → `video_mixer`/VGA path (synchronous, TV-syncable), replacing the failed `ascal` `FB_EN` approach — so the app-surface fits (SCAN's 160 M10K freed) and the title screen renders on a signal the TV locks to.

**Architecture:** `comp_fb_dma` bursts WORK → a DDR3 double-buffer (control word + Buffer 0/1) at compositor vblank and flips `active_buffer`; a repointed `openbor_video_reader` streams the active buffer in raster order → `openbor_video_timing` → `VGA_*` (`VGA_SCALER=0`). Producer and consumer are decoupled by the double buffer — no `ascal`, no `FB_VBL`.

**Tech Stack:** SystemVerilog (Cyclone V, Quartus 17.0.2), Icarus sim, MiSTer framework video path (`video_mixer`/`video_freak`, no `ascal` FB), GitHub-Actions Windows RBF build, MiSTer device @ `192.168.20.81`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-17-maldita-ddr-scanout-framebuffer-design.md` (revised 2026-07-18: custom-reader pivot).
- **This plan supersedes the ascal path** in `docs/superpowers/plans/2026-07-17-maldita-ddr-scanout-framebuffer.md`. **Prerequisites already landed + reviewed:** Task 1 `comp_fb_dma` (`6bc693a`, byte-exact WORK→DDR raster DMA) and Task 2 SCAN + `openbor_video_top` instantiation removal (`c24ad41`, −160 M10K). **To revert:** the ascal Task 3 (`cdd8e29`) — its `FB_*`/`VGA_SCALER=1`/`MISTER_FB` changes are undone by Task 2 of *this* plan. The `openbor_video_reader.sv` / `openbor_video_timing.sv` / `openbor_video_top.sv` module files are **still in the tree** (only the top-level instantiation was removed) — reuse the reader + timing directly.
- **RTL-only, `fpga/`.** RTL specified by interface + datapath + TDD (project precedent), not final inline RTL. The emu top (`Maldita.sv`) cannot be iverilog-elaborated → the lead review is the elaboration gate before the RBF build.
- **DDR framebuffer layout (matches the reader's existing map, repointed):** base = a reserved slot at the top of the 16 MB blitter window `0x3B000000`, above the texture heap (host writes ≤ `0xF40000`). Control word @ `base+0x000` (`frame_counter[31:2]`, `active_buffer[1:0]`); Buffer 0 @ `base+0x040`; Buffer 1 @ `base+0x40040` (each 320×240×2 = 153,600 B RGB565). Fabric-internal (written by `comp_fb_dma`, read by the reader; host never touches it). Suggested base `0x3BF40000` (qword `0x077E8000`) — the ascal build's slot; confirm it still clears the heap and fits control+2×256 KB within the window.
- **Video path:** `VGA_SCALER=0`; the reader + `openbor_video_timing` drive `VGA_R/G/B/HS/VS/DE` via the existing Genesis H40 `ce_pix_gen` timing (the signal the TV synced to pre-ascal). No `ascal` FB, no `MISTER_FB`.
- **Fit:** M10K ≤ 553 (was 415 on the ascal build with SCAN freed; the reader's line-buffer is small — expect similar).
- **Build/test:** `export PATH="/opt/homebrew/bin:$PATH"`; sims `cd fpga/sim && ./run_sims.sh [tb]`. Pre-existing non-blocking: `tb_audio_burst_wedge` (`tb_scanout_fbram` already retired). RBF = GH-Actions Windows on push touching `fpga/**`; STA in `output_files/Maldita.sta.summary`. Device: `deploy.py --no-content`, `load_core`, `gmloader_diag.sh --preset fabric`, screenshots, `busybox devmem`.
- **Push policy:** local commits; lead pushes after review (user has standing push + device authorization for this work).

---

## Task 1: `comp_fb_dma` double-buffer + control word + compositor-vblank trigger

Extend the existing byte-exact DMA (`6bc693a`) from one buffer to the reader's double-buffer layout, and decouple its trigger from `ascal`.

**Files:**
- Modify: `fpga/rtl/comp_fb_dma.sv`
- Test: `fpga/sim/tb_fb_dma.sv`

**Interfaces:**
- Consumes (unchanged from Task 1): `work_rd_en`/`work_rd_qw[14:0]`/`work_rd_qword[63:0]`; `mem_wr`/`mem_addr[31:0]`(qword)/`mem_burstcnt[7:0]`/`mem_din[63:0]`/`mem_be[7:0]`/`mem_busy`; `start`; `busy`. `input [28:0] fb_qw_base` (the DDR qword base; was `fb_base_qw`).
- Produces: on each `start` (compositor vblank), (1) burst WORK (19200 qwords) → the **inactive** buffer at `fb_qw_base + (0x40>>3) + sel*(0x40000>>3)`, then (2) write the **control word** qword at `fb_qw_base + 0` = `{frame_counter[31:2], 2'b0 | sel}` (match the reader's `{frame_counter[31:2], active_buffer[1:0]}` layout — confirm bit packing against `openbor_video_reader.sv`), then (3) toggle `sel` and increment `frame_counter`. `busy` spans the whole sequence.

- [ ] **Step 1: Extend the failing bench.** In `tb_fb_dma.sv`, parameterize the DDR capture model to cover control word + both buffers. Add assertions across **two** `start` cycles: frame A writes Buffer 0 (`+0x40`) byte-exact + control word `active=0, frame_counter=N`; frame B writes Buffer 1 (`+0x40040`) byte-exact + control word `active=1, frame_counter=N+1`; neither frame writes the *other* buffer's region; the existing single-buffer byte-exactness (19200 qwords) holds per buffer.

```
// per frame f in {0,1}: buffer base = FB + 0x08 (qw) + f*(0x8000 qw)
for (qw=0; qw<19200; qw++) assert ddr[bufbase(f)+qw] === work_f[qw];
assert ddr[FB+0] === {frame_counter_f, f};   // control word after the buffer write
```

- [ ] **Step 2: Run, verify it fails.** `cd fpga/sim && ./run_sims.sh tb_fb_dma` → FAIL (single-buffer DUT writes one fixed buffer, no control word).

- [ ] **Step 3: Implement.** Add a 1-bit `sel` reg (reset 0) + a `frame_counter`; compute the buffer base from `sel`; after the 19200-qword copy, issue one more `mem_wr` to `fb_qw_base+0` with the packed control word; then toggle `sel` / bump `frame_counter`. Keep the Task-1 back-pressure discipline (`mem_wr` held until `~mem_busy`, single-outstanding read pipeline) unchanged. **Order matters:** the control-word write must land *after* the buffer write completes (so the reader never sees `active` point at a half-written buffer).

- [ ] **Step 4: Run, verify PASS.** `./run_sims.sh tb_fb_dma` → both frames byte-exact, control words correct, no cross-buffer writes, control-word-after-buffer ordering held.

- [ ] **Step 5: Full suite unregressed.** `./run_sims.sh` → surface + blitter benches green; only `tb_audio_burst_wedge` pre-existing-fails.

- [ ] **Step 6: Commit.**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git add fpga/rtl/comp_fb_dma.sv fpga/sim/tb_fb_dma.sv
git commit -m "rtl: comp_fb_dma double-buffer + control-word write (openbor reader layout)"
```

---

## Task 2: Revert ascal + wire the `openbor` reader (`Maldita.sv` + `.qsf`)

Undo the ascal integration and connect the repointed reader to the fabric framebuffer + the VGA path. This is the elaboration-gated emu-top integration.

**Files:**
- Modify: `fpga/Maldita.sv`, `fpga/Maldita.qsf`
- Modify (repoint base): `fpga/rtl/openbor_video_reader.sv` (base-address constants `29'h0740_0000…` → the fabric qword base) — or add a base parameter and set it from `Maldita.sv`.

**Interfaces:**
- Consumes: Task 1 `comp_fb_dma` (`fb_qw_base`, `start`=`fb_dma_start`, `busy`=`fb_dma_busy`, `mem_*`, `work_rd_*`); `blitter_top.fb_dma_start`/`fb_dma_busy` (`c24ad41`); the `ddr_blitter_arb` `rdr_*` (raw read/write master) + `blt_*` slots; `openbor_video_reader` (`ddr_*` master; `clk_vid`/`ce_pix`/`de`/`hblank`/`vblank`/`new_frame`/`new_line`/`vcount`; `r_out`/`g_out`/`b_out`/`frame_ready`; unused SDRAM `scan_*` → tie off) + `openbor_video_timing` (`ce_pix`→timing).
- Produces: `VGA_SCALER=0`; reader+timing → `VGA_R/G/B/HS/VS/DE` via `ce_pix_gen`; the `rdr_*` arbiter slot carrying reader **reads** (active display) and `comp_fb_dma` **writes** (vblank, `fb_dma_busy`); the ascal `FB_*`/`MISTER_FB` path removed.

- [ ] **Step 1: Revert the ascal drives.** In `Maldita.sv`: remove the Task-3 `assign FB_EN/FB_FORMAT/FB_WIDTH/FB_HEIGHT/FB_STRIDE/FB_BASE/FB_FORCE_BLANK` drives and the `VGA_SCALER=1`; restore `assign VGA_SCALER = 1'b0;`. In `Maldita.qsf`: remove `set_global_assignment -name VERILOG_MACRO "MISTER_FB=1"` (leave `MISTER_DISABLE_PALETTE1` as pre-Task-3). Tie the emu `FB_*` outputs to their disabled defaults (`FB_EN=0` etc.) as they were pre-ascal.

- [ ] **Step 2: Repoint the reader base.** In `openbor_video_reader.sv`, change the hardcoded control/buffer qword base (`29'h0740_0000` → `FB_QW_BASE`) so control word @ `FB_QW_BASE`, Buffer 0 @ `+0x08` qw (`+0x40` byte), Buffer 1 @ `+0x8008` qw (`+0x40040` byte). Prefer a `parameter [28:0] FB_QW_BASE` set from `Maldita.sv` over editing constants. Leave the reader's raster/prefetch/double-buffer logic otherwise unchanged.

- [ ] **Step 3: Instantiate reader + timing.** In `Maldita.sv`, instantiate `openbor_video_timing` (`.clk(CLK_VIDEO)`, `.ce_pix(ce_pix_gen)`, `.h_adj/.v_adj` from status as before) and `openbor_video_reader` (`.clk_vid(CLK_VIDEO)`, `.ce_pix(ce_pix_gen)`, timing inputs from the timing module, `ddr_*` → the `rdr_*` arbiter slot, `scan_*` tied off, `.fb_qw_base(FB_QW_BASE)`). Wire `r_out/g_out/b_out` + `hsync/vsync/de` → `VGA_R/G/B/HS/VS/DE` (via `video_mixer` if the pre-ascal core used it — check the pre-Task-2 `openbor_video_top` wiring; it drove `VGA_*` directly). Do **not** re-instantiate `openbor_video_top` (its audio/joystick/ioctl stays deferred).

- [ ] **Step 4: Wire the `rdr_*` read/write time-share.** The `rdr_*` slot carries `openbor_video_reader.ddr_*` (reads, during active display) and `comp_fb_dma.mem_*` (writes, during `fb_dma_busy` vblank). Mux: `rdr_addr/din/be/we/rd/burstcnt = fb_dma_busy ? comp_fb_dma.mem_* : reader.ddr_*`; route `rdr_busy`/`rdr_grant`/`ddram_dout_ready` back to whichever owns the slot. Double-buffering guarantees the reader (active buffer) and writer (inactive buffer) never touch the same bytes; the mux serializes f2h access. `comp_fb_dma.work_rd_*` → `comp_fbram` WORK `rd_*` (mux by `fb_dma_busy`, compositor idle in `S_SNAP_*`). Clean up the Task-3 comp_fb_dma-as-sole-rdr-writer wiring.

- [ ] **Step 5: Lead port/width review (elaboration gate).** Verify (grep, no `default_nettype none`): every reader/timing/`comp_fb_dma`/arbiter port connected, none dangling; `rdr_*` mux single-driver per net; no leftover `FB_EN`/`ascal`/`MISTER_FB` refs (except disabled ties); `VGA_SCALER=0`; `VGA_*` sourced from the reader/timing; `scan_*` tied off; base repoint consistent (`FB_QW_BASE` matches `comp_fb_dma.fb_qw_base`).

- [ ] **Step 6: Full suite (emu top not simmed).** `cd fpga/sim && ./run_sims.sh` → `tb_fb_dma` (Task 1) + surface + blitter benches green.

- [ ] **Step 7: Commit.**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git add fpga/Maldita.sv fpga/Maldita.qsf fpga/rtl/openbor_video_reader.sv
git commit -m "rtl: revert ascal, wire openbor DDR reader to fabric framebuffer (VGA_SCALER=0)"
```

---

## Task 3: RBF build + device bring-up (the real gate)

**Files:** none (build + deploy + observe). Lead-driven (user device priority).

**Interfaces:** Consumes Tasks 1–2.

- [ ] **Step 1: Push → RBF build.** `git push origin milestone-a`; `gh run list --workflow=build-rbf.yml --limit 2`; watch to completion.
- [ ] **Step 2: Fit + STA.** `gh run download <id> -n quartus-reports`; confirm **Fitter Successful, M10K ≤ 553**; read `Maldita.sta.summary` emu-clock slack (expect ≥ the ascal build's −0.557, likely healthier — no ascal FB-read path).
- [ ] **Step 3: Deploy.** `gh run download <id> -n maldita-rbf -D _Other` (delete any stale same-name local RBF first — same-day builds share `MalditaCastilla_YYYYMMDD.rbf`; verify the fresh sha1 differs); `./deploy.py --no-content`; verify on-device RBF sha1; `load_core`.
- [ ] **Step 4: Peek-verify the DDR frame FIRST (the isolation the pivot buys).** Launch `--preset fabric`; `busybox devmem <FB_BASE+0x40> 32` (Buffer 0) and `+0x40040` (Buffer 1) — confirm **coherent RGB565** (image structure / zeros / border colour), **not ARM code**; `devmem <FB_BASE>` control word `active_buffer` toggling + `frame_counter` climbing. This proves `comp_fb_dma` writes before trusting the reader.
- [ ] **Step 5: Confirm display.** `C_SUBMIT` climbs / `C_DONE` tracks; **TV syncs**; two screenshots ~15 s apart differ (animating) and reach a coherent **Cursed Castilla title screen** — centre fills in (app-surface displayed), not noise/black; tear-free; no stale-frame blank. Heap still fits (sub-region intact).
- [ ] **Step 6: Record + commit device notes; update the ledger.**

```bash
git add -A && git commit -m "deploy: DDR custom-reader scanout verified on device (fits, TV syncs, title renders)"
```

**Definition of done:** RBF fits (M10K ≤ 553); DDR buffers hold coherent RGB565 frames (peek-verified); TV syncs; title screen renders + animates + tear-free; host sub-region heap still fits.

---

## Task 4: (Contingent) app-surface UV scale fix — host

Only if Task 3 shows the surface displayed but **scaled/offset** (the latent 288×216-in-512×256 vs RTL fixed-320×240 bug). Host-side, `impl-engine`. Unchanged from the prior plan: capture the real device sample UVs, write a failing parity test for the corrected `src_is_appsurf` UV scale, implement, re-verify on device. Also fold in the sub-region pin-drop `g_upload_count`/`g_stage_count` over-count minor if trivial.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
# after fix:
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_test.cpp
git commit -m "mfgpu: scale app-surface (SRC_SURFACE) UVs by used 288x216 region to match RTL fixed-surface sample"
```

---

## Self-review

- **Spec coverage:** pivot rationale (spec §Revision) → this plan's premise. Custom-reader approach (§Chosen approach) → Task 2. `comp_fb_dma` double-buffer + control word + compositor-vblank trigger (§Components, §Architecture) → Task 1. Reader repoint + VGA path + revert ascal (§Components, §Video-path) → Task 2. DDR double-buffer layout (§placement) → Global Constraints + Tasks 1–2. Verification: `tb_fb_dma` double-buffer (§Verification sim) → Task 1; peek-verify + TV-sync + title (§Verification device) → Task 3. Risks: `rdr_*` time-share (§risks) → Task 2 Step 4 + Task 3 Step 5; latent UV (§risks) → Task 4; STA (§risks) → Task 3 Step 2. All mapped.
- **Placeholder scan:** RTL bodies are interface+datapath+TDD per precedent; the one open item (exact `rdr_*` mux + whether `video_mixer` sits in the reader→VGA path) is resolved by reading the pre-Task-2 `openbor_video_top` wiring, named in Task 2 Step 3.
- **Type consistency:** `fb_qw_base`/`fb_dma_start`/`fb_dma_busy`/`FB_QW_BASE` named consistently across Tasks 1–2; buffer offsets (`+0x40`/`+0x40040` byte = `+0x08`/`+0x8008` qw) consistent between `comp_fb_dma` (Task 1) and the reader repoint (Task 2).
- **Ordering:** Task 1 (sim-gated) → Task 2 (integration, elaboration-gated) → Task 3 (combined build/device) → Task 4 contingent.

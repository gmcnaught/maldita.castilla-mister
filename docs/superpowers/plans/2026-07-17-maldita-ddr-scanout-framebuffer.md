# DDR3 Scanout Framebuffer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:team-driven-development (RTL-heavy, file-partitionable) or superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Move the composited-frame **scanout** off-chip — `blitter_top` burst-copies the WORK framebuffer to a DDR3 buffer at vblank, and the MiSTer framework's `ascal` scans it out (triple-buffered) — freeing the 160 M10K of the on-chip SCAN buffer so the app-surface BRAM (`surf_*`, `2a78462`) fits and the title screen renders.

**Architecture:** Host-transparent, RTL-only in `fpga/`. A new `comp_fb_dma` reads WORK in raster order and bursts RGB565 into a reserved DDR framebuffer via the existing `arb_ddr_*` f2h arbiter; `Maldita.sv` drives `FB_EN`/`FB_*` + `VGA_SCALER=1` + `lowlat=0` and deletes the custom `openbor` scanout + SCAN banks. Render targets (WORK, SURFACE) stay in BRAM.

**Tech Stack:** SystemVerilog (Cyclone V, Quartus 17.0.2), Icarus sim (`fpga/sim/run_sims.sh`), MiSTer framework `sys/ascal.vhd` + `sys/sys_top.v`, GitHub-Actions Windows RBF build, MiSTer device @ `192.168.20.81`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-17-maldita-ddr-scanout-framebuffer-design.md`.
- **RTL-only, `fpga/`:** no host/protocol/reference-model change. The sub-region residency work (Tasks 1–3, on device) and `gmloader-next` are untouched **except** the contingent Task 5 UV follow-up.
- **RTL specified by interface + datapath + TDD, not final inline RTL** (project precedent — see `.superpowers/sdd/progress.md`). A strict reviewer may flag "no complete code"; that is intentional for the HDL-datapath tasks. Exact signal/port names are given; the FSM/datapath body is tuned against the sim.
- **The emu top (`Maldita.sv`) cannot be iverilog-elaborated** (framework `` `BUILD_DATE `` macro + `'{}` array syntax). Port/integration correctness is gated by grep/width comparison + reviewer + the RBF build, **not** sim. The lead review IS the elaboration gate (a wrong port name fails only at Quartus, ~12 min in).
- **Fit is the primary gate:** target M10K ≤ 553 (currently 620 with SCAN). Removing SCAN (`sbank0-3`, 160 M10K) is what makes room.
- **FB register values (from spec):** `FB_EN=1`, `FB_FORMAT=5'b00100` (16bpp RGB565), `FB_WIDTH=320`, `FB_HEIGHT=240`, `FB_STRIDE=640` (bytes), `VGA_SCALER=1`, `lowlat=0` (triple-buffer). DDR framebuffer = a reserved ≤512 KB slot inside the 16 MB blitter window (`0x3B000000`), non-overlapping the control block (`+0x00`), ring (`+0x40`), or texture heap (`+0x80000`). The framebuffer is **fabric-internal** (written by `blitter_top`, read by `ascal`; the host never touches it).
- **Build/test:** `export PATH="/opt/homebrew/bin:$PATH"`; sims `cd fpga/sim && ./run_sims.sh [tb]`. Pre-existing non-blocking sim failures: `tb_audio_burst_wedge` and `tb_scanout_fbram` (the latter is **retired by this plan** — it tests the deleted scan path). RBF build = GitHub Actions Windows runner on push touching `fpga/**`; STA in `output_files/Maldita.sta.summary`. Device: `deploy.py`, `load_core` via `/dev/MiSTer_cmd`, `gmloader_diag.sh --preset fabric`, screenshots, `busybox devmem 0x3B000000 32`.
- **Push policy:** local commits only; the lead pushes (which triggers the RBF build) after review, per user go.
- **Combined RBF:** Tasks 1–3 all land, then a single build (Task 4). There is no fitting intermediate RBF (fit needs SCAN gone AND the FB path live), matching the spec's one-build decision.

---

## Task 1: WORK→DDR framebuffer burst-DMA (`comp_fb_dma`)

Extract the vblank copy into a focused module that reads WORK in raster order and bursts RGB565 to DDR, replacing the WORK→SCAN(BRAM) snapshot. This is the one genuinely sim-able unit and the core new logic.

**Files:**
- Create: `fpga/rtl/comp_fb_dma.sv`
- Test: `fpga/sim/tb_fb_dma.sv`, `fpga/sim/tb_fb_dma.mk` (mirror an existing `tb_*.mk`)
- Modify (wiring only, Task 3 integrates): none yet — sim instantiates `comp_fb_dma` standalone.

**Interfaces:**
- Consumes: a WORK read port — `output work_rd_en; output [14:0] work_rd_qw; input [63:0] work_rd_qword` (same shape as `comp_fbram`'s `rd_*` / snapshot read: 19200 qwords, 4 px/qword RGB565, lane0=leftmost). A DDR write master mirroring `blitter_top`'s existing `mem_*`: `output mem_wr; output [AW-1:0] mem_addr (qword addr); output [7:0] mem_burstcnt; output [63:0] mem_din; output [7:0] mem_be; input mem_busy`. A `start` pulse (vblank) and `input fb_base_qw` (DDR qword base of the framebuffer). `input vs` / `output busy`.
- Produces: on `start`, walks WORK qw `0..19199`, writes each 64-bit qword (4 RGB565 px) to `mem_addr = fb_base_qw + qw`, respecting `mem_busy` (stall) and issuing power-of-2 bursts; asserts `busy` until the 19200-qword copy completes. Byte/lane order identical to how `ascal` reads `FB_FORMAT=5'b00100` at `FB_STRIDE=640` (row = 320 px = 80 qwords; 240 rows = 19200 qwords; linear, stride-640 == 80 qwords/row contiguous).

- [ ] **Step 1: Write the failing byte-correctness bench.** In `tb_fb_dma.sv`: instantiate `comp_fb_dma`; back the `work_rd_*` port with a behavioral RAM preloaded with a distinctive pattern (`work[qw] = {qw*4+3, qw*4+2, qw*4+1, qw*4+0}` as four RGB565 lanes); back the `mem_*` master with a DDR capture model (array indexed by `mem_addr`, with a scripted `mem_busy` toggle to prove stall handling); pulse `start`; wait for `!busy`; assert **every** captured DDR qword at `fb_base_qw+qw` equals `work[qw]` for all 19200, and that no write landed outside `[fb_base_qw, fb_base_qw+19200)`.

```
// assertion core (pseudocode)
for (qw = 0; qw < 19200; qw++)
  if (ddr_capture[fb_base_qw + qw] !== work_ram[qw]) begin bad++; end
if (bad != 0) $fatal;
```

- [ ] **Step 2: Run it, verify it fails.**

Run: `cd fpga/sim && export PATH="/opt/homebrew/bin:$PATH" && ./run_sims.sh tb_fb_dma`
Expected: FAIL — `comp_fb_dma` undefined / no DDR writes captured.

- [ ] **Step 3: Implement `comp_fb_dma.sv`.** Datapath: an FSM that on `start` iterates `qw=0..19199`, reads `work_rd_qword` (1-cycle BRAM latency — pipeline the read address vs the write), drives `mem_wr`/`mem_addr=fb_base_qw+qw`/`mem_din=work_rd_qword`/`mem_be=8'hFF`/`mem_burstcnt` (start with `1`; a power-of-2 run is a later optimization), stalling the walk whenever `mem_busy`. Assert `busy` from `start` to the final accepted write. Match `blitter_top`'s existing `mem_*` write discipline (drop `mem_wr` between accepted beats under `mem_busy`) — reuse the idiom at `blitter_top.sv` around the `mem_*`/`p_mem_*` master and the `ddram_busy` back-pressure comments (`blitter_top.sv:~246-261,1448`).

- [ ] **Step 4: Run the bench, verify PASS.**

Run: `cd fpga/sim && ./run_sims.sh tb_fb_dma`
Expected: PASS — all 19200 qwords byte-exact, no out-of-range writes, stalls honored.

- [ ] **Step 5: Full suite unregressed.**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: existing benches unchanged (new module not yet wired into `blitter_top`/`Maldita.sv`); pre-existing fails only (`tb_audio_burst_wedge`, `tb_scanout_fbram`).

- [ ] **Step 6: Commit.**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git add fpga/rtl/comp_fb_dma.sv fpga/sim/tb_fb_dma.sv fpga/sim/tb_fb_dma.mk
git commit -m "rtl: comp_fb_dma — vblank WORK->DDR framebuffer raster burst DMA + tb_fb_dma"
```

---

## Task 2: Remove SCAN buffer + custom scanout (the −160 M10K)

Delete the on-chip SCAN framebuffer and the `openbor` scanout it fed, and update benches. This is what makes the design fit.

**Files:**
- Modify: `fpga/rtl/comp_fbram.sv` (drop `sbank0-3` + the `snap_*` write port + the `scan_rd_*` port that served scanout; keep WORK `bank0-3` + SURFACE `surf_*`)
- Modify: `fpga/Maldita.sv` (delete `openbor_video_top native_video`, `fbram_scan_adapter u_fbram_scan`, the `scn_*` wires, the stale-frame watchdog, and the `fb_snap_*` / SCAN wiring on `comp_fbram`/`blitter_top`)
- Modify: `fpga/rtl/blitter_top.sv` (remove the `fb_snap_we/qw/qword` output port + the `u_snap` WORK→SCAN instance; the S_SNAP_* FSM now triggers `comp_fb_dma.start` instead — the trigger stays, the target changes)
- Modify/retire tests: `fpga/sim/tb_scanout_fbram.*` (retire — tests the deleted scan path); any bench instantiating `comp_fbram` updated for the reduced port list; `tb_surfram`, `tb_blitter_surface_src`, `tb_blitter_system_pipe` must stay green.

**Interfaces:**
- Consumes: Task 1's `comp_fb_dma` (its `start`/`busy`/`work_rd_*` replace `u_snap`).
- Produces: a `comp_fbram` with exactly two framebuffers (WORK + SURFACE); a `blitter_top` whose vblank FSM pulses `comp_fb_dma.start` (via a `fb_dma_start`/`fb_dma_busy` handshake) instead of `snap_start`/`snap_busy`; `Maldita.sv` with the custom scanout removed.

- [ ] **Step 1: Retire the scan bench + adjust `comp_fbram` benches.** Delete/rename `fpga/sim/tb_scanout_fbram.*`; remove it from `run_sims.sh`'s list. In every remaining bench that instantiates `comp_fbram`, delete the `sbank`/`scan_rd_*`/`snap_*` port connections (leave WORK + `surf_*`).

- [ ] **Step 2: Run the surface + core benches, verify they still pass BEFORE editing RTL** (baseline).

Run: `cd fpga/sim && ./run_sims.sh tb_surfram && ./run_sims.sh tb_blitter_surface_src`
Expected: PASS (pre-change baseline).

- [ ] **Step 3: Edit `comp_fbram.sv`.** Remove the `sbank0-3` `altsyncram` instances, the `snap_we/qw/qword` input port + its write logic, and the `scan_rd_en/qw/qword` port + its read mux. Keep `bank0-3` (WORK), `surf_bank0-3` (SURFACE), and their `wr_*`/`rd_*`/`surf_*` ports. Update the header comment.

- [ ] **Step 4: Edit `blitter_top.sv`.** Remove the `fb_snap_*` output ports and the `u_snap` (`fbram_snapshot`) instance + `snap_busy/snap_rd_*/snap_start` plumbing. Rename the S_SNAP_* handshake to drive a new `output fb_dma_start` + `input fb_dma_busy` (the FSM sequence — `S_SNAP_WAIT`(vs_rise)→pulse→wait-busy→wait-`!busy` — is unchanged; only the target module changes). Keep `input vs`.

- [ ] **Step 5: Edit `Maldita.sv`.** Delete `openbor_video_top native_video`, `fbram_scan_adapter u_fbram_scan`, the `scn_addr/scn_rd/scn_dout/scn_ok` wires, the stale-frame watchdog logic, the `fb_snap_*` wires, and the `comp_fbram` `snap_*`/`scan_rd_*` connections. (FB integration is Task 3 — after this step the core has no scanout driver yet; that is fine, sim doesn't exercise the emu top and the device gate is Task 4.)

- [ ] **Step 6: Run the full suite.**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: surface + blitter benches green; `tb_scanout_fbram` gone; only `tb_audio_burst_wedge` pre-existing-fails. Confirm `grep -n "sbank\|scan_rd\|snap_\|openbor\|fbram_scan" fpga/rtl/comp_fbram.sv fpga/Maldita.sv` shows the scan path removed.

- [ ] **Step 7: Commit.**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git add fpga/rtl/comp_fbram.sv fpga/rtl/blitter_top.sv fpga/Maldita.sv fpga/sim/
git commit -m "rtl: remove SCAN buffer + openbor scanout (−160 M10K); vblank FSM drives comp_fb_dma"
```

---

## Task 3: `Maldita.sv` FB integration (`FB_EN`/`ascal` + DMA writer client)

Wire `comp_fb_dma` into the DDR arbiter at the reserved framebuffer address and drive the framework framebuffer path.

**Files:**
- Modify: `fpga/Maldita.sv` (instantiate `comp_fb_dma`; add it as an `arb_ddr_*` client; drive `FB_*` regs, `VGA_SCALER`, `lowlat`; DDR address-map constant; `FB_VBL` handshake; crop/aspect; `CLK_VIDEO`/`CE_PIXEL` retention)

**Interfaces:**
- Consumes: Task 1 `comp_fb_dma` (`start`/`busy`/`work_rd_*`/`mem_*`/`fb_base_qw`); Task 2's `blitter_top.fb_dma_start`/`fb_dma_busy`; the existing `arb_ddr_*` arbiter (`arb_ddr_burstcnt/addr/rd/din/be/we`, `blt_*`/`rdr_*` grant/busy) and the `DDRAM_*` f2h port; `comp_fbram`'s WORK `rd_*` port.
- Produces: a fitting, functional emu top: `assign FB_EN=1; FB_FORMAT=5'b00100; FB_WIDTH=12'd320; FB_HEIGHT=12'd240; FB_STRIDE=14'd640; FB_BASE=<byte addr of reserved slot>; assign VGA_SCALER=1;` with `lowlat`/`FB_VBL` wired; `comp_fb_dma` as a DDR write client; the reader-side arbiter (`use_nv`/`rdr_*`) removed or repurposed (the video reader is gone — the DMA writer takes an arbiter master slot).

- [ ] **Step 1: Define the DDR framebuffer address map.** Add a localparam block: `localparam [28:0] FB_QW_BASE = <ring/heap-clear slot>;` and `localparam [31:0] FB_BYTE_BASE = {FB_QW_BASE,3'b0} | 32'h... ;` matching the fabric DDR window base (`0x3B000000`). Place the ≤512 KB slot so it does not overlap control block/ring/heap. Document the byte range in a comment and confirm it is disjoint from the host texture-heap region (`+0x80000 .. +0x80000+MF_DEV_SRC_CAP`). Prefer a slot the host never allocates (either below the ring padding or above the heap within the 16 MB window); if none fits without shrinking the heap, note the host-constant trim as a Task-5 dependency.

- [ ] **Step 2: Instantiate `comp_fb_dma` + wire the arbiter client.** Connect `comp_fb_dma.work_rd_*` to `comp_fbram`'s WORK `rd_*` port (arbitrated with the compositor's own WORK reads — the DMA runs only at vblank when compositing is idle), `comp_fb_dma.mem_*` as a write master into the DDR arbiter (reuse the freed reader slot or add a master), `.fb_base_qw(FB_QW_BASE)`, `.start(fb_dma_start)`, `.busy(fb_dma_busy)`, `.vs(<scanout vblank>)`. Feed `fb_dma_start`/`fb_dma_busy` to/from `blitter_top`.

- [ ] **Step 3: Drive the framework FB path.** `assign FB_EN = 1'b1; assign FB_FORMAT = 5'b00100; assign FB_WIDTH = 12'd320; assign FB_HEIGHT = 12'd240; assign FB_STRIDE = 14'd640; assign FB_BASE = FB_BYTE_BASE; assign FB_FORCE_BLANK = 1'b0; assign VGA_SCALER = 1'b1;`. Remove the old `assign VGA_SCALER = 0;`. Wire `FB_VBL` (input) into the `comp_fb_dma`/FSM swap timing per the framework contract (verify: single fixed `FB_BASE` under `ascal` triple-buffer, vs. `FB_VBL`-gated writes — check `sys/ascal.vhd` triple-buffer + a reference triple-buffered core; the writer must not race `ascal`'s read of the same buffer). Retain `CLK_VIDEO`/`CE_PIXEL` only as the framework still requires under `FB_EN`.

- [ ] **Step 4: Crop/aspect.** The 320×224 crop (`status[18]`, was `video_freak`) no longer sits on the analog path. Initial approach: present the full 320×240 frame (`FB_HEIGHT=240`) and let the existing `VIDEO_ARX/ARY` reporting drive the framework HDMI scale; if the crop regresses on device (Task 4), switch to `FB_HEIGHT=224` + adjust `FB_BASE`/aspect. Leave a comment marking this as the device-confirmed decision point.

- [ ] **Step 5: Lead port/width review (the elaboration gate).** Since `Maldita.sv` can't be iverilog-elaborated, the reviewer verifies port-by-port: every new signal declared with correct width; every `comp_fb_dma`/`comp_fbram`/arbiter port connected, none dangling; `FB_*` widths match the emu port declarations (`FB_WIDTH[11:0]`, `FB_STRIDE[13:0]`, `FB_BASE[31:0]`, `FB_FORMAT[4:0]`); single-driver/single-reader on the new arbiter client; no leftover `scn_*`/`openbor`/`snap_*` references.

- [ ] **Step 6: Full suite (sanity — emu top not simmed).**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: surface + blitter benches green (Task-2 state preserved); `tb_fb_dma` green. Confirm `grep -nE "FB_EN|VGA_SCALER|comp_fb_dma" fpga/Maldita.sv` shows the new wiring.

- [ ] **Step 7: Commit.**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git add fpga/Maldita.sv
git commit -m "rtl: FB_EN/ascal scanout — DDR framebuffer + comp_fb_dma arbiter client, delete VGA_SCALER=0 path"
```

---

## Task 4: RBF build + STA + device bring-up (the real gate)

Combined build; confirm it fits, closes STA acceptably, and the title screen renders tear-free.

**Files:** none (build + deploy + observe).

**Interfaces:** Consumes Tasks 1–3.

- [ ] **Step 1: Push to trigger the RBF build** (lead, on user go — push policy). `git push origin milestone-a`; find the run: `gh run list --workflow=build-rbf.yml --limit 3`.

- [ ] **Step 2: Confirm FIT.** On completion: `gh run download <id> -n quartus-reports -D _reports`; read `output_files/Maldita.fit.summary`. Expected: **Fitter Status: Successful**, **M10K ≤ 553** (was 620 with SCAN; expect ~460). If it still overflows, stop and reassess (SCAN removal insufficient / SURFACE larger than modeled).

- [ ] **Step 3: Check STA.** `output_files/Maldita.sta.summary` — the `emu` clock slack. Expect **improved vs the −0.017 baseline** (SCAN + `openbor` removed = less congestion). Record; a small negative on the fragile `emu`/`pll_hdmi` path is acceptable per project history (degrades gracefully).

- [ ] **Step 4: Deploy the RBF** (RTL changed; engine unchanged). `gh run download <id> -n maldita-rbf -D _Other`; `./deploy.py --no-content`; `echo "load_core /media/fat/_Other/MalditaCastilla_YYYYMMDD.rbf" > /dev/MiSTer_cmd` on the device.

- [ ] **Step 5: Bring-up + observe.** Launch `gmloader_diag.sh --preset fabric` (HEAPLOG on). Confirm: `busybox devmem 0x3B000000 32` (C_SUBMIT) climbing + C_DONE (`+0x28`) tracking; heap still fits (sub-region work intact); two screenshots ~15 s apart with **different MD5s** (animating), reaching a coherent **Cursed Castilla title screen** — the **centre fills in** (app-surface now displayed via the connected `surf_*` + working scanout), not black; no stale-frame blank; no tearing.

- [ ] **Step 6: Record + commit device notes; update the ledger.**

```bash
git add -A && git commit -m "deploy: DDR scanout framebuffer verified on device (fits, title screen renders)"
```

**Definition of done:** RBF fits (M10K ≤ 553); on device the title screen renders (centre no longer black), screenshots animate, tear-free, no watchdog blank; host sub-region heap still fits; sim `tb_fb_dma` byte-exact + surface benches green.

---

## Task 5: (Contingent) app-surface UV scale fix — host

Only if Task 4 shows the surface content displayed but **scaled/offset** (the latent bug the overflow previously masked): the app-surface is a 288×216 render inside a 512×256 GL texture, but the RTL samples a fixed 320×240 surface. This is host-side.

**Files:**
- Modify: `gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp` (`src_is_appsurf` UV scale)
- Test: `gmloader-next/gmloader/mister/raster_backend_test.cpp`

**Interfaces:**
- Consumes: the working scanout (Task 4). Produces: the `src_is_appsurf` sample path scales UVs by the app-surface's **used** region (~288×216) instead of the raw bound-tex dims (512×256), matching the RTL fixed-surface clamp.

- [ ] **Step 1: Capture the real device geometry first.** With Task-4's RBF up, log the `draw#N+1` app-surface sample UVs (the sample-back draw) via HEAPLOG/framegraph; do not guess the scale. Confirm whether the render appears scaled or offset and by how much.
- [ ] **Step 2: Write a failing parity test** for the corrected `src_is_appsurf` UV→pixel mapping against the intended geometry (bit-exact vs the RTL fixed-320×240 sample for a known app-surface draw).
- [ ] **Step 3: Run, verify it fails.** `cd gmloader-next && make -f Makefile.gmloader raster-backend-test && ./<binary>`.
- [ ] **Step 4: Implement the UV-scale fix** in `src_is_appsurf`. Also fold in the Task-3 (sub-region) minor: pin-drop `g_upload_count`/`g_stage_count` over-count, if trivial.
- [ ] **Step 5: Run, verify PASS + suite green; build armhf; redeploy engine (`deploy.py --engine-only`); re-verify title screen unscaled.**
- [ ] **Step 6: Commit.**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_test.cpp
git commit -m "mfgpu: scale app-surface (SRC_SURFACE) UVs by used 288x216 region to match RTL fixed-surface sample"
```

---

## Self-review

- **Spec coverage:** insight/idiom (spec §insight/validation) → design intent, no task. Architecture+data flow (§arch) → Tasks 1–3. `comp_fbram` SCAN removal (§components) → Task 2. `blitter_top` WORK→DDR writer (§components) → Tasks 1–2. `Maldita.sv` FB regs + deletes (§components) → Tasks 2–3. DDR placement (§placement) → Task 3 Step 1. Video-path crop/CE_PIXEL (§video) → Task 3 Steps 3–4. Verification (§verification): `tb_fb_dma` byte-correctness → Task 1; sim updates → Task 2; device fit/title/tear-free → Task 4. Risks (§risks): `FB_VBL` handshake → Task 3 Step 3; latent UV → Task 5; STA → Task 4 Step 3. All spec sections map to a task.
- **Placeholder scan:** RTL bodies are intentionally interface+datapath+TDD-specified (declared pre-flight, project precedent), not "TODO"; the one genuine deferral (crop full-vs-224, FB address slot) has an explicit initial choice + device decision point.
- **Type consistency:** `comp_fb_dma` ports (`work_rd_*`, `mem_*`, `fb_base_qw`, `start`/`busy`) are named identically across Tasks 1–3; `fb_dma_start`/`fb_dma_busy` handshake consistent between `blitter_top` (Task 2) and `Maldita.sv` (Task 3); `FB_*` widths match the emu port declarations.
- **Ordering:** Tasks 1–3 land together (no fitting intermediate RBF); Task 4 is the combined build/device gate; Task 5 is contingent on Task 4's observation.

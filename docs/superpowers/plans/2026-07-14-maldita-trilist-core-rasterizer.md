# Maldita TRILIST Fabric Rasterizer (Phase 1d) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire a perf-optimal `OP_TRILIST` triangle rasterizer into the Maldita core's `blitter_top`, renumber the opcode off the `BGPLANE_WRITE=8` collision, and remove the 5 Solarus-legacy opcodes — so the fabric rasterizes gmloader's GLES triangles into `comp_fbram` at ≥30 fps (target 60).

**Architecture:** A new incremental triangle front-end (reciprocal-area setup once/triangle, then per-pixel adds — replacing `blt_tri.sv`'s six per-pixel divides) drives `blt_tri`'s kept combinational **blend** core, feeding the *reused* on-chip backend: SDRAM texels via the `P_SRC` cache port, RMW into on-chip `comp_fbram`. The triangle FSM is a third bus owner (`tri_busy`) alongside `comp_pipeline`. Textures are pre-loaded into SDRAM in simulation; the on-device STAGE path is a cross-plan dependency (offload plan Task 3).

**Tech Stack:** SystemVerilog (Maldita `fpga/rtl`), Icarus Verilog `iverilog -g2012` + `vvp` sim (`fpga/sim/run_sims.sh`), C golden model (`blt_tri.c`), Quartus Lite 17.0 RBF build on a self-hosted Windows CI runner, cross-repo ABI in `mister-fpga-blitter`.

## Global Constraints

- **Opcode map after this change:** `OP_NOP=0, OP_END=1, OP_FILL=2, OP_BLIT=3, OP_STAGE=4, OP_TRILIST=10`. Opcodes 5–9 (TILELIST/TILELIST_RES/FRT_UPLOAD/BGPLANE_WRITE/CLUT_UPLOAD) are **removed**.
- **`OP_TRILIST = 10`** — a free slot above the retained ops; the collision with `BGPLANE_WRITE=8` is resolved by renumbering, not by the removal.
- **Verification tolerance:** RTL composited output must match the `blt_tri.c` golden **within ±1 LSB per RGB565 channel** (the project's accepted oracle tolerance).
- **Blend modes to support (only these — YAGNI):** `COPY(0)`, `COLORKEY(1)`, `CONST_ALPHA(2)` (rides per-vertex alpha), `ADD(4)`. Not PALPHA, MULTIPLY, color-mod-tint.
- **Texture format:** RGB565 nearest only; vertex color modulates the texel.
- **Keep the shared render datapath** (`comp_pipeline`/`comp_mixer`/`comp_fbram`/`comp_span_setup`/`comp_src_linebuf`/`sdram_fb_cache` ch1 STAGE + ch5 P_SRC + the STAGE FSM + snapshot). Removal touches only the 5 Castilla ops' FSMs/regs/submodules/testbenches.
- **`comp_mixer` blend reuse is gated** on a proven ±1 LSB equivalence to `blt_tri.c` (Task 6 spike). Default is `blt_tri`'s own blend.
- **Sim pass marker:** a testbench prints `RESULT: PASS` and no `FAIL`/`TIMEOUT`; run via `cd fpga/sim && ./run_sims.sh tb_<name>`.
- **CI:** pushing a branch that touches `fpga/**` (excluding `fpga/sim/**`) triggers `.github/workflows/build-rbf.yml` on the self-hosted Windows runner; artifact `maldita-rbf` = `_Other/MalditaCastilla_*.rbf`.
- **Repos:** core RTL in `maldita.castilla-mister` (branch `milestone-a`); ABI renumber in `mister-fpga-blitter` (submodule-synced into `gmloader-next/3rdparty/mfgpu`).

---

## Task 1: Renumber `OP_TRILIST` 8 → 10 (cross-repo ABI)

**Goal:** Break the opcode-8 collision at the source of truth before any RTL. gmloader's consumer uses the `BLT_OP_*` symbol (no literal), so this is a small, symbol-clean change; the host battery proves it.

**Files:**
- Modify: `mister-fpga-blitter/refmodel/blitter_ref.h:88` (canonical enum)
- Modify: `mister-fpga-blitter/refmodel/test_blitter_ref.c:223` (`== 8` assert)
- Modify: `mister-fpga-blitter/host/blt_wire.h:97` (wire-doc comment)
- Modify: `mister-gmloader/external/gmloader-next/3rdparty/mfgpu/...` (submodule pointer bump after the above)
- Test: `mister-fpga-blitter/refmodel/test_blitter_ref.c` (runs the assert)

**Interfaces:**
- Produces: `BLT_OP_TRILIST == 10` everywhere host + refmodel; unchanged host emitter API (`blt_trilist`, `blt_push_tris`).

- [ ] **Step 1: Update the failing assert first (it is the test).** In `mister-fpga-blitter/refmodel/test_blitter_ref.c:223` change `assert(BLT_OP_TRILIST == 8);` → `assert(BLT_OP_TRILIST == 10);`

- [ ] **Step 2: Run it to verify it now fails** (enum still 8):

Run: `cd mister-fpga-blitter && make -C refmodel test_blitter_ref && ./refmodel/test_blitter_ref`
Expected: FAIL — `Assertion 'BLT_OP_TRILIST == 10' failed`.

- [ ] **Step 3: Renumber the enum + doc comment.** In `refmodel/blitter_ref.h:88` change `BLT_OP_TRILIST = 8` → `BLT_OP_TRILIST = 10`. In `host/blt_wire.h:97` change the comment `opcode = BLT_OP_TRILIST (8)` → `(10)`.

- [ ] **Step 4: Run the refmodel + emitter round-trip battery:**

Run: `cd mister-fpga-blitter && make -C refmodel test_blitter_ref && ./refmodel/test_blitter_ref && make -C host test_emitter && ./host/test_emitter`
Expected: both print their PASS lines (TRILIST round-trip encodes/decodes opcode 10).

- [ ] **Step 5: Host oracle regression in gmloader** (uses the symbol, must stay green):

Run: `cd mister-gmloader/external/gmloader-next && /opt/homebrew/bin/docker run --rm -v "$(pwd):/src" -w /src gmloader-armhf-build:bullseye bash -lc 'make -f Makefile.gmloader raster-backend-test && ./raster-backend-test'`
Expected: all cases PASS (no numeric-literal `8` on the gmloader side; symbol resolves to 10).

- [ ] **Step 6: Bump the submodule pointer + commit.**

```bash
cd mister-fpga-blitter && git add refmodel/blitter_ref.h refmodel/test_blitter_ref.c host/blt_wire.h && \
  git commit -m "abi: renumber BLT_OP_TRILIST 8->10 (deconflict device BGPLANE_WRITE=8)"
cd ../mister-gmloader/external/gmloader-next && git add 3rdparty/mfgpu && \
  git commit -m "vendor: bump mfgpu submodule to BLT_OP_TRILIST=10"
```

---

## Task 2: Remove the 5 Castilla opcodes from the Maldita core

**Goal:** Slim `blitter_top` to `NOP/END/FILL/BLIT/STAGE` (TRILIST added in Task 5), deleting the TILELIST/TILELIST_RES/FRT_UPLOAD/BGPLANE_WRITE/CLUT_UPLOAD FSMs, their regs, their support submodules, and their testbenches — anchored by the kept-op pipe sims as a regression net.

**Files:**
- Modify: `fpga/rtl/blitter_defs.vh` (remove ops 5–9 + their `*_QW`/size defines)
- Modify: `fpga/rtl/blitter_top.sv` (remove decode branches, states, handlers, regs, submodule instances, collapse muxes, prune port list)
- Modify: `fpga/Maldita.sv` (remove `bgw_ch0_mux` + bgw nets + blitter dst_/bgw_active connections)
- Delete: `fpga/rtl/fbram_to_sdram.sv`, `fpga/rtl/bgplane_coverage.sv`, `fpga/rtl/bgw_ch0_mux.sv`
- Delete: `fpga/sim/tb_bgplane_*.sv`, `tb_bgw_ch0_mux.sv`, `tb_tilelist.sv`, `tb_tilelist_res.sv`, `tb_clut_upload.sv`, `tb_pal8_*.sv`, `tb_mixed_format_seq.sv`
- Modify: `fpga/sim/run_sims.sh` (drop deleted TB names from `SKIP`/`NONGATING`/`NIGHTLY_ONLY`/`pass_re`/`timeout_s`/`defines_for`/nightly-timeout tables)
- Modify: `fpga/rtl/comp_pipeline.sv` port wiring in `blitter_top.sv:1046-1047` (tie off CLUT/PAL8 — see Step 5)

**Interfaces:**
- Produces: a `blitter_top` whose decode dispatches only `NOP/END/FILL/BLIT/STAGE`; ports `dst_wr/dst_addr/dst_din/dst_wdsn/dst_ok/bgw_active` removed; STAGE + P_SRC + comp_fbram ports unchanged.

- [ ] **Step 1: Establish the regression baseline (kept-op sims green BEFORE editing).**

Run: `cd fpga/sim && for t in tb_blitter_copy_pipe tb_blitter_blend_pipe tb_blitter_add_pipe tb_blitter_clear_pipe tb_blitter_cafill_pipe tb_blitter_snapshot_pipe tb_blitter_system_pipe; do ./run_sims.sh $t; done`
Expected: every one prints `RESULT: PASS`. (If any already fails, STOP — fix the baseline first.)

- [ ] **Step 2: Delete the support submodules + their testbenches.**

```bash
cd fpga
git rm rtl/fbram_to_sdram.sv rtl/bgplane_coverage.sv rtl/bgw_ch0_mux.sv
git rm sim/tb_bgplane_base_wrap_xl.sv sim/tb_bgplane_3plane_xl.sv sim/tb_bgplane_coverage.sv \
       sim/tb_bgplane_maptrans.sv sim/tb_bgplane_inval_teeth.sv sim/tb_bgplane_equivalence.sv \
       sim/tb_bgplane_write_pipe.sv sim/tb_bgplane_write_pipe_xl.sv sim/tb_bgw_ch0_mux.sv \
       sim/tb_tilelist.sv sim/tb_tilelist_res.sv sim/tb_clut_upload.sv \
       sim/tb_pal8_bgplane.sv sim/tb_pal8_tilelist.sv sim/tb_pal8_lookup.sv \
       sim/tb_pal8_fill_8bpp.sv sim/tb_mixed_format_seq.sv
```

- [ ] **Step 3: Prune `blitter_top.sv` — decode branches, states, handlers, regs, instances.** Delete these line ranges (bottom-up so earlier ranges stay valid). Remove **decode branches** `OP_TILELIST` (:671-687), `OP_FRT_UPLOAD` (:688-694), `OP_TILELIST_RES` (:695-712), `OP_CLUT_UPLOAD` (:713-719), `OP_BGPLANE_WRITE` (:720-732) — keep `OP_STAGE` (:658-670) and the FILL/BLIT `else` (:733-740). Remove **state handlers** `S_TL_*` (:810-857), `S_FRT_*` (:860-868), `S_CLUT_*` (:871-879), `S_CFT_*` (:882-894), `S_TLR_*` (:897-927), `S_BGW_*` (:988-995). Remove **state localparams** at :158-159, :179-183, :190-191, :193 (keep :164-172 STAGE + barrier, :169 PIPE, :175-177 SNAP). Remove **regs/wires**: :324-335 (tl_*), :341-369 (res_/frt_/cft_ + frt_bram/cft_mem), :377-394 (clut_ + clut_bram + pipe_clut_addr + its always), :228-240 + :307 (bgw_/bgcov + c_bgcov_clear), :1089-1094 + :1146-1147 + :1159-1169 (bgw nets/SVA). Remove **reset initializers** :490-500. Remove **submodule instances** `fbram_to_sdram u_bgw` (:1095-1105) and `bgplane_coverage u_bgcov` (:1116-1121).

- [ ] **Step 4: Collapse the co-owned muxes to the STAGE/kept side.** In `blitter_top.sv`: change `assign bgw_active = bgw_sdram_wr_en;` and the three `src_sdram_we_burst/din64/waddr = bgw_active ? bgw_* : stage_*_fsm` (:1148-1151) to drive the `stage_*_fsm` side unconditionally. In the `fb_rd_en/fb_rd_qw` mux (:1181-1182) drop the `bgw_busy ? bgw_rd_*` middle term → `snap_busy ? snap_* : pipe_fb_rd_*`. Remove ports `dst_wr/dst_addr/dst_din/dst_wdsn/dst_ok/bgw_active` (:95-99, :105) and the now-dead tie-offs (:1154-1157).

- [ ] **Step 5: Resolve the PAL8/CLUT dangling ref.** `comp_pipeline` still has `.c_pal_id/.c_base_off/.clut_rd_addr/.clut_rd_data` wired at `blitter_top.sv:1046-1047`. gmloader never uses PAL8, so tie them off: replace `.c_pal_id(c_pal_id)` → `.c_pal_id(5'd0)`, `.c_base_off(c_base_off)` → `.c_base_off(8'd0)`, `.clut_rd_data(clut_q)` → `.clut_rd_data(32'd0)`, and leave `.clut_rd_addr()` unconnected (or to a dead wire). Delete the now-unused `c_pal_id`/`c_base_off` decode regs (:312-313).

- [ ] **Step 6: Fix `Maldita.sv`.** Delete `bgw_ch0_mux u_bgw_ch0_mux (...)` (:399-413); wire `vram_demux`'s `vd_sd_*` write-side straight to `fbcache.dst_wr/dst_addr/dst_din/dst_wdsn` (:470-476). Delete bgw nets `bgw_active` (:392), `bgw_dst_*` (:393-397). Drop the blitter port connections `.dst_wr/.dst_addr/.dst_din/.dst_wdsn/.dst_ok/.bgw_active` (:659-664). Keep `.src_sdram_*`, `.stage_barrier*`, `.p0_*`, and the comp_fbram composite port.

- [ ] **Step 7: Prune `blitter_defs.vh`.** Remove `OP_TILELIST` (:94), `OP_TILELIST_RES` (:125), `OP_FRT_UPLOAD` (:126), `OP_BGPLANE_WRITE` (:138), `OP_CLUT_UPLOAD`+`BLT_OP_CLUT_UPLOAD` (:146-147), and the dead sizing defines `TL_BUF_BYTES`/`TL_BUF_QW` (:99,:110), `MAXP/MAXF` (:127-128), `FRT_BUF_QW/CFT_BUF_QW` (:130-131), `CLUT_BUF_QW` (:157).

- [ ] **Step 8: Prune `run_sims.sh` tables.** Remove every deleted TB name from `SKIP` (:39), `NONGATING` (:107), `NIGHTLY_ONLY` (:129), `pass_re` (:150), `timeout_s` (:157-212), `defines_for` (:217-220), nightly overrides (:288-299).

- [ ] **Step 9: Elaborate + regress.** Confirm no dangling references and the kept datapath is intact.

Run: `cd fpga/sim && iverilog -g2012 -o /tmp/elab.vvp -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe -y ../sys -y . -Y .sv -Y .v tb_blitter_copy_pipe.sv 2>&1 | tee /tmp/elab.log`
Expected: no `error:`/`Unknown module`/`identifier ... not declared`. Then re-run the Step-1 kept-op set — all `RESULT: PASS`.

- [ ] **Step 10: Commit.**

```bash
cd .. && git add -A fpga && git commit -m "feat(core): remove 5 Solarus-legacy blitter ops (gmloader-GPU-only); slim to NOP/END/FILL/BLIT/STAGE"
```

---

## Task 3: Bring `blt_tri` into the tree + the C golden generator

**Goal:** Land the golden math (`blt_tri.sv` blend core for RTL, `blt_tri.c` for expected values) and a small generator that emits per-scenario DDR-init + expected-`comp_fbram` hex, so every triangle testbench diffs RTL vs golden at ±1 LSB.

**Files:**
- Create: `fpga/rtl/blt_tri.sv` (copy from `mister-fpga-blitter/rtl/blt_tri.sv`; the blend core is used as-is, cover/interp outputs are the golden the front-end must match)
- Create: `fpga/sim/gen_tri_golden.c` (`#include "blt_tri.c"`; builds a ring/src/vertex image + a golden comp_fbram from `blt_raster_tri`, writes `<scen>_ddr.hex` + `<scen>_exp.hex`)
- Create: `fpga/sim/blt_tri.c` (copy from `mister-fpga-blitter/refmodel/blt_tri.c`)
- Create: `fpga/sim/gen_tri_golden.mk` (host cc build of the generator)

**Interfaces:**
- Produces: `gen_tri_golden <scen>` → writes `fpga/sim/vectors/<scen>_ddr.hex` (memory image: control block, ring, SRC verts+texture) and `<scen>_exp.hex` (320×240 comp_fbram, qword-packed, 4 px/qword). Scenarios: `tri_copy`, `tri_key`, `tri_calpha`, `tri_add`, `tri_quad`.

- [ ] **Step 1: Copy the golden files.**

```bash
cp ../../mister-fpga-blitter/rtl/blt_tri.sv fpga/rtl/blt_tri.sv
cp ../../mister-fpga-blitter/refmodel/blt_tri.c fpga/sim/blt_tri.c
```

- [ ] **Step 2: Write `gen_tri_golden.c`.** It mirrors upstream `sim/gen_vectors.c`'s `add_trilist`/`add_tri` heap builders: place an 8×8 solid-magenta (or gradient) RGB565 texture at SRC heap offset 0, three `blt_vtx_t` at the vertex region, a control block (clear=blue, cmd_count, target=0) + a TRILIST command in the ring; then call `blt_raster_tri(...)` over the same scene into an `uint16 fb[320*240]` and dump it qword-packed. Emit both hex files under `vectors/`. Select scenario by `argv[1]`; each sets blend mode + colorkey + vertex colors/alpha per the Global-Constraints mode list.

- [ ] **Step 3: Build + generate.**

Run: `cd fpga/sim && cc -O2 -I ../../../mister-fpga-blitter/refmodel -o gen_tri_golden gen_tri_golden.c && mkdir -p vectors && for s in tri_copy tri_key tri_calpha tri_add tri_quad; do ./gen_tri_golden $s; done && ls vectors`
Expected: 10 hex files (`*_ddr.hex`, `*_exp.hex`). Sanity: `tri_copy_exp.hex` non-empty and contains both the blue clear qword and magenta pixels.

- [ ] **Step 4: Commit.**

```bash
git add fpga/rtl/blt_tri.sv fpga/sim/blt_tri.c fpga/sim/gen_tri_golden.c fpga/sim/gen_tri_golden.mk fpga/sim/vectors
git commit -m "sim: vendor blt_tri golden + gen_tri_golden (triangle expected-vector generator)"
```

---

## Task 4: Triangle setup datapath — reciprocal-area + gradients (front-end part 1)

**Goal:** Compute, once per triangle, the fixed-point `1/area` and the incremental per-x / per-row deltas for barycentric weights and interpolated attributes (u, v, r, g, b, a), so the per-pixel walk needs only adds + one multiply — no divides. Verified against `blt_tri.c` at sampled pixels within ±1 LSB.

**Files:**
- Create: `fpga/rtl/blt_tri_setup.sv` (combinational/registered setup block)
- Create: `fpga/sim/tb_tri_setup.sv` (self-checking unit tb)

**Interfaces:**
- Consumes: 3 vertices `{vx,vy (12.4 s16), vu,vv (12.4 u16), r,g,b,a (u8)}`, `tex_w/tex_h`.
- Produces (registered): `area_recip` (fixed-point 1/area), edge deltas `dw0dx/dw1dx/dw2dx`, `dw0dy/...`, attribute gradients `dudx,dvdx,drdx,...` and `dudy,...`, plus origin values at the bbox min corner `{w0_0,w1_0,w2_0, u_0,v_0, r_0,...}`. All sized to keep the walk's interpolation ±1 LSB of `blt_tri.c`'s `divr(w·attr, area)`.

- [ ] **Step 1: Write the failing unit tb.** `tb_tri_setup.sv` instantiates `blt_tri_setup` with a fixed triangle (e.g. the `tri_copy` verts), and also instantiates the golden `blt_tri` combinationally; for ~8 sample pixels inside the bbox it steps the setup outputs (origin + k·gradient) and asserts the reconstructed `(u,v,r,g,b,a)` equals `blt_tri`'s `(tu,tv,cr,cg,cb,ca)` within ±1. Prints `RESULT: PASS`/`FAIL`.

- [ ] **Step 2: Run it — fails (module absent).**

Run: `cd fpga/sim && ./run_sims.sh tb_tri_setup`
Expected: FAIL / elaboration error (`blt_tri_setup` undefined).

- [ ] **Step 3: Implement `blt_tri_setup.sv`.** Signed area `A = edgef(v0,v1,v2)`; CCW-normalize (swap v1/v2 if `A<0`) exactly as `blt_tri.sv:76-90`. Compute `area_recip` via a pipelined reciprocal (LUT-seeded Newton or a multi-cycle restoring divide — amortized once/triangle, ~10/frame). Edge deltas are constants of the edge functions: `dw_k/dx`, `dw_k/dy` are the vertex-difference terms. Attribute gradients: `d(attr)/dx = (attr·dw/dx)·area_recip` summed over the 3 verts (affine). Register all outputs. Tune the fixed-point widths of `area_recip`/gradients until Step 4 passes ±1.

- [ ] **Step 4: Run it — passes.**

Run: `cd fpga/sim && ./run_sims.sh tb_tri_setup`
Expected: `RESULT: PASS` (all sampled pixels within ±1 of golden).

- [ ] **Step 5: Commit.**

```bash
git add fpga/rtl/blt_tri_setup.sv fpga/sim/tb_tri_setup.sv
git commit -m "feat(tri): reciprocal-area + gradient setup datapath (+-1 LSB vs blt_tri.c)"
```

---

## Task 5: Triangle walk + integration into `blitter_top` (front-end part 2)

**Goal:** Add the `OP_TRILIST=10` decode + `S_TRI_*` FSM: fetch vertices (DDR master), run setup, walk the bbox with incremental weights emitting covered pixels, read texels from SDRAM `P_SRC`, blend via `blt_tri`'s kept blend core, RMW into `comp_fbram`. Wire `tri_busy` as the third bus owner. End-to-end verified by `tb_blitter_trilist_pipe` vs the Task-3 golden.

**Files:**
- Modify: `fpga/rtl/blitter_defs.vh` (add `localparam OP_TRILIST = 8'd10;`)
- Modify: `fpga/rtl/blitter_top.sv` (new `S_TRI_*` states, decode branch, `blt_tri`/`blt_tri_setup` instances, `tri_busy` mux terms, vertex/texel/dst datapath)
- Create: `fpga/sim/tb_blitter_trilist_pipe.sv` (loads `tri_copy_ddr.hex` → runs DUT → diffs `comp_fbram` vs `tri_copy_exp.hex` ±1 LSB)

**Interfaces:**
- Consumes: `blt_tri_setup` (Task 4) outputs; `blt_tri` blend inputs `texel/dst/g_alpha/blend_mode/colorkey` → `write_en/out_pix`; the P_SRC port (`p0_addr/p0_rd/p0_dout/p0_ok`), the DDR `mem_*` master (free — comp_pipeline retired it), and the `comp_fbram` RMW ports (`fb_rd_*`, `fb_wr_*`).
- Produces: `blitter_top` that composites `OP_TRILIST` into `comp_fbram`; TRILIST header decode reuses `dst_x|dst_y<<16 = vertex byte offset`, `w = tri count`, `src_off/stride/src_x/src_y = tex page + dims`.

- [ ] **Step 1: Write the failing end-to-end tb.** `tb_blitter_trilist_pipe.sv` — clone `tb_blitter_copy_pipe.sv`'s harness (clk, `blitter_top`+`comp_fbram` instances, the single-beat DDR model, the P_SRC cache-ok model). Instead of hand-writing `mem[]`, `$readmemh("vectors/tri_copy_ddr.hex", mem)` to load control block + ring + SRC (verts+texture). Run the submit/poll handshake to `done_seq==submit_seq`. Then load `vectors/tri_copy_exp.hex` into `exp[]` and compare every `comp_fbram` qword (`fbram.bank0..3[idx]`, all 320×240) to the golden, allowing ±1 per RGB565 channel; `RESULT: PASS` iff done and zero out-of-tolerance pixels.

- [ ] **Step 2: Run it — fails (no TRILIST decode).**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_trilist_pipe`
Expected: FAIL — screen is the blue clear only (opcode 10 undecoded → no triangle), or timeout.

- [ ] **Step 3: Add the decode + `S_TRI_*` states.** In `blitter_defs.vh` add `localparam [7:0] OP_TRILIST = 8'd10;`. In `blitter_top.sv` `S_SETUP`, add `else if (c_opcode==OP_TRILIST)` seeding `tri_count<=c_w`, `entry_qw_base<=SRC_QW + ({c_dst_y,c_dst_x}>>3)`, `tri_idx<=0` → `S_TRI_VFETCH`. Add states: `S_TRI_VFETCH/VCOLLECT/DECV` (fetch 6 qwords/tri via the `bm_*` DDR master, unpack per `blt_tri.sv:436-444`), `S_TRI_SETUP` (pulse `blt_tri_setup`, latch its registered outputs, seed bbox min/max + incremental accumulators), `S_TRI_PIX` (evaluate coverage from the running `w0/w1/w2`; if covered issue the P_SRC texel read at `tri_tu/tri_tv`), `S_TRI_GOTTEX` (latch texel; for CALPHA/ADD issue the `comp_fbram` dst read), `S_TRI_GOTDST`, `S_TRI_WR` (drive `blt_tri` blend, if `write_en` write `comp_fbram` via `fb_wr_*`), `S_TRI_ADV` (step `w*`/attributes by the per-x deltas, wrap rows by the per-row deltas). Instance `blt_tri_setup u_tri_setup(...)` and `blt_tri u_tri(...)` (blend port group only driven from the walk).

- [ ] **Step 4: Wire `tri_busy` as the third bus owner.** Add `tri_busy` (set on the TRILIST decode, cleared at `S_NEXT_CMD`), mirroring `pipe_busy` bookkeeping. Extend the muxes: DDR `mem_*` (:1196) `tri_busy ? tri_mem_* : (pipe_busy_q ? p_mem_* : bm_*)`; P_SRC `p0_*` (:1207) select `tri_*` when `tri_busy`; `comp_fbram` read (:1181) add `tri_busy ? tri_fb_rd_*`; add the **new `fb_wr` mux** at :1065 `tri_busy ? tri_fb_wr_* : pipe_fb_wr_*`. One op runs at a time, so this is arbitration only.

- [ ] **Step 5: Run it — passes.**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_trilist_pipe`
Expected: `RESULT: PASS` — composited triangle matches `tri_copy_exp.hex` within ±1 LSB.

- [ ] **Step 6: Regress the kept datapath** (TRILIST integration must not disturb FILL/BLIT/STAGE):

Run: `cd fpga/sim && for t in tb_blitter_copy_pipe tb_blitter_blend_pipe tb_blitter_add_pipe tb_blitter_clear_pipe tb_blitter_system_pipe tb_blitter_snapshot_pipe; do ./run_sims.sh $t; done`
Expected: all `RESULT: PASS`.

- [ ] **Step 7: Commit.**

```bash
cd .. && git add fpga/rtl/blitter_defs.vh fpga/rtl/blitter_top.sv fpga/sim/tb_blitter_trilist_pipe.sv && \
  git commit -m "feat(core): OP_TRILIST=10 rasterizer FSM -> comp_fbram (incremental front-end + blt_tri blend)"
```

---

## Task 6: gmloader-mode coverage + optional `comp_mixer` blend spike

**Goal:** Prove the four production blend paths (COPY/COLORKEY/CONST_ALPHA-vtx-alpha/ADD) and a textured quad (2 tris) render ±1 LSB, and decide whether to collapse the blend onto `comp_mixer`.

**Files:**
- Create: `fpga/sim/tb_blitter_trilist_key.sv`, `tb_blitter_trilist_calpha.sv`, `tb_blitter_trilist_add.sv`, `tb_blitter_trilist_quad.sv` (same harness as Task 5, different `<scen>` vectors)
- Create (spike only): `fpga/sim/tb_tri_mixer_equiv.sv` (diff `comp_mixer` output vs `blt_tri` blend over the 4 modes)

**Interfaces:**
- Consumes: Task-3 vectors `tri_key/tri_calpha/tri_add/tri_quad`; the `comp_mixer` module (`comp_mixer.sv`).

- [ ] **Step 1: Write the four mode testbenches** (each `$readmemh`s its `<scen>_ddr.hex`, diffs vs `<scen>_exp.hex` ±1 LSB, as Task 5 Step 1).

- [ ] **Step 2: Run them — expect PASS** (front-end + blt_tri blend already implement these modes):

Run: `cd fpga/sim && for t in tb_blitter_trilist_key tb_blitter_trilist_calpha tb_blitter_trilist_add tb_blitter_trilist_quad; do ./run_sims.sh $t; done`
Expected: all `RESULT: PASS`. If COLORKEY or vtx-alpha mismatches, fix the walk's key-cull / per-pixel `g_alpha` feed and re-run.

- [ ] **Step 3: `comp_mixer` equivalence spike.** `tb_tri_mixer_equiv.sv`: stream ~256 `(src,dst,alpha,key,mode)` tuples through `comp_mixer` and through `blt_tri`'s blend; assert all within ±1 LSB over COPY/KEY/CALPHA/ADD. Run it. **If PASS:** record that the blend may be collapsed to `comp_mixer` (fold into a follow-up; not required for correctness). **If any mode diverges >1 LSB:** keep `blt_tri`'s blend (the default) and note the divergent mode.

Run: `cd fpga/sim && ./run_sims.sh tb_tri_mixer_equiv`
Expected: `RESULT: PASS` or a recorded per-mode divergence.

- [ ] **Step 4: Commit.**

```bash
git add fpga/sim/tb_blitter_trilist_*.sv fpga/sim/tb_tri_mixer_equiv.sv
git commit -m "test(tri): gmloader blend-mode + quad coverage; comp_mixer equivalence spike"
```

---

## Task 7: RBF build on CI + timing check

**Goal:** Produce a `MalditaCastilla_*.rbf` with the slimmed core + TRILIST rasterizer, green on the Windows Quartus runner with clean STA.

**Files:**
- Modify: `fpga/files.qip` (add `rtl/blt_tri.sv`, `rtl/blt_tri_setup.sv`; confirm the 3 deleted `.sv` are not listed)
- (No source edits beyond the qip — this task is build + inspect.)

**Interfaces:**
- Consumes: Tasks 2 + 5 RTL. Produces: `_Other/MalditaCastilla_*.rbf` (artifact `maldita-rbf`) + `quartus-reports`.

- [ ] **Step 1: Register the new RTL in the Quartus filelist.** Add `rtl/blt_tri.sv` and `rtl/blt_tri_setup.sv` to `fpga/files.qip`; grep it for `fbram_to_sdram`/`bgplane_coverage`/`bgw_ch0_mux` and remove any lines found.

- [ ] **Step 2: Trigger CI.** Push the `milestone-a` branch (the push touches `fpga/**` → `build-rbf.yml` runs `build-windows`).

Run: `cd .. && git push origin milestone-a`
Expected: the `Build Maldita RBF` workflow starts on the self-hosted Windows runner.

- [ ] **Step 3: Confirm green build + inspect STA.** Wait for the run; download the `quartus-reports` artifact and read `sta_*.log` for negative slack on the core clock (the removed ops freed logic; TRILIST adds the setup reciprocal — the risk area).

Run: `gh run watch $(gh run list --workflow=build-rbf.yml -L1 --json databaseId -q '.[0].databaseId')`
Expected: conclusion `success`; `maldita-rbf` artifact present; `sta_*.log` shows no unmet setup on the fabric clock (if it does, register the reciprocal deeper / add a pipeline stage in `blt_tri_setup` and re-run Tasks 4–5 sims + push).

- [ ] **Step 4: Commit the qip.**

```bash
git add fpga/files.qip && git commit -m "build: add blt_tri/blt_tri_setup to Quartus filelist" && git push origin milestone-a
```

---

## Self-Review

- **Spec coverage:** incremental front-end + kept blt_tri blend → Tasks 4,5; reuse P_SRC/comp_fbram → Task 5; ±1 LSB vs blt_tri.c → Tasks 3,4,5,6; comp_mixer gated spike → Task 6; opcode 8→10 renumber (5 sites) → Task 1; remove 5 Castilla ops → Task 2; workload blend modes (COPY/KEY/CALPHA/ADD) → Task 6; RBF build + STA → Task 7. Success criteria 1–3 → Tasks 5–7; criterion 4 (on-device ≥30 fps) is the offload plan's device tasks (cross-plan, noted below).
- **Cross-plan dependency:** on-device rendering needs `backend_mfgpu` to emit `BLT_OP_STAGE` so textures are SDRAM-resident (offload plan Task 3) + device present/publish (offload plan Task 4). This plan verifies TRILIST fully in sim by pre-loading SDRAM in the testbench; the device slice depends on those offload tasks.
- **Placeholder scan:** the front-end datapath (Tasks 4–5) is specified by interface + math + TDD loop rather than final RTL by intent — HDL datapath fixed-point widths (reciprocal precision) are tuned against the ±1 LSB unit test, which is the correct method, not a placeholder. All commands, file paths, and line ranges are concrete.
- **Type/name consistency:** `blt_tri_setup` outputs (`area_recip`, `dw*dx`, gradients) consumed in Task 5; `OP_TRILIST=10` consistent (Task 1 host, Task 5 device); `tri_busy` mux terms match the interface catalog's mux line numbers; scenario names (`tri_copy/key/calpha/add/quad`) consistent Tasks 3/5/6.
- **Ordering:** remove-first (Task 2) then build (Tasks 3–5) — the front-end integrates into the slim mux surface; kept-op pipe sims anchor the removal. Task 1 (ABI) precedes all so the device opcode matches the host contract.

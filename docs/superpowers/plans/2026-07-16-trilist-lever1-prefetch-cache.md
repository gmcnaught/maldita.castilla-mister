# TRILIST Lever 1 — Prefetching Qword Texel Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide the single-outstanding P_SRC texel-fetch latency in the Maldita TRILIST rasterizer by decoupling texel fetch from consumption — a prefetching qword-granular local BRAM cache — cutting fabric `texwait` (~8.23ms) toward ~0 by overlapping it under the datapath (~15.55ms).

**Architecture:** `pa` (address-gen) becomes a best-effort prefetcher: it pushes each covered pixel's blend payload into a depth-`D` FIFO and, when the P_SRC fill arbiter is idle, kicks a fill for the pixel's texel qword into a direct-mapped local BRAM. `pb` (consume+blend) pops the FIFO and reads the texel from BRAM at a 1-cyc hit, demand-fetching through the same arbiter on a miss. Prefetch is purely additive on a bit-exact demand backbone, so a prefetch miss degrades to today's per-pixel fetch, never a wrong pixel.

**Tech Stack:** SystemVerilog (`blitter_top.sv`, IEEE 1364 / `-g2012`), Icarus Verilog (`iverilog`/`vvp`) sim, the existing golden bit-exact TRILIST harness (`gen_tri_golden.c` → `blitter_ref` → `tb_blitter_trilist_pipe.sv`), Quartus/Windows RBF build + `mister_run.sh` on-device bench.

## Global Constraints

- **Bit-exact is the invariant.** Every RTL task must keep `./run_sims.sh tb_blitter_trilist_pipe` printing `RESULT: PASS` (full comp_fbram diff vs `vectors/tri_copy_exp.hex`, ±1 LSB/channel). The change alters *when* texels are fetched, never *which* texel or the blend result.
- **Keep the whole suite green:** `./run_sims.sh` — `tb_scanout_fbram` and `tb_audio_burst_wedge` fail pre-existing on `milestone-a` (unrelated); nothing else may regress.
- **Zero jtframe changes.** Do not touch `sdram_fb_cache.sv`, `jtframe_*`, or ch5 `RO_BLOCKS`. The cache is blitter-local.
- **P_SRC is strictly single-outstanding.** Exactly one `tri_p0_rd` in flight; `p0_ok` is a 1-cycle strobe that must be latched in *any* cycle a read is outstanding (never sampled in one FSM state) — the Stage-3a device-hang lesson. Reuse the always-listening catcher pattern.
- **Working dir:** `/Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister` (the SIBLING dev repo, NOT the `mister-gmloader` submodule). Branch `milestone-a`.
- **Sim iteration command** (from `fpga/sim/`): `./run_sims.sh tb_blitter_trilist_pipe`. It rebuilds the TB in `.simbuild/` with the correct `-y` RTL search paths and greps `RESULT: PASS`. The TB also prints `=== PERF tri=<n> texwait=<n> dpath=<n> covered_px=<n> | dpath_cyc/px=<n> ===` and `=== done_seq=.. submit=.. (to=<n>) ===`.
- **Params (final names, defaults tuned in Task 4):** `TEXQ_N=256` (cache qwords), `TEXQ_AW=8` (`$clog2(TEXQ_N)`), `TEXFIFO_D=16` (payload FIFO depth), `TEXFIFO_AW=4`.
- **Address arithmetic:** `p0_addr` is a 27-bit byte address, 8-byte aligned (`& ~27'h7`). Qword address `qtag = texbyte[26:3]` (24 bits). Direct-map `slot = qtag[TEXQ_AW-1:0]`; stored tag `qtag[23:TEXQ_AW]` (16 bits). Texel lane within the qword = `texbyte[2:1]` (already `tex_lane_q`).

---

## File Structure

- **Modify** `fpga/sim/tb_blitter_trilist_pipe.sv:30-69` — extend the P_SRC stub with a faithful LRU line-cache latency model (Task 0). Self-contained sim change.
- **Modify** `fpga/rtl/blitter_top.sv` — all RTL work (Tasks 1-4), in-place in the existing `pa`/`pb` sub-FSMs and their declaration/reset blocks:
  - declarations near `:420-452` (params, local BRAM, tag/valid, fill arbiter regs, payload FIFO regs),
  - reset block `:594-595`,
  - the STAGE→P_SRC barrier (`:106-157`) for cache invalidation,
  - the `S_TRI_PIX` umbrella (`:939-1187`): the always-listening catcher, `pa` (`A_ISSUE`), `pb` (`B_GOT`/`B_DSTW`), and the P_SRC issue mux.

No new files — this is a focused single-module datapath change plus one sim-model change.

---

## Task 0: Faithful LRU line-cache P_SRC stub (measure the win)

**Files:**
- Modify: `fpga/sim/tb_blitter_trilist_pipe.sv:30-69`
- Test: `fpga/sim/tb_blitter_trilist_pipe.sv` (self, via `run_sims.sh`)

**Interfaces:**
- Consumes: nothing new (the stub already drives `s_src_addr`/`s_src_rd`/`s_src_dout`/`s_src_ok`, single-outstanding via `so_busy`).
- Produces: a `texwait` in the PERF line that is **nonzero and responds to prefetch** — the metric every later task is scored against. No RTL interface change.

**Why:** the current stub picks latency by `$random` (4 or 4..28), which is not a real cache — it can't reward prefetching. Replace it with an LRU line model (hit=4, cold-fill=140, `NLINES=2` resident) driven by the real address stream, so a read that hits an already-fetched line is cheap and misses cost real latency. Prefetch then shows up as a `texwait` drop because `pb` stalls (`state==S_TRI_PIX && pb==B_GOT && !tex_rdy`) less.

- [ ] **Step 1: Capture the current baseline (pre-change reference)**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_trilist_pipe 2>&1 | grep -E 'PERF|done_seq|RESULT'`
Expected: `RESULT: PASS`; record the printed `tri=.. texwait=.. dpath=..` (this is the *random-stub* baseline — texwait will be small; that's the point of the change).

- [ ] **Step 2: Replace the latency picker with an LRU line model**

In `tb_blitter_trilist_pipe.sv`, replace the single-outstanding latency block (`:47-69`, from `reg so_busy = 1'b0;` through the closing `end` of the `always` at `:69`) with:

```systemverilog
  // SINGLE-OUTSTANDING faithful line-cache model: hit=HIT_LAT, cold line-fill=MISS_LAT,
  // NLINES resident with LRU (rline[0]=MRU). Keyed by line = addr>>LINE_LOG2. Reproduces
  // the real jtframe ch5 behaviour (2 tiny lines the row-order texel walk thrashes) so a
  // prefetcher that issues reads AHEAD overlaps the miss latency and drops pb's stall
  // (texwait). Still single-outstanding + address-dependent variable phase, so it keeps
  // catching the p0_ok strobe-miss hang.
  localparam LINE_LOG2 = 8;    // 256-byte lines (tune with NLINES so texwait is ~30% of tri)
  localparam NLINES    = 2;    // faithful jtframe ch5 = 2 lines
  localparam HIT_LAT   = 4;
  localparam MISS_LAT  = 140;
  reg        so_busy = 1'b0;
  integer    so_cnt  = 0;
  reg [26:0] so_addr = 27'd0;
  reg [26:0] rline   [0:NLINES-1];   // resident line addrs, [0]=MRU
  reg        rline_v [0:NLINES-1];
  integer    li, hitpos;
  initial for (li=0; li<NLINES; li=li+1) begin rline[li]=27'h7FFFFFF; rline_v[li]=1'b0; end
  always @(posedge clk) begin
    s_src_ok <= 1'b0;
    if ((s_src_rd & ~s_rd_d) && !so_busy) begin
      so_busy <= 1'b1;
      so_addr <= s_src_addr;
      // LRU lookup on the accepted address' line.
      hitpos = -1;
      for (li=0; li<NLINES; li=li+1)
        if (rline_v[li] && (rline[li] == (s_src_addr >> LINE_LOG2))) hitpos = li;
      if (hitpos >= 0) begin
        so_cnt <= HIT_LAT;
        // promote to MRU
        for (li=0; li<NLINES; li=li+1) if (li <= hitpos && li>0) rline[li] <= rline[li-1];
        rline[0] <= (s_src_addr >> LINE_LOG2); rline_v[0] <= 1'b1;
      end else begin
        so_cnt <= MISS_LAT;
        // insert new line at MRU, shift others down, evict LRU
        for (li=NLINES-1; li>0; li=li-1) begin rline[li] <= rline[li-1]; rline_v[li] <= rline_v[li-1]; end
        rline[0] <= (s_src_addr >> LINE_LOG2); rline_v[0] <= 1'b1;
      end
    end
    if (so_busy) begin
      if (so_cnt <= 1) begin
        s_src_dout <= mem[SRC_WIN + (so_addr >> 3)];
        s_src_ok   <= 1'b1;
        so_busy    <= 1'b0;
      end else so_cnt <= so_cnt - 1;
    end
  end
```

- [ ] **Step 3: Run — verify still PASS and texwait is now real**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_trilist_pipe 2>&1 | grep -E 'PERF|RESULT'`
Expected: `RESULT: PASS` (bit-exact — the model only changes latency, not data), and `texwait` is now a **substantial fraction of `tri`** (nonzero, materially larger than the Step-1 baseline). If `texwait` is ~0 or ~=`tri`, adjust `LINE_LOG2` (larger → fewer/bigger lines → fewer misses; smaller → more thrash) so it lands in a realistic band (roughly 20-40% of `tri`). Record the tuned `LINE_LOG2` and the `tri/texwait/dpath` numbers — this is the **Task-0 baseline** every later task compares against.

- [ ] **Step 4: Commit**

```bash
git add fpga/sim/tb_blitter_trilist_pipe.sv
git commit -m "sim: faithful LRU line-cache P_SRC stub for tb_blitter_trilist_pipe

Replace the random 4..28cyc latency picker with a 2-line LRU model
(hit=4, cold-fill=140) keyed by addr>>LINE_LOG2, driven by the real
texel address stream. Makes texwait real so the Lever-1 prefetch win
is measurable in sim. Still single-outstanding + variable phase; golden
diff bit-exact."
```

---

## Task 1: Local texel BRAM + tag/valid array + P_SRC fill arbiter (plumbing)

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` — declarations `:420-452`, reset `:594-595`, barrier `:148-157`, `pa` `A_ADDR2`/`A_ISSUE` `:1036-1057`, `pb` `B_GOT` `:1070-1085`, always-listening catcher `:939-948`.
- Test: `fpga/sim/tb_blitter_trilist_pipe.sv` via `run_sims.sh`.

**Interfaces:**
- Consumes: `texbyte` (`:1041`, the computed texel byte address), the P_SRC port (`p0_addr`/`p0_rd`/`p0_dout`/`p0_ok`), the `tri_p0_rd`/`tri_p0_addr` registered owner outputs (`:449`).
- Produces (used by Tasks 2-3):
  - `tq_data[0:TEXQ_N-1]` (64b), `tq_tag[0:TEXQ_N-1]` (16b), `tq_valid[TEXQ_N-1:0]` — the local cache.
  - `fill_req_valid`, `fill_req_qtag[23:0]`, `fill_busy`, `fill_slot[TEXQ_AW-1:0]`, `fill_tag[15:0]` — the arbiter handshake.
  - `function automatic tq_hit(input [23:0] qt)` → 1 when `tq_valid[qt[TEXQ_AW-1:0]] && tq_tag[qt[TEXQ_AW-1:0]]==qt[23:TEXQ_AW]`.

**Design for this task:** keep the existing single-deep `h_full` handoff and `pb` structure. The only change: route the texel read through a fill arbiter that writes into the BRAM, and have `pb` read the texel from the BRAM instead of the `tex_hold` latch. This is pure plumbing — behavior and cycle-count stay ~identical, proving the cache path is bit-exact before decoupling.

- [ ] **Step 1: Add declarations**

Insert after `:452` (after the `tri_fb_*` registered-owner outputs), before `wire tri_need_dst`:

```systemverilog
    // ── Lever 1: blitter-local prefetching qword texel cache ────────────────
    // Direct-mapped BRAM of TEXQ_N qwords; slot = qtag[TEXQ_AW-1:0]; a single
    // P_SRC read fills one slot. Decouples the rasterizer's texel read (1-cyc
    // BRAM hit) from the single-outstanding P_SRC latency. Bit-exact: same
    // texel bytes, fetched earlier. See docs .../2026-07-16-trilist-lever1-*.
    localparam integer TEXQ_N     = 256;
    localparam integer TEXQ_AW    = 8;      // $clog2(TEXQ_N)
    reg  [63:0] tq_data  [0:TEXQ_N-1];      // cached qwords
    reg  [15:0] tq_tag   [0:TEXQ_N-1];      // qtag[23:TEXQ_AW]
    reg  [TEXQ_N-1:0] tq_valid;             // per-slot valid (packed for 1-cyc barrier clear)
    // P_SRC fill arbiter: sole owner of tri_p0_rd/tri_p0_addr, single-outstanding.
    reg         fill_busy;                  // a fill is in flight (p0_ok pending)
    reg  [TEXQ_AW-1:0] fill_slot;           // slot the in-flight fill targets
    reg  [15:0] fill_tag;                   // tag the in-flight fill will stamp
    // combinational hit test for a qtag against the current cache contents.
    function automatic tq_hit(input [23:0] qt);
        tq_hit = tq_valid[qt[TEXQ_AW-1:0]] && (tq_tag[qt[TEXQ_AW-1:0]] == qt[23:TEXQ_AW]);
    endfunction
```

- [ ] **Step 2: Reset the arbiter/valid state**

At `:595` (the `pa<=A_PIX; pb<=B_IDLE; ...` reset line), append on the next line inside the `if (rst)` block:

```systemverilog
            fill_busy<=1'b0; tq_valid<={TEXQ_N{1'b0}};
```

- [ ] **Step 3: Invalidate the cache on the per-command STAGE→P_SRC barrier**

Find the barrier state that requests ch5 invalidation (near `:148-157`, the `S_STAGE_BARRIER`/`stage_barrier` assertion). In that state's body, add `tq_valid <= {TEXQ_N{1'b0}};` on the cycle the barrier fires, so the local cache drops all lines exactly when jtframe ch5 is invalidated (per-command, not per-triangle — triangles in a command share the atlas). If the barrier is a single-cycle pulse asserted in one state, clear `tq_valid` there.

Run after this step (should still PASS — nothing reads the cache yet): `cd fpga/sim && ./run_sims.sh tb_blitter_trilist_pipe 2>&1 | grep RESULT` → `RESULT: PASS`.

- [ ] **Step 4: Route the always-listening catcher to fill the BRAM**

Replace the catcher at `:944-948` (currently latches into `tex_hold`/`tex_rdy`):

```systemverilog
                if (fill_busy && p0_ok) begin
                    tq_data[fill_slot]  <= p0_dout;
                    tq_tag[fill_slot]   <= fill_tag;
                    tq_valid[fill_slot] <= 1'b1;
                    fill_busy           <= 1'b0;
                end
```

(Retire `tex_pend`/`tex_rdy`/`tex_hold` once Steps 5-6 no longer reference them; leave the declarations until then to keep intermediate builds compiling.)

- [ ] **Step 5: `pa` — issue the fill through the arbiter instead of the single read**

The `qtag` is `texbyte[26:3]`. In `A_ADDR2` (`:1036-1044`) keep computing `texbyte`, and change the payload latch so `A_ISSUE` has the qtag. Replace `A_ISSUE` (`:1050-1057`) so it (a) starts a fill if the qword isn't resident and the arbiter is idle, (b) still hands the pixel to `pb` via `h_full` carrying the qtag/lane:

```systemverilog
            A_ISSUE: if (!h_full) begin
                // start a fill for this pixel's qword if not resident and arbiter idle.
                if (!tq_hit({3'd0, tri_p0_addr[26:3]}) && !fill_busy) begin
                    tri_p0_rd  <= 1'b1;
                    tri_p0_addr<= tri_p0_addr;            // set in A_ADDR2 (already aligned)
                    fill_busy  <= 1'b1;
                    fill_slot  <= tri_p0_addr[3+:TEXQ_AW];
                    fill_tag   <= tri_p0_addr[3+TEXQ_AW +: 16];
                end
                h_cr <= cr_q; h_cg <= cg_q; h_cb <= cb_q; h_ca <= ca_q;
                h_dst_qw <= dst_qw_q; h_dst_lane <= dst_lane_q;
                h_tex_lane <= tex_lane_q;
                h_qtag <= tri_p0_addr[26:3];              // NEW handoff field
                h_full <= 1'b1;
                pa<=A_PIX;
            end
```

Add `reg [23:0] h_qtag;` to the handoff declarations near `:427-429`, and `b_qtag` (`reg [23:0] b_qtag;`) near `:444-446` for the B-local snapshot.

- [ ] **Step 6: `pb` — read the texel from BRAM (demand-fetch on miss)**

Replace `B_GOT` (`:1070-1085`) so it snapshots the payload, then reads the cache: hit → proceed to dst/blend with `texel_q` from BRAM; miss → demand-fetch (priority) and wait. Insert a `B_FILL` wait state (add `B_FILL=3'd6` to the `localparam` at `:422-423`):

```systemverilog
            B_GOT: if (h_full) begin
                b_cr <= h_cr; b_cg <= h_cg; b_cb <= h_cb; b_ca <= h_ca;
                b_dst_qw <= h_dst_qw; b_dst_lane <= h_dst_lane;
                b_qtag <= h_qtag; b_tex_lane <= h_tex_lane;   // add reg [1:0] b_tex_lane
                h_full <= 1'b0;
                pb <= B_FILL;
            end
            // Resolve the texel: BRAM hit -> latch texel_q; miss -> demand-fetch, wait.
            B_FILL: begin
                if (tq_hit(b_qtag)) begin
                    texel_q <= tq_data[b_qtag[TEXQ_AW-1:0]][b_tex_lane*16 +: 16];
                    if (tri_need_dst) begin
                        tri_fb_rd_en <= 1'b1; tri_fb_rd_qw <= b_dst_qw; pb<=B_DSTW;
                    end else begin dst_q <= 16'd0; pb<=B_WR; end
                end else if (!fill_busy) begin
                    // demand-fetch (arbiter idle): issue the read for b_qtag.
                    tri_p0_rd  <= 1'b1;
                    tri_p0_addr<= {b_qtag, 3'd0};
                    fill_busy  <= 1'b1;
                    fill_slot  <= b_qtag[TEXQ_AW-1:0];
                    fill_tag   <= b_qtag[23:TEXQ_AW];
                    // stay in B_FILL; the catcher fills the slot, then tq_hit passes.
                end
                // else: a fill (ours or pa's) is in flight -> wait here for it.
            end
```

Note the `B_GOT` guard changed from `if (tex_rdy)` to `if (h_full)`; the texel is no longer pre-caught into `tex_hold` — `pb` now resolves it from BRAM in `B_FILL`. Remove the `tex_pend<=1'b1` arm in `A_ISSUE` and the `tex_rdy`/`tex_hold` references; delete their decls at `:437-439` and their resets at `:595`/`:931`.

- [ ] **Step 7: Run — bit-exact + no texwait regression**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_trilist_pipe 2>&1 | grep -E 'PERF|RESULT'`
Expected: `RESULT: PASS`. `texwait` ≈ the Task-0 baseline (±small) — the read still happens per-pixel synchronously via the demand path; only the plumbing changed. `to` in the `done_seq` line must be a real number `< 4000000` (no hang).

- [ ] **Step 8: Whole-suite sanity + commit**

Run: `cd fpga/sim && ./run_sims.sh 2>&1 | tail -30` — confirm only `tb_scanout_fbram` + `tb_audio_burst_wedge` fail (pre-existing).

```bash
git add fpga/rtl/blitter_top.sv
git commit -m "trilist: local qword texel BRAM + P_SRC fill arbiter (plumbing)

Route the texel read through a fill arbiter that writes a direct-mapped
local BRAM (TEXQ_N qwords); pb resolves the texel from BRAM (hit) or
demand-fetches through the arbiter (miss). Single-deep handoff retained;
behavior/cycle-count unchanged. Cache invalidated on the per-command
STAGE->P_SRC barrier. Bit-exact; single-outstanding preserved."
```

---

## Task 2: Depth-D payload FIFO (decouple pa from pb)

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` — declarations `:420-446`, reset `:595`, `pa` `A_ISSUE`, `pb` `B_IDLE`/`B_GOT`, triangle-drain condition `:1185`.
- Test: `fpga/sim/tb_blitter_trilist_pipe.sv` via `run_sims.sh`.

**Interfaces:**
- Consumes: the `A_ISSUE` payload fields (`cr_q..ca_q`, `dst_qw_q`, `dst_lane_q`, `tex_lane_q`, `qtag=tri_p0_addr[26:3]`) and the `B_FILL`/`B_GOT` consumer from Task 1.
- Produces: `pf_mem[0:TEXFIFO_D-1]` + `pf_wr`/`pf_rd` pointers, `pf_full`/`pf_empty`; the FIFO replaces the single-deep `h_full` handoff. `pa` now runs up to `TEXFIFO_D` pixels ahead of `pb`.

**Design:** replace the 1-deep `h_full` handoff with a small synchronous FIFO (registers/MLAB, single clock). Payload = `{ca,cb,cg,cr[8b each]=32, dst_qw[15], dst_lane[2], qtag[24], texlane[2]}` = 75 bits. Still no prefetch yet — `pa` fills the FIFO, `pb` drains it demand-fetching; the decoupling lets `pa` race ahead so a *later* prefetch (Task 3) has slots to work on. `texwait` should already dip slightly (pa's demand read for pixel N+1 can be issued while pb blends N).

- [ ] **Step 1: Add FIFO declarations**

Near `:420` (by the sub-FSM state decls), add:

```systemverilog
    localparam integer TEXFIFO_D  = 16;
    localparam integer TEXFIFO_AW = 4;      // $clog2(TEXFIFO_D)
    localparam integer PW = 32+15+2+24+2;   // payload width = 75
    reg  [PW-1:0] pf_mem [0:TEXFIFO_D-1];
    reg  [TEXFIFO_AW:0] pf_wr, pf_rd;       // extra MSB for full/empty disambiguation
    wire pf_empty = (pf_wr == pf_rd);
    wire pf_full  = (pf_wr[TEXFIFO_AW-1:0]==pf_rd[TEXFIFO_AW-1:0]) && (pf_wr[TEXFIFO_AW]!=pf_rd[TEXFIFO_AW]);
    wire [PW-1:0] pf_head = pf_mem[pf_rd[TEXFIFO_AW-1:0]];
```

Reset (`:595`): add `pf_wr<=0; pf_rd<=0;`.

- [ ] **Step 2: `pa` — push payload to FIFO (replace h_full)**

Rewrite `A_ISSUE` to push into the FIFO when not full (drop the `h_*` handoff regs — the FIFO carries the payload). Keep the fill-if-not-resident-and-idle logic from Task 1:

```systemverilog
            A_ISSUE: if (!pf_full) begin
                if (!tq_hit({3'd0, tri_p0_addr[26:3]}) && !fill_busy) begin
                    tri_p0_rd  <= 1'b1;
                    fill_busy  <= 1'b1;
                    fill_slot  <= tri_p0_addr[3+:TEXQ_AW];
                    fill_tag   <= tri_p0_addr[3+TEXQ_AW +: 16];
                end
                pf_mem[pf_wr[TEXFIFO_AW-1:0]] <=
                    {ca_q, cb_q, cg_q, cr_q, dst_qw_q, dst_lane_q, tri_p0_addr[26:3], tex_lane_q};
                pf_wr <= pf_wr + 1'b1;
                pa<=A_PIX;
            end
```

- [ ] **Step 3: `pb` — pop the FIFO head, resolve via BRAM**

Replace `B_IDLE`/`B_GOT`/`B_FILL` so `pb` waits on `!pf_empty`, unpacks `pf_head`, pops, then resolves the texel exactly as Task-1 `B_FILL`:

```systemverilog
            B_IDLE: if (!pf_empty) begin
                {b_ca, b_cb, b_cg, b_cr, b_dst_qw, b_dst_lane, b_qtag, b_tex_lane} <= pf_head;
                pf_rd <= pf_rd + 1'b1;
                pb <= B_FILL;
            end
            B_FILL: begin
                // (unchanged from Task 1 Step 6: tq_hit -> latch texel_q -> B_DSTW/B_WR;
                //  miss & !fill_busy -> demand-fetch; else wait)
            end
```

Delete the `B_GOT` state and the `h_*` handoff declarations (`:425-429`) now that the FIFO replaces them. Remove `h_full` from reset (`:595`) and the triangle-drain condition.

- [ ] **Step 4: Fix the triangle-drain condition**

At `:1185`, replace `if ((pa==A_DONE) && (pb==B_IDLE) && !h_full)` with the FIFO-empty + arbiter-idle version:

```systemverilog
            if ((pa==A_DONE) && (pb==B_IDLE) && pf_empty && !fill_busy)
                state<=S_TRI_NEXT;
```

- [ ] **Step 5: Run — bit-exact, texwait ≤ baseline**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_trilist_pipe 2>&1 | grep -E 'PERF|RESULT'`
Expected: `RESULT: PASS`; `texwait` ≈ or slightly below the Task-0 baseline (decoupling alone gives a small overlap; the big drop is Task 3). No hang (`to` real, `< 4000000`).

- [ ] **Step 6: Commit**

```bash
git add fpga/rtl/blitter_top.sv
git commit -m "trilist: depth-D payload FIFO decouples pa from pb

Replace the single-deep h_full handoff with a TEXFIFO_D-deep synchronous
payload FIFO (colour, dst, qtag, texlane). pa now runs up to D pixels
ahead of pb; pb pops and resolves the texel from the local BRAM. Still
demand-fetch only (no prefetch yet). Bit-exact; single-outstanding."
```

---

## Task 3: Best-effort prefetch (the win)

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` — `pa` walk (`A_PIX`/`A_MUL`/`A_ADDR2`) so the fill is kicked as early as the qword address is known, and give pa a standing prefetch for the FIFO's not-yet-resident head-of-window qtag.
- Modify: `fpga/sim/tb_blitter_trilist_pipe.sv` — add a texwait-drop assertion.
- Test: `run_sims.sh`.

**Interfaces:**
- Consumes: `tq_hit`, `fill_busy`, and the qtag stream pa already computes.
- Produces: `texwait` → ~0 in the faithful stub (pb almost never stalls); the assertion locks it.

**Design:** Task 1/2 already issue a fill at `A_ISSUE` when the arbiter is idle. The remaining win is coverage: whenever the arbiter is idle and pa knows an upcoming not-resident qtag, kick it — so fills stream ahead of pb's consumption instead of only at the single `A_ISSUE` moment. Because pa runs `TEXFIFO_D` ahead (Task 2), most of pb's texels are resident by the time pb pops them.

- [ ] **Step 1: Issue the fill one cycle earlier (at A_ADDR2, when texbyte is known)**

In `A_ADDR2` (`:1036-1044`), after computing `tri_p0_addr`/`tex_lane_q`, kick the prefetch immediately if idle and not resident (so the fill overlaps the `A_ISSUE`→FIFO push and pb's blend of earlier pixels):

```systemverilog
            A_ADDR2: begin
                texbyte = c_src_off + tex_row + (itu_q<<<1);
                tri_p0_addr <= texbyte[26:0] & ~27'h7;
                tex_lane_q  <= texbyte[2:1];
                if (!tq_hit(texbyte[26:3]) && !fill_busy) begin
                    tri_p0_rd <= 1'b1;
                    fill_busy <= 1'b1;
                    fill_slot <= texbyte[3+:TEXQ_AW];
                    fill_tag  <= texbyte[3+TEXQ_AW +: 16];
                end
                pa<=A_ISSUE;
            end
```

Then simplify `A_ISSUE` to *only* push the payload (the fill was already kicked here or is still in flight; `B_FILL`'s demand path is the safety net):

```systemverilog
            A_ISSUE: if (!pf_full) begin
                pf_mem[pf_wr[TEXFIFO_AW-1:0]] <=
                    {ca_q, cb_q, cg_q, cr_q, dst_qw_q, dst_lane_q, tri_p0_addr[26:3], tex_lane_q};
                pf_wr <= pf_wr + 1'b1;
                pa<=A_PIX;
            end
```

- [ ] **Step 2: Run — texwait should collapse**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_trilist_pipe 2>&1 | grep -E 'PERF|RESULT'`
Expected: `RESULT: PASS`; `texwait` **far below** the Task-0 baseline (target: a small fraction of it — pb rarely stalls because upcoming lines are prefetched). `dpath` ≈ unchanged (datapath untouched). Record the new `tri/texwait/dpath`.

- [ ] **Step 3: Add the texwait-drop assertion to the TB**

In `tb_blitter_trilist_pipe.sv`, after the PERF `$display` (`:141-143`), add a regression gate. Set `TEXWAIT_MAX` to a value between the Task-3 result and the Task-0 baseline (e.g. half the baseline):

```systemverilog
    // Lever-1 regression gate: prefetch must keep pb's texel stall well below the
    // pre-prefetch baseline (Task-0 stub). Tighten TEXWAIT_MAX to the measured
    // Task-3 texwait + margin once stable.
    if (blt.perf_texwait_cyc > TEXWAIT_MAX) begin
      $display("RESULT: FAIL (texwait=%0d > TEXWAIT_MAX=%0d — prefetch regressed)",
               blt.perf_texwait_cyc, TEXWAIT_MAX);
      $finish;
    end
```

Add `localparam TEXWAIT_MAX = <value>;` near the TB's other localparams (`:15-16`). Choose `<value>` from the recorded numbers.

- [ ] **Step 4: Run — assertion passes**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_trilist_pipe 2>&1 | grep RESULT` → `RESULT: PASS`.

- [ ] **Step 5: Whole-suite green + commit**

Run: `cd fpga/sim && ./run_sims.sh 2>&1 | tail -30` — only the two pre-existing fails.

```bash
git add fpga/rtl/blitter_top.sv fpga/sim/tb_blitter_trilist_pipe.sv
git commit -m "trilist: best-effort texel prefetch — Lever 1 win

Kick the P_SRC fill as soon as texbyte is known (A_ADDR2) whenever the
arbiter is idle and the qword is not resident, so fills stream ahead of
pb's consumption across the FIFO window. texwait collapses in the
faithful-stub sim; dpath unchanged; bit-exact. Adds a texwait-drop
regression assertion to the TB."
```

---

## Task 4: Tune N (cache) and D (FIFO)

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` — `TEXQ_N`/`TEXQ_AW`, `TEXFIFO_D`/`TEXFIFO_AW`.
- Test: `run_sims.sh`.

**Interfaces:** no interface change — parameter sweep only.

- [ ] **Step 1: Sweep and record**

For `TEXQ_N ∈ {64, 128, 256, 512}` (update `TEXQ_AW` to `$clog2`) and `TEXFIFO_D ∈ {8, 16, 32}` (update `TEXFIFO_AW`), run `./run_sims.sh tb_blitter_trilist_pipe` and record `texwait`/`dpath`/`RESULT` for each. Keep bit-exact (`RESULT: PASS`) at every point.

- [ ] **Step 2: Pick the knee**

Choose the smallest `(TEXQ_N, TEXFIFO_D)` at the texwait knee (further increase gives diminishing return) — minimize BRAM while `texwait` stays near its floor. Set those as the defaults; update `TEXWAIT_MAX` in the TB to the chosen config's texwait + small margin.

- [ ] **Step 3: Commit**

```bash
git add fpga/rtl/blitter_top.sv fpga/sim/tb_blitter_trilist_pipe.sv
git commit -m "trilist: tune texel cache N + FIFO depth to the texwait knee

Sweep recorded in the commit body: <paste the N/D -> texwait table>.
Chosen: TEXQ_N=<n>, TEXFIFO_D=<d>. Retighten TEXWAIT_MAX."
```

---

## Task 5: Quartus/Windows RBF build + STA

**Files:**
- No RTL change. Build via the canonical Windows Quartus runner (do NOT substitute the Linux fallback).

**Interfaces:** produces a `MalditaCastilla_YYYYMMDD.rbf` + a fitter/STA report.

- [ ] **Step 1: Push milestone-a and trigger the build**

```bash
git push origin milestone-a
gh run watch   # ~9 min; the canonical build is the self-hosted Windows Quartus runner
```

- [ ] **Step 2: Check STA — the fragile domains**

From the fitter/STA report, confirm:
- **fabric emu-pll (clk_sys) domain worst setup slack > 0** (the added BRAM read + tag compare must not push it negative). Prior close was +0.47ns.
- **`pll_hdmi` divclk path** not newly failing (it is placement-fragile, swung −0.017→−0.240ns across builds — variance, not this change, but confirm it didn't worsen materially). If the emu-pll domain regresses <0, register the tag compare / BRAM read output an extra cycle and re-sim bit-exact before rebuilding.

- [ ] **Step 3: Download the RBF**

```bash
gh run download <run-id> -n <rbf-artifact>   # -> MalditaCastilla_YYYYMMDD.rbf
```

---

## Task 6: Deploy + on-device A/B + visual validation

**Files:** none — device bring-up via `mister-gmloader/scripts/mister_run.sh`.

**Interfaces:** the `fabric` preset sets `GMLOADER_MFSUBMIT_STAT=1`; bench reads `fabric_ms[frame/tri/texwait/dpath]` + `to=`.

- [ ] **Step 1: Stage both RBFs on the device (for a true A/B)**

Keep the prior (pre-prefetch) RBF alongside the new one under `/media/fat/_Other/`:

```bash
scp .../MalditaCastilla_YYYYMMDD.rbf root@192.168.20.81:/media/fat/_Other/
# (the prior milestone-a RBF should already be there; if not, scp it too)
```

- [ ] **Step 2: Load the new RBF + bench**

```bash
ssh root@192.168.20.81 'echo "load_core /media/fat/_Other/MalditaCastilla_YYYYMMDD.rbf" > /dev/MiSTer_cmd'
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
scripts/mister_run.sh bench --secs 22 --preset fabric
```

Expected: `to=0` (no hang), and **`texwait` dropped** vs the prior RBF with a corresponding **`frame` drop** (target frame ~26ms → ~15-18ms on a fabric-bound in-game scene; the menu/title is GM-logic-bound so menu fps is ~unchanged — bench an in-game scene).

- [ ] **Step 3: Controlled A/B at the same scene**

Load the prior RBF back-to-back at the *same* scene and bench again; diff the two `fabric_ms` breakdowns. Confirm the `texwait`/`frame` delta is the prefetch win, not scene drift.

- [ ] **Step 4: Visual correctness**

This touches the texel path — inspect the running game for **texel sampling artifacts** (wrong/garbled texels, seams, flicker), not just perf. A prefetch/eviction bug that somehow escaped the golden gate would show as wrong texels. If clean and `to=0` with the texwait drop, the milestone is confirmed.

- [ ] **Step 5: Record the result**

Update the memory note (`on-device-bench-harness-and-baseline` / a new `trilist-lever1-*`) with the device A/B numbers (frame/tri/texwait/dpath before vs after), the chosen `TEXQ_N`/`TEXFIFO_D`, and the STA slacks. Leave the device with the new RBF loaded.

---

## Self-Review

**Spec coverage:**
- Decoupled prefetch FIFO → Task 2. Qword-granular direct-mapped cache → Task 1. P_SRC fill arbiter (single-owner, demand-priority) → Task 1 (arbiter) + Task 3 (prefetch coverage). Always-listening catcher → Task 1 Step 4. Per-command invalidation → Task 1 Step 3. Faithful sim model → Task 0. Texwait-drop assertion → Task 3 Step 3. Tune N/D → Task 4. STA (emu-pll >0, HDMI) → Task 5. Device A/B + visual → Task 6. All spec sections mapped.

**Placeholder scan:** The only intentional fill-ins are numeric tuning values (`LINE_LOG2`, `TEXWAIT_MAX`, chosen `TEXQ_N`/`TEXFIFO_D`, `<run-id>`, RBF date) — each has an explicit measure-then-set step, which is correct for a tuning/build/deploy task, not a hidden TODO.

**Type/name consistency:** `tq_data`/`tq_tag`/`tq_valid`/`tq_hit`, `fill_busy`/`fill_slot`/`fill_tag`, `pf_mem`/`pf_wr`/`pf_rd`/`pf_full`/`pf_empty`/`pf_head`, `b_qtag`/`b_tex_lane`, `B_FILL`, `TEXQ_N`/`TEXQ_AW`/`TEXFIFO_D`/`TEXFIFO_AW`/`PW`/`TEXWAIT_MAX` — used consistently across Tasks 1-4. The Task-1 `h_qtag` handoff field is introduced then removed in Task 2 when the FIFO replaces the handoff (noted in both tasks).

**Note for the implementer:** the RTL FSM edits (Tasks 1-3) are in-place surgery on a 1400-line module; the **bit-exact golden gate (`RESULT: PASS`) is the real test at every step** — if an edit compiles but breaks the diff, the edit is wrong, not the test. Do not "fix" the golden. If an intermediate step won't compile because a decl was removed too early, keep the old decl until the referencing code is gone (called out in Task 1 Step 4 and Task 2 Step 3).

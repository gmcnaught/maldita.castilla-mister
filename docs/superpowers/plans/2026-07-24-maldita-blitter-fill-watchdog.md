# Blitter fill_busy self-heal watchdog — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an RTL liveness watchdog to `blitter_top.sv` that force-clears a stuck `fill_busy` (lost `p0_ok` SDRAM texel-fetch strobe) so the fabric self-heals instead of hanging frame 1, and expose a device-readable fire-count.

**Architecture:** An always-compiled saturating counter increments while `fill_busy && !p0_ok`; at `WD_TIMEOUT` it pulses `wd_fire`, and the always-listening catcher in `S_TRI_PIX` synthesizes a fill-completion (set `tq_tag`/`tq_valid`, clear `fill_busy`, leave `tq_data` stale) so the `pb` FSM re-reads a HIT and makes forward progress. A saturating `wd_fire_count` is published in `C_STATUS.low[31:8]` at frame completion.

**Tech Stack:** SystemVerilog (`blitter_top.sv`), Icarus Verilog sim (`iverilog`/`vvp` via `fpga/sim/run_sims.sh`), Quartus 17.0 Lite RBF build (Windows CI).

## Global Constraints

- **RTL-only.** No reference-model (`fpga/sim/blt_tri.c`), host (gmloader), protocol, or golden `.hex` change. The watchdog is hardware liveness with no functional-golden counterpart.
- **Bit-exact preserved.** Every existing `tb_blitter_trilist_*` / `tb_blitter_system_pipe` golden stays byte-identical; the watchdog must NEVER fire in any existing bench.
- **`WD_TIMEOUT = 13'd4096`.** ≫ the sim P_SRC stub's `MISS_LAT=140`, so it never fires in sim.
- **Recovery = synthetic hit, stale data.** On `wd_fire`: set `tq_tag[fill_slot]`/`tq_valid[fill_slot]`, clear `fill_busy`; do NOT write `tq_data`. `p0_ok` keeps priority over `wd_fire`.
- **Observability in `C_STATUS.low[31:8]`.** Preserve bits `[1:0]` (`osd_fps_on`, `osd_restart_pending`); `[7:2]` stay 0. Do not touch `C_STATUS.hi`.
- **`blitter_top.sv` uses `default_nettype none`** — declare every reg/wire before use; no forward references (place declarations with the existing `fill_busy` decls near line 543).
- **Sim runner:** `cd fpga/sim && ./run_sims.sh [tb_name]`. Pre-existing failures NOT caused by this work: `tb_scanout_fbram`, `tb_audio_burst_wedge` (and, at `--tier=nightly`, `FABRIC-ASSERT` on `tb_blitter_trilist_*`). New benches are auto-discovered (no per-tb `.mk`).
- **RBF build** = GitHub Actions `Build Maldita RBF` (self-hosted Windows, Quartus 17.0 Lite), ~12 min; the fabric `emu` clock is placement-fragile.

---

### Task 1: Watchdog self-heal + withhold-`p0_ok` bench (RED → GREEN) + bit-exact regression

**Files:**
- Create: `fpga/sim/tb_blitter_fill_watchdog.sv` (copy of `tb_blitter_trilist_pipe.sv` + a withhold knob)
- Modify: `fpga/rtl/blitter_top.sv` (decls near `:543`; reset near `:740`; counter after the perf block near `:770`; catcher at `:1111`)

**Interfaces:**
- Consumes (existing, unchanged): `fill_busy` (`reg`, `:543`), `fill_slot` (`reg [TEXQ_AW-1:0]`, `:544`), `fill_tag` (`reg [TEXQ_TW-1:0]`, `:545`), `tq_data`/`tq_tag`/`tq_valid` arrays, `p0_ok` (`input`, `:70`), the `S_TRI_PIX` catcher block (`:1104-1116`).
- Produces (used by Task 2): `reg [23:0] wd_fire_count;` — saturating count of watchdog fires, reset only on `rst`.

- [ ] **Step 1: Create the withhold-`p0_ok` bench**

Copy the working trilist bench, then inject a lost-strobe fault and change the pass criteria (the recovered texel is intentionally wrong, so this bench does NOT assert bit-exact pixels — it asserts the frame *completes* and the watchdog *fired*).

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
cp tb_blitter_trilist_pipe.sv tb_blitter_fill_watchdog.sv
```

In `tb_blitter_fill_watchdog.sv`, edit the module name (first `module ...` line) from `tb_blitter_trilist_pipe` to `tb_blitter_fill_watchdog`.

In the P_SRC stub, add the withhold state. Immediately AFTER this existing line (the resident-line init, ~`:56`):

```systemverilog
  initial for (li=0; li<NLINES; li=li+1) begin rline[li]=27'h7FFFFFF; rline_v[li]=1'b0; end
```

insert:

```systemverilog
  // [watchdog test] emulate a LOST p0_ok strobe on the Nth accepted read: complete the
  // latency countdown but NEVER assert s_src_ok, so the DUT's fill_busy stays latched.
  localparam integer WITHHOLD_FILL = 1;   // first texel fill of the frame
  integer fill_num = 0;
```

In the same stub's accept branch, record the fill number. Change:

```systemverilog
    if ((s_src_rd & ~s_rd_d) && !so_busy) begin
      so_busy <= 1'b1;
      so_addr <= s_src_addr;
```

to:

```systemverilog
    if ((s_src_rd & ~s_rd_d) && !so_busy) begin
      so_busy <= 1'b1;
      so_addr <= s_src_addr;
      fill_num = fill_num + 1;
```

In the stub's completion branch, withhold the strobe for the chosen fill. Change:

```systemverilog
    if (so_busy) begin
      if (so_cnt <= 1) begin
        s_src_dout <= mem[SRC_WIN + (so_addr >> 3)];
        s_src_ok   <= 1'b1;
        so_busy    <= 1'b0;
      end else so_cnt <= so_cnt - 1;
    end
```

to:

```systemverilog
    if (so_busy) begin
      if (so_cnt <= 1) begin
        if (fill_num == WITHHOLD_FILL) begin
          // WITHHOLD: drop p0_ok — stub goes idle, DUT fill_busy stays latched (hang
          // until the watchdog fires). No s_src_ok, no s_src_dout.
          so_busy <= 1'b0;
        end else begin
          s_src_dout <= mem[SRC_WIN + (so_addr >> 3)];
          s_src_ok   <= 1'b1;
          so_busy    <= 1'b0;
        end
      end else so_cnt <= so_cnt - 1;
    end
```

Replace the final pass/fail check (the block at ~`:161-175`, from `bad=0;` through the `RESULT: PASS/FAIL` and `$finish;`) with a **completion-only** check (no `wd_fire_count` yet — that reg does not exist until Step 3, so referencing it here would be a compile error instead of a genuine hang RED). Find:

```systemverilog
    bad=0;
```

...and replace the whole compare-and-report block down to `$finish;` with:

```systemverilog
    // [watchdog test] the withheld fill is recovered with STALE texel data, so pixels
    // are intentionally wrong — do NOT assert bit-exact. Success = the frame COMPLETED
    // (done==submit, no hang). Task 1 Step 3 adds the wd_fire_count==1 assertion.
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0])
      $display("RESULT: PASS");
    else
      $display("RESULT: FAIL (done=%0d submit=%0d)",
               mem[32'h200005][31:0], mem[32'h200000][31:0]);
    $finish;
```

(`blt` is the `blitter_top` instance name at `:93`; the `wd_fire_count` hierarchical ref is added in Step 3.)

- [ ] **Step 2: Run the bench to verify it FAILS (RED — hang)**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim && ./run_sims.sh tb_blitter_fill_watchdog
```
Expected: compiles and runs, then FAILs via the timeout guard — `RESULT: FAIL (timeout)`. The withheld first fill hangs the un-modified blitter (`fill_busy` never clears → `pb` parks in `B_WAIT` forever), so `done` never reaches `submit` and the `#200000000`-ns guard trips. This proves the bench genuinely detects the hang (non-vacuous RED).

- [ ] **Step 3: Implement the watchdog in `blitter_top.sv`**

**(a) Declarations** — immediately after the `fill_tag` declaration (`:545`):

```systemverilog
    reg  [TEXQ_TW-1:0] fill_tag;            // tag the in-flight fill will stamp
    // [fill watchdog] self-heal a lost p0_ok strobe (permanent B_WAIT hang, no timeout).
    // Always compiled (distinct from the ifdef'd fill_run diag below).
    localparam [12:0] WD_TIMEOUT = 13'd4096;   // ~42us @ ~98MHz; >> sim MISS_LAT=140 so never fires in sim
    reg  [12:0] wd_stall;                   // continuous (fill_busy && !p0_ok) cycles, saturates at WD_TIMEOUT
    reg  [23:0] wd_fire_count;              // saturating count of watchdog fires (reset only on rst)
    wire        wd_fire = (wd_stall == WD_TIMEOUT);
```
(The line shown for context already exists; add only the four new lines.)

**(b) Reset** — in the main FSM reset branch, extend the existing line (`:740`):

```systemverilog
            fill_busy<=1'b0; tq_valid<={TEXQ_N{1'b0}}; last_pf_qtag<=24'hFFFFFF;
```
to:
```systemverilog
            fill_busy<=1'b0; tq_valid<={TEXQ_N{1'b0}}; last_pf_qtag<=24'hFFFFFF;
            wd_stall<=13'd0; wd_fire_count<=24'd0;
```

**(c) Counter** — in the main FSM `else` branch, immediately AFTER the perf-accumulation block that ends at `:770` (the `end` closing `if (!idle) begin`), and BEFORE `case (state)` (`:772`):

```systemverilog
            // [fill watchdog] count continuous fill-stall cycles; saturate at WD_TIMEOUT.
            if (fill_busy && !p0_ok) begin
                if (wd_stall != WD_TIMEOUT) wd_stall <= wd_stall + 13'd1;
            end else wd_stall <= 13'd0;
```

**(d) Synthetic completion** — extend the always-listening catcher (`:1111-1116`). Change:

```systemverilog
                if (fill_busy && p0_ok) begin
                    tq_data[fill_slot]  <= p0_dout;
                    tq_tag[fill_slot]   <= fill_tag;
                    tq_valid[fill_slot] <= 1'b1;
                    fill_busy           <= 1'b0;
                end
```
to:
```systemverilog
                if (fill_busy && p0_ok) begin
                    tq_data[fill_slot]  <= p0_dout;
                    tq_tag[fill_slot]   <= fill_tag;
                    tq_valid[fill_slot] <= 1'b1;
                    fill_busy           <= 1'b0;
                end else if (fill_busy && wd_fire) begin
                    // [fill watchdog] synthesize a completion with STALE tq_data so the
                    // pb FSM re-reads a HIT and makes forward progress (few wrong texels
                    // vs a permanent hang). tq_data intentionally left unwritten.
                    tq_tag[fill_slot]   <= fill_tag;
                    tq_valid[fill_slot] <= 1'b1;
                    fill_busy           <= 1'b0;
                    wd_fire_count       <= (wd_fire_count==24'hFFFFFF) ? wd_fire_count
                                                                       : wd_fire_count + 24'd1;
                end
```

**(e) Strengthen the bench assertion** — now that `wd_fire_count` exists, make the bench prove the watchdog actually fired (not a vacuous pass). In `fpga/sim/tb_blitter_fill_watchdog.sv`, change:

```systemverilog
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0])
      $display("RESULT: PASS");
    else
      $display("RESULT: FAIL (done=%0d submit=%0d)",
               mem[32'h200005][31:0], mem[32'h200000][31:0]);
```
to:
```systemverilog
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && blt.wd_fire_count==24'd1)
      $display("RESULT: PASS (wd_fire_count=%0d)", blt.wd_fire_count);
    else
      $display("RESULT: FAIL (done=%0d submit=%0d wd_fire_count=%0d)",
               mem[32'h200005][31:0], mem[32'h200000][31:0], blt.wd_fire_count);
```

- [ ] **Step 4: Run the bench to verify it PASSES (GREEN)**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim && ./run_sims.sh tb_blitter_fill_watchdog
```
Expected: `RESULT: PASS (wd_fire_count=1)` — the withheld fill is force-completed at `WD_TIMEOUT`, the frame reaches `done==submit`, and the watchdog fired exactly once.

- [ ] **Step 5: Run the full suite — existing goldens stay bit-exact**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim && ./run_sims.sh
```
Expected: all `tb_blitter_trilist_{pipe,key,calpha,add,quad}`, `tb_blitter_system_pipe`, `tb_blitter_copy_pipe`, `tb_surfram`, `tb_blitter_surface_src` = PASS with `bad=0` (watchdog never fires — `wd_fire` stays 0 because no fill exceeds 140 cyc). ONLY the known pre-existing failures remain (`tb_scanout_fbram`, `tb_audio_burst_wedge`). If any previously-passing bench changes result, STOP — the watchdog is perturbing the healthy path.

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git add fpga/rtl/blitter_top.sv fpga/sim/tb_blitter_fill_watchdog.sv
git commit -m "feat(fabric): fill_busy self-heal watchdog + withhold-p0_ok bench

Force-clear a stuck fill_busy (lost p0_ok) at WD_TIMEOUT via a synthetic
cache-hit (stale texel) so the blitter self-heals instead of hanging frame 1.
New tb_blitter_fill_watchdog: RED (hang) without, GREEN (frame completes,
wd_fire_count==1) with. Full suite bit-exact (watchdog never fires; goldens
unchanged).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LA7TST2iRjejQp2v2TE3wt"
```

---

### Task 2: Observability — publish `wd_fire_count` to `C_STATUS.low[31:8]`

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (`S_WR_STATUS` publish, `:1480` and `:1482`)
- Modify: `fpga/sim/tb_blitter_fill_watchdog.sv` (assert the published word)

**Interfaces:**
- Consumes: `wd_fire_count` (from Task 1). Control block C_STATUS qword = `mem[32'h200006]` in the bench (C_DONE is `mem[32'h200005]`).
- Produces: device-readable fire-count at `0x3B000030`, bits `[31:8]`.

- [ ] **Step 1: Add the published-word assertion to the bench (RED)**

In `tb_blitter_fill_watchdog.sv`, change the PASS condition (added in Task 1 Step 1) to also require the published fire-count. Find:

```systemverilog
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && blt.wd_fire_count==24'd1)
      $display("RESULT: PASS (wd_fire_count=%0d)", blt.wd_fire_count);
    else
      $display("RESULT: FAIL (done=%0d submit=%0d wd_fire_count=%0d)",
               mem[32'h200005][31:0], mem[32'h200000][31:0], blt.wd_fire_count);
```
and replace with:

```systemverilog
    // published fire-count = C_STATUS.low[31:8] (0x3B000030 >> 8); OSD bits [1:0] preserved.
    if (mem[32'h200005][31:0]==mem[32'h200000][31:0] && blt.wd_fire_count==24'd1
        && mem[32'h200006][31:8]==24'd1)
      $display("RESULT: PASS (wd_fire_count=%0d published=%0d)",
               blt.wd_fire_count, mem[32'h200006][31:8]);
    else
      $display("RESULT: FAIL (done=%0d submit=%0d wd_fire_count=%0d published=%0d)",
               mem[32'h200005][31:0], mem[32'h200000][31:0],
               blt.wd_fire_count, mem[32'h200006][31:8]);
```

- [ ] **Step 2: Run the bench to verify it FAILS (RED)**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim && ./run_sims.sh tb_blitter_fill_watchdog
```
Expected: `RESULT: FAIL (... published=0)` — the watchdog fires and recovers, but `C_STATUS.low[31:8]` is still 0 (not yet published).

- [ ] **Step 3: Publish `wd_fire_count` in `S_WR_STATUS`**

In `blitter_top.sv`, change the `ifdef` (debug) branch (`:1480`):

```systemverilog
                bm_din<={wedge_snap2, 30'd0, osd_fps_on, osd_restart_pending};
```
to:
```systemverilog
                bm_din<={wedge_snap2, wd_fire_count, 6'd0, osd_fps_on, osd_restart_pending};
```

and change the `else` (shipping) branch (`:1482`):

```systemverilog
                bm_din<={perf_texwait_cyc, 30'd0, osd_fps_on, osd_restart_pending};
```
to:
```systemverilog
                bm_din<={perf_texwait_cyc, wd_fire_count, 6'd0, osd_fps_on, osd_restart_pending};
```
(Both keep the 64-bit width: `hi32` unchanged + `low32 = {wd_fire_count[23:0], 6'd0, osd_fps_on, osd_restart_pending}`.)

- [ ] **Step 4: Run the bench to verify it PASSES (GREEN)**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim && ./run_sims.sh tb_blitter_fill_watchdog
```
Expected: `RESULT: PASS (wd_fire_count=1 published=1)`.

- [ ] **Step 5: Run the full suite — still bit-exact**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim && ./run_sims.sh
```
Expected: unchanged from Task 1 Step 5 — all previously-passing benches PASS `bad=0` (the C_STATUS.low change only adds `wd_fire_count==0` into bits `[31:8]` on the healthy path, which no bench asserts on; the OSD bits `[1:0]` and `C_STATUS.hi` are untouched). Only the known pre-existing failures remain.

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git add fpga/rtl/blitter_top.sv fpga/sim/tb_blitter_fill_watchdog.sv
git commit -m "feat(fabric): publish watchdog fire-count to C_STATUS.low[31:8]

Device reads (devmem 0x3B000030 >> 8) & 0xFFFFFF to see watchdog fires
(saturating, cumulative since core load). Preserves the [1:0] OSD mirror
bits and C_STATUS.hi. Bench asserts the published word == 1.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01LA7TST2iRjejQp2v2TE3wt"
```

---

### Task 3: RBF build + STA + device verification (user / CI-gated)

**Not a code task** — this is the definition-of-done gate. It requires the Windows RBF build and physical-device access, so it is driven by the human partner (per the standing device-auth rule: build + deploy autonomously, but ask before running on hardware).

- [ ] **Step 1: Push to trigger the RBF build**

Pushing `milestone-a` (touching `fpga/**`) triggers `Build Maldita RBF` (self-hosted Windows, Quartus 17.0 Lite, ~12 min).
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister && git push origin milestone-a
```

- [ ] **Step 2: Fetch RBF + STA when the run succeeds**

```bash
gh run download <run-id> -n maldita-rbf -D _Other
gh run download <run-id> -n quartus-reports -D _Other/qreports
```
Check `_Other/qreports/output_files/Maldita.sta.summary` — the fabric `emu general[0]` slack. Expected in the runs-on-hardware band (the counter+compare should not materially worsen it); the worst path is usually `pll_hdmi` (framework, out of scope). If `emu` regressed sharply, the `wd_fire`→catcher path may have landed on the tag-mux critical path — revisit the STA watch-item in the spec §6.

- [ ] **Step 3: Deploy (autonomous OK) then verify on device (ASK FIRST)**

Deploy the RBF: `./deploy.py --no-content` (or `scp` the RBF only). Then — **after** the human partner OKs hardware testing — verify via the WRAPPER path (the one that wedges): arm `main=`, MENU-bounce → load core → wrapper auto-launches. Expected: `C_DONE` tracks `C_SUBMIT` (no wedge), title screen renders. Read the fire-count:
```bash
ssh root@192.168.20.81 'V=$(busybox devmem 0x3B000030 32); python3 -c "print(\"wd_fires\", (int(\"'$V'\",16)>>8)&0xFFFFFF)"'
```
Interpret: a small boot-only count that then holds ⇒ one-shot race, watchdog IS the fix. Count climbing every frame (+ low fps) ⇒ broken timing regime, watchdog is masking — reopen the diagnosis (do NOT treat as done).

---

## Notes for the implementer

- `blt` is the DUT instance in the bench (`blitter_top blt(...)`, `:93`). Hierarchical refs (`blt.wd_fire_count`) work in Icarus.
- The withheld fill is recovered with stale `tq_data` (reset value / prior slot content), so the watchdog bench's frame is intentionally wrong-colored — that is why it asserts completion + fire-count, NOT `bad==0`.
- Do not touch the `SOLARUS_DBG_PROBES`-gated `fill_run`/`max_fill_run` diagnostic — it is a separate debug-only counter; the watchdog is always compiled.
- The surface path (`tri_src_surface`) never sets `fill_busy`, so the watchdog does not affect it.

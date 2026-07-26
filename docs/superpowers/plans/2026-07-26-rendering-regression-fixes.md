# Rendering Regression + Stall Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the arbiter defect behind the e338f3c texel regression and the ~430-frame stalls, close the sim coverage gap that hid Bug A, make the engine re-STAGE textures after discarded frames, and run the discriminating device experiments.

**Architecture:** The DDR arbiter (`ddr_blitter_arb.sv`) steers return beats by FSM state with no command↔beat binding; a mis-steered beat either poisons a STAGE texture write (texel corruption) or strands `G_BLT_RD`, which has no timeout (the stall). Fix = bounded borrow (symmetric with the reader's QUIET_MAX self-correct) + `blt_burstcnt!=0` guard. Separately: the TRILIST sim goldens verify only one u-address bit (8×8/stride-16 textures), so we add a 128×128 stride-256 coordinate-texture golden plus a real-`sdram_fb_cache` co-sim bench; and the engine's stage-once-per-page invariant breaks when a frame is discarded, so cache hits re-STAGE after any ring discard.

**Tech Stack:** SystemVerilog (Icarus iverilog/vvp at `/opt/homebrew/bin`), C (host golden generator + probes, armhf cross-build via Docker), C++ (gmloader engine host tests), MiSTer device at 192.168.20.62.

## Global Constraints

- **Bit-exact discipline:** every RTL change must keep `cd fpga/sim && ./run_sims.sh` green with all existing goldens BYTE-IDENTICAL. Known pre-existing failures that are NOT yours: `tb_audio_burst_wedge` (PR tier); `--tier=nightly` additionally has pre-existing FABRIC-ASSERT failures on `tb_blitter_trilist_{pipe,add,calpha,key,quad}`, `tb_scanout_fbram` artifacts, `tb_comp_replay` (non-gating).
- **Goldens:** regenerate with `cd fpga/sim && make -f gen_tri_golden.mk vectors` (REFMODEL is PINNED to `../../../gmloader-next/3rdparty/mfgpu/refmodel`; the contract-check must pass). Existing scenario vectors must regenerate byte-identical; only the NEW scenario adds files.
- **Tool PATH:** subagents do NOT inherit the interactive PATH. `export PATH="/opt/homebrew/bin:$PATH"` before using `iverilog`, `vvp`, `docker`, `python3`.
- **Protocol:** NO protocol/refmodel changes anywhere in this plan. The arbiter fix is liveness-only; the new golden scenario uses the existing TRILIST contract (opcode 10).
- **Repos:** RTL work in `~/MisterFPGA-Projects/maldita.castilla-mister` (branch `fix/launch-via-master-daemon-handler`); engine work in `~/MisterFPGA-Projects/gmloader-next` (commit on its current branch); probes also in gmloader-next.
- **Device:** `.62` = 192.168.20.62 (ssh root@, key auth). `.81` is wedging on reconfigure — do not use. Always restore device state after experiments (handler re-enable procedure is in each device task).
- **Commit style:** follow repo convention (`fix(scope): ...`, `test(sim): ...`); end commit messages with the standard Claude co-author trailer.

---

### Task 1: Bounded blitter borrow in `ddr_blitter_arb.sv` (TDD)

**Files:**
- Create: `fpga/sim/tb_arb_blt_timeout.sv`
- Modify: `fpga/rtl/ddr_blitter_arb.sv`

**Interfaces:**
- Consumes: existing `ddr_blitter_arb` port list (unchanged — no port changes allowed; `Maldita.sv` wiring must not change).
- Produces: same module, plus internal `BLT_QUIET_MAX`/`bquiet`/`blt_abort` and `b_burst_eff`. Task 6 (device A/B) relies on this commit being the ONLY RTL delta vs current HEAD.

Background (why): `G_BLT_RD`'s only exit is `ddram_dout_ready & (blt_out==8'd1)` (`ddr_blitter_arb.sv:136-137`) and `ddram_rd`/`ddram_we` are gated off in that state (`:160-161`), so a lost beat parks it **escape-free** — no master can issue the command whose return beat would exit it. Chain on device: `rdr_busy` stuck (`:147`) → `comp_fb_dma.mem_busy` stuck → `fb_dma_busy` high → blitter parks in `S_SNAP_DRAIN`. The reader side has a 400-cycle `QUIET_MAX` self-correct (`:82-92`); the blitter side has nothing. Also `blt_burstcnt==0` would arm `blt_out<=0` (read: exit unreachable; write: `0-1` underflows to 255) — a latent instant deadlock currently avoided only because `comp_pipeline` ties `mem_rd=0` while its `mem_burstcnt=0`.

- [ ] **Step 1: Write the failing test**

Create `fpga/sim/tb_arb_blt_timeout.sv`:

```verilog
// tb_arb_blt_timeout.sv — bounded-borrow (lost-beat) liveness for ddr_blitter_arb.
//
// Device evidence 2026-07-24/26: the arbiter parks in G_BLT_RD when a blitter
// read's return beat is lost (mis-steered/consumed elsewhere). That state gates
// ddram_rd/we off, so no master can issue the command whose beat would exit it:
// escape-free deadlock -> rdr_busy stuck -> comp_fb_dma stalls -> fb_dma_busy
// stuck -> blitter S_SNAP_DRAIN park (the recurring ~430-frame stalls).
//
//   RED  (today): DDR model swallows the first blitter read's beat -> arbiter
//                 sits in G_BLT_RD forever -> FAIL.
//   GREEN (fix):  BLT_QUIET_MAX bounded exit -> arbiter returns to G_READER,
//                 re-grants the still-asserted blt_rd (retry, reads idempotent),
//                 the retry's beat completes the blitter, and a subsequent
//                 reader burst is served in full -> PASS.
// Also covers the blt_burstcnt==0 arming guard (read AND write).
`timescale 1ns/1ps
`default_nettype none
module tb_arb_blt_timeout;
  reg clk=0, reset=1; always #5 clk=~clk;

  reg  [7:0]  r_burst=8'd4; reg [28:0] r_addr=0; reg r_rd=0; reg [63:0] r_din=0;
  reg  [7:0]  r_be=8'hFF; reg r_we=0; wire r_busy, r_grant;
  reg  [7:0]  b_burst=8'd1; reg [28:0] b_addr=0; reg b_rd=0; reg [63:0] b_din=0;
  reg  [7:0]  b_be=8'hFF; reg b_we=0; wire b_busy, b_grant;
  reg  ddr_busy=0, ddr_dready=0; reg [63:0] ddr_dout=64'd0;
  wire [7:0] d_burst; wire [28:0] d_addr; wire d_rd, d_we;
  wire [63:0] d_din; wire [7:0] d_be;

  ddr_blitter_arb #(.ENABLE(1'b1)) arb(.clk(clk),.reset(reset),
    .rdr_burstcnt(r_burst),.rdr_addr(r_addr),.rdr_rd(r_rd),.rdr_din(r_din),.rdr_be(r_be),.rdr_we(r_we),
    .rdr_busy(r_busy),.rdr_grant(r_grant),
    .blt_burstcnt(b_burst),.blt_addr(b_addr),.blt_rd(b_rd),.blt_din(b_din),.blt_be(b_be),.blt_we(b_we),
    .blt_busy(b_busy),.blt_grant(b_grant),
    .ddram_busy(ddr_busy),.ddram_dout_ready(ddr_dready),
    .ddram_burstcnt(d_burst),.ddram_addr(d_addr),.ddram_rd(d_rd),.ddram_din(d_din),.ddram_be(d_be),.ddram_we(d_we));

  // Behavioral DDR: accepts one read, latency 3, streams beats. `swallow` makes it
  // accept the NEXT read command but return ZERO beats (the lost-beat event).
  reg swallow=0;
  reg [7:0] beats_left=0; reg [3:0] lat_left=0;
  integer blt_beats=0, rdr_beats=0, cmds_seen=0;
  always @(posedge clk) begin
    ddr_dready <= 1'b0;
    if (reset) begin ddr_busy<=0; beats_left<=0; lat_left<=0; end
    else if (!ddr_busy) begin
      if (d_rd) begin
        cmds_seen = cmds_seen + 1;
        if (swallow) begin swallow<=0; ddr_busy<=0; end       // command eaten, no beats ever
        else begin beats_left<=d_burst; lat_left<=4'd3; ddr_busy<=1; end
      end
    end else if (lat_left != 0) lat_left <= lat_left - 4'd1;
    else if (beats_left != 0) begin
      ddr_dready <= 1'b1; ddr_dout <= 64'hFEED_0000 + beats_left;
      beats_left <= beats_left - 8'd1;
      if (beats_left == 8'd1) ddr_busy <= 1'b0;
    end
  end
  always @(posedge clk) if (ddr_dready) begin
    if (b_grant) blt_beats = blt_beats + 1;
    if (r_grant) rdr_beats = rdr_beats + 1;
  end

  integer errors=0, waitc;
  initial begin
    repeat(4) @(posedge clk); reset<=0; repeat(2) @(posedge clk);

    // ── Phase 1: lost-beat read. Model the real blitter: hold blt_rd through the wait.
    swallow<=1;
    b_burst<=8'd1; b_addr<=29'h100; b_rd<=1;
    // wait for the (doomed) command accept
    waitc=0; while(!(arb.state==3'd1 && !ddr_busy)) begin @(posedge clk); waitc=waitc+1;
      if (waitc>200) begin $display("RESULT: FAIL (blt cmd never accepted)"); $finish; end end
    // arbiter is now headed into G_BLT_RD with no beat ever coming.
    // GREEN: bounded exit + retry completes within ~BLT_QUIET_MAX + latency slack.
    waitc=0; while(blt_beats==0 && waitc<5000) begin @(posedge clk); waitc=waitc+1; end
    if (blt_beats==0) begin
      errors=errors+1;
      $display("FAIL: blitter beat never arrived (arb.state=%0d, parked %0d cyc) — G_BLT_RD unbounded", arb.state, waitc);
    end
    b_rd<=0;
    repeat(8) @(posedge clk);
    if (arb.state != 3'd0) begin errors=errors+1; $display("FAIL: arbiter not back in G_READER (state=%0d)", arb.state); end

    // ── Phase 2: reader service after the event — 4-beat burst must fully return.
    waitc=0; while(r_busy) begin @(posedge clk); waitc=waitc+1;
      if (waitc>5000) begin $display("RESULT: FAIL (reader locked out post-abort)"); $finish; end end
    r_addr<=29'h200; r_rd<=1; @(posedge clk);
    while(!(r_grant && !ddr_busy)) @(posedge clk);
    r_rd<=0;
    waitc=0; while(rdr_beats<4 && waitc<5000) begin @(posedge clk); waitc=waitc+1; end
    if (rdr_beats!=4) begin errors=errors+1; $display("FAIL: reader got %0d/4 beats", rdr_beats); end

    // ── Phase 3: blt_burstcnt==0 guard — read then write must both complete, not deadlock.
    blt_beats=0;
    b_burst<=8'd0; b_addr<=29'h140; b_rd<=1;      // pathological burstcnt=0 read
    waitc=0; while(blt_beats==0 && waitc<5000) begin @(posedge clk); waitc=waitc+1; end
    b_rd<=0;
    if (blt_beats==0) begin errors=errors+1; $display("FAIL: burstcnt=0 read deadlocked"); end
    repeat(8) @(posedge clk);
    if (arb.state != 3'd0) begin errors=errors+1; $display("FAIL: state=%0d after burstcnt=0 read", arb.state); end
    b_burst<=8'd0; b_addr<=29'h180; b_din<=64'hCAFE; b_we<=1;   // burstcnt=0 write
    waitc=0; @(posedge clk);
    while(arb.state != 3'd0 || b_we) begin
      @(posedge clk); waitc=waitc+1;
      if (arb.state==3'd0 && waitc>2) b_we<=0;    // accepted via the 1-beat shortcut -> release
      if (waitc>5000) begin $display("RESULT: FAIL (burstcnt=0 write deadlocked, state=%0d)", arb.state); $finish; end
    end

    if (errors==0) $display("RESULT: PASS (bounded borrow: lost beat retried, reader restored, burstcnt=0 guarded)");
    else           $display("RESULT: FAIL (%0d errors)", errors);
    $finish;
  end
  initial begin #2000000 $display("RESULT: FAIL (timeout)"); $finish; end
endmodule
`default_nettype wire
```

- [ ] **Step 2: Run it to verify it fails (RED)**

```bash
export PATH="/opt/homebrew/bin:$PATH"
cd ~/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
./run_sims.sh tb_arb_blt_timeout
```
Expected: `RESULT: FAIL` — phase 1's beat never arrives (unbounded G_BLT_RD park), or the phase-3 burstcnt=0 read deadlocks and the bench times out. Confirm the failure message names the park, not a bench bug.

- [ ] **Step 3: Implement the bounded borrow + burstcnt guard**

In `fpga/rtl/ddr_blitter_arb.sv`:

(a) After the `b_rd`/`b_we` gating wires (line ~62), add:

```verilog
    // [bounded borrow] a burstcnt of 0 would arm blt_out at 0 (reads: the G_BLT_RD
    // exit blt_out==1 becomes unreachable; writes: 0-1 underflows to 255) => instant
    // permanent deadlock. No current master emits 0 (comp_pipeline ties mem_rd off
    // while its mem_burstcnt=0) — this is a guard, not a behavior change.
    wire [7:0] b_burst_eff = (blt_burstcnt == 8'd0) ? 8'd1 : blt_burstcnt;
```

(b) After the `rdr_idle` assign (line ~100), add the blitter-side self-correct:

```verilog
    // [bounded borrow] symmetric self-correct for the BLITTER side. The reader's
    // rd_out has QUIET_MAX/drift_clr above; blt_out had NOTHING, and a G_BLT_RD
    // park is escape-free by construction: ddram_rd/we are gated off in that state,
    // so no master can issue the very command whose return beat would exit it
    // (device signature: fb_dma_busy stuck -> S_SNAP_DRAIN park -> recurring stalls).
    // On timeout, abandon the wait and return to G_READER. The blitter still holds
    // its mem_rd asserted through the wait (see the mux CRITICAL note below), so
    // the next reader-idle gap re-grants and RE-ISSUES the read — a retry, not a
    // data loss (reads are idempotent). BLT_QUIET_MAX >> any real f2h latency.
    localparam [10:0] BLT_QUIET_MAX = 11'd1024;
    reg [10:0] bquiet;
    always @(posedge clk) begin
        if (reset)                                        bquiet <= 11'd0;
        else if ((state != G_BLT_RD) | ddram_dout_ready)  bquiet <= 11'd0;
        else if (bquiet != BLT_QUIET_MAX)                 bquiet <= bquiet + 11'd1;
    end
    wire blt_abort = (bquiet >= BLT_QUIET_MAX);
```

(c) Replace the `blt_out` arming/decrement block (lines ~109-118) with:

```verilog
    always @(posedge clk) begin
        if (reset) blt_out <= 8'd0;
        else case (state)
            G_BLT:    if (b_rd & ~ddram_busy)      blt_out <= b_burst_eff; // arm read beats
                      else if (b_we & ~ddram_busy) blt_out <= b_burst_eff - 8'd1; // 1st write beat taken
            G_BLT_RD: if (blt_abort)                                   blt_out <= 8'd0;
                      else if (ddram_dout_ready & (blt_out!=8'd0))     blt_out <= blt_out - 8'd1;
            G_BLT_WR: if (b_we & ~ddram_busy & (blt_out!=8'd0)) blt_out <= blt_out - 8'd1;
            default: ;
        endcase
    end
```

(d) In the grant FSM, change the `G_BLT` write shortcut and `G_BLT_RD` exit:

```verilog
            G_BLT:
                if      (b_rd & ~ddram_busy)               state <= G_BLT_RD;  // await read beats
                else if (b_we & ~ddram_busy)
                    state <= (b_burst_eff==8'd1) ? G_READER : G_BLT_WR;        // 1-beat write done now
                else if (~b_rd & ~b_we)                    state <= G_READER;
                // else: blitter command stalled by ddram_busy -> hold G_BLT
            G_BLT_RD:
                if (ddram_dout_ready & (blt_out==8'd1))     state <= G_READER;  // last beat captured
                else if (blt_abort)                         state <= G_READER;  // [bounded borrow] lost beat -> retry
```

(e) In the output mux `else` branch (line ~159), forward the guarded burstcnt:

```verilog
            ddram_burstcnt = b_burst_eff; ddram_addr = blt_addr;
```

Do NOT change ports, `dbg`, the reader-side counters, or `G_BLT_WR` (a write stalled on `ddram_busy` means the whole f2h is dead — reader included — and no arbiter action helps).

- [ ] **Step 4: Run the new bench to verify it passes (GREEN)**

```bash
./run_sims.sh tb_arb_blt_timeout
```
Expected: `RESULT: PASS (bounded borrow: ...)`.

- [ ] **Step 5: Full suite — bit-exact gate**

```bash
./run_sims.sh
```
Expected: everything green except the documented pre-existing `tb_audio_burst_wedge`. Pay special attention to `tb_ddr_blitter_arb` (both modules), `tb_arb_borrow`, `tb_arb_reader_burst`, `tb_stage_psrc`, `tb_stage_psrc_sameframe`, `tb_blitter_system_pipe`, `tb_vram_contention` — all touch the arbiter and must be untouched functionally (BLT_QUIET_MAX=1024 is far above every model latency, so the abort must never fire in a healthy bench).

- [ ] **Step 6: Commit**

```bash
cd ~/MisterFPGA-Projects/maldita.castilla-mister
git add fpga/rtl/ddr_blitter_arb.sv fpga/sim/tb_arb_blt_timeout.sv
git commit -m "fix(arb): bounded G_BLT_RD borrow + blt_burstcnt!=0 guard

A lost return beat parked G_BLT_RD escape-free (ddram_rd/we are gated off
in that state, so nothing could ever generate the exiting dout_ready):
rdr_busy stuck -> comp_fb_dma never finishes -> fb_dma_busy stuck ->
S_SNAP_DRAIN park. The reader side has had a QUIET_MAX self-correct all
along; this is its blitter-side mirror, exiting to G_READER after 1024
quiet cycles so the still-asserted mem_rd re-issues (idempotent retry).
Also guards blt_burstcnt==0 arming (read exit unreachable / write count
underflow), previously safe only by accident of comp_pipeline's tie-off."
```

---

### Task 2: `tri_uvfull` golden — 128×128 stride-256 coordinate texture at non-zero src_off

**Files:**
- Modify: `fpga/sim/gen_tri_golden.c`
- Modify: `fpga/sim/gen_tri_golden.mk:32` (SCENARIOS)
- Create: `fpga/sim/tb_blitter_trilist_uvfull.sv`
- Create (generated): `fpga/sim/vectors/tri_uvfull_ddr.hex`, `fpga/sim/vectors/tri_uvfull_exp.hex`

**Interfaces:**
- Consumes: `blt_raster_tri()` from the pinned refmodel (6-arg form, already used).
- Produces: scenario name `tri_uvfull`; heap layout: verts at `EOFF=0x80`, texture at `TEX_OFF=0x100`, `heap_len≈0x8100`. Task 3's bench loads the SAME `tri_uvfull_*.hex` files and depends on `TEX_OFF`, stride 256, size 32768.

Background: every existing TRILIST golden is an 8×8 stride-16 texture at `src_off=0` — that verifies exactly ONE bit of the u→address mapping (`texbyte[3]`), zero lane bits (`texbyte[2:1]`), and never a non-zero `c_src_off`. This scenario closes ranks 1–2 of the Bug A mechanism list: full u sweep (`texbyte[7:1]`), full v sweep, non-zero offset, and per-texel-distinct content (B5 = `(u^v)&0x1F` varies within a qword, so a wrong LANE is visible too).

- [ ] **Step 1: Extend the generator**

In `fpga/sim/gen_tri_golden.c`:

(a) Grow the heap and add the texture offset constant (near line 142):

```c
#define EOFF  0x80u             /* vertex-array byte offset within the SRC heap        */
#define TEX_OFF 0x100u          /* [tri_uvfull] non-zero texture offset (verts end at 0xE0) */
```
and change line 161:
```c
static uint8_t   heap[40960];   /* holds the 32 KiB tri_uvfull texture + verts */
```

(b) Add the texture builder after `tex_checker8` (line ~204):

```c
/* 128x128 coordinate-encoded RGB565 texture at heap byte offset `off`:
 * R5 = u>>2, G6 = v>>1, B5 = (u^v)&0x1F. R maps the qword-and-above address
 * bits, G maps the row bits, and B varies with u's low bits so a wrong LANE
 * (texbyte[2:1]) is visible too — the 8x8 goldens covered exactly one u
 * address bit (texbyte[3]) and zero lane bits. */
static void tex_coord128(uint32_t off) {
    for (int v = 0; v < 128; v++)
        for (int u = 0; u < 128; u++) {
            uint16_t c = (uint16_t)((((u>>2)&0x1F)<<11) | (((v>>1)&0x3F)<<5) | ((u^v)&0x1F));
            size_t o = off + ((size_t)v*128 + u)*2;
            heap[o] = (uint8_t)c; heap[o+1] = (uint8_t)(c>>8);
        }
    if (heap_len < off + 128u*128u*2u) heap_len = off + 128u*128u*2u;
}
```

(c) Add the scenario in `build()` before the final `else`:

```c
    } else if (!strcmp(s, "tri_uvfull")) {
        /* [Bug A sim gap] 128x128 stride-256 texture at a NON-ZERO src_off,
         * u and v sweeping the full 0..127 texel range across a 2-tri quad
         * (128x128 px => ~1 texel/px on both axes). Exercises texbyte[7:1]
         * (u), texbyte[15:8] (v), lane select, the tq qword cache under
         * thousands of distinct fills, and c_src_off in address assembly. */
        tex_coord128(TEX_OFF);
        blt_vtx_t v[6] = {
            VTX(40,40,        0,      0, 255,255,255,255),
            VTX(168,40,  127*16,      0, 255,255,255,255),
            VTX(168,168, 127*16, 127*16, 255,255,255,255),
            VTX(40,40,        0,      0, 255,255,255,255),
            VTX(168,168, 127*16, 127*16, 255,255,255,255),
            VTX(40,168,       0, 127*16, 255,255,255,255),
        };
        put_verts(v,6);
        set_hdr(BLT_BLEND_COPY, 128,128,256, 0, 255);
        hdr.src_off = TEX_OFF;
    }
```

(d) In `gen_tri_golden.mk` line 32:

```make
SCENARIOS := tri_copy tri_key tri_calpha tri_add tri_quad tri_surface tri_uvfull
```

- [ ] **Step 2: Regenerate vectors; existing goldens must be byte-identical**

```bash
export PATH="/opt/homebrew/bin:$PATH"
cd ~/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
git stash list >/dev/null  # (no-op, just make sure you're clean)
md5 vectors/*.hex > /tmp/vec_before.md5
make -f gen_tri_golden.mk vectors
md5 vectors/*.hex > /tmp/vec_after.md5
diff <(grep -v tri_uvfull /tmp/vec_before.md5) <(grep -v tri_uvfull /tmp/vec_after.md5)
```
Expected: contract-check passes; diff is EMPTY (all pre-existing vectors identical); `vectors/tri_uvfull_ddr.hex` + `vectors/tri_uvfull_exp.hex` now exist. `tri_uvfull_exp.hex` must NOT be a constant field: `sort -u vectors/tri_uvfull_exp.hex | wc -l` should be ≳ 3000 (many distinct texel values plus the blue background).

- [ ] **Step 3: Write the RTL bench (expected GREEN — the P_SRC stub path has no known bug)**

Create `fpga/sim/tb_blitter_trilist_uvfull.sv` as an exact copy of `fpga/sim/tb_blitter_trilist_pipe.sv` with these deltas:
1. `module tb_blitter_trilist_uvfull;` (line 14)
2. `$readmemh("vectors/tri_uvfull_ddr.hex", mem);` (line 138)
3. `$readmemh("vectors/tri_uvfull_exp.hex", exp);` (line 139)
4. Header comment: replace the first paragraph with:
```verilog
// tb_blitter_trilist_uvfull.sv — full-UV-sweep TRILIST equivalence (Bug A sim gap).
// 128x128 stride-256 coordinate texture at non-zero src_off (vectors/tri_uvfull_*):
// verifies texbyte[7:1] (u), texbyte[15:8] (v), lane select and the tq cache under
// thousands of distinct qword fills — the 8x8 goldens covered one u bit and no lanes.
```
Everything else (P_SRC line-cache stub, DDR model, compare loop, PERF print) stays identical.

- [ ] **Step 4: Run it**

```bash
./run_sims.sh tb_blitter_trilist_uvfull
```
Expected: `RESULT: PASS`, `bad pixels = 0 / 76800`. If it FAILS: this bench reproduces a real address-path bug with the trivial P_SRC stub — STOP, capture the mismatch pattern (are wrong pixels row-constant?), and report before any fix; that is a Bug A root-cause finding, not a bench bug.

- [ ] **Step 5: Full suite + commit**

```bash
./run_sims.sh
cd ~/MisterFPGA-Projects/maldita.castilla-mister
git add fpga/sim/gen_tri_golden.c fpga/sim/gen_tri_golden.mk fpga/sim/tb_blitter_trilist_uvfull.sv fpga/sim/vectors/tri_uvfull_ddr.hex fpga/sim/vectors/tri_uvfull_exp.hex
git commit -m "test(sim): tri_uvfull golden — full u/v sweep, 32KiB texture, non-zero src_off

Every prior TRILIST golden was an 8x8 stride-16 texture at src_off=0,
verifying exactly one bit of the u->address mapping (texbyte[3]) and no
lane bits. Bug A (device: column pinned to 0 at 32 KiB) was structurally
invisible to the suite. tri_uvfull sweeps u,v 0..127 over a 128x128
stride-256 coordinate texture (B5=(u^v)&0x1F makes lanes visible) at
TEX_OFF=0x100. Existing vectors regenerate byte-identical."
```

---

### Task 3: Real-`sdram_fb_cache` TRILIST co-sim bench (`tb_blitter_trilist_sdram`)

**Files:**
- Create: `fpga/sim/tb_blitter_trilist_sdram.sv`

**Interfaces:**
- Consumes: `vectors/tri_uvfull_ddr.hex` + `vectors/tri_uvfull_exp.hex` from Task 2 (TEX_OFF=0x100, stride 256, size 32768); the `tb_stage_psrc.sv` harness pattern (blitter_top + vram_demux + ddr_blitter_arb + sdram_fb_cache + mt48lc16m16a2); the `tb_blitter_trilist_pipe.sv` compare loop.
- Produces: the FIRST bench that runs TRILIST texel fetch through the real cache + SDRAM chip model. May legitimately go RED (see Step 3) — that outcome is a deliverable, not a failure of this task.

Design: two submissions on one harness.
- Phase 1 = STAGE: ring written by the bench (`wmem`), flags=0 (same-offset), `src_off=0x100`, size=32768 → copies the hex's texture DDR3→SDRAM via ch1. Wait for done, then pulse `vs` (flush ch1 + invalidate ch5), mirroring `tb_stage_psrc.sv:224-226`.
- Phase 2 = TRILIST: restore the hex's original ring qwords (saved at time 0 before phase 1 overwrote them), set `cmd_count=2`, `FLAGS=1` (clear), submit seq 2. The blitter's `p0_*` is wired to the cache's `p0_*` (unlike `tb_stage_psrc`, where the TB drives p0 itself), so the texel walk fetches through ch5 → real SDRAM. Compare `comp_fbram` against `tri_uvfull_exp.hex` ±1 LSB.

- [ ] **Step 1: Write the bench**

Create `fpga/sim/tb_blitter_trilist_sdram.sv`. Start from a copy of `fpga/sim/tb_stage_psrc.sv` and apply:

1. Rename module `tb_blitter_trilist_sdram`; replace the header comment:
```verilog
// tb_blitter_trilist_sdram.sv — TRILIST texel fetch through the REAL sdram_fb_cache
// + mt48 SDRAM chip model (Bug A follow-through: no prior bench co-simulated the
// rasterizer's P_SRC path with the real cache — texel reads always hit a behavioral
// stub). Phase 1 stages the tri_uvfull 32 KiB coordinate texture DDR3->SDRAM via a
// real BLT_OP_STAGE (ch1, ~126 evictions); phase 2 runs the tri_uvfull TRILIST with
// blitter p0_* wired to the cache ch5, and diffs comp_fbram against the golden.
// If this bench FAILS with row-constant/column-pinned texels, it has REPRODUCED
// Bug A in sim — capture the pattern and report; do not "fix" the bench.
```
2. Delete the TB-driven p0 regs (`p0_addr_r`/`p0_rd_r`) and instead wire the blitter's texel port straight to the cache:
```verilog
  wire [26:0] p0_addr; wire p0_rd; wire [63:0] p0_dout; wire p0_ok;
```
   In the `blitter_top` instance replace the tied-off p0 hookup with:
```verilog
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_dout(p0_dout), .p0_ok(p0_ok),
```
   and in the `sdram_fb_cache` instance:
```verilog
    .p0_addr(p0_addr), .p0_rd(p0_rd), .p0_dout(p0_dout), .p0_ok(p0_ok),
```
3. Add `comp_fbram` + the fb wires exactly as in `tb_blitter_trilist_pipe.sv` lines 88-92, and connect `fb_wr_*`/`fb_rd_*` on the `blitter_top` instance (`tb_blitter_trilist_pipe.sv:98-99`).
4. Keep `localparam integer NQW` etc. but replace the staging parameters with:
```verilog
  localparam [26:0] STAGE_OFF  = 27'h100;   // == TEX_OFF: same-offset staging
  localparam integer STAGE_BYTES = 32768;   // 128*256
```
5. Replace `submit_stage` with a flags=0 same-offset STAGE of the texture:
```verilog
  task submit_stage;   // phase 1: DDR3 heap[0x100..0x8100) -> SDRAM same-offset
    begin
      wmem(32'h200002, 64'd0);           // target
      wmem(32'h200004, 64'd0);           // flags: no CLEAR
      wmem(32'h200007, 64'd1);           // C_SRCSEL
      wmem(32'h200001, 64'd2);           // STAGE + END
      // STAGE flags=0 (same-offset): u32[0]=op4, u32[1]=src_off, u32[3]=w|h<<16=size
      wmem(32'h200008, {32'(STAGE_OFF), 32'h0000_0004});
      wmem(32'h200009, {32'd0, 32'(STAGE_BYTES)});
      wmem(32'h20000A, 64'd0); wmem(32'h20000B, 64'd0);
      wmem(32'h20000C, 64'd1);           // END
      wmem(32'h20000D, 64'd0); wmem(32'h20000E, 64'd0); wmem(32'h20000F, 64'd0);
      wmem(32'h200000, 64'd1);           // submit seq 1
    end
  endtask
```
   NOTE: verify the STAGE wire layout against `blitter_top.sv`'s decode (`stage_off = c_src_off` at flags=0, `stage_size = {c_h,c_w}` from u32[3]) — `tb_stage_psrc.sv:166-169` used the `F_STAGE_DST` variant; this uses the flags=0 same-offset variant the engine and probes use. If the decode reads size from a different dword, match the RTL, and say so in a comment.
6. At time 0, load the hex and SAVE the ring before phase 1 stomps it:
```verilog
  reg [63:0] ring_save [0:7];
  initial begin
    for (i=0;i<MEMQW;i=i+1) mem[i]=64'd0;
    $readmemh("vectors/tri_uvfull_ddr.hex", mem);
    $readmemh("vectors/tri_uvfull_exp.hex", exp);
    for (i=0;i<8;i=i+1) ring_save[i] = mem[32'h200008+i];
  end
```
   (plus the `exp` array + `chan_ok` function + compare loop copied verbatim from `tb_blitter_trilist_pipe.sv:120-134,161-175`.)
7. Main sequence: reset → wait `sdram_init` done (as in `tb_stage_psrc.sv:212-215`) → `submit_stage` → wait `done_seq==1` (allow 20M cycles) → vs pulse + wait `!coh_busy` (as `tb_stage_psrc.sv:224-226`) → restore ring + control for the TRILIST frame:
```verilog
    for (i=0;i<8;i=i+1) wmem(32'h200008+i, ring_save[i]);
    wmem(32'h200001, 64'd2);      // TRILIST + END
    wmem(32'h200004, 64'd1);      // FLAGS bit0 = CLEAR before list
    wmem(32'h200003, 64'h001f);   // clear color blue (matches golden)
    wmem(32'h200000, 64'd2);      // submit seq 2
```
   → wait `done_seq==2` (allow 40M cycles) → run the compare loop → `RESULT: PASS` iff `bad==0`.
8. Global timeout `#900_000_000` with `RESULT: FAIL - global timeout`.

- [ ] **Step 2: Run it**

```bash
export PATH="/opt/homebrew/bin:$PATH"
cd ~/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
./run_sims.sh tb_blitter_trilist_sdram
```
Two acceptable outcomes:
- `RESULT: PASS` → the real-cache path is clean in sim at 32 KiB scale; Bug A's remaining sim-side suspects narrow to hardware-only effects (M10K read-during-write don't-care, device SDRAM timing). Record that in the commit message.
- `RESULT: FAIL` with structured mismatches → potentially Bug A reproduced. Before anything else, characterize: print a few mismatch rows; if `got` is constant per texture row (column-pinned) that is THE device signature. Commit the bench as-is with the failure documented (it is a legitimate RED that gates a future fix), mark it NONGATING in `run_sims.sh` with a loud comment, and STOP this task — report to the coordinator/user; root-cause work is a separate decision.

- [ ] **Step 3: Full suite (the new bench may be slow — note wall time) + commit**

```bash
./run_sims.sh
git add fpga/sim/tb_blitter_trilist_sdram.sv
git commit -m "test(sim): TRILIST through the real sdram_fb_cache + mt48 (first ever)

Stages the tri_uvfull 32KiB coordinate texture via a real BLT_OP_STAGE
(ch1 write-back, ~126 evictions), then rasterizes with blitter p0_* wired
to cache ch5 — no prior bench co-simulated the texel fetch with the real
cache; the P_SRC stub could never catch request-drop, arbitration or
line-offset defects. <PASS/FAIL outcome + one-line interpretation here>"
```

---

### Task 4: Engine — re-STAGE cached textures after any discarded ring (TDD)

**Files:**
- Modify: `~/MisterFPGA-Projects/gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp`
- Test: `~/MisterFPGA-Projects/gmloader-next/gmloader/mister/raster_backend_test.cpp`

**Interfaces:**
- Consumes: `MfTexEntry` (line ~129), `g_texcache`, `blt_stage()`, `g_stage_count`, the drop-guard globals (`g_drop_run`, `mf_drop_limit()`), test hooks `RasterBackend_MFGPU_Test{Reinit,SetFabricBusy,UploadCount,StageCount,DropCount}`.
- Produces: `MfTexEntry.stage_gen` + global `g_stage_gen`; new test `case_restage_after_reclaim`.

Background: `blt_stage` is emitted exactly once, tied to the upload (`raster_backend_mfgpu.cpp:789-800`), inside a frame that can be discarded after the fact: emitter-overflow return (`:1426-1428`), device-unmapped return (`:1431`), and the drop-limit ring reclaim (`:598-601`). The cache then believes the page is SDRAM-resident forever while the fabric samples SDRAM that was never written — wrong texels that persist long after a stall. The DDR heap copy IS intact in all three cases (uploads write straight to DDR and the heap block stays allocated), so a re-STAGE is sufficient and idempotent. The submit-timeout path (`:512-521`) must NOT bump: the ring is left intact and the fabric is still executing it.

- [ ] **Step 1: Write the failing test**

In `raster_backend_test.cpp`, add after `case_inflight_drop_limit` (ends ~line 1330; match its local idiom — it also drives the drop guard to the reclaim point, reuse its loop structure if it differs from below):

```c
// [restage-after-drop] blt_stage is emitted once per resident page, inside a frame
// that can be discarded (overflow / device-unmapped / drop-limit ring reclaim).
// The DDR heap copy survives, but the SDRAM copy may never have been made; the
// cache then serves "resident" hits the fabric samples as unwritten SDRAM — the
// post-stall persistent-garbage mechanism. A ring discard must trigger exactly one
// re-STAGE per cached entry on its next hit (and zero re-uploads).
static int case_restage_after_reclaim(void) {
    static const uint8_t px[4] = { 10, 200, 30, 255 };
    RTexture t = { px, 1, 1, 1, 1, 0, 1 };
    BVtx v[3] = { {1,1,0,0,1,1,1,1}, {60,1,1,0,1,1,1,1}, {1,60,0,1,1,1,1,1} };
    static uint8_t rgba_mf[BW*BH*4];
    RSurface s = { rgba_mf, BW, BH };
    RasterBackend_MFGPU_SetDefaultSurface(rgba_mf);
    RasterBackend_MFGPU_TestReinit(0);
    RasterBackend_MFGPU_TestSetFabricBusy(-1);
    uint32_t key = next_key();

    // frame A (miss: upload+stage) then frame B (hit: no new stage)
    backend_mfgpu.clear(&s, 0,0,0,255);
    backend_mfgpu.draw(&s, v, 1, &t, RB_NONE, 0.f, key);
    backend_mfgpu.present(&s);
    backend_mfgpu.clear(&s, 0,0,0,255);
    backend_mfgpu.draw(&s, v, 1, &t, RB_NONE, 0.f, key);
    backend_mfgpu.present(&s);
    const uint32_t up0 = RasterBackend_MFGPU_TestUploadCount();
    const uint32_t st0 = RasterBackend_MFGPU_TestStageCount();
    if (up0 != 1 || st0 != 1) {
        printf("  FAIL restage-precondition up=%u st=%u (want 1/1: one miss, one hit)\n", up0, st0);
        return 0;
    }

    // Hold "fabric busy" past MF_DROP_LIMIT: frames drop whole, then the guard
    // reclaims the ring — the abandoned batch's STAGEs may never have executed.
    RasterBackend_MFGPU_TestSetFabricBusy(1);
    const uint32_t dr0 = RasterBackend_MFGPU_TestDropCount();
    for (int i = 0; i <= 60 /* MF_DROP_LIMIT_DEFAULT */; i++) {
        backend_mfgpu.clear(&s, 0,0,0,255);
        backend_mfgpu.present(&s);
    }
    RasterBackend_MFGPU_TestSetFabricBusy(-1);
    if (RasterBackend_MFGPU_TestDropCount() == dr0) {
        printf("  FAIL restage-setup: guard never engaged (no drops)\n");
        return 0;
    }

    // Next hit on the same texture must RE-EMIT the stage — no re-upload.
    backend_mfgpu.clear(&s, 0,0,0,255);
    backend_mfgpu.draw(&s, v, 1, &t, RB_NONE, 0.f, key);
    backend_mfgpu.present(&s);
    if (RasterBackend_MFGPU_TestUploadCount() != up0) {
        printf("  FAIL restage  hit became a re-upload (up %u->%u)\n",
               up0, RasterBackend_MFGPU_TestUploadCount());
        return 0;
    }
    if (RasterBackend_MFGPU_TestStageCount() != st0 + 1) {
        printf("  FAIL restage  stage_count=%u want=%u (discarded STAGE never re-emitted)\n",
               RasterBackend_MFGPU_TestStageCount(), st0 + 1);
        return 0;
    }
    printf("  OK   restage-after-reclaim  1 re-STAGE, 0 re-uploads\n");
    return 1;
}
```
and register it in `main()` next to the other inflight cases:
```c
    if (!case_restage_after_reclaim()) { printf("FAIL mfgpu-restage-after-reclaim\n"); ok = 0; }
```

- [ ] **Step 2: Run to verify it fails (RED)**

```bash
cd ~/MisterFPGA-Projects/gmloader-next
make -f Makefile.gmloader raster-backend-test
```
Expected: `FAIL restage  stage_count=1 want=2 (discarded STAGE never re-emitted)` and a non-zero exit. All pre-existing cases must still pass.

- [ ] **Step 3: Implement**

In `raster_backend_mfgpu.cpp`:

(a) `MfTexEntry` (line ~129): append a field:
```c
struct MfTexEntry { uint32_t key; bool used; bool has_key; bool mask_only; blt_surface_ref_t ref; uint64_t lru;
                    uint16_t rx, ry, rw, rh;
                    uint32_t stage_gen;   // [restage-after-drop] generation the last OP_STAGE survived to submit in
};
```
(match the actual existing member list — the aggregate init at line ~825 shows the real order; add `stage_gen` LAST).

(b) Globals (near `g_stage_count`):
```c
static uint32_t g_stage_gen = 0;   // [restage-after-drop] bumped whenever emitted STAGEs may have been discarded
```
and in `mf_init_once()` (line ~549 cluster): `g_stage_gen = 0;`

(c) Bump sites — add `g_stage_gen++;` at exactly these three places, each with the one-line comment `// [restage-after-drop] ring discarded; emitted STAGEs may never execute`:
   1. `mf_frame_begin` reclaim branch — inside the `if (g_drop_run >= mf_drop_limit())` body (line ~598-600), next to the fprintf.
   2. `mf_frame_end` MISTER_NATIVE_VIDEO overflow return (line ~1426-1428) and the `device DDR unmapped` else (line ~1431) — one bump covering both:
      restructure to bump before each `return`/after the fprintf so BOTH non-submitted exits bump.
   3. `mf_frame_end` host-oracle overflow return (line ~1435-1437). (The host oracle has no SDRAM, but bumping keeps device and host behavior identical — and makes the mechanism testable, which is how Step 1's test works: the reclaim bump (c.1) is the one it exercises.)
   Do NOT bump on submit timeout (`mf_device_submit` line ~512-521): the ring is intact and still being executed.

(d) `mf_upload_and_cache` insert (line ~825): add `g_stage_gen` as the final aggregate member:
```c
    g_texcache[slot] = MfTexEntry{ key, true, has_key, mask_only, ref, ++g_lru_clock,
                                   (uint16_t)rx, (uint16_t)ry, (uint16_t)w, (uint16_t)h,
                                   g_stage_gen };
```

(e) Both cache-hit sites — `stage_texture` (line ~852-857) and `stage_texture_region` (line ~915-921) — after the `g_texcache[i].lru = ++g_lru_clock;` line, insert:
```c
            // [restage-after-drop] a discarded ring (overflow / no device / drop-limit
            // reclaim) may have thrown away this entry's OP_STAGE before the fabric
            // copied it to SDRAM; the cache would then believe the page resident
            // forever while the fabric samples unwritten SDRAM. The DDR heap copy is
            // intact, so one idempotent re-STAGE per generation restores the invariant.
            if (g_texcache[i].stage_gen != g_stage_gen) {
                if (blt_stage(&g_e, g_texcache[i].ref.off,
                              (uint32_t)g_texcache[i].ref.stride * g_texcache[i].ref.h) == 0)
                    g_stage_count++;
                g_texcache[i].stage_gen = g_stage_gen;
            }
```

- [ ] **Step 4: Run tests to verify they pass (GREEN)**

```bash
make -f Makefile.gmloader raster-backend-test
```
Expected: `OK   restage-after-reclaim  1 re-STAGE, 0 re-uploads`; ALL pre-existing cases pass. If `case_inflight_drop_limit` (or any case that renders after a reclaim) now sees an extra stage count, review whether its assertion counts stages — the +1 is the intended new behavior; update that assertion with a comment referencing this task, and re-verify the case still fails under the mutation `git stash` of the fix (i.e., its update didn't hollow it out).

- [ ] **Step 5: Run the sibling suites + armhf build**

```bash
make -f Makefile.gmloader blitter-raster-test && make -f Makefile.gmloader blitter-appsurf-test
docker build -f Dockerfile.gmloader-build -t gmloader-build . 2>/dev/null || true   # reuse cached image if present
# repo-standard armhf build (mirror whatever invocation the repo README/Makefile documents):
make -f Makefile.gmloader armhf 2>/dev/null || docker run --rm -v "$PWD:/src" gmloader-build   # use the repo's documented build path
```
Expected: unit suites green; armhf binary builds clean. (The exact armhf invocation: use the same command previous sessions used with `Dockerfile.gmloader-build` — check `git log` / build scripts rather than guessing.)

- [ ] **Step 6: Commit (gmloader-next)**

```bash
cd ~/MisterFPGA-Projects/gmloader-next
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_test.cpp
git commit -m "fix(mfgpu): re-STAGE resident textures after any discarded ring

OP_STAGE was emitted exactly once, tied to the upload — inside a frame
that can be discarded (emitter overflow, device unmapped, drop-limit ring
reclaim). The cache then believed the page SDRAM-resident forever while
the fabric sampled SDRAM that was never written: persistent wrong texels
that outlive a stall. A generation counter bumps on every ring discard
(NOT on submit timeout — that ring still executes) and each cache hit
re-emits one idempotent same-offset STAGE per generation."
```

---

### Task 5: Device experiment — symmetric-UV probe on .62 (Bug A discriminator)

**Files:**
- Create: `~/MisterFPGA-Projects/gmloader-next/tools/fabric_probe_uvsym.c`
- Modify: `~/MisterFPGA-Projects/gmloader-next/tools/Makefile.fabric_probe_uv` (add a target, or clone to `Makefile.fabric_probe_uvsym` following the existing pattern)

**Interfaces:**
- Consumes: `fabric_probe_uv.c` (existing coordinate probe), the ledger's device repro procedure.
- Produces: a screenshot-decoded verdict that splits Bug A mechanism 1 (u-interpolant collapse, layout-dependent) from mechanisms 2/3 (address/cache path).

Background: the existing probe's UV layout `(64,0)/(127,127)/(0,127)` makes v depend ONLY on barycentric b0, so a "correct" green ramp survives large errors in the w1/w2 split while u dies. The symmetric layout `(0,0)/(127,0)/(0,127)` makes u and v depend on independent barycentrics.

- [ ] **Step 1: Create the probe variant**

`cp tools/fabric_probe_uv.c tools/fabric_probe_uvsym.c`, then replace the vertex block (lines ~178-182) with:

```c
    /* SYMMETRIC UVs: u and v ride independent barycentrics (u<-b1, v<-b2).
     * The uv probe's layout (64,0)/(127,127)/(0,127) made v depend only on b0,
     * so a collapsed w1 term kills u while v still ramps plausibly. Here a
     * u-interpolant defect and an address defect separate:
     *   red ramps now, was pinned    -> interpolant (w-split) defect
     *   red still pinned at 0        -> address/cache path (or device SDRAM)   */
    blt_vtx_t tris[3] = {
        { (int16_t)(10  << 4), (int16_t)(10  << 4), (uint16_t)(0   << 4), (uint16_t)(0   << 4), BLT_RGBA(255, 255, 255, 255), 0 },
        { (int16_t)(300 << 4), (int16_t)(10  << 4), (uint16_t)(127 << 4), (uint16_t)(0   << 4), BLT_RGBA(255, 255, 255, 255), 0 },
        { (int16_t)(10  << 4), (int16_t)(220 << 4), (uint16_t)(0   << 4), (uint16_t)(127 << 4), BLT_RGBA(255, 255, 255, 255), 0 },
    };
```
Update the top-of-file comment to name the variant. Add the build target by cloning the existing `Makefile.fabric_probe_uv` pattern with `uv` → `uvsym` substitutions (read that 46-line makefile first and mirror it exactly, including the docker cross-build invocation it documents).

- [ ] **Step 2: Build it**

```bash
export PATH="/opt/homebrew/bin:$PATH"
cd ~/MisterFPGA-Projects/gmloader-next
# use the docker cross-build command documented at the top of tools/Makefile.fabric_probe_uv
```
Expected: `tools/fabric_probe_uvsym.armhf` exists, file type ARM 32-bit.

- [ ] **Step 3: Run on .62 (current HEAD RBF first)**

```bash
scp tools/fabric_probe_uvsym.armhf root@192.168.20.62:/tmp/
ssh root@192.168.20.62 'mv "/media/fat/games/Maldita Castilla/_handler.sh"{,.off} 2>/dev/null; killall -9 gmloader gmloadernext.armhf 2>/dev/null; sleep 2; nohup /tmp/fabric_probe_uvsym.armhf 30 >/tmp/uvsym.log 2>&1 & sleep 5; echo screenshot > /dev/MiSTer_cmd; sleep 2; cat /tmp/uvsym.log'
ssh root@192.168.20.62 'ls -t "/media/fat/screenshots/Maldita Castilla/" | head -1'
scp "root@192.168.20.62:/media/fat/screenshots/Maldita Castilla/<newest>.png" /tmp/uvsym_head.png
python3 ~/MisterFPGA-Projects/maldita.castilla-mister/tools/png.py /tmp/uvsym_head.png   # check tools/png.py usage first (capture.sh shows the idiom)
```
Decode: sample pixels across the triangle's top edge (u sweeps 0→127 left-to-right at y≈15): report whether R5 ramps 0→31 or stays 0, and whether G6 ramps down the left edge.

- [ ] **Step 4 (decision point): interpret + optionally repeat on the Jul-18 RBF**

| result | meaning | next |
|---|---|---|
| red ramps, green ramps | u-interp collapse was layout-specific → mechanism 1 (w-split defect at the asymmetric layout) | record; the original uv probe layout becomes a regression scene for the interp fix |
| red still pinned, green ramps | address/cache path or device-SDRAM — mechanism 2/3/4 | repeat this probe against the Jul-18 RBF (`/media/fat/_Other/` has the bisect RBFs; `echo "load_core ..." > /dev/MiSTer_cmd`), and note Task 3's sim outcome — together they narrow to hardware-only |
| garbage / no ramp at all | on HEAD RBF this is the e338f3c regression compounding — retest after Task 6's fixed RBF | defer Bug A judgment until the arbiter fix is deployed |

- [ ] **Step 5: RESTORE the device + record**

```bash
ssh root@192.168.20.62 'mv "/media/fat/games/Maldita Castilla/_handler.sh"{.off,} 2>/dev/null; echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd; sleep 3; echo "load_core /media/fat/_Other/MalditaCastilla_20260725.rbf" > /dev/MiSTer_cmd'
```
(The handler fires only on a CORENAME change — the menu bounce is required.) Verify the game relaunches (`tail /media/fat/logs/MalditaCastilla/maldita.log`). Commit the probe:

```bash
cd ~/MisterFPGA-Projects/gmloader-next
git add tools/fabric_probe_uvsym.c tools/Makefile.fabric_probe_uv*  # whichever makefile route was taken
git commit -m "tools: symmetric-UV probe variant — splits u-interp collapse from address-path (Bug A)"
```

---

### Task 6: Device A/B of the arbiter fix (RBF build + wedge/stall/magenta metrics)

**Files:** none (CI + device operations). Requires Task 1 committed.

**Interfaces:**
- Consumes: Task 1's commit on `fix/launch-via-master-daemon-handler`; CI workflow `.github/workflows/build-rbf.yml` (self-hosted Windows, Quartus 17.0, ~12 min); `deploy.py`; `fabric_probe.armhf` + `wedgerate.sh` already on .62 (`/tmp`, and `scratchpad/wedgerate.sh` in-repo if /tmp was cleared).
- Produces: the confirmation/refutation of the beat-desync mechanism for BOTH bugs.

- [ ] **Step 1: Push and build**

```bash
cd ~/MisterFPGA-Projects/maldita.castilla-mister
git push origin fix/launch-via-master-daemon-handler
gh run list --workflow=build-rbf.yml --limit 1    # note the run id, wait for completion (~12 min)
gh run watch <id> --exit-status
gh run download <id> -n maldita-rbf -D _Other
gh run download <id> -n quartus-reports -D /tmp/sta_new && grep -A3 "emu" /tmp/sta_new/output_files/Maldita.sta.summary | head -20
```
Expected: RBF lands in `_Other/`; note the fabric `emu` clock slack (placement-fragile; slightly negative is tolerated per CLAUDE.md, but RECORD it — the pre-fix build was all-positive +0.051, and a big regression here confounds the A/B).

- [ ] **Step 2: Deploy + wedge-rate A/B (engine out of the loop)**

```bash
./deploy.py --no-content
ssh root@192.168.20.62 'mv "/media/fat/games/Maldita Castilla/_handler.sh"{,.off}; killall -9 gmloader gmloadernext.armhf 2>/dev/null'
# wedgerate: NOENGINE + reload core + fabric_soak, >=10 rolls (script: /tmp/wedgerate.sh or scratchpad/wedgerate.sh)
ssh root@192.168.20.62 '/tmp/wedgerate.sh 10'
```
Baseline to beat (pre-fix): ~1-in-5 wedges per reconfigure (best-measured; up to ~50% in clustered runs). Expected if the mechanism is right: 0 wedges. Also run the magenta probe once per healthy roll:
```bash
ssh root@192.168.20.62 '/tmp/fabric_probe.armhf 5; echo screenshot > /dev/MiSTer_cmd'
# fetch + decode: BAD = triangle 0x001F, GOOD = 0xF81F
```
The magenta verdict is the REGRESSION test: if the fixed RBF renders 0xF81F where HEAD rendered 0x001F, the beat-desync mechanism explains e338f3c and is closed by the retry.

- [ ] **Step 3: Engine stall soak**

```bash
ssh root@192.168.20.62 'mv "/media/fat/games/Maldita Castilla/_handler.sh"{.off,}; echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd; sleep 3; echo "load_core /media/fat/_Other/<new rbf>" > /dev/MiSTer_cmd'
# let the game run >=5 min, then sample sub/done/ctrl at 100ms for 3 min (prior sessions' sampling loop)
# metric: % of wall time with done frozen; baseline = ~37-57% stalled, episodes to ~18s
```
Expected if fixed: stall percentage collapses to ~0; C_DONE tracks C_SUBMIT. Record fps too (baseline ~19-27fps).

- [ ] **Step 4: Record the verdict**

Whatever the outcome, append the three measurements (wedgerate, magenta value, stall %) to the ledger (Task 7) with RBF sha1s. If the stall/wedge metrics do NOT improve: the bounded exit stays (defense-in-depth, zero cost — matches the fill-watchdog precedent) but the mechanism is refuted for the stall face; escalate to the issuer-tagged beat-accounting design (out of scope for this plan) rather than iterating blind.

---

### Task 7: Ledger update

**Files:**
- Modify: `.superpowers/sdd/progress.md` (append a dated section at the end)

- [ ] **Step 1: Append the session record**

Append a `## 2026-07-26 — DESIGN-VS-IMPL ANALYSIS + FIX ROUND` section covering, tersely, in the ledger's established style:
1. The three-agent analysis conclusions: arbiter stateless beat-steering + falsifiable `rd_out` = one mechanism, two faces (STAGE texel poisoning / G_BLT_RD escape-free park); e338f3c's causal channel is latency-distribution only (bisect airtight — probe binary pinned — but mechanism inferred).
2. Bug A re-baselined: .81/.62 device conflation (all "known-good with atlases" evidence is .81; Bug A evidence all .62; magenta probe structurally blind to column-pinning); sim goldens covered ONE u address bit; probe UV layout blind to lane faults and weak on v.
3. Engine audit highlights: lost-STAGE persistence (fixed this round, Task 4), stale appsurf identity on GL name recycling (A2, OPEN), UV quantization never implemented (B3, OPEN), mid-frame InvalidateTex pin bypass (B2, OPEN), SDRAM FB0/FB1-vs-heap collision at 4 MiB and DDR heap-end/scanout zero guard band (latent, OPEN — will bite per-quad staging growth).
4. What landed (commit hashes for Tasks 1-4), each device measurement from Tasks 5-6 with numbers, and the explicit next-decision if any leg was refuted.

No commit (the ledger is gitignored/local-only).

---

## Execution notes

- Task order: 1 → 2 → 3 → 4 can run with 4 in parallel to 2/3 (different repos). 5 needs only the probe build; 6 needs Task 1 + CI + device. 7 last.
- Device availability: .62 is the only usable rig; if it is mid-experiment or unreachable, do Tasks 1-4 and leave 5-6 queued with a note.
- If Task 3 goes RED with the column-pinned signature, that finding may change Task 5/6 priorities — surface it to the user before proceeding to device work.

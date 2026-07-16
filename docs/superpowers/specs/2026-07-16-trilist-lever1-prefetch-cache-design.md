# Design: TRILIST Lever 1 — decoupled prefetching qword texel cache

**Status:** approved (design; no HDL written yet)
**Date:** 2026-07-16
**Target:** `fpga/rtl/blitter_top.sv` (the `S_TRI_*` per-pixel rasterizer, `pa`/`pb` sub-FSMs)
**Predecessor:** the datapath pipeline (Stage 1 + 3a) is DONE and device-confirmed
(fabric frame 48.87ms → 26.24ms, 1.86x, `to=0`, bit-exact @ 3985069). This spec is
**Lever 1** from `2026-07-16-trilist-rasterizer-throughput-design.md`: hide the
single-outstanding P_SRC texel latency.

## Problem (measured on device, do NOT re-derive)

After Stage 3a the device breakdown at the menu scene is:

```
tri=23.78ms  texwait=8.23ms  dpath=15.55ms  ovhd=2.46ms
```

`pa` (`blitter_top.sv:939-1061`) walks coverage → interp multiply → texel byte-addr,
and at `A_ISSUE` issues **one** P_SRC read into a **single-deep** handoff (`h_full`),
stalling until `pb` frees it at `B_GOT`. `pb` (`:1063-1181`) waits on the
always-listening `tex_pend/tex_rdy` catcher, then dst-read → 3-stage blend → write.
Consequently texel reads are **serialized**: read N must return (`p0_ok`) and be consumed
before pa issues read N+1.

**Established facts (already falsified alternatives on-device — do not retry):**

- P_SRC (jtframe ch5) is **strictly single-outstanding**: hit ≈ 4 clk, miss ≈ 140 clk,
  ~30% miss rate (row-order walk interleaves more texture rows than the 2-line jtframe
  cache holds). Forking jtframe for multi-outstanding is **out of scope**.
- Widening jtframe ch5 `RO_BLOCKS` 2→8 **FAILED on device** (frame 48.87→48.77ms, 0.2%).
  The cost is **serialization**, not capacity — do not retry a bigger jtframe cache.
- Datapath already overlaps under the texel wait (Stage 3a). Stage 3b (split
  wait-from-blend) was built, measured useless, reverted. `dpath` won't drop further.
- `p0_ok` is a **1-cycle strobe** on a single-outstanding channel. Any consumer must
  latch it in **every** cycle a read is outstanding, never sample it in one FSM state
  (this is the Stage-3a device-hang bug; the always-listening `tex_pend/tex_rdy/tex_hold`
  latch already in RTL is the fix pattern).

### The precise lever

**`texwait` (8.23ms) < `dpath` (15.55ms)**, but they are currently *serialized* (pb
blocks on each fill). Decouple fetch from consume so pa fills *ahead* while pb runs
datapath on already-resident texels, and the 8.23ms of fill latency **overlaps under**
the 15.55ms of datapath. Frame drops toward `~max(dpath, fill) + prologue ≈ 15–18ms`
(~1.4–1.5x). The local BRAM makes pb's texel read a guaranteed **1-cyc hit** so it never
re-blocks on P_SRC; a deep decoupling FIFO + residency check lets pa race ahead. This
also explains why widening jtframe ch5 did nothing: capacity was never the bottleneck,
serialization was.

**Target:** cut fabric `texwait` toward ~0; drop fabric frame from ~26ms toward
~15–18ms; `to=0`; bit-exact; zero jtframe changes.

## Design — 4 units, one new P_SRC port owner

```
        payload FIFO (depth D)                    local texel BRAM (N qwords, direct-mapped)
pa ───► {colour, dst_qw/lane, qtag, texlane} ───► pb          slot = qtag[log2N-1:0]
 │  (walk + best-effort prefetch)             (pop → BRAM read → blend → write)
 │                                                 │          tag[slot] = qtag[hi], valid[slot]
 └──────────────► P_SRC FILL ARBITER ◄─────────────┘  (pb demand-fetch has PRIORITY)
                  owns tri_p0_rd / tri_p0_addr, strictly single-outstanding,
                  always-listening p0_ok catcher → BRAM[slot] + tag valid, clears in-flight
```

### Unit 1 — `pa` (prefetch address-gen)

Today's coverage → interp (`A_MUL0/1/MUL`) → texel byte-addr (`A_ADDR/ADDR2`) walk, with
**unchanged arithmetic**. Two changes:

1. **Payload FIFO instead of the single-deep handoff.** Replace the `h_full` handoff +
   `A_ISSUE` stall with a push of the full per-pixel payload into a **depth-D FIFO**:
   `{cr, cg, cb, ca, dst_qw, dst_lane, qtag = texbyte[26:3], texlane = texbyte[2:1]}`.
   pa blocks only on **FIFO-full**, never on a fill returning.
2. **Best-effort prefetch.** As pa walks, if the pixel's `qtag` is **not resident** and
   the fill arbiter is **idle**, pa kicks a prefetch for that `qtag`. Because pa walks in
   consumption order, prefetches issue in the order pb will need them. pa never blocks on
   prefetch — if the arbiter is busy, pa moves on and the line is either prefetched on a
   later pa cycle or demand-fetched by pb.

`texbyte` is already computed at `A_ADDR2` (`texbyte = c_src_off + tex_row + (itu_q<<<1)`);
`qtag = texbyte[26:3]` (8-byte aligned qword address), `texlane = texbyte[2:1]` (already
`tex_lane_q`). No new arithmetic.

### Unit 2 — P_SRC fill arbiter

Sole owner of the single P_SRC port (today pa drove `tri_p0_rd` at `A_ISSUE`). Arbitrates
**pb-demand (priority) over pa-prefetch**, strictly **one outstanding**. On issue it
records the target `{slot, tag}`. The **always-listening `p0_ok` catcher** (reusing the
Stage-3a `tex_pend`-style pattern) captures `p0_dout` in any cycle after issue → writes
the 64-bit qword to `BRAM[slot]`, stamps `tag[slot]=qtag[hi]` + `valid[slot]=1`, clears
in-flight. This preserves the single-outstanding discipline and the strobe-latch fix.

### Unit 3 — local texel BRAM

`N` qwords × 64b, **direct-mapped**: `slot = qtag[log2N-1:0]`,
`tag_stored = qtag[26:log2N]`, plus a per-slot `valid` bit. **Default N = 256** (2KB,
~2×M10K) — holds far more texture rows than jtframe's 2 lines, killing interleave-thrash.
`N` (and `D`) are sim-tuned parameters (Task 4).

**Invalidation:** the local cache mirrors P_SRC data, so it must drop all `valid` bits
exactly when jtframe ch5 is invalidated — i.e. on the **per-command STAGE→P_SRC coherency
barrier** already in RTL (`blitter_top.sv:106-157`), NOT per-triangle (triangles within a
command share the same source atlas and may legitimately reuse resident qwords). A single
`valid <= '0` on that barrier's cycle suffices.

### Unit 4 — `pb` (consume + blend)

Pop the FIFO → read `BRAM[slot]`:

- **`valid[slot] && tag[slot] == qtag[hi]` → 1-cyc hit** → select `texel = qword[texlane]`
  → existing 3-stage blend/write (`B_WR/WR2/WR3`), unchanged.
- **Miss** (not-yet-filled, or evicted alias) → **demand-fetch** the `qtag` via the
  arbiter (priority), wait for `valid`, re-read → blend. Identical outcome to today's
  per-pixel fetch.

## Correctness / bit-exactness (the invariant)

- **Prefetch is purely best-effort; pb's demand path is the correctness backbone**,
  behaviorally identical to today. Worst case (prefetch never lands) collapses to today's
  serialized fetch — same texel address, same lane, same order. Bit-exactness is
  therefore **structural**; only *when* a texel is fetched changes, never *which*.
- **Direct-mapped aliasing** (two qtags → same slot; pb still needs the evicted one) is
  caught by the `tag == qtag` check → pb demand-refetches → same data. A perf pothole,
  not a correctness bug; `N ≫ D` makes it rare.
- **Single-outstanding discipline preserved** end-to-end through the arbiter; the
  always-listening catcher prevents the strobe-miss hang.

## Sim / validation (TDD — bit-exact golden gate every iteration)

Neither `tb_blitter_trilist_pipe` (variable-latency stub, random 4–28cyc "miss") nor
`tb_blitter_system_pipe` (fixed `SRC_LAT`) models a real **line-fill cache**, so neither
can *measure* a prefetch win — they'd show near-zero `texwait` regardless.

- **Extend `tb_blitter_trilist_pipe.sv`'s P_SRC stub** into a faithful line-cache model:
  track a resident-line set, `hit = 4cyc / cold-fill ≈ 140cyc`, **LRU-evict to 2 lines**
  to reproduce the ~30% thrash, driven by the real texel address stream. This makes
  `texwait` *real* in sim so the prefetch drop is measurable. Keep it single-outstanding
  with variable phase (so it still catches strobe-miss hangs).
- **Golden bit-exact gate:** `cd fpga/sim && ./run_sims.sh tb_blitter_trilist_pipe` must
  stay green every iteration (it diffs against `gen_tri_golden.c` / `blitter_ref`). Keep
  the whole suite green: `./run_sims.sh` (`tb_scanout_fbram` + `tb_audio_burst_wedge` are
  pre-existing fails on milestone-a, unrelated).
- **Throughput assertion:** the TB already prints `tri/texwait/dpath` + `dpath_cyc/px`.
  Add a **texwait-drop assertion** (prefetch build vs. the faithful-stub baseline) so the
  win is regression-checked in sim, not just on device.

## Risks

- **pa fill-bound?** Only if the unique-line fill rate exceeds pb's datapath rate. Device
  says `texwait 8.23 < dpath 15.55`, so it should fully overlap — the faithful stub
  confirms before any RBF build.
- **STA / Fmax:** +~2 M10K (cache) + tag array + small FIFO; +1 registered BRAM read + a
  tag equality compare. The **`pll_hdmi` divclk path is placement-fragile** (worst slack
  swung −0.017 → −0.240ns across builds) and the **fabric emu-pll domain must stay >0** —
  STA re-check is a gated task (Task 5), not assumed. Added BRAM/prefetch must not regress
  the emu-pll domain.
- **BRAM/DSP budget:** no new DSP (multiplies unchanged); modest BRAM (cache + tags +
  FIFO). No second framebuffer.
- **Visual regression:** this touches the texel path — Task 6 must verify sampling
  correctness on device, not just perf and `to=0`.

## Staged plan (each stage sim-verified bit-exact before the next)

- **T0 — Faithful sim.** Extend the `tb_blitter_trilist_pipe` P_SRC stub to the
  line-cache model (resident set, hit/cold-fill latency, LRU-to-2-lines thrash). Capture
  baseline `tri/texwait/dpath` + `cyc/px` with the **current** RTL (no RTL change). Lock
  the golden pass. Deliverable: a real, nonzero `texwait` in sim matching the ~30%
  miss/thrash shape.
- **T1 — Cache + arbiter (plumbing).** Add the local BRAM + tag/valid array + P_SRC fill
  arbiter; route the single P_SRC port through the arbiter. Keep the single-deep consumer
  for now (pb demand-fetches through the arbiter). Bit-exact + no texwait regression.
- **T2 — Payload FIFO.** Replace the `h_full` handoff with the depth-D payload FIFO; pb
  pops and reads BRAM via demand-fetch (no prefetch yet). Bit-exact; `texwait` ≈ baseline.
- **T3 — Prefetch (the win).** Add pa best-effort prefetch. `texwait` → ~0 in the
  faithful stub; bit-exact; add the texwait-drop assertion.
- **T4 — Tune.** Sweep `N` (cache qwords) + `D` (FIFO depth) in sim for the texwait/frame
  minimum at a fixed BRAM budget. Record the chosen params + the sim curve.
- **T5 — Build + STA.** Quartus/Windows RBF build; STA: fabric emu-pll domain >0, `pll_hdmi`
  not regressed. Report worst slacks.
- **T6 — Deploy + validate.** `mister_run.sh bench --secs 22 --preset fabric` A/B at the
  **same scene** (load the prior RBF back-to-back, both under `/media/fat/_Other/`):
  confirm `to=0`, a `texwait`/`frame` drop matching sim, and **visual correctness** (watch
  for texel sampling artifacts, not just perf).

**Ordering note:** T1→T2→T3 keep the design bit-exact and demand-correct at every step;
prefetch (T3) is the only stage that changes *timing behavior*, and it is purely additive
on top of a correct demand path — so a prefetch bug degrades to today's perf, never to a
wrong pixel.

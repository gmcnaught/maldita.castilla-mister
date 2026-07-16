# Design: TRILIST rasterizer throughput — 1 px/cyc pipeline

**Status:** proposed (design + plan; no HDL written yet)
**Date:** 2026-07-16
**Target:** `fpga/rtl/blitter_top.sv` (the `S_TRI_*` per-pixel rasterizer)

## Problem (measured on device)

Fabric-offloaded gmloader (Maldita Castilla) runs ~14 fps. On-device profiling
via the fabric's own perf counters + a render-resolution sweep localized the cost:

- Fabric-busy per frame at 320×240 = **48.9 ms**, of which the composite pipeline
  (`perf_pipe_cyc`) is only **2.45 ms**. The rest is the TRILIST per-pixel walk.
- Cost scales ~linearly with pixel count (320×240→48.9 ms, 160×120→14.8 ms,
  80×60→5.6 ms) ⇒ **~0.6 µs/px ≈ 59 clk_sys cyc/px** @ 98.4375 MHz.
- NOT the poll wait, NOT the framebuffer (already WORK/SCAN double-buffered), NOT
  staging (miss-only), NOT textures (NOTEX saved ~2 ms).

### Per-pixel cycle attribution (from FSM trace)

For a covered pixel with a dst-reading blend (`blitter_top.sv` inner loop
`S_TRI_PIX`→`S_TRI_ADV`):

| Cost | Cyc | Note |
|---|---|---|
| **SDRAM texel fetch** (`S_TRI_GOTTEX` blocks on `p0_ok`) | **~46** | **78% — single outstanding read, no read-ahead** |
| interp/address multiply chain (`S_TRI_MUL0/1/MUL`, `S_TRI_ADDR/ADDR2`) | 6 | already registered DSP stages, walked serially |
| blend (`S_TRI_WR/WR2/WR3`) | 3 | already a 3-stage pipeline, walked serially |
| comp_fbram dst read (`S_TRI_DSTW/DSTC`) | 2 | 1-cyc BRAM latency |
| coverage + advance (`S_TRI_PIX`, `S_TRI_ADV`) | 2 | |

- **No per-pixel divide.** Interpolation is affine (area-normalized barycentric);
  `area_recip` is computed once per triangle in `blt_tri_setup` (~54 cyc, amortized).
- Only loop-carried dependency: the linear edge/attribute accumulator (`S_TRI_ADV`
  steps `w*/W*` by constant per-x deltas) — trivially parallelizable
  (`w(x,y) = row_base + x·dwdx`).
- Non-covered bbox pixels cost 2 cyc (test + skip); covered pixels ~59, so cost
  tracks covered-pixel count (≈ full-screen for this game).

**Target:** ~1–2 cyc/px steady state ⇒ 320×240 fabric ~1–3 ms ⇒ frame becomes
A9-logic-bound (~20 ms) ⇒ **~14 → ~40+ fps**.

## Design

The datapath math is already correct and bit-exact vs the refmodel; this is a
**control-path restructuring** (serialize→pipeline) plus a **memory-latency fix**.
The datapath arithmetic must stay bit-identical — the existing `tb_blitter_trilist_*`
golden tests are the invariant.

### Lever 1 (mandatory, ~78%): non-blocking, read-ahead texel fetch

Today: `S_TRI_ADDR2` issues one P_SRC read, `S_TRI_GOTTEX` blocks ~46 cyc on
`p0_ok`. Decouple address-generation from data-consumption so a texel read is
issued (up to) every cycle and responses stream back matched in-order to the
blend stage. Two sub-options, chosen after Task 1 characterizes P_SRC:

- **(a) read-ahead FIFO** if the jtframe P_SRC channel (`sdram_fb_cache.sv`
  ch5 / `jtframe_cache_mux`) accepts multiple outstanding reads: issue ahead,
  queue tags, consume on `p0_ok`. Hides the fixed latency after a one-time fill.
- **(b) texel cache / line buffer** (small BRAM) exploiting 2D spatial locality
  (row-order walk samples adjacent texels) to convert misses→1-cyc hits. Needed
  if the ~46 cyc is miss latency rather than fixed hit latency, and composes
  with (a).

This alone takes per-pixel from `~46 + datapath` to `~1 + fill`.

### Lever 2: pipeline the datapath (1 px/cyc)

Convert the `S_TRI_*` one-pixel-at-a-time FSM into a fixed-depth streaming
pipeline (~13–16 stages) accepting one new pixel/cycle. The stages already exist
as register layers (multiply split for Fmax; blend is a 3-stage mixer). This is a
control rewrite, not a datapath rewrite. RMW hazard: at 1 px/cyc, 4 pixels in a
row share a comp_fbram qword (`dst_qw = py*80 + px>>2`, lane = `px[1:0]`) — batch
the 4 lanes into one read-modify-write per qword (also cuts fb traffic 4×).

### Lever 3: parallel edge/attribute evaluation

Replace the serial `S_TRI_ADV` accumulator with a row-base + per-pixel-offset
evaluation (or a bank of adders) feeding the pipeline 1 px/cyc. Cheap; removes
the only loop-carried step.

## Validation (TDD — bit-exact is the invariant)

- The existing sim harness (`fpga/sim/tb_blitter_trilist_*`, `gen_tri_golden.c`,
  refmodel `blitter_ref`) provides golden bit-exact TRILIST vectors. **Every task
  must keep all golden tests passing** — the redesign changes *when* pixels are
  produced, never *what*.
- Add a **throughput assertion** to the TB (cycles-per-frame / cyc-per-covered-px)
  so speedup is regression-checked in sim, not just on device.
- On device: the deployed `GMLOADER_MFSUBMIT_STAT` perf counters already report
  fabric cyc/px directly — validate the real speedup + visual correctness with the
  `mister_run.sh` harness after each RBF build.

## Risks

- **Timing closure (Fmax):** more, shorter pipeline stages should *help* Fmax
  (prior TRILIST timing work fought comb depth) — but the texel-cache/FIFO and
  the wider RMW add paths to re-close. STA after Task 5.
- **P_SRC multiple-outstanding support** (Task 1 gate): decides Lever-1 (a) vs (b).
- **BRAM/DSP budget:** no second framebuffer needed (FB unchanged). Added BRAM =
  a small texel cache; added DSP = none (multiplies already present). Modest.
- **RMW hazard / pipeline correctness:** the batched-qword RMW and in-flight
  same-qword pixels need careful hazard handling — caught by golden bit-exact tests.

## Staged plan (each stage sim-verified bit-exact before the next)

- **Task 0 — Lock in the invariant.** Add a throughput counter + cyc/px assertion
  to a TRILIST TB; capture the current golden pass + baseline cyc/px in sim.
- **Task 1 — Characterize P_SRC.** Sim-probe `sdram_fb_cache.sv` ch5: is the ~46 cyc
  fixed hit latency or miss latency? Does it accept multiple outstanding reads?
  Decides Lever-1 (a) vs (b). Deliverable: a one-page finding, no RTL change.
- **Task 2 — Lever 3 (parallel edge/attr eval).** Smallest change; decouples
  `S_TRI_ADV`. Sim bit-exact.
- **Task 3 — Lever 2 (pipeline the datapath).** The control rewrite to 1 px/cyc
  (still texel-fetch-bound → limited device speedup, but sim bit-exact + datapath
  throughput proven). Includes batched-qword RMW.
- **Task 4 — Lever 1 (texel read-ahead / cache).** The big win. Sim bit-exact +
  cyc/px → ~1–2 in the TB throughput assertion.
- **Task 5 — Quartus build + timing closure + STA** (Windows runner; the RBF build
  is the canonical path).
- **Task 6 — Deploy RBF + on-device perf + visual validation** via `mister_run.sh`
  (expect fabric ~46 ms → ~1–3 ms; frame → A9-logic-bound ~40+ fps).

**Ordering note:** Lever 1 is ~78% of the win but needs the 1-px/cyc consumer
(Lever 2) to be useful, so datapath pipelining lands first in sim even though its
*device* speedup only appears once Lever 1 removes the texel stall. Tasks 2–4 are
all gated behind the Task 0 throughput harness + the golden bit-exact suite.

---

## Task 1 findings (COMPLETE, 2026-07-16) — reshapes the plan

P_SRC (ch5) fully characterized (jtframe cache + `sdram_fb_cache.sv`):
- **Hit latency = 4 clk; miss latency ≈ 140 clk** (128-word line-fill, single-beat
  SDRAM bursts, tRCD/CL=2).
- **Cache = 2 lines × 256 B (32 texels/line), fully associative, 512 B total.**
- **Strictly SINGLE-OUTSTANDING**: `jtframe_cache_req` holds one request
  (1-bit `req_pending`), `jtframe_cache_ctrl` takes a new req only in `S_IDLE`,
  the mux `ok_hold[5]` is a single bit. **A read-ahead FIFO of many outstanding
  P_SRC reads is impossible without forking vendored jtframe.**
- **The measured ~46 cyc/px = ~30% miss rate** (`4 + m·136 = 46 ⇒ m≈0.30`). A
  sequential in-line walk would miss ~3%; 30% ⇒ the 2-line cache **thrashes**
  because the texel walk interleaves more texture rows than 2 lines hold.
- Corollary from `tb_profile`: the `comp_pipeline` **BLIT** path is already fast
  (1.65–2.23 cyc/px, source-fetch overlapped) — the problem is unique to the
  **TRILIST** per-pixel gather FSM, not the compositor.

### Revised Lever 1 (was "FIFO or cache" → now decided)

Read-ahead FIFO is blocked by hardware. Lever 1 = a **blitter-side prefetching
texel line cache**: a prefetcher runs ahead of the rasterizer issuing
single-outstanding P_SRC reads into a local BRAM; the rasterizer reads texels at
**1/cyc** from BRAM, fully decoupled from P_SRC latency and its single-outstanding
limit. Zero jtframe changes.

### NEW cheap experiment (front-loaded) — potential ~7× for a one-line change

Before the line-cache build: bump **ch5 `RO_BLOCKS` 2→8** (more fully-assoc lines
= holds more texture rows → kills the 30% thrash). Best case ~46→~8 cyc/px (mostly
4-cyc hits) ⇒ 320×240 fabric ~46 ms→~7 ms ⇒ **~14→~37 fps** with *no rasterizer
rewrite*. Caveats: can't reach 1 px/cyc (4-cyc hit floor through the mux — only a
blitter-local 1-cyc BRAM port does), and BRAM cost (size a ch5-only param, don't
widen ch2/3/4/6/7). Measurable in sim (`tb_blitter_trilist_pipe`, real cache)
BEFORE any Quartus build.

### Revised task order

- **T2 (NEW, cheap first):** ch5 `RO_BLOCKS` 2→8 param bump; measure miss-rate/cyc-px
  in sim with the real cache. If it lands ~37 fps, this may be most of the win.
- **T3:** blitter-side texel line cache (the real 1-tex/cyc decoupling) — bigger,
  needed for full 1 px/cyc.
- **T4:** pipeline the datapath (Lever 2) + parallel edge/attr (Lever 3), riding on
  the line cache.
- **T5/T6:** Quartus build + timing closure + STA; deploy + on-device validation.


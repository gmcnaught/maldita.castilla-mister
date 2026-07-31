# Maldita 60 fps — Phase 3: fabric dpath lever

**Date:** 2026-07-29
**Status:** approved design (user, 2026-07-29)
**Baseline:** period 21.6 ms / 46.3 fps on `.62`; period ≈ fabric (19.30 ms) +
~1.7 ms exposed host. Numbers and re-gate from
`docs/superpowers/findings/2026-07-29-phase2-baseline.md`.

## Goal and success gates

60 fps needs period ≤16.69 ms, so fabric ≤ **15.0 ms**. Phase 3 is two-stage by
decision:

1. **Quiet-scene gate (this phase must pass):** fabric `frame` 19.30 → **≤14.5 ms
   design target** (≤15.0 is the hard gate; 15.0 is exactly at budget, so 14.5 is
   the margin target) on the Chapter I quiet standing pose, measured by the
   Phase 2 protocol.
2. **Arrival sizing (deliverable, not a gate):** a measured decomposition of the
   Chapter I arrival transient (fabric 25.5 ms, needs 1.70×) sufficient to decide
   Phase 4's scope on data instead of conjecture.

Non-regression gates: rendering bit-exact vs refmodel; 0 timeouts / drops /
reclaims across the measurement window; audio underflow 0.0/s; STA no new
violations and M10K inference clean (`grep 276007 *.map.rpt`).

## Where the time is (measured, Phase 2)

| Term | Quiet | Arrival | Nature |
|---|---|---|---|
| fabric `frame` | 19.30 ms | 25.5 ms | the phase target |
| `dpath` | 13.59 (70%) | 18.0 | RTL-internal |
| `texwait` | 3.42 | 5.2 | prefetch-cache residual |
| `ovhd` | 2.29 | ~2.3 | ring/clear/setup |
| cyc/px | 7.3 | 7.2 | vs 6-cycle pb path |
| overdraw | 2.94 | 3.94 | contract-side |
| covered px | 182,661 | 245,346 | |

Two independent multipliers: **cyc/px 7.3** (RTL-internal) and **overdraw
2.94/3.94** (what the host submits). A structural contributor to cyc/px: the
rasterizer walks the full triangle **bounding box** (`S_TRI_PIX` tests coverage
per bbox pixel), and quads arrive split into two right triangles, so each
triangle covers ~half its bbox — the walk visits roughly 2× the covered pixels
and every miss still costs a cycle.

## Decisions taken at design time

- **Gate:** two-stage — quiet 60 fps now, size arrival for Phase 4.
- **Base:** `origin/milestone-a` (f2a39e2). Audit result: bit-identical in
  `fpga/` to the measured Phase 2 RBF `cd4d9f1`, and gm_audio is already merged
  there (PR #18 fixed the starvation artifact, verified on both rigs; PR #19 =
  cd4d9f1). There is no separate audio-base question.
- **Surface:** fabric RTL first; host↔fabric contract changes (opaque cull /
  ordering / scissor) allowed **if Stage A shows RTL-internal levers cannot
  reach the quiet gate** — decided before, not after, the Quartus cycle.
- **Workspace:** worktree `wt-maldita-60fps-p3`, branch `perf/60fps-phase3`
  (never `checkout -b` in the shared tree).

## Stage A — sizing, no Quartus cycle

Both decompositions are computable without a bitstream change.

- **A1 Draw-stream capture.** Dump the submitted triangle stream (vertices,
  texture id/coords, blend state, tint) for the quiet scene and the arrival
  transient. The input scripts are deterministic, so the capture is
  reproducible. Capture point: the engine's emit/submit boundary in
  `raster_backend_mfgpu.cpp`, env-gated, dumping to a file the bench scp's
  back — no bitstream or protocol change involved.
- **A2 Offline decomposition.** From the stream compute, per scene:
  bbox-area vs covered-area per triangle (the bbox-miss tax), and overdraw
  composition — covered pixels by (opaque texel, colorkey/alpha texel,
  blended draw), giving the ceiling for an opaque-cull contract lever.
- **A3 Sim replay + lever prototyping.** Replay the captured stream through the
  RTL sim for exact per-state cycle accounting, then prototype candidate levers
  in sim and measure predicted cycles bit-exactly before hardware. Candidates:
  - **Span-walk:** step the edge equations per row to derive the covered x-span
    and visit only covered pixels — removes the bbox tax entirely.
  - **Pixel-pipeline completion:** deepen the pa/pb overlap toward a streaming
    pipeline; 7.3 → ~5 cyc/px target.
- **A4 Decision gate.** Pick the lever set whose simulated quiet-scene cycles
  ≤14.5 ms at the fabric clock. If RTL-internal levers land short, add the
  opaque-cull contract lever to Stage B scope now. Write the arrival-scene
  Phase 4 sizing memo from the same data.

## Stage B — one committed Quartus cycle

- **B1 Implement the chosen lever(s)** in the vendored RTL
  (`maldita.castilla-mister/fpga/rtl/blitter_top.sv` + refmodel + sim in
  lockstep — the three-copy discipline). Bit-exact against the refmodel is a
  hard gate; span-walk changes pixel *visit order* but no pixel is visited
  twice within a triangle, so output must be identical — the refmodel gate
  proves it rather than assumes it.
- **B2 Bundled riders** (so the cycle isn't spent alone):
  - scanout-period counter (Phase 2 findings open question 4 — C_DONE counts
    fabric completions, not scanout);
  - STA hygiene: M10K inference gate, tint-path slack check.
- **B3 Sim gates:** full suite (51 at baseline) plus new equivalence tests for
  the new walk; mutation-check the new gates so they demonstrably catch bugs.
- **B4 Device validation on `.62`,** Phase 2 protocol unchanged: C_DONE
  (`0x3B000028`) delta over ≥30 s confirmed gameplay, sole-engine asserted
  every sample, screenshot-confirmed scenes, quiet + arrival windows, the
  non-regression gates above. Deploy via `make deploy-rbf` / `make
  deploy-engine` (HOST defaults `.62`).

## Risks and fallbacks

- **Sim-predicted ≠ device wall-clock.** Mitigation: A3 predictions are cycle
  counts from the same RTL, and the fallback is the Phase 2 loop — re-measure,
  re-gate, and only then choose the next lever. Texel-latency effects that sim
  underestimates show up in `texwait`, which is separately counted.
- **Levers land short at A4.** The decision gate escalates to the contract
  lever before Quartus; A2's opaque-cull ceiling says whether that closes the
  gap or Phase 3 re-scopes.
- **Timing closure risk** from a wider/deeper pixel path: multiply/divide comb
  depth is the known failure mode; pipeline each mul per the STA cell trace,
  and keep the `ramstyle` read-in-bare-always rule.
- **Measurement contamination:** dual-engine/daemon hazards are gated by
  `mister_run.sh` sole-engine assertions and the fixed deploy kill path; any
  anomalous window is discarded, not explained.

## Out of scope

- The remaining ~1.7 ms exposed host tail (revisit only if it grows).
- `texwait` (3.42 ms) and `ovhd` (2.29 ms) levers.
- The frame limiter defect (`main.cpp:836-849`) — measured zero-cost; do not
  spend a lever on it.
- Arrival-scene *fix* — Phase 3 sizes it; Phase 4 owns it.

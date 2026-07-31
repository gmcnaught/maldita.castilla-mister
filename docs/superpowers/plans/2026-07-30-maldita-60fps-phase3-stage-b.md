# Maldita 60 fps Phase 3 — Stage B (build + device validation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the Stage A RTL levers (span-walk + A-chain pipeline, already sim-complete on `perf/60fps-phase3`) through one Quartus cycle and device-validate quiet-scene 60 fps on `.62`, after resolving the texwait reserve offline.

**Architecture:** Ratified A4 decision (memo `docs/superpowers/findings/2026-07-30-phase3-stage-a-sizing.md` §1.1): Stage B = RTL levers only; the opaque-cull contract lever is Phase 4. The RTL is done and strictly bit-exact — Stage B is measurement, riders, build, and validation. Pre-Quartus prerequisite: the real-cache texwait sim, whose result is mechanical against the memo's §10 threshold table (quiet needs ≥42.2 % device-texwait recovery for the 15.0 ms hard gate; sim predicts 98.1 %).

**Tech Stack:** Icarus Verilog (`fpga/sim/run_sims.sh`, 54 gating), Quartus on the self-hosted Windows runner (canonical RBF build), `make deploy-rbf` / `make deploy-engine` (HOST defaults `.62`), `mister_run.sh` bench protocol.

**Spec:** `docs/superpowers/specs/2026-07-29-maldita-60fps-phase3-fabric-dpath.md` (B1–B4) as amended by the ratified deviation in the Stage A memo.

## Global Constraints

- **Branch state:** maldita `perf/60fps-phase3` @ 25c813a (worktree `wt-maldita-60fps-p3`) carries all RTL; gmloader-next `perf/60fps-phase3` @ b775007 carries the trace capture (no engine change is required for Stage B validation — the Phase 2 engine protocol works unchanged).
- **Device:** `.62` only. `.81` is production — never deploy there in this phase.
- **Decision numbers (memo §10):** measured device texwait after the levers must be ≤1.98 ms for fabric ≤15.0 (hard gate), ≤1.48 ms for ≤14.5 (design). Today's device texwait: 3.42 ms quiet / 5.2 ms arrival. Sim (stub floor) shows 0.013 ms.
- **STA/build gates (memo §9.2, binding pre-deploy):** `grep 276007 *.map.rpt` (M10K inference), tint-path slack check, verify `pp_*`/`tex_row` DSPs pack input+output-registered under the `ax_v[k]` enables.
- **Bench prerequisite (memo §10 item 5):** the automated submit-timeout wedge gate must land in `mister_run.sh` before any B-phase device measurement (frame-1 wedge hits ~1/2 core loads; retry clears, reboot does NOT).
- **Measurement protocol:** Phase 2 unchanged — C_DONE (`0x3B000028`) delta ≥30 s confirmed gameplay, sole engine asserted every sample, screenshots, fabric medians match 0.01 ms across runs or the run is discarded.
- **Suite must stay green:** 54 gating tbs, strict bit-exact.

---

### Task 1: Real-cache texwait sim (pre-Quartus prerequisite)

**Files:**
- Modify: `wt-maldita-60fps-p3/fpga/sim/tb_blitter_trilist_stream.sv` (a `STREAM_REALCACHE` ifdef variant re-pointing the `p0_*` texel port at `sdram_fb_cache` + the mt48 model, exactly as `tb_blitter_trilist_sdram.sv` wires it — reuse that bench's instantiation block)
- Modify: `wt-maldita-60fps-p3/fpga/sim/run_sims.sh` (register the variant NIGHTLY_ONLY/NONGATING — runtime ~10× the stub tb)

**Interfaces:**
- Consumes: committed `stream_quiet_f0` vectors + regenerated arrival f3 (recipe in task-6-report; source traces committed).
- Produces: measured sim texwait on the real-cache path for quiet f0 and arrival f3, post-levers → the memo §10 decision: recovery ≥42.2 % → proceed to Task 2; below → STOP, escalate candidate A (pb pipeline) per the memo before any Quartus spend, and re-plan.

- [ ] **Step 1:** Study `tb_blitter_trilist_sdram.sv`'s cache+mt48 wiring; add the `STREAM_REALCACHE` variant to the stream tb (single harness copy, macro pattern like `tb_blitter_trilist_synthquad.sv`).
- [ ] **Step 2:** Run quiet f0 + arrival f3 through it; record `texwait` (and `total`) alongside the stub numbers. Bit-exact gate must still hold (same DDR image, slower texels — output identical).
- [ ] **Step 3:** Evaluate against the §10 table; write the verdict into the report. Register in run_sims.sh, full suite green, commit with both CYC lines in the body.

**RESULT (2026-07-30, commits 79273f5 + bf2fb11 — task COMPLETE):** measured
real-cache texwait **2.437 ms quiet / 3.749 ms arrival** = **28.2 % recovery**
against the ≥42.2 % required, so the §10 trigger **FIRED**. Pre-lever
calibration was −0.69 % / −0.56 % against device on two scenes (no fitted
constants), and the number was independently reproduced in review; unmodelled
gaps are bounded ≤6 % and signed conservative. Memo §11 records the corrected
non-texwait (13.71 ms) and restated thresholds (1.29 / 0.79 ms).

**USER DECISION (2026-07-30): BUILD ANYWAY — ship the ~56 fps now.** The gate
governed *whether to spend the cycle*; the user elected to spend it on the two
landed levers rather than hold for candidate A. Tasks 2–6 therefore proceed as
written. Expectation to validate against: fabric 19.30 → **~16.15 ms**, period
21.02 → **~17.85 ms**, 46.3 → **~56 fps** — NOT 60. Candidate A (pb pipelining)
and the cull lever move to Phase 4; per the review's I2 correction, candidate A
alone leaves the arrival scene at 15.25 ms (misses 15.0), so Phase 4 needs the
cull lever for arrival regardless.

### Task 2: Scanout-period counter rider (spec B2)

**Files:**
- Modify: `wt-maldita-60fps-p3/fpga/rtl/` (small counter: scanout frame completions published to a spare perf address — follow the existing perf-counter publish pattern in `blitter_top.sv`/reader; C_DONE counts fabric completions, NOT scanout — this closes Phase 2 open question 4)

- [ ] **Step 1:** Locate the scanout vsync/frame boundary in the reader path; count completions; publish to a documented spare address (extend the reader-contract notes).
- [ ] **Step 2:** Sim: a tb assertion that the counter advances once per scanout frame in the system bench; full suite green; commit.

### Task 3: Bench wedge gate (pre-measurement prerequisite)

**Files:**
- Modify: `mister-gmloader/scripts/mister_run.sh` — after launch, automatically fail-and-retry the run if the log shows `submit timeout` (or C_DONE static while C_SUBMIT climbs) in the first N seconds; print an explicit `wedge: retry K` line. Manual discipline from Task 3/Stage A becomes mechanical.

- [ ] **Step 1:** Implement the gate + one retry loop (max 3), commit on master.

### Task 4: Quartus build + STA gates

- [ ] **Step 1:** Push `perf/60fps-phase3`; run the canonical Windows-runner build against the branch (maldita build flow; `make rbf-watch` / `deploy.py --fetch-rbf` resolves by fpga/ tree hash).
- [ ] **Step 2:** Gates on the build artifacts, all binding: `grep 276007 *.map.rpt` → no hits; setup slack report — no new failing domains vs the cd4d9f1 baseline (tint path in particular); confirm `pp_*`/`tex_row` DSP packing (input+output registered) in the fitter report. Any failure → fix on the branch (the STA cell-trace pipelining discipline), rebuild; do NOT deploy a failing build.

### Task 5: Deploy + device validation on `.62`

- [ ] **Step 1:** `make deploy-rbf HOST=192.168.20.62` (tree-hash gate live). Engine unchanged (Phase 2 binary) unless the capture env is wanted — it is: deploy the b775007 engine for the post-lever `--capture` re-run.
- [ ] **Step 2:** Phase 2 protocol, quiet + arrival: C_DONE-delta period, fabric counters, screenshots, sole engine, wedge gate active, audio underflow 0.0/s, 0 timeouts/drops/reclaims.
- [ ] **Step 3:** The decisive read: device fabric `frame` and `texwait` vs the memo predictions (quiet needs ≤15.0; texwait recovery vs the 42.2 % threshold). Re-run `--capture` + analyzer with `--expect-covered 182661` as the stream-consistency check.
- [ ] **Step 4:** Findings doc: measured vs predicted table (carry the memo's band), the re-gate for whatever remains, and the Phase 4 (arrival/cull ± candidates A/B) sizing handoff. Commit.

**RESULT (2026-07-30, RBF `MalditaCastilla_7c0b370.rbf` on `.62` — task COMPLETE).**
Full findings: `docs/superpowers/findings/2026-07-30-phase3-stage-b-device.md`.

**Fabric predictions landed; the fps prediction did not, and the miss is host-side.**
Quiet fabric `frame` **16.20 ms** (predicted 16.15, +0.31 %), `texwait` **2.465**
(predicted 2.437, +1.1 %), `dpath` 13.59 → 11.42, cyc/px 7.3 → 6.20, `cov_px`
182,661 unchanged. Arrival at the same `cov_px` 245,346 window: **21.37 ms** (band
was 21.6–22.0). Four independent runs match to ≤0.01 ms on every fabric column.

Delivered period **19.79 / 19.69 ms (50.5 / 50.8 fps)** as shipped, against a
predicted 17.85 / ~56. With `GMLOADER_FPS=0` (diagnostic sweep only): **18.09 ms /
55.27 fps** — i.e. the prediction is right and the engine's 60 fps cap
(`main.cpp:836-849`, `frame_ms = 1000/60 = 16` integer) is padding **1.70 ms/frame**
of `SDL_Delay`. Phase 2's "the limiter costs zero" finding was true at a 27 ms loop
body and is false at 18 ms. Host fix, no Quartus cycle, worth 1.70 ms.

New scanout counter works: `scan_period_cyc` = **1,642,740 in all 215 samples**
(zero spread) = **16.6882 ms / 59.9228 Hz**. Phase 2 open question 4 closed, and the
limiter now has a measured pacing target.

Clean: `to=0` over 1,172 windows, 0 drops/reclaims, no wedge on any of 4 loads, sole
engine at all 590 samples, 9 screenshots with no corruption, `--capture` +
`--expect-covered 182661` gate **0.00 %** off and byte-identical to Stage A's
decomposition. Audio: the `b775007` engine has no periodic underflow counter, so
"underflow 0.0/s" was checked only as absence (0 matches) — instrument gap recorded.

**Re-gate for Phase 4:** exposed host tail measured **1.89 ms**, so the fabric gate
is **≤ 14.80 ms** (vs Phase 2's 15.0). Quiet 16.20 → **1.095×**; arrival 21.37 →
**1.44×**. The `texwait` recovery is **27.9 %** (Task 1 predicted 28.2 %) against the
**≥ 62.3 %** the 15.0 gate needs — Stage A §11.2 corrected §10's 42.2 % as too
permissive by a stub-ratio error — and against **≥ ~69 %** for the new 14.80 ms gate
(14.80 − the measured 13.74 ms non-`texwait` leaves `texwait` ≤ 1.06 ms, 69.0 % of
3.42 ms). The pre-build trigger fired again on device at the same magnitude, by a
wider margin than the superseded threshold showed, so arrival still needs the
opaque-cull lever.

### Task 6: Merge decision

- [ ] **Step 1:** On device-validated success: merge maldita `perf/60fps-phase3` → milestone-a and gmloader `perf/60fps-phase3` → master via PRs (finishing-a-development-branch flow), bump pins in mister-gmloader, update memory. On a miss: the findings doc's re-gate decides Phase 4 scope first.

## Verification ladder

1. Task 1's threshold verdict gates everything downstream — no Quartus spend on a failed prerequisite.
2. Suite green (54+) at every RTL commit; strict bit-exact is unchanged as the oracle.
3. Build gates (M10K/STA/DSP) are binding pre-deploy.
4. Device numbers, not sim, decide the phase outcome; contaminated runs are discarded, not explained.

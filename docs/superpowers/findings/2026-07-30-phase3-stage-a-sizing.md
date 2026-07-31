# Phase 3 Stage A — sizing, the A4 decision, and the arrival-scene Phase 4 memo

**Date:** 2026-07-30
**Stack sized:** RBF `MalditaCastilla_cd4d9f1.rbf` (the Phase 2 baseline bitstream, unchanged
through all of Stage A) + engine `wt-gmloader-60fps-p3` @ `b775007`, md5
`8f6a2e542bd124d7b6c9496b13aa9c77`. Device `.62` (`root@192.168.20.62`); `.81` untouched.
**RTL sized:** `wt-maldita-60fps-p3`, branch `perf/60fps-phase3`, head `d4c346b`
(span walk `9414bba`+`b651c9b`, A-chain pipeline `c28c38f`+`d4c346b`). **No Quartus build was
made in Stage A** — every RTL number here is an iverilog cycle count, bit-exact against the
refmodel, and every device number is either a Phase 2/Task 3 measurement or a calibrated
prediction labelled as such.

**Gate.** **Phase 2's re-gate sets the hard gate: fabric ≤ 15.0 ms** — delivered period ≈ fabric +
~1.7 ms exposed host, and 60 fps is a 16.69 ms period. **The ≤ 14.5 ms design target is the Stage A
plan's**, not Phase 2's (plan Global Constraints: *"Budget: ≤14.5 ms fabric = ≤1.427 M cycles/frame"*)
— i.e. the hard gate plus a margin allowance. Every "frame" figure below is *fabric* ms; "period"
adds the 1.7 ms host tail, which was **measured on the quiet scene only** (Phase 2 host-lever run,
period 21.02 − fabric 19.30), so every arrival period/fps figure in this memo is an **extrapolation**
of that tail to a heavier scene.

---

## 1. The A4 decision, stated first

**RTL levers alone — span walk plus the A-chain pipeline — ship in Stage B, with the real-cache
`texwait` sim measurement as a pre-Quartus prerequisite. The opaque-cull contract lever does NOT
enter Stage B; it is the arrival scene's Phase 4 lever.**

**The A4 gate's trigger fired, so this is a deviation from A4 as written, ratified by the user on
2026-07-30.** §1.1 has the clause text, the deviation statement and the rationale.

### 1.1 The A4 trigger FIRED. Declining the cull is a RATIFIED DEVIATION from A4 as written.

Stated plainly, because the two halves are separate facts and only the first is arithmetic:

**The trigger fired.** §6's uncertainty-band item 2 sets this memo's own convention — *the
fixed-`texwait` row is the prediction, the zero-`texwait` row is a ceiling.* Under that convention
the RTL levers alone predict quiet at **16.28 – 16.44 ms** fabric, which **misses the 15.0 hard gate
across the whole ±5 % calibration band** (15.91 – 16.98 ms on the multiplicative form). So the A4
condition "RTL-internal levers land short" **is satisfied on the data as reported**.

**And the governing A4 clause is imperative, not permissive.** An earlier revision of this memo
argued the rule was a merely *necessary* condition and that declining the cull was therefore a
permitted non-exercise. **That was wrong, and it was wrong because it quoted the wrong clause.** The
clause it leaned on is the spec's Decisions-taken-at-design-time surface note (spec:52-54):

> **Surface:** fabric RTL first; host↔fabric contract changes (opaque cull / ordering / scissor)
> allowed **if Stage A shows RTL-internal levers cannot reach the quiet gate** — decided before, not
> after, the Quartus cycle.

The clause that actually governs this decision is **A4 itself, and it is an instruction**
(spec:79-82):

> **A4 Decision gate.** Pick the lever set whose simulated quiet-scene cycles ≤14.5 ms at the fabric
> clock. **If RTL-internal levers land short, add the opaque-cull contract lever to Stage B scope
> now.** Write the arrival-scene Phase 4 sizing memo from the same data.

reinforced by the risk register (spec:109-111):

> **Levers land short at A4.** The decision gate **escalates to the contract lever before Quartus**;
> A2's opaque-cull ceiling says whether that closes the gap or Phase 3 re-scopes.

"add … now" and "escalates" are directives. The antecedent is satisfied. **So keeping the cull out of
Stage B is a deviation from A4 as written — not a permitted non-exercise of an option.** It is
recorded here as a deviation so that a later reader comparing the spec against Stage B's scope finds
the departure named rather than having to rediscover it.

**Deviation status: RATIFIED by the user on 2026-07-30.** Ratified scope: **Stage B = RTL levers
only** (span walk + A-chain pipeline + riders), with the **real-cache `texwait` sim measurement as a
pre-Quartus prerequisite**; the **opaque-cull lever moves to Phase 4**. The rationale is the memo's
own data, unchanged by the ratification:

1. **Quiet does not need the cull if `texwait` recovers.** The fired trigger is a *reported* miss at
   a **fixed-`texwait`** assumption, not a demonstrated one — the ceiling row clears both gates
   (12.93 ms), and the required recovery is 42.2 % against a sim-measured 98.1 %. A4's antecedent is
   satisfied on the conservative reading and unsatisfied on the optimistic one, and Stage A never
   measured which holds. The prerequisite converts that into a number **before** the Quartus cycle,
   which preserves A4's actual intent — *decide before, not after, the Quartus cycle* — while
   deferring the irreversible part of the commitment.
2. **The RTL-internal levers are not exhausted.** pb still runs a 6.000 cyc/px sequencer (§5.1): the
   same defect, in the same module, just removed from pa. Candidate A sizes it at 5.27 ms (quiet) /
   7.01 ms (arrival) of dpath with no realization fraction required.
3. **The cull's ceiling needs 64 % realization on arrival** (§4) against an idealized model — perfect
   per-pixel occlusion knowledge at zero cull cost — whose cheap subset is only whole-draw and
   whole-triangle culls. Admitting it to Stage B would put a host↔fabric contract change and an
   unmeasured realization fraction into the same Quartus cycle as two levers that are already
   bit-exact and sim-gated.
4. **The spec provides for this outcome itself.** spec:111's alternative branch is explicit — the
   opaque-cull ceiling "says whether that closes the gap **or Phase 3 re-scopes**." Moving the cull
   to Phase 4 is that re-scope, taken on A2's ceiling data as the clause anticipates.

Nothing above weakens the trigger finding: **if the prerequisite measurement shows < 42.2 % recovery,
quiet misses on RTL levers alone**, and the escalation named in §5.3 (candidate A) has to happen
before the build. The deviation is about *which* lever the escalation reaches for, not about whether
one is needed.

Two things qualify the decision, and both are quantified rather than hedged:

* **The gap between the prediction and the ceiling is one unmeasured quantity.** Fixed-`texwait`
  gives 16.28 – 16.44 ms (55.1 – 55.6 fps delivered); the zero-`texwait` ceiling gives **12.93 ms**
  (68.4 fps), which clears both gates with room. **Nothing else differs between those rows** — the
  entire 3.35 ms is device `texwait` after the ~8× prefetch-lead change. So the fired trigger is
  a *reported* miss, not a demonstrated one.
* **What `texwait` has to do for the RTL levers to land the gate on their own.** Multiplicative form
  first (§6.1 deprecates the additive form for extrapolation); additive shown for continuity with
  Tasks 6–7:

| for quiet to reach | non-texwait (multiplicative) | `texwait` ≤ | recover | (additive form) |
|---|---|---|---|---|
| **15.0 ms (hard)** | **13.02 ms** (point) | **≤ 1.98 ms** | **≥ 42.2 %** of the 3.42 ms | 12.87 → ≤ 2.13 → ≥ 37.6 % |
| 15.0 ms, band high end (+5 %) | 13.56 ms | ≤ 1.44 ms | ≥ 57.9 % | 13.51 → ≤ 1.49 → ≥ 56.4 % |
| 15.0 ms, band low end (−5 %) | 12.49 ms | ≤ 2.51 ms | ≥ 26.5 % | 12.22 → ≤ 2.78 → ≥ 18.8 % |
| **14.5 ms (design)** | **13.02 ms** | **≤ 1.48 ms** | **≥ 56.8 %** | 12.87 → ≤ 1.63 → ≥ 52.2 % |

Sim measured a **98.1 %** recovery (`texwait` 69,520 → 1,303 cyc on quiet f0), far above every
threshold in that table — **but sim `texwait` is a floor, not an estimate** (§6), so it cannot be
quoted as the prediction. The required **26 – 58 %** is a much weaker claim than the 98 % sim shows,
which is why the verdict is **"RTL levers probably reach the quiet gate"** and not "will".

**What resolves it, in order of cost:**

1. **Task 5 follow-up #1 — re-point the stream tb's `p0_*` at `sdram_fb_cache` + mt48**
   (`tb_blitter_trilist_sdram` already co-simulates both). Offline, no Quartus, ~10× runtime →
   nightly/NONGATING. This is the single highest-value item in the whole phase: it converts the
   3.35 ms of uncertainty into a number **before** the Quartus cycle is spent.
2. Stage B's device validation (B4) measures it directly, but only after the build.

**Recommendation: run (1) before committing the Stage B build.** If it shows **< 42.2 %** recovery
(multiplicative point form), the escalation is **candidate A (pb pipelining, §5.1)** — not the
contract lever.

**Why candidate A rather than the cull, stated on the correct comparison.** Candidate A does **not**
size larger than the cull ceiling — on both scenes the ceiling is bigger (quiet: A saves 5.27 ms of
dpath, 10.73 → 5.46, against a 7.08 ms cull ceiling; arrival: A saves 7.01 ms, 14.31 → 7.30, against
10.68 ms). The preference is about what kind of number each is:

* **Candidate A's figure is a full sizing** — a definite mechanism (remove pb's serialization) with a
  hard floor (the 3.000 cyc/px blend) computed from measured per-state occupancy. It needs no
  realization fraction.
* **The cull's figure is an idealized upper bound** — perfect per-pixel occlusion knowledge at zero
  cull cost — and arrival needs **64 % of it realized** to reach the gate (§4). Only whole-draw and
  whole-triangle culls are cheap; the realizable fraction is unknown.
* Candidate A is also RTL-internal (no host↔fabric protocol change, no engine/RBF deploy coupling)
  and reuses an implementation template just proven on pa.

So the cull is not dominated on size; it is deferred because its number is softer and its blast
radius is larger. §5.3 has the composition arithmetic, including the fact that funding the cull
*after* candidate A halves its value.

---

## 2. The lever table (the A4 shape)

Fabric ms. "today" is **measured on device**; the two prediction columns are **sim cycles
calibrated to device** (§6), quoted with the ±5 % non-texel band and the fixed-`texwait`
assumption. Two calibration forms are given because neither is privileged (§7.1) — they disagree by
**0.09 ms** (quiet span-walk), **0.16 ms** (quiet pipeline), **0.24 ms** (arrival span-walk) and
**0.39 ms** (arrival pipeline, three forms): **additive** = Task 6/7's method (sim non-texwait
+ 73,445 cyc); **multiplicative** = sim dpath cyc/px × the device/sim dpath ratio, then + measured
`texwait` + measured `ovhd`. **§6.1 deprecates the additive form for extrapolation**, so the
multiplicative figure is the one to carry forward.

| Scene | fabric today | predicted w/ span-walk | + pipeline | needed | verdict |
|---|---|---|---|---|---|
| **Quiet** | **19.30 ms** (measured, 3 runs to 0.01 ms) | **17.55 – 17.64 ms** ± 0.54 – 0.64 band | **16.28 – 16.44 ms** ± 0.54 – 0.64 band | ≤ 14.5 design / 15.0 hard | **MISS at fixed `texwait`** — misses across the whole band (15.91 – 16.98 multiplicative). **CLEARS at the `texwait` ceiling (12.93 ms).** Needs **≥ 42.2 %** `texwait` recovery (multiplicative; 37.6 % additive). |
| **Arrival** | **25.5 ms** (measured; Task 3 recap 25.52) | **23.29 – 23.53 ms** ± 0.72 – 0.83 band | **21.57 – 21.96 ms** ± 0.72 – 0.83 band | ≤ 15.0 | **MISS, decisively.** 6.8 ms short — larger than the band by ~9×. Not closable by any further pa or texel-latency work: the non-texwait term alone is 16.4 – 16.8 ms. |

Delivered period and fps (fabric + 1.7 ms exposed host). **The 1.7 ms tail was measured on the quiet
scene only**, so every arrival row here is an extrapolation of it — flagged per-row:

| | fabric | period | fps | vs 60 |
|---|---|---|---|---|
| quiet today | 19.30 | 21.02 – 21.60 (**measured**) | 46.3 (**measured**) | −13.7 |
| quiet + span-walk | 17.55 – 17.64 | 19.25 – 19.34 | 51.7 – 52.0 | −8 |
| quiet + pipeline, fixed `texwait` | 16.28 – 16.44 | 17.98 – 18.14 | 55.1 – 55.6 | **−4.5** |
| quiet + pipeline, `texwait` ceiling | 12.93 | 14.63 | **68.4** | **+8.4** |
| arrival today | 25.5 (measured) | ~27.2 (**extrapolated tail**) | ~36.8 (**extrapolated**) | −23 |
| arrival + pipeline, measured `texwait` 5.2 | 21.57 – 21.96 | 23.27 – 23.66 (**extrapolated tail**) | 42.3 – 43.0 (**extrapolated**) | −17 |

The extrapolation is not free: the exposed host tail is post-await draw emission, present and
capture, and there is no measurement showing it stays at 1.7 ms when the fabric term grows by 6 ms.
It is used because no arrival-scene period was ever sampled; all *fabric* arrival figures are
independent of it.

**`texwait` is the whole reserve, on both scenes.** Note that quiet's conservative row is 4.5 fps
short of 60 while the ceiling row is 8.4 fps over: the deliverable outcome of the Stage B build is
genuinely undetermined by Stage A data.

### 2.1 Where the cycles went — the sim ladder both levers were measured on

Strictly bit-exact (`exact_bad = 0`) at every rung, on all five replay vectors; `pix_covered`,
`wr`, `rowsetup` and the synthquad/spanedge hand-count anchors are **numerically identical**
before and after both changes, which is the evidence that no walk decision and no written pixel
moved.

| quiet f0 (182,661 covered px) | `total` cyc | `tri` cyc | non-texwait cyc | `tri`/covered | sim ms |
|---|---|---|---|---|---|
| baseline (`96915e2`) | 1,561,088 | 1,482,814 | 1,489,743 | 8.118 | 15.859 |
| + span walk (`b651c9b`) | 1,386,792 | 1,308,428 | 1,317,272 | **7.163** | 14.088 |
| + A-chain pipeline (`d4c346b`) | **1,194,272** | **1,115,958** | **1,192,969** | **6.109** | **12.132** |

| arrival f3 (245,530 covered px) | `total` cyc | `tri` cyc | non-texwait cyc | `tri`/covered | sim ms |
|---|---|---|---|---|---|
| baseline | 2,070,124 | 1,989,654 | 1,963,170 | 8.104 | 21.030 |
| + span walk | 1,835,528 | 1,754,964 | 1,731,005 | 7.148 | 18.647 |
| + A-chain pipeline | **1,577,496** | **1,496,983** | **1,576,156** | **6.097** | **16.025** |

Mechanisms, named:

* **Span walk** removed the bbox tax. The walk paid one coverage test per *bbox* pixel (372,644
  tests for 182,661 pixels, 2.03×); three pa states now traverse each row's covered interval
  (`A_SEEK` locates the row's first covered x incrementally from the previous row's endpoint — no
  divide, 2.93 seek+rowstep cyc/row), so `pix_visits` fell 372,644 → 185,450.
* **A-chain pipeline** turned the six `A_MUL0..A_ISSUE` states from a sequencer into a 6-deep
  feed-forward pipeline behind a credit-limited dispatcher: initiation interval 7 → 1 cyc/px,
  latency unchanged at 6, **203 net flops** (single-stage hand-offs already *were* the pipeline
  registers under NBA semantics). pa fell **7.087 → 1.099** cyc/covered px. Wall-clock now tracks
  **pb**, whose floor is 6.000 state-cycles/px.
* **Second-order:** giving pa an 8-pixel lead (`TEXFIFO_D = 8` ≈ 48 cyc at pb's retire rate) turned
  the best-effort texel prefetch from a 76.3 % hit rate into a 99.8 % one. Sim `texwait`
  69,520 → 1,303 cyc. **Directionally robust, magnitude not transferable** — §6.

**pa has nothing measurable left.** `synth_quad` (6.011 cyc/px) and `span_edge` (6.082) are
pure-hit-path vectors and both have landed on pb's 6.000 floor; `a2_cycle_gate.vh` prints
`pb-occupancy 6.00 / wall-clock 6.00`, the convergence its EXPIRY note said would mark pa dropping
below pb.

---

## 3. Device-truth anchors — the 182,661 chain

Nothing in this memo is trusted from a single implementation. The quiet scene's covered-pixel
count is produced by **three independent implementations of the same coverage rule** and they
agree **exactly**:

| source | implementation | quiet | arrival |
|---|---|---|---|
| device `perf_covered_px` (fabric counter, `.62`) | registered edge-function walk in `blitter_top.sv` | **182,661** (constant across 6,270 MFSUBMIT windows) | 245,492 ± 8 (Task 3); 245,346 (Phase 2) |
| offline analyzer (`scripts/mftrace_analyze.py`) | Python transcription of `blt_tri.c`'s `blt_raster_tri()` | **182,661** (median of 8 frames) | 245,484 (median) |
| sim replay (`tb_blitter_trilist_stream`) | the production RTL, re-executing the captured stream | **182,661** (f0, f1, f2 identical) | 245,530 (f3) |

Overdraw corroborates: device 2.94, analyzer 2.936 (quiet); device 3.94, analyzer 3.946 (arrival).
The analyzer's device-truth gate (covered_px within ±2 % of 182,661, overdraw ≈ 2.94) is
**PASS at 0.0 % delta**, and `pix_covered == perf_covered_px` is a *gated* cross-check in the sim
suite — a divergence prints `RESULT: FAIL`.

The arrival spread (245,346 / 245,484 / 245,492 / 245,530) is ±0.08 % and is scene-transient
sampling, not implementation disagreement: the analyzer figure is a median over 8 captured frames,
the sim figure is the one frame replayed (frame 3, +46 px = +0.019 % from the median), and the two
device figures come from different runs of a transient whose frame index drifts ≈ 30 frames run to
run.

### 3.1 Calibrated capture windows (Task 3)

Both captures are gated on `grep -c 'submit timeout' == 0` and on the bench's per-sample
sole-engine assertion.

| capture | `--capture START:FRAMES` | f-range | in-scene evidence |
|---|---|---|---|
| quiet | `4000:8` | 4000–4007 | log window `n=4080`: `frame=19.33 tri=17.01 texwait=3.42 dpath=13.59 cov_px=182,661`; screenshot at `hit_f=4050` — Chapter I forest, HUD `SPEEDRUN 00:36 / TIME 89` |
| arrival | `2465:8` | 2465–2472 | log window `n=2490`: `frame=25.52 cov_px=245,492`; adjacent `n=2460` = `25.86 / 248,427`; screenshot at `hit_f=2520` — Chapter I, sword raised, `SPEEDRUN 00:11` |

`2465` was the **second** attempt: `START=2500` landed in the transient's decay (22.82 ms /
218,221 px) and that file was inspected and rejected rather than used. The arrival transient's
frame index drifts ≈ 30 frames run to run — any future arrival capture must re-confirm placement
against **its own** run's `MFSUBMIT` windows.

Capture files: 8 frames each, `docs/superpowers/findings/data/mftrace-quiet.txt` (848 G / 5,088 V
records, 212 tris/frame) and `mftrace-arrival.txt` (980 G / 5,880 V, 248 tris ×6 + 236 ×2). Zero
malformed or foreign lines; `V == 3 × Σnt` in both.

---

## 4. Opaque-cull ceiling, converted to ms — the arrival scene's lever

The analyzer's `cullable_px` marks a covered pixel of a triangle cullable iff that triangle is not
the pixel's final writer **and** the final writer's group blend mode is `BLT_BLEND_COPY` — i.e. a
provable full occluder, since a COPY-mode TRILIST group is opaque by construction (the engine's
`mf_emit_group` promotion comment: "an opaque, un-keyed ALPHA draw has nothing to blend against").

| | covered_px | cullable_px | cullable share | ceiling @ 6.1 sim cyc/px | ceiling, device-calibrated |
|---|---|---|---|---|---|
| quiet | 182,661 | **120,453** | **65.9 %** | 735,847 cyc = **7.48 ms** | 5.784 cyc/px → **7.08 ms** |
| arrival | 245,484 | **183,276** | **74.7 %** | 1,117,633 cyc = **11.35 ms** | 5.737 cyc/px → **10.68 ms** |

Blend composition, which is what makes the ceiling large: quiet is COPY 125,568 / COLORKEY 57,093
/ CONST_ALPHA 0; arrival is COPY 125,568 / CONST_ALPHA 62,208 / COLORKEY 57,708. Both frames touch
only 62,208 unique pixels — the full 288×216 screen — so `unique_px == covered_px − cullable_px`
exactly on quiet (182,661 − 120,453 = 62,208) and the arrival delta (245,484 − 183,276 = 62,208)
is the same identity. **A perfect occlusion cull would leave exactly one write per screen pixel.**

**Positioned per the A4 rule:** the trigger fired on the quiet scene, and A4 as written would put this
lever into Stage B scope now. It is held out instead — a **deviation, ratified by the user on
2026-07-30** (§1.1) — so this does not enter Stage B. The arrival scene is where it earns its place,
and it needs *something* of this size:

* Arrival after both RTL levers is **21.81 ms** fabric (multiplicative form, measured 5.2 ms
  `texwait`); the gate is 15.0 ms, so the required cut is **6.81 ms**.
* Against a device-calibrated cull ceiling of **10.68 ms**, that is **64 % of the ceiling** —
  a demanding but not absurd realization fraction.
* Arrival's shortfall is **immune to further pa or texel-latency work**: its non-texwait term alone
  is 16.37 ms (arrival-anchored) to 16.76 ms (quiet-anchored additive), against a 15.0 ms fabric
  gate. Even at a zero-`texwait` ceiling it lands at 16.4 – 16.8 ms and misses.

**Ceiling caveats, stated so the 10.68 ms is not mistaken for a deliverable.** The ceiling assumes
perfect per-pixel occlusion knowledge at zero cull cost. Only *whole-draw* and *whole-triangle*
culls are cheap; a partial cull needs per-pixel occlusion state (a coverage mask or a scissor
contract), which has its own cost not modelled here. The one piece that is unambiguously realizable
is the **CLEAR** (§8.1): a 62,208-pixel draw that is **100 % cullable** by this rule, since the
COPY draws already repaint every screen pixel.

---

## 5. Two further candidates, sized on paper

**Label: paper sizing from Task 7 §5.1's post-pipeline `CYCX` occupancy** (not §1's, which is the
*pre*-pipeline baseline). **Neither candidate is prototyped, neither is sim-validated, neither has
been through STA.** Method: take the post-pipeline pb occupancy, remove the cycles the candidate
overlaps or widens away, take `max(pa, pb) + per-triangle tail` as the new sim cyc/px, then apply the
device/sim dpath ratio and add the *measured* `texwait` and `ovhd`. **The ±5 % non-texel calibration
band (§6, item 1) applies to every dpath figure below and is carried in both tables** — it is not
optional decoration, because two of these rows sit inside it relative to their gate.

pb's 6.000 cyc/px floor decomposes cleanly, and this is the input both candidates work from
(quiet f0, post-pipeline):

| pb component | cyc | /covered px | note |
|---|---|---|---|
| `B_IDLE` pop | 182,661 | **1.000** | the FIFO pop |
| texel acquire (`B_LOOK`+`B_FILL`, or `B_SURF_W`+`B_SURF_C`) | 365,868 | **2.003** | 2 cyc/px uniformly — registered BRAM read + resolve |
| blend/write (`B_WR`+`WR2`+`WR3`) | 547,983 | **3.000** | 3-stage blend, one fb qword write |
| `B_WAIT` + starvation residue | 5,666 | 0.031 | |
| per-triangle tail (`tri` − Σocc) | 13,780 | 0.075 | setup + vfetch |
| **wall-clock** | | **6.109** | pa is 1.099 and no longer binding |

### 5.1 Candidate A — pb pipelining

**pb is still a sequencer, exactly as pa was.** Per pixel it runs pop → look → fill → wr → wr2 →
wr3 in sequence, so the pop and the 2-cycle texel acquire of pixel N+1 sit *behind* the blend of
pixel N instead of underneath it. The pa transformation applies verbatim: overlap N+1's pop and
lookup with N's blend, gated on a valid-shift register rather than a `case (pb)` arm.

**Ceiling:** pb service falls to the **blend's 3.000 cyc/px**, which is the floor because the three
`B_WR*` stages cannot be overlapped without duplicating the blend arithmetic (that is candidate B).
New sim wall-clock ≈ **3.106 cyc/px** (3.000 blend + 0.031 residual + 0.075 tail); pa at 1.099
stays comfortably under it.

| candidate A | dpath ± band | fabric frame (band range) | period | fps | vs gate |
|---|---|---|---|---|---|
| quiet (`texwait` 3.42 measured) | 5.46 ± 0.27 ms | **11.17 ms** (10.90 – 11.45) | 12.87 | **77.7** | clears 14.5 by 3.3 ms — **band-robust** (3.1 ms clear at the worst end) |
| arrival (`texwait` 5.2 measured) | 7.30 ± 0.36 ms | **14.80 ms** (14.43 – 15.16) | 16.50 | **60.6** | **BAND-INCONCLUSIVE** vs 15.0 — point estimate clears by 0.20 ms, the band's high end **misses by 0.16 ms** |

**Candidate A brings the arrival scene to the edge of its gate at arrival's own measured `texwait`,
which no other lever sized here does — but 0.20 ms of margin against a ±0.36 ms band is not a fit.**
The correct claim is: candidate A is the only candidate for which arrival's gate is *in reach at all*
on the fixed-`texwait` prediction, and whether it actually lands there cannot be settled by paper
sizing. Resolving it needs the prototype's own sim measurement plus a device check — the same
discipline §1 applies to quiet.

For quiet, candidate A **is** band-robust: 11.17 ms with a worst-case 11.45 ms is 3.05 ms inside the
14.5 design gate even at zero `texwait` recovery, so it removes the §1 uncertainty from the quiet
decision entirely. That asymmetry — decisive on quiet, inconclusive on arrival — is the honest
summary of candidate A.

Risks, from the same source that makes the estimate credible: pb's three blend stages **exist
because a shallower blend failed STA**, so unlike pa's 7-cycle chain this 6 is not obviously slack.
The overlap does not shorten any stage — it only removes the serialization — so it should not
deepen the `modch` critical path, but the credit/valid control would add fanout onto exactly the
path that is already critical. Task 7 follow-up #4 named the cheaper half of this
(collapsing `B_LOOK`/`B_FILL` by folding the resolve into `B_WR` if the tag compare closes — worth
~2 of the 6, ≈5 ms on arrival) as the more promising first step.

### 5.2 Candidate B — 2-px/cyc blend widening

Halve the 3.000 blend floor by processing **adjacent pixel pairs** through a duplicated blend
datapath.

**Stage A created the enablers:**
* The span walk emits **sequential x within a row** — adjacent pairs are now the natural
  dispatch order, which the old bbox scan also gave but with a coverage test between them.
* At 4 px per framebuffer qword, an adjacent pair **shares its destination fb qword** most of the
  time, so the pair is one write, not two.
* Adjacent pairs usually share their **texel cache qword** too (the same 4-consecutive-pixels-per-
  qword locality that the prefetch-lead change exploited to reach a 99.8 % hit rate).
* The A-chain pipeline already dispatches at 1 px/cyc, so pa can feed a 2-px/cyc consumer without
  further work (`ax_cred`/`TEXFIFO_D` set the lead and both are now width-derived and safe to
  raise).

**Costs:**
* Duplicated 3-stage blend arithmetic. ALM headroom exists — the last recorded Quartus fit put
  ALMs at **38 %** after the `tq_data` M10K-inference fix (61 % → 38 %) — but that fit predates all
  Phase 3 RTL and has **not** been re-measured.
* A **second texel-cache read port**, via M10K true dual-port. Cheap in fabric, but the
  `ramstyle` read must stay in a bare unconditional `always` block (the Info-276007 rule).
* **Paired dst reads only for non-promoted alpha** — COPY and COLORKEY need no destination read;
  CONST_ALPHA does, and arrival has 62,208 CONST_ALPHA pixels where quiet has none. So the
  widening's benefit is *smaller* on arrival than a flat halving suggests unless the dst path is
  widened too.
* **Pair-former edge cases:** odd span lengths, row ends, and single-pixel spans (the sliver
  geometry `span_edge` exists for) all need a 1-px path that must stay bit-exact.
* **STA risk is routing/fanout, not depth** — no stage gets deeper, but the pair mux and the
  duplicated write path land on the `modch` blend net that is already critical.

* **Both candidates HALVE the prefetch lead in cycles at a fixed `TEXFIFO_D`.** The lead is
  `TEXFIFO_D` pixels × pb's retire interval: 8 px × 6 cyc = **48 cyc today**, 8 × 3 = **24 cyc after
  candidate A**, 8 × 1.5 = **12 cyc after A+B**. Since a device texel miss costs ~12 cyc, A+B would
  erase the lead margin entirely at `TEXFIFO_D = 8`. So **§6's item-2 re-measure rule applies to
  candidates A and B in their own right** — each changes texel arrival timing — and `TEXFIFO_D = 16`
  stops being an optional sweep (§8.2) and becomes a co-requisite of either candidate. This coupling
  is not in any task report; it falls out of the retire-rate change.

| candidate B | dpath ± band | fabric frame (band range) | period | fps | vs gate |
|---|---|---|---|---|---|
| **alone**, quiet | 8.09 ± 0.40 ms | 13.80 ms (13.40 – 14.21) | 15.50 | 64.5 | clears 14.5 — band-robust |
| **alone**, arrival | 10.79 ± 0.54 ms | **18.29 ms** (17.75 – 18.83) | 19.99 | 50.0 | **misses 15.0 by 3.3 ms** — band-decisive |
| **A + B**, quiet | 2.83 ± 0.14 ms | 8.54 ms (8.39 – 8.68) | 10.24 | 97.7 | — |
| **A + B**, arrival | 3.77 ± 0.19 ms | 11.27 ms (11.09 – 11.46) | 12.97 | 77.1 | — |

**B alone does not fix arrival, and A alone only reaches its edge (§5.1).** B removes 1.5 of pb's 6.0
where A removes 3.0, because A attacks the serialization and B attacks one stage group. Past A+B the
datapath stops being the binding term entirely: quiet's 8.54 ms fabric is `texwait` 3.42 + `ovhd`
2.29 + dpath 2.83, i.e. **67 % of the frame is the two terms Phase 3 declared out of scope** — and
per the bullet above, that `texwait` term is precisely the one A+B puts at risk.

### 5.3 How the candidates compose with the cull, and the recommended ordering

**They multiply.** The cull cuts the **pixel count** (covered_px, the multiplier); candidates A and
B cut **cycles per pixel** (the rate). Frame dpath ≈ covered_px × cyc/px × the calibration ratio,
so a 64 %-realized arrival cull (−117,297 px) on top of candidate A (2.929 device cyc/px) leaves
**3.82 ms** of dpath — not the 7.30 − 6.81 = 0.49 ms a naive subtraction of the two lever deltas
would give. Two consequences worth stating:

* **The cull's ms value shrinks as cyc/px falls.** At today's 5.737 device cyc/px the arrival cull
  ceiling is 10.68 ms; after candidate A it is 2.929 cyc/px and the *same* 183,276 cullable pixels
  are worth **5.45 ms**. Funding the cull first therefore buys the most ms — and funding it *after*
  the RTL levers buys about half as much.
* **The cull is the only lever that attacks overdraw** (2.94 quiet / 3.95 arrival), which is a
  host-submission property. If a future scene submits more overdraw, A and B do not help with the
  extra; the cull does. That is its durable value, not its current ms.

**Recommended ordering, with rationale:**

| # | item | why here |
|---|---|---|
| **0** | **Real-cache `texwait` measurement** (Task 5 follow-up #1) | Offline, no Quartus, decides a 3.35 ms uncertainty that currently determines whether Stage B delivers 60 fps or 55. Cheapest decisive check in the phase. |
| **1** | **Stage B build: span walk + A-chain pipeline + riders** | Already implemented, sim-gated, bit-exact. Both levers are pure wins on both scenes and nothing later invalidates them. Riders: scanout-period counter, STA hygiene. |
| **2** | **Candidate A — pb pipelining** | Largest single remaining **RTL** lever (−3.0 of pb's 6.0 cyc/px). Makes the quiet gate `texwait`-independent (band-robust, 3.05 ms clear) and brings arrival to the edge of its gate (14.80 ms, band-inconclusive). Same transformation just proven on pa, so the design risk is characterised. Co-requisite: raise `TEXFIFO_D` (§5.2 lead bullet). |
| **3** | **Opaque cull / CLEAR removal** (Phase 4, scene-side) | Only lever that reduces overdraw, and the only one big enough to give arrival real margin rather than edge-of-band. Start with the **CLEAR** — 100 % cullable, ≥0.80 ms, no per-pixel occlusion state needed. The general per-triangle cull is a host↔fabric contract change and should be funded on its own evidence, after (2) re-sizes it. |
| **4** | **Candidate B — 2-px/cyc blend** | Lowest value/risk ratio: alone it misses arrival, after (2) the frame is already `texwait`+`ovhd`-dominated so B's ~2.6 ms of dpath buys little, and it is the change that shrinks the prefetch lead furthest. Hold until a scene is measured that needs it. |

**Why the contract lever is not first, despite its ceiling being the larger number.** The cull ceiling
exceeds candidate A's saving on both scenes (quiet 7.08 vs 5.27 ms; arrival 10.68 vs 7.01 ms), so this
is *not* an argument from size — §1.1 states the same correction. The ordering is:

* **Candidate A's number needs no realization fraction**; the cull's needs 64 % on arrival, against an
  idealized model (perfect per-pixel occlusion, zero cull cost) whose cheap subset is only whole-draw
  and whole-triangle culls.
* **Candidate A is RTL-internal** — no host↔fabric protocol change, no engine/RBF deploy coupling, and
  it reuses a template just proven on pa.
* **The A4 escalation is for exhausted RTL levers**, and pb's 6.000 cyc/px says they are not (§1.1).
* **Sequencing cost is asymmetric:** doing the cull first preserves its full 10.68 ms, doing it second
  halves it — but doing candidate A first costs the cull nothing that the cull's own uncertainty does
  not already dominate, and it de-risks the *quiet* gate, which is Phase 3's actual deliverable.

---

## 6. Calibration provenance

Calibration lives in **`.superpowers/sdd/task-5-report.md` §4**. Device truth: quiet gameplay on
`.62`, fabric `frame` = **19.30 ms** (1,899,844 cyc @ 98.4375 MHz), `texwait` = **3.42 ms**
(336,656 cyc), non-texwait = 1,563,188 cyc = **15.88 ms**, `ovhd` = 2.29 ms, `dpath` = 13.59 ms.

| quantity | sim (quiet f0, baseline) | device | Δ |
|---|---|---|---|
| frame / `total` | 1,561,088 cyc = 15.859 ms | 1,899,844 cyc = 19.30 ms | **−17.8 %** |
| `texwait` | 71,345 cyc = 0.725 ms | 336,656 cyc = 3.42 ms | **−79.2 %** (device is 4.7× the sim floor) |
| frame **excluding** `texwait` | 1,489,743 cyc = 15.134 ms | 1,563,188 cyc = 15.88 ms | **−4.7 %** (offset +73,445 cyc) |

**The band to carry on every prediction:**

1. **Non-texel cycles: ±5 %** (measured −4.7 % low). Datapath predictions — span walk, occupancy,
   cull, candidates A and B — may be quoted from sim with this band. On quiet's post-pipeline
   non-texwait that is **±0.54 ms** (multiplicative, 13.02 ms) or **±0.64 ms** (additive, 12.87 ms),
   either of which is **larger than the margin the conservative prediction has against any gate**
   — 0.39 ms against the 16.67 ms *period* budget, and a negative margin against the 15.0 ms fabric
   gate. That is why §1.1 does not claim quiet lands. **Two candidate rows in §5 also sit inside this
   band relative to their gate** (candidate A on arrival), and are labelled band-inconclusive rather
   than passing.
2. **`texwait` is a FLOOR, not an estimate.** The mechanism: sim's `P_SRC` is a fixed 3-cycle stub
   (`P_SRC_LAT = 3`); a device miss goes through `sdram_fb_cache` + mt48 at **~12 cycles**, and the
   single-outstanding `P_SRC` channel also queues behind f2h arbitration, which the stub does not
   model at all. **Any change that alters texel access timing or locality must be re-measured, never
   scaled from this bench.** The A-chain pipeline is exactly such a change — it multiplies the
   prefetch lead by ~8× — so its 98.1 % sim `texwait` collapse is reported as a **direction with an
   unquantified magnitude**, and every prediction here is quoted twice: fixed-`texwait`
   (conservative, the prediction) and zero-`texwait` (ceiling).
3. **Budget in device ms, not sim ms.** The sim frame was 15.86 ms while the device frame was
   19.30 ms; a change that looks under budget in sim can miss on device by the `texwait` delta
   alone.

**No tuning was applied.** The DDR/`P_SRC` latencies are the sibling benches' values, unchanged —
the −4.7 % agreement is a result, not a fit.

### 6.1 Where the −4.7 % actually lives (matters for extrapolation)

The net −4.7 % is two larger errors partly cancelling, and this is not visible in the headline:

| term | sim | device | Δ |
|---|---|---|---|
| `dpath` (`tri` − `texwait`) | 1,411,469 cyc = 14.34 ms | 1,337,766 cyc = 13.59 ms | sim **+5.5 % HIGH** |
| overhead (`nontri` / `ovhd`) | 78,274 cyc = 0.795 ms | 225,422 cyc = 2.29 ms | sim **−65 % LOW** |

Consequence: **the additive-offset form (`sim + 73,445 cyc`) treats a term that is 5.5 % high and a
term that is 65 % low as one fixed adder.** That is fine at the measured point and increasingly
wrong as the datapath shrinks — by candidate A's 5.46 ms dpath, the fixed 2.29 ms `ovhd` is 42 % of
the datapath term it is being added to. All §5 sizing therefore uses the **multiplicative dpath
ratio** plus *measured* `texwait` and `ovhd` as separate terms, which is the form that
extrapolates. The §2 table gives both forms so the two prior reports' numbers remain locatable.

**The two dpath ratios, with the own-denominator step shown** — each side divides by *its own*
covered-pixel count (§7.4), so the ratio is a cyc/px ratio and not a cycle-count ratio:

| | device dpath | ÷ device covered_px | sim dpath | ÷ sim covered_px | ratio |
|---|---|---|---|---|---|
| quiet | 13.59 ms = 1,337,766 cyc | ÷ **182,661** = 7.3237 cyc/px | 1,411,469 cyc | ÷ **182,661** = 7.7273 cyc/px | **0.94778** |
| arrival | 18.0 ms = 1,771,875 cyc | ÷ **245,346** = 7.2219 cyc/px | 1,882,700 cyc | ÷ **245,530** = 7.6679 cyc/px | **0.94184** |

Quiet's two denominators are the same number (182,661 exactly, §3) so its ratio is unaffected by the
choice. Arrival's differ by 184 px (0.075 %): the device figure is from the Phase 2 run that reported
245,346, the sim figure is the replayed frame 3 at 245,530. Collapsing to a common denominator makes
the ratio a plain cycle ratio, `1,771,875 / 1,882,700 = 0.94114` (−0.075 %), which moves arrival's
post-pipeline frame from **21.81 to 21.80 ms** — worth 0.01 ms, i.e. ~70× smaller than the ±0.72 ms
band. Recorded because a ratio built from two different denominators looks like an error unless the
size of it is stated. Self-check: applying the own-denominator ratio back to the *baseline* sim dpath
returns 18.01 ms against the measured 18.0, as it must.

---

## 7. Discrepancies between the task reports (flagged, not smoothed)

### 7.1 Task 7's "16.67 ms budget" is the **period** budget, not the fabric budget

Task 7 §5.2/§5.4 compares fabric ms against **16.67 ms** and reports fps as `1000 / fabric`. That
omits the ~1.7 ms exposed host tail Phase 2 measured, so its fps figures are **fabric-implied, not
delivered**: quiet's 16.28 ms reads "60.5 fps" in Task 7 and is **55.6 fps delivered**
(period 17.98 ms). Phase 2's re-gate is explicit — *"period ≈ fabric + ~1.7, so 60 fps now needs
fabric ≤ 15.0 ms"*. **This memo uses ≤ 15.0 hard (Phase 2's re-gate) / ≤ 14.5 design (the Stage A
plan's budget) throughout, and quotes period separately.** The direction of the correction makes every verdict in this memo *stricter* than
Task 7's, not looser: quiet misses the fabric gate by 1.28 ms where Task 7 read it as clearing by
0.39 ms.

### 7.2 Task 7's "no device frame counter published for the arrival scene" is wrong

Task 7 §5.2 labels its arrival `texwait` row *inferred* on the grounds that no arrival device
counter exists. **There are two.** The Phase 2 baseline publishes the Chapter I arrival row —
`frame 25.5 / tri 23.2 / texwait 5.2 / dpath 18.0 / covered 245,346 / overdraw 3.94`, reproducible
across four independent runs — and Task 3 §4's calibration run re-measured it
(`frame=25.52 / cov_px=245,492`, adjacent window `25.86 / 248,427`).

Two consequences:

* Task 7's *inferred* pessimistic row (`texwait` scaled by the sim ratio 1.5035× → **5.14 ms**)
  is within 1.2 % of the **measured 5.2 ms**. So that row is not a bound to be shown for range —
  it is effectively **the measurement**, and it is therefore the arrival prediction. Arrival's
  conservative fabric figure is **21.6 – 22.0 ms**, not the 20.18 ms Task 7 headlined (which
  assumed quiet's 3.42 ms).
* Arrival can be calibrated against **its own** device anchor instead of quiet's offset:
  device non-texwait 25.5 − 5.2 = 20.3 ms vs sim 19.94 ms → offset **+35,111 cyc (+0.36 ms, −1.8 %
  low)**, less than half quiet's +73,445.

### 7.3 The arrival non-texwait claim is calibration-dependent

Task 7 states arrival "misses 60 fps under every assumption" because **16.76 ms of non-texwait work
exceeds a 16.67 ms budget**. That specific inequality holds only under the quiet-derived additive
offset. Under arrival's own anchor (§7.2) the non-texwait term is **16.37 ms** — *under* 16.67.

**The conclusion survives; the argument for it does not.** Against the correct fabric gate
(≤ 15.0, §7.1) arrival's non-texwait term misses by **1.37 – 1.76 ms** under *both* calibrations,
so arrival still cannot be fixed by any amount of pa or texel-latency work and still needs a
pixel-count or cyc/px lever. The memo's arrival verdict rests on that, not on the 16.76 vs 16.67
comparison.

### 7.4 Minor: covered_px spread and cyc/px denominators

Arrival covered_px is quoted as 245,346 (Phase 2), 245,484 (analyzer median), 245,492 ± 8
(Task 3 device) and 245,530 (sim f3) in different places — a ±0.08 % spread from transient sampling
(§3). Ratios in this memo use each source's own denominator and are annotated; the cull ceiling
uses the analyzer's 245,484 because `cullable_px` comes from the same pass.

---

## 8. Secondary findings

### 8.1 Redundant full-screen CLEAR — 0.795 ms/frame

`nontri` = 78,274 cyc (baseline) / 78,314 cyc (post-pipeline) = **0.795 – 0.796 ms**, 5.0 % of the
sim frame, **untouched by both Stage A levers**. It is dominated by the full-screen CLEAR fill
(62,208 px at ~1 px/cyc) plus the 107-command ring fetch and the perf publish tail. The captured
stream's opaque draws **already repaint the whole screen** — COPY covers 125,568 px over 62,208
unique — so the CLEAR is a **100 % cullable draw** by the §4 rule and is the one piece of the cull
ceiling realizable without per-pixel occlusion state. It needs a host-side guarantee that the
frame's opaque draws cover the screen, so it is a small contract change, not a pure RTL one.
(Device `ovhd` is 2.29 ms, of which sim accounts for 0.80 — see §6.1 — so the device CLEAR may be
larger than 0.80 ms; measure before sizing.)

### 8.2 `TEXFIFO_D = 16` is now safe, and is a live performance knob

`TEXFIFO_D` sets the prefetch **lead** directly (8 px ≈ 48 cyc at pb's retire rate), which is the
mechanism behind the 76 % → 99.8 % hit-rate change. Before `d4c346b`, `reg [3:0] ax_cred` was
correct at 8 and **silently wrong at 16** — the `ax_room` compare becomes a tautology, the
dispatcher never throttles, and the credit scheme was the justification for deleting the
`if (!pf_full)` guard, so nothing downstream would have caught the overrun. Now
`AX_CW = $clog2(TEXFIFO_D+1)` derives the width, an elaboration-time guard (`FAIL 3B-CREDW`)
catches a hand-override, and **`TEXFIFO_D = 16` was negative-tested green** on synthquad and
spanedge (with only `TEXFIFO_AW` co-changed). Worth one sweep once §8.3 can measure the effect;
left at 8 for now. Three things co-move and are named at the issue stage: `TEXFIFO_D`/`TEXFIFO_AW`,
the `ax_room` bound, and `ax_cred`'s width.

**It stops being optional if either candidate lands.** The lead is `TEXFIFO_D` × pb's retire
interval, so cutting that interval cuts the lead: 8 × 6 = 48 cyc today, 8 × 3 = **24 cyc after
candidate A**, 8 × 1.5 = **12 cyc after A+B** — against a ~12-cycle device miss. Raising `TEXFIFO_D`
is therefore a **co-requisite** of candidates A and B, not a separate experiment (§5.2).

### 8.3 Real-cache `texwait` sim path — now load-bearing

Re-point `tb_blitter_trilist_stream`'s `p0_*` at `sdram_fb_cache` + mt48, which
`tb_blitter_trilist_sdram` already co-simulates. ~10× runtime → nightly/NONGATING. Per §1.1 this is
no longer a nice-to-have follow-up: it is the measurement that decides the A4 outcome and it costs
no Quartus cycle.

### 8.4 Off-screen-triangle walk defect — already FIXED

`tri_maxx_cl`/`tri_maxy_cl` raised a negative bbox-max to 0, so `S_TRI_SWAIT`'s
`(ts_ox > tri_maxx)` guard did not fire and **12 fully-off-left/above triangles per frame** were
walked as a degenerate 1-column strip (1,160 cyc = 0.012 ms). Fixed in Task 6 via a registered
`tri_bbox_neg` reject — folded in deliberately, because under the span walk an empty row costs a
seek *plus* a row step (~2 cyc) where the bbox scan paid 1, so leaving it would have **doubled**
the waste. Bit-exact: zero covered pixels either way. This also explains the +1,160 (+0.31 %)
`pix_visits`-vs-analyzer-`bbox_px` gap in Task 5 §3.3 — a real cull-convention difference between
refmodel and RTL, not analyzer error.

---

## 9. Watch items carried into Stage B

### 9.1 Device: intermittent frame-1 fabric wedge — **live on `cd4d9f1`**

Signature: `MFSUBMIT … fabric_ms[frame=0.00 …] cov_px=0 … to=30` (every submit timing out),
`backend_mfgpu: fabric submit timeout (pending=1 emitter=2 done=0 status=0 waited=200ms)` from the
**first** submit, `wait_ms ≈ 204`, 910-byte blank screenshots; DDR3 `0x3B000000` (C_SUBMIT)
climbing, `0x3B000028` (C_DONE) = 0, `0x3B000030` (STATUS) = 0.

* **Rate: ~1 in 2 core loads** during the Task 3 session (two consecutive 170 s runs contaminated
  and discarded; two 35 s probes immediately after → 1 wedged, 1 clean).
* **A retry clears it. A reboot does NOT** — `.62` was rebooted and the next run wedged again.
* **Every device measurement must gate on `grep -c 'submit timeout' == 0`** before its data is
  used. `mister_run.sh` does **not** check this itself — it asserts sole-engine but has no
  submit-timeout gate. **Adding that gate is a Stage B prerequisite**, same class as the
  sole-engine assertion; without it a wedged run's zeros can silently enter a comparison.
* `0x3B0000xx` is **DDR3, not FPGA registers** — those words survive a reboot, so reading them
  with no engine running is stale data, not live state.

### 9.2 Build obligations from Task 7 §8.1 — order matters

**No Quartus build has been made on any Phase 3 RTL.** Run in this order, and check inference
**before** reading slack:

1. **`grep 276007 *.map.rpt`** — the `tq_data`/`tq_tag` read block was deliberately not touched
   (still its own unconditional `always @(posedge clk)`), so this should stay clean. If it does not,
   the cause is elsewhere in the Phase 3 change. Rule that produced this gate: a `ramstyle` array's
   read must **never** be nested in an FSM case arm — last violation cost 20,480 stray flops and a
   1,735-fanout 256:1 mux.
2. **Confirm DSP packing under the new `ax_v[k]` enables** — the twelve `pp_*` multiplies and
   `tex_row` must still pack as input+output-registered DSPs now that their enable is a 1-bit
   `ax_v[k]` rather than a 4-bit `case(pa)` compare. An unpacked 48×24 puts ~8.9 ns of
   combinational multiply back on the fabric clock and would present as a mysterious timing
   regression.
3. **Then the new control paths:** `ax_room`'s 4-bit compare, `ax_busy`'s 6-input OR, `ax_cred`'s
   ±1 adder, `ax_disp` into `A_PIX`'s branch; plus Task 6's widened pa decode, the three 64-bit
   `w*m` subtracts in `step_left`, and `sk_need_r`/`sk_need_l`/`sk_block`. All are adder/compare
   depth, so **`modch`'s blend path is predicted to remain critical** — a prediction, not a
   measurement. Note the standing rig-specific caveats: SDRAM_CLK phase is board-specific and STA
   is blind to it (multicycled), so probe-pass ≠ game-stable.
4. **`TEXFIFO_D = 16`** if §8.3 justifies it — costs ~600 flops, and per §8.2 raising it is now safe.

### 9.3 Gates that must keep running

* **`ax_push == pix_covered`** (the pipeline-conservation cross-check). This is the **only** gate in
  the suite that caught mutation M6 — dropping `!ax_busy` from the triangle-drain test loses one
  real pixel in 182,661, and the **golden framebuffer diff PASSED it** (`bad pixels = 0 / 62208`,
  and all nine fast trilist benches passed) because the dropped pixel was colour-keyed out or later
  overpainted. Task 6's gate set would have shipped this. Any future re-timing of pa's tail or of
  the drain condition must be re-mutation-checked against it specifically.
* The two `` `ifndef SYNTHESIS `` credit assertions (`FAIL 3B-PFFULL`, `FAIL 3B-CRED0`) and the
  elaboration guard `FAIL 3B-CREDW`.
* Suite baseline to hold: **`passed=54 gating-failures=0 non-gating-failures=0 skipped=1
  deferred=1`**, with strict bit-exactness (`exact_bad=0`) on all five replays and the
  synthquad/spanedge hand-count anchors unchanged.

### 9.4 Diagnostics and reproducibility caveats

* **`SOLARUS_DBG_PROBES` word-A layout changed in Task 6** (`pa` is now `[9:6]`, `pb` `[13:10]`,
  fill `[14]`, fbdma `[15]`) — tooling that decodes by bit position needs the new layout. Task 7
  additionally left `pa` encodings **1..6 as a documented hole** rather than renumbering, so an old
  dump reading 1..6 still means "somewhere in the mul/addr chain".
* **`ax_live` is an OR** — per-stage pa occupancy is no longer observable; the informative pair is
  `ax_live` + `pa_hold`. If a future change lets the stages advance independently, per-bit counts
  must come back.
* **`stream_arrival_f3` vectors are gitignored** — arrival numbers are not reproducible from a
  fresh clone without regenerating them, and regeneration depends on `TRACEDIR` pointing at the
  sibling `mister-gmloader` checkout (a working path, not a recorded pin). Quiet f0, synthquad and
  spanedge have no such caveat.
* **Arrival capture placement drifts ±30 frames** — re-confirm against the run's own `MFSUBMIT`
  windows, never reuse `START=2465` blind.
* **`deploy.py` engine provenance** is hardcoded to the sibling `../gmloader-next` for its commit
  label, freshness gate and `gmloader.json` source, ignoring the checkout `--engine` came from
  (Task 3 labelled the binary `a3688a0` when it was `b775007`; `gmloader.json` diffed identical, so
  no functional impact that run).

---

## 10. Stage B scope, as decided

**Provenance of this scope:** it is a **ratified deviation from A4 as written** — A4 (spec:79-82)
instructs "add the opaque-cull contract lever to Stage B scope now" once RTL levers land short, and
they did. The user ratified holding the cull out on **2026-07-30**; §1.1 carries the clause text and
the four-point rationale. Anyone comparing this scope against the spec should read §1.1 first.

**In scope (already implemented on `perf/60fps-phase3`, sim-gated, bit-exact):**

1. **Span walk** — `9414bba` + `b651c9b`, including the off-screen-triangle reject (§8.4).
2. **A-chain pipeline** — `c28c38f` + `d4c346b`, including the derived `AX_CW` fix.

**In scope (riders, so the Quartus cycle isn't spent alone):**

3. **Scanout-period counter** — Phase 2 open question 4: C_DONE counts fabric completions, not
   scanout, and no per-scanout counter is exposed to the host.
4. **STA hygiene** — §9.2's ordered checks (276007 inference gate, DSP packing, tint-path slack).
5. **Bench submit-timeout gate** in `mister_run.sh` (§9.1) — a measurement-integrity prerequisite,
   not an optional cleanup.

**Prerequisite, before the build (offline, no Quartus):**

6. **Real-cache `texwait` measurement** (§8.3). **Operational trigger, multiplicative form (§6.1):
   if measured device-representative `texwait` > 1.98 ms — i.e. < 42.2 % recovery of the 3.42 ms —
   prototype candidate A before spending the Quartus cycle.** Thresholds, so the decision needs no
   re-derivation at the bench:

   | measured `texwait` | recovery | quiet fabric | verdict |
   |---|---|---|---|
   | ≤ 1.48 ms | ≥ 56.8 % | ≤ 14.5 | clears the **design** gate — build as-is |
   | 1.48 – 1.98 ms | 42.2 – 56.8 % | 14.5 – 15.0 | clears the **hard** gate only — build as-is, no margin |
   | **> 1.98 ms** | **< 42.2 %** | **> 15.0** | **misses — prototype candidate A first** |

   (Additive-form equivalents, for continuity with Tasks 6–7: 1.63 ms / 2.13 ms, 52.2 % / 37.6 %.
   The multiplicative numbers are the operative ones — the additive form is deprecated for
   extrapolation by §6.1 and is the more permissive of the two, so using it would under-trigger.)
   Note the band: at the +5 % end the hard-gate threshold tightens to 1.44 ms (57.9 % recovery), so a
   measurement landing in 1.44 – 1.98 ms is itself band-inconclusive and should be treated as a
   trigger.

**NOT in Stage B:**

* **Opaque-cull contract lever** → Phase 4, as the arrival scene's lever (§4). **The A4 trigger fired
  and A4 as written says "add the opaque-cull contract lever to Stage B scope now" (spec:79-82), so
  keeping it out is a DEVIATION — RATIFIED by the user on 2026-07-30** (§1.1). Re-size it after candidate A —
  which halves its value (§5.3).
* **Candidates A and B** → sized here on paper only (§5); neither is prototyped, neither has sim
  or STA evidence, and candidate A's arrival row is band-inconclusive. Candidate A is the recommended
  next RTL lever, with a raised `TEXFIFO_D` as its co-requisite (§5.2).
* `texwait` and `ovhd` levers, the remaining ~1.7 ms host tail, and the frame-limiter defect
  (measured zero-cost) — all out of scope per the spec.

**Expected Stage B outcome, stated as a range rather than a number:** quiet fabric
**12.93 – 16.44 ms** (period 14.63 – 18.14 ms, **68.4 – 55.1 fps**), arrival fabric
**21.6 – 22.0 ms** (~42 – 43 fps, extrapolated host tail). Whether the quiet build delivers 60 fps is
decided by item 6, not by anything else in the list.

---

## 11. Stage B Task 1 update — measurement appended 2026-07-30

**This section reports data collected AFTER this memo's Stage A analysis (§1–§10 above) was
written. It is item 6's prerequisite (§10) coming back with an answer; §1–§10 are left as the
Stage A record, not rewritten.** Full detail, harness, and error bars:
`.superpowers/sdd/stageB-task-1-report.md` (`wt-maldita-60fps-p3` commit `79273f5`, parent
`25c813a` — the same post-lever RTL this memo sizes).

### 11.1 The §10 item-6 trigger fired

Real-cache `texwait` — measured with `tb_blitter_trilist_streamcache` (`sdram_fb_cache` +
`mt48lc16m16a2` in place of the fixed-3-cycle `P_SRC` stub) — is:

| | measured `texwait` | recovery of the pre-lever value | §10 threshold | verdict |
|---|---|---|---|---|
| quiet (pre-lever 3.42 ms) | **2.437 ms** | **28.2 %** | ≥ 42.2 % hard / ≥ 56.8 % design | **misses both** |
| arrival (pre-lever 5.2 ms) | **3.749 ms** | ~27–28 % (report §4.3: 27.5 %) | — (no separately-thresholded gate) | same recovery fraction as quiet — a property of the lever, not one scene |

**Trigger fires. Per §10 item 6 and §1.1's ratified scope: prototype candidate A before
spending the Quartus cycle.**

### 11.2 §6.1's 0.94778 ratio is a stub artifact — corrected non-`texwait` and thresholds

On the real texel path, sim `dpath` matches device `dpath` directly (+0.03 % quiet, +0.08 %
arrival) — the 0.94778 (quiet) / 0.94184 (arrival) multiplicative correction in §6.1 was
compensating for the *stub's* `texwait` bucket being 4.7× too small (so ~73 k cycles the
device charges to `B_WAIT` were charged to `dpath` in the stub run), not a genuine sim/device
datapath gap. Applying it to real-cache data double-corrects.

* **Corrected non-`texwait`: 13.71 ms** (`dpath` 11.420 + `ovhd` 2.29), not §1/§10's 13.02 ms.
* **Restated §10 thresholds**, same 15.0 ms hard / 14.5 ms design gates:

  | gate | `texwait` ≤ | recovery of 3.42 ms |
  |---|---|---|
  | 15.0 ms (hard) | **1.29 ms** | **62.3 %** (was 1.98 ms / 42.2 %) |
  | 14.5 ms (design) | **0.79 ms** | **76.9 %** (was 1.48 ms / 56.8 %) |

  Both original thresholds were too permissive by the same stub-ratio error. The measured
  28.2 % recovery misses the corrected thresholds by a wider margin than it missed the
  originals.

### 11.3 Candidate A (§5.1) re-sized — the arrival row flips from clear to miss

§5.1's candidate-A `dpath` figures (5.46 ms quiet, 7.30 ms arrival) were built with the same
deprecated ratio, applied to candidate A's *own* `dpath`. The ratio's effect scales with the
`dpath` term it multiplies, and candidate A's `dpath` is about half the pre-lever figure, so
un-applying it does not shift both scenes by the same amount:

| scene | §5.1 `dpath` (ratio applied) | corrected `dpath` | §5.1 fabric | **corrected fabric** | vs gate |
|---|---|---|---|---|---|
| quiet | 5.46 ms | 5.46 / 0.94778 = **5.76 ms** | 11.17 ms | **11.47 ms** | clears the 14.5 ms design gate by 3.03 ms (was 3.3 ms) — still band-robust |
| arrival | 7.30 ms | 7.30 / 0.94184 = **7.75 ms** | 14.80 ms | **15.25 ms** | **MISSES the 15.0 ms hard gate by 0.25 ms — flips from a clear** |

**Consequence.** §5.1's read of candidate A on arrival — "brings arrival to the edge of its
gate... point estimate clears by 0.20 ms" — no longer holds: the point estimate now *misses*
by 0.25 ms. Quiet's verdict is unchanged (still clears, margin reduced from 3.3 to 3.03 ms).
Candidate A remains the recommended next RTL lever (§8's ranked list, item 2) — nothing sizes
larger on RTL-internal terms — but its paper sizing can no longer be read as closing arrival's
gate. It needs its own real-cache `texwait` measurement once prototyped: candidate A halves
`pb`'s retire rate, which shrinks the prefetch lead in wall-clock terms, so `texwait` cannot
be assumed to hold at 2.44 ms after it lands.

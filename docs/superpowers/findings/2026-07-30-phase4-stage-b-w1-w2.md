# Phase 4 Stage B W1+W2 — the redundant clear, decomposed on `.62`

**Date:** 2026-07-30
**Device:** `.62` (test unit). `.81` was never touched.
**Bitstream:** unchanged for the whole of W1+W2 (RTL untouched — verified per
task: `git status`/`git diff --stat` show zero files under `fpga/rtl/` in the
maldita worktree). Only the host engine changed.
**Instrument:** `MFSUBMIT` (`GMLOADER_MFSUBMIT_STAT=1`), `MFCLEAR`, `MFTRACE`
(`GMLOADER_MFGPU_TRACE`), `mftrace_analyze.py`, the real-cache stream-replay
bench (`tb_blitter_trilist_streamcache`).
**Design under test:** `docs/superpowers/specs/2026-07-30-phase4-stage-b-fabric-design.md`.
**Plan:** `docs/superpowers/plans/2026-07-30-phase4-stage-b-w1-w2.md`.

All fabric-time units are `_ms` at 98.4375 MHz unless stated. Scanout free-runs
at **16.6882 ms / 59.9228 Hz**; that figure is never rounded here. The Stage B
gate is `frame ≤ 16.13 ms`, derived as `16.6882 − notice(0.56) − pub(0.00)`
(plan, Global Constraints).

---

## 0. Headline conclusion

**W2 (the deferred full-screen clear) removed 1.33 ms from fabric `frame` at
all three measured anchors, purely on the host side, with the bitstream
frozen.**

- **Observed** (Task 5, exact-`cov_px`-matched A/B, `GMLOADER_MFGPU_DEFER_CLEAR=0`
  vs `=1`):

  | point | pre-W2 `frame` | post-W2 `frame` | Δ | vs 16.13 fabric gate |
  |---|---|---|---|---|
  | quiet | 16.20 | **14.87** | −1.33 | clears by 1.26 (fabric term only — see below) |
  | heavy-B | 18.02 | **16.68** | −1.34 | short by 0.55 |
  | arrival | 21.37 | **20.04** | −1.33 | short by 3.91 |

  `tri`, `dpath`, `texwait`, and `cov_px` are bit-identical between arms at every
  point — the entire delta lands in `ovhd`. No bitstream change was involved.
- **Observed, end-to-end** (`MFSEAM period=` lines, the two quiet-scene A/B
  logs `w2-baseline-defer0-ingame-stage1.log` /
  `w2-lever-defer1-ingame-stage1.log`, all windows in each log):

  | arm | windows | mean period | rate | windows exceeding 16.6882 ms |
  |---|---|---|---|---|
  | baseline `defer=0` | 190 | 17.119 ms | 58.42 Hz | 152 (80%) |
  | lever `defer=1` | 188 | 16.982 ms | 58.89 Hz | 127 (68%) |

  This is the only measurement of delivered display rate anywhere in this
  corpus. **W2's end-to-end gain on quiet is 58.42 → 58.89 Hz — not a lock.**
  Two thirds of windows on the lever arm still miss the 16.6882 ms scanout
  period.
- **Inferred, scoped to the fabric term only — this is NOT a measured display
  rate.** The earlier framing of this result ("the quiet scene now locks the
  pre-existing `.62` bitstream to 59.9228 Hz") over-read the fabric-gate table
  above: `frame` alone (14.87 ms) clears the 16.13 ms fabric gate by 1.26 ms,
  which says the fabric processing budget fits inside its allotted share of
  the scanout period. It does not say, and was never measured to say, that the
  delivered frame rate reaches 59.9228 Hz — the `MFSEAM` table immediately
  above shows it does not (58.89 Hz, 68% of windows still over period). The
  only `59.9228` figure in this corpus is the engine's own
  `frame-cap: scanout period ... (59.9228 Hz)` startup banner, a configuration
  constant, not a measurement.
- **Observed.** On quiet, the lever-arm `MFSEAM host=` mean is **15.72 ms**
  against a fabric `frame` of **14.87 ms**. **The host body, not the fabric,
  is now the binding term on the quiet scene.** This bears directly on the
  value of an RTL datapath lever there: W3 (pb-datapath pipelining) only moves
  the fabric term, and the fabric term is no longer what stands between quiet
  and a lock — the host body is. Heavy-B (fabric 16.68 vs the 16.13 gate,
  short 0.55) and arrival (fabric 20.04 vs 16.13, short 3.91) remain
  fabric-bound, so this does not undercut W3's case on those scenes.
- **Inferred.** The prediction that motivated W2 (~0.63 ms) missed the measured
  delta (1.33 ms) by ~2.1×. The cause is diagnosed in §2: the build issues
  ~3 full-extent clears per engine frame, not 1.
- **Inferred, resolving a standing Unknown.** The 1.53 ms of device `ovhd` left
  unattributed after Phase 3/Stage A is **not** DDR3 single-beat burst latency,
  the leading suspect named in the option register. §3 shows 87% of that gap
  was the extra clears; the true residual against the calibration sim is
  0.184 ms.
- **Action, by user decision 2026-07-30.** W3 (pb-datapath pipelining) is
  **funded**, judged on the `dpath` calibration term (−0.03%), not the plan's
  literal total-error gate (±0.7%), which the calibration run **fails** at
  −1.27%. §4 records both the literal failure and the decision.

**The 1.33 ms fabric saving above is unaffected by this correction** — it is
directly measured, matched at 4,716+504 `cov_px`-identical pairs (§1), and
remains the real result of W2. What is corrected is only the claim about what
that saving delivers end-to-end on the quiet scene.

---

## 1. The §0 correction — confirmed on device

The Stage B design's §0 (and, before it, the Stage A seam document's §8)
corrected a location claim: the redundant full-screen clear is **not** the RTL
control-block path (`blitter_top.sv:1322-1353`, `S_GOT_CLEAR` → `S_CLR_FILL`).
That path's sole gate is `blt_begin_frame(&g_e, 0, /*clear=*/0, 0)` at
`raster_backend_mfgpu.cpp:1390` — `clear` is hard-zero in the only production
call site, so `S_CLR_FILL` is never entered on device. The real clear is the
game's own `glClear`, reaching `mf_clear()` and emitted as an ordinary ring
`BLT_OP_FILL` (`raster_backend_mfgpu.cpp:1426`), which dispatches through
`comp_pipeline`, not the `S_TRI_*` states counted by `tri` — so its cost sits
inside `ovhd = frame − tri`.

**Task 5's device A/B confirms this exactly.** Deferring/dropping the ring
`BLT_OP_FILL` (`GMLOADER_MFGPU_DEFER_CLEAR=1`) moves `ovhd` down by 1.33 ms at
every anchor while `tri`, `dpath`, `texwait`, and `cov_px` stay bit-identical.
If the clear had instead lived in the RTL control-block path, deferring a
*host*-side emission would have changed nothing on device — it didn't; it
moved exactly the term the correction said it would. The reviewer's broader
pass (not just the 3-point table) matched 4,716 (quiet/heavy-B scene) + 504
(arrival scene) `cov_px`-identical pairs under strict `tri`/`dpath`/`texwait`
identity and found the same ~1.33 ms median in both, stdev 0.02–0.05 in steady
state — the headline is the dataset's central tendency, not a cherry-picked
sample.

---

## 2. The magnitude miss, and why

**The prediction missed in magnitude, not location.** The design's estimate
was one full-extent `mf_clear()` per engine frame: 62,208 px at ~1 px/cyc ≈
**0.632 ms**. The measured delta is **1.33 ms** — about **2.1×** larger.

**Observed** (`MFCLEAR` counters, lever arm, both scene scripts, sampled at
multiple 300-frame intervals from frames=300 through frames=11700):
`(clears_dropped + clears_emitted) / frames` is a **hard 3.00 invariant** —
not an average that happens to land near 3, but a value that holds at every
sampled interval in both `ingame-stage1` and `ingame-stage1-busy`. The build
issues **~3 full-extent clears per engine frame**, not 1.

At steady state the split is **~2 dropped + 1 emitted per frame** (~74%
dropped, ~26% still emitted because not every clear is provably covered by a
following draw). That gives a reconciliation of:

```
2 dropped/frame x 0.632 ms/clear = 1.264 ms predicted
measured                          = 1.33  ms
unreconciled                      = ~0.07 ms
```

**This is a partial reconciliation, not a clean one.** 1.264 ms accounts for
the great majority of the 1.33 ms measured delta, but ~0.07 ms is not
explained by the dropped-clear count alone. No further attribution was
attempted this phase.

---

## 3. The 1.53 ms `ovhd` residual — solved, and it is not DDR3

Phase 3 / Stage A left `ovhd` (device 2.32 on the heavy scene) 1.53 ms above
the sim's `nontri` term (0.795, from Phase 3's sim baseline) with no
attribution. The option register named single-beat DDR3 bursts
(`mem_burstcnt = 8'd1`) as the leading suspect, sized against a platform
figure that did not arithmetically close (would require ~390 cycles per round
trip against a ~20-cycle platform figure).

**Measured resolution, using Task 7's real-cache calibration run** (the same
run used for the W3 decision in §4, `STREAM_VEC=stream_heavy_f0`,
`tb_blitter_trilist_streamcache`, `exact_bad = 0/62208`):

```
sim nontri (Phase 3 baseline)     0.795
device ovhd, pre-W2               2.32     gap = 1.53
W2 removes                        1.33  ->  device ovhd, post-W2 = 0.97 (Task 7)
sim nontri (Task 7 calibration)   0.786
residual, post-W2 device vs sim   0.97 - 0.786 = 0.184
```

**87% of the original 1.53 ms gap was the two extra full-screen clears per
frame that W2 removes.** The DDR3-single-beat-burst theory is **defunded** as
the leading `ovhd` suspect — what is left to explain is 0.184 ms, not 1.53 ms,
and W3's proposed "`ovhd` attribution counter" rider drops sharply in value as
a result. The reviewer's steady-state split (§2, ~1.0 clear/frame surviving to
emission after defer) also confirms the sim's own one-synthesized-clear model
(§7) is now counting the *same* number of clears as the device emits, so the
0.184 ms residual is unmodelled ring-fetch/DDR latency, not a clear-count
artifact.

**A note on precision.** Task 5's own A/B table (measured directly, not via
the calibration run) reports post-W2 heavy-B `ovhd` as **0.97**, and its quiet
row as **0.99**; Task 7's calibration run — a separate device session run
specifically against the heavy-B sim vector — reads **0.97** for the same
quantity. The two agree at heavy-B; the discrepancy is only that Task 5's
early quiet-scene figure (0.99) is not the number used in the calibration
above, which is heavy-B-specific throughout. See "Data-trust" §7 for the
general caution about cross-session `ovhd`/`frame` figures agreeing to
~0.01–0.02 ms but not exactly.

---

## 4. Calibration and the W3 decision

**Task 7 real-cache calibration** (`STREAM_VEC=stream_heavy_f0`,
`tb_blitter_trilist_streamcache`, 168.7 s, bit-exact `0/62208` bad pixels,
`pix_covered=213358` == device):

| term | sim | device (post-W2 heavy-B) | error |
|---|---|---|---|
| `dpath` | — | 13.31 | **−0.03%** |
| `tri` | 15.682 | 15.72 | **−0.24%** |
| `texwait` | 2.376 | 2.41 | **−1.4%** |
| `ovhd` | 0.786 | 0.97 | **−0.184 ms** |
| **total** | 16.468 | 16.68 | **−1.27%** |

**The plan's literal gate (total within ±0.7%) FAILS at −1.27%.**

**User decision, 2026-07-30: W3 IS FUNDED anyway, judged on `dpath`
(−0.03%), not the −1.27% total.** Rationale recorded at the time: the gate's
purpose was to establish whether the bench can *size* Candidate A (the
pb-datapath rewrite) before spending a Quartus cycle. Candidate A moves
`dpath` and nothing else; `dpath` calibrates to −0.03%, essentially exact. The
−1.27% total miss is entirely the fixed, per-frame `ovhd` offset resolved in
§3 (0.184 ms), which is independent of the datapath and now understood rather
than mysterious. This is recorded as a decision that overrides the plan's
literal text on a documented finding, not a silent pass — the calibration run
genuinely failed the stated gate.

W3's residual ask on heavy-B fell from **1.89 ms (pre-W2)** to **0.55 ms
(post-W2)** — Candidate A's paper size is ~4.7 ms, still well above the ask.

---

## 5. A reordering W3 must inherit

**Observed.** Post-W2, heavy-B's fabric `frame` is **16.68 ms**, essentially
at the scanout period of **16.6882 ms** — the fabric now *fits* the period on
this scene (16.68 < 16.6882). The 0.55 ms shortfall against the 16.13 ms gate
is not a fabric-capability gap; the gate itself embeds `notice` (0.56 ms) and
`pub` (0.00 ms), and on heavy-B those two terms are now essentially the whole
remaining distance.

**This overturns the Stage A design's lever ordering.** Stage A's §7/§8 (and
the Stage B design's carry-forward) ranked the `notice` lever (L2, ~0.56 ms)
**second** in priority behind any `cov_px` reduction, on the grounds that the
heavy scenes needed 0.52–1.33 ms off `frame` *before* a lock was even
arithmetically possible — `notice` alone could never close that gap. **They no
longer need it.** With W2 landed, `notice` is now competitive with — arguably
*the* — binding term standing between heavy-B and a lock.

---

## 6. Corpus and its limits

**3 of 4 anchor points captured and numerically gated at 0.00% deviation**
(`mftrace_analyze.py --expect-covered <n> --tol 2.0`, exit 0 on all three):

| point | scene | pre-W2 `frame` | `cov_px` | matches Phase 3 device exactly? |
|---|---|---|---|---|
| quiet | `ingame-stage1` | 16.20 | 182,661 | yes |
| heavy-B | `ingame-stage1` | 18.01–18.02 | 213,358 | (new anchor this phase; also present in Stage A's 200-tri window at the same `frame`/`cov_px`) |
| arrival | `ingame-stage1-busy` | 21.37 | 245,346 | yes |
| heavy-A | — | — | 195,084 | **not reproduced** |

**Heavy-A (195,084) was not reproduced** despite two dedicated attempts: a
150-frame bracket around the frame where the discovery run's coarse
30-frame-throttled sampling reported it once, and a 1,100-frame exhaustive
per-frame scan of the entire early-game region. Neither found any frame at
195,084; the closest was 189,428 (2.90% away, outside the 2% tolerance).

**This was stopped by judgment, with one `mister_run.sh bench` invocation
still held in reserve — not because the invocation budget was exhausted.**
(Task 2's own status line said "budget exhausted (8/8)"; its own invocation
table shows 7 of 8 used, with the 8th deliberately withheld because a third
heavy-A guess had no evidence basis once two systematic attempts — one
targeted, one exhaustive — both came up empty. The "exhausted" framing
overstates how constrained the decision was; it was a judgment call to stop
chasing a value that behaves like a single-sample transient, not a hard
resource limit.)

**What would answer it:** a reactive capture trigger — poll `MFSUBMIT` live
and open the `--capture` window when `cov_px` nears the target — rather than
another static `--capture START:FRAMES` index rescan, which has now failed
twice (a targeted bracket and a 1,100-frame exhaustive sweep).

---

## 7. Data-trust caveats

Stated plainly, in the style of the Stage A document's §9, so no downstream
plan over-reads this corpus.

1. **Scene identity rests on a numeric gate, corroborating a prior
   screenshot-confirmed fingerprint — no new frame-exact screenshot was taken
   this phase.** The primary proof for all three reproduced anchors is
   `mftrace_analyze.py --expect-covered <n> --tol 2.0`, GATE OK at 0.00%
   deviation. For quiet (182,661) and arrival (245,346), that numeric identity
   corroborates a pre-existing screenshot-confirmed identity from
   `docs/superpowers/investigations/2026-07-28-ingame-frame-budget.md`, which
   recorded an `echo screenshot > /dev/MiSTer_cmd` confirmation for the same
   `cov_px` fingerprint in an earlier session. Heavy-B (213,358) has no such
   prior screenshot pedigree — it reproduces Stage A's own 200-tri plateau
   numerically, but Stage A itself recorded no screenshot confirmation either.
   Task 5's W2 A/B *did* take four new screenshots, but at wall-clock dwell
   points, not at the exact `cov_px`-matched frames the perf table cites (see
   point 3 below) — they are corroborating evidence of "no visible
   corruption," not frame-exact scene-identity proof.
2. **The trace's `f=` frame index is skewed against the live console's
   `MFSUBMIT n=` label at ramp edges, agreeing only inside a stable plateau.**
   In the same run, the live console printed `MFSUBMIT n=1890 cov_px=165665`
   while the trace's own `f=1890` group reported `cov_px=213358` — a
   same-run, same-nominal-frame disagreement of ~48,000 px. The two agree
   once sampling moves a few dozen frames into the plateau (`n=1920` matches
   the trace exactly). Consequence: every match in this document was made on
   exact `cov_px` values read from the same instrument (trace-to-trace or
   `MFSUBMIT`-to-`MFSUBMIT`), never by trusting a literal frame-index label,
   and never by cross-reading a trace `f=` against a console `n=` at a ramp
   edge.
3. **Engine-frame alignment drifts between separately-launched runs — by
   hundreds of frames, not "tens to ~90."** Task 5's own report characterized
   the drift as "tens to ~90 frames," but its own arrival A/B rows are cited
   at `n=4200` (baseline) and `n=5130` (lever) — **930 frames apart** — for
   the same `cov_px=245346` value. The `cov_px`-exact match itself is still
   valid (both rows independently satisfy the anchor), but the stated
   magnitude of the drift is corrected here: it is at least an order of
   magnitude larger than "tens to ~90" in the arrival case.
4. **The sim models one synthesized clear; production emits roughly three per
   frame, of which about one survives to be emitted after the defer/drop
   lever.** `gen_tri_stream.c` synthesizes exactly one full-screen clear via
   the RTL control-block path (`MFTRACE` carries no fill/clear records at
   all — only triangle groups), which is the same path §1 shows is dead in
   production. The calibration in §4 is therefore comparing a sim with one
   synthesized clear against a post-W2 device stream that, per §2/§3, emits
   ~1.0 clears/frame after deferral — the counts are aligned by coincidence
   of the lever's steady state, not because the sim models the pre-W2
   3-clears-per-frame reality; a pre-W2 comparison would not have this
   coincidental alignment.
5. **Visual checks are corroborating, not frame-exact**, in both the Stage B
   corpus captures (Task 2, mechanism identified but not exercised for the
   4-point corpus — see Task 2 report) and the W2 A/B screenshots (Task 5 §7,
   four screenshots at wall-clock dwell points: no stale pixels, no blanking,
   no missing geometry in either arm at either scene, but not matched at the
   precise `cov_px`-sampled frame numbers the perf tables use, and the busy
   pair in fact shows a different gameplay outcome — player death — between
   arms, attributable to the same frame-alignment drift as point 3, not a
   rendering regression).
6. **Partial-clear interleaving with the defer/drop lever is a pre-existing
   hazard, not proven unreachable, and not a W2 regression.** `mf_clear()`
   routes any non-`appsurf` FBO to the WORK slot using that surface's own
   `w`/`h`, not a hardcoded full-screen extent — so a clear on a small effect
   surface already emits a partial fill to WORK today, independent of W2. This
   document does not claim the reachability question is settled; W2's own
   defer test is explicitly full-extent-only (`w == BLT_FB_WIDTH && h ==
   BLT_FB_HEIGHT`, plan Task 3 implementation), so the lever itself cannot
   defer a partial clear — but that guard says nothing about whether a
   partial clear can still land interleaved with a *deferred full-extent* one
   on the same target. That interaction was not exercised this phase and is
   not proven safe.

---

## 8. Provenance

**Worktrees:** `wt-p4b-harness` (`perf/phase4-stage-b-harness`, harness +
findings), `wt-gmloader-p4b-clear` (`perf/phase4-stage-b-clear`, engine),
`wt-maldita-p4b-vectors` (`test/phase4-stage-b-vectors`, sim vectors, RTL
untouched).

**Data corpus:**
`docs/superpowers/findings/data/2026-07-30-phase4-stage-b/` — the 4-scene
pre-W2 baseline logs and traces (`quiet-capture.log`, `heavy-b-capture.log`,
`arrival-capture.log`, `heavy-a-attempt-*.log`, `mftrace-{quiet,heavy-b,arrival}.txt`
+ `.analysis.md`), the W2 A/B logs (`w2-{baseline-defer0,lever-defer1}-ingame-stage1{,-busy}.log`),
and the W2 screenshots (`w2-screenshots/`).

**Task reports:** `task-1-report.md` (scene provenance fix), `task-2-report.md`
(4-point corpus + heavy-A gap), `task-5-report.md` (ARM build, deploy, device
A/B, screenshots) in this worktree; `task-3-report.md` / `task-4-report.md`
(deferred-clear module + backend wiring, incl. the diagonal-pair cover-proof
fix and the FPS-overlay ordering fix) in `wt-gmloader-p4b-clear`;
`task-6-report.md` (sim vectors) in `wt-maldita-p4b-vectors`. Task 7's
calibration result is recorded directly in
`mister-gmloader/.superpowers/sdd/progress.md` under the
`PHASE 4 STAGE B W1+W2` ledger.

**Engine build:** `wt-gmloader-p4b-clear` @ `f184435`, cross-built in Docker
(`arm32v7/debian:bullseye-slim`), md5 `e67f5b1acad0f704d164f393ce96d773`,
local == device, verified before and after the A/B.

⚠️ **The measured commit is not the merged tree.** The engine branch tip moved
to `3e0704a` after this A/B was taken — the source-sample discharge fix, which
makes a pending APPSURF clear also discharge on a draw that *samples* the
surface rather than only on one that *targets* it. That path is argued to be
unreached in the production draw order (which is why the measured `emitted` /
`dropped` counters are unaffected), but every number in this document was
produced by `f184435`, not by what ships.

**The device-validated binary predates a toolchain change on the merge
target.** The measured engine is md5 `e67f5b1acad0f704d164f393ce96d773`, built
from base `e3fccae`. `gmloader-next` master has since moved to `2ca78ce`,
which widened `-mfpu=neon-vfpv3` from one object to all of
`gmloader/mister/`, including the files this phase changed. The merge is
textually clean and the risk is low on the merits (no `-ffast-math`, no
`-ftree-vectorize`; the cover proof this phase adds is scalar float
compares) — but **the merged artifact has never been built or measured.**
That is a gap in this document's provenance, not a closed question.

**Arm identity is not fully covered by the provenance block.** W1 fixed
`--scene` reaching neither the filename nor the log contents. `--env` has
exactly the same shape and is what selected the A/B arms in this W2 dataset
(`defer=0` vs `defer=1`), and it was **not** fixed: the two quiet-arm
provenance blocks are byte-identical to each other. Arm identity survives
only via the engine's own `MFCLEAR ... defer=N` line inside each log and a
hand-chosen filename (`w2-baseline-defer0-...` / `w2-lever-defer1-...`) —
machine-recoverable, but the provenance fix from W1 is incomplete in exactly
the dimension this phase depended on to tell the two arms apart.

**Not in scope for this document:** opening the engine/sim-vector PRs and
bumping the `external/gmloader-next` submodule pin, per the plan's Task 8
Steps 3–5. Those are held pending a separate review and are not performed
here.

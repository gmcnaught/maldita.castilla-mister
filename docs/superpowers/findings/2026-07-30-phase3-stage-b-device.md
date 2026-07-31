# Phase 3 Stage B — device validation on `.62`

**Date:** 2026-07-30
**Stack:** RBF `MalditaCastilla_7c0b370.rbf` (Quartus CI run `30554378574`, branch
`perf/60fps-phase3`, `wt-maldita-60fps-p3` HEAD `7c0b370`, `fpga/` tree
`eba40b41`), engine `wt-gmloader-60fps-p3` @ `b775007`, md5
`8f6a2e542bd124d7b6c9496b13aa9c77` (already resident from Stage A; verified by md5
against the local build rather than assumed). Device `.62` (`root@192.168.20.62`,
host `misterCade`). `.81` untouched.
**What shipped in this bitstream:** span-walk rasterization + the A-chain pipeline
(the two perf levers) + the new scanout-frame counter. No host change.
**Protocol:** Phase 2 unchanged — `mister_run.sh bench --scene ingame-stage1
--preset fabric --godmode`, daemon-path launch, wedge gate armed, sole engine
asserted every sample, scene screenshot-confirmed at 288×216, period from the
C_DONE (`0x3B000028`) delta. Deviation: `--secs 150/160/150` instead of 120, which
widens the C_DONE window from ~33 s to 60–90 s of confirmed gameplay. Nothing else
differs.

---

## The result, stated first

**Both fabric predictions landed. The delivered-fps prediction did not, and the
whole miss is a host frame limiter — not the fabric.**

| Claim | Predicted | Measured | Error |
|---|---|---|---|
| Quiet fabric `frame` | 16.15 ms | **16.20 ms** | +0.31 % |
| Quiet `texwait` | 2.437 ms | **2.465 ms** | +1.1 % |
| Arrival `texwait` | 3.749 ms | **3.70 ms** | −1.3 % |
| Quiet non-`texwait` | 13.71 ms | **13.74 ms** | +0.18 % |
| Arrival fabric `frame` | 21.6 – 22.0 ms | **21.37 ms** | −1.1 % vs band low |
| Quiet period | 17.85 ms | **19.81 / 19.69 ms** as shipped | **+11 %** |
| Quiet fps | ~56 | **50.5 / 50.8** as shipped | **−10 %** |
| Quiet period, limiter disabled | (17.85) | **18.09 ms** | +1.3 % |
| Quiet fps, limiter disabled | (~56) | **55.27** | −1.3 % |

The fabric did exactly what Stage A said it would. The delivered period carries an
extra **~1.6–1.7 ms/frame of `SDL_Delay` padding** from the engine's 60 fps frame cap,
which Phase 2 measured as costless and which became real the moment the loop body
dropped near 16 ms. Disabling it (`GMLOADER_FPS=0`, a sweep — the shipped default
is unchanged) recovers the predicted number to within 1.3 %.

---

## Quiet scene — Chapter I standing pose (`cov_px` 182,661, `draws=12 tris=216`)

Medians over the last 60 MFSUBMIT windows. Coverage is bit-identical to Phase 2, so
this is the same pixels through different RTL.

| Metric | Phase 2 (`cd4d9f1`) | run 1 | run 2 | run 3 (`--fps 0`) |
|---|---|---|---|---|
| fabric `frame` ms | 19.30 | **16.20** | **16.20** | **16.20** |
| `tri` ms | 17.01 | 13.89 | 13.88 | 13.88 |
| `dpath` ms | 13.59 | 11.42 | 11.42 | 11.42 |
| `texwait` ms | 3.42 | 2.47 | 2.46 | 2.46 |
| `ovhd` ms | 2.29 | 2.32 | 2.32 | 2.32 |
| covered px | 182,661 | 182,661 | 182,661 | 182,661 |
| overdraw | 2.94 | 2.94 | 2.94 | 2.94 |
| **cyc/px** | **7.3** | **6.20** | **6.20** | **6.20** |
| `wait_ms` avg | 21.49 | 19.16 | 19.23 | 17.73 |
| BLITPROF `logic` / `raster` | 7.0 / 2.5 | 7.9 / 2.3 | — | 5.9 / 2.3 |
| timeouts (`to=`) | 0 | 0 | 0 | 0 |
| **True period ms (fps)** | 21.02–21.60 (46.3) | **19.81 (50.48)** | **19.69 (50.78)** | **18.09 (55.27)** |

C_DONE windows: run 1 = 3,251 completions / 64.40 s; run 2 = 4,547 / 89.55 s (the
`n ≥ 2750` quiet segment of a 102.7 s window); run 3 = 3,536 / 63.98 s. One sample
per second, sole engine asserted at every one.

**Determinism check passes.** The three runs' fabric medians match to ≤0.01 ms on
every column, across three independently loaded cores and three distinct logs, while
the host-side rows (`logic`, `wait_ms`, period) differ as expected. Nothing is
discarded.

**Where the 3.10 ms came from.** `dpath` 13.59 → 11.42 (−2.17) and `texwait`
3.42 → 2.47 (−0.95); `ovhd` is flat at 2.32. cyc/px 7.3 → 6.20 is the span walk
and the A-chain pipeline showing up as fewer cycles for identical coverage.

## Arrival scene — the Chapter I transient

The apples-to-apples row is the window where `cov_px` is exactly 245,346, the same
window Phase 2 quoted; run 1 hits it at `n=2580` and run 2 at `n=2490`.

| | Phase 2 | run 1 | run 2 |
|---|---|---|---|
| fabric `frame` | 25.5 | **21.36** | **21.37** |
| `tri` | 23.2 | 19.02 | 19.02 |
| `texwait` | 5.2 | 3.70 | 3.70 |
| `dpath` | 18.0 | 15.32 | 15.32 |
| `ovhd` | — | 2.34 | 2.36 |
| covered px | 245,346 | 245,346 | 245,346 |
| cyc/px | 7.2 | 6.1 | 6.1 |
| transient peak `frame` (cov) | — | 21.55 (246,644) | 21.85 (248,860) |

**Measured 21.36 / 21.37 against a predicted 21.6 – 22.0 band** — marginally better
than the band's low end. Per-second C_DONE across the transient (run 2, the run whose
sampler window was placed to cover it): **22.45 – 22.98 ms** at the peak, against
Phase 2's ~33 ms. Still short of 16.69, which is the outcome Phase 4 was scoped for.

## The new scanout instrument — Phase 2 open question 4 is closed

`0x3BFB0018` (monotonic scanout frame count) and `0x3BFB001C` (period in `clk_sys`
cycles @ 98.4375 MHz), read by `devmem` once per second. 215 samples across the
three runs. (The engine now reads the same words out of its own mmap, per frame,
to pace the loop — see the frame-limiter section.)

| | value |
|---|---|
| `scan_period_cyc` | **1,642,740 — identical in all 215 samples, zero spread** |
| → scanout period | **16.6882 ms** |
| → scanout rate | **59.9228 Hz** |
| RTL header's nominal | 1,642,672 (59.92 Hz — the header's own stated nominal, not 60.0000) — measured is +68 cyc, +0.0041 % |
| `scan_frame_cnt` rate (host wall clock) | 59.922 / 59.910 / 59.894 Hz |

The counter reads the video timing generator, which is free-running: the scanout
period does **not** move with render load, and it is **not** the delivered frame
rate. C_DONE is. The useful product is the ratio:

| | scanout Hz | render fps | scanout frames per rendered frame | repeated frames |
|---|---|---|---|---|
| Quiet, as shipped | 59.92 | 50.5 | 1.187 | 18.7 % |
| Quiet, limiter off | 59.89 | 55.3 | 1.084 | 7.7 % |

The residual spread in the `scan_frame_cnt` rate (±0.05 %) is `/proc/uptime`
granularity in the host sampler, not scanout jitter — `scan_period_cyc` itself never
varied by a single cycle. Note the two 32-bit `devmem` reads are not mutually atomic
(the FPGA writes them in one 64-bit beat); with a period this stable it does not
matter here, but a straddled pair is possible in principle.

**Bonus deliverable:** 16.6882 ms is now a *measured* pacing target for the host
frame limiter, which is the next section's whole problem.

## Why the fps prediction missed: the frame limiter, quantified

Phase 2's model was `period ≈ fabric + ~1.7 ms exposed host`. Test it three ways:

| | fabric | period | exposed host |
|---|---|---|---|
| Phase 2 quiet (`cd4d9f1`) | 19.30 | 21.02–21.60 | 1.72 – 2.30 |
| Phase 3 quiet, as shipped | 16.20 | 19.81 | **3.61** |
| Phase 3 quiet, `GMLOADER_FPS=0` | 16.20 | 18.09 | **1.89** |
| Phase 3 arrival, as shipped | 21.37 | 22.45–22.98 | 1.1 – 1.6 |

**The model holds — 1.89 ms measured against ~1.7 predicted.** What breaks it is a
term that appears only when the loop body approaches 16 ms: 19.81 − 18.09 =
**1.72 ms** (run 2's 19.69 gives 1.60), i.e. **~1.6–1.7 ms**.

**Mechanism — corrected 2026-07-30 after the fix was built and measured.** The
version first published here (*"at Phase 2's 27 ms loop body every frame tripped
that branch, so `SDL_Delay` never fired"*) is **wrong**, and is retained only as the
claim being withdrawn. Two reviews caught it against the code, and a device A/B
settled it.

*Observed, in `main.cpp:836-849`.* The catch-up branch
`if (next_ms == 0 || now > next_ms + frame_ms) next_ms = now;` is followed by an
**unconditional** `next_ms += frame_ms;` and then
`if (now < next_ms) SDL_Delay(next_ms - now);`. After a catch-up reset,
`next_ms == now + frame_ms > now`, so tripping the branch produces a **full 16 ms
sleep** — the opposite of "never fired".

*Observed, in simulation.* That limiter driven in isolation by a fixed 18.09 ms body
trips catch-up on 20,000/20,000 frames and sleeps 16.00 ms on every one, yielding a
34.09 ms period. The device measures 19.795 ms. So the sleep is **not additive to
the loop body**, and neither published explanation survives.

*Inferred, and it fits both regimes with one constant.* The sleep sits **after** the
doorbell, so it overlaps fabric work; it costs only what it pushes the next doorbell
past `C_DONE`. With `S` = sleep, `A` = host work between the cap and the next
doorbell, `F` = fabric `frame`, `e` = post-`C_DONE` serial tail:

`period ≈ max(S + A, F) + e`

| | `F` | `S` | `A` | model | measured |
|---|---|---|---|---|---|
| Phase 2 quiet | 19.30 | 16 | 1.9 | `max(17.9, 19.30) + e` = 19.30 + e | 21.02–21.60 — cap invisible |
| Phase 3 quiet, capped | 16.20 | 16 | 1.9 | `max(17.9, 16.20) + 1.89` = **19.79** | **19.795** |
| Phase 3 quiet, uncapped | 16.20 | 0 | 1.9 | `max(1.9, 16.20) + 1.89` = **18.09** | **17.93** |

`frame_ms = (Uint32)(1000/60) = 16` is still an integer-truncation defect (it targets
62.5 fps against a 16.6882 ms scanout period), and it is still true that the cost
only appears once the loop body drops near 16 ms. What is **not** true is that the
delay stopped firing at 27 ms: it fired, and was hidden by a slower fabric.

**Phase 2's "the limiter costs nothing" finding is superseded, not contradicted** —
it was true at 27 ms and false at 16.2 ms — but the reason is overlap, not absence.

**Fixed, and measured.** `GMLOADER_FPS=0` was never a shipping option (the cap stops
the blitter running the GM VM far above the display rate, which races the game's
logic and triggers relaunch loops, `main.cpp:832-835`). The shipped replacement is a
**leaky-bucket cap over the scanout counter** at `0x3BFB0018`, read out of the
mapping `backend_mfgpu` already holds. Same-session three-arm A/B on `.62`, same RBF,
same scene, fabric identical at 16.20 ms in all three:

| arm | cap | period | fps |
|---|---|---|---|
| **new scanout cap** | leaky bucket, depth 2 | **17.996 ms** | **55.57** |
| old wall clock (`--fps 60`) | `SDL_Delay` on a 16 ms grid | 19.795 ms | 50.52 |
| none (`--fps 0`) | — | 17.931 ms | 55.77 |

**−1.79 ms/frame, +5.05 fps**, and within 0.06 ms of uncapped. Details, fallback
behaviour and the cap-still-engages evidence:
`.superpowers/sdd/stageB-task-limiter-report.md`.

## `texwait` — the number that decides Phase 4 scope, and the sim's credibility

| | sim (real-cache) | device | error |
|---|---|---|---|
| Quiet `texwait` | 2.437 ms | 2.465 ms | **+1.1 %** |
| Arrival `texwait` | 3.749 ms | 3.70 ms | **−1.3 %** |
| Quiet non-`texwait` | 13.71 ms | 13.74 ms | **+0.18 %** |
| Quiet total `frame` | 16.15 ms | 16.20 ms | **+0.31 %** |

**The real-cache sim is credible as a Phase 4 sizing instrument.** Two scenes, both
inside ±1.3 %, on the one quantity it was built to predict, with no fitted constants
and the pre-lever calibration (−0.69 % / −0.56 %) done before the levers landed. A
Phase 4 lever sized on it can be trusted to that band.

The recovery figure the A4 gate turns on: `texwait` 3.42 → 2.465 = **27.9 %
recovered**, against the ≥ 62.3 % Stage A §11.2 corrected the 15.0 ms
threshold to (§10's 42.2 % was too permissive by a stub-ratio error), and against
the ≥ ~69 % this document's own re-gate demands: a 14.80 ms fabric gate less the
measured 13.74 ms non-`texwait` leaves `texwait` ≤ 1.06 ms, i.e. 69.0 % of 3.42 ms. Task 1's pre-Quartus measurement predicted 28.2 %; the
device says 27.9 %. **The trigger that fired before the build fired again on the
device, at the same magnitude.** The user's decision to build anyway is validated on
its own terms — it bought the fabric numbers it was told it would buy — and the gate
it declined to close is still open.

Do not read the earlier idealized-cache sim's 98.1 % recovery as a failed
prediction: Stage A §6 explicitly labelled it a floor and refused to quote it as
one. The number that was quoted as a prediction is 2.437, and it was right.

## Draw-stream consistency check (`--capture` + analyzer)

A fourth run captured the post-lever draw stream (`--capture 4000:8`, 8 frames /
848 groups / 5,088 verts, window entirely inside the quiet scene) and ran it through
`mftrace_analyze.py --expect-covered 182661`:

    GATE OK: covered_px median 182661.0 is 0.00% away from expected 182661.0

Every line of the resulting decomposition is **identical** to Stage A's pre-lever
`mftrace-quiet.txt.analysis.md` — `covered_px` 182,661, `bbox_px` 371,484,
`unique_px` 62,208, `overdraw` 2.936, `cullable_px` 120,453, and the same COPY
125,568 / COLORKEY 57,093 blend split. The host emits the same stream; only the
fabric that consumes it changed. That run's own fabric medians (`frame` 16.20,
`texwait` 2.46, `dpath` 11.42, `to=0` over 252 windows) are a **fourth** independent
match to 0.01 ms, taken with `GMLOADER_MFGPU_TRACE` active — its host-side timing is
distorted by the trace (`capture` 0.9–2.9 ms) and is deliberately not used for any
period figure here.

## Correctness

- **Zero corruption.** Nine screenshots (three per run, inside the measurement
  window) all show Chapter I "Colomera del Rey" at 288×216: no stale-parity bands,
  no torn tilemap, no garbage geometry, correct HUD, correct palette.
- **The game plays.** The HUD TIME counts down across a run (92 → 83 → 76 in run 1)
  and the SPEEDRUN timer advances, so the GM VM is progressing, not paused on an
  overlay.
- **`to=0`** across all 1,172 MFSUBMIT windows in the four runs. `MFDUP
  dup_draws_elided=0` throughout. No drops, no reclaims, no submit timeouts.
- **Wedge gate: never fired.** All four core loads came up
  clean on the first attempt (`engine up after 3s`, no `wedge: retry`, no post-hoc
  hit). No run was retried, so no run is a retry in disguise.
- **Sole engine** asserted at all 590 per-second samples across the four runs.
- **No incidents.** Nothing on `.62` needed manual repair; `.81` was never contacted.

**Audio: instrument gap, recorded rather than papered over.** The spec's criterion is
"audio underflow 0.0/s", but the `b775007` engine emits no periodic underflow
counter — the only `MisterAudio:` lines in any log are the three startup lines
(native audio active, pump pinned to core 1, track 1 open at 22050 Hz). The
criterion was therefore checked only as *absence*: zero lines matching
`underflow|xrun` in all four logs, and the track opened once and was never
re-opened. **It is not verified as a rate.** Adding a periodic underflow counter is a
prerequisite for anyone who wants that criterion to mean something.

## Re-gate for Phase 4

The delivered target is the *measured* scanout period, **16.6882 ms**, not the
nominal 16.69. With the exposed host tail measured at **1.89 ms**, the fabric gate
is **≤ 14.80 ms** — 0.20 ms tighter than Phase 2's 15.0, because the tail measured
slightly larger than Phase 2's estimate.

| Scene | fabric today | needed | factor |
|---|---|---|---|
| Quiet gameplay | 16.20 | 14.80 | **1.095×** |
| Chapter I arrival | 21.37 | 14.80 | **1.44×** |

Two items, in value order:

1. **Frame limiter (host, no Quartus cycle) — ~1.6–1.7 ms of delivered period,
   free. DONE, 2026-07-30.** Replaced by a leaky-bucket cap over the scanout
   counter; measured **19.795 → 17.996 ms (50.52 → 55.57 fps)** on `.62` with the
   cap still in force. The cap was kept, not disabled. See
   `.superpowers/sdd/stageB-task-limiter-report.md`.
2. **Fabric.** Quiet needs 1.095× — Stage A's candidate A (the pb sequencer, still
   at 6.000 cyc/px; measured cyc/px 6.20 confirms it is untouched) is sized well
   above that. Arrival needs 1.44×, and Stage A's I2 correction already found
   candidate A alone leaves arrival at 15.25 ms against the *old* 15.0 gate — against
   the new 14.80 gate it is worse. **Arrival still needs the opaque-cull contract
   lever**, exactly as the ratified A4 deviation anticipated.

Sizing both against the real-cache sim is now defensible: it predicted this
bitstream's fabric to +0.31 % and its `texwait` to +1.1 %.

---

## Provenance

- Logs: `bench-results/20260730-111518---preset_fabric_--godmode.log` (run 1),
  `20260730-112010---preset_fabric_--godmode.log` (run 2),
  `20260730-112520---preset_fabric_--godmode_--fps_0.log` (run 3, the limiter
  sweep), `20260730-113239---preset_fabric_--godmode.log` + its
  `-mftrace-4000_8.txt` / `.analysis.md` (run 4, the stream check). Explicitly
  un-ignored in `.gitignore` because they are cited here.
- Counter samples (uptime, C_DONE, `scan_frame_cnt`, `scan_period_cyc`, one line per
  second) and one confirming screenshot per run:
  `docs/superpowers/findings/data/2026-07-30-phase3-stage-b/`.
- Deviations from the Phase 2 protocol, all deliberate: `--secs 150/160/150/130`
  instead of 120 (longer confirmed-gameplay window; Phase 2's rule is ≥30 s), a
  third run with `--fps 0` added as a diagnostic sweep, and a fourth with
  `--capture` for the stream check. No shipped default was
  changed and nothing was tuned to make a number match.

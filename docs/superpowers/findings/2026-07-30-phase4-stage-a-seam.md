# Phase 4 Stage A — the submit seam, decomposed on `.62`

**Date:** 2026-07-30
**Device:** `.62` (test unit). Bitstream frozen for the whole stage (maldita RTL
`a723aa5`); only the host engine changed.
**Instrument:** `MFSEAM` (Tasks 4–5), `GMLOADER_FCAP_STAT=1`, `MFSUBMIT`, `BLITPROF`.
**Design under test:** `specs/2026-07-30-phase4-host-coupling-design.md`.

**Captures** (all `bench-results/`, all `GMLOADER_FCAP_STAT=1`, all 30 s):

| id | file | cap |
|---|---|---|
| **A** | `20260730-175503---preset_fabric.log` | ON (`mode=scanout`) |
| **B** | `20260730-175627---preset_fabric_--fps_0.log` | OFF (`mode=off`) |
| **C** | `20260730-175732---preset_fabric.log` | ON (`mode=scanout`) |

All units below are `_ms` unless stated. Scanout free-runs at **16.6882 ms /
59.9228 Hz**; that figure is never rounded here.

---

## 0. Headline conclusion

**On every scene in this corpus that still has something to win, the FPGA's own
`frame` counter already exceeds the 16.6882 ms scanout period on its own. No
host-side lever can reach a locked 59.9228 fps on those scenes.**

- **Observed.** On the two heavy scenes, `frame` = 17.21–18.02. The three captures
  reproduce it: the settled 228-tri window reads 17.21 / 17.23 / 17.23 (A / B / C)
  and the 200-tri windows read 18.02 / 18.02 / 18.02 and 18.01 / 18.01 / 18.01. The
  scanout period is 16.6882. `frame` exceeds it by **+0.52 to +1.33**.
- **Observed.** On those same windows the host is blocked on the fabric for
  90–100 % of frames, and the total exposed tail (`period − frame`) is
  **0.47–0.86**, of which `notice` is **0.46–0.80** and `pub` is **0.00**. Driving
  the entire host-side exposure to zero would give `period = frame = 17.21`, i.e.
  **58.11 fps** — still short of 59.9228.
- **Observed.** On the light scenes (`frame` 9.04–13.59) the loop already runs at
  **59.60–59.66 fps** (mean period 16.762–16.779 over non-transition windows, an
  excess of **+0.074 to +0.090 ms/frame** over 16.6882), with `block` a median of
  0.34–0.40. The host↔fabric coupling on those scenes is already essentially
  closed.
- **Verdict against spec §8.** Risks **1 and 2 both obtain**. `notice` dominates
  the host-side exposure (§6 below), *and* removing all of it still does not fit
  16.6882 because the fabric term alone does not fit. Spec §8 records this as a
  planned outcome, not a failure. **Stage B re-gates as an RTL stage.** Its target
  is the fabric term (`cov_px`-driven raster cost), not the seam.

---

## 1. Instrument integrity (spec §5.3 gates)

**Observed, all three logs:**

```
$ grep -c 'suspect=[^0]' <log>      -> 0   (A, B, C)
$ grep -c 'incomplete=[^0]' <log>   -> 0   (A, B, C)
$ grep -c 'submit timeout' <log>    -> 0   (A, B, C)
```

`MFSEAM` windows: A = 80, B = 81, C = 80. **The identity closes on every window in
the corpus.** Spot check, A line 1671 and A tail:

```
MFSEAM n=30 period=18.88 host=6.40 block=12.44 pub=0.04 notice=0.71 blocked=97% suspect=0 incomplete=0 host_hist=0/0/0/0/14/9/6/1 pub_hist=29/0/0/1/0/0/0/0
MFSEAM n=30 period=17.70 host=9.08 block=8.62 pub=0.00 notice=0.49 blocked=100% suspect=0 incomplete=0 host_hist=0/0/0/0/0/13/16/1 pub_hist=30/0/0/0/0/0/0/0
```

6.40 + 12.44 + 0.04 = 18.88 ✓;  9.08 + 8.62 + 0.00 = 17.70 ✓.

Cap mode confirmed in every capped log:

```
A,C: frame-cap: scanout period 1642740 cyc = 16.6882 ms (59.9228 Hz); burst=2; mode=scanout
B:   frame-cap: disabled (GMLOADER_FPS=0)
B:   frame-cap: scanout period 1642740 cyc = 16.6882 ms (59.9228 Hz); burst=2; mode=off
```

No log contains `falling back to the wall-clock cap`.

**Two gates could not be checked from these artifacts — Unknown:**

- *Spec §5.3 gate 3 / brief Step 5.3 (instrument cost < 0.05 ms).* All three
  captures ran with the stat knob **on**. Nothing here bounds the instrument's own
  cost. **What would answer it:** one further capture, identical scene script, with
  `GMLOADER_MFSUBMIT_STAT` unset, comparing the run-summary frame period.
- *Brief Step 5.2 (`period` vs the run summary's frame period).* The pulled logs
  contain **no run-summary fps/period line** — they end at the last `MFSEAM`. There
  is no second instrument to cross-check `period` against.

**Correction to a prior claim.** `pub` is **not** `0.00` on every line with all 30
samples in bucket 0. Three lines in the corpus are exceptions: A line 1671
(`pub=0.04`, `pub_hist=29/0/0/1/0/0/0/0` — one sample in the 1.0–2.0 bucket), and B
lines 1654 and 1727 (`pub=0.01`, histogram still `30/0/0/0/0/0/0/0`). Every other
line — 79/80 in A, 79/81 in B, 80/80 in C — is `pub=0.00` with
`pub_hist=30/0/0/0/0/0/0/0`.
The conclusion is unchanged; the statement needed to be exact.

---

## 2. What these three captures actually contain (read this before the tables)

**Observed.** The three logs are the **same scripted trajectory**, frame for frame.
Comparing `BLITPROF tris` and `MFSUBMIT frame` window-by-window across A/B/C:

| window `n` | tris A/B/C | `frame` A/B/C |
|---|---|---|
| 150 | 28 / 28 / 28 | 10.70 / 10.70 / 10.70 |
| 1440 | 280 / 280 / 280 | 13.59 / 13.58 / 13.58 |
| 1920 | 200 / 200 / 200 | 18.02 / 18.02 / 18.02 |
| 2160 | 174 / 174 / 174 | 9.04 / 9.04 / 9.04 |
| 2400 | 228 / 228 / 228 | 17.21 / 17.23 / 17.23 |

C is offset by one 30-frame window from about `n=810` onward and is otherwise
identical to A. **Inferred:** capture C ("arrival / busy") and capture A ("quiet")
are not distinguishable as different scenes in this data; whatever scene selector
was intended did not produce a different workload. The logs record no scene
argument, so the labels cannot be confirmed from the artifacts. **Unknown:** whether
an actual arrival scene behaves differently. **What would answer it:** a capture
with the scene argument echoed into the log, plus the screenshot confirmation the
brief's Step 4 requires.

**Observed.** Fabric time tracks **coverage**, not triangle count. Over A's 80
windows: Pearson r(`frame`, `cov_px`) = **0.981**; r(`frame`, `tris`) = **0.204**.

| tris | N | `frame` med | `cov_px` med | overdraw med |
|---|---|---|---|---|
| 174 | 7 | 9.04 | 97,660 | 1.57 |
| 198 | 8 | 13.22 | 151,462 | 2.43 |
| 280 | 10 | 13.58 | 153,659 | 2.47 |
| 228 | 3 | **17.21** | 195,084 | 3.14 |
| 200 | 3 | **18.01** | 213,358 | 3.43 |

280 triangles cost 13.58; 200 triangles cost 18.01. **A triangle count is not a
scene identity and not a cost predictor.**

**Therefore: no comparison in this document is like-for-like against the Phase 3
baseline.** The Phase 3 figures (`fabric_ms[frame=]` 16.20, the 1.89 ms
serialization gap, 55.6 fps, 216 triangles) were taken on a scene whose fabric
term was 16.20. The heaviest scenes here measure 17.21–18.02, and the scene that
carries the run is 13.58. **The 16.20 / 1.89 / 55.6 numbers are not comparable to
anything below and are not used as a baseline.** Where this document reports a
change, it is between captures **within this corpus only**.

---

## 3. The term table

Because the corpus is one trajectory covering fabric times from 8.11 to 18.02, a
single per-log average would blend two structurally different regimes. The tables
are therefore split by whether the fabric term fits the scanout period.
Warm-up (first two windows) excluded throughout. Format: **mean (median, min–max)**
across windows.

### 3.1 Host-bound regime — `frame ≤ 16.6882`

| capture | N | `period` | `host` | `block` | `pub` | `notice` | `blocked%` | `frame` | tail = `period−frame` |
|---|---|---|---|---|---|---|---|---|---|
| **A** cap ON | 73 | 16.96 (16.71, 16.40–28.38) | 16.19 (16.38) | 0.77 (0.34) | **0.00** (0.00) | 0.26 (0.16) | 14.8 % (10) | 12.61 (13.33) | 4.35 (3.41) |
| **B** cap OFF | 73 | 16.92 (16.69, 16.41–24.83) | 16.17 (16.42) | 0.75 (0.34) | **0.00** (0.00) | 0.46 (0.14) | 13.7 % (7) | 12.61 (13.32) | 4.31 (3.47) |
| **C** cap ON | 72 | 16.94 (16.73, 16.40–26.15) | 16.12 (16.37) | 0.81 (0.40) | **0.00** (0.00) | 0.36 (0.12) | 15.3 % (10) | 12.63 (13.33) | 4.31 (3.47) |

The `min–max` on `period` is dominated by scene-transition windows. Excluding
windows with `period ≥ 18` (2 in A, 3 in B, 3 in C):

| capture | N | mean `period` | fps | excess over 16.6882 |
|---|---|---|---|---|
| **A** cap ON | 71 | **16.779** | 59.60 | +0.090 |
| **B** cap OFF | 70 | **16.766** | 59.64 | +0.078 |
| **C** cap ON | 69 | **16.762** | 59.66 | +0.074 |

### 3.2 Fabric-bound regime — `frame > 16.6882`

| capture | N | `period` | `host` | `block` | `pub` | `notice` | `blocked%` | `frame` | tail |
|---|---|---|---|---|---|---|---|---|---|
| **A** cap ON | 5 | 18.69 (18.81, 17.70–19.45) | 8.14 (6.92) | 10.53 (11.89) | 0.01 (0.00) | **0.60** (0.58) | 90.8 % | 17.60 (17.99, 16.77–18.02) | **1.09** (0.82) |
| **B** cap OFF | 6 | 18.54 (18.27, 17.70–20.38) | 7.85 (7.56) | 10.69 (10.30) | 0.00 (0.00) | **0.51** (0.48) | 91.2 % | 17.61 (17.60, 17.21–18.02) | **0.93** (0.60) |
| **C** cap ON | 5 | 18.81 (18.48, 17.94–20.48) | 8.21 (7.57) | 10.59 (10.82) | 0.00 (0.00) | **0.65** (0.72) | 90.0 % | 17.67 (17.56, 17.23–18.02) | **1.14** (0.72) |

### 3.3 Per-plateau detail (capture A; B and C agree to ±0.05 on `frame`)

| plateau | N | `frame` | `period` med | `host` med | `block` med | `pub` | tail med |
|---|---|---|---|---|---|---|---|
| 174 tris | 7 | 9.04 | 16.70 | 16.51 | 0.19 | 0.00 | 7.66 |
| 198 tris | 8 | 13.22 | 16.68 | 16.42 | 0.29 | 0.00 | 3.42 |
| 270 tris | 8 | 13.54 | 16.70 | 16.26 | 0.49 | 0.00 | 3.19 |
| 280 tris | 10 | 13.58 | 16.79 | 16.31 | 0.41 | 0.00 | 3.27 |
| 228 tris | 3 | 16.77 / 17.99 / 17.21 | 18.81 | 9.08 | 8.62 | 0.00 | 0.82 |
| 200 tris | 2 | 18.02 / 18.01 | 18.73 | 5.71 | 13.00 | 0.02 | 0.72 |

**Observed:** the two regimes are structurally opposite. Host-bound —
`host` ≈ 16.1–16.5, `block` ≈ 0.2–0.5, tail 3.2–7.7 (the fabric is *idle* for
that tail). Fabric-bound — `host` collapses to 5.0–9.4, `block` rises to
8.5–13.6, tail collapses to 0.47–0.86.

**Observed identity on a fully-blocked window:** since
`period = host + block + pub` and `notice = (host + block) − frame`, a window at
`blocked=100%` satisfies `period = frame + notice + pub` exactly. A `n=2400`
(capture A): 17.21 + 0.49 + 0.00 = 17.70 ✓. This is why the fabric-bound tail and
`notice` are the same number to two decimals.

---

## 4. `host` and `pub` distributions; is the body bimodal?

### 4.1 `pub` — measured zero

Aggregating `pub_hist` over the whole corpus: **7,229 of 7,230 samples** fall in
bucket 0 (`≤ 0.25 ms`). One sample sits in bucket 3 (1.0–2.0 ms, capture A window
`n=1920`). Every window mean is `0.00` except three (`0.04`, `0.01`, `0.01`).

**Inferred:** the control-block publish + barrier + doorbell costs under 0.25 ms
per frame, i.e. under 1.5 % of the scanout period. **`pub` carries no bimodality
and no removable cost.**

### 4.2 `host` — bimodal *across regimes*, unresolved *within* the host-bound regime

Aggregated `host_hist` (bucket edges 0.25 / 0.5 / 1.0 / 2.0 / 4.0 / 8.0 / 16.6882 / ∞):

| capture | regime | ≤2.0 | 2–4 | 4–8 | 8–16.6882 | >16.6882 |
|---|---|---|---|---|---|---|
| A | host-bound (2,190 samples) | 0.0 % | 0.6 % | 1.7 % | **60.7 %** | **36.9 %** |
| B | host-bound (2,190) | 0.0 % | 0.4 % | 1.8 % | **61.6 %** | **36.2 %** |
| C | host-bound (2,160) | 0.0 % | 0.5 % | 1.9 % | **60.6 %** | **37.0 %** |
| A | fabric-bound (150) | 0.0 % | 22.7 % | 40.0 % | 30.0 % | 7.3 % |
| B | fabric-bound (180) | 0.0 % | 19.4 % | 43.3 % | 30.6 % | 6.7 % |
| C | fabric-bound (150) | 0.0 % | 24.0 % | 39.3 % | 30.0 % | 6.7 % |

**Observed:** `host` has **zero mass below 2.0 ms anywhere in the corpus**. There
is no "fast half" of the body.

**Answer to the design's question — where does the bimodality live?**

- **The body is bimodal, and the bimodality is in `host`, not `pub` and not
  `block`.** The two modes are the two regimes: `host` ≈ 16.4 when the fabric fits
  the period, `host` ≈ 5–9 when it does not. But this is a *consequence*, not a
  cause: in the fabric-bound regime the host is simply overtaken by `block`, and
  `host + block` stays pinned at `frame + notice`.
- **Within the host-bound regime the histogram cannot resolve the shape.** 97.6 %
  of samples land in the two widest buckets (8–16.6882 and >16.6882), split roughly
  61/37. The instrument tells us `host` is between 8 and ~20 on almost every frame;
  it cannot tell us whether that is one tight mode straddling the 16.6882 edge or
  two. **Unknown.** **What would answer it:** a bucket set with edges inside 8–20
  (e.g. 10 / 12 / 14 / 16 / 16.6882 / 18 / 20), or a p50/p90/p99 on `host`.

### 4.3 The `--fps 0` capture does **not** measure an unpaced body

**Observed (data).** Capture B, with the cap fully disabled, is statistically
indistinguishable from A and C: mean `period` 16.766 vs 16.779 / 16.762 in the
host-bound regime, and its aggregated `host_hist` matches A's to within 1 % in every
bucket.

**Observed (code, `gmloader/main.cpp`).** `fcap_refresh_hz()` (`:242`) calls
`fcap_resolve()` and returns the *measured* 59.9228 Hz regardless of cap mode; that
value is passed to `RunnerJNILib::Process` at `:1089`. The file's own comment at
`:93-95` states it: *"the GM refresh rate is resolved independently of which cap is
in force: `GMLOADER_FPS=0` and `GMLOADER_FPS=N` still hand GM the measured
59.9228 Hz when the instrument reads sanely. Only the PACING differs."*

**Inferred:** `GMLOADER_FPS=0` removes the engine's cap but leaves the guest VM
paced by the 59.9228 Hz it was handed, and GameMaker's pacing is display-gated by
design. **The design's "18.09 ms unpaced body at `fps=0`" baseline is not what this
build's `--fps 0` measures.** There is no measurement of the host's true unpaced
capability in this corpus.

**Unknown:** what the host body costs with no pacing at all. **What would answer
it:** a capture with `GMLOADER_FPS=0` *and* `fcap_refresh_hz()` forced to a high
value (e.g. 1000), so `Process()` is not handed a 60 Hz-shaped delta.

**Unknown:** the source of the residual +0.074 to +0.090 ms/frame over 16.6882 in
the host-bound regime — equivalent to losing one scanout boundary about every 185
frames (~3.1 s). Two named candidates: (a) the credit bucket is one-sided by
construction — `main.cpp:97-100` states it clamps surplus credit and therefore
"settles slightly BELOW 59.9228 Hz"; this cannot explain capture B, where the cap is
off and the same excess appears; (b) skew between `CLOCK_MONOTONIC` on the HPS and
`clk_sys` on the fabric, which would bias every host-measured `period` by a fixed
ratio. **What would answer it:** log the raw scanout-counter delta per frame
alongside the host timestamp, and compare the two clocks directly.

---

## 5. `FCAP` — the repaired, windowed numbers

`FCAP` is now windowed at 300 frames and timed with `clock_gettime(CLOCK_MONOTONIC)`.
Capture B produced **no `FCAP` lines at all** (`mode=off` returns before the stat
block), so the cap is only measured in A and C.

**Capture A** (`20260730-175503---preset_fabric.log`), verbatim:

```
FCAP n=300 win=300 waited=79 (26.3%) wait_ms_avg=10.017 starved=0 mode=scanout
FCAP n=600 win=300 waited=89 (29.7%) wait_ms_avg=3.546 starved=0 mode=scanout
FCAP n=900 win=300 waited=63 (21.0%) wait_ms_avg=4.273 starved=0 mode=scanout
FCAP n=1200 win=300 waited=56 (18.7%) wait_ms_avg=7.067 starved=0 mode=scanout
FCAP n=1500 win=300 waited=101 (33.7%) wait_ms_avg=5.761 starved=0 mode=scanout
FCAP n=1800 win=300 waited=80 (26.7%) wait_ms_avg=4.851 starved=0 mode=scanout
FCAP n=2100 win=300 waited=52 (17.3%) wait_ms_avg=7.828 starved=0 mode=scanout
FCAP n=2400 win=300 waited=88 (29.3%) wait_ms_avg=8.988 starved=0 mode=scanout
```

**Capture C**: `waited%` 16.3–37.3, `wait_ms_avg` 1.213–8.497, `starved=0` on all 8.

Amortised cap cost per frame (`waited × wait_ms_avg / 300`):

| capture | per-window range | **run mean** | frames that waited |
|---|---|---|---|
| A | 0.90 – 2.64 | **1.642** | 608 / 2400 = 25.3 % |
| C | 0.20 – 3.13 | **1.387** | 618 / 2400 = 25.8 % |

**The reading rule (spec §6.2), stated as required.**

> At a locked 59.9228 fps the cap reports `waited` near **100 %** with a *small*
> average wait. **That is the success signature, not a cost.**
> - high `waited%` + low `wait_ms_avg` → frames locking to consecutive boundaries;
> - low `waited%` + multi-millisecond `wait_ms_avg` → frames are **missing** their
>   boundary.
>
> Reading `waited%` alone as waste optimises in exactly the wrong direction. The
> 1.642 ms above is **not** a recoverable 1.642 ms: it is idle the loop must spend
> to avoid rendering faster than 59.9228 Hz, which `comp_fb_dma.sv:201` discards
> with the full fabric and host cost already paid.

**Applying the rule to this corpus:** `waited%` 16–37 with `wait_ms_avg` 1.2–10.0 is
the **second** signature. These runs are **not locked**. A quarter of frames arrive
at `fcap_wait()` early by an average of 6.48 (A) / 5.39 (C); three quarters arrive already in
credit, i.e. late. With `burst=2` this is a beat, not a lock. It is consistent with
the +0.074 to +0.090 ms/frame period excess of §3.1 and with the fabric-bound
windows where the loop simply cannot make the boundary.

---

## 6. Audio

**Observed: `starved=0` on all 16 `FCAP` lines across captures A and C** — a
measured zero, not an absence of lines. Spec §6.1 gate 2 is satisfied for the
captures that report it.

**Unknown for capture B:** `MisterAudio_StarvedFrames()` is folded into the `FCAP`
line, which `mode=off` never emits. The `--fps 0` run has **no** starvation
evidence either way. **What would answer it:** emit the starvation counter outside
the `FCAP_SCANOUT` branch, or re-run `--fps 0` with an unconditional audio stat.

---

## 7. Stage B lever sizing

Each lever is sized against the term spec §6 assigned it, using the measured
numbers above. Sizes are the **maximum** win available if the term went to zero.

| lever | term it attacks | **measured size of that term** | verdict |
|---|---|---|---|
| **L1** — eliminate the body variance | `pub` / `rem` spread | `pub` = **0.00** (7,229/7,230 samples ≤ 0.25). `rem` does not exist in this decomposition — spec §5.1 replaced it. The variance that remains lives in `host`, and it is the guest's own paced loop: cap ON and cap OFF give the same distribution to within 1 % per bucket (§4.3). | **DEAD** |
| **L2** — reduce `notice` | doorbell notice + `S_SNAP` serialization + DDR visibility | **0.38–0.80** (mean 0.58, median 0.56) over the 15 well-sampled windows at `blocked ≥ 90 %`; **0.46–0.80** over the fabric-bound subset of those windows. This is **86 %** of the fabric-bound exposed tail (0.56 / 0.65 median). | **SURVIVES — but is RTL, not host-only.** See §8. |
| **L3** — cheaper publish (fewer control words, batched writes) | `pub` | `pub` = **0.00**. Same measurement as L1. | **DEAD** |
| **L4** — move `update_inputs` / `video_process` into the fabric-busy window | host work still serialized after the fabric | Ceiling = `block` in the host-bound regime = median **0.34–0.40**, and even that is only winnable if the host's *arrival* were the blocker. In the fabric-bound regime the host already idles 8.5–13.6 ms at the barrier — there is nothing left to overlap. The Phase 2 deferred `C_DONE` await (`raster_backend_mfgpu.cpp:811`) already did this work. | **DEAD** (ceiling ≤ 0.40, unrealisable) |

**Levers entering Stage B: L2 only, and L2 is not host-only.** Per spec §5.5, "no
lever enters Stage B without a sized term" — L1, L3 and L4 have no term.

---

## 8. The `notice` verdict — Stage B's shape

**Observed.** Restricted to the 15 windows across A/B/C where `blocked ≥ 90 %` (so
`notice` is taken over essentially every frame in the window, not a small sample):

| quantity | min | median | max | mean |
|---|---|---|---|---|
| `notice` | 0.38 | **0.56** | 0.80 | 0.58 |
| tail (`period − frame`) | 0.47 | **0.65** | 1.59 | 0.71 |
| `pub` | 0.00 | 0.00 | 0.04 | 0.00 |

Representative verbatim lines (A line 1675 / `n=1950`, C line 1733 / `n=2370`, B line 1732 / `n=2400`):

```
MFSEAM n=30 period=18.59 host=5.02 block=13.56 pub=0.00 notice=0.58 blocked=100% suspect=0 incomplete=0 host_hist=0/0/0/0/20/5/5/0 pub_hist=30/0/0/0/0/0/0/0
MFSEAM n=30 period=18.40 host=7.57 block=10.82 pub=0.00 notice=0.80 blocked=97% suspect=0 incomplete=0 host_hist=0/0/0/0/0/22/7/1 pub_hist=30/0/0/0/0/0/0/0
MFSEAM n=30 period=17.70 host=6.89 block=10.80 pub=0.00 notice=0.46 blocked=100% suspect=0 incomplete=0 host_hist=0/0/0/0/0/21/9/0 pub_hist=30/0/0/0/0/0/0/0
```

**Inferred, and this is the verdict spec §6.2 / brief Step 6.6 asks for:**

1. **`notice` does dominate the host-side exposure.** 0.56 of a 0.65 ms tail. Spec
   §8 risk 1 obtains. `S_SNAP_WAIT`→`S_SNAP_DRAIN` is ~0.158 ms by design; the
   remaining ~0.40 is doorbell notice + DDR visibility. **Unknown:** the split
   between those two. **What would answer it:** an RTL counter stamping
   doorbell-observed against `C_DONE` written, which is an RTL change and therefore
   already outside the frozen-bitstream constraint.
2. **Even a perfect `notice` fix does not reach the gate.** `notice = 0`, `pub = 0`
   gives `period = frame`. On the 228-tri scene that is 17.21 → **58.11 fps**; on
   the 200-tri scene 18.02 → **55.49 fps**. Spec §6.1 gate 1 (`period ≤ 16.6882`)
   is unreachable by any host-only lever on those scenes. Spec §8 risk 2 obtains
   as well.
3. **Spec §8 risk 3 also obtains, in its literal form.** The variance is
   scene-driven: `frame` ranges 8.11–18.02 across one 30 s script, and it tracks
   `cov_px` at r = 0.981 (§2). A quiet-scene lock says little about the rest.
4. **Where the coupling *is* already closed:** on every scene with `frame ≤ 13.6`,
   `block` is a median 0.34–0.40 and the delivered rate is 59.60–59.66 fps. There
   is no ~1.4–1.9 ms serialization gap left to remove on those scenes *in this
   corpus*. (This is a statement about this corpus only; it is **not** a claim about
   the Phase 3 scene, which is not comparable — see §2.)

**Stage B therefore re-gates as an RTL stage.** Its target is the fabric term. The
work the design deliberately deferred is now the work: the redundant full-screen
CLEAR (≥0.795 ms, `blitter_top.sv:1322-1353`), the `ovhd` residual (2.29–2.63 on
the heavy scenes here), and opaque cull — all of which attack `cov_px`, which is
what `frame` is actually made of. The `notice` lever (L2) is worth 0.56 and belongs
in the same RTL stage, but it is second in size to any `cov_px` reduction: the
heavy scenes need **0.52–1.33 ms off `frame`** before a lock is even arithmetically
possible, and `notice` is not in `frame`.

---

## 9. Data-trust caveats

Stated plainly so no downstream plan over-reads this corpus.

1. **A and C are the same scene script** (§2). This corpus contains **one**
   workload, not a quiet/arrival pair. Spec §6.1 gate 3 ("arrival measured and not
   regressed") has no distinct arrival measurement to anchor to.
2. **No screenshot confirmation** was recorded, which the brief's Step 4 requires
   precisely when triangle counts do not distinguish scenes — and here they do not.
3. **The heavy scenes are thinly sampled**: the 228-tri segment is 3–4 windows
   (90–120 frames) at the *end* of each run, and the 200-tri segment is 2 windows
   (60 frames). The headline rests on `frame` = 17.21–18.02. The settled windows
   reproduce across captures to ±0.02 (228-tri: 17.21 / 17.23 / 17.23; 200-tri:
   18.02 / 18.02 / 18.02) — that reproducibility is why the thin sample is still
   usable. The *host-side* terms on those windows carry real sampling error, and
   the earlier windows of the 228-tri entry (16.77 / 17.81 / 17.56) do not align
   across captures because scene entry falls at a different point in each window.
4. **`--fps 0` is not an unpaced body** (§4.3) — a code-confirmed property of this
   build, not a run artifact.
5. **No comparison to Phase 3 is valid** (§2). Different scene, `frame` 17.21–18.02
   vs 16.20, coverage-driven not triangle-driven.
6. **Two spec §5.3 gates are unverified** (§1): instrument self-cost, and `period`
   against a second instrument.

---

## 10. Provenance

Logs: `bench-results/20260730-175503---preset_fabric.log`,
`bench-results/20260730-175627---preset_fabric_--fps_0.log`,
`bench-results/20260730-175732---preset_fabric.log`.
Engine code read directly for this document: `../wt-gmloader-p4-seam/gmloader/main.cpp`
(`fcap_resolve`, `fcap_wait`, `fcap_refresh_hz`, the `Process()` call site, the
`FCAP` print). `raster_backend_mfgpu.cpp` line references are carried from the
design spec, not re-verified here. Bitstream: maldita RTL `a723aa5`, unchanged for
the whole stage.
Design: `specs/2026-07-30-phase4-host-coupling-design.md`.

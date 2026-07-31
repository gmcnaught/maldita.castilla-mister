# `fabric_ms` scene-insensitivity — H1-H4 verdicts and the instrument trust gate

Tasks 5+6 (combined pass). Root-causes the 2026-07-17 observation that `MFSUBMIT
fabric_ms` read identical (`frame=25.58 tri=23.12`) at 28 triangles and at 360
triangles, while host-side `BLITPROF raster` scaled 16→37 ms. Branch
`perf/60fps-phase0-diagnostics`.

## Provenance for every number below

- **RBF**: `/media/fat/_Other/MalditaCastilla_476a422.rbf` on `root@192.168.20.81`.
  `fpga/` tree hash `34a4251fe9d5cd5e4b2eeda530214b05273b7f54`, identical
  (`git diff 476a422 HEAD -- fpga/` = 0 lines) to `maldita.castilla-mister` HEAD
  `e373e2f8a8b9e52c3f733169f860a04ab013ec1e` at the time of this investigation.
  This RBF does **not** define `SOLARUS_DBG_PROBES` (see H1 step 2).
- **Engine**: `gmloader-next` commit `70b4126249a40979344b73b33193d2856e354b49`
  ("fix: gate coverage estimate on GMLOADER_MFSUBMIT_STAT, count only
  fabric-emitted tris"), rebuilt via the Docker ARM cross-toolchain
  (`gmloader-armhf-build:bullseye`, `Makefile.gmloader ARCH=arm-linux-gnueabihf
  MISTER_BUILD=1 MISTER_NATIVE_VIDEO=1`) and deployed to
  `/media/fat/games/gmloader/gmloader`. **Deviation from the brief, recorded
  here explicitly**: the engine binary already on the device (mtime `Jul 28
  14:29`) predated this commit (`14:37:02`) by ~8 minutes and was still running
  the pre-fix `cov_px_est` accumulation site (`blitter.cpp`'s generic
  backend-dispatch, which the 70b4126 commit message says over-counted by
  "~6.6x on device" versus the fixed site in `mf_emit_group`). Since Task 6's
  gate consumes `cov_px_est` directly, measuring with the known-buggy site
  would have contaminated the gate verdict, so the engine was rebuilt and
  redeployed from HEAD before capturing the Task 6 numbers. Verified this
  mattered: re-ran both scenes after the rebuild and the `cov_px_est` values
  were unchanged to the pixel (see Trust Gate section) — for these two scenes
  the fixed and unfixed call sites saw the same triangle set, so this dead end
  is recorded rather than silently dropped.
- Fabric clock: `clk_sys = 98.4375 MHz` (host source comment,
  `raster_backend_mfgpu.cpp:458`, PLL outclk_0 / DDRAM_CLK).

## H1 — are the counter words `SOLARUS_DBG_PROBES` wedge snapshots? REFUTED

**Hypothesis**: `C_STATUS.hi` (`0x3B000034`) publishes `wedge_snap2` and
`C_SRCSEL.hi` (`0x3B00003C`) publishes `wedge_snap` — persistent worst-case
latches, structurally scene-insensitive — rather than the live perf counters.

**Step 1 — build config.** `maldita.castilla-mister/fpga/Maldita.qsf`:

```
$ grep -n "SOLARUS_DBG_PROBES" fpga/Maldita.qsf
21:# NOTE (2026-07-24): do NOT re-enable SOLARUS_DBG_PROBES without reading the probe-v3
```

Only a comment; no `set_global_assignment -name VERILOG_MACRO
"SOLARUS_DBG_PROBES=1"` is active. `git log --oneline -5 -- fpga/Maldita.qsf`:

```
d019207 diag(fabric): disable the probe define — the instrumented build wedges
698dc8a diag(fabric): wedge probe v3 — pin the stall to the S_SNAP tail
d8e95fe build: revert TEMP SOLARUS_DBG_PROBES enable (root cause pinned)
7cb722f build: TEMP enable SOLARUS_DBG_PROBES for reader-health tear diag
6f06a9c rtl: revert ascal, wire openbor DDR reader to fabric framebuffer
```

The define was enabled only for a temporary diagnostic (7cb722f) and disabled
again (d019207); it is off in the tree that built the deployed RBF. Confirmed
directly in `blitter_top.sv`: the `wedge_snap`/`wedge_snap2` wires and their
publish sites at `S_WR_STATUS`/`S_WR_PERF` are wrapped in
`` `ifdef SOLARUS_DBG_PROBES / `else / `endif` ``; the `` `else `` branch (the
one actually compiled) publishes `perf_texwait_cyc` to `C_STATUS.hi` and
`perf_tri_cyc` to `C_SRCSEL.hi` — the live per-frame cycle counters, not the
debug latches.

**Step 2 — raw device reads**, engine intended to be running the title scene
(see Trust Gate below for scene detail — **correction below**: these reads
actually landed on a later, drifted sample, not the title scene's `n=150`
point), 1 sample/sec:

```
$ ssh root@192.168.20.81 'for i in 1 2 3 4 5; do \
    printf "status_hi="; devmem 0x3B000034; \
    printf "srcsel_hi="; devmem 0x3B00003C; \
    printf "done_hi=";   devmem 0x3B00002C; \
    echo; sleep 1; done'

status_hi=0x00041F51   srcsel_hi=0x00181A25   done_hi=0x001BCB0E
status_hi=0x00042156   srcsel_hi=0x001819DB   done_hi=0x001BCCB3
status_hi=0x00042015   srcsel_hi=0x00181AA1   done_hi=0x001BCBCC
status_hi=0x00042036   srcsel_hi=0x00181A37   done_hi=0x001BC759
status_hi=0x00041F9A   srcsel_hi=0x00181921   done_hi=0x001BD95C
```

Converted at 98.4375 MHz: `status_hi` (`perf_texwait_cyc`) ≈ 270–271k cycles ≈
**2.74–2.76 ms**; `srcsel_hi` (`perf_tri_cyc`) ≈ 1.579–1.580M cycles ≈
**16.03–16.05 ms**; `done_hi` (`perf_frame_cyc`) ≈ 1.818–1.881M cycles ≈
**18.5–19.1 ms**.

**Correction (review pass)**: the write-up originally claimed these "match
the `MFSUBMIT` log's `texwait`/`tri`/`frame` fields for the same run to
within rounding." They do not, against the title scene's headline sample
(`n=150`: `texwait=1.45 tri=10.99 frame=13.02`,
`bench-results/20260728-151223-title-fixedbuild.log`): `srcsel_hi`'s 16.03ms
is **46% above** `tri=10.99`, and `status_hi`'s 2.74ms is **90% above**
`texwait=1.45`. They *do* match a later sample in the same log —
`n=1110` onward: `tri=16.05 texwait=2.75 frame=18.50` — to within rounding.
That log does not stay at its `n=150` reading: it drifts upward continuously
from `n=150` (`tri=10.99`) through `n=1110+` (`tri=16.05`, +46%), i.e. the
raw `devmem` reads landed on this later, drifted state, not the title-scene
point this section was trying to cross-check. Two consequences: (a) H1's
verdict (live counters, not latched debug snapshots) is unaffected — the
`devmem` values still match a real, live `MFSUBMIT` sample from the same
run, just not the one this section names; (b) the Trust Gate's "title scene"
sample below is contaminated by the same drift and is corrected there.

They also **fluctuate non-monotonically sample to sample** (`status_hi` goes
0x41F51 → 0x42156 → 0x42015 → 0x42036 → 0x41F9A — up, down, down, down)
rather than latching a worst-case and holding or climbing. A packed bbox
(`wedge_snap2 = max_fbdma_run`, or `wedge_snap`'s `peak_stuck`-derived word)
would be small (`maxx<288`, `maxy<216`) and monotonically non-decreasing
within a run; neither is observed.

**Verdict: H1 REFUTED.** The counter words are the live `perf_*_cyc`
accumulators, not `SOLARUS_DBG_PROBES` wedge snapshots. Confirmed both by the
`` `ifdef ``-gated source (the debug branch is not compiled into this RBF) and
by the raw values' magnitude/variance matching live per-frame cycle counts.

## H2 — dual-engine contamination. CONFIRMED (per earlier device work today)

This investigation did not re-litigate H2 — the morning's device work already
found three `Master_Daemon` instances on `.81`, each spawning a handler, two
engines writing one control block, visible as two interleaved `MFSUBMIT`
sequences at the same `n=` with different values in one log. **I agree with
this verdict.** It also fully explains the original 2026-07-17 numbers: a
fixed `frame=25.58 tri=23.12` regardless of scene is exactly what two engines
racing writes to the same `C_DONE`/`C_STATUS`/`C_SRCSEL` words would produce —
whichever engine's `S_WR_STATUS`/`S_WR_PERF` write lands last each frame wins,
decoupling the published number from either engine's real per-frame workload.

Live corroboration gathered today while driving this task: `Master_Daemon`
count on `.81` **flickers between 1 and 2** on its own —

```
$ for i in 1 2 3 4 5; do ssh root@192.168.20.81 'ps | grep -c "[M]aster_Daemon"'; sleep 2; done
1
1
1
2
1
```

— a live instance of the exact respawn-contamination mechanism the memory
record already names. `mister_run.sh`'s `assert_sole_engine` (which checks the
**engine** count via `[.]/gmloader`, not the daemon count) is the correct
per-sample gate; every capture in this document asserts engine count = 1
immediately before use. One capture attempt during this session (documented
under the Trust Gate section) hit a genuine fabric wedge unrelated to H2
(single daemon, single engine, `to=30` on the sample) — noted there, not
folded into H2, since dual-engine was ruled out for that sample.

## H3 — does `frame` track vblank rather than workload? REFUTED

**Hypothesis** (`blitter_top.sv:853`, `perf_frame_cyc` accumulates under `if
(!idle)`, `idle` set only in `S_POLL_SUBMIT`): `S_SNAP_WAIT`/the vblank
snapshot get counted into `frame`, so `frame` might be flat near the scanout
period regardless of workload, making `ovhd = frame - tri` meaningless.

Steady-state samples, sole engine, `to=0` both scenes:

| scene | tris | frame_ms | tri_ms | ovhd_ms |
|---|---|---|---|---|
| title (n=150) | 28 | 13.02 | 10.99 | 2.03 |
| gameplay (n=3420) | 216 | 20.79 | 18.50 | 2.29 |

`frame` moves from 13.02 → 20.79 ms (+60%) in lockstep with `tri` (10.99 →
18.50 ms, +68%); it is **not** flat, and it is **not** anywhere near the
measured 16.69 ms scanout period in either direction (13.02 ms is below it,
20.79 ms is above it) — a vsync-quantized wall-clock measure would cluster
near a multiple of the scanout period regardless of scene. Instead `ovhd =
frame - tri` is *itself* the stable quantity across a >2x cov_px_est range:
2.03 ms vs 2.29 ms, an 13% move against a 4.85x change in covered pixels. That
is consistent with `ovhd` being a real, small, roughly-fixed per-frame cost
(ring/setup/clear, as the source comment at `blitter_top.sv:861` describes),
not noise from vsync alignment.

**Verdict: H3 REFUTED.** `frame` tracks workload (via `tri` plus a stable
small overhead), not the vblank/scanout period. `ovhd = frame - tri` is a
meaningful (if minor) per-frame fixed-cost metric, not vsync-quantization
noise.

## H4 — are the counter reads stable (publish/read race)? REFUTED

```
$ ssh root@192.168.20.81 'for i in 1 2 3 4 5 6 7 8 9 10; do \
    a=$(devmem 0x3B00003C); b=$(devmem 0x3B00003C); echo "$a $b"; done'
0x00181989 0x00181970
0x00181970 0x00181970
0x00181952 0x00181952
0x001819B7 0x001819B7
0x001818FF 0x001818FF
0x001819A0 0x001819A0
0x001819A0 0x00181964
0x00181964 0x001818E0
0x001818E0 0x00181917
0x00181917 0x00181917
```

6/10 pairs are bit-identical; the other 4 differ by 25–128 cycles (≤1.3 µs at
98.4375 MHz) — far too small to be a full frame boundary (~1.6-2M cycles) and
far too small to be a torn 32-bit read (which would produce a value
unrelated in magnitude to its neighbor, not one a few dozen cycles off). Two
separate `devmem` process invocations each cost several ms of fork/exec on
this ARM target, so the two reads in a pair are not truly simultaneous; the
small deltas are consistent with the word being re-published by a new frame's
`S_WR_PERF` between the two reads (each frame's `perf_tri_cyc` is a
fresh per-frame count, not a running total, so small frame-to-frame drift on
an otherwise-static title screen is expected), not with a read/write race.

**Verdict: H4 REFUTED.** No publish/read race detected. `C_DONE`-last
ordering (documented at `blitter_top.sv:1580-1586`) appears to hold.

## Scanout period

`maldita.castilla-mister/fpga/rtl/openbor_video_timing.sv`:

```
5: //  288x216 active @ 59.92 Hz (380x262 total)
14: //  Refresh: 15,700 / 262 = 59.92 Hz (unchanged)
15: //  H freq:  53,693,182 / 3420 = 15,700 Hz (unchanged; 380 px/line x 9 MCLK = 3420 MCLK/line)
51: localparam H_ACTIVE = `FB_W;
52: localparam H_FP     = 16;
53: localparam H_SYNC   = 34;
54: localparam H_BP     = 42;
55: localparam H_TOTAL  = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 380
57: localparam V_ACTIVE = `FB_H;
59: localparam V_FP     = 14;
60: localparam V_SYNC   = 3;
61: localparam V_BP     = 29;
62: localparam V_TOTAL  = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 262
```

262 lines/frame at 15,700 Hz line rate ⇒ **59.92 Hz, period ≈ 16.69 ms**. This
is the quantum against which any vsync-quantization claim must be measured;
neither `frame` (13.02/20.79 ms) nor `tri` sits near it or a multiple of it in
either scene, reinforcing H3's refutation.

## Trust gate

Both scenes captured on the sole-instance engine (asserted before each
capture: `ps | grep -c "[M]aster_Daemon"` = 1, `[.]/gmloader` count = 1),
rebuilt engine (`70b4126`), same RBF (`476a422`, tree hash above).

**Operational note**: reaching gameplay required launching `joy_script`
(scripted "Sword" presses, `scripts/scenes/ingame-stage1.joy`) and
`load_core` back-to-back in the same remote command. Three earlier attempts
in this session that inserted an extra status-check round trip between
starting `joy_script` and issuing `load_core` (or which staged `bench.env`
after `load_core`) either (a) left the game looping the intro cutscene
because the button-press schedule had already elapsed before the engine
finished booting, confirmed by screenshot showing the same intro panel
repeating over 90+ seconds, or (b) hit a genuine fabric wedge
(`fabric never acked seq=N after 60 frames`, `to=30` in the `MFSUBMIT`
window) with a **single** confirmed daemon and engine — a real, intermittent
device-level stall distinct from H1-H4, not investigated further here as
out of scope; retrying the launch cleared it every time. Screenshots for
every scene transition (including the failed attempts) are retained in the
session scratchpad. The successful capture used
`scripts/scenes/ingame-stage1.joy` unmodified.

**Title scene — RETRACTED, see correction above.** The sample originally
quoted here (`bench-results/20260728-151223-title-fixedbuild.log`, `n=150`)
was labeled as the title scene's steady state:

```
BLITPROF f=150 draws=5 tris=28 culled=0 | ...
MFSUBMIT n=150 wait_ms[avg=14.85] fabric_ms[frame=13.02 tri=10.99 texwait=1.45 dpath=9.54 ovhd=2.03] cov_px_est=124840 overdraw=2.01 cyc_px=7.5 spin_avg=6828 to=0
```

It was not steady state — the H1 correction above shows this same log
climbing continuously from `n=150` to `n=1110` (`tri=10.99 → 16.05`, cov_px_est
`124,840 → 204,832`) before leveling off. `n=150` is one point on that climb,
not a settled title-screen reading, so the title/gameplay two-point
comparison and the "~2-3x residual gap" analysis originally built on it below
are both retracted in favor of the within-run sweep in the next section,
which does not depend on any single sample being "the" steady state for a
scene.

**Gameplay scene** — screenshot-confirmed Chapter I forest level (HUD:
P1-SCORE, LIVES x3, SPEEDRUN 00:27), `bench-results/20260728-151526-ingame-fixedbuild.log`,
engine `70b4126` (pre-clip `cov_px_est`, see below):

```
BLITPROF f=3420 draws=12 tris=216 culled=0 | ...
MFSUBMIT n=3420 wait_ms[avg=20.94] fabric_ms[frame=20.79 tri=18.50 texwait=3.77 dpath=14.73 ovhd=2.29] cov_px_est=605045 overdraw=9.73 cyc_px=2.4 spin_avg=12359 to=0
```

**Flag, not previously called out**: `cyc_px=2.4` here is *lower* than
title's `cyc_px=7.5` even though `cov_px_est` is *higher* (605,045 vs
124,840) — `cyc_px = dpath_ms × clk_sys ÷ cov_px_est`, a fixed-rate
rasterizer's per-pixel cost, cannot fall as the numerator's workload grows;
a falling cyc/px against rising claimed coverage means the coverage
estimate's denominator is inflated, not that the fabric got faster per
pixel. That is exactly what the discussion originally in this slot
concluded (the no-clip `cov_px_est` estimator over-counts scrolling content
with off-screen parallax layers) — this document just didn't name the
falling-cyc/px signature as the tell. It also means `cov_px_est=605,045` /
`cyc_px=2.4` above should not be read as this scene's true throughput
figure; see the sweep below, captured after the estimator was actually
fixed, for the trustworthy numbers.

## Reissued trust-gate evidence (post-fix within-run sweep)

The above two-point title-vs-gameplay comparison used engine `70b4126`,
which gates `cov_px_est` on `GMLOADER_MFSUBMIT_STAT` but does not clip it —
the exact limitation flagged in the paragraph this section replaces. That
was fixed two commits later in `ef93d4c` ("fix: rect-clip the covered-pixel
estimator instead of per-triangle clamping"), the same engine build the
budget document (`2026-07-28-ingame-frame-budget.md`) measures against. This
document was never reissued against that fix — it kept citing the pre-clip
`605,045`/`9.73`/`2.4` numbers while the budget document, correctly, cites
different numbers for nominally the same gameplay scene. That inconsistency
is closed here with a genuine within-run sweep pulled from
`bench-results/20260728-ingame-run1.log` (`ef93d4c`, rect-clip fix active,
same RBF/tree hash as above), spanning the scene's natural intro/settle
transition rather than resting on any single before/after pair:

| cov_px_est | dpath ms | dpath cyc/px |
|---|---|---|
| 88,633 | 7.04 | 7.82 |
| 124,507 | 9.50 | 7.51 |
| 182,661 | 14.72 | 7.93 |
| 213,358 | 16.05 | 7.41 |
| 246,165 | 20.87 | 8.35 |

(Verified line-by-line against `bench-results/20260728-ingame-run1.log`:
`n=1920`, `n=90`, `n=2520`(-`2880`, the settled `tris=216` window), `n=1830`,
`n=2430` respectively; `dpath cyc/px` recomputed independently from each
row's `dpath ms`/`cov_px_est` and matches the log's own `cyc_px` field to
rounding in every row.)

This is a **2.78x** range on `cov_px_est` (88,633 → 246,165) within one
continuous run of one scene — far stronger evidence than the original
title-vs-gameplay comparison (which spanned two different scenes and, per
the correction above, one contaminated sample) — and `dpath ms` **tracks it
throughout** (7.04 → 20.87ms, a 2.97x move, same direction, same order of
magnitude), while the derived `dpath cyc/px` stays in a tight band
(7.41–8.35, spread 11% around a ~7.8 mean) **with no falling-cyc/px episode
anywhere in the range** — the physical-impossibility signature flagged above
does not recur once the estimator is clipped. This is decisively consistent
with `tri`/`dpath` tracking real per-pixel fabric work as coverage varies
continuously, not with a flat/scene-insensitive counter (the original 2026-07-17
symptom) and not with an estimator artifact reappearing.

**On the residual ~2-3x gap** originally raised against the pre-clip
comparison (cyc_px 7.5 at "title" vs 2.4 at "gameplay"): with the estimator
now clipped, that gap has closed — the reissued sweep's `dpath cyc/px` sits
in a single tight 7.4–8.3 band across the whole coverage range, not two
disjoint per-scene values 3x apart. That confirms the original hypothesis
(no-clip `cov_px_est` inflation, not an RTL/counter defect) rather than
merely asserting it from a same-value rebuild check.

**TRUST GATE: PASS**, reissued. The within-run sweep on the fixed
(`ef93d4c`) engine shows `dpath ms` tracking `cov_px_est` by a real,
same-order-of-magnitude, monotonic factor across a genuine 2.78x coverage
range inside one scene, with `dpath cyc/px` stable and never inverted. This
supersedes the original pre-clip title/gameplay comparison, which is
retracted above (title sample contaminated by drift) and superseded here
(gameplay sample built on an estimator later shown to over-count). The
original conclusion — the RTL counters are live, workload-tracking, and not
the H1-H4 defect pattern — is unaffected by either correction; the estimator
issue was always host-side C++, never the RTL counters.

## Is Task 7 (RTL counter fix + Quartus build) required?

**No.** All four hypotheses that could have indicted the RTL counters
resolved favorably: H1 refuted (live counters, not debug latches), H3
refuted (workload-tracking, not vblank-quantized), H4 refuted (no
publish/read race). H2 (dual-engine contamination) is a **process/launch**
defect already fixed by the sole-instance discipline (`mister_run.sh`'s
per-sample `assert_sole_engine`), not an RTL defect. The trust gate passes
on real device data with a rebuilt, verified engine. The one open item at
the time this section was written — the `cov_px_est` estimator's
no-clipping inflation — was a host-side C++ refinement (add per-triangle
clipping in `mf_cov_add_triangle`, `raster_backend_mfgpu.cpp`), not an RTL
change; it has since landed (`ef93d4c`, "fix: rect-clip the covered-pixel
estimator instead of per-triangle clamping") and is the engine build the
"Reissued trust-gate evidence" section above measures. None of this blocks
using `tri_ms`/`dpath` as the throughput metric per `blitter_top.sv:861`'s
own guidance (`tri_cyc/covered` is the true metric; `dpath` is only a
conservative proxy already known to differ from it).

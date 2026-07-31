# In-game frame budget and the 60fps decision gate

Task 8 (final task, Phase 0). Captures a real Maldita Castilla gameplay frame
budget under the trusted instrument (Tasks 5+6, `TRUST GATE: PASS`,
`docs/superpowers/investigations/2026-07-28-fabric-ms-insensitivity.md`) and
closes with the arithmetic statement of what 60fps requires. Branch
`perf/60fps-phase0-diagnostics`.

## Provenance

- **Device**: `root@192.168.20.81`. Exactly one `Master_Daemon` and one
  `gmloader` engine asserted before and after every run
  (`ps | grep -c "[M]aster_Daemon"` = 1 throughout; `[.]/gmloader` count = 1
  at every per-second sample inside the sampling windows below).
- **RBF**: `/media/fat/_Other/MalditaCastilla_476a422.rbf`, device md5
  `86136eb5d956f3ba27112d7635efd608`. `fpga/` tree hash
  `34a4251fe9d5cd5e4b2eeda530214b05273b7f54` (`git rev-parse HEAD:fpga` in
  `maldita.castilla-mister`, HEAD `e373e2f`) — unchanged from the Task 6 trust
  gate.
- **Engine**: `gmloader-next` HEAD `ef93d4cfcd645903ecf1ab43ca2f62e5e0e600aa`
  ("fix: rect-clip the covered-pixel estimator instead of per-triangle
  clamping"), the commit named in the Task 8 brief's established facts.
  **Deviation recorded explicitly, same class as Task 6's**: the binary
  already on the device (mtime `Jul 28 15:35`) predated this commit's commit
  timestamp (`15:41:07`), i.e. it was still running the pre-clip
  coverage-estimator code. Rebuilt via the documented Docker ARM
  cross-toolchain (`gmloader-armhf-build:bullseye`, `Makefile.gmloader
  ARCH=arm-linux-gnueabihf MISTER_BUILD=1 MISTER_NATIVE_VIDEO=1`, working tree
  otherwise clean apart from untracked build artifacts / the `3rdparty/mfgpu`
  submodule pointer) and redeployed to
  `/media/fat/games/gmloader/gmloader` (md5 `31d612824af8a7474425dc06ade4827e`,
  matching the local build output byte-for-byte) before any of the three runs
  below.
- **Scene script**: `scripts/scenes/ingame-stage1.joy`, md5
  `7cc028e395085ef5ed37a152f42e999d`, copied to the device unmodified as
  `/media/fat/games/gmloader/scene.joy`. Persistent Sword presses every 2s
  from t=20000ms to t=64000ms, then `joy_script` reports
  `JOYSCRIPT settled t=72000ms mask=0x000 capture-may-begin`.
- **Launch discipline** (per run): kill any live engine → `load_core
  /media/fat/menu.rbf` (clears the loaded-core state so the next `load_core`
  is not a no-op) → start `./joy_script /dev/shm/maldita-joy scene.joy` in the
  background → immediately `echo "load_core
  .../MalditaCastilla_476a422.rbf" > /dev/MiSTer_cmd` → poll for the engine
  → wait for the script's `settled` line (~78s total) → screenshot →
  20s sampling window asserting `[.]/gmloader` count == 1 every second → pull
  the log → teardown (kill engine, remove `bench.env`). `bench.env` staged
  each run with exactly the four brief-specified exports:
  `GMLOADER_BLITTER=2`, `GMLOADER_RASTER=mfgpu`, `GMLOADER_BLITTER_PROF=1`,
  `GMLOADER_MFSUBMIT_STAT=1`.
- **Run logs**: `bench-results/20260728-ingame-run1.log`,
  `-run2.log`, `-run3.log`.
- **Correction pass (review, this revision)**: two interpretations below were
  wrong — `wait_ms` is not the host-observed frame period (it is timed from
  the SAME edge the fabric's own `frame` counter is, `raster_backend_mfgpu.cpp:637`
  starts the clock right after the `C_SUBMIT` doorbell write), and the
  vsync-quantization test compared the wrong quantity (`frame`/`tri` are
  busy-cycle accumulators gated `if (!idle)`, `blitter_top.sv:853` —
  structurally incapable of being vsync-quantized). Both are fixed below with
  a real wall-clock measurement: `GMLOADER_DRAW_TRACE=1` (existing
  instrumentation, `gmloader/mister/draw_trace.cpp`, previously not enabled
  for this phase) added to `bench.env` and one additional device run,
  `bench-results/20260728-165609---preset_fabric.log`, same engine binary
  (`ef93d4c`, md5 `31d612824af8a7474425dc06ade4827e`, reverified unchanged on
  device before this run — no engine rebuild was needed since
  `GMLOADER_DRAW_TRACE` support already existed in that binary, only gated
  off by default), same RBF, same scene script, driven via
  `scripts/mister_run.sh bench --scene ingame-stage1 --preset fabric` (the
  new `--scene` flag, added this revision — see Reproducibility below).
- **Scene confirmed by screenshot, every run**: `echo screenshot >
  /dev/MiSTer_cmd`, newest file in `/media/fat/screenshots/Maldita Castilla/`.
  All three (`20260728_154942-screen.png`, `_155210-`, `_155436-`) show the
  same in-progress gameplay frame — "CHAPTER I / COLOVERA DEL REY" banner,
  HUD with `P1-SCORE`, `LIVES x3`, `SPEEDRUN 00:05/00:05/00:06`, `HI-SCORE`,
  `TIME 199` — not the gmloader overlay menu (which would read `tris≈168`,
  not the `216` seen below).

## Determinism gate

**Restated (review pass) on the terminal settled window, not the whole log**:
the whole-log statistic below was computed per the brief's literal command
(`grep -o 'tris=[0-9]*' | mean`), but that command averages over the
boot/intro/settle transition too — a period that is deterministic in
*content* (same script, same button-press schedule) but not in *duration*
(scp/ssh/EGL-init jitter shifts exactly where each 1-second sample lands on
that transition, run to run), so a few-percent spread there is measuring
launch-timing jitter, not scene nondeterminism. The gate this document
actually needs — is the measured *scene* reproducible? — is answered by the
terminal window instead: every run converges to a single frozen value,
`tris=216`, `draws=12`, `culled=0`, on **every** sample in **every** run
(`n=13` run 1, `n=13` run 2, `n=15` run 3), with one single-frame transient
per run (the frame the idle pose finishes settling — see Budget table note)
immediately before it. Spread on the terminal window is **0** (not a
percentage — the value is bit-identical across 41 samples spanning three
independent launches). **PASS**, and a stronger pass than the whole-log
figure suggests: this is the actual scene the Budget table below measures.

For completeness, the brief's literal whole-log command (including
boot/intro/settle):

| run | log | mean tris | n samples |
|---|---|---|---|
| 1 | `20260728-ingame-run1.log` | 176.392 | 97 |
| 2 | `20260728-ingame-run2.log` | 173.072 | 97 |
| 3 | `20260728-ingame-run3.log` | 174.896 | 96 |

Range 173.072–176.392 (spread 3.32) against a grand mean of 174.79 = **1.9%
spread, inside the ±5% gate.** The per-run `tris=` value histograms
(8→280 across intro/settle frames) are near-identical run to run, consistent
with the same script driving the same deterministic transition sequence at
slightly different wall-clock offsets — corroborating, not superseding, the
terminal-window result above.

## Budget table (steady-state gameplay, `tris=216`, transient excluded)

One settle-transient sample per run (the single frame where the character's
idle animation was still mid-pose: `frame` 25.17–25.71ms, `cov_px_est` up to
220,311 vs the settled 182,661) is excluded from this table and reported
separately below — it is a one-frame animation-settle artifact, not scene
noise, and folding it in would mislabel a real, understood, single-sample
event as steady-state spread.

| field | run1 mean | run2 mean | run3 mean | grand mean | cross-run spread |
|---|---|---|---|---|---|
| `frame` (fabric, ms) | 20.7854 | 20.7862 | 20.7867 | **20.786** | 0.0013 |
| `tri` (fabric, ms) | 18.4969 | 18.4969 | 18.4973 | **18.497** | 0.0004 |
| `texwait` (fabric, ms) | 3.7700 | 3.7708 | 3.7707 | **3.771** | 0.0008 |
| `dpath` (fabric, ms) | 14.7200 | 14.7200 | 14.7200 | **14.720** | 0.0000 |
| `ovhd` (fabric, ms) | 2.2900 | 2.2900 | 2.2900 | **2.290** | 0.0000 |
| `wait_ms avg` (host, ms) | 20.8454 | 20.9523 | 20.9500 | **20.916** | 0.1069 |
| `cov_px_est` (px) | 182,661 | 182,661 | 182,661 | **182,661** | 0 |
| `overdraw` (logged) | 2.94 | 2.94 | 2.94 | **2.94** | 0.00 |
| `cyc_px` (logged, dpath basis) | 7.9 | 7.9 | 7.9 | **7.9** | 0.0 |
| host `raster` (ms) | 1.6692 | 1.4462 | 1.5200 | **1.545** | 0.2231 |
| host `logic` (ms) | 4.7077 | 3.3538 | 4.6067 | **4.223** | 1.3538 |
| `tris` | 216 | 216 | 216 | 216 | 0 |
| `draws` | 12 | 12 | 12 | 12 | 0 |

The RTL-side numbers (`frame`/`tri`/`texwait`/`dpath`/`ovhd`/`cov_px_est`)
are reproducible to rounding across all three independently-launched runs —
this is the payoff of the Task 6 trust gate: the counters track a fixed
scene deterministically rather than drifting or freezing on stale values.
The host-side numbers (`raster`, `logic`, `wait_ms avg`) carry real run-to-run
spread (`logic` ranges 3.35–4.71ms, a 32% swing on its own mean) — small in
absolute terms next to the ~20.8ms fabric budget, but real, and reported
here rather than averaged away.

**Settle-transient, for the record** (one sample per run, excluded above):
run1 `frame=25.17 cov_px_est=216132`; run3 `frame=25.71 cov_px_est=220311`;
run2 had no such sample inside its captured window (its window started one
sample later). Consistent with a single frame where the idle-pose sprite was
still mid-transition — real, understood, and not folded into the headline.

## Derived numbers, with spread

- **Overdraw** = `cov_px_est ÷ (288×216)` = 182,661 ÷ 62,208 = **2.9363**
  (matches the logged `overdraw=2.94` to rounding — internal consistency
  check passes).
- **`cyc_px`, dpath basis (conservative proxy, `blitter_top.sv:861`)** =
  `dpath_ms × 98,437.5 ÷ cov_px_est` = 14.72 × 98,437.5 ÷ 182,661 =
  **7.93 cyc/px** (matches the logged `cyc_px=7.9`). Spread across runs:
  0.0 (dpath and cov_px_est are both frozen at rounding precision).
- **`cyc_px`, tri basis (the metric `blitter_top.sv:861` calls the *true*
  wall-clock throughput, `tri_cyc/covered`)** = `tri_ms × 98,437.5 ÷
  cov_px_est` = 18.497 × 98,437.5 ÷ 182,661 = **9.97 cyc/px** — **26% higher**
  than the dpath proxy. The gap is `texwait` (3.77ms of the 18.50ms `tri`
  phase, 20%): real per-pixel stall time the dpath-only proxy excludes by
  construction (`blitter_top.sv:861`'s own comment: dpath undercounts
  because the A/B pipeline overlap means some `B_WAIT` cycles are still
  "productive address-gen work" on the A side, but texwait cycles are real
  wall-clock time the pixel is not landing). **This report uses the tri-basis
  9.97 cyc/px as the true throughput figure and the dpath-basis 7.9 cyc/px as
  the conservative proxy, per the source's own guidance — both are given
  everywhere below so neither reading is silently preferred.**
- **Serialization factor — arithmetic retained, framing corrected below.**
  This was originally computed as `frame_time ÷ max(host_logic,
  fabric_busy)`, treating `wait_ms avg` as the measured host-observed
  frame_time. **It is not**: see "Serialization verdict — CORRECTED" below —
  `wait_ms` and the fabric's `frame` counter bracket the same submit-to-
  `C_DONE` interval by construction, so this ratio being ≈1 is a
  consistency check between two clocks on one interval, not a measurement of
  host/fabric overlap. The arithmetic itself is unaffected and kept for the
  record:
  `frame_time ÷ max(host_logic, fabric_busy)`,
  using `wait_ms avg` as the (mislabeled) frame_time and the
  fabric's own `frame` counter as `fabric_busy`:

  | run | wait_ms (frame_time) | fabric `frame` | host `logic` | max(logic,fabric) | factor |
  |---|---|---|---|---|---|
  | 1 | 20.8454 | 20.7854 | 4.7077 | 20.7854 | **1.0029** |
  | 2 | 20.9523 | 20.7862 | 3.3538 | 20.7862 | **1.0080** |
  | 3 | 20.9500 | 20.7867 | 4.6067 | 20.7867 | **1.0079** |

  Mean **1.0062**, spread **0.0051** (1.0029–1.0080). Robust to whether
  `host_logic` is taken as `logic` alone or `raster+logic` combined — even
  the combined host-CPU figure (1.45–2.30 + 3.35–4.71 ≈ 4.8–6.4ms) never
  approaches the ~20.79ms fabric term, so `max(...)` is `fabric_busy` in
  every single sample of every run, not just on average.

## Serialization verdict — CORRECTED (was inverted)

**The original verdict below was wrong.** It read `wait_ms` as the
host-observed per-frame wall time and, finding it tracked the fabric's own
`frame` accumulator to ~0.6%, concluded the two overlap (`max`, not `+`).
That is a near-tautology, not a finding: `mf_device_submit`
(`raster_backend_mfgpu.cpp:630-637`) starts its clock (`t0`) **immediately
after** the `C_SUBMIT` doorbell write and stops it (`mf_submit_stat`) when
`C_DONE` matches — the identical interval the fabric's own `perf_frame_cyc`
measures from the RTL side (`blitter_top.sv:853`, `idle` clears the same
cycle the FSM leaves `S_POLL_SUBMIT` on a new submit, i.e. the same edge
`C_SUBMIT` triggers). Two clocks bracketing the same interval will agree to
rounding *by construction* — `wait_ms ≈ frame` says the two measurements are
consistent with each other, not that host work overlaps the fabric.

The actual pipeline is strictly serial, confirmed by control flow, not
inferred from timing: `main.cpp:775-777` brackets `RunnerJNILib::Process()`
(game logic + draw submission) alone; only *after* `Process()` returns does
`main.cpp:779` call `Blitter_PresentDefault()` → `RasterBackend->present()` →
`mf_present` → `mf_frame_end` (`raster_backend_mfgpu.cpp:1563-1594`) →
`mf_device_submit()`, which is where the doorbell gets written and where the
blocking C_DONE poll (`wait_ms`) happens. `Process()` cannot start again for
frame N+1 until this whole chain returns. And `blitter.cpp:700-706`
constructs `BLITPROF`'s `logic` as `process_ns − blitter_time` — the fabric
wait happens entirely *after* the interval `process_ns` covers, so it
appears in neither `logic` nor `raster`. The host time is real and it is not
inside the fabric's window; it is a step the fabric window cannot start
until it finishes.

**This is directly measurable**, and the measurement already existed
(`gmloader/mister/draw_trace.cpp:61-79`, gated on `GMLOADER_DRAW_TRACE=1`,
previously not enabled for this phase) — it just wasn't turned on.
`DrawTrace_FrameEnd` prints `frame = process_ns + capture_ns`, where
`process_ns` brackets exactly `Process()` (main.cpp:775-777) and
`capture_ns` covers everything from there through the return of
`Blitter_PresentDefault()` (main.cpp:826) — i.e. the fabric-offload path's
`capture_ns` **is** `mf_device_submit`'s blocking wait, the same interval as
`wait_ms`, timed independently by a second clock on the host side. Enabling
it and re-running the settled scene once
(`scripts/mister_run.sh bench --scene ingame-stage1 --preset fabric`, engine
unchanged at `ef93d4c`, log `bench-results/20260728-165609---preset_fabric.log`)
gives, over 16 settled samples at the identical `cov_px_est=182,661`/`tris=216`
signature as the Budget table above:

| field | mean | min | max |
|---|---|---|---|
| `DRAWTRACE frame` (ms) | **26.106** | 24.4 | 27.8 |
| `DRAWTRACE capture` (ms) | 21.000 | 20.8 | 23.3 |
| `DRAWTRACE logic` (ms, `Process()` only) | 5.106 | 3.6 | 7.0 |
| `MFSUBMIT wait_ms avg` (ms) | 20.950 | 20.81 | 21.23 |
| `MFSUBMIT tri` (ms) | 18.497 | 18.49 | 18.50 |

`capture` (21.00ms mean) matches `wait_ms` (20.95ms mean) closely, as
expected — they are the same interval, measured twice. **What is new is
`frame` = `logic + capture` = 26.106ms, sitting ~5.1ms above `wait_ms`/`frame`
alone** — exactly the host `Process()` time, measured directly, additively,
not folded into either published counter. Corroborating evidence predates
this run: `bench-results/20260716-113456-fabric-INSTRUMENTED.log` (an
earlier 320×240 fabric config) shows the identical relationship —
`capture=48.9ms` ≈ `wait_ms avg=49.2ms`, and `frame=68.7ms` =
`logic=19.8ms + capture=48.9ms` — this is not a one-off artifact of this
session's build.

**Reading corrected: total observed frame period ≈ `host + fabric`, not
`max(host, fabric)`.** Host CPU work (`Process()`, ~5.1ms measured directly
via `DRAWTRACE logic`, consistent with the Budget table's `raster + logic` ≈
5.8ms from the independent `BLITPROF` accounting) runs strictly serially
*before* the submit, not concurrently with the fabric's busy window — it
cannot, because the submit that starts the fabric's window has not been
issued yet while `Process()` runs. The true measured frame period is
**~26.1ms (~38.3 fps)**, not the ~20.8ms/~48fps this document previously
published. `spin_avg` (~11,600-12,300 cycles/frame) still shows the host
spin-waiting for nearly the entire *fabric* window, which is true and
unchanged — it just isn't the whole frame period. **There is a real
host-side lever here** (host/fabric pipelining — issuing frame N+1's
`Process()` concurrently with frame N's fabric wait, instead of after it) —
see the closing statement.

## Vsync-quantization verdict — CORRECTED (original test was vacuous)

**The original test below was structurally incapable of detecting
quantization**, regardless of what the answer actually is. It compared
`frame`/`wait_ms` — both, as corrected above, brackets of the *same*
submit-to-C_DONE interval — against the scanout period. `frame`
(`perf_frame_cyc`) is a busy-cycle accumulator that only increments `if
(!idle)` (`blitter_top.sv:853`, `idle` is 1 throughout `S_POLL_SUBMIT`); a
counter that stops accumulating the moment the FSM goes idle **cannot**, by
its own construction, include a wait state that happens after it stops —
so "is `frame` vsync-quantized" can only ever answer "no," independent of
whether the real wall-clock delivery rate is quantized. The quantity that
*could* be quantized is the wall-clock frame period, which the corrected
Serialization section above finally measures directly (`DRAWTRACE frame`,
26.106ms mean).

**There is also a specific, real RTL candidate for a quantizing wait, not
previously examined.** `blitter_top.sv:1651` in `maldita.castilla-mister`:

```
S_SNAP_WAIT: if (vs_rise) begin fb_dma_start<=1'b1; snap_guard<=6'd0; state<=S_SNAP_BUSY; end
```

This is an **unconditional per-frame wait for the next scanout vblank**,
sitting between `C_DONE` (written in `S_WR_DONE`, which precedes
`S_SNAP_WAIT`) and the FSM's return to `S_POLL_SUBMIT` (only reached after
`S_SNAP_WAIT` → `S_SNAP_BUSY` → `S_SNAP_DRAIN` complete) — i.e. between
finishing frame N and being ready to accept frame N+1's submit. It is
invisible to both published measurements for the reason each was designed
the way it was: `perf_frame_cyc` resets to 0 the moment `idle` next clears
(`blitter_top.sv:909`, at the *start* of frame N+1, i.e. `S_SNAP_WAIT`'s
cycles for frame N accumulate into the register but are discarded by that
reset before ever being published) — and the host's `wait_ms` timer stops
at `C_DONE`, which fires *before* `S_SNAP_WAIT` begins. Neither counter has
a term for this state; both were built to bracket exactly the interval that
excludes it.

**Does it bind?** The scanout period itself (16.69ms) is **derived, not
measured** — relabeled here (Important 6, review pass): Task 6 read
`H_TOTAL`/`V_TOTAL` out of `openbor_video_timing.sv` (262 lines/frame @
15,700Hz line rate ⇒ 59.92Hz ⇒ 16.69ms) rather than observing scanout
cadence on the device. That is static analysis, not a device measurement,
in a phase whose premise is "stop inferring" — it is left as a derivation
here (not re-measured this pass) because the RTL constants are exact and
board-independent for this core, unlike the timing questions elsewhere in
this document that motivated an actual device rerun; a live check would use
the reader beacon at `0x3BFB0010` or the vblank cadence implicit in the
`DRAWTRACE` wall-clock samples above. Per the instructed test — a delivered
rate at or near `59.92/2 ≈ 29.96fps` (33.38ms) would indicate the vblank
wait is the dominant, rate-setting cost — the measured settled-scene rate is
**~38.3fps (26.106ms mean, `DRAWTRACE frame`)**. `26.106 ÷ 16.69 = 1.564×`
the scanout period: not near 1× (16.69ms/60fps), not near 2× (33.38ms/
~30fps), not near any other low-integer multiple. **Verdict: at the
currently measured rate, `S_SNAP_WAIT` does not bind** — the delivered
period is a real continuous value, not a value quantized up to the next
vblank-multiple. This is a narrower, better-supported claim than the
original "not vsync-quantized" verdict: that one tested a counter that could
never have shown quantization either way; this one tests the actual
wall-clock number against the actual boundary and the boundary the RTL
evidence says to watch, and still comes back negative today.

This has a forward-looking implication the original document did not flag:
`S_SNAP_WAIT` is real, structurally present, and currently slack (mostly
hidden because the frame period is well above one scanout period in either
direction). **If the fabric-throughput lever in the closing statement below
lands and pushes detect→done materially closer to 16.69ms, `S_SNAP_WAIT`'s
up-to-one-scanout-period cost stops being slack and becomes a candidate to
newly bind**, quantizing the delivered rate up to the next scanout multiple
right as the budget approaches its target — worth re-measuring at that time,
not assumed away because it doesn't bind at today's rate.

## Ordinary gameplay is busier than this headline scene

**Worth flagging (review pass), and it strengthens the conclusion, not
weakens it**: the Budget table's headline scene (`tris=216`,
`cov_px_est=182,661`) is the *idle-settled* pose the scripted scene reaches
and holds — a quiescent moment by construction (it's what "settle" means).
The same three runs also pass through busier, still-in-motion gameplay: all
three logs show an identical sample at `tri=26.68 dpath=21.36
cov_px_est=245,346` (`run1.log:1574`, `run2.log:1576` at `cov_px_est=245,334`,
`run3.log:1570` — matching to the pixel across independent launches, the
same reproducibility signature as the headline scene). That is 44% more
`tri` time and 34% more covered pixels than the idle-settled figure this
report leads with. The headline number is not a worst case; ordinary
gameplay costs more than this document's true frame period figure below
already reflects.

## Closing statement

> Fabric raster is 20.79ms detect→done (`frame`, the RTL's total per-frame
> busy accumulator: `tri` 18.50ms + `ovhd` 2.29ms) at 2.94× overdraw and
> 9.97 cyc/px (the `tri_cyc/covered` basis `blitter_top.sv:861` calls the
> true throughput metric; 7.9 cyc/px on the conservative `dpath`-only proxy
> the same comment names). Host CPU work is 5.8ms (4.22ms logic + 1.55ms
> raster-submit, `BLITPROF`; independently corroborated at 5.11ms mean by
> direct wall-clock measurement, `DRAWTRACE logic`) and runs **strictly
> serially before the submit** — `main.cpp:775-779` calls `Process()` to
> completion before `Blitter_PresentDefault()` ever issues the doorbell that
> starts the fabric's window, so this time cannot overlap it. The true
> frame period, measured directly (`GMLOADER_DRAW_TRACE=1`, 16 settled
> samples, `bench-results/20260728-165609---preset_fabric.log`), is
> **~26.1ms (~38.3fps)** — not the ~20.8ms/~48fps this document previously
> published from the `wait_ms≈frame` tautology. The fabric additionally
> waits for a vblank (`S_SNAP_WAIT`, `blitter_top.sv:1651`) after every frame
> before it can accept the next submit; this does not currently bind (the
> measured 26.1ms sits at 1.564× the (RTL-derived, not directly measured)
> 16.69ms scanout period, not near an integer multiple), but it is real,
> structurally present, invisible to every counter this project has
> published, and a candidate to start binding if the fabric term below is
> ever cut far enough to approach 16.69ms.
>
> **60fps therefore requires BOTH**: the fabric to reach ≲16.5ms detect→done
> (`tri` from 18.50ms to ≲14.2ms, ~1.29×, leaving `ovhd` room inside a
> vblank-safe margin under 16.69ms) **AND** host/fabric pipelining so the
> ~5.8ms of `Process()` overlaps the fabric's window instead of preceding it
> — closing only the fabric gap still leaves a ~5.8ms serial host tax on top
> of every frame; closing only the host gap (perfect overlap) still leaves a
> fabric term almost 25% above the pixel-exact 16.69ms budget. **Neither
> alone suffices**, and the ordinary-gameplay figure above says even this
> combined target likely needs more margin than the idle-settled scene
> implies.

**Fabric-throughput lever status, corrected (Important 4, review pass)**:
the previous revision dismissed Lever 1 (texel prefetch, "+2.8%" on its own
A/B) by comparing it to this report's *host* `logic` spread (32% swing on
its mean) — but Lever 1 is a **fabric** measurement, and the applicable
noise floor is this report's own fabric-side spread: `tri` varies by
**0.0004ms (0.002%)** across three independently-launched runs of this same
scene (Budget table above). +2.8% is roughly three orders of magnitude
above that floor — by the fabric's own demonstrated run-to-run stability,
+2.8% is not obviously noise. The conclusion (don't trust that A/B) survives
on different, better grounds: Lever 1 was measured on the **menu scene**
(project memory: `trilist-lever1-prefetch-cache-status.md`), and the same
memory record flags the fabric perf counter used for that A/B as
"scene-insensitive → unreliable" independent of this document's own H1-H4
work. A single-digit-percent result from a contaminated counter on an
unrepresentative scene is not trustworthy regardless of which noise floor
you compare it to — that is the reason to distrust it, not a host-side
spread argument that doesn't apply to a fabric measurement.

**This is not reachable by anything measured or diagnosed so far in this
project — and the corrected numbers make the gap larger, not smaller.**
Closing a ~29% gap on the true fabric throughput metric (`tri` 18.50→≲14.2ms)
*and* pipelining ~5.8ms of host work that has never been overlapped in any
build measured to date is a materially larger, two-part ask than any lever
this phase has shown capable of moving on its own. **60fps at full native
288×216, bit-exact, tear-free is not reachable with the fabric raster path
as currently built; reaching it requires both a fabric throughput
improvement of roughly a third and host/fabric overlap that does not exist
in any measured build, not a diagnostic tweak, and no candidate measured to
date gets either one, let alone both.** Surfacing this now, before funding
another lever on the strength of a within-noise A/B or an uncorrected
tautology, is the deliverable this phase exists to produce.

## Reproducibility (review pass)

The original revision of this document was not reproducible from the
committed tree: `scripts/mister_run.sh` had no scene support at all (the
three original runs' scene-driving steps survived only as prose in the
Provenance section above), and `bench-results/` was untracked and
`.gitignore`d only implicitly (not listed, but also not committed) — the
three logs cited as this document's primary evidence were not actually in
the repo. Both are fixed this revision:

- `scripts/mister_run.sh` gained a `--scene NAME` option (`bench`/`launch`
  both) that stages `scripts/scenes/NAME.joy` plus the `joy_script` binary
  (built from the sibling `gmloader-next` checkout) and starts the
  scripted-input driver before `load_core`, matching the ordering
  requirement `joy_script.c` documents (the shm transport latches on the
  engine's first input poll and is never re-checked). The correction-pass
  run above (`bench-results/20260728-165609---preset_fabric.log`) was driven
  through this flag, not ad hoc, as a live test of the fix.
- `bench-results/` is now `.gitignore`d by default (most logs are ad hoc,
  local-only working files) with an explicit allowlist for the three Task 8
  logs this document cites as provenance (`20260728-ingame-run{1,2,3}.log`),
  which are committed.
- `gmloader-next/tools/joy_script.c` had a separate bug found in the same
  review pass (Important 5, not specific to this document but load-bearing
  for trusting any future `--scene` run): it never cleared its shm file's
  `magic` word or unlinked the file on exit, so a bench session left a live,
  frozen-mask shm file on the device that the *next production launch*
  would silently latch onto (`input.cpp:307-319` latches the input
  transport once and never re-checks) — the same failure class as the
  project's recorded "input death" incident. Fixed: `magic` is cleared
  before `munmap()` and the file is `unlink()`-ed on every exit path,
  including the signal path (`SIGINT`/`SIGTERM` already funnel into the same
  cleanup code). `mister_run.sh`'s `teardown()` also now removes
  `/dev/shm/maldita-joy` directly as a second, independent safety net.

## Provenance recap

- RBF: `MalditaCastilla_476a422.rbf`, `fpga/` tree `34a4251fe9d5cd5e4b2eeda530214b05273b7f54`.
- Engine: `gmloader-next` `ef93d4cfcd645903ecf1ab43ca2f62e5e0e600aa`, rebuilt and redeployed this session (device md5 `31d612824af8a7474425dc06ade4827e`).
- Scene script: `scripts/scenes/ingame-stage1.joy`, md5 `7cc028e395085ef5ed37a152f42e999d`.
- Engine count: 1 at every sample, every run. Master_Daemon count: 1, checked before and after every run.
- Logs: `bench-results/20260728-ingame-run1.log`, `-run2.log`, `-run3.log`.
- Screenshots: gameplay confirmed for all three runs (Chapter I / Colovera del Rey, HUD present, `tris=216` — not the ~168-tri gmloader overlay menu).
- **Correction-pass run** (review, this revision): same RBF/engine/scene above,
  `bench.env` with `GMLOADER_DRAW_TRACE=1` added, driven via
  `scripts/mister_run.sh bench --scene ingame-stage1 --preset fabric` (new
  `--scene` flag). Log: `bench-results/20260728-165609---preset_fabric.log`.
  Identified as the same settled scene by the `tris=216`/`cov_px_est=182,661`/
  `draws=12` signature, bit-identical to the three screenshot-confirmed runs
  above — not independently reconfirmed by a fresh screenshot this run (the
  engine was already torn down by the time the log was reviewed); the
  signature match is the corroborating evidence for this run instead. Reached
  a genuine, single, intermittent fabric wedge on the first launch attempt
  this session (`fabric never acked seq=N after 60 frames`, single confirmed
  daemon/engine — the same known device-level stall class recorded in
  `2026-07-28-fabric-ms-insensitivity.md`'s Trust Gate section); retrying the
  launch cleared it, consistent with that prior record.

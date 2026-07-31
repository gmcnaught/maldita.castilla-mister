# Phase 4 Stage A/B — close the host↔fabric coupling on the frozen bitstream

**Date:** 2026-07-30
**Status:** design, approved in conversation 2026-07-30. Supersedes audit §1 (see §2).
**Target:** a locked 59.9228 fps on the quiet scene using the bitstream already
deployed on `.62`.
**Predecessors:** `docs/superpowers/HANDOFF-2026-07-30.md`,
`findings/2026-07-30-phase4-option-space.md`,
`findings/2026-07-30-exposed-cost-audit.md`.

---

## 1. The number this phase is about

Phase 3 shipped 46.3 → 55.6 fps. On the quiet scene **both tracks already clear 60
individually**: fabric compute is 16.20 ms (61.7 fps) and host work is 8–10 ms
against a 16.67 ms budget. The 55.6 delivered is neither track's capability — it is
the ~1.4–1.9 ms of **serialization between them**. Removing it needs no new
bitstream.

Scanout is free-running at 1,642,740 clk_sys cycles = **16.6882 ms / 59.9228 Hz**,
zero spread over 215 samples. That is the period the render loop must fit inside.

---

## 2. Correction to the exposed-cost audit, §1

The audit attributed 1.70 ms to the frame limiter and analysed the mechanism as
"integer `1000/fps` = 16 ms grid, `SDL_Delay` at 1 ms resolution, catch-up branch
sleeps a full `frame_ms`". **That code is `fcap_wait_ticks`
(`gmloader/main.cpp:242-247`), the wall-clock fallback, and it is not in force on
the fabric preset.**

Verified: on the fabric preset the cap resolves to the scanout-gated leaky bucket
(`main.cpp:219-226`, `g_fcap_mode = FCAP_SCANOUT`). The wall-clock fallback appears
only where the scanout counter is unreadable — i.e. `preset_sw` runs
(`bench-results/20260730-131051---preset_sw.log`: *"scanout counter unavailable
after 241 attempts — falling back to the wall-clock cap"*).

The cap's true cost is **already instrumented** by `GMLOADER_FCAP_STAT=1`:

```
FCAP n=1500 waited=325 (21.7%) wait_ms_avg=5.19 mode=scanout
FCAP n=1800 waited=375 (20.8%) wait_ms_avg=5.25 mode=scanout
        (bench-results/20260730-130816---preset_fabric_--godmode.log)
```

0.21 × 5.2 ms ≈ **1.1–1.4 ms/frame**. This is the coupling cost, measured, on the
shipped engine.

**Consequences.** (a) Stage A does not build a limiter histogram from scratch.
(b) The audit's proposed limiter fix (sub-ms accumulation via
`clock_nanosleep(TIMER_ABSTIME)`, catch-up-branch repair) targets non-executing
code and is **not** a Phase 4 lever. (c) Audit §8 item 4 is also stale: a
starvation counter landed 2026-07-30 (`gmloader/mister/mister_native_audio.cpp:83`,
exported at `:355`), though it prints only on change, so "clean" is still reported
as absence of lines.

---

## 3. What the device logs actually indict

Across 8,000+ frames on a constant 12-draw / 216-triangle scene
(`BLITPROF f=… draws=12 tris=216 culled=0`):

| quantity | value | source |
|---|---|---|
| `fabric_ms[frame=]` | **16.20–16.21, invariant** | MFSUBMIT, 30-frame true average |
| `tri / texwait / dpath / ovhd` | 13.88 / 2.46 / 11.42 / 2.32, invariant | same |
| `wait_ms[avg=]` (doorbell→`C_DONE`) | **16.58 → 21.39**, swings per 30-frame sample | same |
| FCAP `waited%` / `wait_ms_avg` | 20.5–24.9 % / 5.13–5.52 ms | FCAP_STAT |

Throughout this document **body** means the render loop's doorbell-to-doorbell
interval, i.e. the `period` of §5.1 — not `RunnerJNILib::Process`, which DRAWTRACE
reports separately.

**The fabric is invariant and the host body is bimodal.** A ~5.2 ms cap wait means
that frame's body finished ~5 ms *before* a scanout boundary; the same run's
`wait_ms` samples exceed the fabric time on other frames. A locked 59.9228 fps
requires the body to be consistently under 16.6882 ms, so **the variance is what
stands between us and the lock — not a mean.**

Stage A's question is therefore: *why is the body variable when the fabric is not?*

---

## 4. Scope and constraints

**In scope:** `gmloader-next` (host engine) only.

**Bitstream frozen** at what is deployed on `.62` (maldita RTL `a723aa5`). No
maldita RTL change in this phase-stage. Rationale: with one half moving, every A/B
attributes cleanly. The corpus records two expensive failures of the opposite
pattern — the audio rate contract shipping its fabric half without its engine half,
and the dual-engine control-block contention.

**Out of scope, deliberately:** the redundant full-screen CLEAR (≥0.795 ms,
`blitter_top.sv:1322-1353`), the 1.53 ms unexplained `ovhd` residual, opaque cull
for the arrival scene, and the f2h-port / LW-bridge reallocation of
`findings/2026-07-30-phase4-option-space.md`. All are RTL and belong to a later
stage. The arrival scene stays at its current ~43 fps this stage; it is measured,
not gated.

**Device conventions** (from prior phases, not re-derived here): `.62` is the test
device and `.81` is production; `make` defaults `HOST` to `.62`; engine deploy is
scp-to-`gmloader.new` → `mv -f` → `killall -9 gmloader`, never a hand-launch;
`mister_run.sh` auto-retries the frame-1 fabric wedge and exits non-zero on a
post-hoc `submit timeout` hit.

---

## 5. Stage A — measure the body

### 5.1 The identity

The period is partitioned into three **consecutively measured intervals**, not into
one measured set plus a residual. The seam, from the code
(`raster_backend_mfgpu.cpp:2264` device path):

```
t_db   doorbell N rung          (mf_device_publish, g_publish_t0 — already stamped)
       ... host runs: cap wait, video_process, update_inputs, Process()/draws ...
t_be   mf_publish_barrier entry (raster_backend_mfgpu.cpp:1150)
       ... mf_device_await blocks on C_DONE ...
t_ar   barrier returns true     (raster_backend_mfgpu.cpp:1163)
       ... mf_device_publish writes the control block, doorbell LAST ...
t_db'  doorbell N+1 rung

period = host + block + pub
   host  = t_be − t_db     everything the host does before it needs the fabric
   block = t_ar − t_be     how long the host actually waited on the fabric
   pub   = t_db' − t_ar    control-block publish + barrier + doorbell
```

| term | definition | measured how | today |
|---|---|---|---|
| `frame` | fabric compute, new-submit detect → done write | `C_DONE.hi` (exists) | 16.20 ms |
| `host` | doorbell → barrier entry, **including** the cap wait | **new** stamp pair | unknown |
| `block` | barrier entry → barrier return | **new** stamp pair | unknown |
| `pub` | barrier return → next doorbell | **new** stamp pair | unknown |
| `period` | doorbell → doorbell | derived, checked | 18.09 (`fps=0`) / 19.79 (capped) |
| `notice` | doorbell notice + `S_SNAP` serialization + DDR visibility | `wait_ms − frame`, **over blocked frames only** | unknown |

**Why `notice` is gated on `block > 0`.** `wait_ms` (the existing MFSUBMIT field) is
`t_ar − t_db`, which contains `host`. When the host arrives at the barrier *later*
than the fabric finished, `block == 0` and `wait_ms` measures the host's lateness,
not the fabric's latency — it is only an upper bound. `notice` is therefore
accumulated only over frames where `block > 0`, and the **fraction of blocked
frames is reported** so a `notice` computed from a small sample is visible as such.
This replaces the earlier `rem` residual: no term in this decomposition is a
leftover. Audit §6.2 records BLITPROF's `logic` bucket silently absorbing a 16.9 ms
deferred await precisely because it was a residual.

`S_SNAP_WAIT`→`S_SNAP_DRAIN` (~158 µs) needs no RTL counter to observe. `C_DONE` is
published at `S_WR_DONE` (`blitter_top.sv:2211-2215`) *before* the snap states
(`:2288`), so the snap delays the fabric acting on the **next** doorbell and
therefore lands inside `notice`.

### 5.2 Changes

All env-gated, zero cost when off, matching the existing `MFSUBMIT` / `FCAP_STAT`
pattern.

1. **A new `MFSEAM` line** carrying `period`, `host`, `block`, `pub`, `notice`,
   `blocked%` — emitted alongside `MFSUBMIT` on the same 30-frame window and
   behind the same existing `mf_stat_on()` knob, so no new env var is introduced
   and the `MFSUBMIT` line stays byte-identical (§5.3 gate 1). The window matches
   `MFSUBMIT`'s because both are true 30-frame averages
   (`raster_backend_mfgpu.cpp:786`), unlike BLITPROF/DRAWTRACE which are 1-in-30
   point samples.
2. **Identity self-check on every print.** If
   `|period − (host + block + pub)| ≥ 0.05 ms`, the line marks itself suspect.
   The three intervals are consecutive, so the identity holds *by construction* on
   a well-formed frame — which is exactly what makes it a useful check: it fires on
   a dropped frame, a lost publish, an unpaired await, or a missed stamp, all of
   which are real hazards in this seam and all of which would otherwise be
   silently averaged away.
3. **Fixed-bucket histograms on `host` and `pub`** — the two terms that can carry
   the bimodality. Not on the cap wait: `FCAP_STAT` already reports it, and
   duplicating it would create two numbers for one quantity.
4. **Fix two `FCAP_STAT` defects** found while reading `main.cpp:317-322`:
   its counters are **cumulative since process start**, not windowed, so
   `waited=375 (20.8%)` at `n=1800` is a lifetime average that cannot show the
   ratio changing over a run; and the wait is timed with `SDL_GetTicks()`
   (`main.cpp:305`), a 1 ms quantum, which is too coarse for a term the gate needs
   to see fall below 1 ms. Make the window 300 frames and time it with
   `clock_gettime(CLOCK_MONOTONIC)`.
5. **`MisterAudio_StarvedFrames()` folded into the `FCAP` line in `main.cpp`**, not
   the `MFSUBMIT` line — `main.cpp` already includes `mister_native_audio.h:34`,
   whereas the backend translation unit is not linked against the audio module in
   the host tests and would fail to link.

### 5.3 Instrument gates

- With every new env var unset, the `MFSUBMIT` line is byte-identical to today's.
- The identity closes to < 0.05 ms on a clean run.
- Enabling the instruments does not move `period` by more than 0.05 ms
  (measure with them on and off; an instrument that changes the thing it measures
  is the failure mode `GMLOADER_MFGPU_TRACE` already demonstrates at 0.9–2.9 ms).

### 5.4 Run protocol

`.62` via `mister_run.sh`, fabric preset, `GMLOADER_FCAP_STAT=1`. Two configs
back-to-back — cap ON (`mode=scanout` confirmed in the log) and `GMLOADER_FPS=0` —
capturing quiet **and** arrival in the same session. 3 runs to absorb the frame-1
wedge retry. Baseline to beat: period 18.09 (`fps=0`) / 19.79 (capped) from
`findings/2026-07-30-phase3-stage-b-device.md`.

Confirm `mode=scanout` in every capped log before using its numbers. A run that
silently fell back to wall-clock is measuring a different system.

### 5.5 Deliverable

A findings doc giving each term to ±0.05 ms in both configs, the `pub`/`rem`
distributions, and a named cause for the body variance. **Each Stage B lever must
be pre-sized against the specific term it removes; no lever enters Stage B without
one.**

---

## 6. Stage B — remove it

| lever | term attacked | host-only? |
|---|---|---|
| **L1** — eliminate the body variance Stage A names | `pub` / `rem` spread | expected yes |
| **L2** — reduce `notice` | doorbell notice + `S_SNAP` serialization + DDR visibility | **no** if `S_SNAP` dominates → defer to an RTL stage and re-gate |
| **L3** — cheaper publish: fewer control words, batched writes | `pub` | yes (the LW-bridge variant is RTL, out of scope here) |
| **L4** — move `update_inputs` / `video_process` into the window where the fabric is busy | `rem` | yes |

The deferred `C_DONE` await already landed in Phase 2 (`raster_backend_mfgpu.cpp:811`
— the await runs at the top of the *next* frame's publish barrier), so
`Process()`, `video_process()` and `update_inputs()` already overlap fabric
execution in principle. L4 is about what still does not.

### 6.1 Stage B gates

1. **Quiet-scene period ≤ 16.6882 ms sustained**, cap ON, `mode=scanout` confirmed.
2. `MisterAudio_StarvedFrames()` reported and **zero**.
3. Arrival scene measured and **not regressed** against its Stage A number.
4. No producer-side drop signature (`comp_fb_dma.sv:201` discards a submit whose
   `disp_active == published`; rendering faster than 59.9228 Hz is paid-for work
   thrown away, so the target is the lock, never more).

### 6.2 How to read `FCAP` at the gate — write this into the report

At a locked 59.9228 fps the cap will report `waited` near **100 %** with a *small*
`wait_ms_avg`. **That is the success signature, not a cost.**

- high `waited%` + low `wait_ms_avg` → frames are locking to consecutive boundaries;
- low `waited%` + multi-millisecond `wait_ms_avg` → frames are *missing* boundaries.

Reading `waited%` as waste optimises in exactly the wrong direction.

---

## 7. Verification and failure handling

- **Instrument correctness before conclusions:** §5.3's three gates run first. If
  the identity does not close, Stage A stops and fixes the decomposition rather
  than reporting terms.
- **Frame-1 fabric wedge:** `mister_run.sh` detects `submit timeout`, retries up to
  3×, and re-greps the pulled log post-hoc, exiting non-zero on a hit. A wedged run
  cannot be mistaken for a clean one. A retry clears it; a reboot does not.
- **Two engines on one control block:** never hand-launch after a deploy. The
  handler `exec`s, so `killall -9 gmloader` is what starts the new binary.
- **Point-sample instruments:** BLITPROF and DRAWTRACE reset their accumulators
  every frame but print 1-in-30, so their medians are not means and must not be
  added to fabric terms. Only `MFSUBMIT` and `FCAP_STAT` are true averages.

---

## 8. Risks — what would invalidate this design

- **`notice` dominates.** If `wait_ms − frame` turns out to be mostly `S_SNAP`
  serialization or DDR visibility, no host-only lever reaches the gate and Stage B
  must re-gate as an RTL stage. This is an accepted, planned-for outcome of Stage
  A, not a failure — it is the reason Stage A exists.
- **The residual `rem` is the whole story and is irreducible.** Then the body
  cannot fit 16.6882 ms with fabric at 16.20, and the phase's conclusion is that
  the fabric must come down first (CLEAR cull, `ovhd` decomposition), which is the
  deferred RTL stage.
- **The variance is scene- or input-driven** rather than structural, in which case
  a quiet-scene lock is achievable but says little about gameplay. Arrival is
  measured every run for exactly this reason.

---

## 9. Provenance

Code read at `gmloader-next` `36de92a` (master) and the maldita RTL at `a723aa5`.
Device logs: `mister-gmloader/bench-results/20260730-130816---preset_fabric_--godmode.log`,
`20260730-125137---preset_fabric_--godmode.log`,
`20260730-151333---preset_fabric.log`,
`20260730-131051---preset_sw.log`,
`20260730-111518---preset_fabric_--godmode.log`.
Prior analysis: `findings/2026-07-30-exposed-cost-audit.md` (§1 superseded here,
§2–§8 intact), `findings/2026-07-30-phase3-stage-b-device.md`,
`findings/2026-07-30-phase4-option-space.md`.

# Phase 2 baseline — post-Phase-1 re-baseline on .62

**Date:** 2026-07-29
**Stack:** RBF `MalditaCastilla_cd4d9f1.rbf` (milestone-a @ cd4d9f1), engine
`gmloader-next` master @ 675f190 (godmode linked), device `.62` (host `misterCade`).
**Protocol:** `mister_run.sh bench --secs 120 --scene ingame-stage1 --preset fabric
--godmode`, daemon-path launch, sole-engine asserted every sample. Scene confirmed by
288×216 screenshot inside the measurement window. True period measured by C_DONE
(`0x3B000028`) delta over ≥30 s of confirmed gameplay — NOT `wait_ms`, NOT DRAW_TRACE.

## Reading the instruments (verified against source, `raster_backend_mfgpu.cpp:772`)

- `MFSUBMIT n=K` lines are **30-frame windowed averages** (sums reset each print), so
  per-window medians are honest scene-local numbers.
- The input script is deterministic and the game follows it deterministically: the
  fabric-side medians of two runs matched to 0.01 ms (logs md5-distinct; host-side
  `wait_ms`/DRAW_TRACE differ run-to-run as expected).
- With Phase 1 host pipelining, DRAW_TRACE `frame=` is host work only and **no longer
  equals the frame period**; the period must come from the C_DONE delta.
- Gameplay window: scene arrival ≈87 s after bench start; extraction uses the last 60
  MFSUBMIT windows (≈last 49 s), which sit entirely inside confirmed gameplay.

## Quiet scene (`ingame-stage1.joy`, Chapter I standing pose) — the apples-to-apples row

Medians over the last 60 windows; Phase 0 column is the `.81` pre-Phase-1 handoff
budget (same scene, same script).

| Metric | Phase 0 (.81, pre-P1) | Phase 2 run 1 | Phase 2 run 2 | Phase 2 run 3 |
|---|---|---|---|---|
| Fabric `frame` ms | 20.79 | 19.30 | 19.30 | 19.30 |
| `tri` ms | 18.50 | 17.01 | 17.01 | 17.01 |
| `dpath` ms | 14.72 | 13.59 | 13.59 | 13.59 |
| `texwait` ms | 3.77 | 3.42 | 3.42 | 3.42 |
| `ovhd` ms | 2.29 | 2.29 | 2.29 | 2.29 |
| covered px | ~182.9k (est) | 182,661 (exact) | 182,661 (exact) | 182,661 (exact) |
| overdraw | 2.94 (est) | 2.94 | 2.94 | 2.94 |
| cyc/px | ~8.0 | 7.3 | 7.3 | 7.3 |
| host DRAW_TRACE ms | 5.3 (process, serial) | 16.2 | 16.0 | 17.0 |
| `wait_ms` (avg) | — | 19.67 | 19.68 | 19.68 |
| **True period ms (fps)** | 26.1 (38.3) | — | **27.05 (36.97)** | **27.30 (36.63)** |

The fabric columns matching to 0.01 ms across three runs is the determinism property
above, not copy-paste: logs are md5-distinct and the host-side rows differ.
(Run 1's C_DONE delta was not captured — its instrumentation helper fired
post-teardown; run 1 counts via its log only.)

### First-look observations (analysis lands in the open-questions section)

1. **The in-game fabric gain from Phase 1 is small: 20.79 → 19.30 ms (−7%).** cyc/px
   7.3 vs 8.0. The A2 datapath cut (pb 8→6 cyc/px) did not translate ~25% because
   `dpath` is not purely the pb path. Overdraw is unchanged at 2.94 — now exact, the
   old estimate was accurate.
2. **True period is unchanged: 27.05 ms vs Phase 0's 26.1 ms** despite the fabric
   improving. Something other than the fabric term now pins the period —
   host DRAW_TRACE gameplay median is **16.1 ms** (vs 5.3 in Phase 0's accounting)
   and `wait_ms` ≈ 19.7 > fabric 19.3. Mechanism analysis is Task 6's job (host
   overlap question), and the answer likely redefines the lever choice.
3. **The intro scene runs at fabric ≈13 ms, overdraw 2.00** (early windows) —
   scene-sensitivity of the counters is again confirmed.
4. Run validity: every sample asserted exactly one engine; C_SUBMIT/C_DONE health
   check within the window; screenshots show Chapter I HUD at 288×216.

### Device-state incidents during Task 3 (both resolved, both documented hazards)

- `.62` was found running **two Master_Daemon instances** → first launch attempt
  aborted (handler race), and two engines were live. Killed the duplicate daemon
  (kept boot-time PID 788), bounced to menu. One daemon is now the asserted baseline.
- `mister_run.sh` teardown is not a durable idle state: with CORENAME still Maldita,
  the daemon respawns an engine within seconds, and the fresh handler **rotates
  `maldita.log` → `maldita.prev.log`**, which can race the bench's log scp (run 2's
  scp lost; log recovered from `maldita.prev.log`). Follow-up: bounce to menu inside
  teardown, or pull the log before the kill.

## Heavy load — reached, but NOT via a scene script

**Scripted blind input cannot navigate Stage 1.** Three drafts of
`ingame-stage1-busy.joy` (walk-right; +jump; +cycling Up/Action/Sword) all ended with
the hero pinned within a screen of the arrival point — screenshots show him stuck at a
stone bridge, and the fabric counters go dead-constant (19.94 ms, cov 185,140 every
window), the signature of a static pose. Score does increment, so he kills adjacent
enemies; he does not advance. The scene file is kept for the record but is NOT a
sustained heavy scene, and no result in this document depends on it.

Heavy load comes instead from a phase that occurs in **every** run: the Chapter I
arrival transient (windows n≈2310–2520), reproducible across four independent runs:

| | fabric `frame` | `tri` | `texwait` | `dpath` | covered px | overdraw | cyc/px |
|---|---|---|---|---|---|---|---|
| Quiet standing pose | 19.30 | 17.01 | 3.42 | 13.59 | 182,661 | 2.94 | 7.3 |
| **Chapter I arrival** | **25.5** | 23.2 | 5.2 | 18.0 | 245,346 | 3.94 | 7.2 |

## Load sweep — what actually sets the frame period

Four configurations, each with its own fabric counters and its own C_DONE-delta period
(`0x3B000028` sampled ≥30 s apart, or per-second across a window):

| Config | fabric `frame` | measured period | fps |
|---|---|---|---|
| Quiet, textured, capped | 19.30 | 27.05 / 27.30 | 36.6–37.0 |
| Quiet, textured, **uncapped** (`GMLOADER_FPS=0`) | 19.30 | 26.3–28.9 | 34.6–38.0 |
| Heavy, **`--notex`** | 22.34 (texwait 0.00, dpath 20.12) | 28.2–30.0 | 33.3–35.5 |

### The model: period ≈ fabric + ~8 ms exposed host

Host-side buckets in the same windows: BLITPROF `logic` ≈ 6.7 ms, `raster` ≈ 2.8 ms,
`clear` ≈ 16.9 ms. **The `clear` bucket is not clear cost.** `Blitter_OnClear` →
`mf_clear` → `mf_ensure_frame` → `mf_frame_begin`, and Phase 1 B2 put
`mf_device_await` at the top of `mf_frame_begin` — so the frame's first clear absorbs
the entire blocking wait for the *previous* frame's batch, and that wait is billed to
`clear`. That is why `clear` tracks fabric time (≈16.9 vs fabric 19.30) rather than
tracking anything about clearing.

The deferral therefore overlaps only the host work that runs **before** the first
clear. Everything after it — draw emission, present, capture, ≈8 ms — is serialized
behind the fabric:

    period (27.3) ≈ fabric (19.30) + post-await host (~8)

Both sweeps corroborate it: `--notex` raises fabric by 3.0 ms and the period by
~1.5–2.5 ms; uncapping changes neither.

## Open handoff questions — resolved

1. **30 fps cliff: GONE.** Per-second period traces across 45 s show a continuous
   26.3–30.0 ms distribution with no clustering at 16.7/33.4 ms multiples. A1's
   deletion of `S_SNAP_WAIT` holds in the field.
2. **Host overlap: PARTIAL, and the boundary is the first clear.** Not the clean
   `max(fabric, host)` Phase 1 aimed for, and not Phase 0's full serialization —
   `fabric + post-await host`, per the model above. The remaining ~8 ms is the host
   lever's whole size.
3. **cyc/px residual: RESOLVED as an artifact of the estimate.** With the exact
   `perf_covered_px` denominator, cyc/px is **7.3** (7.2 heavy), against ~8.0 on the
   old estimate. Note `--notex` *raises* it to 8.1 with `dpath` 13.59 → 20.12 — the
   texture path is not the net cost sink the old Lever-1 framing assumed.
4. **Scanout period: still derived, NOT measured.** No per-scanout-frame counter is
   exposed to the host; C_DONE counts fabric completions, not scanout. Measuring it
   needs a small RTL counter — bundle into the next Quartus cycle rather than
   spending one on it alone.

### Two hypotheses raised and killed by measurement (recorded so they are not re-run)

- **"Fabric load doesn't affect the period."** Raised from a per-second trace whose
  MFSUBMIT-window-to-wall-clock mapping was assumed, not verified. Refuted: the
  `--notex` sweep moves fabric and the period moves with it.
- **"The frame limiter's catch-up branch adds a full 16 ms sleep per frame."**
  `main.cpp:836-849` genuinely does reset `next_ms = now` when behind and then add
  `frame_ms` unconditionally. But `GMLOADER_FPS=0` (limiter fully disabled) measured
  26.3–28.9 ms against the capped 27.05–27.30 ms — **no difference**. The loop body
  overruns far enough that the delay branch effectively never fires. The defect is
  real; its cost here is zero. Do not spend a lever on it.

## Decision gate

**Target:** 16.69 ms period. **Today:** 27.3 ms quiet / ~33 ms at the Chapter I
arrival. Because period ≈ fabric + ~8 ms exposed host, 60 fps needs **both** terms
fixed; each alone is insufficient — the same structural conclusion Phase 0 reached,
but with a much smaller required fabric cut than its 1.29×.

| Lever | Measured size (quiet) | Ceiling | Notes |
|---|---|---|---|
| **Host: hide the post-await work** | ~8 ms exposed | ~8 ms | Highest value/effort ratio. No Quartus cycle. Move the await later than the first clear, or emit draws into the next-frame arena so nothing after the await is serial. |
| Fabric `dpath` | 13.59 (70% of `frame`) | need only −2.6 ms for the quiet scene | 19.30 → ≤16.67 is **1.16×**; the heavy scene needs 25.5 → 16.67 = **1.53×**, which is the hard case. |
| Fabric `texwait` | 3.42 (18%) | 3.42 | `--notex` shows removing texturing costs more in `dpath` than it saves here. |
| Fabric `ovhd` | 2.29 (12%) | small | ring/clear/setup; already tight. |

**Recommendation:** fund the **host lever first** (Task C-1) — it is ~8 ms, needs no
bitstream, and until it lands no fabric gain can reach the delivered frame rate (which
is exactly what happened to Phase 1: fabric −1.49 ms, period unchanged). Then
re-measure and size the `dpath` lever against the quiet **and** arrival scenes.


---

# Host lever result — measured on `.62`, 2026-07-29

**Landed. Period 27.05–27.30 → 21.02–21.60 ms (36.8 → 46.3 fps), +26%.** RBF
unchanged (`cd4d9f1`); engine `a3688a0`, md5 `da09b747ae57`. 80 s of C_DONE
(`0x3B000028`) sampling, one sample/s, sole engine asserted every second, scene
screenshot-confirmed as Chapter I gameplay at 288×216 with the timer advancing.

| | Phase 1 baseline | Host lever |
|---|---|---|
| **Period median** | 27.05 / 27.30 ms | **21.60 ms** |
| **fps** | 36.6–37.0 | **46.3** |
| Period mean over window | — | 21.02 ms (3799 completions / 79.9 s) |
| Period min–max (per-second) | — | 17.7 – 26.8 ms |
| Fabric `frame` | 19.30 ms | 19.30 ms (unchanged, as intended) |
| `dpath` / `tri` / `texwait` / `ovhd` | 13.59 / 17.01 / 3.42 / 2.29 | 13.59 / 17.01 / 3.41 / 2.29 |
| BLITPROF `clear` | **16.9 ms** | **0.0 ms** |
| BLITPROF `logic` / `raster` | 6.7 / 2.8 ms | 7.0 / 2.5 ms |
| `wait_ms` avg | 19.67 | 21.49 |
| timeouts / drops / reclaims | — | **0 / 0 / 0** (`to=0` across 219 windows) |

**The model held.** Exposed host was ~8 ms; it is now ~1.7 ms (period 21.02 −
fabric 19.30). The `clear` bucket going 16.9 → 0.0 ms is the direct confirmation
that bucket was never clear cost — it was the deferred `mf_device_await` billed to
the frame's first `glClear`, and moving the await to the publish site removed it
from that accounting entirely.

**Corruption check: clean.** Five screenshots across the run; no stale-parity
bands, no garbage geometry, no torn tilemap. Arena guard is correct.

## Two defects the device found that the host suite could not

1. **The await polled the wrong sequence** (`fix(mfgpu): await the PUBLISHED seq`).
   `mf_device_await` compared `C_DONE` against `g_e.submit_seq`. That was correct
   only from its old site at the top of `mf_frame_begin`, before `blt_end_frame`
   bumped the emitter's seq. From the publish barrier it waits for the batch it is
   itself gating — unsatisfiable. First device run: `to=30` of 30, `wait_ms` avg
   205, period **535 ms (1.9 fps)** with the fabric still reporting 19.29 ms. The
   host oracle has no `C_DONE`, so nothing off-device could feel it; it is now
   covered by two seam witnesses asserted in `case_submit_publish_await_split`.

2. **Duplicate `Master_Daemon`** (maldita `deploy.py`). Its restart step ran
   `pkill -f Master_Daemon.sh`, and MiSTer's busybox has no `pkill` (exit 127) —
   the kill was a no-op and the following `nohup … &` added a daemon on *every*
   deploy. Each spawns its own handler, so the core came up with two gmloader
   processes on one control block. `mister_run.sh` correctly refuses to measure
   that ("engine did not come up within 30s" is the sole-engine assertion failing,
   not a slow launch). Replaced with a `/proc` walk plus a post-check that prints
   "Master_Daemon: exactly 1 running". **Any measurement taken between 15:08 and
   15:26 on 2026-07-29 is contaminated and was discarded.**

## Re-gate: what the fabric still owes

With the host term down to ~1.7 ms, period ≈ fabric + ~1.7, so 60 fps (16.69 ms)
now needs fabric ≤ **15.0 ms**:

| Scene | fabric today | needed | factor |
|---|---|---|---|
| Quiet gameplay | 19.30 | 15.0 | **1.29×** |
| Chapter I arrival | 25.5 | 15.0 | **1.70×** |

`dpath` is 13.59 ms of the quiet 19.30 (70%), so the quiet target needs roughly a
**1.4× dpath** cut with `texwait` and `ovhd` untouched — plausible for one RTL
phase. The arrival scene at 1.70× is not reachable by pipelining `dpath` alone and
is the case that decides whether 60 fps needs a different rendering strategy. Size
both before committing to a Quartus cycle.

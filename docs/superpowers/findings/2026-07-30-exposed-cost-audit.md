# Exposed-cost audit — what was "zero" only because the frame was slow

**Date:** 2026-07-30
**Trigger:** Stage B superseded Phase 2's "the frame limiter costs zero. Do not spend a
lever on it" — true at a 27 ms loop body, false at 18 ms, worth **1.70 ms/frame**.
This document is the completeness sweep for the rest of that class, run **before**
Phase 4 unlocks more speed.

**Operating points used throughout.**

| | fabric `frame` | period | fps | source |
|---|---|---|---|---|
| Phase 2 (`cd4d9f1`) | 19.30 | 21.02 – 21.60 | 46.3 | phase2-baseline.md |
| Phase 3 as shipped (`7c0b370`) | **16.20** | **19.79 / 19.69** | **50.5 / 50.8** | stage-b-device.md |
| Phase 3, `GMLOADER_FPS=0` | 16.20 | **18.09** | **55.27** | stage-b-device.md |
| **Next plausible point (Phase 4 gate)** | **14.80** | **16.6882** | **59.9228** | stage-b-device.md "Re-gate" |
| Scanout (free-running, measured) | — | **16.6882** (1,642,740 cyc, zero spread, 215 samples) | 59.9228 | stage-b-device.md |

Quiet-scene fabric gap still to close: **16.20 − 14.80 = 1.40 ms**. Every "share of
the remaining gap" figure below is against that 1.40 ms.

---

## Ranked table — expected cost at the NEXT operating point (fabric ~14.80 / period 16.6882)

| # | Candidate | Mechanism | Size at the next point | Becomes binding when | Evidence |
|---|---|---|---|---|---|
| 1 | **Host frame limiter** | `main.cpp:836-849`; `frame_ms = 1000/60 = 16` (integer), `SDL_GetTicks`/`SDL_Delay` at 1 ms resolution, catch-up branch sleeps a full `frame_ms` after resetting | **≥ 1.70 ms measured today**; regime changes again at a ~16.7 ms body. **Mechanism NOT established** (§1) | Already binding. Regime flips again when the body crosses 16.000 ms | `stage-b-device.md` "the frame limiter, quantified"; §1 below |
| 2 | **Unexplained `ovhd` residual** | Device `ovhd` 2.32 ms vs sim-accounted 0.795 ms — a **1.53 ms fixed per-submit term nobody has decomposed**. Sim is −65 % low on this term | **1.53 ms = 109 % of the entire remaining 1.40 ms gap**; `ovhd` share rises 14.3 % → 15.7 % of fabric | Already binding, and it is the term that does **not** shrink with any datapath lever | `stage-a-sizing.md` §6.1; `stageB-task-1-report.md` §3.2; RTL states in §3 below |
| 3 | **Redundant full-screen CLEAR** | `blitter_top.sv:1322-1353` `S_CLR_FILL`: 62,208 px at ~1 px/cyc, inside `ovhd`. The frame's COPY draws already repaint all 62,208 unique px | **≥ 0.795 ms = 57 % of the remaining 1.40 ms gap.** Device value unmeasured and may be larger | Already binding; share rises as `dpath` shrinks | `stageA-task-5-report.md` §4; `stage-a-sizing.md` §8.1 |
| 4 | **Exposed host tail, undecomposed** | Period − fabric = **1.89 ms** (`GMLOADER_FPS=0`). Contains publish + doorbell + `update_inputs` + `video_process` + loop overhead + the fabric's snap tail. **No instrument covers it** | At the gate, fabric 14.80 + tail 1.89 = **16.69 ms = the scanout period exactly. Zero margin.** Any tail growth costs delivered fps 1:1 | Binding **now** as the thing that sets the 14.80 gate | `stage-b-device.md` "Why the fps prediction missed"; §2 below |
| 5 | **Producer-side drop at 59.9228 Hz** | `comp_fb_dma.sv:201` `if (start && (disp_active == published))` — a surplus submit is **dropped at the producer**, full fabric + host cost already paid | At the limiter's 16 ms grid (62.5 fps) **4.1 % of rendered frames are discarded undisplayed**. Beat period at a 16.60 ms period = one drop per 3.1 s | Binding the moment the render period drops below **16.6882 ms** | RTL read, §4 below |
| 6 | **`S_SNAP_DRAIN` copy tail invisible to `perf_frame_cyc`** | `perf_frame_cyc` is published at `S_WR_DONE` (`blitter_top.sv:2211-2215`), **before** `S_SNAP_WAIT`/`S_SNAP_BUSY`/`S_SNAP_DRAIN`. The 15,552-beat copy ≈ **158 µs/frame** is in the period but not in the `frame` counter | **0.158 ms = 8.4 % of the 1.89 ms tail**; true per-frame fabric-side cost is 16.36 ms, not 16.20 | Already; matters because the tail sets the gate | `blitter_top.sv:2211-2215`, `:2288`; §2 below |
| 7 | **Host await spin → DDR3 pressure** | `raster_backend_mfgpu.cpp:748` `MF_POLL_SPIN_ITERS=2000`, `MF_POLL_US_DEFAULT=0` — an unbounded pure spin of uncached reads at `0x3B000028`, one `clock_gettime` per iteration | **Unsizable without a sweep.** Measured `spin_avg` median **1,976/frame at `--fps 0`** (≈109 k uncached DDR3 reads/s at 55.3 fps) vs 291/frame as shipped | Rises with fps *and* with any fabric/host imbalance; contends with the reader and blitter on the same DDR3 | log extraction, §5 below |
| 8 | **Instrument hazards** | BLITPROF/DRAWTRACE are **1-in-30 point samples, not averages**; `logic` is a **residual** bucket; no periodic audio-underflow counter | Not a ms cost — a wrong-number risk. The shipped-run DRAWTRACE distribution is bimodal (4.7 / 13.0 / 27.1 ms) *because of* the limiter | Already; every Phase 4 host number is read off these | §6 below |
| 9 | **Stationary starvation band** | `f2h_slot_mux.sv:15-31`: the 158 µs copy's phase relative to scanout walks by (T_scan − T_submit) per frame. At T_submit → T_scan it **parks** | **Unsizable.** Character change: a rolling 4-line band becomes stationary and, if parked inside active display, stays there | When the render period sits within ~0.05 ms of 16.6882 ms | RTL read, §4 below |
| 10 | **Frame-counted patience windows** | `raster_backend_mfgpu.cpp:249` `MF_DROP_LIMIT_DEFAULT = 60` **frames** before a forced ring reclaim (a deliberate stomp of a batch the fabric may still be reading) | Wall-clock patience 1.63 s (27 ms) → 1.19 s (19.79) → **1.00 s** at 16.69. Never fired: `to=0` / 0 drops across 1,172 windows | A risk window, not a per-frame cost. Binds only when drops start | `raster_backend_mfgpu.cpp:1128`; `stage-b-device.md` "Correctness" |

---

## 1. The frame limiter — the measured cost is real, the published mechanism is not established

**Observed (code).** `main.cpp:836-849`, verbatim:

```c
static Uint32 frame_ms = 0xFFFFFFFF, next_ms = 0;
if (frame_ms == 0xFFFFFFFF) { const char *fe = getenv("GMLOADER_FPS");
    int fps = fe ? atoi(fe) : 60; frame_ms = (fps > 0) ? (Uint32)(1000 / fps) : 0; }
if (frame_ms) {
    Uint32 now = SDL_GetTicks();
    if (next_ms == 0 || now > next_ms + frame_ms) next_ms = now;
    next_ms += frame_ms;
    if (now < next_ms) SDL_Delay(next_ms - now);
}
```

**Observed (device).** As shipped 19.79 ms; `GMLOADER_FPS=0` 18.09 ms. Δ = **1.70 ms**.

**Observed (new, extracted from the Stage B logs for this audit).** DRAWTRACE `frame=`
(the `RunnerJNILib::Process` span only) over the last two thirds of each run:

| run | n | min | p25 | median | p75 | max | mean | frac < 16 ms |
|---|---|---|---|---|---|---|---|---|
| run 3 (`--fps 0`) | 218 | 15.9 | 16.4 | **16.4** | 16.4 | 42.6 | 17.53 | **1.4 %** |
| run 1 (as shipped) | 190 | **4.7** | 9.4 | **13.0** | 15.3 | 27.1 | 12.78 | **79.5 %** |

Enabling the limiter does not merely add idle time at the end of the loop — it moves
**where the host blocks**. With the limiter off, `Process` is pinned at 16.4 ms ≈ the
16.20 ms fabric time, i.e. it blocks on the fabric. With the limiter on, `Process`
collapses to a 4.7–15.3 ms spread because the preceding `SDL_Delay` already absorbed
the fabric wait.

**Observed (replay).** An open-loop replay of the code above at a constant 18.09 ms
body, with `SDL_GetTicks` truncated to integer ms, gives **34.09 ms** (the catch-up
branch fires every frame because `now − next_ms == B > frame_ms`, and the immediately
following `next_ms += frame_ms` then forces a full 16 ms `SDL_Delay`). The device
measures 19.79 ms. The same replay gives 43.30 ms at Phase 2's 27.3 ms body, against a
measured 27.05–27.30 ms.

**Inferred.** The loop is not open-loop: the `SDL_Delay` overlaps fabric execution, so
most of the sleep is absorbed and only its overhang is additive. That is consistent
with the 1.70 ms, and it is **not** what `stage-b-device.md` states as the mechanism —
"`next_ms` stays pinned to a 16 ms grid, and every frame that finishes early is padded
up to the next grid point" requires the loop body to be under 16 ms, and the measured
unpaced body is 18.09 ms.

**Unknown, and it blocks the proposed fix.** The per-frame `SDL_Delay(next_ms - now)`
distribution has never been observed. The Phase 4 recommendation is "pace to the
measured 16.6882 ms with sub-millisecond resolution". If the dominant term is the
catch-up branch's full-`frame_ms` sleep rather than grid padding, **raising the grid
from 16 to 16.6882 makes that sleep larger, not smaller.**

**Action before sizing the fix:** log a histogram of `next_ms - now` for one run. Then
fix the two defects separately — (a) sub-ms accumulation (`clock_nanosleep(TIMER_ABSTIME)`,
the pattern already correct in `tools/joy_script.c:60`), and (b) the catch-up branch
must **not** sleep a full period after resetting `next_ms = now`.

**Do not ship `GMLOADER_FPS=0`.** The cap exists to stop the GM VM racing (`main.cpp:832-835`),
and §4 shows that running above 59.9228 Hz is discarded work.

---

## 2. Costs hidden behind the fabric — when does the host become the floor?

**Observed.** Phase 2's model, re-verified in Stage B: `period ≈ fabric + exposed host`,
with exposed host **1.89 ms** at `GMLOADER_FPS=0`, against ~1.7 predicted.

**Observed.** Total host work per frame is *not* 1.89 ms — most of it is overlapped.
The unblocked host emit chain is visible as the shipped run's DRAWTRACE minimum and p25:
**4.7 ms floor, 9.4 ms p25**. BLITPROF at `--fps 0`: `logic` 5.9, `raster` 2.3.

**Inferred.** `period ≈ max(fabric, host-emit-chain) + tail`. With the host chain at
5–9 ms, **the host does not become the binding term until fabric falls below ≈ 9 ms.**
The Phase 4 gate is 14.80 ms. **This is a negative result: host work does not become
the floor in Phase 4.**

**But the tail is at zero margin.** 14.80 + 1.89 = **16.69 ms = the scanout period**.
There is no slack in that sum, and the 1.89 ms is a single undecomposed number
containing at least:

* the fabric's own `S_SNAP_WAIT`→`S_SNAP_DRAIN` copy tail, **~158 µs**, which
  `perf_frame_cyc` excludes because it is published at `S_WR_DONE`
  (`blitter_top.sv:2211-2215`); `S_SNAP_DRAIN` (`:2288`) is one of the design's two
  unbounded waits;
* `video_process()` (`main.cpp:773`) and `update_inputs()` (`main.cpp:775`), both of
  which run **before** `_dt_p0` and are therefore outside DRAWTRACE, outside BLITPROF,
  and outside every published number;
* the publish barrier and doorbell write.

**Action:** decompose the 1.89 ms before any Phase 4 document claims 60 fps. A 0.2 ms
error in it moves the fabric gate by 0.2 ms, which is 14 % of the remaining 1.40 ms.

---

## 3. Fixed per-frame costs whose share is rising

**Observed.** `ovhd` = 2.29 (Phase 2) → **2.32 ms** (Phase 3) — flat in absolute terms
while `dpath` fell 13.59 → 11.42 and `texwait` 3.42 → 2.47.

| | of fabric 19.30 (P2) | of fabric 16.20 (today) | of the 14.80 gate | of the 16.6882 period |
|---|---|---|---|---|
| `ovhd` 2.32 ms | 12.0 % | **14.3 %** | **15.7 %** | 13.9 % |
| CLEAR component ≥ 0.795 ms | 4.1 % | 4.9 % | 5.4 % | 4.8 % |

Phase 2's lever table called `ovhd` "already tight". **That call is now wrong twice
over:**

1. **0.795 ms of it is a 100 %-cullable redundant draw.** `stageA-task-5-report.md` §4
   and `stage-a-sizing.md` §8.1: `nontri` = 78,274 cyc = 0.795 ms, dominated by the
   full-screen CLEAR fill of 62,208 px at ~1 px/cyc, while the frame's COPY draws
   already cover 125,568 px over the same 62,208 unique pixels. RTL:
   `blitter_top.sv:1322-1353` (`S_CLR_FILL`/`S_CLR_FILL_WAIT`, `c_w <= FB_W; c_h <= FB_H`),
   dispatched through `comp_pipeline` at 1 px per `fb_wr_en`. It needs a host-side
   coverage guarantee, so it is a contract change, not a pure RTL one — but it is
   **57 % of the entire remaining quiet-scene gap**.
2. **The other 1.53 ms is unexplained.** Sim accounts for 0.795 of the device's 2.32
   (`stage-a-sizing.md` §6.1: sim −65 % low; `stageB-task-1-report.md` §3.2 flags the
   same gap while matching `dpath` to +0.03 %). The RTL states that could hold it are
   all f2h round trips the sim's stub does not model: 7 control-block reads in the
   prologue (`blitter_top.sv:1266-1343`), **4 f2h reads per ring command** ×107 commands
   (`:1365-1379`), 4 control-block writes in the tail (`:2195-2256`), each through
   `S_RD_WAIT`/`S_WR_WAIT`, and `S_WR_THROTTLE` (`:2320-2333`, `throttle_cfg` from
   `C_SRCSEL[15:8]`). **1.53 ms is 109 % of the remaining 1.40 ms gap and it is immune
   to every datapath lever Phase 4 is considering.**

**Action:** measure the device `ovhd` decomposition (it is a counter change, not a
Quartus-cycle-worth of work on its own — bundle it) before spending a Phase 4 lever on
`dpath`.

---

## 4. Quantization and beat effects at the scanout period

**Observed.** Scanout is free-running at 1,642,740 clk_sys cycles = **16.6882 ms**,
zero spread across 215 samples, invariant under render load.

**Observed (RTL).** The producer gate is `comp_fb_dma.sv:201`:
`if (start && (disp_active == published))` — otherwise the start pulse is **dropped**
(`:211-223`, `skip_cnt++`) and the blitter falls through `S_SNAP_BUSY` on
`SNAP_GUARD = 32` cycles (0.33 µs, `blitter_top.sv:2282-2285`). It is a drop at the
producer, never a stall and never a queue. Tear safety is intact three ways: the copy
always targets `~disp_active`; the control word is written only after the whole buffer
is accepted (`:249-269`); the reader latches `buf_base_addr` for the whole frame at
`ST_CHECK_CTRL` (`openbor_video_reader.sv:875`). `active_buffer` can change **at most
once per scanout frame** (`:870`), which is the hard cap on delivery.

**Inferred, and it reproduces the measured numbers exactly.** The repeat/drop rate is
the beat frequency between the render period and 16.6882 ms:

| render period | beat period | outcome | check |
|---|---|---|---|
| 19.79 (shipped) | 106 ms | repeat every ~6.4 scanout frames = **18.7 %** | matches `stage-b-device.md`'s measured 18.7 % |
| 18.09 (`--fps 0`) | 215 ms | **7.7 %** | matches the measured 7.7 % |
| **16.69 (the gate)** | **154 s** | one repeated frame every **~2.6 minutes** | — |
| 16.60 (slightly fast) | 3.1 s | one **dropped** frame every 3.1 s, full render cost paid | — |
| 16.00 (the limiter's grid, 62.5 fps) | — | **4.1 % of rendered frames discarded undisplayed** | — |

**This is the character change the audit was asked for.** Judder goes from a uniform
18.7 % repeat rate to a single hitch every couple of minutes — and crossing to the
fast side converts repeats into *discarded work*. It also means **there is no value in
a render rate above 59.9228 Hz**, which the current `1000/60 = 16` grid (62.5 fps)
would produce the moment the body fits under 16 ms.

**Observed (RTL).** A second, unquantified effect at the same crossing: since
`S_SNAP_WAIT` no longer waits for vblank, the 158 µs copy lands at an arbitrary phase
that advances by (T_scan − T_submit) per frame — ~0.49 ms/frame at 16.20 vs 16.688,
sweeping fully in ~554 ms. **As T_submit → T_scan the phase stops walking and parks.**
`f2h_slot_mux.sv:15-31` documents the artifact class this can expose (a 4-line stale-
linebuf band) and names the reason it is currently harmless: *"drifting because the
fabric frame period is not locked to scanout."* At the gate it stops drifting.
**Unknown** whether the parked phase lands in active display; watch for a stationary
band in Phase 4 screenshots, not a rolling one.

---

## 5. Rate-dependent costs

**Observed (new, from the Stage B logs).** `spin_avg` — poll iterations per
`mf_device_await`:

| run | median | mean | max | polls/s at that run's fps |
|---|---|---|---|---|
| run 3 (`--fps 0`, 55.3 fps) | **1,976** | 1,944 | 3,136 | **≈109,000** |
| run 1 (shipped, 50.5 fps) | 291 | 319 | 918 | ≈14,700 |

Each iteration is an uncached read of `0x3B000028` **plus** a `clock_gettime`
(`raster_backend_mfgpu.cpp:1014-1016`), and the backoff is dead by default
(`MF_POLL_US_DEFAULT = 0`, `:748`). The limiter's sleep is currently masking 85 % of
this pressure. Removing the limiter — which Phase 4 must do in some form — raises it
by 7.4×, onto the same DDR3 the scanout reader's 15,552 beats/frame and the blitter's
ring traffic use. **Unsizable from logs; the cheap probe is a `GMLOADER_MFGPU_POLL_US`
sweep watching whether fabric `frame` moves.**

**Checked and cleared, with the reason:**

* **Scanout starvation from the framebuffer copy does not grow with submit rate.** The
  copy is capped at one per scanout frame by the `disp_active == published` gate, so
  its DDR3 cost saturates at ~158 µs per 16.6882 ms (0.95 % duty) regardless of fps.
* **The reader can never be interrupted mid-burst.** `ddr_blitter_arb.sv:221` lends the
  bus to the blitter only when the reader has zero beats in flight and is not
  requesting; `f2h_slot_mux.sv:180` gives the reader priority over the copy, with a
  1024-cycle anti-starvation escape that grants the copy exactly one beat.
* **The SDRAM texel path cannot starve scanout.** Scanout is entirely on DDR3 now
  (ch4 P_SCAN retired); the SDRAM arbiter's strict priority
  (`jtframe_cache_mux_arb.v:56-80`) only orders STAGE against texel reads.
* **Audio is decoupled from the frame rate.** Free-running pump thread pinned to core 1
  (`mister_native_audio.cpp:130-140`, 1 ms idle sleep only when the ring is at target),
  ring 64 KiB = 341 ms capacity, `kTargetFillFrames = 4800` = exactly 100 ms latency.
  There is no per-frame refill on the gameplay path. The only consequence of higher fps
  is that 100 ms is now 6 frames of buffer instead of 3.7, which matters to nothing that
  exists.
* **Present/capture memcpy traffic is not on the fabric path.** `main.cpp:786-794` is
  `(void)0` for `backend_mfgpu`; the 124 KB `Blitter_ToRGB565` and the ~373 KB
  glReadPixels row-flip are software-path only.
* **Every RTL watchdog has ≥ 20× margin** at a 16.7 ms period: `RW_WD_MAX` 42.61 ms
  (`blitter_top.sv:41`), `FLUSH_QUIET_MAX` 10.65 ms (`ddr_blitter_arb.sv:49`),
  reader `TIMEOUT_MAX` 10.65 ms, `BLT_QUIET_MAX` 10.40 µs, `STARVE_MAX` 10.40 µs,
  `WD_TIMEOUT` 41.6 µs, `SNAP_GUARD` 0.33 µs. `comp_fb_dma`'s `SKIP_MAX = 32` needs 33
  submits inside one scanout period (~2,000 fps) to fire.
* **The stale-frame watchdog is not reachable by judder.** `openbor_video_reader.sv:886-889`
  needs **29 consecutive** stale vblanks ≈ 484 ms; a beat repeat resets it after one.
  It remains a wedge detector.
* **The two-frame texture pin is safe.** `raster_backend_mfgpu.cpp:270`/`:1206-1207`
  pin texture pages for two host frames to cover a fabric batch that is a *time*. Two
  frames at the gate = 33.4 ms against a 14.80 ms batch (21.37 ms at the arrival
  scene) — **2.3× margin, and the margin grows as the fabric shrinks**, because the
  period cannot fall below the fabric time. Binds only if fabric > 2 × period, which
  the `period ≈ fabric + tail` model makes impossible.
* **No perf counter wraps.** All the per-frame `perf_*_cyc` are 32-bit at 98.4375 MHz
  (43.6 s) and reset every frame at `S_CHK_NEW`; a faster submit rate makes them safer.
  `scan_free_cyc`/`scan_period_cyc` wrap (not saturate) at 43.6 s but depend only on
  the free-running timing generator.

---

## 6. Instruments that would now mislead

1. **BLITPROF and DRAWTRACE are 1-in-30 point samples, not averages.** `blitter.cpp:705`
   prints when `g_pf_frame % 30 == 0`, but the accumulators are reset **unconditionally
   every frame** (`:711`); same structure at `draw_trace.cpp:71`. (MFSUBMIT at
   `raster_backend_mfgpu.cpp:816` *is* a true 30-frame average — those numbers are fine.)
   This matters now because the limiter makes the host frame cost **bimodal**: the
   shipped run's DRAWTRACE spans 4.7 – 27.1 ms with a 13.0 median, so a median of point
   samples is not the mean cost and cannot be added to the fabric term.
2. **BLITPROF `logic` is a residual**, `process_ns − (raster + clear + tex)`
   (`blitter.cpp:704`). Anything unaccounted inside `Process` lands in it — exactly the
   failure mode that made Phase 2's `clear` bucket read 16.9 ms when it was really the
   deferred `mf_device_await`. Today `logic` is absorbing the block on the fabric:
   at `--fps 0` its median tracks fabric time (16.4 vs 16.20). **Do not read `logic` as
   host compute.**
3. **`perf_frame_cyc` excludes the snap tail** (§2). The published `frame` is not the
   fabric's full per-submit occupancy.
4. **No periodic audio-underflow counter exists** (`stage-b-device.md` "Correctness";
   `stageB-task-5-report.md` §8). The spec criterion "audio underflow 0.0/s" was checked
   only as absence of log lines. Separately, the only audio cost figure in the corpus —
   `specs/2026-07-28-maldita-60fps-diagnostics-design.md` "Audio pump | host |
   measured ~0" — has **no measurement behind it anywhere**. Both need fixing before
   anyone claims audio is unaffected at 60 fps.
5. **Saturating diagnostic counters**: the reader's `underflow_cnt` is 5-bit and pegs at
   31 (`openbor_video_reader.sv:412`) — read a 31 as "≥31"; `dbg_stuck` saturates at
   170.4 ms. Probe builds only.
6. **The two `devmem` scanout reads are not mutually atomic** (`stage-b-device.md`).
   Harmless while `scan_period_cyc` has zero spread; a straddled pair is possible if it
   ever moves.

---

## 7. Prior "negligible" conclusions re-checked, one by one

| Claim | Where | Period when made | Verdict now |
|---|---|---|---|
| "The defect is real; its cost here is zero. Do not spend a lever on it." (frame limiter) | phase2-baseline.md | 27.05–27.30 ms | **OVERTURNED** — 1.70 ms, and the replacement mechanism is itself unverified (§1) |
| "`ovhd` … already tight" | phase2-baseline.md lever table | 27.05 ms | **OVERTURNED twice** — 0.795 ms is 100 % cullable, 1.53 ms is unexplained (§3) |
| "`S_SNAP_WAIT` does not bind … worth re-measuring at that time" | investigations/2026-07-28-ingame-frame-budget.md | 26.106 ms | **CLOSED by code inspection.** The state constant survives (`blitter_top.sv:173`) but its body is an unconditional pass-through (`:2278`); `vs_rise` is retained with **no consumer** (`:262-271`) and is stripped by synthesis. The 30 fps cliff cannot return. This was the corpus's one explicitly slow-body-conditional claim; it is now discharged |
| "12 off-screen triangles … 0.012 ms … too small to be a Stage-B lever" | stageA-task-5-report.md §3.3 | sim 15.859 ms | **Already flipped, by the project itself.** `stage-a-sizing.md` §8.4: under the span walk an empty row costs ~2 cyc where the bbox scan paid 1, so leaving it "would have **doubled** the waste". Precedent, not an open item |
| "pa never waited on pb, and the FIFO depth was never reached" | stageA-task-7-report.md §1.2 | sim 14.088 ms | **Inverted by the A-chain lever** (pa 7.087 → 1.099 cyc/px). `stage-a-sizing.md` §8.2: raising `TEXFIFO_D` "stops being optional if either candidate lands" — it is a **co-requisite** of Phase 4 candidates A and B, not a separate experiment |
| "one extra qword write/frame … noise"; "`scan_free_cyc` wraps … buys nothing observable" | stageB-task-2-report.md §4 | pre-deploy | **Stands.** Per-scanout-frame, fixed at 59.92 Hz, independent of render period |
| "the two `devmem` reads are not mutually atomic … does not matter here" | stage-b-device.md | 19.79 ms | **Stands**, conditional on zero spread (§6.6) |
| "`GMLOADER_MFGPU_TRACE` … zero cost when unset" | plans/2026-07-29-…-stage-a.md | pre-measurement | **Stands** (branch-predictable `getenv` cache), but unmeasured. When *enabled* it costs 0.9–2.9 ms of `capture` — never mix a trace run into a period figure |
| "DDR scanout reader … already overlapped"; "Audio pump … measured ~0" | specs/2026-07-28-…-diagnostics-design.md | pre-Phase-0 | **Reader: stands** (§5, capped at one copy per scanout frame). **Audio: unsupported** — no measurement exists and the instrument that would produce one does not (§6.4) |
| "arrival denominator correction … 0.01 ms, ~70× smaller than the ±0.72 ms band" | stage-a-sizing.md §6.1 | arrival 21.81 ms | **Stands on magnitude**, but the band it was compared against was later retracted as a stub artifact (§11.2), so the "70×" no longer has a valid denominator |

---

## 8. What Phase 4 should do with this, in order

1. **Instrument the limiter before fixing it** — a `next_ms - now` histogram. One run.
   The 1.70 ms is real; the mechanism is not, and the proposed fix is sized on the
   mechanism (§1).
2. **Decompose the 1.89 ms exposed tail** — it sets the fabric gate, and at the gate it
   consumes 100 % of the margin against 16.6882 ms (§2).
3. **Measure device `ovhd`** — 2.32 ms fixed, of which 1.53 ms is unexplained and
   0.795 ms is a provably redundant CLEAR. Together they are larger than the entire
   remaining 1.40 ms quiet-scene gap, and no `dpath` lever touches either (§3).
4. **Add a periodic audio-underflow counter** — otherwise the "underflow 0.0/s"
   criterion stays unverifiable, and the higher poll rate in §5 lands on an unmeasured
   subsystem (§6.4).
5. **Do not target a render rate above 59.9228 Hz.** Anything faster is dropped at
   `comp_fb_dma.sv:201` with the full fabric and host cost already paid (§4).
6. **Watch for a stationary (not rolling) linebuf band** in Phase 4 screenshots (§4).

---

## Provenance

Sources: `docs/superpowers/findings/2026-07-29-phase2-baseline.md`,
`2026-07-30-phase3-stage-a-sizing.md` (§4, §6, §6.1, §8.1, §8.2, §8.4, §11),
`2026-07-30-phase3-stage-b-device.md`; `.superpowers/sdd/stageA-task-5-report.md` §3.3/§4,
`stageA-task-7-report.md` §1/§1.2, `stageB-task-1-report.md` §3/§4/§5,
`stageB-task-2-report.md` §4, `stageB-task-5-report.md` §4/§5/§8/§9;
`docs/superpowers/investigations/2026-07-28-ingame-frame-budget.md`,
`2026-07-28-60fps-phase1-handoff.md`, `2026-07-28-fabric-ms-insensitivity.md`;
`docs/superpowers/specs/2026-07-28-maldita-60fps-diagnostics-design.md`.

Code read at `wt-gmloader-60fps-p3` @ `b775007` (`perf/60fps-phase3`) and
`wt-maldita-60fps-p3` (shipping RTL under `fpga/rtl/`, the vendored copy —
`mister-fpga-blitter/rtl/` is the non-shipping v1 spike and was not used).

New measurements taken **for this audit** (both are re-analyses of the existing Stage B
logs `bench-results/20260730-111518---preset_fabric_--godmode.log` and
`20260730-112520---preset_fabric_--godmode_--fps_0.log`, not new device runs):
the DRAWTRACE `frame=` distributions in §1 and the `spin_avg` distributions in §5.
No device was contacted; `.62` and `.81` were both untouched.

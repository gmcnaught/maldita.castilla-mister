# Maldita 60 FPS — Phase 0 diagnostics — design

**Date:** 2026-07-28
**Status:** Approved (sections reviewed in-session)
**Repos affected:** mister-gmloader (harness forward-port, bench captures), gmloader-next (scene driver tool, host instrumentation read), maldita.castilla-mister (RTL counter fix *only if* H1–H4 all fail)

## Problem

The path to 60 fps cannot be planned, because the two things a plan would rest on are both missing.

**We have never measured the scene that matters.** Every Maldita performance number on record comes from the intro, title, attract or menu — GM-logic-bound, texel-light scenes of 28–360 triangles. The fabric-bound in-game case (parallax + sprites + UI, estimated ~3.1× overdraw) has never been benchmarked, because the game did not progress past its title screen under gmloader. That blocker is now lifted: joystick input works, so gameplay is reachable.

**The primary in-fabric instrument is untrustworthy.** On 2026-07-17 the `MFSUBMIT fabric_ms` counters read *identical* (`frame=25.58 tri=23.12`) at 28 triangles and at 360 triangles, while host-side `BLITPROF raster` scaled 16→37 ms over the same transition. A counter that does not move with the workload cannot attribute a frame budget.

Compounding both: this project has a documented history of optimization work funded by static analysis and then falsified on device.

- The `mf_device_submit` **poll-wait** hypothesis — falsified; the wait was real but the fix was a no-op.
- The **ch5 cache-capacity** hypothesis — falsified by an A/B that cost a full Quartus build and moved frame time 48.87→48.77 ms (0.2%).
- The **"~46 cyc/px is texel wait"** attribution — falsified by direct per-state counters; the true split was 14 ms texel wait, 32 ms datapath.
- The **"native audio wedges the fabric"** conclusion — overturned 2026-07-27; it was two concurrent engine instances writing one control block.

The in-tree lesson is recorded verbatim: *"Stop inferring."* Phase 0 exists to make the next lever the first one chosen from measurement.

## Goal

Produce a populated **16.67 ms frame budget** for a real, reproducible, in-game Maldita Castilla scene on the `.81` bench unit, under a *proven* instrument — and from it, a single arithmetic statement of what 60 fps requires.

**No optimization work ships in this phase.**

### Decisions made during brainstorming

- **Target workload:** Maldita Castilla **in-game** gameplay, not title/menu. Reachable now that joystick input works.
- **Correctness envelope: pixel-exact, and the timing slack must close.** Full native 288×216, no tearing, bit-exact versus the golden refmodel, and the −0.732 ns tint-path slack must be closed before any lever ships. This rules out three otherwise-available levers: render-resolution reduction (`GMLOADER_RENDER_W/H`), `GMLOADER_MFSUBMIT_NOWAIT` (tears), and shipping on the fragile fit.
- **Instrument first.** The counter defect is bug #1. No budget number is recorded until the instrument passes a trust gate.
- **Bench device: `192.168.20.81`** (superstation). The harness and `deploy.py` both default there, both A/B RBFs are already staged in `/media/fat/_Other/`, and the historical baseline table was measured there, so comparisons stay valid. `.62` is *not* a substitute — the SDRAM_CLK phase finding proves these two boards genuinely differ.
- **Approach: instrument-first, lever chosen by data.** This spec covers Phase 0 only and terminates at a decision gate. The lever it names is executed under a separate spec.

## End state

Four components, each independently testable. The first three parallelize; only budget capture is a join point.

| Component | Purpose | Depends on |
|---|---|---|
| Harness forward-port | `mister_run.sh` / `gmloader_diag.sh` onto current `master`, sole-engine assertion folded in | — |
| Scene driver | timed `joy_mask` replay reaching a fixed gameplay scene from cold launch | harness |
| Instrument repair | rule out `SOLARUS_DBG_PROBES`, root-cause `fabric_ms` insensitivity, prove with a two-tri-count A/B | — |
| Budget capture | run the scene under trusted counters; emit the allocation table and the vsync-serialization verdict | all three |

### Non-goals

No RTL optimization. No host pacing or double-buffering changes. No lever implementation. No tint-slack fit-cycle. Each follows from the data, in a later spec.

## Component 1 — Harness forward-port

`mister_run.sh` and `gmloader_diag.sh` exist **only** on branch `perf/mfgpu-submit-profiling` (`07bf085`), not on `master`. They must come forward before anything else runs.

Folded in during the port, because the audio-wedge investigation proved each one load-bearing:

- **Kill by explicit PID.** MiSTer busybox 1.33 has no `pkill`/`pgrep`; `pkill … 2>/dev/null` fails *silently*, so every "I killed the old instance" guard passes vacuously. Use `for p in $(ps | grep -E "[.]/gmloader" | awk '{print $1}'); do kill -9 $p; done`.
- **Match `[.]/gmloader`, not `gmloader`.** A kill script matching the bare name kills itself — its own argv contains the binary name.
- **Assert, don't assume.** Log a per-sample engine process count and **abort the run** if it is not exactly 1.
- **Launch via the Master_Daemon handler, not by hand.** This corrects an earlier assumption in this design. Hand launches are *not* equivalent: the 2026-07-27 handoff records a different halt point (33 versus 21) between the two paths, and an interactive shell masks the `LD_LIBRARY_PATH` requirement that `_handler.sh:70` sets explicitly. The handler is also the production path. Its own singleton guard plus our per-sample assertion is the contamination defence — *not* disabling the daemon.
- **Launch from the correct cwd** (`/media/fat/games/gmloader`); `/tmp` breaks `bin_dir` resolution. The handler already does this.
- **Require `|submit − done| ≤ 1`** before calling a sample healthy; the two words are read non-atomically, so a fast healthy run can legitimately sample `done == submit + 1`.

Note that `scripts/Maldita_Castilla.sh` in gmloader-next still uses `pkill -9 -f "gmloader -c"` — a vacuous guard on this userland. The harness must not depend on it.

## Component 2 — Scene driver

A small on-device armhf writer, placed in `gmloader-next/tools/` alongside the existing `fabric_probe` / `fabric_soak` binaries.

### Contract

`/dev/shm/maldita-joy` is a flat 24-byte struct (`mister_joy_shm.h`): `magic` (`0x4D414C44`), `version` (1), `generation`, `joy_mask[2]`. Bit layout: `bit0=right bit1=left bit2=down bit3=up bit4=Sword bit5=Action bit6=Item1 bit7=Item2 bit8=Pause`. Each mask word is naturally aligned and written as a single atomic word.

### How injection actually works

`input.cpp:307-319` selects between two transports, latched once on first poll:

```
if (g_joyshm_ready == -1) g_joyshm_ready = JoyShm_Init() ? 1 : 0;
...
uint32_t mask = (g_joyshm_ready == 1) ? JoyShm_ReadMask(p) : JoyDdr_ReadMask(p);
```

**shm wins when present**; otherwise input falls back to the DDR words the FPGA core publishes from the real joystick (`joy_ddr_reader.h`, P1 at byte `+0x008`). Both transports share the identical bit layout.

Under the handler launch there is **no shm producer at all** — `_handler.sh:22-25` states plainly that the joystick SHM bridge is one of the wrapper features this path does not provide. So the driver faces no competing writer and can own the canonical `/dev/shm/maldita-joy` directly. The `GMLOADER_JOY_SHM` override (`joy_shm_reader.cpp:31`) remains available but is not required. Creating the file is precisely what diverts the engine from the physical joystick to the script.

Two consequences that are easy to get wrong:

1. **Ordering is load-bearing.** `g_joyshm_ready` latches on the first input poll and is never re-evaluated. The driver must have written `magic` *before* the engine reaches that poll, or the run silently uses the real joystick for its entire life. The driver therefore starts before `load_core`, and writes `magic` **last** after the other header fields — the same doorbell-last discipline the fabric uses for `C_DONE`.
2. **Silent fallback is unobservable today.** `JoyShm_Init()` logs nothing, so a failed injection is indistinguishable in the log from a successful one. The plan adds a one-line transport log so the harness can *assert* which path won, rather than infer it from whether the game moved.

### Script format and determinism

The driver replays a version-controlled script file of `<ms> <mask>` lines, so the route from cold launch to a fixed gameplay scene is reviewable rather than typed live. Each step emits a marker to the log, allowing a bench log to be aligned to scene position after the fact.

The script terminates at a **held, quiescent gameplay position** — a spot where the game keeps rendering a representative scene without further input drifting it. Frame capture begins only after a settle delay past the final step.

**Determinism assertion:** GM VM timing is not guaranteed identical run to run. The capture window's **mean per-frame triangle count must agree within ±5% across the three runs** of a configuration; if it does not, the runs are void and the script is retuned (longer settle, or a more quiescent hold position). A benchmark that silently lands on a different scene is worse than no benchmark.

The settle delay is set empirically during scene-driver bring-up — long enough that the triangle count has plateaued — and is then fixed in the script file, not tuned per run.

## Component 3 — Instrument repair

Root-caused via `systematic-debugging` against four ranked hypotheses. Three of the four resolve with no rebuild, and H1 and H2 between them explain the observation completely.

| # | Hypothesis | Discriminating test | Cost |
|---|---|---|---|
| H1 | The measured RBF had `SOLARUS_DBG_PROBES` defined, so `C_STATUS.hi` published `wedge_snap2` and `C_SRCSEL.hi` published `wedge_snap` — **persistent worst-case snapshots**, structurally scene-insensitive | Read both words raw; a packed bbox (`maxx \| maxy<<16`) is distinguishable from a cycle count. Confirm against the RBF's build config | free |
| H2 | Dual-engine contamination — the 2026-07-17 A/B **predates** the sole-instance discipline that later overturned the audio-wedge result | Re-run the original 28-vs-360 A/B under the asserted-sole-instance harness | free |
| H3 | `perf_frame_cyc` counts vblank/snapshot waiting. `idle` is set only in `S_POLL_SUBMIT`, so `S_SNAP_WAIT` accumulates, pinning `frame` near a vsync period regardless of scene | Compare `frame` slope against `tri` slope across tri counts; `frame` flat while `tri` scales confirms it | free |
| H4 | A genuine publish/read race surviving the C_DONE-last ordering fix (`blitter_top.sv:1579`) | Double-read the counters per frame and check stability | free |

### Where the counters live

- `perf_frame_cyc` → `C_DONE.hi`, published in `S_WR_DONE` (**not** `ifdef`-guarded)
- `perf_texwait_cyc` → `C_STATUS.hi`, published in `S_WR_STATUS` (`ifdef`-guarded — H1)
- `perf_tri_cyc` → `C_SRCSEL.hi`, published in `S_WR_PERF`, host reads at `0x3B00003C` (`ifdef`-guarded — H1)
- All four reset per frame at `S_CHK_NEW` (`blitter_top.sv:896`), accumulate under `if (!idle)` (`:853`)
- Host side: `raster_backend_mfgpu.cpp:468-470`, gated by `GMLOADER_MFSUBMIT_STAT=1`

`Maldita.qsf:21` records that `SOLARUS_DBG_PROBES` is currently off and carries a warning against re-enabling it. The 2026-07-17 observation predates the probe RBFs, so H1 is *plausible but unproven* for that specific measurement — it must nonetheless be ruled out for every RBF measured in this phase.

H3, if confirmed, is **not necessarily a defect**. It may mean `frame` always measured wall-clock-to-vblank and only `tri` was ever the throughput metric. That distinction feeds directly into the serialization verdict.

### Trust gate

The instrument is declared trusted only when a controlled A/B at **two known triangle counts yields proportionally different `tri_ms`**. Until that passes, no budget number is recorded.

An RTL fix plus a Quartus cycle is budgeted but not assumed.

## Component 4 — Budget capture

Each captured run emits one table, expressed against the 16.67 ms budget:

| Line item | Source | Overlappable? |
|---|---|---|
| GM VM logic (A9) | host wall-clock, `BLITPROF` | with fabric, in principle |
| Command/vertex build + ring submit | host | with fabric |
| Fabric raster `S_TRI_*` | `tri_ms` (trusted) | no — the work itself |
| ├─ texel-fetch stall | `texwait_ms` | subset of the above |
| Fabric composite pipe | `perf_pipe_cyc` | subset |
| WORK→scan snapshot | `comp_fb_dma` copy cycles | with next frame |
| DDR scanout reader | continuous | already overlapped |
| Audio pump | host | measured ~0 |
| **Unattributed / serialization** | frame_time − max(host, fabric) | **the overlap deficit** |

### Derived numbers

- **overdraw** = covered_px ÷ (288 × 216). Estimated ~3.1× from a 320×240-era back-calculation; never measured in-game.
- **cyc/px** = `tri_cyc` ÷ covered_px. 13 cyc/px in sim (`tb_blitter_trilist_pipe`); the device value at a texel-heavy scene is unknown.

**Where `covered_px` comes from.** No counter publishes it — the ~3.1× figure was *back-calculated* by dividing device `dpath` by the sim's 13 cyc/px, which assumes the very throughput the number is then used to characterize. That circularity has to go.

Phase 0 measures it **host-side**: the emitter already holds every submitted triangle's screen-space vertices, so summing |cross product| ÷ 2 over the batch gives covered area including overdraw, with no RTL change. This is an *estimate* — it ignores scissor and clipping, and counts degenerate triangles as zero — so it is reported as `covered_px_est` and never presented as exact.

If and only if H1–H4 force a Quartus cycle anyway, an exact `perf_covered_px` counter is bundled into that same build and the host estimate becomes a cross-check. A build is not spent for this metric alone.
- **serialization factor** = frame_time ÷ max(host_logic, fabric_busy). ~1.0 is fully overlapped; ~2.0 is fully serial.

### The vsync question

The original fabric finding was **3 × 16.29 ms of fixed pipeline latency**. At 60 fps the entire budget is a single vsync, so any surviving serialization makes rasterizer throughput irrelevant — the lever would be overlap, not speed. Phase 0 therefore records whether frame time is *quantized* to the scanout period, and measures the core's **actual** scanout rate at 288×216 rather than assuming 60 Hz.

### Decision gate

Phase 0 closes by answering one question — **what would 60 fps actually require?** — as arithmetic, not preference. Illustrative form:

> "Fabric raster is 30 ms at 2.9× overdraw and 11 cyc/px; the host is 9 ms and fully serialized. 60 fps needs 2× raster throughput **and** host/fabric overlap — neither alone suffices."

That sentence, with a measurement behind every clause, is the deliverable. It names the lever for the next spec.

Levers already built or specified — the S_TRI datapath pipeline, the Lever-1 texel prefetch cache, host ring/vertex double-buffering, overdraw reduction — are *candidates*, deliberately not pre-committed here.

## Verification

**Provenance on every number.** Each capture carries: engine build id, RBF tree hash via the `deploy.py` provenance gate (`64b7272`, which refuses a mismatched engine/RBF pair), per-sample sole-engine assertion, the shm path in use, the scene script hash, and per-frame triangle count.

**Repeatability before significance.** Minimum three runs per configuration, reporting **spread**, not a mean alone. A difference smaller than run-to-run spread is not a result. The Lever-1 "−2.8%" claim is exactly what this rule is designed to catch.

**Instrument trust gate** as defined in Component 3 — a blocking precondition for Component 4, not a checklist item.

## Risks

1. **Game progression is newly working and unproven under load.** If the route to gameplay is flaky, the determinism assertion fails loudly rather than silently producing a bad budget. Acceptable.
2. **The current RBF ships with the −0.732 ns tint-path slack.** Under the pixel-exact envelope this must eventually close, but a wrong tint *colour* does not perturb *timing*, so Phase 0 may measure on it. The fit-cycle belongs to the lever phase.
3. **`.81` and `.62` genuinely diverge** (SDRAM_CLK phase finding). All Phase 0 numbers are `.81`-only and must not be generalized without a confirmation pass.
4. **H1–H4 may all be false**, leaving a real RTL counter defect and a Quartus cycle. Budgeted, not assumed.
5. **60 fps may not be reachable within the pixel-exact envelope.** Phase 0 is designed to surface that honestly and early — as arithmetic at the decision gate — rather than after another round of funded levers.

## References

- `docs/superpowers/specs/2026-07-16-trilist-rasterizer-throughput-design.md` (maldita) — datapath/prefetch lever analysis
- `docs/superpowers/specs/2026-07-27-native-288x216-design.md` — current geometry contract
- `docs/superpowers/plans/2026-07-16-trilist-lever1-prefetch-cache.md` (maldita) — Lever-1 status
- Branch `perf/mfgpu-submit-profiling` @ `07bf085` — harness origin

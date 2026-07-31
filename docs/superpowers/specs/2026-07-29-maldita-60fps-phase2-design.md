# 60 FPS Phase 2 — re-baseline, lever gate, lever implementation

**Date:** 2026-07-29
**Status:** Design approved (conversation, 2026-07-29). Implementation not started.
**Shape:** Measure first, then commit. Lever selection is a decision gate inside the
phase, made on post-Phase-1 numbers — not inherited from Phase 0's budget.

---

## 1. Why a re-baseline is mandatory

Every number the campaign holds — fabric `frame` 20.79 ms, `dpath` = 80% of `tri`,
overdraw 2.94×, host 5.3 ms serial — was measured on the **pre-Phase-1** stack
(`MalditaCastilla_476a422.rbf`, engine without pipelining). Phase 1 changed every term:

| Phase 1 change | Term it moves |
|---|---|
| A1: `S_SNAP_WAIT` vblank barrier deleted (5.3 → ~0.16 ms tail) | `frame`, and the 30 fps cliff itself |
| A2: pb datapath 8 → 6 cyc/px | `dpath` (was the dominant term) |
| A3: double-buffered command ring | submit latency |
| A4: exact `perf_covered_px` in `C_FLAGS.hi` | overdraw is now measured, not estimated |
| Host: C_DONE await deferred one frame (`Process()` overlaps raster) | the 5.3 ms serial host term |
| bbox clamp `FB_W-1`/`FB_H-1` (maldita #14) | raster work itself (Phase 0 RBF overran rows) |

Funding a lever against the old budget risks paying for headroom Phase 1 already ate.

## 2. Stack under test

- **RTL:** maldita `origin/milestone-a` @ `cd4d9f1` (includes #14 bbox, #16 Phase 1
  fabric, #17 tint-slack STA fix — the slack drift named in PR #16's follow-up is
  **fixed and merged**, out of scope here). Worktree: `../wt-maldita-60fps-p2`,
  branch `perf/60fps-phase2`. Sim battery 51/51 at worktree creation.
- **Engine:** gmloader-next `origin/master` @ `675f190` (includes #24 pipelining,
  #25 FPS overlay, #26 GODMODE). Worktree: `../wt-gmloader-60fps-p2`, same branch
  name. Docker ARM build per the documented recipe.
- **Harness:** this repo (`mister-gmloader`), worktree `../wt-mister-60fps-p2` —
  `scripts/mister_run.sh`, `scripts/scenes/`, Makefile entry points.

**Device: `.62` only** (`root@192.168.20.62` — the test device; `.81` is production).
Phase 0's wall-clock numbers were taken on `.81`; cross-device comparison leans on the
cycle-count fabric counters (same fabric clock), and `.62` wall-clock is stated as such.
Deploy via `make deploy-engine` / `make deploy-rbf` (HOST already defaults to `.62`);
RBF resolved by `fpga/` tree hash — **rebuild rather than `--force`** on a gate refusal.
Note `.62` is the analog-VGA unit: `vga_scaler=0` / `forced_scandoubler=0` are correct
there, and its SDRAM phase margin differs from `.81` — a run that garbles there needs
the phase memory checked before blaming the RTL under test.

## 3. Task A — re-baseline, two scenes

Both scenes run the Phase 0 bench env plus godmode:

```sh
export GMLOADER_BLITTER=2 GMLOADER_RASTER=mfgpu GMLOADER_BLITTER_PROF=1
export GMLOADER_MFSUBMIT_STAT=1 GMLOADER_DRAW_TRACE=1 GMLOADER_GODMODE=1
```

1. **Quiet (apples-to-apples):** existing `scripts/scenes/ingame-stage1.joy`,
   unchanged, so the budget table lines up row-for-row with Phase 0's.
2. **Busy (binding):** new joy script continuing early into Stage 1 — the ~35 fps
   activity is reached without going far. `GMLOADER_GODMODE=1` (skips `obj_player`
   collision events) keeps the scripted run alive there. This scene carries the
   **16.69 ms / 60 fps target**; results are reported as the quiet–busy range.

Per scene, record the full budget line: `frame`, `tri`, `dpath`, `texwait`, `ovhd`
(fabric counters), exact `perf_covered_px` → true overdraw and cyc/px, and **true
period from `GMLOADER_DRAW_TRACE=1`** (`process_ns + capture_ns`) — never `wait_ms`,
which is a tautology against `perf_frame_cyc`. Scenes confirmed by screenshot
(288×216 = correct bitstream; bare `screenshot` command, no filename arg).

**Questions Task A settles as side effects** (all from the Phase 0 handoff §6):

- **30 fps cliff:** A1 deleted `S_SNAP_WAIT` — verify from measured true period vs
  fabric time that no vblank quantization remains. Verify, don't assume.
- **Host overlap:** with pipelining live, true period should be ≈ max(fabric, host)
  + small ε, not their sum. The Phase 0 evidence for serialization was the exact
  equality `20.79 + 5.3 = 26.1`; the same arithmetic now proves or disproves overlap.
- **cyc/px residual:** measured ~8.0 vs sim ~6–7 on the old 8-cyc datapath. Re-read
  against the 6-cyc datapath with the exact coverage denominator.
- **Scanout period:** 16.69 ms is derived from RTL `H_TOTAL`/`V_TOTAL`, never
  measured. Measure it once during these runs.

Launch discipline (each has bitten): single `Master_Daemon` asserted by count, kill by
explicit PID (busybox has no pkill/pgrep — guards written with them pass vacuously),
bounce through `menu.rbf` before `load_core`, joy script started **before** the core
loads, deployed binary mtime checked against repo HEAD, swap-then-kill for engine
updates (never hand-launch — that is how dual-engine contamination happened).

## 4. Task B — decision gate (stop point)

From the busy-scene budget, rank the levers by measured headroom:

| Lever | Old (stale) size | Post-Phase-1 size |
|---|---|---|
| Per-pixel datapath (`dpath`) | 14.72 ms, 80% of `tri` | **measure** |
| Overdraw (exact `perf_covered_px`) | 2.94× (estimated) | **measure** |
| Texel stalls (`texwait`) | 3.77 ms, 20% of `tri` | **measure** |

Pick the smallest lever set whose measured headroom closes the busy-scene fabric term
to ≤ the 60 fps budget, accounting for host overlap. **This is a stop point:** the
numbers and a lever recommendation come back to the user before any RTL work starts.
If the re-baseline shows the target is already met or nearly met, the gate may
conclude "polish + verify" instead of a lever.

## 5. Task C — lever implementation (scoped at the gate)

Executed in `../wt-maldita-60fps-p2` (RTL) and/or `../wt-gmloader-60fps-p2` (host).
Content deliberately unspecified until the gate. Standing gates regardless of lever:

- Sim battery green (`fpga/sim/run_sims.sh`, currently 51 gating TBs), new TBs for
  new logic, bit-exact against the refmodel where one exists (3 lockstep copies rule).
- M10K inference: `grep -c 276007 *.map.rpt` — only the known `xq_mem` case. A
  `ramstyle` array's read must never be nested in an FSM case arm.
- STA no-regression vs the `cd4d9f1` build's slack.
- Device A/B on **both** scenes, same run protocol as Task A, screenshot-confirmed.

## 6. Exit criteria

Busy scene at ≤16.69 ms true period (60 fps) on `.62` — or a measured budget showing
exactly what remains, which lever was implemented, what it bought, and why the
remainder needs another phase. No claim rests on `wait_ms`, tri counts, or an
unverified scene.

## 7. Out of scope

- Tint-path setup slack (fixed, merged as maldita #17).
- Audio artifact work (`feat/audio-own-clock` follow-up — separate workstream).
- `.81` deployment of anything (production; end-of-campaign promotion only).
- Submodule pin bumps in this repo (done at phase end, after merges, as in Phase 0/1).

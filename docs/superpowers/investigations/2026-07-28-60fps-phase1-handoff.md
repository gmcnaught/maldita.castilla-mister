# 60 FPS — Phase 0 complete, Phase 1 handoff

**Date:** 2026-07-28
**Status:** Phase 0 delivered. Phase 1 (lever selection + implementation) not started.
**Bench device:** `root@192.168.20.81` only. `.62` numbers are NOT interchangeable.

---

## 1. The answer Phase 0 produced

> Fabric raster is **20.79 ms** detect→done at **2.94×** overdraw and **9.97 cyc/px**
> (7.9 on the `dpath` proxy). Host CPU work is **5.3 ms** and runs **strictly serially**
> before the submit — measured true frame period **26.1 ms (38.3 fps)**.
> 60 fps requires **both** the fabric to reach ≤14.40 ms (`tri` 18.50 → 14.40, ~1.29×)
> **and** host/fabric pipelining so `Process()` overlaps the fabric window.
> **Neither alone suffices.**

`fabric 20.79 + host 5.3 = 26.1` matches the measured period exactly. That equality is
the evidence for serialization — not `wait_ms`, see the trap in §4.

**60 fps is not reachable inside the pixel-exact envelope with the raster path as
currently built.** Full detail: `2026-07-28-ingame-frame-budget.md` and
`2026-07-28-fabric-ms-insensitivity.md` in this directory.

### Budget at the measured gameplay scene

| Line item | ms | Note |
|---|---|---|
| Fabric `tri` | 18.50 | the work itself; 80% of it is `dpath` |
| ├─ `dpath` | 14.72 | per-pixel rasterizer datapath — **the dominant term** |
| ├─ `texwait` | 3.77 | texel fetch stall |
| Fabric `ovhd` | 2.29 | ring/clear/setup; stable across scenes |
| **Fabric `frame`** | **20.79** | detect→done |
| Host `Process()` | ~5.3 | **fully additive**, runs before the submit |
| **True period** | **26.1** | measured, `GMLOADER_DRAW_TRACE=1` |

---

## 2. What Phase 1 has to decide

Two levers are now both **required**, not alternatives:

1. **Fabric throughput, ~1.29×.** `dpath` is 80% of `tri`, so the per-pixel datapath is
   the target — consistent with the pre-existing Lever-2 analysis. Overdraw is 2.94×,
   which independently corroborates the historical ~3.1× back-calculation by a different
   route, so overdraw reduction is also a legitimate line of attack.
2. **Host/fabric pipelining.** Worth the full 5.3 ms and currently zero-overlap by
   construction (`main.cpp:779` runs `Blitter_PresentDefault()` → `mf_device_submit()`,
   which blocks, *after* `Process()` completes). The spec listed this as a candidate; an
   earlier draft of the budget wrongly foreclosed it on bad evidence.

**Do not treat Lever-1 (texel prefetch) as dead**, but do not fund it on the old
evidence either. Its recorded "+2.8%" was measured on the menu scene with a
contaminated counter. `texwait` is 3.77 ms = 20% of `tri`, so its ceiling is real but
smaller than the datapath's.

### The 30 fps cliff — check this before celebrating any fabric win

`maldita.castilla-mister/fpga/rtl/blitter_top.sv:1651`:

```systemverilog
S_SNAP_WAIT: if (vs_rise) begin fb_dma_start<=1'b1; snap_guard<=6'd0; state<=S_SNAP_BUSY; end
```

An **unconditional per-frame wait for the scanout vblank**, sitting between C_DONE and
the fabric's return to `S_POLL_SUBMIT`. It is published one state too early to appear in
`perf_frame_cyc` and the host is already released, so it is **invisible to both
counters**. At today's 26.1 ms period (1.564× the 16.69 ms scanout) it does not bind.
**As the fabric term approaches 16.69 ms it may pin delivered rate at 59.92/2 ≈ 30 fps**,
silently eating the entire win. Measure wall-clock with `GMLOADER_DRAW_TRACE=1`, not the
counters, when you get close.

---

## 3. Repository state

| Repo | Branch | PR | Base |
|---|---|---|---|
| `gmloader-next` | `perf/60fps-phase0-diagnostics` | [#23](https://github.com/gmcnaught/gmloader-next/pull/23) | `master` |
| `maldita.castilla-mister` | `perf/60fps-phase0-diagnostics` | [#13](https://github.com/gmcnaught/maldita.castilla-mister/pull/13) | `milestone-a` |
| `mister-gmloader` | `perf/60fps-phase0-diagnostics` | [#1](https://github.com/gmcnaught/mister-gmloader/pull/1) | `master` |

**Merge order:** `gmloader-next#23` → `maldita#13` → `mister-gmloader#1` → **then bump
submodule pins** (not done in the PRs, deliberately).

**Process note — worktrees.** These branches were created **in place** in the shared
checkouts instead of via `superpowers:using-git-worktrees`. That was a mistake and it had
a visible consequence: a concurrent session cut `fix/trilist-bbox-clamp` from this branch
and left the `maldita.castilla-mister` checkout on it, so two sessions were sharing one
working tree. Nothing was lost, but only by luck. **Phase 1 should use a worktree per
workstream** — `git worktree add ../wt-<topic> -b <branch>` — as the sibling
`wt-gmloader-audio` / `wt-maldita-audio` directories already do.

**Unrelated concurrent work:** `maldita.castilla-mister` branch `fix/trilist-bbox-clamp`
(commit `ee13653`, a different session) fixes a real RTL bug — the TRILIST bbox clamp was
hardcoded to 319/239 instead of `FB_W-1`/`FB_H-1`, letting a walk overrun to px 288..319
and wrap onto the next row. **Phase 0's measurements were taken on
`MalditaCastilla_476a422.rbf`, which does NOT contain that fix.** It is a correctness fix,
not a perf one, but re-baseline after it lands.

---

## 4. Device procedure — hard-won, follow exactly

Device `root@192.168.20.81`, key auth, **busybox 1.33: no `pkill`, no `pgrep`, no
`pidof`**. They fail *silently*, so any guard written with them passes vacuously.

```sh
# 1. Assert exactly ONE Master_Daemon. Three were found running, each spawning a
#    handler, producing two engines writing one control block.
ps | grep -c "[M]aster_Daemon"

# 2. load_core to an ALREADY-LOADED rbf is a NO-OP. Bounce via the menu first.
echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd

# 3. Kill by explicit PID. Match [.]/gmloader so grep and the script itself don't match.
for p in $(ps | grep "[.]/gmloader" | sed -e 's/^ *//' -e 's/ .*//'); do kill -9 $p; done

# 4. Stage bench env — the handler sources this if present.
printf 'export GMLOADER_BLITTER=2\nexport GMLOADER_RASTER=mfgpu\nexport GMLOADER_BLITTER_PROF=1\nexport GMLOADER_MFSUBMIT_STAT=1\nexport GMLOADER_DRAW_TRACE=1\n' \
  > /media/fat/games/gmloader/bench.env

# 5. Scripted input MUST start BEFORE load_core — transport latches on first input poll.
setsid ./joy_script /dev/shm/maldita-joy scene.joy </dev/null >/tmp/joyscript.log 2>&1 &

# 6. Load the core; gameplay ~72s after joy_script starts.
echo "load_core /media/fat/_Other/MalditaCastilla_476a422.rbf" > /dev/MiSTer_cmd

# 7. CONFIRM THE SCENE BY SCREENSHOT. Bare command only — a filename arg does NOT work.
echo "screenshot" > /dev/MiSTer_cmd     # newest file in /media/fat/screenshots/Maldita Castilla/
```

Drive remote waits with `ssh root@192.168.20.81 'sh -s' <<'EOF' ... sleep N ... EOF`
heredocs. `mister_run.sh --scene ingame-stage1` now wraps steps 2-6.

### Traps that have each cost real time

- **`wait_ms` IS NOT THE FRAME PERIOD.** It starts *after* the C_SUBMIT doorbell and stops
  at C_DONE — the same interval `perf_frame_cyc` measures from the other side. `wait_ms ≈
  frame` is a **tautology**; a "serialization factor" built on it divides an interval by
  itself, always yields ~1.0, and reads as "host overlapped" when the opposite is true.
  **Use `GMLOADER_DRAW_TRACE=1`** (`frame = process_ns + capture_ns`) for wall clock.
- **Pause (bit8) does not advance the game** — it opens gmloader's **own** overlay menu
  (`RESUME / DISABLE OVERLAY / KEY CONFIG / QUIT`), which renders ~168 tris and is
  indistinguishable from a game scene in `BLITPROF`. Two tuning passes were fooled.
  **Sword (bit4), pressed every 2 s from ~20 s to ~62 s**, reaches Chapter I. The engine
  spends ~15 s loading 49 MB before it reads input at all.
- **Confirm scenes by screenshot, never by triangle count.** The PNG's dimensions are
  themselves a provenance check: **288×216 = native core, 320×224 = a pre-288×216
  bitstream**.
- **`RASTER=sw` renders a BLACK SCREEN** on this core — the engine paints a DDR buffer the
  core no longer scans out. Not a bug; do not debug it.
- **Stale artifacts bite constantly.** `.81` was found with no current bitstream at all
  (newest-by-mtime was an SDRAM *phase-sweep probe* build). Use
  `deploy.py --fetch-rbf --host 192.168.20.81`, which resolves by `fpga/` tree hash and
  refuses mismatched pairs. It correctly refused a stale engine twice; **rebuild rather
  than `--force`**. Check the deployed binary's mtime against repo HEAD before trusting a
  run — that has bitten twice.
- **The Master_Daemon auto-respawns** a killed engine within seconds while `/tmp/CORENAME`
  names Maldita. Teardown is not a durable idle state; bounce to the menu core.

### Live fabric probes

```
0x3B000000 C_SUBMIT    0x3B000028 C_DONE     0x3B00002C frame.hi
0x3B000034 texwait.hi  0x3B00003C tri.hi     0x3BFB0010 reader beacon
```

A sample is healthy only if `|C_SUBMIT − C_DONE| ≤ 1` — they are read non-atomically.

---

## 5. Instrument status

**Trust gate: PASS** for the fabric counters. H1 (wedge snapshots), H3 (`frame` counts
vblank), H4 (publish/read race) all **refuted**. H2 (**dual-engine contamination**)
**confirmed** — that is the whole explanation for the 2026-07-17 "scene-insensitive
counters" symptom, and it is a launch-discipline defect, not a counter defect. Gate
re-established post-fix across a **2.78× coverage range**: cyc/px 7.41–8.35 (±8%).

`cov_px_est` is an **estimate** — Sutherland-Hodgman clipped to the render target, but it
still does not model per-pixel depth/blend rejection. An exact RTL `perf_covered_px`
counter was scoped but **not built**, because no Quartus cycle was otherwise required.
Bundle it into the next RTL build if one happens.

---

## 6. Open questions for Phase 1

1. **Measured cyc/px ~8.0 vs sim ~6-7.** A ~1.2× residual, honestly reported, never
   investigated. Plausible causes: Lever-1's `pb` pipeline latency, real vs stubbed memory
   latency. Worth resolving before sizing a datapath lever, since it is the metric that
   lever would be judged on.
2. **Scanout period 16.69 ms is DERIVED** from RTL `H_TOTAL`/`V_TOTAL`, not measured. The
   one place this phase did the thing it was created to stop. Measure it.
3. **The budget scene is a quiescent pose.** Ordinary gameplay in the same runs reaches
   `tri=26.68 dpath=21.36 cov=245,346` — the headline **understates** real cost by ~44%.
   Phase 1 should pick a busier scene, or state the range.
4. **Does `S_SNAP_WAIT` bind at a higher frame rate?** See §2.

---

## 7. Where things live

- Scene script: `scripts/scenes/ingame-stage1.joy` (verified by screenshot)
- Harness: `scripts/mister_run.sh`, `scripts/lib/device_pids.sh` (+ its host test)
- Device tools: `gmloader-next/tools/joy_script.c`, `joy_script_parse.{h,c}`
- Host tests: `make -f Makefile.gmloader joy-script-test` / `mf-cov-clip-test`
- Spec: `docs/superpowers/specs/2026-07-28-maldita-60fps-diagnostics-design.md`
- Plan: `docs/superpowers/plans/2026-07-28-maldita-60fps-diagnostics.md`
- Full task-by-task history, including every finding and correction:
  `.superpowers/sdd/progress.md` (git-ignored — copy it out before `git clean -fdx`)

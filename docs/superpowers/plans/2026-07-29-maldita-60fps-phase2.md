# 60 FPS Phase 2 Implementation Plan — re-baseline + lever gate

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a trustworthy post-Phase-1 frame budget on `.62` for a quiet and a
busy scene, then select (at a stop-point gate) the lever(s) that close the busy scene
to 60 fps.

**Architecture:** Pure measurement + analysis phase up to the gate. Harness changes
live in `mister-gmloader` (`--godmode` diag knob, new busy scene script); device runs
go through `scripts/mister_run.sh` (daemon-path launches only). Lever implementation
is a follow-up plan written at the gate (Task 7).

**Tech Stack:** bash bench harness over SSH (busybox target), joy_script scripted
input, fabric perf counters via `GMLOADER_MFSUBMIT_STAT`, wall clock via
`GMLOADER_DRAW_TRACE`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-07-29-maldita-60fps-phase2-design.md` — read it first.
- Device: **`.62` only.** Every `mister_run.sh` call MUST be prefixed
  `MISTER_HOST=root@192.168.20.62`; the script's default is `.81` (production).
- Worktrees (never touch the shared checkouts):
  `WT_MISTER=~/MisterFPGA-Projects/wt-mister-60fps-p2` (this repo, branch `perf/60fps-phase2`)
  `WT_GM=~/MisterFPGA-Projects/wt-gmloader-60fps-p2` (engine @ `675f190`)
  `WT_MALDITA=~/MisterFPGA-Projects/wt-maldita-60fps-p2` (RTL @ `cd4d9f1`)
- All commands below run from `$WT_MISTER` unless stated.
- Wall clock comes from `GMLOADER_DRAW_TRACE=1` (`frame = process_ns + capture_ns`).
  **`wait_ms` is a tautology against `perf_frame_cyc` — never use it for period.**
- Fabric counter sample is valid only if `|C_SUBMIT − C_DONE| ≤ 1`.
- Scenes are confirmed by **screenshot** (bare `echo "screenshot" > /dev/MiSTer_cmd`,
  no filename arg; newest file in `/media/fat/screenshots/Maldita Castilla/`).
  288×216 PNG = correct bitstream; 320×224 = stale. Never confirm by tri count —
  gmloader's Pause overlay renders ~168 tris and fakes gameplay.
- Deploys only via the Makefile / `deploy.py` (provenance gates). On a gate refusal,
  **rebuild; never `--force`**. Never hand-launch the engine (dual-engine hazard);
  never bypass with bare scp.
- busybox on device: no `pkill`/`pgrep`/`pidof` — they fail silently. Kill by explicit
  PID lists as `mister_run.sh` already does.

---

### Task 1: `--godmode` knob in `gmloader_diag.sh`

`bench.env` is built exclusively from `gmloader_diag.sh`'s flag→env mapping
(`build_bench_env` runs it with `--dry-run` on the device). `GMLOADER_GODMODE=1`
(gmloader-next #26: skips `obj_player` collision events) needs a flag or it cannot be
staged.

**Files:**
- Modify: `scripts/gmloader_diag.sh` (defaults block ~line 39, KNOBS help ~line 67,
  parse loop ~line 110, ENV assembly ~line 138)

**Interfaces:**
- Produces: `--godmode` flag → `GMLOADER_GODMODE=1` in the `[dry-run] env` line, which
  `build_bench_env` turns into an `export` line in `bench.env`. Tasks 3–5 pass
  `--godmode` in bench ARGS.

- [ ] **Step 1: Add the knob (four one-line edits, matching existing style)**

After the `E_MFSTAT` default line:

```bash
E_GODMODE=""      # GMLOADER_GODMODE        1 = skip obj_player collision events (bench)
```

In the KNOBS help text after `--dump-shaders`:

```
      --godmode       skip obj_player collision events (bench survival)
```

In the parse loop after the `--dump-shaders)` case:

```bash
    --godmode)       E_GODMODE=1;    shift ;;
```

In the ENV assembly after the `E_MFSTAT` line:

```bash
[ -n "$E_GODMODE" ] && ENV+=("GMLOADER_GODMODE=$E_GODMODE")
```

- [ ] **Step 2: Verify locally via dry-run**

Run: `bash scripts/gmloader_diag.sh --preset fabric --godmode --dry-run`
Expected: the `[dry-run] env` line contains `GMLOADER_GODMODE=1` alongside
`GMLOADER_MFSUBMIT_STAT=1`. Also run without `--godmode` and confirm the var is absent.

- [ ] **Step 3: Deploy the diag script to `.62`**

Run: `MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh deploy`
Expected: `[deploy] installed /media/fat/Scripts/gmloader_diag.sh on root@192.168.20.62`

- [ ] **Step 4: Commit**

```bash
git add scripts/gmloader_diag.sh
git commit -m "feat(bench): --godmode diag knob -> GMLOADER_GODMODE=1"
```

### Task 2: Deploy the post-Phase-1 stack to `.62`

**Files:** none modified (device deployment only).

**Interfaces:**
- Consumes: CI RBF for `cd4d9f1` (green `Build Maldita RBF` run exists), engine source
  @ `675f190` in `$WT_GM`.
- Produces: `.62` running the Phase-2 baseline stack all later tasks measure.

- [ ] **Step 1: Fetch + deploy the RBF for the RTL worktree HEAD**

Run: `make deploy-rbf MALDITA=$WT_MALDITA`
Expected: deploy.py resolves the artifact by `fpga/` tree hash (`8b6f563c…`) and
deploys without `--force`. If it refuses, the CI artifact is stale/missing —
investigate the run, do not override.

- [ ] **Step 2: Build the engine (Docker armhf cross-build)**

Run: `make build-engine GMDIR=$WT_GM` (first time may need `make build-image`)
Expected: binary at `$WT_GM/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf`.

- [ ] **Step 3: Deploy the engine (swap-then-kill via deploy.py)**

Run: `make deploy-engine GMDIR=$WT_GM`
Expected: sha1-verified copy + engine kill; Master_Daemon respawns with the new
binary. Do NOT launch anything by hand afterwards.

- [ ] **Step 4: Sanity-check the device state**

Run: `MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh ping`
Expected: SSH ok; exactly one (or zero, if idle at menu) engine process. Also check
the deployed binary's mtime is from today:
`ssh root@192.168.20.62 'ls -la /media/fat/games/gmloader/gmloader'`

### Task 3: Quiet-scene re-baseline (apples-to-apples)

**Files:**
- Create: `bench-results/` outputs (git-ignored) and
  `docs/superpowers/findings/2026-07-29-phase2-baseline.md` (started here, extended
  in Tasks 5–6)

**Interfaces:**
- Consumes: Task 1's `--godmode`, Task 2's deployed stack, existing
  `scripts/scenes/ingame-stage1.joy` (UNCHANGED — that is the apples-to-apples
  contract).
- Produces: quiet-scene budget rows in the findings doc: `frame`, `tri`, `dpath`,
  `texwait`, `ovhd` (cycles and ms), `perf_covered_px`, cyc/px, overdraw, true period
  ms, fps.

- [ ] **Step 1: Run the scripted bench, 3 times**

```bash
MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh \
  bench --secs 120 --scene ingame-stage1 --preset fabric --godmode
```

`--secs 120` covers ~15 s load + ~62 s scripted travel to Chapter I + ≥40 s of
measurement window. Expected per run: every sample prints
`[assert] …: engine count = 1` (a single ABORT invalidates the run — rerun it), and
the summary/collected log contains BLITPROF + MFSUBMIT_STAT + DRAW_TRACE lines.

- [ ] **Step 2: Screenshot-confirm the scene during the measurement window**

While a run is in its last 30 s:

```bash
ssh root@192.168.20.62 'echo "screenshot" > /dev/MiSTer_cmd'
ssh root@192.168.20.62 'ls -t "/media/fat/screenshots/Maldita Castilla/" | head -1'
scp "root@192.168.20.62:/media/fat/screenshots/Maldita Castilla/<newest>" bench-results/
```

Read the PNG. Expected: 288×216, Chapter I gameplay (not title, not the Pause
overlay). If wrong scene, the run's numbers are void.

- [ ] **Step 3: Extract the budget from the pulled logs**

From each run's log in `bench-results/`: take the median steady-state window after
scene arrival. Compute ms from cycles with the fabric clock; cyc/px =
`tri_cyc / perf_covered_px`; overdraw = `perf_covered_px / (288*216)`; true period
from DRAW_TRACE `process_ns + capture_ns`. Record all three runs + median in
`docs/superpowers/findings/2026-07-29-phase2-baseline.md`, in the same row format as
the Phase 0 handoff table so the two line up.

- [ ] **Step 4: Commit the findings doc**

```bash
git add docs/superpowers/findings/2026-07-29-phase2-baseline.md
git commit -m "findings(phase2): quiet-scene post-Phase-1 re-baseline on .62"
```

### Task 4: Author the busy scene script

**Files:**
- Create: `scripts/scenes/ingame-stage1-busy.joy`

**Interfaces:**
- Consumes: joy mask layout (`tools/joy_script_parse.h`): bit0=right 0x001,
  bit1=left, bit2=down, bit3=up, bit4=Sword 0x010, bit5=Action; format
  `<at_ms> <mask>`, at_ms non-decreasing, mask ≤ 0x1FF.
- Produces: a scene script whose 90 s+ window sits in confirmed high-activity
  gameplay (the ~35 fps region is reached early in the level per the user).

- [ ] **Step 1: Write the first draft**

Copy `ingame-stage1.joy` verbatim through its Chapter-I arrival (~62 s), then walk
right with periodic sword swings. Appended tail:

```
64000 0x001
70000 0x011
70250 0x001
74000 0x011
74250 0x001
78000 0x011
78250 0x001
82000 0x011
82250 0x001
86000 0x011
86250 0x001
90000 0x011
90250 0x001
110000 0x001
120000 0x000
```

(`0x001` = hold right; `0x011` = right+sword pulse. GODMODE keeps the hero alive
through contact damage, so no defensive inputs are needed.)

- [ ] **Step 2: Iterate against screenshots until the scene is confirmed busy**

```bash
MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh \
  launch --scene ingame-stage1-busy --preset fabric --godmode
```

Take screenshots at ~75 s, ~90 s, ~105 s (same commands as Task 3 Step 2), then
Ctrl-C (teardown is trapped). Expected: enemies/projectiles on screen in at least
the 75–105 s window. Adjust the walk/swing tail (more `0x001` hold, or brief `0x008`
jump-up presses if terrain blocks progress) and repeat until two consecutive
screenshots in the window show combat activity. Keep the confirming screenshots in
`bench-results/`.

- [ ] **Step 3: Commit**

```bash
git add scripts/scenes/ingame-stage1-busy.joy
git commit -m "feat(bench): busy-scene joy script — early Stage 1 combat under godmode"
```

### Task 5: Busy-scene baseline runs

**Files:**
- Modify: `docs/superpowers/findings/2026-07-29-phase2-baseline.md`

**Interfaces:**
- Consumes: Task 4's confirmed scene script.
- Produces: busy-scene budget rows (same columns as Task 3) — **the binding numbers
  for the gate**.

- [ ] **Step 1: Run the bench, 3 times**

```bash
MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh \
  bench --secs 130 --scene ingame-stage1-busy --preset fabric --godmode
```

Same validity rules as Task 3 (sole-engine asserts, screenshot confirmation inside
the busy window each run, counter sanity `|C_SUBMIT−C_DONE| ≤ 1`).

- [ ] **Step 2: Extract + record**

Same extraction as Task 3 Step 3, into a "busy scene" table in the findings doc,
plus the quiet–busy range statement the spec requires.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/findings/2026-07-29-phase2-baseline.md
git commit -m "findings(phase2): busy-scene baseline — the binding 60fps numbers"
```

### Task 6: Settle the four open handoff questions

**Files:**
- Modify: `docs/superpowers/findings/2026-07-29-phase2-baseline.md` (one subsection
  per question)

**Interfaces:**
- Consumes: Tasks 3+5 logs; RTL in `$WT_MALDITA` for the beacon check.
- Produces: verdicts the gate can rely on.

- [ ] **Step 1: 30 fps cliff — verify deletion**

From the busy-scene DRAW_TRACE series: plot/inspect the true-period distribution.
Expected if the cliff is gone: periods vary continuously with load, no clustering at
16.7/33.4 ms multiples. Also confirm in `$WT_MALDITA/fpga/rtl/blitter_top.sv` that no
unconditional `vs_rise` wait remains between C_DONE and `S_POLL_SUBMIT`
(`grep -n "S_SNAP_WAIT\|vs_rise" fpga/rtl/blitter_top.sv`). Record: Observed, both.

- [ ] **Step 2: Host overlap — prove or disprove with the Phase 0 arithmetic**

Compare `true period` vs `fabric frame ms` + `host process ms` per scene. Overlap
working ⇒ period ≈ max(fabric, host) + ε; serialized ⇒ period ≈ sum (that exact
equality was Phase 0's evidence). State which holds and the ε.

- [ ] **Step 3: cyc/px residual — re-read on the 6-cyc datapath**

Measured cyc/px (Task 3/5, exact `perf_covered_px` denominator) vs the A2 design
value (6 cyc/px pb path). Record the ratio; if ≥1.2× persists, note "residual
survives the exact denominator — memory latency is the remaining suspect" as gate
input for the texwait lever.

- [ ] **Step 4: Measure the scanout period (was only ever derived)**

First check what the reader beacon publishes:
`grep -n "beacon" $WT_MALDITA/fpga/rtl/openbor_video_reader.sv` (contract: beacon
word near FB_QW_BASE `0x3BF40000`; live probe `0x3BFB0010`). If it (or any exposed
counter) increments once per scanout frame, sample it twice 60 s apart while the
core is up:

```bash
ssh root@192.168.20.62 'devmem 0x3BFB0010; sleep 60; devmem 0x3BFB0010'
```

period = 60 s / Δcount. Expected ≈16.69 ms (59.92 Hz) — record the measured value.
If no per-frame counter exists, record that as the finding (do not fake it) and note
the cheapest RTL counter to add in the next Quartus cycle.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/findings/2026-07-29-phase2-baseline.md
git commit -m "findings(phase2): open-question verdicts — cliff, overlap, cyc/px, scanout"
```

### Task 7: Decision gate — lever selection + follow-up plan

**Files:**
- Modify: `docs/superpowers/findings/2026-07-29-phase2-baseline.md` (gate section)
- Create: follow-up implementation plan via superpowers:writing-plans (path decided
  by the chosen lever, e.g. `docs/superpowers/plans/2026-07-29-maldita-60fps-phase2-lever.md`)

**Interfaces:**
- Consumes: the complete findings doc.
- Produces: the funded lever set + its implementation plan (Task C of the spec).

- [ ] **Step 1: Build the lever table from the busy-scene medians**

| Lever | Measured size (ms) | Ceiling if perfected | Cost/risk |
|---|---|---|---|
| dpath (per-pixel datapath) | from Task 5 | dpath × (1 − 6/measured cyc/px floor) | RTL + Quartus cycle |
| Overdraw (exact) | (overdraw−1)/overdraw × dpath | same formula | raster/host-order changes |
| texwait (texel stalls) | from Task 5 | full texwait | prefetch follow-up phase notes apply |

Compute the required fabric reduction: busy `frame` ms → ≤ (measured scanout period)
given the Step-2 overlap verdict. Pick the smallest set that closes it.

- [ ] **Step 2: Report the gate to the user**

Post the two budget tables, the four verdicts, and the lever recommendation.
Per the user's standing approval (2026-07-29: plan and method pre-approved unless
system safety is at risk), continue without waiting **unless** the recommendation
involves anything outside `.62` bench scope or a destructive/production action.
If the baseline shows the target already met (busy period ≤ measured scanout period),
recommend "verify + promote" instead of a lever and stop for user confirmation —
promotion touches production.

- [ ] **Step 3: Write the lever implementation plan**

Invoke superpowers:writing-plans for the chosen lever, executed in `$WT_MALDITA`
(RTL) and/or `$WT_GM` (host). That plan inherits the spec's Task C standing gates:
sim battery green, `grep -c 276007 *.map.rpt` = 1 (known `xq_mem` case only), STA
no-regression vs the `cd4d9f1` build, device A/B on both scenes.

- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/findings/2026-07-29-phase2-baseline.md docs/superpowers/plans/
git commit -m "findings(phase2): decision gate — lever selection + follow-up plan"
```

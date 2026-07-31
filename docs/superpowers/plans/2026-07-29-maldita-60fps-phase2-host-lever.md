# Phase 2 Host Lever — move the C_DONE await off the frame's critical path

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Overlap the ~8 ms of post-await host work with the fabric window by moving the
deferred C_DONE await from the top of `mf_frame_begin` to immediately before the publish
that actually requires it.

**Architecture:** Phase 1 B2 deferred the await by one frame, but landed it at
`mf_frame_begin`, which the game reaches via its *first `glClear`* — early in the frame.
Everything after that point (draw emission, present/`blt_execute`, capture) is therefore
serialized behind the fabric. Measured: period ≈ fabric 19.30 + ~8 ms exposed host =
27.3 ms. The double-buffering that makes a late await safe is already in place (ring and
vertex arenas alternate — B1; textures pinned two frames — B3), so the await can move to
just before the doorbell without weakening the "never rewrite a live batch" guarantee.

**Tech Stack:** C++ engine (`gmloader-next`), armhf Docker cross-build, host-oracle unit
tests plus on-device A/B on `.62`.

## Global Constraints

- Evidence base: `mister-gmloader/docs/superpowers/findings/2026-07-29-phase2-baseline.md`.
  Read it first — it contains the period model and two hypotheses already killed.
- Work in `~/MisterFPGA-Projects/wt-gmloader-60fps-p2`, branch `perf/60fps-phase2`.
  Do NOT touch the shared `../gmloader-next` checkout (another session's branch).
- Device `.62` ONLY (`MISTER_HOST=root@192.168.20.62`); `.81` is production.
- Deploy via `make deploy-engine GMDIR=$WT_GM` from `wt-mister-60fps-p2`. Never bare scp,
  never hand-launch (dual-engine hazard).
- Period is measured by C_DONE (`0x3B000028`) delta over ≥30 s of screenshot-confirmed
  gameplay. Never `wait_ms` (tautology), never DRAW_TRACE `frame` (host work only).
- The safety invariant this plan must not weaken: **the host must never rewind or rewrite
  an arena the fabric is still reading.** Today the await enforces it; after this change
  the double-buffering plus a correctly-placed await must still enforce it.

---

### Task 1: Pin the current await placement with a host-oracle test

**Files:**
- Test: `test/mfgpu/test_submit_seam.cpp` (extend; it already exercises publish/await split)

**Interfaces:**
- Consumes: existing `g_publish_count`, `g_await_count`, `g_publish_depth`,
  `g_unpaired_awaits` witnesses in `raster_backend_mfgpu.cpp`.
- Produces: a test that fails if an await is skipped or ordered after a second publish —
  the regression guard for Tasks 2–3.

- [ ] **Step 1: Write a failing test that pins await-before-second-publish**

Assert, over three simulated frames, that `g_publish_depth` never exceeds 1 and
`g_unpaired_awaits == 0`, and that between any two publishes exactly one await occurs.
Write it against the CURRENT code so it passes now, then confirm it FAILS when you stub
the await out — that mutation check is what proves the test has teeth.

- [ ] **Step 2: Run it**

Run: `make -f Makefile.gmloader mfgpu-seam-test` (host build; add the target if absent)
Expected: PASS on current code.

- [ ] **Step 3: Mutation-check it**

Temporarily make `mf_device_await` return immediately. Expected: the new assertions FAIL.
Revert the mutation.

- [ ] **Step 4: Commit**

```bash
git add test/mfgpu/test_submit_seam.cpp
git commit -m "test(mfgpu): pin the publish/await pairing before moving the await"
```

### Task 2: Move the await to the publish site

**Files:**
- Modify: `gmloader/mister/raster_backend_mfgpu.cpp` — `mf_frame_begin` (~1054) and the
  publish path (~921-935, `mf_device_submit`)

**Interfaces:**
- Consumes: `g_fabric_pending`, `g_pending_seq`, `mf_fabric_still_busy()`, `g_arena`.
- Produces: unchanged external behaviour; the await now runs immediately before the
  doorbell write rather than at frame start.

- [ ] **Step 1: Move the barrier**

In `mf_frame_begin`, the `if (g_fabric_pending)` block currently awaits before
`blt_begin_frame` rewinds cursors. Keep a guard there for the case that genuinely needs
it — frame N+2 reusing arena N&1 — but make it conditional on the arena about to be
rewound being the one still in flight:

```c
// Await only if the arena we are about to rewind is the one the fabric is reading.
// With two arenas that is frame N+2 vs an unfinished N, not the common case.
if (g_fabric_pending && (g_arena & 1u) == (g_pending_arena & 1u)) mf_device_await();
```

Add `static uint32_t g_pending_arena;` set at publish time. Then, at the publish site,
await before ringing the doorbell:

```c
if (g_fabric_pending) mf_device_await();   // one batch in flight at a time
```

- [ ] **Step 2: Fix the coverage-accumulator pairing**

`mf_submit_stat` folds `g_cov_px_accum` and resets it, and its correctness comment
explicitly depends on running *before* the current frame's draws. With the await moved
after those draws, the accumulator now holds the CURRENT frame's estimate, not the
published one. Snapshot it at publish time and fold the snapshot:

```c
static double g_cov_px_published;   // estimate for the batch whose counters we will read
// at publish: g_cov_px_published = g_cov_px_accum; g_cov_px_accum = 0.0;
// in mf_submit_stat: csum += g_cov_px_published;   // NOT g_cov_px_accum
```

Leave `cov_src=exact` alone — `perf_covered_px` comes from the fabric and is unaffected.
This matters only for `cov_px_est`/`est_ratio`.

- [ ] **Step 3: Run the full host test suite**

Run: `make -f Makefile.gmloader mfgpu-seam-test mf-cov-clip-test joy-script-test`
Expected: all PASS, including Task 1's new assertions.

- [ ] **Step 4: Commit**

```bash
git add gmloader/mister/raster_backend_mfgpu.cpp
git commit -m "perf(mfgpu): await at the publish, not at frame start -- overlap draw+present"
```

### Task 3: Device A/B on `.62`

**Files:**
- Modify: `mister-gmloader/docs/superpowers/findings/2026-07-29-phase2-baseline.md`
  (add a "host lever result" section)

**Interfaces:**
- Consumes: the Task 2 engine.
- Produces: before/after period on the quiet scene and across the Chapter I arrival.

- [ ] **Step 1: Build and deploy**

```bash
cd ~/MisterFPGA-Projects/wt-mister-60fps-p2
make build-engine GMDIR=$HOME/MisterFPGA-Projects/wt-gmloader-60fps-p2
make deploy-engine GMDIR=$HOME/MisterFPGA-Projects/wt-gmloader-60fps-p2
```

Expected: deploy.py's freshness gate passes (rebuild, never `--force`). Confirm the
deployed binary's mtime is from this build.

- [ ] **Step 2: Measure the period, same protocol as the baseline**

```bash
MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh \
  bench --secs 120 --scene ingame-stage1 --preset fabric --godmode
```

Concurrently sample C_DONE per second across ≥30 s of gameplay, and screenshot-confirm
the scene (288×216, Chapter I). Baseline to beat: **27.05–27.30 ms**.

Expected if the model holds: period → ~max(fabric 19.30, total host ~9.5) ≈ **19–21 ms
(48–52 fps)**. A result at ~27 ms means the exposed work was not what the model says —
stop and re-derive rather than pressing on to the fabric lever.

- [ ] **Step 3: Check for corruption, which is the specific risk here**

Take 5 screenshots across the run. Expected: no stale-parity bands, no garbage geometry,
no torn tilemap — those are the signatures of a batch being rewritten while in flight
(the exact failure the await protects against, seen on device 2026-07-24). Any of them
means the arena guard in Task 2 Step 1 is wrong; revert and re-derive.

- [ ] **Step 4: Record and commit**

```bash
cd ~/MisterFPGA-Projects/wt-mister-60fps-p2
git add docs/superpowers/findings/2026-07-29-phase2-baseline.md
git commit -m "findings(phase2): host lever device result"
```

### Task 4: Re-gate the fabric lever on the new period

**Files:**
- Modify: the findings doc (gate section)

- [ ] **Step 1: Recompute what the fabric still owes**

With the host term hidden, period ≈ fabric. Quiet needs 19.30 → 16.69 (**1.16×**);
the Chapter I arrival needs 25.5 → 16.69 (**1.53×**). Size the `dpath` lever (13.59 ms
quiet / 18.0 heavy, ~70% of `frame`) against BOTH, and state plainly whether 60 fps at
the arrival scene is reachable in one more phase or needs a different rendering
strategy.

- [ ] **Step 2: Write the fabric-lever plan (or the honest "not reachable" writeup)**

Invoke superpowers:writing-plans. That plan inherits the standing RTL gates: sim battery
green, `grep -c 276007 *.map.rpt` = 1 (known `xq_mem` only), STA no-regression vs
`cd4d9f1`, device A/B on both scenes.

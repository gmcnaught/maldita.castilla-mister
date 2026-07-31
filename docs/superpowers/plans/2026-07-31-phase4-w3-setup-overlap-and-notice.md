# Phase 4 W3 — setup/vfetch overlap and the notice lever: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reach a delivered frame period ≤ 16.6882 ms on the heavy-B scene by removing the serialized per-triangle setup/vertex-fetch cost from the fabric's `frame` term (−0.21 ms, RTL, bit-exact) and by measuring — then attacking — the 0.56 ms `notice` gap between the fabric's own completion and the host's observation of it.

**Architecture:** Three stages against one Quartus cycle, exactly as `specs/2026-07-31-phase4-w3-setup-overlap-and-notice-design.md` §3 lays out. **Stage A** is host-only and spends no bitstream: a doorbell-delay sweep measures the fabric's post-`C_DONE` dead time directly, which is the component the spec calls "inferred and never measured". **Stage B** is the RTL overlap: the coverage walk's per-pixel constants move out of `blt_tri_setup`'s output registers into a register bank in `blitter_top`, which frees the setup module to compute the *next* triangle while the *current* one walks; a small prefetch sub-FSM fetches that triangle's vertices over the DDR3 read master, which is provably idle during the walk. **Stage C** ships an attribution counter that splits `notice` into its fabric and host halves so the next phase is funded on evidence; the *fix* Stage C also carries is determined by Stage A's answer and is deliberately **not** planned here (see "Stage C decision checkpoint").

**Tech Stack:** SystemVerilog (Quartus Prime / Cyclone V 5CSEBA6, `clk_sys` = 98.4375 MHz), Icarus Verilog for simulation (`fpga/sim/run_sims.sh`), C++17 for the gmloader engine, armhf cross-build in Docker, Python/bash device harness (`scripts/mister_run.sh`) over SSH.

## Global Constraints

Values copied verbatim from the spec. Every task's requirements implicitly include this section.

- **Primary gate:** `period ≤ 16.6882 ms` on **heavy-B** (`cov_px` **213,358**), proven by **C_DONE delta with repeated frames ≈ 0**. A fabric term under a fabric gate is **not** a lock — do not report one as the other.
- **Scanout period is 16.6882 ms / 59.9228 Hz.** Never round it.
- **Fabric clock is 98.4375 MHz.** 1 ms = 98,437.5 cycles.
- **Secondary, non-blocking:** arrival (`cov_px` **245,346**) measured and **not regressed** against **20.04 ms**.
- **Non-regression gates, all must be green before any device claim:**
  - `exact_bad == 0` on every stream vector.
  - synthquad / spanedge hand-computed bucket counts unchanged.
  - `grep 276007 *.map.rpt` empty (no M10K uninference).
  - STA TNS not worse than the baseline build's.
  - `MisterAudio_StarvedFrames()` == 0.
- **Device:** `.62` is the TEST device (`192.168.20.62`). `.81` is PRODUCTION and is **not touched by this phase**. `deploy.py --host` defaults to `.81`, so always pass `--host 192.168.20.62` or use the Makefile (`HOST` defaults to `.62`).
- **Engine deploy = swap then kill.** scp to `gmloader.new`, `mv -f` over the running binary, `killall -9 gmloader`; the handler re-execs it. **Never hand-launch afterwards** — that is how two engines end up on one control block.
- **Never background a device run.** A `mister_run.sh bench` call must complete in the foreground. Docker builds, by contrast, survive a killed shell (`docker wait <id>`).
- **Worktree per workstream, created before the first commit.** Concurrent sessions run on these checkouts.
- **The shipping blitter RTL is the vendored copy in `maldita.castilla-mister/fpga/rtl/`.** `mister-fpga-blitter/rtl/` is a non-shipping v1 spike — do not edit it.
- **Device-run integrity gates,** on every captured log: `grep -c 'suspect=[^0]'` → 0, `grep -c 'incomplete=[^0]'` → 0, `grep -c 'submit timeout'` → 0.
- **A `ramstyle` array's read must NEVER be nested in an FSM case arm** (this rule exists because `tq_data`/`tq_tag` silently failed M10K inference and cost 20,480 stray flops).
- **Contingency (spec §5 R2):** if Stage A shows `notice` cannot yield 0.35 ms by any means, ship Stage B alone as a measured −0.21 ms, report heavy-B at `16.48 + notice`, and re-open the gate with Candidate A funded. **Do not redefine the gate to match what was achieved.**

---

## File Structure

**`maldita.castilla-mister` (RTL + simulation)** — worktree `../wt-maldita-w3`, branch `perf/phase4-w3`:

| File | Responsibility | Change |
|---|---|---|
| `fpga/rtl/blt_tri_setup.sv` | per-triangle setup math (edge functions, 48-cycle reciprocal) | add a `ready` output that exposes the existing internal start-guard condition. No arithmetic change. |
| `fpga/rtl/blitter_top.sv` | the blitter FSM, the TRILIST walk, the perf publish chain | add the `tw_*` walk-constant register bank; repoint the walk's reads at it; add the `pv` vertex/setup prefetch sub-FSM; add the fast path in `S_TRI_NEXT`; add `perf_snap_cyc` / `perf_detect_cyc` and their publish state |
| `fpga/sim/tb_tri_setup.sv` | unit bench for the setup module | assert the `ready` contract |
| `fpga/sim/tb_blitter_trilist_stream.sv` | the captured-frame replay harness + the CYC bucket contract | no change expected; it is the measuring instrument for Stage B |
| `fpga/sim/tb_perf_publish_order.sv` | asserts `C_DONE` is published last | extend to cover the new counter word |
| `fpga/sim/vectors/stream_heavy_f0_{ddr,exp}.hex` | the heavy-B replay vectors | merged in from `test/phase4-stage-b-vectors`, not authored here |

**`gmloader-next` (engine)** — worktree `../wt-gmloader-w3`, branch `perf/phase4-w3-notice-probe`:

| File | Responsibility | Change |
|---|---|---|
| `gmloader/mister/raster_backend_mfgpu.cpp` | the mfgpu raster backend, the submit seam, the C_DONE poll | add the `GMLOADER_MFGPU_PUBLISH_DELAY_US` probe knob + its test hook; later, read and print the new fabric counters |
| `gmloader/mister/raster_backend_test.cpp` | host unit test for the backend | add the probe-knob tests |

**`mister-gmloader` (integration, docs, pins)** — worktree `../wt-mgml-w3`, branch `perf/phase4-w3`:

| File | Responsibility | Change |
|---|---|---|
| `docs/superpowers/findings/2026-07-31-phase4-w3.md` | the phase's findings document | created in Task 4 (Stage A results), extended in Task 12 |
| `docs/superpowers/findings/data/w3-sim-baseline.txt` | the pre-change sim baseline the Stage B delta is measured against | created in Task 1 |
| `external/gmloader-next` | submodule pin | bumped at the end |

---

## Stage C decision checkpoint

**Tasks 1–4 are Stage A. Tasks 5–9 are Stage B plus the Stage C attribution counter. Task 10 builds the bitstream, Tasks 11–12 validate it and write the findings.**

Stage C's *fix* for `notice` is not in this plan, and that is deliberate: the spec makes its content conditional on Stage A's measurement (§3 Stage C, §5 R1). **After Task 4, stop and return to `superpowers:writing-plans`** with Stage A's result to plan the fix, then fold it into the same Quartus cycle as Task 10. Tasks 5–9 do not depend on that answer and should proceed in parallel with the planning of it.

---

## Task 1: Worktrees, the heavy-B vectors, and a recorded sim baseline

Nothing in this phase can be measured without a pre-change number to measure against, and the heavy-B vectors that number needs live on an unmerged branch. This task ends with three isolated worktrees and a committed baseline file.

**Files:**
- Create: `docs/superpowers/findings/data/w3-sim-baseline.txt` (in the `mister-gmloader` worktree)
- Modify: none

**Interfaces:**
- Consumes: nothing.
- Produces: three worktree paths used by every later task — `../wt-maldita-w3` (branch `perf/phase4-w3`), `../wt-gmloader-w3` (branch `perf/phase4-w3-notice-probe`), `../wt-mgml-w3` (branch `perf/phase4-w3`); and the baseline `CYC`/`CYCX` lines for `stream_quiet_f0` and `stream_heavy_f0`.

- [ ] **Step 1: Create the three worktrees**

The maldita worktree must carry the heavy-B vectors, which are on `test/phase4-stage-b-vectors` (commit `ae914d8`) and are **not** merged into `milestone-a`.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git fetch origin
git worktree add ../wt-maldita-w3 -b perf/phase4-w3 origin/milestone-a
cd ../wt-maldita-w3
git merge --no-edit origin/test/phase4-stage-b-vectors

cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
git fetch origin
git worktree add ../wt-gmloader-w3 -b perf/phase4-w3-notice-probe origin/master

```

`../wt-mgml-w3` (branch `perf/phase4-w3`) **already exists** — it is where this plan is committed. Verify rather than re-create it:

```bash
git -C /Users/gmcnaught/MisterFPGA-Projects/wt-mgml-w3 branch --show-current
```
Expected: `perf/phase4-w3`.

- [ ] **Step 2: Verify the heavy-B vectors are present**

Run: `ls /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim/vectors/ | grep heavy`
Expected, both lines present:

```
stream_heavy_f0_ddr.hex
stream_heavy_f0_exp.hex
```

If they are absent the merge did not take — stop and fix that before going further; every Stage B number in this plan is measured on this vector.

- [ ] **Step 3: Run the stub stream bench on the quiet vector**

The stub bench (`P_SRC` returns in a fixed 3 cycles) is the fast one — ~30 s — and it is the right instrument for `setup`/`vfetch`, which are memory-latency-independent.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim
iverilog -g2012 -DSTREAM_VEC='"stream_quiet_f0"' -o /tmp/s_quiet.vvp \
  -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe \
  -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_blitter_trilist_stream.sv \
  && vvp /tmp/s_quiet.vvp | tee /tmp/w3_base_quiet.log
```

Expected: the tail contains `RESULT: PASS`, and a line of the shape
`CYC total=<n> tri=<n> pix_visits=<n> pix_covered=<n> rowsetup=<n> texwait=<n> wr=<n> setup=<n> vfetch=<n> pix=<n> other=<n>`.

- [ ] **Step 4: Run the stub stream bench on the heavy-B vector**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim
iverilog -g2012 -DSTREAM_VEC='"stream_heavy_f0"' -o /tmp/s_heavy.vvp \
  -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe \
  -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_blitter_trilist_stream.sv \
  && vvp /tmp/s_heavy.vvp | tee /tmp/w3_base_heavy.log
```

Expected: `RESULT: PASS`, and the `CYC` line reports `setup=10976 vfetch=9940` (the spec's §2b sizing). If those two fields differ from 10,976 / 9,940, **record the actual values and use them as the plan's baseline** — the −0.2125 ms figure is derived from them, not the other way round.

- [ ] **Step 5: Run the gating PR-tier suite to confirm a clean starting point**

Run: `cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim && ./run_sims.sh --tier=pr 2>&1 | tail -40`
Expected: the summary table shows no `FAIL` for any gating testbench, and the script exits 0 (`echo $?` → `0`). Record any pre-existing non-gating failure verbatim — a failure that was already there must not be attributed to this phase later.

- [ ] **Step 6: Write the baseline record**

Create `/Users/gmcnaught/MisterFPGA-Projects/wt-mgml-w3/docs/superpowers/findings/data/w3-sim-baseline.txt` containing, verbatim and unedited, the `CYC` and `CYCX` lines from both runs plus the head-of-run banner that names the vector, under these headings:

```
# W3 pre-change sim baseline
# Instrument: fpga/sim/tb_blitter_trilist_stream.sv (stub P_SRC, 3-cycle fixed)
# maldita worktree ../wt-maldita-w3 at <paste `git -C ../wt-maldita-w3 rev-parse HEAD`>
# Recorded <date>

## stream_quiet_f0
<paste the "=== stream replay: stream_quiet_f0 ===" line>
<paste the CYC line>
<paste the CYCX line>

## stream_heavy_f0
<paste the "=== stream replay: stream_heavy_f0 ===" line>
<paste the CYC line>
<paste the CYCX line>
```

- [ ] **Step 7: Commit the baseline**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-mgml-w3
git add docs/superpowers/findings/data/w3-sim-baseline.txt
git commit -m "test(w3): record the pre-change sim baseline for the setup/vfetch overlap"
```

---

## Task 2: The doorbell-delay probe knob (engine, TDD)

Stage A must answer "does host-side polling strategy change `notice`?" — but the more decisive question underneath it is *how long the fabric is unable to accept a submit after it writes `C_DONE`*, because `notice = (host + block) − frame` and `pub` is measured at 0.00, meaning the host rings the next doorbell essentially the instant it observes `C_DONE`. If the fabric is still in its `S_SNAP_*` framebuffer-copy tail at that moment, the doorbell sits unseen and the whole dead time lands in the next sample's `notice`.

A delay deliberately inserted between the await returning and the doorbell being rung measures that dead time with no RTL: while the inserted delay is shorter than the fabric's dead time it is **free** (the fabric was not listening anyway, so `period` does not move); once it exceeds the dead time, every further microsecond adds 1:1 to `period`. **The knee is the fabric-side component of `notice`.**

**Files:**
- Modify: `gmloader/mister/raster_backend_mfgpu.cpp` (in `../wt-gmloader-w3`)
- Modify: `gmloader/mister/raster_backend_test.cpp` (in `../wt-gmloader-w3`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - env knob `GMLOADER_MFGPU_PUBLISH_DELAY_US` (integer microseconds; absent or `0` = disabled, which is the shipping default);
  - `static long mf_publish_delay_us(void)` — the parsed value, cached on first call;
  - `static void mf_publish_delay(void)` — spins `CLOCK_MONOTONIC` for that many microseconds; a no-op at 0;
  - `extern "C" long RasterBackend_MFGPU_TestPublishDelayUs(void)` — the parsed value, for the host test;
  - `extern "C" double RasterBackend_MFGPU_TestSpinDelayMs(void)` — runs `mf_publish_delay()` once and returns the elapsed wall time in ms, for the host test.

- [ ] **Step 1: Write the failing test**

Append to `gmloader/mister/raster_backend_test.cpp`, immediately before its `main`'s final return (find `main` and the last `RUN(...)`/`printf("ALL TESTS PASSED` line and place these above it). First add the declarations next to the other `extern "C"` hooks near line 60:

```cpp
// [Phase 4 W3 Stage A] Doorbell-delay probe. The knob inserts a busy-wait between the
// await returning and the doorbell being rung, so a device sweep can find the knee at
// which `period` starts tracking the delay 1:1 -- that knee is the fabric's post-C_DONE
// dead time, the component of `notice` the W3 spec calls inferred and never measured.
extern "C" long   RasterBackend_MFGPU_TestPublishDelayUs(void);
extern "C" double RasterBackend_MFGPU_TestSpinDelayMs(void);
```

Then add the test body:

```cpp
static void test_publish_delay_knob(void) {
    // Default (unset) must be 0 -- the knob is a probe and must cost nothing when off.
    unsetenv("GMLOADER_MFGPU_PUBLISH_DELAY_US");
    RasterBackend_MFGPU_TestReinit(0);
    if (RasterBackend_MFGPU_TestPublishDelayUs() != 0) {
        printf("FAIL: publish delay default is %ld, want 0\n",
               RasterBackend_MFGPU_TestPublishDelayUs());
        exit(1);
    }
    // With the knob off, the delay call must be effectively free.
    double off_ms = RasterBackend_MFGPU_TestSpinDelayMs();
    if (off_ms > 0.05) {
        printf("FAIL: disabled publish delay spun %.3f ms, want <= 0.05\n", off_ms);
        exit(1);
    }
    printf("  publish delay: default off, spin %.4f ms\n", off_ms);
}

static void test_publish_delay_spins(void) {
    // 400 us is the middle of the sweep range the device probe uses.
    setenv("GMLOADER_MFGPU_PUBLISH_DELAY_US", "400", 1);
    RasterBackend_MFGPU_TestReinit(0);
    if (RasterBackend_MFGPU_TestPublishDelayUs() != 400) {
        printf("FAIL: parsed publish delay is %ld, want 400\n",
               RasterBackend_MFGPU_TestPublishDelayUs());
        exit(1);
    }
    double ms = RasterBackend_MFGPU_TestSpinDelayMs();
    // Lower bound is the contract. Upper bound catches a nanosleep-style
    // implementation whose scheduler granularity would blur the knee the device
    // sweep is looking for: the whole measurement rests on the delay being the
    // value asked for, not "at least" it rounded up to a timer tick.
    if (ms < 0.400) { printf("FAIL: spun %.3f ms, want >= 0.400\n", ms); exit(1); }
    if (ms > 0.600) { printf("FAIL: spun %.3f ms, want <= 0.600\n", ms); exit(1); }
    printf("  publish delay: 400 us requested, %.4f ms spun\n", ms);
    unsetenv("GMLOADER_MFGPU_PUBLISH_DELAY_US");
}
```

and call both from `main`, in the same style as the surrounding calls:

```cpp
    test_publish_delay_knob();
    test_publish_delay_spins();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-w3 && make -f Makefile.gmloader raster-backend-test`
Expected: FAIL at link time with `undefined reference to RasterBackend_MFGPU_TestPublishDelayUs` (and `...TestSpinDelayMs`).

- [ ] **Step 3: Implement the knob**

In `gmloader/mister/raster_backend_mfgpu.cpp`, add immediately after `mf_poll_us()` (it ends with the closing brace of the `static long mf_poll_us(void)` body, just before the `// Doorbell->C_DONE wait budget` comment):

```cpp
// [Phase 4 W3 Stage A] Doorbell-delay probe (GMLOADER_MFGPU_PUBLISH_DELAY_US, 0 = off,
// the shipping default). Inserted between the await returning and the doorbell being
// rung, i.e. inside the seam's `pub` term.
//
// WHY IT MEASURES SOMETHING. `pub` is 0.00 ms on 159 of 160 Stage A windows, so the
// host rings the next doorbell the instant it observes C_DONE. If the fabric is still
// in its S_SNAP_* WORK->DDR copy tail at that moment it is not polling C_SUBMIT, and
// the doorbell waits -- that wait lands in the NEXT sample's `notice`, not in any host
// term. So: sweep this delay and watch `period`. While the delay is shorter than the
// fabric's dead time the fabric was not listening anyway and `period` does not move;
// past it, every microsecond adds 1:1. The knee is the fabric-side share of `notice`.
//
// A SPIN, NOT A SLEEP, ON PURPOSE. nanosleep rounds up to the scheduler tick, which is
// coarser than the 0.1-0.8 ms window the knee is expected in -- the rounding would BE
// the measurement. This burns a core for at most the swept delay, on a probe path.
static long mf_publish_delay_us(void) {
    static long v = -1;
    if (v < 0) {
        const char *e = getenv("GMLOADER_MFGPU_PUBLISH_DELAY_US");
        v = (e && *e) ? atol(e) : 0;
        if (v < 0) v = 0;
    }
    return v;
}
static void mf_publish_delay(void) {
    const long us = mf_publish_delay_us();
    if (us <= 0) return;
    struct timespec t0; clock_gettime(CLOCK_MONOTONIC, &t0);
    for (;;) {
        struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
        long elapsed_us = (now.tv_sec - t0.tv_sec) * 1000000L
                        + (now.tv_nsec - t0.tv_nsec) / 1000L;
        if (elapsed_us >= us) return;
    }
}
```

`mf_publish_delay_us()` caches on first call, so the host test must clear the cache between arms. Give it an explicit reset that `RasterBackend_MFGPU_TestReinit` already provides a home for — change the two statics to file-scope so the reinit can clear them:

```cpp
static long g_publish_delay_us = -1;   // -1 = unparsed; see mf_publish_delay_us
```

and rewrite the accessor to use it:

```cpp
static long mf_publish_delay_us(void) {
    if (g_publish_delay_us < 0) {
        const char *e = getenv("GMLOADER_MFGPU_PUBLISH_DELAY_US");
        g_publish_delay_us = (e && *e) ? atol(e) : 0;
        if (g_publish_delay_us < 0) g_publish_delay_us = 0;
    }
    return g_publish_delay_us;
}
```

then, inside `mf_init_once()`, next to the other counter resets (the line `g_publish_count = 0; g_await_count = 0;`), add:

```cpp
    g_publish_delay_us = -1;   // [W3 Stage A] re-read the probe knob on reinit
```

- [ ] **Step 4: Call it from the publish path**

The delay must land **after** the seam's barrier-exit stamp `g_seam_ar` (taken in `mf_publish_barrier`, before it calls `mf_device_publish`) and **before** the doorbell write, so it is measured as `pub` and not as `block`. In `mf_device_publish` the tail reads:

```cpp
    mf_ctrl_barrier();                          // data before doorbell (traced)
    mf_ctrl_wr(MF_C_SUBMIT, g_e.submit_seq);    // doorbell LAST
    g_last_published_seq = g_e.submit_seq;      // [Phase 2 host lever] seam witness
    clock_gettime(CLOCK_MONOTONIC, &g_publish_t0);
```

Insert the call immediately above `mf_ctrl_barrier()`:

```cpp
    mf_publish_delay();                         // [W3 Stage A] probe: delay the doorbell
    mf_ctrl_barrier();                          // data before doorbell (traced)
```

That places it between `g_seam_ar` and `g_publish_t0`, which is exactly the interval `pub` measures, and ahead of the doorbell, which is what the fabric sees. Task 3 Step 5 confirms it is inert when unset; Task 4 Step 4's first self-check confirms `pub` tracks the knob 1:1 when set.

- [ ] **Step 5: Add the test hooks**

Next to the other `RasterBackend_MFGPU_Test*` definitions in `raster_backend_mfgpu.cpp` (search for `RasterBackend_MFGPU_TestPublishCount` and add after it):

```cpp
// [Phase 4 W3 Stage A] Probe-knob observability for the host test.
extern "C" long RasterBackend_MFGPU_TestPublishDelayUs(void) { return mf_publish_delay_us(); }
extern "C" double RasterBackend_MFGPU_TestSpinDelayMs(void) {
    struct timespec a, b;
    clock_gettime(CLOCK_MONOTONIC, &a);
    mf_publish_delay();
    clock_gettime(CLOCK_MONOTONIC, &b);
    return (b.tv_sec - a.tv_sec) * 1000.0 + (b.tv_nsec - a.tv_nsec) / 1e6;
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-w3 && make -f Makefile.gmloader raster-backend-test`
Expected: PASS, with the two new lines in the output:

```
  publish delay: default off, spin 0.0000 ms
  publish delay: 400 us requested, 0.4001 ms spun
```

- [ ] **Step 7: Run the rest of the host suite**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-w3
make -f Makefile.gmloader mf-seam-stat-test
make -f Makefile.gmloader mf-cov-clip-test
make -f Makefile.gmloader blitter-appsurf-test
```
Expected: each prints its own PASS marker and exits 0. The seam accumulator is the instrument the whole of Stage A reads, so it must stay green.

- [ ] **Step 8: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-w3
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_test.cpp
git commit -m "feat(mfgpu): add the W3 Stage A doorbell-delay probe knob"
```

---

## Task 3: Build and deploy the probe engine to `.62`

**Files:**
- Modify: none (build + deploy only)

**Interfaces:**
- Consumes: the Task 2 branch in `../wt-gmloader-w3`.
- Produces: an armhf `gmloadernext.armhf` carrying the probe knob, running on `.62` under the Master_Daemon handler.

- [ ] **Step 1: Cross-build the engine**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
make build-engine GMDIR=../wt-gmloader-w3
```

Expected: the build ends without error and `../wt-gmloader-w3/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf` exists with a fresh mtime. The default `GMDIR` is the plain `../gmloader-next` clone, which is a stale-clone trap — **passing `GMDIR` explicitly is not optional.**

- [ ] **Step 2: Deploy to the test device**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
make deploy-engine GMDIR=../wt-gmloader-w3 HOST=192.168.20.62
```

Expected: `deploy.py` reports a sha1-verified copy and kills the running engine. Do **not** hand-launch afterwards.

- [ ] **Step 3: Confirm exactly one engine is running**

Run: `ssh root@192.168.20.62 'ps | grep -c "[g]mloader"'`
Expected: `1`. busybox has no `pgrep`/`pkill`, so a guard written with them passes vacuously — count with `ps | grep` as above. Two engines on one control block is the failure mode that produced the retracted "native audio wedges the fabric" call.

- [ ] **Step 4: Smoke-run the unchanged default path**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh bench --secs 30 \
  --preset fabric --scene ingame-stage1 --env GMLOADER_MFSUBMIT_STAT=1
```

Expected: a log lands in `bench-results/`, the run exits 0, and the log's integrity gates are clean:

```bash
L=$(ls -t bench-results/*.log | head -1)
grep -c 'suspect=[^0]' "$L"; grep -c 'incomplete=[^0]' "$L"; grep -c 'submit timeout' "$L"
```
Expected: `0`, `0`, `0`. If `submit timeout` appears, `mister_run.sh` already retried up to 3× and exits non-zero on a post-hoc hit — a non-zero exit means the run is unusable, not that the probe is broken.

- [ ] **Step 5: Confirm the knob is inert when unset**

In the same log, the `MFSEAM` lines' `pub=` field must still read `0.00` on essentially every window. Run: `grep -o 'pub=[0-9.]*' "$L" | sort | uniq -c | sort -rn | head -5`
Expected: `pub=0.00` dominant. A non-zero `pub` with the knob unset means the delay call landed on the wrong side of a stamp — go back to Task 2 Step 4.

---

## Task 4: Stage A — the `notice` measurement sweep

This is the task the whole of Stage A exists for. It is a measurement, not a code change; its deliverable is a **stated, measured answer** written into the findings document, and the decision it feeds is what Stage C becomes.

**Files:**
- Create: `docs/superpowers/findings/2026-07-31-phase4-w3.md` (in `../wt-mgml-w3`)

**Interfaces:**
- Consumes: the probe engine from Task 3.
- Produces: the measured fabric-side and host-side split of `notice`; the answer that Stage C's fix is planned against.

- [ ] **Step 1: Reach and confirm the heavy-B scene**

heavy-B is `cov_px` **213,358** on the `ingame-stage1` scene. Confirm scene identity **numerically**, and do not confirm it by triangle count — the gmloader overlay fakes ~168 triangles and has faked progress before.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh bench --secs 40 \
  --preset fabric --scene ingame-stage1 --env GMLOADER_MFSUBMIT_STAT=1
L=$(ls -t bench-results/*.log | head -1)
grep -o 'cov_px=[0-9]*' "$L" | sort | uniq -c | sort -rn | head -10
```

Expected: a plateau at or within 2 % of `cov_px=213358`. Record which wall-clock segment of the run it occupies — every arm below must be read on the **same plateau**, or the comparison is between scenes rather than between arms.

- [ ] **Step 2: Run the doorbell-delay sweep**

Seven arms, 30 s each, all else identical. Run them **in the foreground, one at a time** — a backgrounded device run dies with the shell that started it and leaves `.62` un-torn-down.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
for D in 0 100 200 300 400 600 900; do
  MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh bench --secs 30 \
    --preset fabric --scene ingame-stage1 \
    --env GMLOADER_MFSUBMIT_STAT=1 \
    --env "GMLOADER_MFGPU_PUBLISH_DELAY_US=$D" || { echo "ARM $D FAILED"; break; }
done
```

Expected: seven logs in `bench-results/`, each exiting 0.

- [ ] **Step 3: Extract the term table**

For each arm's log, restricted to `MFSEAM` windows on the heavy-B plateau with `blocked ≥ 90%` (the same restriction the Stage A findings used, so `notice` is taken over essentially every frame in the window):

```bash
for L in $(ls -t bench-results/*.log | head -7); do
  echo "== $L"
  grep 'MFSEAM' "$L" | awk '{for(i=1;i<=NF;i++){split($i,a,"=");v[a[1]]=a[2]}}
       v["blocked"]+0>=90 {printf "period=%s host=%s block=%s pub=%s notice=%s blocked=%s\n",
       v["period"],v["host"],v["block"],v["pub"],v["notice"],v["blocked"]}'
done
```

Record, per arm: the mean `period`, `pub`, and `notice` over those windows, and the window count they rest on.

- [ ] **Step 4: Read the knee**

Two self-checks first, both of which must hold before the knee means anything:
1. `pub` must rise ≈ 1:1 with the requested delay in every arm. If it does not, the delay is not landing inside `pub` and the sweep measures nothing.
2. `frame` must be unchanged across arms (the bitstream is frozen and the scene is matched). A moving `frame` means the arms are on different scenes.

Then: plot `period` against the delay. **The fabric-side share of `notice` is the largest delay at which `period` has not yet risen above its `D=0` value by more than the run-to-run spread.** Past that point `period` rises 1:1.

- [ ] **Step 5: Run the host-side poll-strategy arms**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
for P in 0 50 250; do
  MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh bench --secs 30 \
    --preset fabric --scene ingame-stage1 \
    --env GMLOADER_MFSUBMIT_STAT=1 \
    --env "GMLOADER_MFGPU_POLL_US=$P" || { echo "ARM $P FAILED"; break; }
done
```

Expected: three logs. `P=0` is the shipping default (a pure spin whose ~25,000 uncached reads over a ~30 ms frame put its observe granularity near 1.2 µs), so the prior is that **`notice` will not move** and the host-side share is negligible. Record the measured `notice` per arm either way — a refuted prior recorded is worth more than an unrecorded assumption.

- [ ] **Step 6: Verify the integrity gates on all ten logs**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
for L in $(ls -t bench-results/*.log | head -10); do
  printf '%s suspect=%s incomplete=%s timeout=%s\n' "$L" \
    "$(grep -c 'suspect=[^0]' "$L")" "$(grep -c 'incomplete=[^0]' "$L")" \
    "$(grep -c 'submit timeout' "$L")"
done
```
Expected: `0 0 0` on every line. Any arm that is not clean is discarded, not explained away.

- [ ] **Step 7: Write the Stage A findings**

Create `/Users/gmcnaught/MisterFPGA-Projects/wt-mgml-w3/docs/superpowers/findings/2026-07-31-phase4-w3.md` with this structure, following the Stage A / W2 discipline the spec §6 requires:

```markdown
# Phase 4 W3 — Stage A: `notice`, measured

**Date:** <date>
**Device:** `.62`. `.81` untouched.
**Bitstream:** unchanged for the whole of Stage A (RTL untouched — `git -C ../wt-maldita-w3 status` shows zero files under `fpga/rtl/`).
**Instrument:** `MFSEAM` (`GMLOADER_MFSUBMIT_STAT=1`) + the `GMLOADER_MFGPU_PUBLISH_DELAY_US` probe.
**Design under test:** `specs/2026-07-31-phase4-w3-setup-overlap-and-notice-design.md` §3 Stage A.

## 0. Headline conclusion
<Observed / Inferred, one paragraph each>

## 1. Instrument integrity
<the three gate counts per log, verbatim>

## 2. The doorbell-delay sweep
<the seven-arm table: delay, pub, period, notice, frame, window count>

## 3. The knee, and what it attributes
<where period departs from flat; the fabric-side share of the 0.56>

## 4. The poll-strategy arms
<three-arm table; whether notice moved>

## 5. Verdict against spec §3 Stage A
<does the ~0.40 ms live in the fabric or in DDR read-visibility? Which of §5 R1 / R2 obtains?>

## 6. Unknown
<each Unknown carries "what would answer it">

## 7. Data-trust caveats
<sample depth, scene identity basis, anything the corpus cannot support>
```

Fill every section from the measurements. **Do not** write a conclusion the sweep did not support; if the knee is ambiguous, say the knee is ambiguous and name what would resolve it.

- [ ] **Step 8: Commit the findings**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-mgml-w3
git add docs/superpowers/findings/2026-07-31-phase4-w3.md
git commit -m "docs(findings): Phase 4 W3 Stage A — notice measured by doorbell-delay sweep"
```

- [ ] **Step 9: STOP — Stage C decision checkpoint**

Report the measured answer and return to `superpowers:writing-plans` to plan Stage C's fix against it. Do not invent the fix here. Tasks 5–9 proceed independently in the meantime.

---

## Task 5: Latch the walk constants into `blitter_top` (bit-exact refactor)

The coverage walk reads `blt_tri_setup`'s 18 `dx`/`dy` deltas and `area_recip` on **every pixel**. That is what pins the setup module to the triangle currently being walked, and it is the only reason the module cannot start the next one. Copying those values into a register bank in `blitter_top` at the seed cycle frees the module — and it is, on its own, a **zero-behaviour-change refactor**, which makes it the right place for the strict `exact_bad == 0` gate to catch a mistake before any concurrency exists to confuse the diagnosis.

19 × 48 = 912 flops (~1.2 % ALM against the current 42 %). The bbox needs no copy — `tri_maxx`/`tri_maxy`/`tri_bbox_neg` are already `blitter_top` registers, latched at `S_TRI_SETUP`. The seeds (`ts_w0_0`, `ts_Wu_0`, …) need no copy either — they are consumed in the single `S_TRI_SWAIT` cycle.

**Files:**
- Modify: `fpga/rtl/blitter_top.sv:961-969` (declarations), `:1115-1117`, `:1146-1194`, `:1582-1618`, `:1699` — in `../wt-maldita-w3`
- Test: `fpga/sim/tb_blitter_trilist_stream.sv` (unchanged; used as the gate)

**Interfaces:**
- Consumes: the Task 1 worktree and baseline.
- Produces: `tw_dw0dx, tw_dw1dx, tw_dw2dx, tw_dw0dy, tw_dw1dy, tw_dw2dy, tw_dWudx, tw_dWvdx, tw_dWrdx, tw_dWgdx, tw_dWbdx, tw_dWadx, tw_dWudy, tw_dWvdy, tw_dWrdy, tw_dWgdy, tw_dWbdy, tw_dWady, tw_area_recip` — all `reg signed [47:0]`, loaded at the `S_TRI_SWAIT` seed cycle, read by the walk from `S_TRI_PIX` onward. Task 7 relies on these existing.

- [ ] **Step 1: Declare the register bank**

In `fpga/rtl/blitter_top.sv`, immediately after the `blt_tri_setup registered outputs` wire block (the `wire signed [47:0] ts_dWudy, ...;` line at ~969, before the `blt_tri_setup #(.SHIFT(40)) u_tri_setup (` instantiation), insert:

```systemverilog
    // ── [W3 §2b] walk-constant register bank ──────────────────────────────────
    // The coverage walk reads these on EVERY pixel. Holding them in
    // blt_tri_setup's own output registers is precisely what pins that module to
    // the triangle being walked and makes setup serial with the walk. Copying
    // them here at the S_TRI_SWAIT seed cycle frees the module to start the NEXT
    // triangle immediately, which is what the setup/vfetch overlap needs.
    //
    // Only the values read THROUGHOUT the walk are duplicated: the 18 dx/dy
    // deltas and area_recip (19 x 48 = 912 flops). The bbox is already a
    // blitter_top register (tri_maxx/tri_maxy/tri_bbox_neg, latched at
    // S_TRI_SETUP) and the seeds (ts_w*_0 / ts_W*_0 / ts_ox / ts_oy) are consumed
    // in the single seed cycle, so neither needs a copy.
    //
    // Prefix is tw_ (triangle walk); cw_ is already the composite-write mux.
    reg signed [47:0] tw_dw0dx, tw_dw1dx, tw_dw2dx;
    reg signed [47:0] tw_dw0dy, tw_dw1dy, tw_dw2dy;
    reg signed [47:0] tw_dWudx, tw_dWvdx, tw_dWrdx, tw_dWgdx, tw_dWbdx, tw_dWadx;
    reg signed [47:0] tw_dWudy, tw_dWvdy, tw_dWrdy, tw_dWgdy, tw_dWbdy, tw_dWady;
    reg signed [47:0] tw_area_recip;
```

- [ ] **Step 2: Load the bank at the seed cycle**

In the `S_TRI_SWAIT` non-degenerate branch (the `else begin` at ~1586), add these loads immediately after the `row_Wg<=ts_Wg_0; row_Wb<=ts_Wb_0; row_Wa<=ts_Wa_0;` line and before the `// [pipeline stage 3a] arm both sub-FSMs empty` comment:

```systemverilog
                    // [W3 §2b] copy the walk constants out of blt_tri_setup so the
                    // module is free from this cycle on. Loaded by NBA here, first
                    // read on the next cycle (the walk's first cycle) -- the walk
                    // never reads them in the seed cycle itself, so this is exact.
                    tw_dw0dx<=ts_dw0dx; tw_dw1dx<=ts_dw1dx; tw_dw2dx<=ts_dw2dx;
                    tw_dw0dy<=ts_dw0dy; tw_dw1dy<=ts_dw1dy; tw_dw2dy<=ts_dw2dy;
                    tw_dWudx<=ts_dWudx; tw_dWvdx<=ts_dWvdx; tw_dWrdx<=ts_dWrdx;
                    tw_dWgdx<=ts_dWgdx; tw_dWbdx<=ts_dWbdx; tw_dWadx<=ts_dWadx;
                    tw_dWudy<=ts_dWudy; tw_dWvdy<=ts_dWvdy; tw_dWrdy<=ts_dWrdy;
                    tw_dWgdy<=ts_dWgdy; tw_dWbdy<=ts_dWbdy; tw_dWady<=ts_dWady;
                    tw_area_recip<=ts_area_recip;
```

The `w0m<=ts_w0_0-ts_dw0dx;` lines a few lines above stay on `ts_*` — they run in the seed cycle, where `ts_*` is the correct and only available source.

- [ ] **Step 3: Repoint the walk's reads**

Three sites. **Site 1**, the span-seek direction wires at `:1115-1117` — replace `ts_` with `tw_`:

```systemverilog
    wire sk_need_r = ((w0<0) && (tw_dw0dx>0)) || ((w1<0) && (tw_dw1dx>0)) || ((w2<0) && (tw_dw2dx>0));
    wire sk_need_l = ((w0<0) && (tw_dw0dx<0)) || ((w1<0) && (tw_dw1dx<0)) || ((w2<0) && (tw_dw2dx<0));
    wire sk_block  = ((w0<0) && (tw_dw0dx==0))|| ((w1<0) && (tw_dw1dx==0))|| ((w2<0) && (tw_dw2dx==0));
```

**Site 2**, the three walk tasks at `:1142-1196`. Each body becomes, byte-identical except for the prefix:

```systemverilog
    task automatic step_right;
        begin
            tri_px <= tri_px + 16'd1;
            w0m<=w0; w1m<=w1; w2m<=w2;
            w0<=w0+tw_dw0dx; w1<=w1+tw_dw1dx; w2<=w2+tw_dw2dx;
            Wu<=Wu+tw_dWudx; Wv<=Wv+tw_dWvdx; Wr<=Wr+tw_dWrdx;
            Wg<=Wg+tw_dWgdx; Wb<=Wb+tw_dWbdx; Wa<=Wa+tw_dWadx;
        end
    endtask
```
```systemverilog
    task automatic step_left;
        begin
            tri_px <= tri_px - 16'd1;
            w0<=w0m; w1<=w1m; w2<=w2m;
            w0m<=w0m-tw_dw0dx; w1m<=w1m-tw_dw1dx; w2m<=w2m-tw_dw2dx;
            Wu<=Wu-tw_dWudx; Wv<=Wv-tw_dWvdx; Wr<=Wr-tw_dWrdx;
            Wg<=Wg-tw_dWgdx; Wb<=Wb-tw_dWbdx; Wa<=Wa-tw_dWadx;
        end
    endtask
```
```systemverilog
    task automatic step_row;
        begin
            tri_py <= tri_py + 16'd1;
            tri_px <= row_px;
            row_w0<=row_w0+tw_dw0dy; w0<=row_w0+tw_dw0dy;
            row_w1<=row_w1+tw_dw1dy; w1<=row_w1+tw_dw1dy;
            row_w2<=row_w2+tw_dw2dy; w2<=row_w2+tw_dw2dy;
            row_w0m<=row_w0m+tw_dw0dy; w0m<=row_w0m+tw_dw0dy;
            row_w1m<=row_w1m+tw_dw1dy; w1m<=row_w1m+tw_dw1dy;
            row_w2m<=row_w2m+tw_dw2dy; w2m<=row_w2m+tw_dw2dy;
            row_Wu<=row_Wu+tw_dWudy; Wu<=row_Wu+tw_dWudy;
            row_Wv<=row_Wv+tw_dWvdy; Wv<=row_Wv+tw_dWvdy;
            row_Wr<=row_Wr+tw_dWrdy; Wr<=row_Wr+tw_dWrdy;
            row_Wg<=row_Wg+tw_dWgdy; Wg<=row_Wg+tw_dWgdy;
            row_Wb<=row_Wb+tw_dWbdy; Wb<=row_Wb+tw_dWbdy;
            row_Wa<=row_Wa+tw_dWady; Wa<=row_Wa+tw_dWady;
        end
    endtask
```

`snap_row` between them is pure register-to-register and reads no delta — leave it untouched.

**Site 3**, the reciprocal latch at `:1699`:

```systemverilog
                        recip_q <= $signed(tw_area_recip);
```

- [ ] **Step 4: Prove nothing outside the seed reads `ts_` any more**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3
grep -n 'ts_dw\|ts_dW\|ts_area_recip' fpga/rtl/blitter_top.sv
```
Expected: **every** hit is either inside the `blt_tri_setup` instantiation port map (~971-987), inside the `S_TRI_SWAIT` seed branch, or in a comment. Any hit in the `S_TRI_PIX` walk body or in a `wire` outside the seed is a missed substitution and will silently produce correct pixels today and wrong ones once Task 7 lands.

- [ ] **Step 5: Run the bit-exact gate on both vectors**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim
for V in stream_quiet_f0 stream_heavy_f0; do
  iverilog -g2012 -DSTREAM_VEC="\"$V\"" -o /tmp/s_$V.vvp \
    -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe \
    -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_blitter_trilist_stream.sv \
    && vvp /tmp/s_$V.vvp | tee /tmp/w3_t5_$V.log | tail -5
done
```

Expected on both: `RESULT: PASS` and `=== bad pixels = 0 / <N> (bit-exact mismatches = 0) ===`.

- [ ] **Step 6: Assert the cycle counts are byte-identical to the baseline**

This is a refactor; the CYC line must not have moved by a single cycle.

```bash
diff <(grep '^CYC ' /tmp/w3_base_heavy.log) <(grep '^CYC ' /tmp/w3_t5_stream_heavy_f0.log)
diff <(grep '^CYC ' /tmp/w3_base_quiet.log) <(grep '^CYC ' /tmp/w3_t5_stream_quiet_f0.log)
```
Expected: no output from either `diff`. A difference here means the refactor changed timing, which it must not.

- [ ] **Step 7: Run the gating suite**

Run: `cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim && ./run_sims.sh --tier=pr 2>&1 | tail -40`
Expected: exits 0; the synthquad and spanedge hand-computed bucket gates print no `GATE-MISMATCH`.

- [ ] **Step 8: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3
git add fpga/rtl/blitter_top.sv
git commit -m "refactor(blitter): latch the walk constants into blitter_top (bit-exact, no timing change)"
```

---

## Task 6: Expose `ready` on `blt_tri_setup`

The module already refuses a `start` that arrives while it is busy — silently, by an internal guard. Task 7 pulses `start` from a concurrent sub-FSM, and a silently dropped start there would mean the prefetch never completes and the walk stalls at `S_TRI_NEXT` forever. Publishing the guard as a `ready` output turns a silent drop into an explicit, assertable handshake.

**Files:**
- Modify: `fpga/rtl/blt_tri_setup.sv:86-120` (port list) and the region around `:304`
- Modify: `fpga/rtl/blitter_top.sv` (instantiation + one new wire)
- Test: `fpga/sim/tb_tri_setup.sv`

**Interfaces:**
- Consumes: nothing from Task 5.
- Produces: `blt_tri_setup.ready` — a `wire` output, high exactly when a `start` pulse would be accepted; `blitter_top`'s `wire ts_ready` carrying it. Task 7 gates its `start` pulse on `ts_ready`.

- [ ] **Step 1: Write the failing test**

In `fpga/sim/tb_tri_setup.sv`, add a check that `ready` tracks acceptance. Add to the DUT instantiation a `.ready(ts_ready)` connection and a `wire ts_ready;` declaration, then append this task and call it from the existing test sequence:

```systemverilog
  // [W3 §2b] The ready contract: a start pulsed while !ready must be IGNORED (the
  // module's internal guard already does this), and ready must be low from the
  // accepted start until the outputs are valid. Task 7 pulses start from a
  // concurrent sub-FSM, where a silently dropped start stalls the walk forever.
  task check_ready_contract;
    integer guard;
    begin
      // idle => ready
      @(posedge clk);
      if (ts_ready !== 1'b1) begin
        $display("RESULT: FAIL (ready low while idle)"); $finish;
      end
      // accept a start, then ready must fall and stay low until valid
      start <= 1'b1; @(posedge clk); start <= 1'b0;
      @(posedge clk);
      if (ts_ready !== 1'b0) begin
        $display("RESULT: FAIL (ready still high one cycle after an accepted start)");
        $finish;
      end
      guard = 0;
      while (!valid && guard < 200) begin
        if (ts_ready !== 1'b0) begin
          $display("RESULT: FAIL (ready rose at cycle %0d before valid)", guard);
          $finish;
        end
        @(posedge clk); guard = guard + 1;
      end
      if (guard >= 200) begin
        $display("RESULT: FAIL (no valid within 200 cycles)"); $finish;
      end
      $display("  ready contract OK (valid after %0d cycles)", guard);
    end
  endtask
```

Wire the vertices to any non-degenerate triangle already set up in the bench before calling it; reuse whatever case the bench's first test already loads.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim
./run_sims.sh tb_tri_setup 2>&1 | tail -20
```
Expected: FAIL — iverilog errors with `port ``ready'' is not a port of u_dut` (or equivalent) because the output does not exist yet.

- [ ] **Step 3: Add the output**

In `fpga/rtl/blt_tri_setup.sv`, add to the port list immediately after `input wire start,` (line ~91):

```systemverilog
    // [W3 §2b] high exactly when a `start` pulse would be ACCEPTED. Mirrors the
    // internal guard below one-for-one; published so a concurrent producer cannot
    // lose a start silently.
    output wire                ready,
```

and next to the internal guard (the `if (start && !busy && !mac_busy && !e1 && ...)` at ~304), add the continuous assignment at module scope — **not** inside the always block:

```systemverilog
    // Must stay literally identical to the start guard's condition below. If a new
    // pipeline stage is added, it belongs in BOTH or the handshake lies.
    assign ready = !busy && !mac_busy && !e1 && !e1b && !e1c && !g1 && !g2 && !g3 && !g4;
```

Then rewrite the guard to consume it, so the two can never drift:

```systemverilog
            if (start && ready) begin
```

- [ ] **Step 4: Connect it in `blitter_top`**

Add to the `ts_*` wire block in `blitter_top.sv`:

```systemverilog
    wire               ts_ready;    // [W3 §2b] a start would be accepted this cycle
```

and to the instantiation port map, on the `.clk(clk), .rst(rst), .start(tri_setup_start),` line:

```systemverilog
        .clk(clk), .rst(rst), .start(tri_setup_start), .ready(ts_ready),
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim
./run_sims.sh tb_tri_setup 2>&1 | tail -20
```
Expected: PASS, with `  ready contract OK (valid after <n> cycles)` in the output and `n` around 54.

- [ ] **Step 6: Confirm nothing else moved**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim
iverilog -g2012 -DSTREAM_VEC='"stream_heavy_f0"' -o /tmp/s_t6.vvp \
  -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe \
  -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_blitter_trilist_stream.sv \
  && vvp /tmp/s_t6.vvp | tee /tmp/w3_t6_heavy.log | tail -5
diff <(grep '^CYC ' /tmp/w3_base_heavy.log) <(grep '^CYC ' /tmp/w3_t6_heavy.log)
```
Expected: `RESULT: PASS`, `bit-exact mismatches = 0`, and no `diff` output.

- [ ] **Step 7: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3
git add fpga/rtl/blt_tri_setup.sv fpga/rtl/blitter_top.sv fpga/sim/tb_tri_setup.sv
git commit -m "feat(blitter): publish blt_tri_setup.ready as an explicit start handshake"
```

---

## Task 7: The vertex/setup prefetch sub-FSM

This is the lever. While triangle N walks, fetch triangle N+1's six vertex qwords and run its setup, so that `S_TRI_NEXT` can seed the next triangle immediately instead of paying ~48 cycles of divide plus six DDR round trips per triangle.

**The DDR3 read master is provably idle during the walk.** Between `S_TRI_SWAIT` and `S_TRI_NEXT` the FSM sits in `S_TRI_PIX`, whose case arm never touches `bm_rd`/`bm_addr`; texels come from the SDRAM `P_SRC` port (`src_in_sdram` is hardwired 1, so texels never touch DDR3) and framebuffer writes go to `comp_fbram`. So the prefetch steals no cycle from the walk — it re-times traffic that already existed, from between triangles to during them.

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` — declarations near `:448`, the TRILIST command entry at `:1447`, the reset block at `:1214`, the `S_TRI_SWAIT` gate at `:1582`, `S_TRI_NEXT` at `:2158`, and a new prefetch block after the `case (state)` `endcase`
- Test: `fpga/sim/tb_blitter_trilist_stream.sv` (unchanged; the gate)

**Interfaces:**
- Consumes: `tw_*` (Task 5), `ts_ready` (Task 6).
- Produces: nothing consumed by later tasks except the measured cycle reduction.

- [ ] **Step 1: Declare the prefetch state**

In `fpga/rtl/blitter_top.sv`, immediately after `reg tri_setup_start;` (~448), insert:

```systemverilog
    // ── [W3 §2b] vertex + setup prefetch engine ───────────────────────────────
    // Runs CONCURRENTLY with the coverage walk, i.e. only while state==S_TRI_PIX.
    // That is the one state in which the main FSM leaves bm_*/mem_* idle: the
    // walk's texels come from the SDRAM P_SRC port (src_in_sdram is hardwired 1)
    // and its writes go to comp_fbram, so nothing else drives the DDR3 read
    // master between S_TRI_SWAIT and S_TRI_NEXT. The prefetch therefore steals no
    // walk cycle -- it re-times reads that already happened, from BETWEEN
    // triangles to DURING them.
    //
    // It has its OWN issue/accept/response handshake rather than borrowing
    // S_RD_WAIT, which is a main-FSM subroutine. That includes its own reissue
    // watchdog on the same RW_WD_MAX window: the startup wedge (a lost f2h read
    // response at core-load bring-up) was exactly a master that never re-issued,
    // and a second requester without the watchdog would re-introduce it.
    localparam [2:0] PV_IDLE  = 3'd0,   // nothing in flight
                     PV_ISSUE = 3'd1,   // drive bm_rd for qword pv_k
                     PV_WAIT  = 3'd2,   // await the response (with reissue watchdog)
                     PV_DECV  = 3'd3,   // unpack the 6 qwords into tri_v*
                     PV_START = 3'd4,   // pulse blt_tri_setup.start; latch the bbox
                     PV_RUN   = 3'd5,   // setup computing; await ts_valid
                     PV_HOLD  = 3'd6;   // ts_* hold the NEXT triangle: seed on demand
    reg  [2:0]   pv;
    reg  [2:0]   pv_k;                  // which of the 6 vertex qwords
    reg  [63:0]  pv_qw [0:5];
    reg  [31:0]  pv_base;               // qword address of the prefetched vertex 0
    reg          pv_rd_issued;
    reg  [21:0]  pv_wd;                 // reissue watchdog (same window as rw_wd)
    // Pre-registered bbox for the prefetched triangle, for the same reason
    // S_TRI_SETUP pre-registers it: keep the raw-vertex compare cloud out of the
    // seed cycle, which was the -4.5 ns worst setup path before it was hoisted.
    reg  [15:0]  pv_maxx, pv_maxy;
    reg          pv_bbox_neg;
    reg          pv_ready;              // PV_HOLD reached: ts_* are the next triangle's
```

- [ ] **Step 2: Reset it**

In the reset branch, on the line `tri_busy<=1'b0; tri_setup_start<=1'b0;` (~1214), append:

```systemverilog
            pv<=PV_IDLE; pv_rd_issued<=1'b0; pv_wd<=22'd0; pv_ready<=1'b0;
```

and at the TRILIST command entry (~1447, in the `else if (c_opcode==OP_TRILIST)` block, after `tri_idx <= 16'd0;`):

```systemverilog
                    // [W3 §2b] a new command's first triangle always takes the
                    // serial path; the prefetch arms once its walk begins.
                    pv <= PV_IDLE; pv_rd_issued <= 1'b0; pv_ready <= 1'b0;
```

- [ ] **Step 3: Add the watchdog tick**

Next to the existing `S_RD_WAIT` dwell counter (the `if (state != S_RD_WAIT) rw_wd <= 22'd0;` pair at ~1262), add:

```systemverilog
            // [W3 §2b] prefetch reissue watchdog, mirroring rw_wd. Reset outside
            // PV_WAIT; PV_WAIT's own reissue branch clears it too (that NBA runs
            // later in this block, so it wins on the reissue cycle).
            if (pv != PV_WAIT) pv_wd <= 22'd0;
            else if (pv_wd != RW_WD_MAX) pv_wd <= pv_wd + 22'd1;
```

- [ ] **Step 4: Add the prefetch block**

Insert immediately **after** the main `case (state) ... endcase` (the `endcase` at ~2335, before the `end` that closes the `always` block's else branch):

```systemverilog
            // ── [W3 §2b] the prefetch engine ──────────────────────────────────
            // Gated on state==S_TRI_PIX so its bm_* drive can never collide with
            // the main FSM's: that is the only state in which the case above
            // leaves bm_rd/bm_addr untouched. Placed AFTER the case so its NBAs
            // win over the block-top `bm_rd<=1'b0` default.
            if (state == S_TRI_PIX) begin
                case (pv)
                PV_IDLE: if (tri_idx + 16'd1 < tri_count) begin
                    pv_base <= tri_entry_qw + (tri_idx + 16'd1)*16'd6;
                    pv_k    <= 3'd0;
                    pv      <= PV_ISSUE;
                end
                PV_ISSUE: begin
                    bm_rd        <= 1'b1;
                    bm_addr      <= pv_base + {29'd0, pv_k};
                    pv_rd_issued <= 1'b0;
                    pv           <= PV_WAIT;
                end
                PV_WAIT: begin
                    if (!pv_rd_issued) begin
                        bm_rd <= 1'b1;                    // hold the request
                        if (!mem_busy) pv_rd_issued <= 1'b1;
                    end else if (mem_dout_ready) begin
                        pv_qw[pv_k]  <= mem_dout;
                        pv_rd_issued <= 1'b0;
                        if (pv_k == 3'd5) pv <= PV_DECV;
                        else begin pv_k <= pv_k + 3'd1; pv <= PV_ISSUE; end
                    end else if (pv_wd == RW_WD_MAX) begin
                        pv_rd_issued <= 1'b0;             // response lost: re-arm
                        bm_rd        <= 1'b1;
                        pv_wd        <= 22'd0;
                        if (~&rd_reissue_cnt) rd_reissue_cnt <= rd_reissue_cnt + 8'd1;
                    end
                end
                // Identical unpack to S_TRI_DECV. Writing tri_v* here is safe: the
                // CURRENT triangle's setup latched its vertices at P1 on `start`
                // and the walk reads only tw_*/w*/W*, never tri_v*.
                PV_DECV: begin
                    tri_vx0<=pv_qw[0][15:0];  tri_vy0<=pv_qw[0][31:16];
                    tri_vu0<=pv_qw[0][47:32]; tri_vv0<=pv_qw[0][63:48];
                    tri_vr0<=pv_qw[1][7:0];   tri_vg0<=pv_qw[1][15:8];
                    tri_vb0<=pv_qw[1][23:16]; tri_va0<=pv_qw[1][31:24];
                    tri_vx1<=pv_qw[2][15:0];  tri_vy1<=pv_qw[2][31:16];
                    tri_vu1<=pv_qw[2][47:32]; tri_vv1<=pv_qw[2][63:48];
                    tri_vr1<=pv_qw[3][7:0];   tri_vg1<=pv_qw[3][15:8];
                    tri_vb1<=pv_qw[3][23:16]; tri_va1<=pv_qw[3][31:24];
                    tri_vx2<=pv_qw[4][15:0];  tri_vy2<=pv_qw[4][31:16];
                    tri_vu2<=pv_qw[4][47:32]; tri_vv2<=pv_qw[4][63:48];
                    tri_vr2<=pv_qw[5][7:0];   tri_vg2<=pv_qw[5][15:8];
                    tri_vb2<=pv_qw[5][23:16]; tri_va2<=pv_qw[5][31:24];
                    pv <= PV_START;
                end
                // ts_ready is high here in every expected case (the current
                // triangle's setup completed before its walk began), but the pulse
                // is gated on it anyway: blt_tri_setup drops a start it cannot
                // accept, and a dropped start here would park the walk in
                // S_TRI_NEXT forever.
                PV_START: if (ts_ready) begin
                    tri_setup_start <= 1'b1;
                    pv_maxx <= tri_maxx_cl; pv_maxy <= tri_maxy_cl;
                    pv_bbox_neg <= tri_bbox_neg_c;
                    pv <= PV_RUN;
                end
                PV_RUN: if (ts_valid) begin
                    pv_ready <= 1'b1;
                    pv       <= PV_HOLD;
                end
                PV_HOLD: ;   // ts_* hold the next triangle; S_TRI_NEXT consumes them
                default: pv <= PV_IDLE;
                endcase
            end
```

- [ ] **Step 5: Widen the seed gate**

`S_TRI_SWAIT` gates on `ts_valid`, a one-cycle pulse that has already fired by the time the prefetched triangle is seeded. Change the gate at `:1582` to:

```systemverilog
            // [W3 §2b] `pv_ready` is the prefetch path's latched equivalent of the
            // one-cycle ts_valid pulse. The two are mutually exclusive by
            // construction: pv_ready is set only in PV_RUN->PV_HOLD, and the slow
            // path into this state is taken only when pv==PV_IDLE.
            S_TRI_SWAIT: if (ts_valid || pv_ready) begin
```

and inside it, on **both** branches (the degenerate/reject `state<=S_TRI_NEXT` line and the `else begin` seed branch), clear the flag. Add `pv_ready <= 1'b0;` as the first statement of the `if (ts_degenerate || ...)` branch and as the first statement of the `else begin` branch.

- [ ] **Step 6: Add the fast path in `S_TRI_NEXT`**

Replace the body of `S_TRI_NEXT` (`:2158-2166`) with:

```systemverilog
            S_TRI_NEXT: begin
                if (tri_idx + 16'd1 < tri_count) begin
                    // [W3 §2b] fast path: the prefetch already fetched this
                    // triangle's vertices and ran its setup during the previous
                    // triangle's walk, so ts_* hold its outputs and the bbox is
                    // pre-registered in pv_*. Seed straight from them.
                    if (pv == PV_HOLD) begin
                        tri_idx      <= tri_idx + 16'd1;
                        tri_maxx     <= pv_maxx;
                        tri_maxy     <= pv_maxy;
                        tri_bbox_neg <= pv_bbox_neg;
                        pv           <= PV_IDLE;
                        state        <= S_TRI_SWAIT;
                    end else if (pv == PV_IDLE) begin
                        // No prefetch ran (first triangle of a command, or the
                        // previous walk was too short to cover the fetch): the
                        // original serial path, unchanged.
                        tri_idx <= tri_idx + 16'd1;
                        state   <= S_TRI_VFETCH;
                    end
                    // else: a prefetch is mid-flight. HOLD here. Leaving now would
                    // let the main FSM issue bm_rd with a prefetch read still
                    // outstanding, and the two responses are indistinguishable on
                    // mem_dout_ready.
                end else if (pv == PV_IDLE || pv == PV_HOLD) begin
                    // Command done. Same quiescence requirement: never leave the
                    // TRILIST walk with a prefetch read outstanding.
                    tri_busy <= 1'b0;
                    pv       <= PV_IDLE;
                    pv_ready <= 1'b0;
                    state    <= S_NEXT_CMD;
                end
            end
```

Note the prefetch block in Step 4 is gated on `state == S_TRI_PIX`, so a prefetch that is mid-flight when the walk ends **cannot advance**, and `S_TRI_NEXT` would hold forever. Close that: change the Step 4 gate from

```systemverilog
            if (state == S_TRI_PIX) begin
```
to
```systemverilog
            // Also ticks in S_TRI_NEXT so an in-flight prefetch can DRAIN — that
            // state issues no bm_* of its own, and S_TRI_NEXT refuses to leave
            // until pv is quiescent, so the two can never both drive the master.
            if ((state == S_TRI_PIX) || (state == S_TRI_NEXT)) begin
```

and guard `PV_IDLE`'s arming so a drain-only tick cannot start a *new* prefetch from `S_TRI_NEXT`:

```systemverilog
                PV_IDLE: if ((state == S_TRI_PIX) && (tri_idx + 16'd1 < tri_count)) begin
```

- [ ] **Step 7: Check the bit-exact gate on both vectors**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim
for V in stream_quiet_f0 stream_heavy_f0; do
  iverilog -g2012 -DSTREAM_VEC="\"$V\"" -o /tmp/s7_$V.vvp \
    -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe \
    -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_blitter_trilist_stream.sv \
    && vvp /tmp/s7_$V.vvp | tee /tmp/w3_t7_$V.log | tail -8
done
```

Expected on both: `RESULT: PASS` and `bit-exact mismatches = 0`. The overlap changes **when** setup runs, never what it computes — a single changed pixel means the prefetch is seeding the wrong triangle, and no cycle number from the run is usable until that is fixed.

- [ ] **Step 8: Measure the delta**

```bash
grep '^CYC ' /tmp/w3_base_heavy.log
grep '^CYC ' /tmp/w3_t7_stream_heavy_f0.log
```

Expected on heavy-B: `setup` falls from 10,976 to roughly one cycle per triangle (~230, the single `S_TRI_SWAIT` seed cycle each) and `vfetch` falls from 9,940 to roughly the first triangle's share, because the prefetch's cycles are spent inside the `S_TRI_PIX` umbrella and are bucketed by whatever `pb` is doing. `total` should fall by ~20,900 cycles ≈ **0.2125 ms at 98.4375 MHz**.

Compute it explicitly and record it:
```bash
python3 - <<'EOF'
base = <paste baseline total>
new  = <paste new total>
print(f"delta = {base-new} cyc = {(base-new)/98437.5:.4f} ms")
EOF
```

**Report the measured value per scene, not the single 0.2125 figure** (spec §5 R4): repeat the same extraction for `stream_quiet_f0`. Quiet has a different triangle size distribution and will recover a different amount.

- [ ] **Step 9: Run the gating suite**

Run: `cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim && ./run_sims.sh --tier=pr 2>&1 | tail -40`
Expected: exits 0. Pay particular attention to `tb_arb_beat_owner`, `tb_arb_blt_timeout`, `tb_arb_borrow`, `tb_arb_reader_burst` and `tb_blitter_rdwait_reissue` — the prefetch adds a second requester on the DDR3 read master, and those are the benches that model ownership and lost-beat recovery.

- [ ] **Step 10: Run the real-cache bench on heavy-B**

The stub bench's `texwait` is a floor. The real-cache bench is the one calibrated to within 0.31 % of device fabric, so it is what sizes the change honestly. It takes ~10× as long (budget up to 60 min).

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim
iverilog -g2012 -DSTREAM_VEC='"stream_heavy_f0"' -o /tmp/sc7.vvp \
  -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe \
  -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_blitter_trilist_streamcache.sv \
  && vvp /tmp/sc7.vvp | tee /tmp/w3_t7_sc_heavy.log | tail -10
```
Expected: `RESULT: PASS`, `bit-exact mismatches = 0`, and an `MS total=` line. Compare it against the pre-change real-cache figure (`MS total=16.468` per spec §8); the drop should be ≈ the Step 8 delta.

- [ ] **Step 11: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3
git add fpga/rtl/blitter_top.sv
git commit -m "perf(blitter): overlap per-triangle setup and vertex fetch with the previous walk"
```

---

## Task 8: The `notice` attribution counter (Stage C rider)

`notice` is currently a single number with an inferred split. Task 4 measures that split behaviourally; this counter makes it **durable and re-checkable** from any future run, which is what funds the next phase's levers on evidence rather than on inference. It ships regardless of what Stage A concluded.

Two fabric-side quantities bracket the whole of `notice`:
- **`perf_snap_cyc`** — cycles from the `C_DONE` write being accepted to the FSM returning to `S_POLL_SUBMIT`. This is the `S_SNAP_*` WORK→DDR copy tail, during which a doorbell cannot be seen. Designed at ~0.158 ms; whether it *is* that is the open question.
- **`perf_detect_cyc`** — cycles from entering `S_POLL_SUBMIT` to `S_CHK_NEW` observing new work. This is the fabric's own submit-detect round trip.

`notice − (snap + detect)` is then the host's share, by subtraction.

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` — counters near `:307`, accumulation near `:1240`, a new publish state before `S_WR_DONE`
- Modify: `fpga/sim/tb_perf_publish_order.sv`
- Modify: `gmloader/mister/raster_backend_mfgpu.cpp` (in `../wt-gmloader-w3`) — read and print the new word

**Interfaces:**
- Consumes: nothing from Tasks 5–7.
- Produces: the packed counter word at **`C_CMDCOUNT.hi`**, host address `0x3B00000C`, layout `{snap8[31:16], detect8[15:0]}` where each field counts **eighths of a cycle-count** (i.e. `cyc >> 3`, saturating at `16'hFFFF` ≈ 5.33 ms). Engine-side: `MFSEAM` gains `snap=<ms> detect=<ms>` fields.

**Why `C_CMDCOUNT.hi`:** every other high word is taken (`C_FLAGS.hi` = covered_px, `C_DONE.hi` = frame, `C_STATUS.hi` = texwait, `C_SRCSEL.hi` = tri), and control-block qword 8 aliases the ring base so there is no spare qword. The host writes `C_CMDCOUNT` as a 32-bit store at the qword's low half (`mf_ctrl_wr` writes `qw*8`), so a fabric write with `be=8'hF0` touches strictly disjoint bytes — exactly the pattern `C_FLAGS.hi` already ships.

- [ ] **Step 1: Write the failing test**

In `fpga/sim/tb_perf_publish_order.sv`, extend the write-order monitor to cover the new word. Add a timestamp register beside the existing ones (`t_status`, `t_srcsel`, `t_flags`):

```systemverilog
  reg [31:0] t_cmdcnt = 32'd0;   // [W3 Stage C] notice attribution word
```

add its capture next to the others (near the `if (wr_idx == (CTRL + \`C_FLAGS)) t_flags <= cyc;` line):

```systemverilog
    if (wr_idx == (CTRL + `C_CMDCOUNT)) t_cmdcnt <= cyc;
```

extend the display line and the verdict chain — add `t_cmdcnt > 0` to the "monitor saw no write" guard's condition, and add to the pass condition and the failure diagnostics:

```systemverilog
      if (t_done <= t_cmdcnt) $display("    C_DONE(%0d) <= C_CMDCOUNT(%0d) -> notice attribution read stale", t_done, t_cmdcnt);
```

The pass condition must become `t_done > t_status && t_done > t_srcsel && t_done > t_flags && t_done > t_cmdcnt`.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim
./run_sims.sh tb_perf_publish_order 2>&1 | tail -20
```
Expected: FAIL — `RESULT: FAIL (monitor saw no write: ... t_cmdcnt=0)`, because the fabric does not write that word yet.

- [ ] **Step 3: Add the counters**

In `blitter_top.sv`, next to `reg [31:0] perf_frame_cyc, perf_pipe_cyc;` (~307):

```systemverilog
    // [W3 Stage C] `notice` attribution. notice = (host+block) - frame is a single
    // number today with an inferred split. These two bracket its fabric half:
    //   perf_snap_cyc   C_DONE written -> back in S_POLL_SUBMIT. The S_SNAP_* WORK
    //                   ->DDR copy tail, during which a doorbell cannot be SEEN
    //                   (S_POLL_SUBMIT is the only state that reads C_SUBMIT).
    //                   Designed at ~0.158 ms; whether it IS that is the question.
    //   perf_detect_cyc S_POLL_SUBMIT entered -> S_CHK_NEW sees new work. The
    //                   fabric's own submit-detect round trip.
    // The host's share of notice is then notice - (snap + detect), by subtraction.
    // Both are LIVE counters for the interval just ended; they are latched into the
    // published pair at S_WR_NOTICE so the host reads a coherent frame's worth.
    reg  [31:0] perf_snap_cyc, perf_detect_cyc;
    reg  [31:0] snap_run, detect_run;
    reg         snap_counting, detect_counting;
```

- [ ] **Step 4: Accumulate them**

Add to the reset branch (beside `perf_frame_cyc<=32'd0; perf_pipe_cyc<=32'd0;` at ~1204):

```systemverilog
            perf_snap_cyc<=32'd0; perf_detect_cyc<=32'd0;
            snap_run<=32'd0; detect_run<=32'd0;
            snap_counting<=1'b0; detect_counting<=1'b0;
```

Add the free-running accumulation immediately after the `if (!idle) begin ... end` perf block (~1252), **outside** it — these intervals both live in the window `idle` is high, so gating them on `!idle` would count nothing:

```systemverilog
            // [W3 Stage C] snap tail: runs from the C_DONE write leaving S_WR_DONE
            // until S_POLL_SUBMIT is reached. detect: runs from S_POLL_SUBMIT until
            // S_CHK_NEW takes the new-work branch. Both are armed/disarmed in the
            // states themselves (below); here they just tick.
            if (snap_counting)   snap_run   <= snap_run   + 32'd1;
            if (detect_counting) detect_run <= detect_run + 32'd1;
```

Arm the snap counter where the `C_DONE` write is handed to `S_WR_WAIT` — in `S_WR_DONE`, after `wr_ret<=S_SNAP_WAIT; state<=S_WR_WAIT;`:

```systemverilog
                snap_run <= 32'd0; snap_counting <= 1'b1;   // [W3 Stage C]
```

Disarm it and arm detect on entry to `S_POLL_SUBMIT`, inside that state's body (which currently reads `idle<=1; bm_rd<=1; bm_addr<=...`):

```systemverilog
                // [W3 Stage C] close the snap tail on the FIRST cycle of the poll
                // loop and open the detect interval. S_POLL_SUBMIT re-enters itself
                // every poll round, so only latch the tail once per frame.
                if (snap_counting) begin
                    perf_snap_cyc <= snap_run;
                    snap_counting <= 1'b0;
                    detect_run    <= 32'd0;
                    detect_counting <= 1'b1;
                end
```

Close detect in `S_CHK_NEW`'s new-work branch, beside the other per-frame resets:

```systemverilog
                    perf_detect_cyc <= detect_run;   // [W3 Stage C]
                    detect_counting <= 1'b0;
```

- [ ] **Step 5: Publish it**

Add the new state constant beside the others in the state `localparam` block (`S_FRAME_VCTRL=6'd20, S_WR_DONE=6'd21, S_WR_STATUS=6'd22,` at ~156). Pick the lowest unused 6-bit code — check with `grep -o "6'd[0-9]*" fpga/rtl/blitter_top.sv | sort -u -t d -k2 -n` and take the first gap. **Do not renumber any existing state**: the wedge probe publishes raw `state_at_peak` values and past findings quote them by number.

```systemverilog
        S_WR_NOTICE=6'd<gap>,   // [W3 Stage C] publish the notice attribution word
```

Retarget `S_WR_COVPX`'s return so the chain becomes `... -> S_WR_COVPX -> S_WR_NOTICE -> S_WR_DONE`. In `S_WR_COVPX`, change `wr_ret<=S_WR_DONE;` to `wr_ret<=S_WR_NOTICE;`, then add the new state immediately before `S_WR_DONE`:

```systemverilog
            // [W3 Stage C] publish the notice attribution pair to the spare HIGH 32
            // of C_CMDCOUNT; be=0xF0 preserves the host-written command count in the
            // low word (the host writes it 32-bit at qw*8, so the bytes are
            // disjoint -- the same split C_FLAGS.hi already ships).
            // Units: cycles >> 3, saturating at 0xFFFF (= 5.33 ms at 98.4375 MHz),
            // so both fields fit a 16-bit half with room over the ~0.16-0.6 ms they
            // are expected in. Sequenced BEFORE S_WR_DONE: C_DONE is the host's
            // release barrier and anything published after it is read one frame
            // stale. Guarded by tb_perf_publish_order.
            S_WR_NOTICE: begin
                bm_wr<=1; bm_be<=8'hF0; bm_addr<=`BLTCTRL_QW+`C_CMDCOUNT;
                bm_din<={ (perf_snap_cyc[31:3]   > 29'h0000FFFF) ? 16'hFFFF : perf_snap_cyc[18:3],
                          (perf_detect_cyc[31:3] > 29'h0000FFFF) ? 16'hFFFF : perf_detect_cyc[18:3],
                          32'd0 };
                wr_ret<=S_WR_DONE;
                state<=S_WR_WAIT;
            end
```

- [ ] **Step 6: Run the test to verify it passes**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim
./run_sims.sh tb_perf_publish_order 2>&1 | tail -20
```
Expected: `RESULT: PASS`, and the publish-cycle line now includes a non-zero `C_CMDCOUNT=<n>` with `n < ` the `C_DONE` cycle.

- [ ] **Step 7: Confirm the rasteriser is untouched**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim
iverilog -g2012 -DSTREAM_VEC='"stream_heavy_f0"' -o /tmp/s8.vvp \
  -I ../rtl -I ../rtl/jtframe -I ../sys -I . -y ../rtl -y ../rtl/jtframe \
  -y ../sys -y . -Y .sv -Y .v *_stub.sv tb_blitter_trilist_stream.sv \
  && vvp /tmp/s8.vvp | tee /tmp/w3_t8_heavy.log | tail -8
diff <(grep '^CYC ' /tmp/w3_t7_stream_heavy_f0.log) <(grep '^CYC ' /tmp/w3_t8_heavy.log)
```
Expected: `RESULT: PASS`, `bit-exact mismatches = 0`. The `diff` may show `total` and `other` larger by the handful of cycles the extra publish write costs; `tri`, `pix`, `wr`, `texwait`, `setup` and `vfetch` must be **identical**.

- [ ] **Step 8: Read the counter in the engine**

`MF_C_CMDCOUNT = 1` already exists in the control-block index enum, so no new constant is needed. In `../wt-gmloader-w3/gmloader/mister/raster_backend_mfgpu.cpp`, inside `mf_submit_stat` where `frame_ms` is derived (`double frame_ms = (double)mf_ctrl_rd_hi(MF_C_DONE) / (MF_CLK_SYS_MHZ * 1000.0);`), add below it:

```cpp
    // [W3 Stage C] notice attribution, published by the fabric at C_CMDCOUNT.hi:
    //   [31:16] snap tail   (C_DONE written -> polling resumed), cycles >> 3
    //   [15:0]  submit detect (polling -> new work seen),        cycles >> 3
    // Both are the fabric's own share of `notice`; the host's share is
    // notice - (snap + detect).
    const uint32_t attrib = mf_ctrl_rd_hi(MF_C_CMDCOUNT);
    const double snap_ms   = ((attrib >> 16) * 8.0) / (MF_CLK_SYS_MHZ * 1000.0);
    const double detect_ms = ((attrib & 0xFFFFu) * 8.0) / (MF_CLK_SYS_MHZ * 1000.0);
```

`mf_submit_stat` prints the **`MFSUBMIT`** line (a 30-frame window with its own accumulators), not `MFSEAM` — so the two values join that window the same way `fsum`/`tsum`/`xsum` do. Add two accumulators beside them:

```cpp
    static double nsum = 0.0, dsum = 0.0;   // [W3 Stage C] snap / detect, ms
```

accumulate on the line that reads `n++; to += timeout ? 1u : 0u; sum += us; ...`:

```cpp
    nsum += snap_ms; dsum += detect_ms;
```

append `snap=%.3f detect=%.3f` to the **end** of the `MFSUBMIT` format string with `nsum/30.0, dsum/30.0` as the matching arguments, and clear them in the same reset line as the others (`fsum = 0; tsum = 0; ...`):

```cpp
        nsum = 0; dsum = 0;
```

- [ ] **Step 9: Verify the host build stays green**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-w3
make -f Makefile.gmloader raster-backend-test
make -f Makefile.gmloader mf-seam-stat-test
```
Expected: both PASS. `mf_submit_stat`'s body is already inside the file's `#ifdef MISTER_NATIVE_VIDEO` device-transport block, so `mf_ctrl_rd_hi` resolves and no new guard is needed. If the build fails with `mf_ctrl_rd_hi was not declared`, the edit landed outside that block — move it in.

- [ ] **Step 10: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3
git add fpga/rtl/blitter_top.sv fpga/sim/tb_perf_publish_order.sv
git commit -m "feat(blitter): publish the notice attribution counters at C_CMDCOUNT.hi"

cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-w3
git add gmloader/mister/raster_backend_mfgpu.cpp
git commit -m "feat(mfgpu): read and print the fabric notice attribution counters"
```

---

## Task 9: Full nightly simulation gate

Everything above ran the PR tier plus targeted benches. Before spending a Quartus cycle, run the whole suite at the tier that includes the real-cache replay.

**Files:**
- Modify: none

**Interfaces:**
- Consumes: Tasks 5–8.
- Produces: a green nightly tier, or a named failure.

- [ ] **Step 1: Run the nightly tier**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3/fpga/sim
./run_sims.sh --tier=nightly 2>&1 | tee /tmp/w3_nightly.log | tail -60
echo "exit=$?"
```
Expected: `exit=0`. Budget ~40 min; `tb_blitter_trilist_streamcache` alone has a 3600 s timeout.

- [ ] **Step 2: Read the non-gating banner**

Run: `grep -n 'NON-GATING\|DEFERRED\|### NOTE' /tmp/w3_nightly.log`
Expected: any non-gating failure listed here is compared against the Task 1 Step 5 baseline. A non-gating testbench that failed **before** this phase is not this phase's regression; one that did not is, and blocks the build.

- [ ] **Step 3: Confirm the bucket gates**

Run: `grep -n 'GATE-MISMATCH' /tmp/w3_nightly.log`
Expected: no output. The synthquad and spanedge benches assert hand-computed bucket counts precisely so a pixel-walk change that drifts is caught here rather than on device.

---

## Task 10: Build the bitstream and check the pre-deploy gates

**Files:**
- Modify: none

**Interfaces:**
- Consumes: the `perf/phase4-w3` branch in `../wt-maldita-w3`, plus Stage C's fix if its plan landed in time to share this cycle.
- Produces: an RBF matched to the `fpga/` tree hash, with STA and map-report gates checked.

- [ ] **Step 1: Push the branch so CI builds it**

The canonical build is the self-hosted Windows Quartus runner. Do not substitute the Linux fallback.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3
git push -u origin perf/phase4-w3
```

- [ ] **Step 2: Watch the build**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
make rbf-watch MALDITA=../wt-maldita-w3
```
Expected: the workflow reaches success. A Quartus cycle is ~40–60 min; this is a foreground watch, not a reason to start unrelated work on the device.

- [ ] **Step 3: Check the M10K inference gate**

Fetch the build artifacts (the workflow uploads the report set alongside the RBF) and run:

```bash
grep -l 276007 *.map.rpt || echo "OK: no M10K uninference"
```
Expected: `OK: no M10K uninference`. A hit here means a `ramstyle` array's read got nested inside an FSM case arm — the exact failure that cost 20,480 stray flops and a 1,735-fanout mux last time, and it is worth checking because Task 7 added a case arm that reads `pv_qw`. If `pv_qw` inferred as flops that is acceptable (six qwords = 384 flops) but must be *noticed*, not discovered later.

- [ ] **Step 4: Check STA**

Compare the build's TNS against the pre-change build's. Expected: **not worse**. Task 5 adds 912 flops between the setup module's outputs and the walk's adders — that inserts a register layer into what were long routes, so the expectation is neutral-to-better on the walk paths; Task 7's second requester on `bm_addr` adds a small mux. If TNS regressed, the likely site is the `bm_addr` mux or `pv_qw` placement, not combinational depth (spec §5 R3).

- [ ] **Step 5: Deploy the RBF to `.62`**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
make deploy-rbf MALDITA=../wt-maldita-w3 HOST=192.168.20.62
```
Expected: `deploy.py` resolves the RBF by `fpga/` tree hash and accepts it. If it refuses as stale, the artifact does not match the tree — fix that rather than passing `--force`.

- [ ] **Step 6: Deploy the matching engine**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
make build-engine GMDIR=../wt-gmloader-w3
make deploy-engine GMDIR=../wt-gmloader-w3 HOST=192.168.20.62
ssh root@192.168.20.62 'ps | grep -c "[g]mloader"'
```
Expected: the last command prints `1`.

---

## Task 11: Device validation against the gate

**Files:**
- Modify: none

**Interfaces:**
- Consumes: the deployed bitstream + engine.
- Produces: the measured `period` on heavy-B; the arrival non-regression check; the `notice` decomposition read from the new counter.

- [ ] **Step 1: Reboot before measuring**

Run: `ssh root@192.168.20.62 reboot; sleep 60`
The f2h wedge (`beacon=0`, `dbg_blt=0`, `C_DONE=0` while `C_SUBMIT` climbs) survives core reloads and is cleared only by a reboot. Starting a validation run on a wedged device produces plausible-looking garbage.

- [ ] **Step 2: Capture heavy-B**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh bench --secs 40 \
  --preset fabric --scene ingame-stage1 --env GMLOADER_MFSUBMIT_STAT=1
L=$(ls -t bench-results/*.log | head -1)
grep -c 'suspect=[^0]' "$L"; grep -c 'incomplete=[^0]' "$L"; grep -c 'submit timeout' "$L"
grep -o 'cov_px=[0-9]*' "$L" | sort | uniq -c | sort -rn | head -5
```
Expected: `0 0 0` and a plateau at `cov_px=213358`.

- [ ] **Step 3: Evaluate the primary gate**

The gate is `period ≤ 16.6882 ms` **with repeated frames ≈ 0** — a fabric term under a fabric gate is not a lock.

```bash
grep 'MFSEAM' "$L" | awk '{for(i=1;i<=NF;i++){split($i,a,"=");v[a[1]]=a[2]}}
     v["blocked"]+0>=90 {n++; p+=v["period"]; f+=v["frame"]; no+=v["notice"]}
     END {printf "windows=%d mean period=%.3f notice=%.3f\n", n, p/n, no/n}'
```
Expected if the phase succeeded: mean `period` ≤ 16.6882. Record the number whatever it is.

For the repeated-frame half of the gate, count distinct `C_DONE` deltas over the window — a repeated frame shows as the fabric completing without the host having published anything new. Read it from the `MFSUBMIT` sequence: consecutive lines whose `n=` advances but whose `cov_px` and `frame` are byte-identical are the candidates; a count near zero is the gate.

- [ ] **Step 4: Read the notice decomposition**

```bash
grep -o 'snap=[0-9.]* detect=[0-9.]*' "$L" | tail -10
```

(These are `MFSUBMIT` fields — a 30-frame mean each, so read them as a series, not as a distribution.)
Expected: `snap` in the region Task 4's knee predicted. **This is the measurement that either confirms or refutes Stage A's behavioural answer** — if the counter and the doorbell-delay knee disagree, say so and treat both as unresolved rather than picking the one that fits.

- [ ] **Step 5: Check arrival has not regressed**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh bench --secs 40 \
  --preset fabric --scene ingame-stage1-busy --env GMLOADER_MFSUBMIT_STAT=1
L2=$(ls -t bench-results/*.log | head -1)
grep -o 'cov_px=[0-9]*' "$L2" | sort | uniq -c | sort -rn | head -5
```
Expected: a plateau at `cov_px=245346`, and its `frame` **not worse than 20.04 ms**. This gate is secondary and non-blocking, but a regression here must be reported, not omitted.

- [ ] **Step 6: Check the audio gate**

Run: `grep -c 'StarvedFrames\|underflow' "$L"`
Expected: no starvation reported. Note the standing instrument gap: there is no periodic audio-underflow counter in the engine, so this criterion is currently only checkable as absence-of-matches — state that limitation rather than reporting a clean pass as if it were measured.

- [ ] **Step 7: Take a screenshot to corroborate scene identity**

Run: `ssh root@192.168.20.62 'echo screenshot > /dev/MiSTer_cmd'` while the run is on the heavy-B plateau, then pull it. heavy-B has **no prior screenshot pedigree** (W1/W2 findings §7.1) — this closes that gap for the phase that used it as its gate.

---

## Task 12: Findings, merge, and pin

**Files:**
- Modify: `docs/superpowers/findings/2026-07-31-phase4-w3.md` (in `../wt-mgml-w3`)
- Modify: `external/gmloader-next` (pin)

**Interfaces:**
- Consumes: everything above.
- Produces: merged branches in all three repos and a bumped pin.

- [ ] **Step 1: Extend the findings document**

Add these sections to the Stage A document created in Task 4, keeping the Observed / Inferred / Unknown discipline and giving every Unknown a "what would answer it":

```markdown
## 8. Stage B — the setup/vfetch overlap
<the per-scene measured delta, NOT the single 0.2125 figure (spec §5 R4);
 sim vs real-cache bench; the bit-exact gate result>

## 9. Stage C — notice, decomposed by counter
<snap / detect / host-share, and whether the counter agrees with §3's knee>

## 10. The gate
<measured heavy-B period, repeated-frame count, PASS or FAIL stated plainly>

## 11. Arrival, non-regression
<measured, against 20.04 ms>

## 12. Data-trust caveats
<sample depth; whether the screenshot was taken; the audio instrument gap>
```

If the gate was missed, say it was missed and apply spec §5 R2: report heavy-B at `16.48 + notice`, re-open the gate with Candidate A funded, and **do not redefine the gate to match what was achieved**.

- [ ] **Step 2: Open the pull requests**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-w3 && gh pr create --fill
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-w3 && git push -u origin perf/phase4-w3-notice-probe && gh pr create --fill
cd /Users/gmcnaught/MisterFPGA-Projects/wt-mgml-w3 && git push -u origin perf/phase4-w3 && gh pr create --fill
```

The maldita PR must also carry the heavy-B vectors merged in Task 1 — check whether `test/phase4-stage-b-vectors` should be merged to `milestone-a` in its own PR first, so this phase's diff is the RTL change alone.

- [ ] **Step 3: Merge and bump the pin**

After the maldita and gmloader-next PRs merge, in the `mister-gmloader` worktree:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-mgml-w3
git -C external/gmloader-next fetch origin
git -C external/gmloader-next checkout <the merged gmloader-next commit>
git add external/gmloader-next
git commit -m "chore: bump gmloader-next pin to Phase 4 W3"
```

⚠️ Bumping the pin does **not** change what ships — `deploy.py` builds from a sibling checkout. The pin is provenance, and it must name the commit that was actually device-validated.

- [ ] **Step 4: Update the handoff**

Rewrite `docs/superpowers/HANDOFF-2026-07-30.md`'s START HERE section to point at the W3 findings and state where the next phase begins. If the gate was met, the next open question is arrival (needs −3.91 ms, for which Candidate A and opaque cull are the sized levers). If it was not, the next phase is Candidate A, funded.

- [ ] **Step 5: Remove the worktrees**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister && git worktree remove ../wt-maldita-w3
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next && git worktree remove ../wt-gmloader-w3
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader && git worktree remove ../wt-mgml-w3
```

---

## Appendix: what this plan deliberately does not do

Carried from spec §4, each with its stated reason, so a later session does not re-derive them:

- **Candidate A (pb pipelining)** — deferred a third time, now because heavy-B does not need it. Its `dpath` calibration (−0.03 %) stands and it remains the **arrival** lever.
- **The product-space DDA hoist** (`blitter_top.sv:1797-1802`) — bit-exact and frees ~24 DSPs, but worth ~0 ms because `pa_hold` is 85.4 %. It is an enabler to sequence *before* Candidate A, never a throughput lever. YAGNI.
- **Opaque cull** — arrival-only, a host↔fabric contract change, unfunded.
- **The LW-bridge doorbell move** — held as Stage C's fallback, not the default; it means editing `sys_top.v` / the Platform Designer system, which this project has so far avoided.
- **Quiet's delivered rate** — host-bound (`MFSEAM host` 15.72 ms against a `frame` of 14.86). No fabric lever moves it; it belongs to a host phase.

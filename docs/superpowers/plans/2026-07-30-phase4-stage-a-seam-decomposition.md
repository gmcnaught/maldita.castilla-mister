# Phase 4 Stage A — Submit-Seam Decomposition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Instrument the gmloader↔fabric submit seam so the render period decomposes into `host + block + pub` with a self-checking identity, then capture it on `.62` and report which term carries the ~1.4 ms of coupling that stands between 55.6 fps and a locked 59.9228.

**Architecture:** A new header-only, dependency-free accumulator (`mf_seam_stat.h`) holds all the arithmetic — means, the identity check, the blocked-frame gating of `notice`, and two histograms — so it is unit-testable on the host with no device, no I/O and no globals. `raster_backend_mfgpu.cpp` contributes only three `clock_gettime` stamps at points that already exist in the seam and feeds them to the accumulator. `main.cpp` gets the two `FCAP_STAT` repairs and the audio starvation field. Nothing in the fabric changes.

**Tech Stack:** C++17 host unit tests via `make -f Makefile.gmloader <target>` (plain `c++`, no framework); armhf cross-build in Docker for the device binary; `scripts/mister_run.sh` for device capture.

## Global Constraints

- **The bitstream is frozen** at what is deployed on `.62` (maldita RTL `a723aa5`). No maldita/RTL file is touched by this plan.
- **No new environment variable.** Everything new is behind the existing `mf_stat_on()` (`GMLOADER_MFSUBMIT_STAT`) and `g_fcap_stat` (`GMLOADER_FCAP_STAT`) knobs.
- **With those knobs unset, the `MFSUBMIT` line must be byte-identical to today's.**
- Identity tolerance is **0.05 ms**; the seam window is **30 frames**, matching `MFSUBMIT`.
- Scanout period is **16.6882 ms / 59.9228 Hz** (1,642,740 clk_sys cycles). Never hardcode 60 Hz or 16.67.
- **Device is `.62`.** `.81` is production. `make` defaults `HOST` to `.62`; `deploy.py --host` still defaults to `.81`, so use the Makefile.
- **Never hand-launch the engine** after a deploy — the handler `exec`s it; `killall -9 gmloader` is what starts the new binary. Two engines on one control block is a known contamination mode.
- Work in a dedicated worktree (the user runs concurrent sessions against these checkouts):
  ```bash
  cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
  git worktree add ../wt-gmloader-p4-seam -b perf/phase4-stage-a
  ```
  All paths below are relative to that worktree.

---

## File Structure

| file | responsibility |
|---|---|
| `gmloader/mister/mf_seam_stat.h` | **Create.** Pure accumulator: sample intake, 30-frame means, identity check, blocked-gated `notice`, two histograms. No I/O, no globals, no device headers. |
| `gmloader/mister/mf_seam_stat_test.cpp` | **Create.** Host unit test for the accumulator. |
| `Makefile.gmloader` | **Modify.** Add the `mf-seam-stat-test` target next to the existing host-test targets (~line 205). |
| `gmloader/mister/raster_backend_mfgpu.cpp` | **Modify.** Three `clock_gettime` stamps, the accumulator instance, the `MFSEAM` print, one test hook. |
| `gmloader/main.cpp` | **Modify.** Window the `FCAP_STAT` counters, time the cap wait with `clock_gettime`, add the audio starvation field. |

---

### Task 1: Seam accumulator core — means and the identity check

**Files:**
- Create: `gmloader/mister/mf_seam_stat.h`
- Create: `gmloader/mister/mf_seam_stat_test.cpp`
- Modify: `Makefile.gmloader` (add target after the `mf-cov-clip-test` target, ~line 232)

**Interfaces:**
- Consumes: nothing.
- Produces: `mf_seam_acc_t`, `mf_seam_out_t`, `mf_seam_reset(mf_seam_acc_t*)`, `mf_seam_add(mf_seam_acc_t*, double host_ms, double block_ms, double pub_ms, double period_ms, double frame_ms)`, `mf_seam_ready(const mf_seam_acc_t*) -> int`, `mf_seam_derive(const mf_seam_acc_t*, mf_seam_out_t*)`, `MF_SEAM_WINDOW`, `MF_SEAM_TOL_MS`. Tasks 2 and 3 extend this same header; Task 4 calls it.

> **Superseded signature.** Task 2 adds a seventh parameter, `int blocked`, and updates every call in this section to pass `0`. The five-argument calls below are the Task-1-era form, kept as the record of what this task built — do not restore them.

- [ ] **Step 1: Write the failing test**

Create `gmloader/mister/mf_seam_stat_test.cpp`:

```cpp
// Host unit test for the Phase 4 Stage A submit-seam accumulator (mf_seam_stat.h).
//
// The accumulator is deliberately pure — no I/O, no globals, no device headers —
// so the whole decomposition's arithmetic is testable without a MiSTer attached.
// The device wiring in raster_backend_mfgpu.cpp contributes only timestamps.
#include "mf_seam_stat.h"

#include <stdio.h>
#include <math.h>

static int g_fail = 0;
#define CHECK(c) do { if (!(c)) { \
    printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); g_fail = 1; } } while (0)
#define NEAR(a, b) (fabs((a) - (b)) < 1e-9)

// The three intervals are consecutive slices of one period, so on a well-formed
// frame they sum to it exactly.
static void case_means_and_identity_closes(void) {
    mf_seam_acc_t a; mf_seam_reset(&a);
    mf_seam_add(&a, 5.0, 10.0, 0.5, 15.5, 16.20);
    mf_seam_add(&a, 7.0,  8.0, 0.5, 15.5, 16.20);
    mf_seam_out_t o; mf_seam_derive(&a, &o);
    CHECK(a.n == 2);
    CHECK(o.suspect == 0);
    CHECK(NEAR(o.host_ms,   6.0));
    CHECK(NEAR(o.block_ms,  9.0));
    CHECK(NEAR(o.pub_ms,    0.5));
    CHECK(NEAR(o.period_ms, 15.5));
}

// A frame whose parts do not sum to its period means a stamp was missed, a
// publish was lost, or the frame was dropped. That must be counted, never
// averaged away.
static void case_identity_fires_on_gap(void) {
    mf_seam_acc_t a; mf_seam_reset(&a);
    mf_seam_add(&a, 5.0, 10.0, 0.5, 15.5, 16.20);   // closes
    mf_seam_add(&a, 5.0, 10.0, 0.5, 20.0, 16.20);   // 4.5 ms unaccounted
    mf_seam_out_t o; mf_seam_derive(&a, &o);
    CHECK(o.suspect == 1);
}

static void case_identity_tolerance_edge(void) {
    mf_seam_acc_t a; mf_seam_reset(&a);
    mf_seam_add(&a, 5.0, 10.0, 0.5, 15.5 + 0.04, 16.20);   // inside tolerance
    CHECK(a.suspect == 0);
    mf_seam_add(&a, 5.0, 10.0, 0.5, 15.5 + 0.06, 16.20);   // outside
    CHECK(a.suspect == 1);
}

static void case_ready_at_window(void) {
    mf_seam_acc_t a; mf_seam_reset(&a);
    for (int i = 0; i < MF_SEAM_WINDOW - 1; i++)
        mf_seam_add(&a, 5.0, 10.0, 0.5, 15.5, 16.20);
    CHECK(!mf_seam_ready(&a));
    mf_seam_add(&a, 5.0, 10.0, 0.5, 15.5, 16.20);
    CHECK(mf_seam_ready(&a));
}

static void case_reset_clears(void) {
    mf_seam_acc_t a; mf_seam_reset(&a);
    mf_seam_add(&a, 5.0, 10.0, 0.5, 20.0, 16.20);
    CHECK(a.n == 1 && a.suspect == 1);
    mf_seam_reset(&a);
    CHECK(a.n == 0 && a.suspect == 0);
    mf_seam_out_t o; mf_seam_derive(&a, &o);
    CHECK(NEAR(o.host_ms, 0.0) && NEAR(o.period_ms, 0.0));   // no divide by zero
}

int main(void) {
    case_means_and_identity_closes();
    case_identity_fires_on_gap();
    case_identity_tolerance_edge();
    case_ready_at_window();
    case_reset_clears();
    printf(g_fail ? "mf-seam-stat FAIL\n" : "mf-seam-stat PASS\n");
    return g_fail;
}
```

- [ ] **Step 2: Add the build target**

In `Makefile.gmloader`, after the `mf-cov-clip-test` recipe (the block ending `-lm -o /tmp/mcct && /tmp/mcct`), add:

```make
.PHONY: mf-seam-stat-test
# TDD host test for the Phase 4 Stage A submit-seam accumulator (mf_seam_stat.h).
# The header is deliberately dependency-free, so unlike raster-backend-test this
# needs no other translation unit and no MFGPU sources.
mf-seam-stat-test:
	c++ -std=c++17 -Igmloader/mister \
	  gmloader/mister/mf_seam_stat_test.cpp \
	  -lm -o /tmp/mfss && /tmp/mfss
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `make -f Makefile.gmloader mf-seam-stat-test`
Expected: FAIL — `fatal error: mf_seam_stat.h: No such file or directory`

- [ ] **Step 4: Write the minimal implementation**

Create `gmloader/mister/mf_seam_stat.h`:

```c
#ifndef MF_SEAM_STAT_H
#define MF_SEAM_STAT_H
// Phase 4 Stage A — the submit-seam decomposition accumulator.
//
//   period = host + block + pub
//     host  = doorbell N            -> mf_publish_barrier entry
//     block = barrier entry         -> barrier returns true  (the real wait on the fabric)
//     pub   = barrier return        -> doorbell N+1
//
// Three CONSECUTIVE intervals, so no term is a residual. That shape is the point:
// the 2026-07-30 exposed-cost audit sec 6.2 records BLITPROF's `logic` residual
// silently absorbing a 16.9 ms deferred await, because a residual absorbs whatever
// nobody named.
//
// Pure by construction: no I/O, no globals, no device headers, so all of the
// arithmetic is unit-testable on the host. The device side contributes timestamps
// and nothing else.
#include <stdint.h>
#include <string.h>

#define MF_SEAM_WINDOW   30      /* frames per report; matches MFSUBMIT's window */
#define MF_SEAM_TOL_MS   0.05    /* identity slack for the timestamp reads themselves */

typedef struct {
    unsigned n;
    unsigned suspect;            /* frames whose parts did not sum to their period */
    double   host_sum, block_sum, pub_sum, period_sum;
} mf_seam_acc_t;

typedef struct {
    double   host_ms, block_ms, pub_ms, period_ms;
    unsigned suspect;
} mf_seam_out_t;

static inline void mf_seam_reset(mf_seam_acc_t *a) { memset(a, 0, sizeof *a); }

/* frame_ms is the fabric's own compute counter (C_DONE.hi) for the batch this
   frame's `block` waited on. Unused until Task 2 introduces `notice`; taken now
   so the call sites written in Task 4 never have to change signature. */
static inline void mf_seam_add(mf_seam_acc_t *a, double host_ms, double block_ms,
                               double pub_ms, double period_ms, double frame_ms) {
    (void)frame_ms;
    a->n++;
    a->host_sum   += host_ms;
    a->block_sum  += block_ms;
    a->pub_sum    += pub_ms;
    a->period_sum += period_ms;

    double d = (host_ms + block_ms + pub_ms) - period_ms;
    if (d < 0.0) d = -d;
    if (d >= MF_SEAM_TOL_MS) a->suspect++;
}

static inline int mf_seam_ready(const mf_seam_acc_t *a) {
    return a->n >= MF_SEAM_WINDOW;
}

static inline void mf_seam_derive(const mf_seam_acc_t *a, mf_seam_out_t *o) {
    const double n = a->n ? (double)a->n : 1.0;   /* an empty window reports zeros */
    o->host_ms   = a->host_sum   / n;
    o->block_ms  = a->block_sum  / n;
    o->pub_ms    = a->pub_sum    / n;
    o->period_ms = a->period_sum / n;
    o->suspect   = a->suspect;
}

#endif /* MF_SEAM_STAT_H */
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `make -f Makefile.gmloader mf-seam-stat-test`
Expected: PASS — output `mf-seam-stat PASS`, exit 0

- [ ] **Step 6: Commit**

```bash
git add gmloader/mister/mf_seam_stat.h gmloader/mister/mf_seam_stat_test.cpp Makefile.gmloader
git commit -m "feat(seam): submit-seam accumulator with a self-checking identity

period = host + block + pub, three consecutive intervals rather than a measured
set plus a residual. The identity check counts frames whose parts do not sum to
their period (a missed stamp, a lost publish, a dropped frame) instead of
averaging them away."
```

---

### Task 2: Blocked-frame gating of `notice`

**Files:**
- Modify: `gmloader/mister/mf_seam_stat.h`
- Modify: `gmloader/mister/mf_seam_stat_test.cpp`

**Interfaces:**
- Consumes: everything from Task 1.
- **Changes** `mf_seam_add` to take a seventh parameter: `mf_seam_add(acc, host_ms, block_ms, pub_ms, period_ms, frame_ms, int blocked)`. Task 1's existing five test cases must be updated to pass `0` for it.
- Produces: `mf_seam_acc_t.blocked` (unsigned), `mf_seam_acc_t.notice_sum` (double), `mf_seam_out_t.notice_ms` (double), `mf_seam_out_t.blocked_frac` (double). Task 4 prints both.

**Why this exists.** The existing `MFSUBMIT wait_ms` is `t_ar − t_db`, which *contains* `host`. When the host reaches the barrier after the fabric already finished, the host never waited and `wait_ms` measures its own lateness, not the fabric's latency — an upper bound only. So `notice = (host + block) − frame` is accumulated over blocked frames only, and the blocked fraction is reported so a `notice` computed from a thin sample is visible as such.

**Why `blocked` is an explicit parameter and not inferred from `block_ms > 0.0`.** It cannot be inferred. `mf_device_await` returns on its *first* poll when `C_DONE` already matches (`raster_backend_mfgpu.cpp:1001-1004`), so on a frame where the host never waited, `block_ms` is not `0.0` — it is the few microseconds of one uncached MMIO read plus two `clock_gettime` calls. `block_ms > 0.0` would therefore be true on **every** device frame, making the gate vacuous and averaging `notice` over exactly the late frames it exists to exclude. The exact signal is that same poll loop's `iters`, which is `0` if and only if the host never waited; Task 4 passes it down. Do not replace this parameter with a threshold on `block_ms` — an epsilon would be an arbitrary constant standing in for a signal we already have exactly.

- [ ] **Step 1: Write the failing tests**

Add to `gmloader/mister/mf_seam_stat_test.cpp`, above `main`:

```cpp
// notice = (host + block) - frame, and ONLY over frames where the host really
// waited. On a frame that arrived late the host never blocked; its wait_ms bounds
// the fabric's latency from above rather than measuring it.
static void case_notice_only_over_blocked(void) {
    mf_seam_acc_t a; mf_seam_reset(&a);
    mf_seam_add(&a, 18.0, 0.002, 0.5, 18.502, 16.20, 0);  // never blocked — excluded
    mf_seam_add(&a, 14.0, 3.0,   0.5, 17.5,   16.20, 1);  // blocked — notice = 17.0 - 16.20
    mf_seam_out_t o; mf_seam_derive(&a, &o);
    CHECK(a.blocked == 1);
    CHECK(NEAR(o.blocked_frac, 0.5));
    CHECK(NEAR(o.notice_ms, 0.80));
}

// The non-blocking frames carry a small NON-ZERO block_ms on purpose: on device a
// frame that never waited still spends the few microseconds of one uncached C_DONE
// read inside the await. A gate written as `block_ms > 0.0` would count these as
// blocked, which is exactly the defect the explicit flag exists to prevent.
static void case_notice_zero_when_never_blocked(void) {
    mf_seam_acc_t a; mf_seam_reset(&a);
    mf_seam_add(&a, 18.0, 0.002, 0.5, 18.502, 16.20, 0);
    mf_seam_add(&a, 19.0, 0.003, 0.5, 19.503, 16.20, 0);
    mf_seam_out_t o; mf_seam_derive(&a, &o);
    CHECK(a.blocked == 0);
    CHECK(NEAR(o.blocked_frac, 0.0));
    CHECK(NEAR(o.notice_ms, 0.0));      // reported as 0, never as a divide by zero
}

static void case_notice_averages_over_blocked_only(void) {
    mf_seam_acc_t a; mf_seam_reset(&a);
    mf_seam_add(&a, 14.0, 3.0,   0.5, 17.5,   16.20, 1);  // notice 0.80
    mf_seam_add(&a, 14.0, 4.0,   0.5, 18.5,   16.20, 1);  // notice 1.80
    mf_seam_add(&a, 20.0, 0.002, 0.5, 20.502, 16.20, 0);  // excluded
    mf_seam_out_t o; mf_seam_derive(&a, &o);
    CHECK(a.blocked == 2);
    CHECK(NEAR(o.notice_ms, 1.30));                 // (0.80 + 1.80) / 2, not / 3
}
```

Also update Task 1's five existing cases to pass `0` as the new final argument — none of them exercise `notice`, and their assertions are unchanged.

Register them in `main`, before the `printf`:

```cpp
    case_notice_only_over_blocked();
    case_notice_zero_when_never_blocked();
    case_notice_averages_over_blocked_only();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make -f Makefile.gmloader mf-seam-stat-test`
Expected: FAIL — `error: 'mf_seam_acc_t' has no member named 'blocked'`

- [ ] **Step 3: Write the minimal implementation**

In `mf_seam_stat.h`, add the two accumulator fields:

```c
typedef struct {
    unsigned n;
    unsigned suspect;            /* frames whose parts did not sum to their period */
    unsigned blocked;            /* frames where the host actually waited on the fabric */
    double   host_sum, block_sum, pub_sum, period_sum;
    double   notice_sum;         /* summed over blocked frames only */
} mf_seam_acc_t;
```

and the two output fields:

```c
typedef struct {
    double   host_ms, block_ms, pub_ms, period_ms;
    double   notice_ms;          /* mean over BLOCKED frames; 0 when none blocked */
    double   blocked_frac;       /* read notice_ms together with this, never alone */
    unsigned suspect;
} mf_seam_out_t;
```

Change the signature of `mf_seam_add` to take the caller's blocked flag, and delete the now-obsolete `(void)frame_ms;`:

```c
/* frame_ms is the fabric's own compute counter (C_DONE.hi) for the batch this
   frame's `block` waited on. `blocked` is the CALLER's answer to "did the host
   actually wait?" — it cannot be derived from block_ms, because a frame that
   never waited still spends the few microseconds of one uncached C_DONE read
   inside the await, so block_ms is never exactly zero on device. */
static inline void mf_seam_add(mf_seam_acc_t *a, double host_ms, double block_ms,
                               double pub_ms, double period_ms, double frame_ms,
                               int blocked) {
```

and append before the closing brace:

```c
    /* Only a frame that actually blocked measures the fabric's doorbell->done
       latency; on a frame that arrived late, host+block is the host's own
       lateness and would overstate `notice` by all of it. */
    if (blocked) {
        a->blocked++;
        a->notice_sum += (host_ms + block_ms) - frame_ms;
    }
```

In `mf_seam_derive`, append before the closing brace:

```c
    o->notice_ms    = a->blocked ? a->notice_sum / (double)a->blocked : 0.0;
    o->blocked_frac = a->blocked / n;
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make -f Makefile.gmloader mf-seam-stat-test`
Expected: PASS — `mf-seam-stat PASS`, exit 0

- [ ] **Step 5: Commit**

```bash
git add gmloader/mister/mf_seam_stat.h gmloader/mister/mf_seam_stat_test.cpp
git commit -m "feat(seam): gate notice on frames that actually blocked

wait_ms contains host, so on a frame that reached the barrier after the fabric
had finished it measures the host's lateness rather than the fabric's latency.
notice is therefore averaged over blocked frames only, and blocked_frac ships
beside it so a notice drawn from a thin sample is visible as one."
```

---

### Task 3: Histograms for `host` and `pub`

**Files:**
- Modify: `gmloader/mister/mf_seam_stat.h`
- Modify: `gmloader/mister/mf_seam_stat_test.cpp`

**Interfaces:**
- Consumes: everything from Tasks 1–2.
- Produces: `MF_SEAM_BUCKETS` (8), `MF_SEAM_EDGES[7]`, `mf_seam_bucket(double) -> int`, `mf_seam_acc_t.host_hist[8]`, `mf_seam_acc_t.pub_hist[8]` (both `uint32_t`). Task 4 prints both arrays.

**Why this exists.** The device logs show `fabric_ms[frame=]` invariant at 16.20–16.21 over 8,000+ frames while the cap waits ~5.2 ms on a fifth of frames — the host body is bimodal and the fabric is not. A mean cannot tell "every frame costs 1.4 ms extra" from "one frame in five costs 7 ms extra", and those imply opposite fixes.

- [ ] **Step 1: Write the failing tests**

Add to `gmloader/mister/mf_seam_stat_test.cpp`, above `main`:

```cpp
// Edges are lower-inclusive: bucket i holds [EDGES[i-1], EDGES[i]).
// Sub-ms resolution below 1 ms is deliberate — that is where `pub` has to land
// for a 16.6882 ms period with a 16.20 ms fabric.
static void case_bucket_edges(void) {
    CHECK(mf_seam_bucket(0.0)     == 0);
    CHECK(mf_seam_bucket(0.24)    == 0);
    CHECK(mf_seam_bucket(0.25)    == 1);
    CHECK(mf_seam_bucket(0.99)    == 2);
    CHECK(mf_seam_bucket(1.0)     == 3);
    CHECK(mf_seam_bucket(5.0)     == 5);
    CHECK(mf_seam_bucket(16.6881) == 6);
    CHECK(mf_seam_bucket(16.6882) == 7);   // at or beyond the scanout period
    CHECK(mf_seam_bucket(1000.0)  == 7);
}

static void case_hist_counts(void) {
    mf_seam_acc_t a; mf_seam_reset(&a);
    mf_seam_add(&a, 5.0, 10.0, 0.10, 15.10, 16.20, 1);   // pub -> bucket 0
    mf_seam_add(&a, 5.0, 10.0, 0.30, 15.30, 16.20, 1);   // pub -> bucket 1
    mf_seam_add(&a, 5.0, 10.0, 0.30, 15.30, 16.20, 1);   // pub -> bucket 1
    CHECK(a.pub_hist[0] == 1);
    CHECK(a.pub_hist[1] == 2);
    CHECK(a.host_hist[5] == 3);                        // host 5.0 ms -> [4.0, 8.0)
    CHECK(a.suspect == 0);                             // all three identities close
}

static void case_hist_cleared_by_reset(void) {
    mf_seam_acc_t a; mf_seam_reset(&a);
    mf_seam_add(&a, 5.0, 10.0, 0.10, 15.10, 16.20, 1);
    CHECK(a.pub_hist[0] == 1);
    mf_seam_reset(&a);
    CHECK(a.pub_hist[0] == 0);
    CHECK(a.host_hist[5] == 0);
}
```

Register them in `main`, before the `printf`:

```cpp
    case_bucket_edges();
    case_hist_counts();
    case_hist_cleared_by_reset();
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make -f Makefile.gmloader mf-seam-stat-test`
Expected: FAIL — `error: 'mf_seam_bucket' was not declared in this scope`

- [ ] **Step 3: Write the minimal implementation**

In `mf_seam_stat.h`, add below the existing `#define`s:

```c
#define MF_SEAM_BUCKETS   8

/* Upper edges in ms, lower-inclusive. Fine below 1 ms because that is where
   `pub` must land for a 16.6882 ms period against a 16.20 ms fabric; the last
   edge IS the scanout period, so the top bucket means "this frame could not have
   locked". */
static const double MF_SEAM_EDGES[MF_SEAM_BUCKETS - 1] = {
    0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.6882
};

static inline int mf_seam_bucket(double ms) {
    for (int i = 0; i < MF_SEAM_BUCKETS - 1; i++)
        if (ms < MF_SEAM_EDGES[i]) return i;
    return MF_SEAM_BUCKETS - 1;
}
```

Add to `mf_seam_acc_t`:

```c
    uint32_t host_hist[MF_SEAM_BUCKETS];
    uint32_t pub_hist[MF_SEAM_BUCKETS];
```

Append inside `mf_seam_add`, before the closing brace:

```c
    a->host_hist[mf_seam_bucket(host_ms)]++;
    a->pub_hist[mf_seam_bucket(pub_ms)]++;
```

(`mf_seam_reset` already clears them — it `memset`s the whole struct.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `make -f Makefile.gmloader mf-seam-stat-test`
Expected: PASS — `mf-seam-stat PASS`, exit 0

- [ ] **Step 5: Commit**

```bash
git add gmloader/mister/mf_seam_stat.h gmloader/mister/mf_seam_stat_test.cpp
git commit -m "feat(seam): host and pub histograms

The device shows an invariant 16.20 ms fabric against a bimodal host body, and a
mean cannot separate 'every frame costs 1.4 ms more' from 'one frame in five
costs 7 ms more'. The two readings imply opposite fixes, so the distribution
ships alongside the mean. Last edge is the 16.6882 ms scanout period: the top
bucket means the frame could not have locked."
```

---

### Task 4: Wire the seam into the backend and print `MFSEAM`

**Files:**
- Modify: `gmloader/mister/raster_backend_mfgpu.cpp` (include; statics; `mf_publish_barrier` at `:1150` and its `return true` at `:1163`; `mf_device_publish` at `:941`; `mf_submit_stat` at `:786`; test hook near `:2434`)
- Modify: `gmloader/mister/raster_backend_test.cpp` (one new case)

**Interfaces:**
- Consumes: `mf_seam_*` from Tasks 1–3.
- Produces: `extern "C" uint32_t RasterBackend_MFGPU_TestSeamSampleCount(void)` — how many complete seam samples have been accumulated since reinit. Nothing later consumes it; it exists so the wiring is testable off-device.

**The seam, verbatim from the current source.** `mf_frame_end` device path (`:2264`) calls `mf_publish_barrier()`, which calls `mf_device_await()` (which calls `mf_submit_stat`, where `frame_ms` is computed), then on success calls `mf_device_publish()`, whose last acts are the doorbell write and `clock_gettime(CLOCK_MONOTONIC, &g_publish_t0)` (`:965-967`). So `g_publish_t0` is already the doorbell stamp — do not add a fourth.

A complete sample needs the *next* doorbell, so `mf_seam_add` is called from `mf_device_publish` using the stamps carried from the previous iteration.

- [ ] **Step 1: Write the failing test**

Add to `gmloader/mister/raster_backend_test.cpp`, above the `main`-level case list. Place it next to `case_submit_publish_await_split` (`:1609`) so the seam cases stay together:

```cpp
// [Phase 4 Stage A] The seam accumulator takes exactly one sample per completed
// frame, and none for the first — a sample spans doorbell N to doorbell N+1, so
// frame 1 has no previous doorbell to measure from. Off-device the oracle never
// blocks, so this checks the plumbing (stamps taken, sample closed, counter
// advanced), not the timings.
static int case_seam_one_sample_per_frame(void) {
    RasterBackend_MFGPU_TestReinit(0);
    if (RasterBackend_MFGPU_TestSeamSampleCount() != 0) {
        printf("  seam: expected 0 samples after reinit, got %u\n",
               RasterBackend_MFGPU_TestSeamSampleCount());
        return 0;
    }
    for (int i = 0; i < 4; i++) { mf_test_drive_one_frame(); }
    const uint32_t got = RasterBackend_MFGPU_TestSeamSampleCount();
    if (got != 3) {                       // 4 doorbells close 3 periods
        printf("  seam: expected 3 samples after 4 frames, got %u\n", got);
        return 0;
    }
    return 1;
}
```

Register it in the case list next to the existing seam case (`:2645`):

```cpp
    if (!case_seam_one_sample_per_frame()) { printf("FAIL mfgpu-seam-sample\n"); ok = 0; }
```

Declare the hook with the other `extern "C"` test hooks at the top of the file (near `:59`):

```cpp
// [Phase 4 Stage A] how many complete submit-seam samples have been accumulated.
extern "C" uint32_t RasterBackend_MFGPU_TestSeamSampleCount(void);
```

`mf_test_drive_one_frame()` is the file's existing helper for pushing one frame through the backend — the same one `case_submit_publish_await_split` uses at `raster_backend_test.cpp:1622`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `make -f Makefile.gmloader raster-backend-test`
Expected: FAIL — link error, `undefined reference to RasterBackend_MFGPU_TestSeamSampleCount`

- [ ] **Step 3: Write the implementation**

In `gmloader/mister/raster_backend_mfgpu.cpp`:

**(a)** With the other local includes near the top:

```cpp
#include "mf_seam_stat.h"   // [Phase 4 Stage A] submit-seam decomposition
```

**(b)** Next to the existing `g_publish_t0` declaration (`:903`):

```cpp
// [Phase 4 Stage A] Submit-seam stamps. g_publish_t0 IS the doorbell stamp — it is
// taken immediately after the doorbell write in mf_device_publish — so the seam
// adds only two: barrier entry and barrier exit. A sample spans doorbell N to
// doorbell N+1, so it can only be closed by the NEXT publish; g_seam_prev_db
// carries the opening stamp across the frame boundary.
static mf_seam_acc_t   g_seam;
static struct timespec g_seam_be, g_seam_ar, g_seam_prev_db;
static bool            g_seam_have_prev = false;
// The fabric's own compute counter for the batch the current `block` waited on,
// stashed by mf_submit_stat so the pairing survives the deferred await.
static double          g_seam_frame_ms = 0.0;
// Did the host ACTUALLY wait this frame? mf_device_await returns on its first poll
// when C_DONE already matches, so a frame that never waited still spends the few
// microseconds of one uncached read inside it — block_ms is never exactly zero and
// cannot answer this. The await's own `iters` can: it is 0 if and only if the first
// read already matched. Cleared at barrier entry so a frame that skips the await
// (drop run) cannot inherit the previous frame's answer.
static bool            g_seam_blocked = false;

static inline double mf_seam_ms(const struct timespec *a, const struct timespec *b) {
    return (double)(b->tv_sec - a->tv_sec) * 1e3 +
           (double)(b->tv_nsec - a->tv_nsec) / 1e6;
}
```

**(c)** In `mf_submit_stat` (`:786`), immediately after `frame_ms` is computed:

```cpp
    g_seam_frame_ms = frame_ms;        // [Phase 4 Stage A] pair with this frame's block
    // Did the host really wait? `iters > 0` means the first C_DONE read did not match.
    // A TIMED-OUT await is excluded: it waited on the full abandoned budget, so its
    // interval measures the timeout, not the fabric's doorbell->done latency, and
    // folding it into `notice` would report one as the other.
    g_seam_blocked  = (iters > 0) && !timeout;
```

`iters` is `mf_submit_stat`'s existing parameter — the await's poll count, already passed by every one of its three call sites (the success return, the timeout path, and the `mf_nowait_on()` probe, which passes 0).

**(d)** In `mf_publish_barrier` (`:1150`), as the very first statements:

```cpp
    clock_gettime(CLOCK_MONOTONIC, &g_seam_be);
    g_seam_blocked = false;   // a frame that skips the await never blocked
```

and immediately before its final `return true;` (`:1163`):

```cpp
    clock_gettime(CLOCK_MONOTONIC, &g_seam_ar);
```

**The other two return paths must also be handled — they are not harmless.** `mf_publish_barrier` returns `true` from three places, and *all three* lead to `mf_device_publish`, which closes a sample:

- the early `return true` when `!g_fabric_pending` — reachable after `mf_frame_begin` runs its own `mf_drop_or_reclaim()`;
- `return mf_drop_or_reclaim()`, which returns `true` when it reclaims the ring at `MF_DROP_LIMIT`;
- the success return, the only one that stamps `g_seam_ar`.

On the first two, the sample closes with a fresh `g_seam_be` and a `g_seam_ar` left over from the last *successful* barrier — an entire drop run earlier. `block` comes out **negative** and `pub` absorbs the same magnitude: on device roughly 60 × 16.7 ms ≈ 1 s folded into a single sample of a 30-frame window.

**The identity check cannot catch this.** The three intervals telescope, so `host + block + pub == period` holds exactly wherever `ar` sits — the bad sample reports `suspect=0` and reads as trustworthy. It would corrupt the window precisely during the wedge this instrument exists to diagnose.

So on both non-success paths, set `g_seam_have_prev = false` (that frame contributes no sample — it did not complete a seam) and increment a counter:

```cpp
static uint32_t g_seam_incomplete = 0;   // samples skipped because the barrier did not complete
```

Print it on the `MFSEAM` line. Dropping samples silently would let a run full of reclaims report a clean-looking mean over whatever survived.

**(e)** In `mf_device_publish` (`:941`), immediately after `clock_gettime(CLOCK_MONOTONIC, &g_publish_t0);` (`:967`):

```cpp
    // [Phase 4 Stage A] Close the previous frame's seam sample. g_publish_t0 is
    // this frame's doorbell, which is the previous sample's closing edge.
    if (g_seam_have_prev) {
        mf_seam_add(&g_seam,
                    mf_seam_ms(&g_seam_prev_db, &g_seam_be),   // host
                    mf_seam_ms(&g_seam_be,      &g_seam_ar),   // block
                    mf_seam_ms(&g_seam_ar,      &g_publish_t0),// pub
                    mf_seam_ms(&g_seam_prev_db, &g_publish_t0),// period
                    g_seam_frame_ms,
                    g_seam_blocked ? 1 : 0);
#ifdef MISTER_NATIVE_VIDEO
        if (mf_stat_on() && mf_seam_ready(&g_seam)) {
            mf_seam_out_t o; mf_seam_derive(&g_seam, &o);
            fprintf(stderr,
                    "MFSEAM n=%u period=%.2f host=%.2f block=%.2f pub=%.2f "
                    "notice=%.2f blocked=%.0f%% suspect=%u "
                    "host_hist=%u/%u/%u/%u/%u/%u/%u/%u "
                    "pub_hist=%u/%u/%u/%u/%u/%u/%u/%u\n",
                    g_seam.n, o.period_ms, o.host_ms, o.block_ms, o.pub_ms,
                    o.notice_ms, 100.0 * o.blocked_frac, o.suspect,
                    g_seam.host_hist[0], g_seam.host_hist[1], g_seam.host_hist[2],
                    g_seam.host_hist[3], g_seam.host_hist[4], g_seam.host_hist[5],
                    g_seam.host_hist[6], g_seam.host_hist[7],
                    g_seam.pub_hist[0], g_seam.pub_hist[1], g_seam.pub_hist[2],
                    g_seam.pub_hist[3], g_seam.pub_hist[4], g_seam.pub_hist[5],
                    g_seam.pub_hist[6], g_seam.pub_hist[7]);
            mf_seam_reset(&g_seam);
        }
#endif
    }
    g_seam_prev_db   = g_publish_t0;
    g_seam_have_prev = true;
```

**(f)** With the other test hooks (near `:2434`):

```cpp
// [Phase 4 Stage A] Complete seam samples since reinit. Off-device nothing prints,
// so the accumulator is never reset and this counts frames directly.
extern "C" uint32_t RasterBackend_MFGPU_TestSeamSampleCount(void) { return g_seam.n; }
```

**(g)** In `RasterBackend_MFGPU_TestReinit` (`:2513`), after the `g_lru_evict_floor = 0;` line and before the closing brace:

```cpp
    mf_seam_reset(&g_seam);            // [Phase 4 Stage A] reinit means "no history"
    g_seam_have_prev  = false;         // ...so the next publish opens a sample, not closes one
    g_seam_blocked    = false;
    g_seam_frame_ms   = 0.0;
    g_seam_incomplete = 0;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make -f Makefile.gmloader raster-backend-test`
Expected: PASS — the existing cases all still pass and the new `mfgpu-seam-sample` case does not print FAIL. Exit 0.

Run: `make -f Makefile.gmloader mf-seam-stat-test`
Expected: PASS — unchanged.

- [ ] **Step 5: Verify the zero-cost gate**

The `MFSUBMIT` line must be byte-identical to before this task. Confirm no `fprintf` inside `mf_submit_stat` was touched:

Run: `git diff -- gmloader/mister/raster_backend_mfgpu.cpp | grep -c 'MFSUBMIT'`
Expected: `0` — the string appears in no changed line.

- [ ] **Step 6: Commit**

```bash
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_test.cpp
git commit -m "feat(seam): stamp the submit seam and print MFSEAM

Two new stamps (barrier entry, barrier exit); the doorbell stamp already existed
as g_publish_t0. A sample spans doorbell N to doorbell N+1 and is therefore
closed by the next publish. Printed on its own MFSEAM line behind the existing
mf_stat_on() knob, so no new env var appears and MFSUBMIT is untouched."
```

---

### Task 5: Repair `FCAP_STAT` and report audio starvation

**Files:**
- Modify: `gmloader/main.cpp` (`:114-124` statics, `:305` the wait timing, `:317-322` the print)

**Interfaces:**
- Consumes: `MisterAudio_StarvedFrames()` from `gmloader/mister/mister_native_audio.h:102` (already included at `main.cpp:34`).
- Produces: nothing consumed by later tasks.

**Two defects and one gap.** `g_fcap_frames` / `g_fcap_waits` / `g_fcap_wait_ms` are cumulative since process start, so `waited=375 (20.8%)` at `n=1800` is a lifetime average that cannot show the ratio moving during a run — and at the gate the ratio is expected to move to ~100 %. The wait is timed with `SDL_GetTicks()`, a 1 ms quantum, too coarse for a term the gate needs to see fall below 1 ms. And audio starvation only prints on change, so "clean" is still reported as absence of lines.

- [ ] **Step 1: Add the windowed counters**

In `gmloader/main.cpp`, beside the existing `g_fcap_waits` / `g_fcap_wait_ms` declarations (`:122-124`):

```cpp
// [Phase 4 Stage A] Windowed twins of the lifetime counters. The lifetime pair
// stays for the `n=` label; every ratio is reported over the last 300 frames,
// because at a locked 59.9228 fps the waited fraction is EXPECTED to move to
// ~100 % and a since-boot average would hide exactly that transition.
static uint32_t  g_fcap_win_frames = 0, g_fcap_win_waits = 0;
static double    g_fcap_win_wait_ms = 0.0;
```

- [ ] **Step 2: Time the wait with a monotonic clock**

In `fcap_wait` (`:292`), add a monotonic stamp beside the existing `t0`. Keep `SDL_GetTicks` for the 50 ms stall deadline — its wrap-safe comparison is load-bearing and 1 ms is ample for a 50 ms bound; only the *measurement* needs sub-ms resolution:

```cpp
                const Uint32 t0 = SDL_GetTicks();
                struct timespec ts0; clock_gettime(CLOCK_MONOTONIC, &ts0);
```

Replace the accounting line (`:305`):

```cpp
                if (g_fcap_stat) {
                    struct timespec ts1; clock_gettime(CLOCK_MONOTONIC, &ts1);
                    const double ms = (double)(ts1.tv_sec - ts0.tv_sec) * 1e3 +
                                      (double)(ts1.tv_nsec - ts0.tv_nsec) / 1e6;
                    g_fcap_waits++;      g_fcap_wait_ms     += ms;
                    g_fcap_win_waits++;  g_fcap_win_wait_ms += ms;
                }
```

- [ ] **Step 3: Window the print and add the audio field**

Replace the print block (`:317-322`):

```cpp
        if (g_fcap_mode == FCAP_SCANOUT) {
            g_fcap_frames++;
            if (g_fcap_stat && ++g_fcap_win_frames >= 300) {
                // waited% must be read WITH wait_ms_avg: high waited% with a small
                // average is a LOCKED frame rate (the success signature at 59.9228
                // Hz), while a low waited% with a multi-millisecond average is
                // frames MISSING their scanout boundary. Reading waited% alone as
                // waste optimises in exactly the wrong direction.
                warning("FCAP n=%u win=%u waited=%u (%.1f%%) wait_ms_avg=%.3f "
                        "starved=%llu mode=scanout\n",
                        (unsigned)g_fcap_frames, (unsigned)g_fcap_win_frames,
                        (unsigned)g_fcap_win_waits,
                        100.0 * g_fcap_win_waits / g_fcap_win_frames,
                        g_fcap_win_waits ? g_fcap_win_wait_ms / g_fcap_win_waits : 0.0,
                        (unsigned long long)MisterAudio_StarvedFrames());
                g_fcap_win_frames = 0; g_fcap_win_waits = 0; g_fcap_win_wait_ms = 0.0;
            }
            return;
        }
```

Note `g_fcap_frames++` moved out of the `if` so the lifetime count advances whether or not `GMLOADER_FCAP_STAT` is set — previously it only counted when the instrument was on, which is harmless but made the label mean two different things in two configurations.

- [ ] **Step 4: Verify it compiles for the device**

There is no host test harness for `main.cpp`; the armhf cross-build is the check.

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
make build-engine GMDIR=/Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-p4-seam
```
Expected: build succeeds and reports the produced `gmloader` binary path. A compile error naming `MisterAudio_StarvedFrames` means the include at `main.cpp:34` was removed — restore it rather than re-declaring the symbol.

- [ ] **Step 5: Verify the host tests still pass**

Run: `make -f Makefile.gmloader raster-backend-test && make -f Makefile.gmloader mf-seam-stat-test`
Expected: both PASS, exit 0.

- [ ] **Step 6: Commit**

```bash
git add gmloader/main.cpp
git commit -m "fix(fcap): window the cap counters, time them monotonically, report starvation

The counters were cumulative since process start, so the reported ratio could not
show the transition the 60 fps gate is defined by — at a locked 59.9228 Hz the
waited fraction is expected to reach ~100 % with a small average wait. The wait
was also timed with SDL_GetTicks, a 1 ms quantum, against a term the gate needs
below 1 ms. Audio starvation now prints every window, so zero is stated rather
than inferred from an absence of lines."
```

---

### Task 6: Device capture and the findings report

**Files:**
- Create: `docs/superpowers/findings/2026-07-30-phase4-stage-a-seam.md` (in `mister-gmloader`, not the engine worktree)

**Interfaces:**
- Consumes: the `MFSEAM` and repaired `FCAP` lines from Tasks 4–5.
- Produces: the sized term table that Stage B's plan is written from.

- [ ] **Step 1: Deploy the engine to the test device**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
make build-engine  GMDIR=/Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-p4-seam
make deploy-engine GMDIR=/Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-p4-seam
```

`HOST` defaults to `192.168.20.62` — do not pass `PROD=1`, that targets production `.81`. Never hand-launch the engine afterwards; `deploy-engine` swaps the binary and kills the running one, and the handler `exec`s the replacement.

- [ ] **Step 2: Capture the quiet scene, cap ON**

```bash
./scripts/mister_run.sh bench --secs 30 --scene ingame-stage1 \
  --preset fabric --prof --env GMLOADER_FCAP_STAT=1
```

Expected in the pulled log: a `frame-cap: … mode=scanout` line, repeating `MFSEAM n=30 …` lines, and `FCAP n=… win=300 …` lines. **If the log says `falling back to the wall-clock cap`, discard the run** — it measured a different system.

The harness retries the known frame-1 fabric wedge up to `MAX_WEDGE_ATTEMPTS` and re-greps the pulled log for `submit timeout` afterwards, exiting non-zero on a hit. A non-zero exit means discard and re-run, not "mostly fine".

- [ ] **Step 3: Capture the quiet scene, cap OFF**

```bash
./scripts/mister_run.sh bench --secs 30 --scene ingame-stage1 \
  --preset fabric --prof --fps 0 --env GMLOADER_FCAP_STAT=1
```

This is the unpaced body — the 18.09 ms baseline. `GMLOADER_FPS=0` is a measurement configuration only; it is never shipped, because rendering above 59.9228 Hz is discarded at the producer (`comp_fb_dma.sv:201`) with the full fabric and host cost already paid.

- [ ] **Step 4: Capture the arrival scene, cap ON**

```bash
./scripts/mister_run.sh bench --secs 30 --scene ingame-stage1-busy \
  --preset fabric --prof --env GMLOADER_FCAP_STAT=1
```

Arrival is measured, not gated, this stage. Confirm the scene by screenshot if the numbers look like the quiet scene — triangle counts alone do not distinguish gameplay from gmloader's own overlay.

- [ ] **Step 5: Check the instruments before trusting any number**

For each of the three logs:

1. `suspect=` must be `0` on essentially every `MFSEAM` line. A non-zero count means frames are being dropped or a stamp is being missed; **stop and fix the decomposition rather than reporting terms.** A handful of `suspect` at start-up (before the first full window) is expected; a sustained non-zero rate is not.
2. `period` on the `MFSEAM` line must agree with the run summary's frame period to within 0.1 ms. Two instruments disagreeing about the period means one of them is wrong.
3. Compare `period` between a run with `GMLOADER_MFSUBMIT_STAT` set and unset. A difference above 0.05 ms means the instrument is moving what it measures — the failure mode `GMLOADER_MFGPU_TRACE` already exhibits at 0.9–2.9 ms of `capture`.

- [ ] **Step 6: Write the findings document**

Create `docs/superpowers/findings/2026-07-30-phase4-stage-a-seam.md` containing:

1. **The term table**, quiet and arrival, cap ON and OFF: `period`, `host`, `block`, `pub`, `notice`, `blocked%`, each to ±0.05 ms, with `frame` from `MFSUBMIT` alongside.
2. **The `host` and `pub` distributions** from the histograms, and an explicit statement of whether the body is bimodal and in which term the bimodality lives.
3. **The repaired `FCAP` numbers** — windowed `waited%` and sub-ms `wait_ms_avg` — with the reading rule stated: high `waited%` + low average = locked; low `waited%` + multi-ms average = missing boundaries.
4. **Audio:** the `starved=` value, stated as a measured zero (or not).
5. **The Stage B lever sizing.** For each candidate — L1 body variance, L2 `notice`, L3 `pub`, L4 `host` — the term it removes and how many ms that term actually holds. **A lever with no term does not enter Stage B.**
6. **The `notice` verdict**, which decides Stage B's shape: if `notice` is dominated by `S_SNAP` serialization or DDR visibility, no host-only lever reaches the gate and Stage B re-gates as an RTL stage. Spec §8 records this as a planned outcome, not a failure.

- [ ] **Step 7: Commit the findings and the logs**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git add docs/superpowers/findings/2026-07-30-phase4-stage-a-seam.md bench-results/
git commit -m "docs(findings): Phase 4 Stage A — the submit seam, decomposed on .62

period split into host/block/pub with the identity closing and notice taken over
blocked frames only. Sizes every Stage B lever against the term it removes."
```

---

## Definition of Done

- [ ] `make -f Makefile.gmloader mf-seam-stat-test` passes.
- [ ] `make -f Makefile.gmloader raster-backend-test` passes, including `mfgpu-seam-sample`.
- [ ] The armhf cross-build succeeds.
- [ ] Three device logs on `.62`, each confirmed `mode=scanout`, each exiting zero from the wedge re-grep.
- [ ] `suspect=0` sustained across all three.
- [ ] Instrument-cost check under 0.05 ms of `period`.
- [ ] The findings doc sizes every Stage B lever against a named term, and states the `notice` verdict.

**Not in this plan, by design:** the redundant full-screen CLEAR, the 1.53 ms unexplained `ovhd` residual, opaque cull for the arrival scene, and the f2h-port / LW-bridge options. All are RTL, all are deferred, and Stage B's plan is written only after this stage's findings exist.

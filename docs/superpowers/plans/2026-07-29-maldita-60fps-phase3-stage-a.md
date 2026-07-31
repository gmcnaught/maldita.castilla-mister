# Maldita 60 fps Phase 3 — Stage A (sizing, no Quartus) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce the measured decomposition (bbox-miss tax, overdraw composition, per-state cycle accounting) and sim-validated lever prototypes that let the A4 gate pick the Stage B RTL scope for fabric 19.30 → ≤14.5 ms.

**Architecture:** An env-gated draw-stream capture at the engine's single emit choke point (`mf_emit_group`) dumps the exact `blt_vtx_t`/TRILIST-header data the fabric consumes; an offline Python analyzer computes pixel statistics; a new iverilog stream-replay testbench in the vendored `fpga/sim/` re-executes captured frames through the production `blitter_top.sv` with per-state cycle buckets; lever prototypes (span-walk, pipeline overlap) are implemented in RTL and validated in sim only — no Quartus cycle in Stage A.

**Tech Stack:** C++17 (engine host suite, native), Python 3 (analyzer), Icarus Verilog (`fpga/sim/run_sims.sh`), busybox ssh/scp bench (`scripts/mister_run.sh`).

**Spec:** `docs/superpowers/specs/2026-07-29-maldita-60fps-phase3-fabric-dpath.md`

## Global Constraints

- **Bases (verbatim from spec):** maldita RTL from `origin/milestone-a` (f2a39e2); engine from gmloader-next `origin/master` (d585b38). The two are the measured Phase 2 stack.
- **Worktrees, never `checkout -b` in a shared tree:** `git worktree add ../wt-maldita-60fps-p3 -b perf/60fps-phase3 origin/milestone-a` and `git worktree add ../wt-gmloader-60fps-p3 -b perf/60fps-phase3 origin/master` (run inside each repo's main checkout). Other sessions run concurrently on these repos.
- **Device:** all device work on `.62` (`root@192.168.20.62`). Never deploy to `.81`.
- **Fabric clock:** 98.4375 MHz (`clk_sys`). Cross-check identity: 13.59 ms × 98.4375 MHz ÷ 182,661 px = 7.32 cyc/px, matching the measured 7.3. Budget: ≤14.5 ms fabric = ≤1.427 M cycles/frame.
- **Quiet-scene reference numbers (Phase 2, must reproduce before trusting new data):** fabric 19.30 ms, tri 17.01, dpath 13.59, texwait 3.42, ovhd 2.29, covered 182,661 px, overdraw 2.94.
- **Sim suite must stay green:** `fpga/sim/run_sims.sh` — 51 passing at baseline. Engine host suite: `make -f Makefile.gmloader raster-backend-test` (native build, no Docker needed).
- **Engine ARM builds (device deploys only):** Docker per `mister-gmloader/Makefile` (`make build-engine deploy-engine HOST=192.168.20.62`); binfmt + submodules must be initialized first.
- **Deterministic scenes:** `scripts/scenes/ingame-stage1.joy` via `mister_run.sh bench --scene ingame-stage1`. Fabric medians of two runs match to 0.01 ms; if they don't, the run is contaminated (dual engine / daemon) — discard, don't explain.
- **Stage A commits no Quartus build.** RTL edits land on `perf/60fps-phase3` gated by sim only.

---

### Task 1: Worktrees and baseline verification

**Files:**
- No source edits. Creates worktrees `../wt-maldita-60fps-p3` and `../wt-gmloader-60fps-p3`.

**Interfaces:**
- Produces: the two branch names all later tasks commit to (`perf/60fps-phase3` in each repo), and recorded baseline test counts.

- [ ] **Step 1: Create the maldita worktree**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git fetch origin
git worktree add ../wt-maldita-60fps-p3 -b perf/60fps-phase3 origin/milestone-a
```

Expected: worktree at `../wt-maldita-60fps-p3`, HEAD = f2a39e2.

- [ ] **Step 2: Create the engine worktree (with submodules)**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
git fetch origin
git worktree add ../wt-gmloader-60fps-p3 -b perf/60fps-phase3 origin/master
cd ../wt-gmloader-60fps-p3 && git submodule update --init --recursive 3rdparty/mfgpu
```

Expected: HEAD = d585b38; `3rdparty/mfgpu` populated at pin 9ccd57a.

- [ ] **Step 3: Run both baselines and record counts**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-60fps-p3/fpga/sim && ./run_sims.sh
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-60fps-p3 && make -f Makefile.gmloader raster-backend-test
```

Expected: sim suite all pass (51 at last baseline; record the exact count — it is the regression floor for every later task); host suite prints its PASS summary and exits 0.

- [ ] **Step 4: Commit nothing; note baseline counts in the task report**

---

### Task 2: Engine draw-stream capture (`GMLOADER_MFGPU_TRACE`)

**Files:**
- Modify: `wt-gmloader-60fps-p3/gmloader/mister/raster_backend_mfgpu.cpp` (capture helpers near `mf_uvlog_on` ~line 1684; call site in `mf_emit_group` after the successful `blt_trilist` at ~line 1639)
- Test: `wt-gmloader-60fps-p3/gmloader/mister/raster_backend_test.cpp` (new case, follow the existing `case_*` function + registration pattern in that file)

**Interfaces:**
- Consumes: `mf_emit_group(const blt_surface_ref_t &tex, int tw, int th, const BVtx *verts, int nt, RBlend bl, bool has_key, uint8_t extra_flags)`; `g_vtxscratch[]` (`blt_vtx_t`: `int16_t x,y` 12.4 signed screen; `uint16_t u,v` 12.4 texel; `uint32_t rgba`); `g_frame_no`; resolved `blend_mode`/`colorkey` locals.
- Produces: text trace file, one line per record, consumed verbatim by Task 4 (analyzer) and Task 5 (sim replay generator):
  - `MFTRACE G f=<frame> off=<tex.off> stride=<tex.stride> texw=<tw> texh=<th> fmt=<tex.format> blend=<blend_mode> key=<colorkey> alpha=255 flags=<extra_flags> nt=<nt>`
  - `MFTRACE V <x> <y> <u> <v> <rgba-hex>` — three per triangle, `blt_vtx_t` integer fields (x,y,u,v as raw 12.4 ints), in `g_vtxscratch` order.
- Env contract: `GMLOADER_MFGPU_TRACE=<path>` enables; `GMLOADER_MFGPU_TRACE_START=<frame>` (default 0) and `GMLOADER_MFGPU_TRACE_FRAMES=<n>` (default 8) bound the window `[start, start+n)` of `g_frame_no`. Zero cost when unset (same lazy-getenv idiom as `mf_stat_on()`).

- [ ] **Step 1: Write the failing test**

Add to `raster_backend_test.cpp` (mirror the file's existing case style and its registration table):

```cpp
// GMLOADER_MFGPU_TRACE: emitted groups within the frame window are dumped as
// parseable G/V records of the exact wire data (blt_vtx_t ints, resolved blend),
// and the file is untouched outside the window or when the env is unset.
static int case_mfgpu_trace_capture(void) {
    const char *path = "/tmp/rbt_mftrace.txt";
    unlink(path);
    setenv("GMLOADER_MFGPU_TRACE", path, 1);
    setenv("GMLOADER_MFGPU_TRACE_START", "0", 1);
    setenv("GMLOADER_MFGPU_TRACE_FRAMES", "2", 1);
    rbt_reinit_mfgpu();                    // use the file's existing reinit helper name
    rbt_draw_textured_quad(/*x=*/10, /*y=*/10, /*w=*/32, /*h=*/16);  // existing helper style
    rbt_end_frame();                       // frame 0 -> in window
    rbt_draw_textured_quad(10, 10, 32, 16);
    rbt_end_frame();                       // frame 1 -> in window
    rbt_draw_textured_quad(10, 10, 32, 16);
    rbt_end_frame();                       // frame 2 -> OUT of window
    FILE *f = fopen(path, "r");
    CHECK(f != NULL, "trace file exists");
    int g_lines = 0, v_lines = 0, bad = 0; char ln[256];
    long frame_max = -1;
    while (fgets(ln, sizeof ln, f)) {
        if (!strncmp(ln, "MFTRACE G ", 10)) {
            g_lines++;
            long fr, nt; 
            CHECK(sscanf(ln, "MFTRACE G f=%ld", &fr) == 1, "G line parses");
            if (fr > frame_max) frame_max = fr;
            CHECK(strstr(ln, " blend=") && strstr(ln, " nt=") && strstr(ln, " off="),
                  "G line carries header fields");
            (void)nt;
        } else if (!strncmp(ln, "MFTRACE V ", 10)) {
            int x, y, u, v; unsigned rgba;
            CHECK(sscanf(ln, "MFTRACE V %d %d %d %d %x", &x, &y, &u, &v, &rgba) == 5,
                  "V line parses as ints");
            v_lines++;
        } else bad++;
    }
    fclose(f);
    CHECK(g_lines >= 2, "one G record per emitted group per in-window frame");
    CHECK(v_lines == g_lines_expected_tris * 3 || v_lines % 3 == 0, "3 V per tri");
    CHECK(frame_max <= 1, "frame 2 not captured (window respected)");
    CHECK(bad == 0, "no stray lines");
    unsetenv("GMLOADER_MFGPU_TRACE");
    return 0;
}
```

Adapt helper names (`rbt_reinit_mfgpu`, `rbt_draw_textured_quad`, `rbt_end_frame`, `CHECK`) to the file's actual local helpers — the file already has reinit/draw/end-frame plumbing used by `case_submit_publish_await_split` and the coverage cases; reuse those, do not invent parallel plumbing. Drop the `g_lines_expected_tris` placeholder in favor of the count your chosen draw helper actually emits (a quad = 2 tris → 6 V lines per group).

- [ ] **Step 2: Run to verify it fails**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-60fps-p3 && make -f Makefile.gmloader raster-backend-test
```

Expected: FAIL — "trace file exists" (no capture code yet).

- [ ] **Step 3: Implement the capture**

In `raster_backend_mfgpu.cpp`, next to the `mf_uvlog_on` block:

```cpp
// ── [Phase 3 Stage A] GMLOADER_MFGPU_TRACE ───────────────────────────────────
// Draw-stream capture for offline sizing + sim replay. Dumps, at the single
// point every surviving draw passes (mf_emit_group, after blt_trilist accepts),
// the exact wire-level data the fabric will read: the resolved blend/colorkey
// and the converted blt_vtx_t integers — NOT the float BVtx, so the offline
// consumers replay what the device executed, conversion included.
static FILE *mf_trace_f = NULL;
static int mf_trace_on(void) {
    static int v = -1;
    if (v < 0) {
        const char *e = getenv("GMLOADER_MFGPU_TRACE");
        if (e && *e) { mf_trace_f = fopen(e, "w"); v = (mf_trace_f != NULL); }
        else v = 0;
    }
    return v;
}
static long mf_trace_env_long(const char *name, long dflt) {
    const char *e = getenv(name);
    return (e && *e) ? atol(e) : dflt;
}
static int mf_trace_in_window(void) {
    static long start = -1, frames = -1;
    if (start < 0) {
        start  = mf_trace_env_long("GMLOADER_MFGPU_TRACE_START", 0);
        frames = mf_trace_env_long("GMLOADER_MFGPU_TRACE_FRAMES", 8);
    }
    return g_frame_no >= start && g_frame_no < start + frames;
}
static void mf_trace_group(const blt_surface_ref_t &tex, int tw, int th,
                           uint8_t blend_mode, uint16_t colorkey,
                           uint8_t extra_flags, int nt) {
    fprintf(mf_trace_f,
            "MFTRACE G f=%d off=%u stride=%u texw=%d texh=%d fmt=%u "
            "blend=%u key=%u alpha=255 flags=%u nt=%d\n",
            g_frame_no, tex.off, (unsigned)tex.stride, tw, th,
            (unsigned)tex.format, (unsigned)blend_mode, (unsigned)colorkey,
            (unsigned)extra_flags, nt);
    for (int i = 0; i < nt * 3; i++)
        fprintf(mf_trace_f, "MFTRACE V %d %d %d %d %08x\n",
                (int)g_vtxscratch[i].x, (int)g_vtxscratch[i].y,
                (int)g_vtxscratch[i].u, (int)g_vtxscratch[i].v,
                g_vtxscratch[i].rgba);
    fflush(mf_trace_f);   // engine may be SIGKILLed by the bench teardown
}
```

Call site in `mf_emit_group`, immediately after the `blt_trilist(...)` success path (after the `g_last_trilist_blend = blend_mode;` line):

```cpp
    if (mf_trace_on() && mf_trace_in_window())
        mf_trace_group(tex, tw, th, blend_mode, colorkey, extra_flags, nt);
```

- [ ] **Step 4: Run the suite to verify it passes**

```bash
make -f Makefile.gmloader raster-backend-test
```

Expected: all cases PASS including `case_mfgpu_trace_capture`.

- [ ] **Step 5: Mutation-check the test** — temporarily invert `mf_trace_in_window()`'s return, re-run, confirm the window assertion fails; revert. (Same discipline as the Phase 2 seam witnesses.)

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-60fps-p3
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_test.cpp
git commit -m "feat(mfgpu): GMLOADER_MFGPU_TRACE draw-stream capture at the emit choke point"
```

---

### Task 3: Bench plumbing + device captures (quiet and arrival)

**Files:**
- Modify: `mister-gmloader/scripts/mister_run.sh` (new `--capture` option on `bench`; post-run scp of the trace file, same guard style as the log pull at ~line 361)
- Output: `mister-gmloader/docs/superpowers/findings/data/mftrace-quiet.txt` and `.../mftrace-arrival.txt` (bench-results/ is GITIGNORED — captures must live under docs/ to be committed)

**Interfaces:**
- Consumes: Task 2's env contract; the engine deploy path `make build-engine deploy-engine HOST=192.168.20.62` from `mister-gmloader/Makefile`.
- Produces: the two trace files all offline analysis uses. Also the calibrated `GMLOADER_MFGPU_TRACE_START` frame numbers for both scenes (recorded in the findings doc).

- [ ] **Step 1: Add `--capture` to `mister_run.sh bench`**

In the arg-parse block that already handles `--scene` (~line 422), add `--capture START:FRAMES` which stages three more `GMLOADER_*` lines into the existing `bench.env` staging (the `--preset` mechanism at ~line 240):

```bash
      --capture) CAPTURE="$2"; shift 2 ;;   # START:FRAMES, e.g. 3200:8
```

and where bench.env is composed:

```bash
  if [ -n "${CAPTURE:-}" ]; then
    cap_start="${CAPTURE%%:*}"; cap_frames="${CAPTURE##*:}"
    printf 'GMLOADER_MFGPU_TRACE=/tmp/mftrace.txt\n'            >> "$tmp"
    printf 'GMLOADER_MFGPU_TRACE_START=%s\n'  "$cap_start"      >> "$tmp"
    printf 'GMLOADER_MFGPU_TRACE_FRAMES=%s\n' "$cap_frames"     >> "$tmp"
  fi
```

In the collect phase (next to the existing log scp, BEFORE teardown — the daemon respawn hazard applies to this file exactly as it does to `maldita.log`):

```bash
  if [ -n "${CAPTURE:-}" ]; then
    scp -o BatchMode=yes "$HOST:/tmp/mftrace.txt" "$outdir/mftrace-$label.txt" >/dev/null \
      || echo "[capture] WARNING: mftrace scp failed" >&2
  fi
```

- [ ] **Step 2: Build + deploy the Task 2 engine to .62**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
make build-engine deploy-engine HOST=192.168.20.62 ENGINE_DIR=../wt-gmloader-60fps-p3
```

(If the Makefile has no `ENGINE_DIR` override, check `make -n build-engine` for the sibling path it uses and point it at the p3 worktree — deploy.py builds from a sibling checkout, NOT the submodule pin, and the default GMDIR is a known stale-clone trap.) Two live deploy hazards from the concurrent session (memory 2026-07-29): (a) deploy.py's daemon-kill loop matched its own ssh shell — the `$$`-skip fix exists but was UNCOMMITTED in the maldita checkout; verify it is present (and commit it) before deploying, else `.62` is left with NO Master_Daemon. (b) If the fabric shows beacon=0 + C_DONE=0 while C_SUBMIT climbs, the f2h wedge survives core reloads — REBOOT `.62` before debugging anything else. Expected: deploy gate passes, exactly 1 Master_Daemon reported.

- [ ] **Step 3: Calibrate the capture window** — dry run `./scripts/mister_run.sh bench --secs 120 --scene ingame-stage1 --preset fabric --godmode --capture 0:4`, confirm the trace lands, then read the frame counter: quiet-scene arrival is ≈87 s in; estimate `START ≈ 87 s × ~46 fps ≈ 4000` and confirm against the screenshot-confirmed scene window by re-running with `--capture <est>:8` and checking the captured `f=` values fall inside the confirmed-gameplay window. Record the calibrated START for quiet; repeat for the Chapter I arrival transient (the MFSUBMIT window indices from the Phase 2 findings identify it; align by matching the fabric-counter spike). Sole-engine assertion must hold on every run used.

- [ ] **Step 4: Take the two captures**

```bash
./scripts/mister_run.sh bench --secs 120 --scene ingame-stage1 --preset fabric --godmode --capture <QUIET_START>:8
./scripts/mister_run.sh bench --secs 120 --scene ingame-stage1 --preset fabric --godmode --capture <ARRIVAL_START>:8
```

Expected: each capture contains 8 frames of G/V records; per-frame covered-pixel sanity happens in Task 4. Copy the pulled files to `docs/superpowers/findings/data/mftrace-quiet.txt` / `mftrace-arrival.txt` (bench-results/ is gitignored).

- [ ] **Step 5: Commit** (script change + the two traces)

```bash
git add scripts/mister_run.sh docs/superpowers/findings/data/mftrace-quiet.txt docs/superpowers/findings/data/mftrace-arrival.txt
git commit -m "feat(bench): --capture stages MFGPU_TRACE and pulls the stream; quiet+arrival captures"
```

---

### Task 4: Offline decomposition analyzer

**Files:**
- Create: `mister-gmloader/scripts/mftrace_analyze.py`
- Test: built-in `--selftest` (no pytest infra in this repo; the selftest is the gate)

**Interfaces:**
- Consumes: MFTRACE text format from Task 2 (G/V lines; x,y,u,v are raw 12.4 fixed-point ints).
- Produces: per-scene table printed to stdout and written as markdown next to the input (`<input>.analysis.md`) with, per frame and as medians: `covered_px`, `bbox_px`, `bbox_tax = bbox_px - covered_px`, `unique_px`, `overdraw = covered_px / unique_px`, covered px split by blend mode {COPY, CONST_ALPHA, COLORKEY, ADD, MULTIPLY}, and `cullable_px` = covered px of draws fully occluded by later COPY-mode geometry (the opaque-cull ceiling). Blend-mode numeric values must be read from `3rdparty/mfgpu/host/blt_wire.h` (`BLT_BLEND_*`) — do not hardcode guesses; copy the constants into the script with a comment naming the source header.

- [ ] **Step 1: Write the selftest first** (in the same file, `--selftest` mode):

```python
def selftest():
    # Two right triangles forming a 16x16 axis-aligned quad at (0,0), 12.4 fixed.
    def fx(v): return v << 4
    quad = [ (fx(0),fx(0)), (fx(16),fx(0)), (fx(0),fx(16)),
             (fx(16),fx(0)), (fx(16),fx(16)), (fx(0),fx(16)) ]
    tris = [quad[0:3], quad[3:6]]
    cov  = sum(coverage_px(t) for t in tris)
    bbox = sum(bbox_px(t) for t in tris)
    assert cov == 256, f"quad coverage {cov} != 256 (fill rule must not double-count the diagonal)"
    assert bbox == 2 * 289 or bbox == 2 * 256, f"bbox {bbox}"  # pin to the actual rule, see step 3
    # Overdraw: same quad drawn twice = covered 512, unique 256, overdraw 2.0
    frames = [make_frame([group(tris, blend=BLT_BLEND_COPY)] * 2)]
    st = analyze(frames)
    assert st.covered == 512 and st.unique == 256 and abs(st.overdraw - 2.0) < 1e-9
    # Cull ceiling: an ALPHA draw fully under a later COPY quad is 100% cullable
    frames = [make_frame([group(tris, blend=BLT_BLEND_CONST_ALPHA),
                          group(tris, blend=BLT_BLEND_COPY)])]
    st = analyze(frames)
    assert st.cullable == 256
    print("selftest OK")
```

- [ ] **Step 2: Run to verify it fails** — `python3 scripts/mftrace_analyze.py --selftest` → NameError (nothing implemented).

- [ ] **Step 3: Implement.** Core pieces:
  - Parser for G/V lines into `(header, [3n vertices])` groups per frame.
  - `coverage_px(tri)`: integer rasterization over pixel centers. **Match the refmodel's sampling rule, not a generic one**: read `fpga/sim/blt_tri.c` (the vendored refmodel copy) for its coverage test (edge functions / pixel-center convention, 12.4 inputs) and transcribe that rule; cite the function name in a comment. The Task 5 sim replay is the bit-exact oracle — this analyzer only needs coverage *counts*, so a ±edge-pixel divergence is tolerable, but starting from the refmodel's rule keeps it honest. Fill a per-frame `bytearray(288*216)` write-count plane; `unique_px` = nonzero cells, `covered_px` = sum.
  - `cullable_px`: process a frame's groups in submission order building an occlusion plane of pixels whose FINAL writer is a COPY-mode draw; a covered pixel of an EARLIER draw at such a location is cullable. (This is the ceiling for a front-to-back/opaque-first contract lever — it needs no texel data: COPY groups are already the has-no-transparency case by construction, see the `mf_emit_group` promotion comment at raster_backend_mfgpu.cpp:1618.)
  - Report emission (stdout table + `.analysis.md`).

- [ ] **Step 4: Selftest passes; run on both captures**

```bash
python3 scripts/mftrace_analyze.py --selftest
python3 scripts/mftrace_analyze.py docs/superpowers/findings/data/mftrace-quiet.txt
python3 scripts/mftrace_analyze.py docs/superpowers/findings/data/mftrace-arrival.txt
```

Expected sanity anchors (quiet): median `covered_px` within ~2% of 182,661; `overdraw` ≈ 2.94. If not, the capture or the coverage rule is wrong — stop and reconcile before proceeding (this is the analyzer's device-truth gate).

- [ ] **Step 5: Commit** (script + the two `.analysis.md` outputs)

---

### Task 5: Sim stream-replay testbench with per-state cycle buckets

**Files:**
- Create: `wt-maldita-60fps-p3/fpga/sim/gen_tri_stream.c` (pattern: `fpga/sim/gen_tri_golden.c` — same ring/vertex-qword packing and golden-frame emission via the local `blt_tri.c` refmodel; new: reads MFTRACE text instead of synthesizing geometry)
- Create: `wt-maldita-60fps-p3/fpga/sim/tb_blitter_trilist_stream.sv` (pattern: `tb_blitter_trilist_quad.sv` — same DDR model + blitter_top instantiation + golden compare; new: per-state cycle buckets)
- Modify: `wt-maldita-60fps-p3/fpga/sim/run_sims.sh` (register the new tb with its PASS marker; mark it NONGATING for the default run if its runtime is long, but it must still be runnable by name)

**Interfaces:**
- Consumes: MFTRACE files (Task 3, under docs/superpowers/findings/data/); `fpga/sim/blt_tri.c` refmodel; the TRILIST wire contract (opcode 12; header carries blend_mode, format, src_off, src_stride, src_x/y, w=tri count, dst_x|dst_y<<16 = vertex-entry byte offset, colorkey, alpha — per `3rdparty/mfgpu/host/blt_wire.h` lines 94–110; vertices are 16-byte `blt_vtx_t`).
- Produces: for a given trace + frame index: `RESULT: PASS` (RTL output bit-exact vs refmodel golden) plus a cycle report consumed by Tasks 6/7/8:
  `CYC total=<n> tri=<n> pix_visits=<n> pix_covered=<n> texwait=<n> wr=<n> setup=<n> vfetch=<n> other=<n>` — where `pix_visits` counts S_TRI_PIX entries (bbox tests) and `pix_covered` counts dispatched covered pixels. Cycle-bucket hooks follow the existing pattern of `perf_tri_cyc`/`perf_texwait_cyc` in `blitter_top.sv` (~line 1022) but live in the TB (hierarchical references to `dut.state`), NOT in the RTL — Stage A adds no RTL counters.
- **Texture content caveat (stated in the tb README comment):** the DDR model must be preloaded with the texture pages the trace references (`src_off`/stride/size from G lines). The capture does not carry texel data; initialize referenced pages with a deterministic pattern (address-hashed texels). Coverage, state sequencing, and cycle counts are texel-value-independent (COLORKEY compare aside); bit-exactness is asserted RTL-vs-refmodel over the SAME DDR image, so golden equivalence still gates. COLORKEY draws will take data-dependent write paths — both models see identical data, so the gate holds; only absolute texwait can differ from device (different memory latency), which is why calibration (Step 5) reports it separately.

- [ ] **Step 1: Write `gen_tri_stream.c`** — parse MFTRACE, select `--frame N`, pack the frame's groups into the command ring + vertex buffer exactly as `gen_tri_golden.c` does (reuse its helpers by `#include` or copy of its pack functions — cite which), run the refmodel over the same image, write `ddr_init.hex` + `fb_expected.hex`. Build line added to `gen_tri_golden.mk`'s pattern:

```make
gen_tri_stream: gen_tri_stream.c blt_tri.c
	$(CC) -O2 -Wall -o $@ gen_tri_stream.c blt_tri.c
```

- [ ] **Step 2: Write the tb** — instantiate `blitter_top` exactly as `tb_blitter_trilist_quad.sv` does (same ddr/sdram models, same poll-before-issue f2h modelling — the benches MUST model the poll gate), load `ddr_init.hex`, ring the doorbell, wait for completion, compare the framebuffer to `fb_expected.hex`, print `RESULT: PASS/FAIL` and the `CYC` line. Bucket by `dut.state` per cycle:

```systemverilog
  // Cycle bucketing (TB-side; no RTL change). State codes from blitter_top.sv:
  // S_TRI_PIX=50, S_TRI_GOTTEX=51 (texwait), S_TRI_WR/WR2/WR3=54/58/59,
  // S_TRI_SETUP/SWAIT=48/49, S_TRI_VFETCH/VCOLLECT/DECV=45/46/47.
  always @(posedge clk) if (in_tri) begin
    cyc_total <= cyc_total + 1;
    case (dut.state)
      6'd50: begin cyc_pix <= cyc_pix + 1; pix_visits <= pix_visits + 1; end
      6'd51: cyc_texwait <= cyc_texwait + 1;
      6'd54, 6'd58, 6'd59: cyc_wr <= cyc_wr + 1;
      6'd48, 6'd49: cyc_setup <= cyc_setup + 1;
      6'd45, 6'd46, 6'd47: cyc_vfetch <= cyc_vfetch + 1;
      default: cyc_other <= cyc_other + 1;
    endcase
  end
```

(Verify the enum values against the file before trusting the literals — they are current at origin/milestone-a lines 177–198; prefer hierarchical enum references `dut.S_TRI_PIX` if iverilog resolves them. `pix_visits` must count ENTRIES to S_TRI_PIX, not cycles in it — add an edge detect on state transition. `pix_covered` comes from the dut's existing covered-dispatch signal; find the signal `perf_covered_px` increments and reference it.)

- [ ] **Step 3: Run on a synthetic single-quad trace first** (write 1 G + 6 V lines by hand from the Task 4 selftest geometry): expect PASS and `pix_visits ≈ 2 × pix_covered` for the two right triangles (the bbox-tax signature) — this validates the buckets themselves.

- [ ] **Step 4: Run on `mftrace-quiet.txt` frame 0..2** — expect PASS (bit-exact) per frame. Runtime note: ~1.4 M cycles/frame in iverilog is minutes-per-frame; that is acceptable, run frames serially.

- [ ] **Step 5: Calibrate against device truth** — `cyc_total / 98.4375e6` per frame vs the device fabric `frame` 19.30 ms; `cyc_texwait` vs device texwait 3.42 ms. Record both deltas in the findings doc. If total is off by >10% with texwait excluded, the sim DDR model's latency needs a note (NOT tuning-by-fiat — record the gap and carry it as an uncertainty band on every Stage B prediction).

- [ ] **Step 6: Register in `run_sims.sh`, full suite still green, commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-60fps-p3/fpga/sim && ./run_sims.sh
git add gen_tri_stream.c tb_blitter_trilist_stream.sv run_sims.sh gen_tri_golden.mk
git commit -m "sim(trilist): stream-replay tb -- captured device frames, per-state cycle buckets"
```

---

### Task 6: Span-walk prototype (RTL, sim-gated)

**Files:**
- Modify: `wt-maldita-60fps-p3/fpga/rtl/blitter_top.sv` (the S_TRI_PIX/S_TRI_ADV walk: derive per-row x-entry/x-exit from the three edge functions instead of testing every bbox pixel)
- Modify (only if the row-span math lives there): `wt-maldita-60fps-p3/fpga/rtl/blt_tri_setup.sv`
- Test: existing `tb_blitter_trilist_*` suite (bit-exactness) + `tb_blitter_trilist_stream.sv` (cycle delta on real frames)

**Interfaces:**
- Consumes: Task 5's `CYC` report as the before/after instrument.
- Produces: a commit implementing span-walk whose gate is: every existing trilist tb PASS (bit-exact — visit order changes, output must not: no pixel is written twice within one triangle) + stream tb PASS on quiet frames + a measured `pix_visits ≈ pix_covered` (bbox tax eliminated) and a recorded `cyc_total` delta.

- [ ] **Step 1: Before-numbers** — run the stream tb on quiet frames at the pre-change commit; save the `CYC` lines.
- [ ] **Step 2: Implement.** Design note to follow (the how, concretely): at each row wrap (the per-row branch of `S_TRI_ADV`), instead of resetting x to bbox-left and testing every pixel, compute the row's covered interval from the three edge-function row values (each edge is linear in x: entry/exit where sign changes; intersect the three half-plane intervals, clamp to bbox). The per-row divide by the edge x-coefficient is the timing hazard — comb divide is the known failure mode ([[maldita-tri-timing-is-comb-depth]]); acceptable Stage A forms: multi-cycle row setup (a few cycles per ROW is nothing against ~1 cycle per saved PIXEL — quiet scene: ~366k bbox visits vs ~183k covered means ~183k saved cycles vs ~worst-case 3 extra cycles × ~rows), or a shift-subtract sequential divider. Keep the fill/tie rule EXACTLY the refmodel's — the span endpoints must reproduce the same >= / > edge comparisons; derive them from `blt_tri.c`'s comparisons, don't re-derive from theory.
- [ ] **Step 3: Bit-exact gates** — `./run_sims.sh` full suite: every trilist tb (including `tb_blitter_trilist_uvfull`, `_key`, `_missdst`) PASS.
- [ ] **Step 4: After-numbers** — stream tb on the same quiet + arrival frames: record `cyc_total`/`pix_visits` deltas; predicted device ms = `cyc_total / 98.4375e6` (+ the Task 5 calibration band).
- [ ] **Step 5: Mutation check** — deliberately off-by-one a span endpoint (`<=` → `<`), confirm at least one trilist tb FAILs (proves the bit-exact gate actually covers the span rule), revert.
- [ ] **Step 6: Commit** with the before/after `CYC` lines in the message body.

---

### Task 7: Pixel-pipeline occupancy analysis and (if indicated) overlap prototype

**Files:**
- Analysis: Task 5/6 `CYC` output; `blitter_top.sv` pa/pb structure (stage-3a comment block at ~line 485)
- Modify (conditional): `wt-maldita-60fps-p3/fpga/rtl/blitter_top.sv`

**Interfaces:**
- Consumes: post-span-walk cycle buckets (Task 6).
- Produces: either a prototype commit (same gates as Task 6) or a written no-go: "post-span-walk cyc/px is X; the remaining per-pixel states are {list}; deepening the overlap saves Y cycles predicted, costs Z risk — (not) worth Stage B scope."

- [ ] **Step 1: Decompose post-span-walk cyc/px** from the buckets: with bbox tax gone, what remains per covered pixel (pix, texwait residual, wr chain, adv)? Compare against the theoretical pb path (6 states/px; 8 with the dst read — see the COPY-promotion comment in `mf_emit_group`).
- [ ] **Step 2: Decide by arithmetic, in writing** — quiet target needs ≤1.20 M tri-cycles ((14.5 ms − 2.29 ms ovhd) × 98.4375 MHz); if span-walk alone gets there with ≥5% margin on BOTH quiet and the arrival capture's predicted number, record the no-go for further pipelining and skip to Task 8.
- [ ] **Step 3 (conditional): Prototype the overlap deepening** — target: B-stage (blend/write) of pixel N concurrent with A-stage of pixel N+1 at ~1 dispatch/cycle when texels hit the prefetch cache; gates identical to Task 6 (full suite bit-exact + stream tb + mutation check). Commit with before/after `CYC`.

---

### Task 8: A4 decision memo, arrival sizing, and the Stage B plan

**Files:**
- Create: `mister-gmloader/docs/superpowers/findings/2026-07-XX-phase3-stage-a-sizing.md` (dated when written)
- Create (via re-entering the writing-plans skill): `docs/superpowers/plans/2026-07-XX-maldita-60fps-phase3-stage-b.md`

**Interfaces:**
- Consumes: everything above — analyzer tables (Task 4), calibration band (Task 5), lever deltas (Tasks 6–7).
- Produces: the A4 decision, in the findings doc, in exactly this shape:

```
| Scene   | fabric today | predicted w/ span-walk | + pipeline | needed | verdict |
|---------|--------------|------------------------|-----------|--------|---------|
| Quiet   | 19.30 ms     | X.XX ± band            | X.XX      | ≤14.5  | ...     |
| Arrival | 25.5  ms     | X.XX ± band            | X.XX      | ≤15.0  | ...     |
plus: opaque-cull ceiling (Task 4 cullable_px → ms), and the Phase 4 sizing
paragraph for the arrival scene.
```

- [ ] **Step 1: Write the findings doc** — include the calibrated capture STARTs, the analyzer device-truth check (covered_px vs 182,661), the sim-vs-device calibration deltas, the lever table above, and the explicit Stage B scope decision: which lever(s) ship, and whether the opaque-cull contract lever is in (spec rule: it enters only if RTL levers alone cannot reach the quiet gate).
- [ ] **Step 2: Commit the findings doc** in mister-gmloader.
- [ ] **Step 3: Re-enter the writing-plans skill** to produce the Stage B plan from the decision (Quartus cycle: chosen lever(s) + scanout-period counter + STA gates + device validation per the spec's B1–B4). Stage B is deliberately NOT planned in detail here — its content is the A4 output.

---

## Verification ladder (recap)

1. Host suite green at every engine commit (`make -f Makefile.gmloader raster-backend-test`).
2. `run_sims.sh` full-suite green at every RTL commit; trilist tbs are the bit-exactness gate for every walk change.
3. Analyzer selftest + device-truth anchor (covered_px ≈ 182,661, overdraw ≈ 2.94) before any conclusion is drawn from it.
4. Stream-tb calibration band (sim cycles vs device 19.30 ms) attached to every Stage B prediction.
5. No device redeploy is needed after Task 3 — Stage A's remaining work is entirely offline. Any device re-measurement follows the Phase 2 protocol (sole engine, C_DONE delta, screenshots).

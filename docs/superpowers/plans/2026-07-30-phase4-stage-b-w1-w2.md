# Phase 4 Stage B — W1 (corpus + calibration) and W2 (CLEAR elimination) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-establish a trustworthy 4-scene measurement corpus, eliminate the redundant full-screen CLEAR from the engine's draw stream (−0.63 ms of fabric `frame`, no bitstream change), and run the stream-bench calibration that decides whether W3 (pb pipelining) is funded.

**Architecture:** Three repos, no Quartus cycle. `mister-gmloader/scripts/mister_run.sh` gains scene provenance so a capture can never again be un-attributable. The engine gains a **deferred full-screen fill**: `mf_clear()` records the fill instead of emitting it, and `mf_emit_group()` — the single point every surviving draw passes, and the only place the fabric blend mode is resolved — either discharges it before the draw or proves it redundant and drops it. The proof is a corner-exact screen-quad test, not a bounding box. Finally the captured heavy-scene trace becomes sim vectors and the real-cache stream bench is checked against the device anchor.

**Tech Stack:** C++17 host unit tests via `make -f Makefile.gmloader <target>` (no framework — plain `main()` + `CHECK` macros); POSIX shell tests run directly; iverilog testbenches via `fpga/sim/run_sims.sh`; ARM cross-build in Docker; device validation over SSH to `.62`.

## Scope

**This plan covers W1 and W2 only.** Spec §2 and §4.4 make **W3 conditional**: "W1 gates W3 — no Quartus time is spent until the stream bench reproduces the gate anchor", and "If it misses, W3 is not funded." W3's task content also depends on measurements W1 produces (the `ovhd` split design, the post-W2 anchor). **W3 gets its own plan after Task 7's calibration gate resolves.**

W2 is independently shippable and delivers a real device measurement on its own, so this plan produces working, deployed software regardless of the W3 decision.

## Global Constraints

- **Gate:** fabric `frame` ≤ **16.13 ms** on the sustained heavy scenes. Derived from `period = frame + notice + pub` with measured `notice` = 0.56, `pub` = 0.00, against a scanout period of **16.6882 ms / 59.9228 Hz** (never round this figure).
- **Test device is `.62`** (`root@192.168.20.62`). `.81` is PRODUCTION and is not touched by this plan. `deploy.py --host` still defaults to `.81` — always pass `--host 192.168.20.62`, or use the Makefile (`HOST` defaults to `.62`).
- **Engine deploy = swap then kill:** scp to `gmloader.new`, `mv -f` over the running binary, `killall -9 gmloader`. The handler re-execs it. **Never hand-launch after** — that is how two engines end up on one control block.
- **Worktree per workstream.** The user runs concurrent sessions on these checkouts. `git worktree add ../wt-<topic> -b <branch>` **before** the first commit. Never `git checkout -b` in a shared tree.
- **The shipping blitter RTL is the vendored copy** in `maldita.castilla-mister/fpga/rtl/`. `mister-fpga-blitter/rtl/` is a non-shipping v1 spike.
- **Failure mode discipline for W2:** any condition not provably met **emits** the fill. The permitted failure is a lost 0.63 ms, never a stale pixel.
- **No device run counts unless** `suspect=0`, `incomplete=0`, and no `submit timeout` appear in its log, and `mister_run.sh` exits zero.

---

## File Structure

**`mister-gmloader`** (this repo — harness + docs)

- Create `scripts/lib/scene_provenance.sh` — pure shell helpers that render the provenance block and compute a portable file digest. No SSH, no globals from `mister_run.sh`.
- Create `scripts/lib/scene_provenance_test.sh` — host test for the above, following `scripts/lib/device_pids_test.sh`'s pattern (source the lib, `check` assertions, non-zero exit on failure).
- Modify `scripts/mister_run.sh` — source the new lib; put the scene name in the results filename; append the provenance block to the pulled log artifact.
- Create `docs/superpowers/findings/data/2026-07-30-phase4-stage-b/` — the 4-scene corpus (traces + analyses + logs).
- Create `docs/superpowers/findings/2026-07-30-phase4-stage-b-w1-w2.md` — the findings document.

**`gmloader-next`** (engine)

- Create `gmloader/mister/mf_pending_clear.h` — the deferred-fill state machine and the cover predicate. Dependency-free and pure, exactly like `mf_seam_stat.h`: no I/O, no globals, no device headers, no engine types.
- Create `gmloader/mister/mf_pending_clear_test.cpp` — host unit test driver.
- Modify `Makefile.gmloader` — add the `mf-pending-clear-test` target next to `mf-seam-stat-test`.
- Modify `gmloader/mister/raster_backend_mfgpu.cpp` — wire the module into `mf_clear()`, `mf_emit_group()`, `mf_frame_begin()`, `mf_frame_end()`; add the witness counters to the periodic stat line.

**`maldita.castilla-mister`** (sim vectors only — no RTL change in this plan)

- Modify `fpga/sim/gen_tri_golden.mk` — add a `stream-vectors-heavy` target.
- Modify `fpga/sim/tb_blitter_trilist_stream.sv` and `fpga/sim/tb_blitter_trilist_streamcache.sv` — document the new `STREAM_VEC` tag in their headers.
- Add `fpga/sim/vectors/stream_heavy_f0_ddr.hex` / `_exp.hex` — the committed heavy-scene vectors.

---

## Task 1: Scene provenance in the bench harness

The Stage A corpus is unusable because captures A and C are the same trajectory and nothing in the artifacts records which scene was requested (seam findings §9 caveats 1–2). The results filename is built from `${args[*]}` in `do_bench()`, and `--scene NAME` is consumed by the argument parser **before** that — so two runs of different scenes with the same `--preset fabric` produce identically-named logs with no scene field inside them. That is the defect.

**Files:**
- Create: `/Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/scripts/lib/scene_provenance.sh`
- Test: `/Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/scripts/lib/scene_provenance_test.sh`
- Modify: `/Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/scripts/mister_run.sh` (`do_bench`, near line 498)

**Interfaces:**
- Produces: `sp_digest <file>` → prints a hex digest of `<file>`, or `unavailable` if no digest tool exists. `sp_block <scene> <joy_path> <joy_digest> <host> <secs> <args...>` → prints the multi-line provenance block. `sp_label_suffix <scene>` → prints `--scene_<scene>` or the empty string.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test**

Create `scripts/lib/scene_provenance_test.sh`:

```bash
#!/bin/bash
# Host-side test for scene_provenance.sh. Pure string/digest helpers, so this
# needs no MiSTer and no network.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/scene_provenance.sh"

fails=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "ok   - $1"
  else echo "FAIL - $1: expected '$2' got '$3'"; fails=$((fails+1)); fi
}
contains() { # contains <desc> <needle> <haystack>
  case "$3" in *"$2"*) echo "ok   - $1" ;;
  *) echo "FAIL - $1: '$2' not found in output"; fails=$((fails+1)) ;; esac
}

# A run with no scene must still produce a label that is a valid filename
# fragment, and must say "none" rather than leaving the field blank -- a blank
# field is what made the Stage A logs unattributable.
check "no scene -> empty label suffix" "" "$(sp_label_suffix "")"
check "scene -> label suffix"          "--scene_ingame-stage1" "$(sp_label_suffix ingame-stage1)"

# The digest must be stable for identical content and differ for different
# content, whichever tool the host actually has.
tmpa="$(mktemp)"; tmpb="$(mktemp)"; tmpc="$(mktemp)"
printf 'alpha\n' > "$tmpa"; printf 'alpha\n' > "$tmpb"; printf 'beta\n' > "$tmpc"
da="$(sp_digest "$tmpa")"; db="$(sp_digest "$tmpb")"; dc="$(sp_digest "$tmpc")"
check "digest is stable for identical content" "$da" "$db"
if [ "$da" = "$dc" ]; then
  echo "FAIL - digest differs for different content"; fails=$((fails+1))
else
  echo "ok   - digest differs for different content"
fi
rm -f "$tmpa" "$tmpb" "$tmpc"

# A missing file must not abort the run; provenance is evidence, not a gate.
check "missing file -> unavailable" "unavailable" "$(sp_digest /nonexistent/scene.joy)"

# The block is the artifact an operator reads months later, so every field the
# Stage A corpus lacked has to be present by name.
blk="$(sp_block ingame-stage1-busy scripts/scenes/ingame-stage1-busy.joy abc123 192.168.20.62 30 --preset fabric)"
contains "block names the scene"  "scene: ingame-stage1-busy"   "$blk"
contains "block names the joy"    "scene_joy: scripts/scenes/ingame-stage1-busy.joy" "$blk"
contains "block names the digest" "scene_joy_digest: abc123"    "$blk"
contains "block names the host"   "host: 192.168.20.62"         "$blk"
contains "block names the secs"   "secs: 30"                    "$blk"
contains "block names the args"   "args: --preset fabric"       "$blk"

blk_none="$(sp_block "" "" "" 192.168.20.62 30 --preset fabric)"
contains "no-scene block says none" "scene: (none)" "$blk_none"

if [ "$fails" -ne 0 ]; then echo "$fails failure(s)"; exit 1; fi
echo "all scene_provenance tests passed"
```

Make it executable:

```bash
chmod +x /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/scripts/lib/scene_provenance_test.sh
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader && ./scripts/lib/scene_provenance_test.sh
```

Expected: FAIL — `scene_provenance.sh: No such file or directory`.

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/lib/scene_provenance.sh`:

```bash
# scene_provenance.sh — pure helpers that make a bench artifact self-describing.
#
# The Phase 4 Stage A corpus could not be interpreted because the results
# filename is built from the diag ARGS only (do_bench's `label`), and --scene is
# consumed by the argument parser before that point. Two runs of different scenes
# with the same --preset therefore produced identically-named logs with no scene
# field inside them, and the findings could not tell which workload was which.
#
# Everything here is a pure function over its arguments: no SSH, no globals from
# mister_run.sh, no side effects. That is what makes it host-testable.

# sp_digest <file> — hex digest of <file>, or the literal string "unavailable".
# Portable across macOS (md5) and Linux (md5sum); provenance is evidence, not a
# gate, so a host with neither tool degrades rather than aborting the run.
sp_digest() {
  local f="$1"
  [ -f "$f" ] || { printf 'unavailable'; return 0; }
  if command -v md5 >/dev/null 2>&1; then
    md5 -q "$f" | tr -d '\n'
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum "$f" | awk '{printf "%s", $1}'
  else
    printf 'unavailable'
  fi
}

# sp_label_suffix <scene> — filename fragment identifying the scene, or empty.
# Kept separate from sp_block so the SAME scene identity reaches both the
# filename and the file contents; the Stage A corpus had it in neither.
sp_label_suffix() {
  local scene="$1"
  [ -n "$scene" ] || { printf ''; return 0; }
  printf -- '--scene_%s' "$scene"
}

# sp_block <scene> <joy_path> <joy_digest> <host> <secs> [args...]
# The provenance block appended to the pulled log. An operator reading
# bench-results/*.log months later has no transcript -- only this.
sp_block() {
  local scene="$1" joy="$2" digest="$3" host="$4" secs="$5"
  shift 5
  echo "----- mister_run.sh scene provenance -----"
  echo "scene: ${scene:-(none)}"
  echo "scene_joy: ${joy:-(none)}"
  echo "scene_joy_digest: ${digest:-(none)}"
  echo "host: $host"
  echo "secs: $secs"
  echo "args: $*"
  echo "------------------------------------------"
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader && ./scripts/lib/scene_provenance_test.sh
```

Expected: every line `ok   - ...`, final line `all scene_provenance tests passed`, exit 0.

- [ ] **Step 5: Wire it into `do_bench`**

In `scripts/mister_run.sh`, source the lib next to the existing `device_pids.sh` source line (find it with `grep -n 'device_pids.sh' scripts/mister_run.sh`), adding:

```bash
. "$HERE/lib/scene_provenance.sh"
```

Then in `do_bench()`, change the label construction so the scene reaches the filename. Replace:

```bash
  label=$(printf '%s' "${args[*]}" | tr ' /' '__' | tr -cd 'A-Za-z0-9_.-')
  [ -n "$label" ] || label="default"
```

with:

```bash
  label=$(printf '%s' "${args[*]}" | tr ' /' '__' | tr -cd 'A-Za-z0-9_.-')
  [ -n "$label" ] || label="default"
  # [Phase 4 Stage B Task 1] The scene is consumed by the arg parser and never
  # reached ${args[*]}, so two different scenes under the same --preset produced
  # identically-named logs. That is why the Stage A corpus could not be read.
  label="${label}$(sp_label_suffix "$SCENE")"
```

Then, immediately **before** the existing `echo "[bench] log -> $local_log"` line, append the provenance block to the artifact:

```bash
  # [Phase 4 Stage B Task 1] Provenance INTO the artifact, next to the wedge
  # gate block, for the same reason: an operator auditing this file later has
  # no transcript.
  sp_block "$SCENE" \
           "${SCENE:+$HERE/scenes/$SCENE.joy}" \
           "$(sp_digest "${SCENE:+$HERE/scenes/$SCENE.joy}")" \
           "$HOST" "$SECS" "${args[@]+"${args[@]}"}" >> "$local_log"
```

- [ ] **Step 6: Verify the wiring with a dry check**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader && bash -n scripts/mister_run.sh && echo "SYNTAX OK"
grep -n 'sp_label_suffix\|sp_block\|scene_provenance.sh' scripts/mister_run.sh
```

Expected: `SYNTAX OK`, and three grep hits (the source line, the label line, the block line).

- [ ] **Step 7: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git add scripts/lib/scene_provenance.sh scripts/lib/scene_provenance_test.sh scripts/mister_run.sh
git commit -m "fix(bench): make a capture say which scene it is

The Stage A corpus was uninterpretable because do_bench's filename label is
built from the diag args only, and --scene is consumed by the parser before
that point. Two scenes under one --preset produced identically-named logs with
no scene field inside them.

Scene now reaches both the filename and a provenance block appended to the
pulled log, alongside the joy script's digest, host, secs and args."
```

---

## Task 2: Capture the 4-scene corpus and the pre-W2 fabric baseline

This produces the anchors every later task measures against, and the traces Task 6 turns into sim vectors. **Nothing in W2 is measured without this baseline.**

**Files:**
- Create: `docs/superpowers/findings/data/2026-07-30-phase4-stage-b/` (traces, analyses, logs)
- Uses: `scripts/mister_run.sh`, `scripts/mftrace_analyze.py`

**Interfaces:**
- Consumes: Task 1's provenance (every log must carry the block).
- Produces: four `mftrace-<tag>.txt` captures and a baseline table of `frame` / `tri` / `dpath` / `texwait` / `ovhd` / `cov_px` per scene, used as the pre-W2 anchor by Task 5 and as the calibration target by Task 7.

- [ ] **Step 1: Confirm the device is reachable and singular**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh ping
```

Expected: SSH ok, core name printed, engine process count `0` or `1`. If it reports `2`, stop — a dual engine invalidates every number (see the `native-audio-does-not-wedge-the-fabric` finding).

- [ ] **Step 2: Determine whether the two scene scripts actually diverge**

Before capturing, settle the §9 caveat-1 question. Run both scenes briefly and compare their coverage distributions:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
for s in ingame-stage1 ingame-stage1-busy; do
  MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh bench \
    --secs 40 --scene "$s" --env GMLOADER_MFSUBMIT_STAT=1 --preset fabric
done
```

Then compare the `cov_px` values the two logs report:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/bench-results
for f in *--scene_ingame-stage1.log *--scene_ingame-stage1-busy.log; do
  echo "== $f"; grep -o 'cov_px=[0-9]*' "$f" | sort -u | tail -5
done
```

Record the answer in the findings document (Task 8): either the scripts genuinely produce one workload (a real defect in `ingame-stage1-busy.joy`, to be fixed here), or they diverge and the Stage A collapse was that both captures were run with the same `--scene` — which Task 1 now makes impossible to repeat.

If they do **not** diverge, edit `scripts/scenes/ingame-stage1-busy.joy` to hold the sword input longer / drive further into the arrival transient, and repeat this step until the two `cov_px` populations differ. Do not proceed with one workload.

- [ ] **Step 3: Capture the four scenes with draw-stream traces**

`--capture START:FRAMES` takes **engine frame numbers** (`g_frame_no` from engine start), not seconds. Use a first pass to find the frame window where each scene settles, reading `MFSUBMIT n=` against `cov_px`, then capture 8 frames inside it.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
# quiet — anchor cov_px 182,661
MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh bench \
  --secs 90 --scene ingame-stage1 --capture 4000:8 \
  --env GMLOADER_MFSUBMIT_STAT=1 --env GMLOADER_FCAP_STAT=1 --preset fabric
# arrival — anchor cov_px 245,346
MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh bench \
  --secs 90 --scene ingame-stage1-busy --capture 2465:8 \
  --env GMLOADER_MFSUBMIT_STAT=1 --env GMLOADER_FCAP_STAT=1 --preset fabric
```

Repeat for the two heavy scenes, choosing `--capture` windows that land on `cov_px` ≈ 195,084 (heavy-A) and ≈ 213,358 (heavy-B, the gate anchor). The bench prints `[capture] frames=N requested=M groups=... f-range=...` — **`frames` must equal `requested`**, otherwise the window did not fully open and the capture is unusable.

- [ ] **Step 4: Gate scene identity numerically**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
./scripts/mftrace_analyze.py bench-results/<quiet-trace>.txt   --expect-covered 182661 --tol 2.0
./scripts/mftrace_analyze.py bench-results/<heavy-b-trace>.txt --expect-covered 213358 --tol 2.0
./scripts/mftrace_analyze.py bench-results/<arrival-trace>.txt --expect-covered 245346 --tol 2.0
```

Expected: exit 0 for each. A non-zero exit means the capture did not land on the intended scene — re-take it, do not adjust the tolerance.

This is the **primary** scene-identity proof. It is reproducible and numeric, which a screenshot is not.

- [ ] **Step 5: Visual confirmation**

The repo has no screenshot tooling, so this is a manual check and must be recorded as one. Determine the mechanism on the device first rather than assuming it:

```bash
ssh root@192.168.20.62 'ls -la /media/fat/screenshots 2>/dev/null | tail -5; ls -la /dev/fb0 2>/dev/null'
```

Record in the findings document which mechanism was used and what each scene showed (e.g. "Chapter I forest, HUD `SPEEDRUN 00:36 / TIME 89`", matching the Phase 3 Stage A style). If no mechanism exists on the device, state that plainly in the findings and rely on Step 4's numeric gate — **do not claim screenshot confirmation that was not performed.**

- [ ] **Step 6: Record the pre-W2 baseline**

For each of the four scenes, extract the medians over the settled windows:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/bench-results
grep -h 'MFSUBMIT' <scene>.log | tail -20
```

Build the baseline table (`frame`, `tri`, `dpath`, `texwait`, `ovhd`, `cov_px`, `overdraw`) into a scratch note for Task 8. Verify the integrity gates on every log:

```bash
for f in bench-results/*.log; do
  echo "$f: suspect=$(grep -c 'suspect=[^0]' "$f") incomplete=$(grep -c 'incomplete=[^0]' "$f") wedge=$(grep -c 'submit timeout' "$f")"
done
```

Expected: `0 0 0` on every file. Any non-zero invalidates that run.

- [ ] **Step 7: Commit the corpus**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
mkdir -p docs/superpowers/findings/data/2026-07-30-phase4-stage-b
cp bench-results/*mftrace*.txt bench-results/*--scene_*.log \
   docs/superpowers/findings/data/2026-07-30-phase4-stage-b/
git add docs/superpowers/findings/data/2026-07-30-phase4-stage-b
git commit -m "data(phase4-b): 4-scene corpus with provenance and numeric identity gates

quiet 182,661 / heavy-A 195,084 / heavy-B 213,358 / arrival 245,346 covered px,
each gated by mftrace_analyze.py --expect-covered within 2%. Replaces the Stage A
corpus, which contained one workload under two labels."
```

---

## Task 3: The deferred-clear module (`mf_pending_clear.h`)

Pure, dependency-free, host-testable — the same shape as `mf_seam_stat.h`. It holds the pending-fill state and the **cover proof**. No engine types, no I/O.

The proof must be exact. A bounding-box test is **not** sufficient: two thin slivers at opposite corners have a full-screen bbox and cover almost nothing. The test used here is corner-exact — each triangle must consist of three *distinct* corners of the target rect, and the two triangles together must hit all four corners. Two such triangles are each exactly half the rect and are the two complementary halves, so their union is the whole rect.

**Files:**
- Create: `/Users/gmcnaught/MisterFPGA-Projects/gmloader-next/gmloader/mister/mf_pending_clear.h`
- Test: `/Users/gmcnaught/MisterFPGA-Projects/gmloader-next/gmloader/mister/mf_pending_clear_test.cpp`
- Modify: `/Users/gmcnaught/MisterFPGA-Projects/gmloader-next/Makefile.gmloader` (new target beside `mf-seam-stat-test`, near line 234)

**Interfaces:**
- Consumes: nothing.
- Produces, for Task 4:
  - `typedef struct { ... } mf_pc_t;` with fields `dropped` and `emitted` (`uint32_t`).
  - `void mf_pc_reset(mf_pc_t *p)`
  - `void mf_pc_record(mf_pc_t *p, int target, int w, int h, uint16_t color)`
  - `int  mf_pc_pending(const mf_pc_t *p, int target)`
  - `int  mf_pc_take(mf_pc_t *p, int target, int *w, int *h, uint16_t *color)` — clears the slot and returns 1 if there was one to emit, counting it as `emitted`.
  - `void mf_pc_drop(mf_pc_t *p, int target)` — clears the slot as proven-redundant, counting it as `dropped`.
  - `int  mf_pc_is_cover(int blend_copy, int nt, const float *xs, const float *ys, int w, int h)`
  - `#define MF_PC_TARGETS 2`

- [ ] **Step 1: Write the failing test**

Create `gmloader/mister/mf_pending_clear_test.cpp`:

```cpp
// Host unit test for the Phase 4 Stage B deferred full-screen clear
// (mf_pending_clear.h).
//
// The module is deliberately pure -- no I/O, no globals, no device headers --
// so the cover proof and the slot bookkeeping are testable without a MiSTer.
// raster_backend_mfgpu.cpp contributes only the vertices and the resolved
// blend mode.
#include "mf_pending_clear.h"

#include <stdio.h>

static int g_fail = 0;
#define CHECK(c) do { if (!(c)) { \
    printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); g_fail = 1; } } while (0)

enum { W = 288, H = 216 };

// The canonical GameMaker full-screen quad: two triangles over the four corners,
// sharing the (0,0)-(W,H) diagonal.
static void full_quad(float *xs, float *ys) {
    const float qx[6] = { 0, (float)W, 0,   (float)W, (float)W, 0        };
    const float qy[6] = { 0, 0,        (float)H, 0,   (float)H, (float)H };
    for (int i = 0; i < 6; i++) { xs[i] = qx[i]; ys[i] = qy[i]; }
}

static void case_full_copy_quad_is_a_cover(void) {
    float xs[6], ys[6]; full_quad(xs, ys);
    CHECK(mf_pc_is_cover(/*blend_copy=*/1, /*nt=*/2, xs, ys, W, H) == 1);
}

// A non-COPY blend does not write every covered pixel (CONST_ALPHA reads dst,
// COLORKEY skips keyed texels), so it can never discharge a clear.
static void case_non_copy_blend_is_not_a_cover(void) {
    float xs[6], ys[6]; full_quad(xs, ys);
    CHECK(mf_pc_is_cover(/*blend_copy=*/0, 2, xs, ys, W, H) == 0);
}

// THE defect a bounding-box test would have: two thin slivers at opposite
// corners have a full-screen bbox and cover almost nothing.
static void case_two_slivers_with_full_bbox_are_not_a_cover(void) {
    const float xs[6] = { 0, 1, 0,        (float)W, (float)W - 1, (float)W };
    const float ys[6] = { 0, 0, 1,        (float)H, (float)H,     (float)H - 1 };
    CHECK(mf_pc_is_cover(1, 2, xs, ys, W, H) == 0);
}

// Both triangles on the SAME three corners: only half the rect is painted twice.
static void case_duplicate_half_is_not_a_cover(void) {
    const float xs[6] = { 0, (float)W, 0,   0, (float)W, 0   };
    const float ys[6] = { 0, 0,        (float)H, 0, 0,   (float)H };
    CHECK(mf_pc_is_cover(1, 2, xs, ys, W, H) == 0);
}

// A quad that falls one pixel short of an edge leaves that edge unpainted.
static void case_quad_short_of_the_edge_is_not_a_cover(void) {
    const float qx[6] = { 0, (float)W - 1, 0,        (float)W - 1, (float)W - 1, 0        };
    const float qy[6] = { 0, 0,            (float)H, 0,            (float)H,     (float)H };
    CHECK(mf_pc_is_cover(1, 2, qx, qy, W, H) == 0);
}

// A quad that OVERHANGS still covers the rect -- conservative in the safe
// direction, so it must be accepted.
static void case_overhanging_quad_is_a_cover(void) {
    const float qx[6] = { -4, (float)W + 4, -4,           (float)W + 4, (float)W + 4, -4           };
    const float qy[6] = { -4, -4,           (float)H + 4, -4,           (float)H + 4, (float)H + 4 };
    CHECK(mf_pc_is_cover(1, 2, qx, qy, W, H) == 1);
}

// Anything that is not a 2-triangle quad is out of scope by construction.
static void case_non_two_triangle_draw_is_not_a_cover(void) {
    float xs[6], ys[6]; full_quad(xs, ys);
    CHECK(mf_pc_is_cover(1, /*nt=*/1, xs, ys, W, H) == 0);
    CHECK(mf_pc_is_cover(1, /*nt=*/4, xs, ys, W, H) == 0);
}

static void case_record_take_and_drop_bookkeeping(void) {
    mf_pc_t p; mf_pc_reset(&p);
    CHECK(mf_pc_pending(&p, 0) == 0);
    CHECK(p.dropped == 0 && p.emitted == 0);

    mf_pc_record(&p, 0, W, H, 0x1234);
    CHECK(mf_pc_pending(&p, 0) == 1);

    int w = 0, h = 0; uint16_t c = 0;
    CHECK(mf_pc_take(&p, 0, &w, &h, &c) == 1);
    CHECK(w == W && h == H && c == 0x1234);
    CHECK(p.emitted == 1 && p.dropped == 0);
    CHECK(mf_pc_pending(&p, 0) == 0);
    CHECK(mf_pc_take(&p, 0, &w, &h, &c) == 0);   // idempotent when empty

    mf_pc_record(&p, 0, W, H, 0x4321);
    mf_pc_drop(&p, 0);
    CHECK(p.dropped == 1 && p.emitted == 1);
    CHECK(mf_pc_pending(&p, 0) == 0);
}

// The two targets are independent: a draw into WORK must not discharge a clear
// that was recorded against APPSURF.
static void case_targets_are_independent(void) {
    mf_pc_t p; mf_pc_reset(&p);
    mf_pc_record(&p, 0, W, H, 0x0001);
    mf_pc_record(&p, 1, W, H, 0x0002);
    int w, h; uint16_t c;
    CHECK(mf_pc_take(&p, 0, &w, &h, &c) == 1);
    CHECK(c == 0x0001);
    CHECK(mf_pc_pending(&p, 1) == 1);
    CHECK(mf_pc_take(&p, 1, &w, &h, &c) == 1);
    CHECK(c == 0x0002);
}

// Two clears with no draw between them: the second provably overwrites the
// first, so the first is a real, countable saving -- not a lost fill.
static void case_second_record_supersedes_the_first(void) {
    mf_pc_t p; mf_pc_reset(&p);
    mf_pc_record(&p, 0, W, H, 0x1111);
    mf_pc_record(&p, 0, W, H, 0x2222);
    CHECK(p.dropped == 1);
    int w, h; uint16_t c;
    CHECK(mf_pc_take(&p, 0, &w, &h, &c) == 1);
    CHECK(c == 0x2222);
    CHECK(p.emitted == 1);
}

// An out-of-range target index must be inert, never a memory error.
static void case_out_of_range_target_is_inert(void) {
    mf_pc_t p; mf_pc_reset(&p);
    mf_pc_record(&p, MF_PC_TARGETS, W, H, 0xFFFF);
    mf_pc_record(&p, -1, W, H, 0xFFFF);
    CHECK(mf_pc_pending(&p, MF_PC_TARGETS) == 0);
    CHECK(mf_pc_pending(&p, -1) == 0);
    CHECK(p.dropped == 0 && p.emitted == 0);
}

int main(void) {
    case_full_copy_quad_is_a_cover();
    case_non_copy_blend_is_not_a_cover();
    case_two_slivers_with_full_bbox_are_not_a_cover();
    case_duplicate_half_is_not_a_cover();
    case_quad_short_of_the_edge_is_not_a_cover();
    case_overhanging_quad_is_a_cover();
    case_non_two_triangle_draw_is_not_a_cover();
    case_record_take_and_drop_bookkeeping();
    case_targets_are_independent();
    case_second_record_supersedes_the_first();
    case_out_of_range_target_is_inert();
    if (g_fail) { printf("mf_pending_clear: FAILURES\n"); return 1; }
    printf("mf_pending_clear: all tests passed\n");
    return 0;
}
```

- [ ] **Step 2: Add the test target**

In `Makefile.gmloader`, immediately after the `mf-seam-stat-test` target (near line 234), add:

```make
.PHONY: mf-pending-clear-test
# TDD host test for the Phase 4 Stage B deferred full-screen clear
# (mf_pending_clear.h). Like mf-seam-stat-test the header is dependency-free,
# so this needs no other translation unit and no MFGPU sources.
mf-pending-clear-test:
	c++ -std=c++17 -Igmloader/mister \
	  gmloader/mister/mf_pending_clear_test.cpp \
	  -lm -o /tmp/mfpc && /tmp/mfpc
```

- [ ] **Step 3: Run the test to verify it fails**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next && make -f Makefile.gmloader mf-pending-clear-test
```

Expected: FAIL — `fatal error: 'mf_pending_clear.h' file not found`.

- [ ] **Step 4: Write the implementation**

Create `gmloader/mister/mf_pending_clear.h`:

```c
#ifndef MF_PENDING_CLEAR_H
#define MF_PENDING_CLEAR_H
// Phase 4 Stage B — the deferred full-screen clear.
//
// The game's glClear reaches mf_clear() and is emitted as a ring BLT_OP_FILL
// over the whole 288x216 target: 62,208 pixels at ~1 px/cyc = 0.632 ms of every
// frame, and it lands in the fabric's `ovhd` term (a ring FILL dispatches
// through comp_pipeline, not through the S_TRI_* states `tri` counts).
//
// On the captured streams the opaque draws already repaint the whole screen
// (COPY covers 125,568 px over 62,208 unique), so that fill is redundant. But
// mf_clear() cannot know it: the draws have not arrived yet. So it DEFERS --
// records the fill here -- and the decision is made at the first subsequent
// draw, in mf_emit_group, which is both the single point every surviving draw
// passes and the only place the fabric blend mode is resolved.
//
// THE PROOF IS EXACT, NOT A BOUNDING BOX. Two thin slivers at opposite corners
// have a full-screen bbox and cover almost nothing. mf_pc_is_cover instead
// requires each triangle to be three DISTINCT corners of the target rect, with
// the two triangles together hitting all four: two such triangles are each
// exactly half the rect and are the two complementary halves, so their union is
// the whole rect.
//
// Any condition not provably met emits the fill. The permitted failure is a
// lost 0.632 ms, never a stale pixel.
//
// Pure by construction: no I/O, no globals, no device headers, no engine types,
// so the whole decision is unit-testable on the host.
#include <stdint.h>
#include <string.h>

#define MF_PC_TARGETS 2      /* WORK, APPSURF — mirrors MF_TARGET_* */

typedef struct {
    int      pending;
    int      w, h;
    uint16_t color;
} mf_pc_slot_t;

typedef struct {
    mf_pc_slot_t slot[MF_PC_TARGETS];
    uint32_t dropped;        /* fills proven redundant and never emitted */
    uint32_t emitted;        /* fills that were emitted after all         */
} mf_pc_t;

static inline void mf_pc_reset(mf_pc_t *p) { memset(p, 0, sizeof *p); }

static inline int mf_pc_valid_target(int target) {
    return target >= 0 && target < MF_PC_TARGETS;
}

/* Record a deferred full-extent fill. A second record with one already pending
   means two clears arrived with no draw between them: the second provably
   overwrites the first, so the first is a real saving and is counted as
   dropped rather than silently lost. */
static inline void mf_pc_record(mf_pc_t *p, int target, int w, int h, uint16_t color) {
    if (!mf_pc_valid_target(target)) return;
    mf_pc_slot_t *s = &p->slot[target];
    if (s->pending) p->dropped++;
    s->pending = 1;
    s->w = w; s->h = h; s->color = color;
}

static inline int mf_pc_pending(const mf_pc_t *p, int target) {
    if (!mf_pc_valid_target(target)) return 0;
    return p->slot[target].pending;
}

/* Take the pending fill so the caller can emit it. Returns 0 when there is
   nothing pending, so the call site needs no separate guard. */
static inline int mf_pc_take(mf_pc_t *p, int target, int *w, int *h, uint16_t *color) {
    if (!mf_pc_valid_target(target)) return 0;
    mf_pc_slot_t *s = &p->slot[target];
    if (!s->pending) return 0;
    if (w)     *w     = s->w;
    if (h)     *h     = s->h;
    if (color) *color = s->color;
    s->pending = 0;
    p->emitted++;
    return 1;
}

/* Discard the pending fill as proven redundant. Call ONLY after the covering
   draw has actually been accepted into the ring. */
static inline void mf_pc_drop(mf_pc_t *p, int target) {
    if (!mf_pc_valid_target(target)) return;
    mf_pc_slot_t *s = &p->slot[target];
    if (!s->pending) return;
    s->pending = 0;
    p->dropped++;
}

/* Which corner of the w x h rect is (x,y)? -1 if it is not a corner.
   Comparisons are >= / <= against the exact edges, never a tolerance: a quad
   that falls short must be REJECTED, and one that overhangs still covers. */
static inline int mf_pc_corner_of(float x, float y, int w, int h) {
    int left  = (x <= 0.0f);
    int right = (x >= (float)w);
    int top   = (y <= 0.0f);
    int bot   = (y >= (float)h);
    if (left && top)   return 0;
    if (right && top)  return 1;
    if (left && bot)   return 2;
    if (right && bot)  return 3;
    return -1;
}

static inline int mf_pc_popcount4(int m) {
    int n = 0;
    for (int i = 0; i < 4; i++) if (m & (1 << i)) n++;
    return n;
}

/* Does this draw provably write EVERY pixel of the w x h target?
     blend_copy : the RESOLVED fabric blend is BLT_BLEND_COPY (out = src on
                  every covered pixel — no dst read, no colorkey, no per-texel
                  alpha). Any other mode can leave a pixel untouched.
     nt         : triangle count; only a 2-triangle quad is in scope.
     xs, ys     : nt*3 screen-space vertex coordinates, in triangle order. */
static inline int mf_pc_is_cover(int blend_copy, int nt,
                                 const float *xs, const float *ys,
                                 int w, int h) {
    if (!blend_copy) return 0;
    if (nt != 2) return 0;
    if (!xs || !ys) return 0;
    int mask[2] = { 0, 0 };
    for (int t = 0; t < 2; t++) {
        for (int i = 0; i < 3; i++) {
            int c = mf_pc_corner_of(xs[t * 3 + i], ys[t * 3 + i], w, h);
            if (c < 0) return 0;              /* not a corner -> not provable */
            mask[t] |= (1 << c);
        }
        if (mf_pc_popcount4(mask[t]) != 3) return 0;   /* degenerate half */
    }
    return (mask[0] | mask[1]) == 0xF;
}

#endif /* MF_PENDING_CLEAR_H */
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next && make -f Makefile.gmloader mf-pending-clear-test
```

Expected: `mf_pending_clear: all tests passed`, exit 0.

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
git add gmloader/mister/mf_pending_clear.h gmloader/mister/mf_pending_clear_test.cpp Makefile.gmloader
git commit -m "feat(mfgpu): deferred full-screen clear module with an exact cover proof

The redundant 62,208-px ring FILL costs 0.632 ms per frame and sits in the
fabric's ovhd term. mf_clear() cannot tell whether it is redundant because the
draws have not arrived, so the fill is deferred and proven at the first draw.

The proof is corner-exact, not a bounding box: two slivers at opposite corners
have a full-screen bbox and cover almost nothing. Each triangle must be three
distinct corners of the target rect, with both triangles hitting all four.
Anything unproven emits the fill."
```

---

## Task 4: Wire the deferred clear into the backend

**Files:**
- Modify: `/Users/gmcnaught/MisterFPGA-Projects/gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp`
  - `mf_clear()` at `:1418`
  - `mf_emit_group()` at `:1743`
  - `mf_frame_begin()` at `:1385`
  - `mf_frame_end()` at `:2356`
- Test: `/Users/gmcnaught/MisterFPGA-Projects/gmloader-next/gmloader/mister/raster_backend_test.cpp` (existing host-oracle suite)

**Interfaces:**
- Consumes: everything Task 3 produced.
- Produces, for Task 5: the env knob `GMLOADER_MFGPU_DEFER_CLEAR` (default **on**; `=0` disables, which is the A/B baseline arm), and the stat line `MFCLEAR frames=%u clears_dropped=%u clears_emitted=%u`.

- [ ] **Step 1: Write the failing integration test**

Append to `gmloader/mister/raster_backend_test.cpp`, and register the new case in its `main()` alongside the existing cases (find the call list with `grep -n 'case_\|int main' gmloader/mister/raster_backend_test.cpp | tail -30`):

```cpp
// [Phase 4 Stage B] The deferred clear must be invisible in the emitted ring
// whenever the frame's first draw provably repaints the screen, and must appear
// -- in its original position, before the draw -- whenever it does not.
static void case_deferred_clear_drops_under_a_full_copy_quad(void) {
    RasterBackend_MFGPU_TestReset();
    setenv("GMLOADER_MFGPU_DEFER_CLEAR", "1", 1);
    RasterBackend_MFGPU_TestEnvReset();

    RSurface d; mf_test_make_default_surface(&d);
    backend_mfgpu.clear(&d, 0, 0, 0, 255);

    // A full-screen 2-tri quad with RB_NONE resolves to BLT_BLEND_COPY.
    BVtx q[6]; mf_test_make_full_screen_quad(q);
    backend_mfgpu.draw(&d, q, 2, mf_test_opaque_texture(), RB_NONE, 1.0f, 0x1001);
    backend_mfgpu.present(&d);

    CHECK(RasterBackend_MFGPU_TestClearsDropped()  == 1);
    CHECK(RasterBackend_MFGPU_TestClearsEmitted()  == 0);
    CHECK(RasterBackend_MFGPU_TestFillCommandCount() == 0);
}

static void case_deferred_clear_emits_under_an_alpha_draw(void) {
    RasterBackend_MFGPU_TestReset();
    setenv("GMLOADER_MFGPU_DEFER_CLEAR", "1", 1);
    RasterBackend_MFGPU_TestEnvReset();

    RSurface d; mf_test_make_default_surface(&d);
    backend_mfgpu.clear(&d, 0, 0, 0, 255);

    // A translucent full-screen quad -- the obj_fade_in / obj_fade_out case.
    // Dropping the clear here would blank the whole transition.
    BVtx q[6]; mf_test_make_full_screen_quad(q);
    for (int i = 0; i < 6; i++) q[i].a = 0.5f;
    backend_mfgpu.draw(&d, q, 2, mf_test_opaque_texture(), RB_ALPHA, 1.0f, 0x1002);
    backend_mfgpu.present(&d);

    CHECK(RasterBackend_MFGPU_TestClearsDropped()  == 0);
    CHECK(RasterBackend_MFGPU_TestClearsEmitted()  == 1);
    CHECK(RasterBackend_MFGPU_TestFillCommandCount() == 1);
    CHECK(RasterBackend_MFGPU_TestFirstCommandIsFill() == 1);   // ring order preserved
}

static void case_deferred_clear_emits_when_no_draw_follows(void) {
    RasterBackend_MFGPU_TestReset();
    setenv("GMLOADER_MFGPU_DEFER_CLEAR", "1", 1);
    RasterBackend_MFGPU_TestEnvReset();

    RSurface d; mf_test_make_default_surface(&d);
    backend_mfgpu.clear(&d, 0, 0, 0, 255);
    backend_mfgpu.present(&d);           // frame ends with the fill undecided

    CHECK(RasterBackend_MFGPU_TestClearsEmitted() == 1);
    CHECK(RasterBackend_MFGPU_TestFillCommandCount() == 1);
}

static void case_deferred_clear_off_is_the_old_behaviour(void) {
    RasterBackend_MFGPU_TestReset();
    setenv("GMLOADER_MFGPU_DEFER_CLEAR", "0", 1);
    RasterBackend_MFGPU_TestEnvReset();

    RSurface d; mf_test_make_default_surface(&d);
    backend_mfgpu.clear(&d, 0, 0, 0, 255);
    BVtx q[6]; mf_test_make_full_screen_quad(q);
    backend_mfgpu.draw(&d, q, 2, mf_test_opaque_texture(), RB_NONE, 1.0f, 0x1003);
    backend_mfgpu.present(&d);

    CHECK(RasterBackend_MFGPU_TestClearsDropped()   == 0);
    CHECK(RasterBackend_MFGPU_TestFillCommandCount() == 1);
}
```

If the helpers `mf_test_make_default_surface`, `mf_test_make_full_screen_quad`, `mf_test_opaque_texture`, `RasterBackend_MFGPU_TestFillCommandCount`, `RasterBackend_MFGPU_TestFirstCommandIsFill` or `RasterBackend_MFGPU_TestEnvReset` do not already exist in the suite, add them in this step alongside the existing `Test*` hooks (`grep -n 'RasterBackend_MFGPU_Test' gmloader/mister/raster_backend_mfgpu.cpp` shows the established hook style — `RasterBackend_MFGPU_TestTraceReset` is the model). `TestFillCommandCount` counts `BLT_OP_FILL` entries in `g_e`'s command list; `TestFirstCommandIsFill` checks the first entry's opcode.

- [ ] **Step 2: Run the test to verify it fails**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next && make -f Makefile.gmloader raster-backend-test
```

Expected: FAIL — the new hooks are undeclared, or `clears_dropped` is 0 where 1 is expected.

- [ ] **Step 3: Add the module state and the env knob**

In `raster_backend_mfgpu.cpp`, include the header next to the other `mf_*` includes and add the state beside `g_cur_target` (near `:375`):

```cpp
#include "mf_pending_clear.h"

// [Phase 4 Stage B] Deferred full-screen clear. See mf_pending_clear.h for why
// the decision cannot be made in mf_clear().
static mf_pc_t g_pc;
static int mf_defer_clear_on(void) {
    static int v = -1;
    if (v < 0) {
        const char *e = getenv("GMLOADER_MFGPU_DEFER_CLEAR");
        v = (e && *e) ? atoi(e) : 1;   // on by default: this is the lever
    }
    return v;
}
```

- [ ] **Step 4: Defer in `mf_clear()`**

Replace the body of `mf_clear()` (`:1418`) with:

```cpp
static void mf_clear(RSurface *d, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    mf_ensure_frame();
    if (g_frame_dropped) return;   // [in-flight-batch guard] emit nothing this frame
    g_last_draw.valid = false;     // [duplicate-draw elimination] a clear breaks the run
    mf_select_target(d->fbo);
    (void)a;   // fabric FILL writes opaque RGB565; no alpha channel on the wire
    int w = d->w < BLT_FB_WIDTH  ? d->w : BLT_FB_WIDTH;
    int h = d->h < BLT_FB_HEIGHT ? d->h : BLT_FB_HEIGHT;
    uint16_t col = mf_rgb565(r, g, b);
    // [Phase 4 Stage B] Only a FULL-EXTENT clear is deferrable. A partial clear
    // is not the redundant full-screen fill this lever targets, and deferring it
    // would introduce a superseding rule (partial-then-full vs full-then-partial)
    // that buys nothing.
    if (mf_defer_clear_on() && w == BLT_FB_WIDTH && h == BLT_FB_HEIGHT) {
        mf_pc_record(&g_pc, g_cur_target, w, h, col);
        return;
    }
    blt_fill(&g_e, 0, 0, w, h, col);
}
```

- [ ] **Step 5: Decide in `mf_emit_group()`**

In `mf_emit_group()`, insert this block **immediately before** the `if (blt_trilist(...) != 0)` call — after `blend_mode` and `colorkey` are resolved, so the opaque-ALPHA→COPY promotion is already applied:

```cpp
    // [Phase 4 Stage B] Discharge or drop the deferred full-screen clear. This
    // is the only point where BOTH facts are known: that the draw survived every
    // silent-discard path in mf_draw, and what fabric blend it actually resolved
    // to. A COPY over the whole target writes every pixel, so the clear beneath
    // it cannot be observed.
    const int pc_target  = g_cur_target;
    const int pc_pending = mf_pc_pending(&g_pc, pc_target);
    int pc_covers = 0;
    if (pc_pending) {
        if (nt == 2) {
            float cxs[6], cys[6];
            for (int i = 0; i < 6; i++) { cxs[i] = verts[i].x; cys[i] = verts[i].y; }
            pc_covers = mf_pc_is_cover(blend_mode == BLT_BLEND_COPY, nt,
                                       cxs, cys, BLT_FB_WIDTH, BLT_FB_HEIGHT);
        }
        if (!pc_covers) {
            // Not provably covered: emit the fill FIRST, in the ring position it
            // would have occupied had it never been deferred.
            int fw, fh; uint16_t fc;
            if (mf_pc_take(&g_pc, pc_target, &fw, &fh, &fc))
                blt_fill(&g_e, 0, 0, fw, fh, fc);
        }
    }
```

Then, **after** the `blt_trilist` success path (immediately before the `if (mf_trace_on() ...)` line), add:

```cpp
    // Drop only once the covering draw is actually in the ring: a failed
    // blt_trilist must leave the clear pending for a later draw or for frame end.
    if (pc_pending && pc_covers) mf_pc_drop(&g_pc, pc_target);
```

- [ ] **Step 6: Reset per frame and flush at frame end**

In `mf_frame_begin()` (`:1385`), immediately after the `blt_begin_frame(...)` call, add:

```cpp
    // [Phase 4 Stage B] A deferred fill must never span frames — the ring it
    // would have gone into has just been rewound.
    mf_pc_reset(&g_pc);
```

In `mf_frame_end()` (`:2356`), immediately after the `if (g_frame_dropped) return;` guard, add:

```cpp
    // [Phase 4 Stage B] A frame that cleared and never drew still has to clear.
    // Re-select the target explicitly: g_cur_target may have moved since the
    // clear was recorded, and the fill must land on the buffer it was meant for.
    for (int t = 0; t < MF_PC_TARGETS; t++) {
        int fw, fh; uint16_t fc;
        if (mf_pc_take(&g_pc, t, &fw, &fh, &fc)) {
            if (t != g_cur_target) { blt_set_target(&g_e, t); g_cur_target = t; }
            blt_fill(&g_e, 0, 0, fw, fh, fc);
        }
    }
```

- [ ] **Step 7: Add the witness counters to the stat line**

In `mf_frame_end()`, extend the existing periodic `MFDUP` report (inside `#ifdef MISTER_NATIVE_VIDEO`, `if (mf_stat_on())`, every 300 frames) with a second line:

```cpp
            fprintf(stderr, "MFCLEAR frames=%u clears_dropped=%u clears_emitted=%u defer=%d\n",
                    nf, g_pc_dropped_total, g_pc_emitted_total, mf_defer_clear_on());
```

`g_pc` is reset every frame, so accumulate run totals. Add beside `g_pc`:

```cpp
static uint32_t g_pc_dropped_total = 0, g_pc_emitted_total = 0;
```

and fold the per-frame counts into them at the top of `mf_frame_begin()`, **before** `mf_pc_reset(&g_pc)`:

```cpp
    g_pc_dropped_total += g_pc.dropped;
    g_pc_emitted_total += g_pc.emitted;
```

Expose both through test hooks next to the other `RasterBackend_MFGPU_Test*` functions:

```cpp
uint32_t RasterBackend_MFGPU_TestClearsDropped(void) { return g_pc_dropped_total + g_pc.dropped; }
uint32_t RasterBackend_MFGPU_TestClearsEmitted(void) { return g_pc_emitted_total + g_pc.emitted; }
```

- [ ] **Step 8: Run the tests to verify they pass**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
make -f Makefile.gmloader mf-pending-clear-test
make -f Makefile.gmloader raster-backend-test
make -f Makefile.gmloader mf-cov-clip-test
make -f Makefile.gmloader blitter-appsurf-test
make -f Makefile.gmloader mf-seam-stat-test
```

Expected: all five exit 0. `blitter-appsurf-test` is in this list deliberately — it drives the real app-surface path where a wrongly-dropped clear would show up.

- [ ] **Step 9: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_test.cpp
git commit -m "feat(mfgpu): defer the full-screen clear and drop it under a proven cover

mf_clear() records the full-extent fill instead of emitting it; mf_emit_group
decides, because it is the single point every surviving draw passes and the only
place the fabric blend mode is resolved (including the opaque-ALPHA -> COPY
promotion). A non-cover emits the fill first, preserving ring order; a cover
drops it only after blt_trilist has accepted the draw.

Frame begin resets the slots so a fill never spans frames; frame end flushes any
still-pending fill and re-selects its target first. GMLOADER_MFGPU_DEFER_CLEAR=0
restores the old behaviour for the device A/B."
```

---

## Task 5: Build for ARM and measure the W2 lever on `.62`

**Files:**
- Uses: `.github/scripts/build_mister_arm.sh`, `scripts/mister_run.sh`, `Makefile`

**Interfaces:**
- Consumes: Task 2's baseline table; Task 4's `GMLOADER_MFGPU_DEFER_CLEAR` knob and `MFCLEAR` line.
- Produces: the post-W2 device anchor used by Task 7's calibration and Task 8's findings.

- [ ] **Step 1: Cross-build the ARM binary**

There is no local cross-toolchain; build in Docker.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
docker run --privileged --rm tonistiigi/binfmt --install arm
git submodule update --init --recursive
docker run --rm --platform linux/arm/v7 -v "$PWD":/src -w /src \
  arm32v7/debian:bullseye-slim bash .github/scripts/build_mister_arm.sh
ls -la games/gmloader/gmloader && md5 -q games/gmloader/gmloader
```

Expected: the binary exists; record its md5 — the device check in Step 3 verifies against this value rather than assuming the copy landed.

- [ ] **Step 2: Deploy the engine to `.62`**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
scp games/gmloader/gmloader root@192.168.20.62:/media/fat/games/gmloader/gmloader.new
ssh root@192.168.20.62 'cd /media/fat/games/gmloader && mv -f gmloader.new gmloader && md5sum gmloader'
ssh root@192.168.20.62 'killall -9 gmloader'
```

Expected: the device md5 matches Step 1's. **Do not hand-launch the engine** — the handler re-execs it.

- [ ] **Step 3: A/B on the corpus, deferred clear OFF then ON**

For each of the four scenes, run the baseline arm and the lever arm:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
for arm in 0 1; do
  for s in ingame-stage1 ingame-stage1-busy; do
    MISTER_HOST=root@192.168.20.62 ./scripts/mister_run.sh bench \
      --secs 90 --scene "$s" \
      --env GMLOADER_MFSUBMIT_STAT=1 --env GMLOADER_FCAP_STAT=1 \
      --env "GMLOADER_MFGPU_DEFER_CLEAR=$arm" --preset fabric
  done
done
```

Repeat for the heavy-A and heavy-B scene scripts once Task 2 has established them.

- [ ] **Step 4: Verify the lever actually engaged**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/bench-results
grep -h 'MFCLEAR' <lever-arm>.log | tail -3
```

Expected: `clears_dropped` climbing and `defer=1` on the lever arm; `clears_dropped=0 defer=0` on the baseline arm. **A lever arm with `clears_dropped=0` means the cover proof never fired — investigate before reporting any delta**, because the two arms would then be measuring the same thing.

- [ ] **Step 5: Check the integrity gates and the delta**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/bench-results
for f in *DEFER_CLEAR*.log; do
  echo "$f: suspect=$(grep -c 'suspect=[^0]' "$f") incomplete=$(grep -c 'incomplete=[^0]' "$f") wedge=$(grep -c 'submit timeout' "$f") starved=$(grep -c 'starved=[^0]' "$f")"
  grep -h 'MFSUBMIT' "$f" | tail -5
done
```

Expected on every file: `0 0 0 0`. Expected delta between arms on each scene: `frame` and `ovhd` each **down ~0.63 ms**, `tri`/`dpath`/`texwait`/`cov_px` unchanged (the clear was never in `tri`).

If `ovhd` moves and `frame` does not, or the delta is far from 0.63, stop and diagnose — do not report a number that the decomposition does not support.

- [ ] **Step 6: Confirm no visual regression**

Using the mechanism established in Task 2 Step 5, confirm all four scenes render identically between the two arms — in particular any `obj_fade_in` / `obj_fade_out` transition, which is the case a wrongly-dropped clear would blank. Record what was checked and how.

- [ ] **Step 7: Commit the results**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
cp bench-results/*DEFER_CLEAR*.log docs/superpowers/findings/data/2026-07-30-phase4-stage-b/
git add docs/superpowers/findings/data/2026-07-30-phase4-stage-b
git commit -m "data(phase4-b): W2 device A/B on .62, deferred clear off vs on"
```

---

## Task 6: Heavy-scene sim vectors

Turns Task 2's heavy-B trace into committed sim vectors so the stream bench can be run against the gate anchor. Per spec R5 this uses the **post-W2** capture, so the bench and the device are compared on the same draw stream.

**Files:**
- Create: `/Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/docs/superpowers/findings/data/mftrace-heavy.txt`
- Modify: `/Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim/gen_tri_golden.mk`
- Create: `/Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim/vectors/stream_heavy_f0_ddr.hex`, `_exp.hex`
- Modify: `/Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim/tb_blitter_trilist_stream.sv` (header comment, near line 131)

**Interfaces:**
- Consumes: Task 5's post-W2 heavy-B `mftrace` capture.
- Produces: the `stream_heavy_f0` vector tag, replayed via `-DSTREAM_VEC='"stream_heavy_f0"'`.

- [ ] **Step 1: Place the trace where the generator expects it**

`gen_tri_golden.mk` sets `TRACEDIR := ../../../mister-gmloader/docs/superpowers/findings/data`, a sibling working checkout rather than a recorded pin.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
cp docs/superpowers/findings/data/2026-07-30-phase4-stage-b/<heavy-b-trace>.txt \
   docs/superpowers/findings/data/mftrace-heavy.txt
./scripts/mftrace_analyze.py docs/superpowers/findings/data/mftrace-heavy.txt --expect-covered 213358 --tol 2.0
```

Expected: exit 0 — the trace is the gate anchor, confirmed numerically before it becomes a vector.

- [ ] **Step 2: Add the generator target**

In `fpga/sim/gen_tri_golden.mk`, after the existing `stream-vectors` target (near line 117), add:

```make
# [Phase 4 Stage B] The heavy scene is the gate anchor (cov_px ~213,358, device
# frame 18.02 ms pre-W2). Committed like stream_quiet_f0 because run_sims.sh
# gates on it; regenerate with this target if the capture is ever re-taken.
stream-vectors-heavy: gen_tri_stream
	mkdir -p vectors
	./gen_tri_stream $(TRACEDIR)/mftrace-heavy.txt 0 stream_heavy_f0
```

Add `stream-vectors-heavy` to the `.PHONY` line at line 40.

- [ ] **Step 3: Generate the vectors**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
make -f gen_tri_golden.mk stream-vectors-heavy
ls -la vectors/stream_heavy_f0_ddr.hex vectors/stream_heavy_f0_exp.hex
```

Expected: both files exist and are non-empty.

- [ ] **Step 4: Run the bit-exact gate against unmodified RTL**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
./run_sims.sh tb_blitter_trilist_stream 2>&1 | tail -20
```

Then the same testbench against the new vectors:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
STREAM_VEC_DEFINE='-DSTREAM_VEC="stream_heavy_f0"' ./run_sims.sh tb_blitter_trilist_stream 2>&1 | tail -20
```

If `run_sims.sh` has no pass-through for extra defines, add one in this step — the testbench header at line 131 already documents replaying alternate vectors with `-DSTREAM_VEC`, so the capability is intended.

Expected: `exact_bad == 0` on both the default `stream_quiet_f0` and the new `stream_heavy_f0`.

- [ ] **Step 5: Document the new tag**

In `tb_blitter_trilist_stream.sv`'s header (near line 131) and `tb_blitter_trilist_streamcache.sv`'s (near line 168), record that `stream_heavy_f0` exists, what scene it is (cov_px ≈ 213,358), and that it is the Phase 4 Stage B gate anchor.

- [ ] **Step 6: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git add fpga/sim/gen_tri_golden.mk fpga/sim/vectors/stream_heavy_f0_ddr.hex \
        fpga/sim/vectors/stream_heavy_f0_exp.hex \
        fpga/sim/tb_blitter_trilist_stream.sv fpga/sim/tb_blitter_trilist_streamcache.sv
git commit -m "test(sim): commit the Phase 4 Stage B heavy-scene stream vectors

stream_heavy_f0 replays the gate-anchor scene (cov_px ~213,358). Bit-exact
against the refmodel on unmodified RTL. The quiet vector alone could not anchor
Stage B: it sits at 16.20 ms where the gate scene is 18.02."

cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git add docs/superpowers/findings/data/mftrace-heavy.txt
git commit -m "data(phase4-b): heavy-scene MFTRACE capture (gen_tri_stream input)"
```

---

## Task 7: The calibration gate — does the bench predict the device?

**This is the decision gate for W3.** Spec §4.4: the real-cache stream bench must reproduce the measured device anchor to within the ±0.7 % it achieved in Phase 3 (where it called device fabric to +0.31 % and texwait to +1.1 %). If it misses, W3 is not funded.

**Files:**
- Uses: `fpga/sim/run_sims.sh --tier=nightly`, `tb_blitter_trilist_streamcache`

**Interfaces:**
- Consumes: Task 6's `stream_heavy_f0` vectors; Task 5's post-W2 device anchor.
- Produces: a funded/defunded verdict for W3, recorded in Task 8's findings.

- [ ] **Step 1: Run the real-cache bench on the heavy vectors**

`tb_blitter_trilist_streamcache` is NONGATING and NIGHTLY_ONLY with a 3600 s budget — it is ~10× the stub bench. Expect a long run.

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/fpga/sim
./run_sims.sh --tier=nightly tb_blitter_trilist_streamcache 2>&1 | tee /tmp/streamcache-heavy.log | tail -40
```

- [ ] **Step 2: Extract the predicted fabric time**

```bash
grep -E 'frame|cyc|texwait|CYCX' /tmp/streamcache-heavy.log | tail -20
```

Convert the reported cycle count to milliseconds at **98.4375 MHz** (`ms = cycles / 98437.5`).

- [ ] **Step 3: Apply the gate**

Compare against the post-W2 device `frame` for the same scene from Task 5 Step 5.

```
error_pct = 100 * (predicted_ms - device_ms) / device_ms
```

- **|error_pct| ≤ 0.7 → W3 IS FUNDED.** Record the number and proceed to Step 4.
- **|error_pct| > 0.7 → W3 IS NOT FUNDED.** Do not open a Quartus cycle. Record the miss, and record what the discrepancy points at (a bench that under-models texel latency behaves differently from one that under-models `ovhd` — the `texwait` and `ovhd` columns separate them). The fallback per spec R2 is W2 alone plus a small counters-only bitstream, planned separately.

**Do not widen the tolerance to make the gate pass.** The tolerance is what Phase 3 actually achieved with no fitted constants; loosening it discards the only reason to trust a Candidate A prediction.

- [ ] **Step 4: Record the verdict**

Write the predicted value, the device value, the error percentage, and the funded/defunded verdict into the findings document (Task 8). This is the single sentence the W3 plan will be written against.

- [ ] **Step 5: Commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
cp /tmp/streamcache-heavy.log docs/superpowers/findings/data/2026-07-30-phase4-stage-b/
git add docs/superpowers/findings/data/2026-07-30-phase4-stage-b
git commit -m "data(phase4-b): stream-bench calibration run against the heavy anchor"
```

---

## Task 8: Findings document, PRs, and the pin bump

**Files:**
- Create: `/Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/docs/superpowers/findings/2026-07-30-phase4-stage-b-w1-w2.md`
- Modify: `/Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/docs/superpowers/HANDOFF-2026-07-30.md`
- Modify: `/Users/gmcnaught/MisterFPGA-Projects/mister-gmloader/external/gmloader-next` (submodule pin)

- [ ] **Step 1: Write the findings document**

Follow the Stage A seam document's discipline exactly — **Observed / Inferred / Unknown / Action**, with a data-trust section. It must contain:

1. **Headline:** the W2 delta on each corpus scene, and the W3 funded/defunded verdict.
2. **The §0 correction, confirmed or refuted on device.** The spec asserts the clear is a ring `BLT_OP_FILL`, not the RTL control-block path, and that its ~0.632 ms sits inside `ovhd`. Task 5's measurement either confirms this (`ovhd` falls by ~0.63 with `tri` unchanged) or refutes it. Say which.
3. **The scene-corpus root cause** from Task 2 Step 2: whether `ingame-stage1-busy.joy` genuinely produced one workload, or whether the Stage A collapse was two captures of the same scene.
4. **The baseline and post-W2 tables** for all four scenes.
5. **Scene identity evidence:** the `mftrace_analyze.py` gate results, and precisely what visual confirmation was and was not performed.
6. **Data-trust caveats,** stated as plainly as Stage A §9 did.
7. **The remaining distance to the gate:** post-W2 heavy-B `frame` against 16.13 ms.

- [ ] **Step 2: Update the handoff**

Add a section to `HANDOFF-2026-07-30.md` pointing at the new findings, and mark the Stage A seam document's §8 claim about `blitter_top.sv:1322-1353` as superseded by the §0 correction — the same way the handoff's existing "⚠️ SUPERSEDED BY MEASUREMENT" section handles the Phase 4 coupling framing. A future session must not re-derive this.

- [ ] **Step 3: Open the engine PR**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
git push -u origin HEAD
gh pr create --title "perf(mfgpu): eliminate the redundant full-screen clear" --body "$(cat <<'EOF'
Phase 4 Stage B, W2. Engine-only — no bitstream change.

The game's glClear reaches mf_clear() and is emitted as a ring BLT_OP_FILL over
the whole 288x216 target: 62,208 px at ~1 px/cyc = 0.632 ms of every frame,
landing in the fabric's `ovhd` term. On the captured streams the opaque draws
already repaint the whole screen, so it is redundant.

mf_clear() cannot know that — the draws have not arrived — so it defers, and
mf_emit_group decides. That is the single point every surviving draw passes and
the only place the fabric blend mode is resolved (including the opaque-ALPHA ->
COPY promotion).

The cover proof is corner-exact, not a bounding box: two slivers at opposite
corners have a full-screen bbox and cover almost nothing. Any unproven condition
emits the fill — the permitted failure is a lost 0.632 ms, never a stale pixel.

Device-measured on .62 across the 4-scene corpus. GMLOADER_MFGPU_DEFER_CLEAR=0
restores the old behaviour.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01MukLwFMCfEUpLg4JMSBdoj
EOF
)"
```

Wait for CI. If `build-mister-arm` fails, check for the known **transient apt fetch** signature (`Connection reset by peer` pulling `libtiff5`) before assuming a code break.

- [ ] **Step 4: Open the sim-vector PR**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git push -u origin HEAD
gh pr create --title "test(sim): Phase 4 Stage B heavy-scene stream vectors" --body "$(cat <<'EOF'
Adds stream_heavy_f0, the Phase 4 Stage B gate-anchor scene (cov_px ~213,358,
device frame 18.02 ms pre-W2), plus the generator target that produces it.
Bit-exact against the refmodel on unmodified RTL — no RTL change in this PR.

The quiet vector alone could not anchor Stage B: it sits at 16.20 ms where the
gate scene is 18.02.

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01MukLwFMCfEUpLg4JMSBdoj
EOF
)"
```

- [ ] **Step 5: Bump the submodule pin once the engine PR merges**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git -C external/gmloader-next fetch origin && git -C external/gmloader-next checkout origin/master
git add external/gmloader-next
git commit -m "chore: bump gmloader-next pin to Phase 4 Stage B W2 (deferred clear)"
```

- [ ] **Step 6: Commit the docs**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git add docs/superpowers/findings/2026-07-30-phase4-stage-b-w1-w2.md docs/superpowers/HANDOFF-2026-07-30.md
git commit -m "docs(findings): Phase 4 Stage B W1+W2 — corpus, CLEAR elimination, W3 verdict"
```

---

## Self-Review

**Spec coverage.** §0 correction → verified on device in Task 5 Step 5 and reported in Task 8 Step 1 item 2. §1 gate → Global Constraints; the remaining distance is reported in Task 8 Step 1 item 7. §4.1 provenance → Task 1 and Task 2 Step 2. §4.2 corpus → Task 2. §4.3 vectors → Task 6. §4.4 calibration gate → Task 7. §4.5 defer-don't-predict → Tasks 3 and 4, with every named composition constraint (`mf_select_target` per target, `g_frame_dropped`, `g_last_draw`, `g_appsurf_presented` / fade transitions) covered by a specific test or step. §4.6 witness counters → Task 4 Step 7. §4.7 device A/B → Task 5. §5 instruments → Task 2 Step 6 and Task 5 Step 5. §6 done → Task 8. §7 R2/R3/R4/R5 → Task 7 Step 3, Task 3's proof plus Task 5 Step 6, the harness's existing wedge gate, and Task 6's use of the post-W2 capture. §4.8–§4.11 (W3) → deliberately out of this plan, per the Scope section.

**Two gaps found and closed while reviewing.** The spec asks for screenshot confirmation, but the repo has no screenshot tooling — Task 2 Step 5 now makes the mechanism a device probe and forbids claiming confirmation that was not performed, with `mftrace_analyze.py` as the primary numeric gate. And `mf_pc_is_cover`'s first draft took a bounding box, which two corner slivers defeat; the predicate is corner-exact and `case_two_slivers_with_full_bbox_are_not_a_cover` pins it.

**Type consistency.** `mf_pc_t`, `mf_pc_reset`, `mf_pc_record`, `mf_pc_pending`, `mf_pc_take`, `mf_pc_drop`, `mf_pc_is_cover` and `MF_PC_TARGETS` are used with identical signatures in Task 3's header, Task 3's test, and Task 4's wiring. `g_pc`, `g_pc_dropped_total`, `g_pc_emitted_total`, `mf_defer_clear_on()` and `GMLOADER_MFGPU_DEFER_CLEAR` are consistent across Tasks 4 and 5. `sp_digest` / `sp_block` / `sp_label_suffix` match between Task 1's test and implementation.

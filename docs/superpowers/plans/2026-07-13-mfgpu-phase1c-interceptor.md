# MFGPU Phase 1c — GM Draw Interceptor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Intercept Maldita Castilla's GLES2 2D draws inside gmloader-next, assemble them into `mfgpu_batch_t`, and emit `BLT_OP_TRILIST` display lists — proven correct against the software-GL frame via a `blt_execute` software oracle, with **no new hardware required**.

**Architecture:** gmloader-next already provides the runner's GLES2 layer (its ELF loader binds `libyoyo.so`'s GLES imports to a symbol table of glad pointers → Mesa softpipe). We retarget the draw entries in that table to our own wrappers (the proven `glShaderSource_dump` override pattern), track the GL state needed to reconstruct each batch, and feed `libmfgpu` (vendored from `mister-fpga-blitter`). A validation mode runs the emitted display list through the golden `blt_execute` and diffs it against `glReadPixels` of the software-GL frame. The FPGA back-end (Phase 1d) consumes the same display list later; this phase is entirely software-verifiable.

**Tech Stack:** C++17 (gmloader-next), C11 (`libmfgpu`/`host`/`refmodel`), armhf (`arm-linux-gnueabihf`) glibc, Mesa softpipe / gl4es, MiSTer (DE10-Nano) at `192.168.20.81`.

## Global Constraints

- **Work in the `gmloader-next` checkout** (`external/gmloader-next` submodule of `mister-gmloader`, remote `git@github.com:gmcnaught/gmloader-next.git`). Commit there; bump the `mister-gmloader` submodule pointer at the end.
- **Target ABI:** armhf / 32-bit / glibc. **Source of truth is the `mister-sdl-buffer-output` branch** of gmloader-next (= `master` + the MiSTer-integration commits + the crash fix), NOT bare `master`. Build in the canonical `gmloader-armhf-build:bullseye` docker image (native arm64 host; the cross-toolchain targets armhf). **Validated build command** (produces the working 10.4 MB binary):
  ```sh
  docker run --rm -v "$PWD":/src -w /src gmloader-armhf-build:bullseye \
    make -f Makefile.gmloader ARCH=arm-linux-gnueabihf MISTER_BUILD=1 \
      LLVM_FILE=/usr/lib/llvm-11/lib/libclang-11.so \
      LLVM_INC=/usr/arm-linux-gnueabihf/include/c++/10/arm-linux-gnueabihf -j"$(nproc)"
  ```
  Output: `build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf`. Requires the untracked build input `3rdparty/gles2-sw/libGLES_sw.so` to be present (reconciling epic's untracked build inputs into the tree is part of the port). Host-only unit tests (Tasks 2–4) compile with native `cc`/`c++` — no container needed.
- **The interceptor MUST default OFF.** With `GMLOADER_MFGPU` unset, every GLES call forwards to glad exactly as today — never regress the working software path.
- **`libmfgpu`/`host`/`refmodel` are C; the interceptor is C++** — include their headers under `extern "C"`.
- **Canary facts (Phase 0 findings):** internal render surface = **288×216** (fits on-chip); **zero custom shaders** → no software-shader fallback path is needed for this canary.
- **Deploy target:** `/media/fat/games/gmloader/` on `192.168.20.81` via `scp` (key-authed SSH); the `Maldita_Castilla.sh` launcher already sets `LD_LIBRARY_PATH`.
- **Never merge to `master` without the on-device smoke passing** and the software path (`GMLOADER_MFGPU` unset) unaffected.

---

## Task 1: Fix the `GetDefaultFrameBuffer` crash (unblock deployment + real baseline)

The current deployment SIGSEGVs on startup: `libyoyo.so` calls the managed JNI method `GetDefaultFrameBuffer`, which `RunnerJNILib` doesn't register. This is the gate for everything downstream. Do it first.

**Files:**
- Modify: `gmloader/classes/RunnerJNILib.h` (declare the managed method)
- Modify: `gmloader/classes/RunnerJNILib.cpp` (implement + register)
- Modify: `../docs/superpowers/findings/2026-07-13-mfgpu-phase0-findings.md` (record the real live baseline once it boots)

**Interfaces:**
- Produces: a `RunnerJNILib::GetDefaultFrameBuffer` managed method returning the default framebuffer handle, registered under signature `()I`.

- [ ] **Step 1: Declare the method** — in `RunnerJNILib.h`, next to the other *managed* methods (the `static RET Method(JNIEnv*, jclass, ...)` group, e.g. `OsGetInfo`), add:
```cpp
static int GetDefaultFrameBuffer(JNIEnv *env, jclass clz);
```
- [ ] **Step 2: Implement it** — in `RunnerJNILib.cpp`, mirroring `OsGetInfo`'s shape:
```cpp
int RunnerJNILib::GetDefaultFrameBuffer(JNIEnv *env, jclass clz) {
    (void)env; (void)clz;
    return 0; /* the window's default framebuffer object (FBO 0) */
}
```
- [ ] **Step 3: Register it** — in the `RunnerJNILibMethods[]` table (where `OsGetInfo`/`MoveTaskToBack` are registered), add:
```cpp
REGISTER_STATIC_METHOD(RunnerJNILib, GetDefaultFrameBuffer, "()I"),
```
- [ ] **Step 4: Build armhf** — Run: `make -f Makefile.gmloader ARCH=arm-linux-gnueabihf`. Expected: clean build, produces the armhf `gmloader` binary.
- [ ] **Step 5: Deploy** — `scp` the new binary to `root@192.168.20.81:/media/fat/games/gmloader/gmloader`.
- [ ] **Step 6: Verify it boots past the crash** — Run on device: `cd /media/fat/games/gmloader && export LD_LIBRARY_PATH="$PWD/mesa:$PWD" && GMLOADER_FPS=1 timeout 40 ./gmloader -c gmloader.json > /tmp/gml.log 2>&1; grep -c "does not have static method GetDefaultFrameBuffer" /tmp/gml.log`. Expected: `0` (no missing-method error), the log shows sustained frames (not just 2), no SIGSEGV.
- [ ] **Step 7: Capture the real softpipe baseline** — Run with `GMLOADER_BLITTER=0 GMLOADER_FPS=1` for ~40 s into the auto-attract gameplay loop; read the fps. Record it under `## A1 Baseline` in the findings doc, replacing the cited ~1 fps figure with the live number + the exact command.
- [ ] **Step 8: Commit**
```bash
git add gmloader/classes/RunnerJNILib.h gmloader/classes/RunnerJNILib.cpp
git commit -m "fix: register RunnerJNILib.GetDefaultFrameBuffer (unblocks GMS runner startup)"
```

---

## Task 2: Vendor `libmfgpu` into gmloader-next + wire the build

**Files:**
- Add submodule: `3rdparty/mfgpu` → `git@github.com:gmcnaught/mister-fpga-blitter.git`
- Modify: `Makefile.gmloader` (compile + link the mfgpu C sources; add include dirs)
- Create: `tests/mfgpu_link_smoke.c` (host compile/link smoke)

**Interfaces:**
- Consumes: `mfgpu_create/frame_begin/submit_batch/frame_end/destroy`, `blt_emitter_init`, `blt_execute` (from the vendored tree).
- Produces: the gmloader binary links the mfgpu object set; an `extern "C"` include surface for the C++ interceptor.

- [ ] **Step 1: Add the submodule** — Run:
```bash
git submodule add git@github.com:gmcnaught/mister-fpga-blitter.git 3rdparty/mfgpu
git -C 3rdparty/mfgpu checkout master
```
- [ ] **Step 2: Write the failing smoke** — `tests/mfgpu_link_smoke.c`:
```c
#include "mfgpu.h"
#include <stdio.h>
int main(void){
    static unsigned char ring[4096], heap[4096];
    blt_emitter_t e; blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    mfgpu_t *m = mfgpu_create(&e);
    if(!m){ printf("FAIL\n"); return 1; }
    mfgpu_destroy(m);
    printf("mfgpu link smoke OK\n"); return 0;
}
```
- [ ] **Step 3: Run to verify it fails** — Run: `cc -I3rdparty/mfgpu/libmfgpu -I3rdparty/mfgpu/host -I3rdparty/mfgpu/refmodel tests/mfgpu_link_smoke.c -o /tmp/lsm 2>&1`. Expected: link error (`mfgpu_create` / `blt_emitter_init` undefined — sources not yet added).
- [ ] **Step 4: Add the mfgpu sources to the build** — in `Makefile.gmloader`, add the C sources and include dirs to the gmloader link:
```
MFGPU_DIR := 3rdparty/mfgpu
MFGPU_SRC := $(MFGPU_DIR)/refmodel/blitter_ref.c $(MFGPU_DIR)/refmodel/blt_tri.c \
             $(MFGPU_DIR)/host/blt_emitter.c $(MFGPU_DIR)/host/blt_alloc.c \
             $(MFGPU_DIR)/libmfgpu/mfgpu.c $(MFGPU_DIR)/libmfgpu/mfgpu_xform.c
MFGPU_INC := -I$(MFGPU_DIR)/libmfgpu -I$(MFGPU_DIR)/host -I$(MFGPU_DIR)/refmodel
```
Append `$(MFGPU_SRC)` objects to the gmloader object list and `$(MFGPU_INC)` to `CFLAGS`/`CXXFLAGS`. (`mfgpu_xform.c` uses `lround` → ensure `-lm` is in `LDLIBS`.)
- [ ] **Step 5: Verify the smoke passes AND armhf still builds** — Run: `cc $(MFGPU_INC) tests/mfgpu_link_smoke.c $(MFGPU_SRC) -lm -o /tmp/lsm && /tmp/lsm`; then `make -f Makefile.gmloader ARCH=arm-linux-gnueabihf`. Expected: `mfgpu link smoke OK`, armhf build clean.
- [ ] **Step 6: Commit**
```bash
git add .gitmodules 3rdparty/mfgpu Makefile.gmloader tests/mfgpu_link_smoke.c
git commit -m "build: vendor mister-fpga-blitter (libmfgpu) + link into gmloader"
```

---

## Task 3: GLES state tracker

To reconstruct a batch at the draw call, we must track the GL state the runner sets up first. Wrap the relevant setters, record state, then forward to glad — registered via the same symtable override as `glShaderSource_dump`.

**Files:**
- Create: `thunks/khronos/mfgpu_intercept.cpp` (auto-compiled by the `thunks/*/*.cpp` glob), `thunks/khronos/mfgpu_intercept.h`
- Modify: `thunks/khronos/gles2.cpp` (register the wrappers into `symtable_gles2`)
- Create: `tests/mfgpu_state_test.cpp` (host unit test)

**Interfaces:**
- Produces:
  - `struct mfgpu_gl_state { ... }` — bound texture id + per-id {w,h,data}; bound array/element buffers + {data,size}; per-attrib {enabled,size,type,norm,stride,ptr,buffer}; current program + MVP uniform location + last `mat4`; blend → `uint8_t` BLT_BLEND_*; viewport w/h.
  - Wrapper fns: `mfgpu_glBindTexture`, `mfgpu_glTexImage2D`, `mfgpu_glBindBuffer`, `mfgpu_glBufferData`, `mfgpu_glBufferSubData`, `mfgpu_glVertexAttribPointer`, `mfgpu_glEnableVertexAttribArray`, `mfgpu_glUseProgram`, `mfgpu_glUniformMatrix4fv`, `mfgpu_glBlendFunc`, `mfgpu_glBlendFuncSeparate`, `mfgpu_glViewport`, `mfgpu_glActiveTexture` — each records into the singleton `mfgpu_gl_state`, then tail-calls the corresponding `glad_*`.
  - `mfgpu_gl_state &mfgpu_state();` accessor.

- [ ] **Step 1: Write the failing test** — `tests/mfgpu_state_test.cpp`: drive `mfgpu_glBindTexture(GL_TEXTURE_2D, 7)`, `mfgpu_glTexImage2D(...7 is 64x64...)`, `mfgpu_glBlendFunc(GL_ONE, GL_ONE)`, `mfgpu_glViewport(0,0,288,216)`, then assert `mfgpu_state().bound_tex==7`, its `{w,h}=={64,64}`, `blend==BLT_BLEND_ADD`, `viewport=={288,216}`. (Provide weak/no-op `glad_*` stubs in the test so the wrappers link without a real GL.)
- [ ] **Step 2: Run to verify it fails** — Run: `c++ -std=c++17 -I3rdparty/mfgpu/... tests/mfgpu_state_test.cpp thunks/khronos/mfgpu_intercept.cpp -o /tmp/mst 2>&1`. Expected: assertion/undefined failure.
- [ ] **Step 3: Implement the tracker** — write `mfgpu_intercept.{h,cpp}` with the struct + wrappers above. Map `glBlendFunc(sfactor,dfactor)` → `BLT_BLEND_*`: `(ONE,ONE)`→ADD; `(SRC_ALPHA,ONE_MINUS_SRC_ALPHA)`→CONST_ALPHA; `(DST_COLOR,ZERO)`→MULTIPLY; `(ONE,ZERO)` / no blend enabled → COPY. (Confirm GM's exact factors against the runner's `glBlendFunc` calls captured on-device; default unknown combos to CONST_ALPHA.)
- [ ] **Step 4: Register the wrappers in the symtable** — in `gles2.cpp`, after each relevant `PTR_RESOLVE(glX)`, override the entry exactly like the shader-dump precedent:
```cpp
symtable_gles2[symtable_gles2_index-1].func = (uintptr_t)mfgpu_glBindTexture; /* etc. per symbol */
```
Do this for the setters listed above. (Draws are added in Task 4.)
- [ ] **Step 5: Verify the test passes AND armhf builds** — Run the test; then `make -f Makefile.gmloader ARCH=arm-linux-gnueabihf`. Expected: `mfgpu_state_test OK`, clean build.
- [ ] **Step 6: Commit**
```bash
git add thunks/khronos/mfgpu_intercept.h thunks/khronos/mfgpu_intercept.cpp thunks/khronos/gles2.cpp tests/mfgpu_state_test.cpp
git commit -m "feat: MFGPU GLES state tracker (texture/buffer/attrib/uniform/blend/viewport)"
```

---

## Task 4: Draw interceptor → `mfgpu_batch_t`

**Files:**
- Modify: `thunks/khronos/mfgpu_intercept.{h,cpp}` (the draw wrappers + batch assembly)
- Modify: `thunks/khronos/gles2.cpp` (override the draw entries)
- Modify: `tests/mfgpu_state_test.cpp` (add a batch-assembly test)

**Interfaces:**
- Consumes: `mfgpu_gl_state`, `mfgpu_batch_t`, `mfgpu_submit_batch`, `mfgpu_frame_begin/end`.
- Produces: `mfgpu_glDrawArrays(GLenum,GLint,GLsizei)`, `mfgpu_glDrawElements(GLenum,GLsizei,GLenum,const void*)`; a global `mfgpu_t*` + `blt_emitter_t` initialized on first use; env gate `GMLOADER_MFGPU` (`0`/unset=off, `1`=on, `validate`=on+oracle).

- [ ] **Step 1: Write the failing test** — synthesize a GM textured quad: a VBO holding 4 interleaved verts `{float x,y; float u,v; uint32 rgba}`, `glVertexAttribPointer` for pos(0)/uv(1)/color(2) with the right stride/offsets, an MVP via `glUniformMatrix4fv`, a bound 64×64 texture, then `mfgpu_glDrawElements(GL_TRIANGLES,6,GL_UNSIGNED_SHORT,idx)`. Assert the batch handed to a captured `mfgpu_submit_batch` has `nverts==4`, `nindices==6`, `tex_w==64`, the expected `blend`, and `mvp` equal to what was set. **Note:** the exact attrib indices (which is pos/uv/color) and VBO-vs-client-array are GM-runner specifics — confirm from the Task-6 on-device capture / the A3 runner `.so` analysis and encode them here.
- [ ] **Step 2: Run to verify it fails** — build the test; expected: undefined `mfgpu_glDrawElements` / assertion fail.
- [ ] **Step 3: Implement** — the draw wrappers read `mfgpu_gl_state`: resolve the position/uv/color attribute arrays (from the bound VBO's tracked `data + offset`, honoring `stride`, or a client pointer), fill `mfgpu_in_vtx_t[]`, set `indices/nindices` (from `glDrawElements` args; NULL for `glDrawArrays`), `mvp` (tracked matrix), `tex_*` (bound texture), `blend`, `screen_w/h` (288×216 or viewport), and call `mfgpu_submit_batch`. Guard with `GMLOADER_MFGPU`: **off → just `glad_glDraw*` (unchanged)**; on → submit; on+forward when validating.
- [ ] **Step 4: Override the draw entries** — in `gles2.cpp`, point the `glDrawArrays`/`glDrawElements` symtable entries at the wrappers.
- [ ] **Step 5: Verify test passes + armhf builds** — Run the test; `make ... ARCH=arm-linux-gnueabihf`. Expected: green + clean.
- [ ] **Step 6: Commit**
```bash
git add thunks/khronos/mfgpu_intercept.h thunks/khronos/mfgpu_intercept.cpp thunks/khronos/gles2.cpp tests/mfgpu_state_test.cpp
git commit -m "feat: MFGPU draw interceptor (glDraw* -> mfgpu_batch_t -> TRILIST)"
```

---

## Task 5: Frame lifecycle + software-oracle validation

Prove the emitted display list is correct **without any FPGA**: run it through the golden `blt_execute` and diff against the software-GL frame.

**Files:**
- Modify: `thunks/khronos/mfgpu_intercept.{h,cpp}` (frame hooks + oracle)
- Modify: `thunks/khronos/egl.cpp` (call the frame-boundary hook at `eglSwapBuffers`)

**Interfaces:**
- Consumes: `mfgpu_frame_begin/end`, `blt_execute`, `glReadPixels`.
- Produces: `mfgpu_frame_boundary()` (called at swap); a `validate` path computing a per-frame match metric between `blt_execute`'s RGB565 288×216 output and the down-converted `glReadPixels` frame.

- [ ] **Step 1: Add the frame hook** — in `egl.cpp`, at `eglSwapBuffers`, call `mfgpu_frame_boundary()` (which does `mfgpu_frame_end` then `mfgpu_frame_begin` around the swap). Gate on `GMLOADER_MFGPU`.
- [ ] **Step 2: Implement the oracle (`validate` mode)** — after `mfgpu_frame_end`, run the accumulated ring through `blt_execute` into a `uint16_t fb565[288*216]`; `glReadPixels` the software-GL frame (RGBA8888), down-convert to RGB565, and compute a match metric (exact-match %, plus max per-channel delta). `printf` `MFGPU_VALIDATE frame=N match=…% maxdelta=…`. Expected differences: nearest-vs-bilinear sampling and RGB565 quantization — define a pass threshold (e.g. ≥95% pixels within ±1 per 5/6/5 channel) and note it.
- [ ] **Step 3: Build + deploy + run `validate`** — `make ... ARCH=arm-linux-gnueabihf`, scp, run Maldita with `GMLOADER_MFGPU=validate`. Expected: per-frame `MFGPU_VALIDATE` lines; match ≥ threshold on gameplay frames.
- [ ] **Step 4: Record results** — capture the match metric across a range of scenes (title, attract gameplay) into the findings doc under a new `## Phase 1c Validation` section. If systematic mismatches appear (wrong attrib mapping, blend-mode misclassification), fix in Task 3/4 and re-run.
- [ ] **Step 5: Commit**
```bash
git add thunks/khronos/mfgpu_intercept.h thunks/khronos/mfgpu_intercept.cpp thunks/khronos/egl.cpp
git commit -m "feat: MFGPU frame lifecycle + blt_execute software-oracle validation"
```

---

## Task 6: On-device bring-up + batch diagnostics

**Files:**
- Modify: `thunks/khronos/mfgpu_intercept.cpp` (diagnostic counters)
- Modify: `../docs/superpowers/findings/2026-07-13-mfgpu-phase0-findings.md` (fold in the confirmed runner vertex-attrib layout; finalize A3)

- [ ] **Step 1: Add per-frame diagnostics** — behind `GMLOADER_MFGPU`, log batches/frame, triangles/frame, culled (degenerate + off-viewport), unique textures/frame, and the observed vertex stride + attrib indices (so the A3 contract detail is captured from live data).
- [ ] **Step 2: Run Maldita with `GMLOADER_MFGPU=1`** on-device end-to-end (past the title into attract gameplay). Expected: no crash, no `escape`-to-software surprises, stable batch counts, the software path unaffected when `GMLOADER_MFGPU` is unset.
- [ ] **Step 3: Finalize A3** — record the confirmed vertex layout (attrib index → pos/uv/color, stride, VBO vs client array, glDrawArrays vs glDrawElements usage) into the findings A3 section; confirm the `mfgpu_batch_t` contract held (or note the adjustment made).
- [ ] **Step 4: Commit + bump the umbrella submodule**
```bash
git add thunks/khronos/mfgpu_intercept.cpp
git commit -m "feat: MFGPU on-device batch diagnostics; finalize A3 vertex layout"
git push -u origin <feature-branch>
# then in mister-gmloader: bump external/gmloader-next to the new tip + commit
```

---

## Phase 1d Roadmap (staged A→C) — each gets its own detailed plan

Phase 1c produces a **validated display-list stream** with no hardware. Phase 1d makes it fast on the fabric, staged to de-risk bring-up before any refactor:

**Stage A — prototype the MFGPU triangle datapath in `solarus-mister/fpga` (gated).**
- Pipeline the `blt_tri` golden (from `mister-fpga-blitter/rtl`) into a triangle-raster front-end that feeds the **existing** `comp_mixer` blend datapath + `fbram_snapshot` framebuffer + scanout; decode `BLT_OP_TRILIST` from the ring via `ddr_blitter_arb`.
- Gate behind a build/core-select so the shipping **Solarus and OpenBOR paths are untouched**.
- Mirror the `mister-fpga-blitter/sim` tri scenarios in the production sim harness; build the RBF via the existing `build-rbf` CI; bring up on hardware with a **mandatory visual analog check** (counters lie about video).
- Wire the Phase-1c A9 interceptor's DDR ring to the fabric; capture the real MFGPU fps vs the Task-1 A1 baseline.
- *Own plan because:* it needs deep exploration of `comp_pipeline`/`comp_mixer`/`ddr_blitter_arb` internals and the production sim harness.

**Stage C — extract the engine-agnostic fabric base (once Stage A is proven on hardware).**
- Factor the generic infra (`fbram_snapshot`+`fbram_scan_adapter`, `comp_mixer`, `ddr_blitter_arb`, command ring/doorbell, MiSTer scaffolding + `jtframe`/`pll`) out of `solarus-mister/fpga` into `mister-fpga-blitter` as the shared engine-agnostic base — leaving Solarus/OpenBOR-specific opcodes + SDRAM residency behind.
- Rebuild **both** the Solarus core and the MFGPU/gmloader core on the extracted base with **zero regression** (per-core sim + analog visual check).
- *Own plan because:* it's a delicate refactor of hardware-validated, analog-sensitive RTL; the extraction seam needs its own exploration, and it must not risk the shipping cores.

---

## Self-Review

**Spec coverage:** A1 crash → Task 1; interception boundary (A3) → Tasks 3–4 + finalized in Task 6; on-chip 288×216 (A2) → screen dims in Task 4/5; zero-shader (A4) → no fallback path (stated in constraints); the `mfgpu_batch_t` contract (design spec) → Tasks 3–5; software-only validation → Task 5; Phase 1d (spec) → staged A→C roadmap.

**Placeholder scan:** the one genuinely runtime-determined value — the GM vertex attrib layout (index→pos/uv/color, stride, VBO vs client) — is specified with the method to obtain it (Task 4 test note + Task 6 finalization from live capture), not left vague. Crash-fix and build tasks have complete code.

**Type consistency:** `mfgpu_batch_t`/`mfgpu_in_vtx_t`/`mfgpu_submit_batch`/`blt_emitter_init`/`blt_execute` match the shipped `libmfgpu`/`host`/`refmodel` signatures; `GMLOADER_MFGPU` gate is consistent across Tasks 4–6; blend-mode mapping targets the shipped `BLT_BLEND_*` values.

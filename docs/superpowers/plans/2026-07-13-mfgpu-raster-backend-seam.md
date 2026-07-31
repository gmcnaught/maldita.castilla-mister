# MFGPU Raster Back-End Seam Implementation Plan

> **STATUS: ✅ DONE — shipped in `gmloader-next` PR #11**
> ([gmcnaught/gmloader-next#11](https://github.com/gmcnaught/gmloader-next/pull/11),
> branch `mister-sdl-buffer-output`). All of Tasks 3–7 below are implemented and
> pushed (commits `8f2e7d5` seam → `fd0a304`/`c749413` device selection), and the
> work continued past this plan into persistent texture-atlas staging
> (`docs/superpowers/plans/2026-07-14-mfgpu-persistent-atlas-staging.md` in that
> repo). This document is retained for historical context only — do not execute
> it. Remaining open items live on the PR (review) and as follow-up issues
> (e.g. gmloader-next#12: build `libGLES_sw.so` in CI).

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Supersedes** Tasks 3–6 of `2026-07-13-mfgpu-phase1c-interceptor.md`. Tasks 1
(crash fix, commit `8d183e6`) and 2 (vendor `libmfgpu`, commit `469b0b9`) of
that plan are **done and reviewed**; this plan replaces the greenfield
`mfgpu_gl*` interceptor tasks after discovering that gmloader-next's
`mister-sdl-buffer-output` branch already ships a live, wired, host-tested
software 2D blitter (`gmloader/mister/blitter*`) that performs GLES state
shadowing and draw decode. We reuse that decode layer and insert a back-end
seam beneath it.

**Goal:** Extract a `RasterBackend` interface from `gmloader/mister/blitter.cpp`
so the existing software rasterizer and a new MFGPU FPGA-fabric rasterizer are
two interchangeable implementations behind one boundary, with the software
back-end serving as the present-space validation oracle for the fabric path.

**Architecture:** `blitter.cpp` keeps ownership of GL state shadowing and draw
decode; it already reduces each draw to GL-free, screen-space data
(`BVtx[]` + `RTexture` + `RBlend`). We route its three post-decode operations —
clear, draw(triangle-list), present — through a `RasterBackend` vtable.
`backend_sw` wraps today's `Blitter_RasterDraw`/`Blitter_ClearSurface`/
`Blitter_ToRGB565` with zero behavior change. `backend_mfgpu` converts the same
decoded data into `BLT_OP_TRILIST` fabric commands via the vendored
`libmfgpu`/`blt_emitter` and, on host, validates through the `blt_execute`
software model.

**Tech Stack:** C11 + C++17, `gmloader/mister/*`, vendored
`3rdparty/mfgpu` (`refmodel/`, `host/`, `libmfgpu/`), armhf cross-build via
`gmloader-armhf-build:bullseye` Docker image, MiSTer DE10-Nano at
`192.168.20.81`.

## Global Constraints

- **Branch:** all work on `mister-sdl-buffer-output` (base `469b0b9`). Never
  `master` — it lacks MiSTer integration and will not build.
- **Decode layer is off-limits:** do NOT change GL state shadowing
  (`Blitter_On*`), vertex/MVP decode, texture/blend resolution, or the
  `gles2.cpp` hook wiring. This plan only inserts a seam beneath the existing
  decode and adds back-ends. The `BVtx`/`RTexture`/`RBlend` produced by decode
  are the fixed input contract.
- **SW back-end is a pure refactor:** `backend_sw` must be byte-identical to
  current behavior. The existing `blitter_raster_test.cpp` is the regression
  gate and must keep passing unchanged.
- **Cross-backend validation is present-space RGB565 with ±1 LSB tolerance,
  NOT bit-exact.** The fabric framebuffer and `blt_execute` operate in RGB565;
  the SW surface is RGBA8888. Compare `Blitter_ToRGB565(sw_surface)` against the
  `blt_execute` RGB565 output. Per-channel difference must be ≤1 in 5/6/5 space
  (SW blends in 8-bit then truncates; the fabric blends in 565 — small rounding
  divergence is expected and acceptable). Bit-exactness lives *inside* mfgpu
  (refmodel↔RTL, already proven 17/17), not across pixel formats.
- **C ABI surface:** the `RasterBackend` header and all `libmfgpu` includes are
  `extern "C"` so the C++ decode layer and the C fabric library link cleanly.
- **Host-first:** every task has a host (`cc`/`c++` on the dev machine) test.
  The armhf link is validated per task via:
  ```
  docker run --rm -v "$PWD:/src" -w /src gmloader-armhf-build:bullseye \
    make -f Makefile.gmloader ARCH=arm-linux-gnueabihf MISTER_BUILD=1 \
    LLVM_FILE=/usr/lib/llvm-11/lib/libclang-11.so \
    LLVM_INC=/usr/arm-linux-gnueabihf/include/c++/10/arm-linux-gnueabihf \
    -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
  ```
  Artifact: `build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf`.

---

## Fixed input contract (from the existing decode layer)

Defined in `gmloader/mister/blitter_raster.h` — **do not modify**:

```c
typedef struct RSurface { uint8_t *rgba; int w, h; } RSurface;          /* RGBA8888 dest */
typedef struct RTexture {
    const uint8_t *rgba; int w, h; int nearest, valid, format, opaque;  /* format: RTEX_RGBA8888=0, RTEX_RGBA4444=1 */
} RTexture;
typedef enum RBlend { RB_NONE = 0, RB_ALPHA, RB_PREMULT, RB_ADD } RBlend;
typedef struct BVtx { float x, y, u, v, r, g, b, a; } BVtx;             /* screen px; uv in [0,1]; color in [0,1] */

void Blitter_RasterDraw(RSurface*, const BVtx*, int triCount, const RTexture*, RBlend, float alphaRef, int threads);
void Blitter_ClearSurface(RSurface*, uint8_t r, uint8_t g, uint8_t b, uint8_t a);
```

MFGPU emit contract (from `3rdparty/mfgpu/host/blt_emitter.h`,
`refmodel/blitter_ref.h` — all `extern "C"`):

```c
typedef struct { int16_t x, y; uint16_t u, v; uint32_t rgba; uint32_t _rsvd; } blt_vtx_t;  /* x/y,u/v are 12.4 fixed */
/* BLT_BLEND_COPY=0, COLORKEY=1, CONST_ALPHA=2, PALPHA=3, ADD=4, MULTIPLY=5 */
void blt_emitter_init(blt_emitter_t*, void *ring, size_t, void *heap, size_t);
void blt_vtx_buf_init(blt_emitter_t*, void *vtx_buf, size_t);
uint32_t blt_push_tris(blt_emitter_t*, const blt_vtx_t*, int ntris);            /* -> entry_off (confirm exact sig in header) */
blt_surface_ref_t blt_upload_argb4444(blt_emitter_t*, const uint16_t *pixels, int w, int h);
int  blt_stage_surface(blt_emitter_t*, blt_surface_ref_t*);
int  blt_trilist(blt_emitter_t*, blt_surface_ref_t tex, uint8_t blend,
                 uint16_t colorkey, uint8_t alpha, uint32_t entry_off, int ntris);
int  blt_execute(uint16_t *fb, /* ...ring/heap/dims; confirm exact sig in blitter_ref.h:262 */ );
```

## File structure

- Create `gmloader/mister/raster_backend.h` — the `RasterBackend` vtable, the
  op enums bridging (`RBlend`→`BLT_BLEND_*`), and `RasterBackend_Select()`.
- Create `gmloader/mister/raster_backend_sw.cpp` — `backend_sw` wrapping the
  existing rasterizer (the oracle).
- Create `gmloader/mister/raster_backend_mfgpu.cpp` — `backend_mfgpu` emitting
  `BLT_OP_TRILIST`; `draw()` falls back to `backend_sw` for FBO targets.
- Create `gmloader/mister/raster_backend_test.cpp` — host tests: sw-equivalence
  (refactor gate) + fabric-vs-oracle present-space comparison.
- Modify `gmloader/mister/blitter.cpp` — route clear/draw/present through
  `RasterBackend_Select()`.
- Modify `Makefile.gmloader` — add the three new `.cpp` to `MISTER_SRCS`; add a
  host test target.

---

## Task 3: Extract the `RasterBackend` seam + `backend_sw` (pure refactor)

**Files:**
- Create: `gmloader/mister/raster_backend.h`
- Create: `gmloader/mister/raster_backend_sw.cpp`
- Create: `gmloader/mister/raster_backend_test.cpp`
- Modify: `gmloader/mister/blitter.cpp` (route clear/draw/present through the vtable)
- Modify: `Makefile.gmloader` (`MISTER_SRCS` += the two new sources; add `raster-backend-test` host target)

**Interfaces:**
- Consumes: `RSurface`, `BVtx`, `RTexture`, `RBlend`, `Blitter_RasterDraw`,
  `Blitter_ClearSurface`, `Blitter_ToRGB565` (from `blitter_raster.h` / `blitter.cpp`).
- Produces: `RasterBackend` struct + `const RasterBackend *RasterBackend_Select(void)`;
  `backend_sw` symbol. Later tasks add `backend_mfgpu` and switch the selector.

- [ ] **Step 1: Write the failing test** — `gmloader/mister/raster_backend_test.cpp`.
  Assert that driving a small triangle list through `backend_sw->draw` yields a
  byte-identical `RSurface` to calling `Blitter_RasterDraw` directly (the refactor
  must not change a single pixel).

```c
#include "raster_backend.h"
#include "blitter_raster.h"
#include <string.h>
#include <stdlib.h>
#include <stdio.h>

static int one_case(void) {
    enum { W = 32, H = 32 };
    uint8_t a[W*H*4], b[W*H*4];
    RSurface sa = { a, W, H }, sb = { b, W, H };
    memset(a, 0, sizeof a); memset(b, 0, sizeof b);
    static const uint8_t tex[4] = { 200, 100, 50, 255 };
    RTexture t = { tex, 1, 1, /*nearest*/1, /*valid*/1, /*format RTEX_RGBA8888*/0, /*opaque*/1 };
    BVtx v[3] = {
        { 2.f, 2.f, 0.f, 0.f, 1,1,1,1 },
        { 28.f, 4.f, 1.f, 0.f, 1,1,1,1 },
        { 4.f, 28.f, 0.f, 1.f, 1,1,1,1 },
    };
    Blitter_RasterDraw(&sa, v, 1, &t, RB_NONE, 0.f, 1);          /* reference */
    RasterBackend_Select()->draw(&sb, v, 1, &t, RB_NONE, 0.f);   /* through seam */
    return memcmp(a, b, sizeof a) == 0;
}
int main(void){ if(!one_case()){ printf("FAIL sw-equivalence\n"); return 1; }
    printf("raster_backend sw-equivalence OK\n"); return 0; }
```

- [ ] **Step 2: Run to verify it fails** — Run:
  `c++ -std=c++17 -Igmloader/mister raster_backend_test.cpp -o /tmp/rbt 2>&1`.
  Expected: compile/link error — `raster_backend.h` and `RasterBackend_Select`
  do not exist yet.

- [ ] **Step 3: Create the interface header** — `gmloader/mister/raster_backend.h`:

```c
#ifndef RASTER_BACKEND_H
#define RASTER_BACKEND_H
#include "blitter_raster.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct RasterBackend {
    const char *name;
    void (*frame_begin)(void);
    void (*clear)(RSurface *dst, uint8_t r, uint8_t g, uint8_t b, uint8_t a);
    void (*draw)(RSurface *dst, const BVtx *verts, int triCount,
                 const RTexture *tex, RBlend blend, float alphaRef);
    void (*present)(const RSurface *defSurf);
    void (*frame_end)(void);
} RasterBackend;

/* Returns the active back-end. Task 3 always returns backend_sw;
 * Task 6 makes this env-selectable. */
const RasterBackend *RasterBackend_Select(void);
#ifdef __cplusplus
}
#endif
#endif
```

- [ ] **Step 4: Implement `backend_sw`** — `gmloader/mister/raster_backend_sw.cpp`.
  Thin wrappers with zero added logic; `present` calls the existing RGB565
  conversion path used by `Blitter_PresentDefault` today.

```c
#include "raster_backend.h"
/* g_threads mirrors blitter.cpp's thread count; a small fixed value is fine for
 * the wrapper — keep identical to what blitter.cpp passes today (read it there). */
static int sw_threads = 1;
void RasterBackend_SW_SetThreads(int n){ sw_threads = n; }

static void sw_frame_begin(void){}
static void sw_clear(RSurface *d, uint8_t r, uint8_t g, uint8_t b, uint8_t a){
    Blitter_ClearSurface(d, r, g, b, a);
}
static void sw_draw(RSurface *d, const BVtx *v, int n, const RTexture *t, RBlend bl, float ar){
    Blitter_RasterDraw(d, v, n, t, bl, ar, sw_threads);
}
static void sw_present(const RSurface *s){ /* call the same RGB565/native-video path
    blitter.cpp::Blitter_PresentDefault uses today — move that body here or call it. */ }
static void sw_frame_end(void){}

extern "C" const RasterBackend backend_sw = {
    "sw", sw_frame_begin, sw_clear, sw_draw, sw_present, sw_frame_end,
};
extern "C" const RasterBackend *RasterBackend_Select(void){ return &backend_sw; }
```

- [ ] **Step 5: Route `blitter.cpp` through the seam** — replace the direct calls:
  - the `Blitter_RasterDraw(&rt, &s_verts[0], count/3, &tex, blend, 0.0f, g_threads)`
    site (currently ~line 512) becomes
    `RasterBackend_Select()->draw(&rt, &s_verts[0], count/3, &tex, blend, 0.0f);`
  - `Blitter_OnClear` routes to `RasterBackend_Select()->clear(...)`.
  - `Blitter_PresentDefault` routes to `RasterBackend_Select()->present(&g_defSurf)`
    (and call `RasterBackend_SW_SetThreads(g_threads)` once at init so the SW
    back-end uses the same thread count).
  Do not alter decode, state shadowing, or the numbers passed — only the callee.

- [ ] **Step 6: Wire the build** — in `Makefile.gmloader`, append
  `gmloader/mister/raster_backend_sw.cpp` to `MISTER_SRCS`; add a host target:

```
raster-backend-test:
	c++ -std=c++17 -Igmloader/mister \
	  gmloader/mister/raster_backend_test.cpp \
	  gmloader/mister/raster_backend_sw.cpp \
	  gmloader/mister/blitter_raster.cpp -o /tmp/rbt && /tmp/rbt
```

- [ ] **Step 7: Verify** — Run `make -f Makefile.gmloader raster-backend-test`.
  Expected: `raster_backend sw-equivalence OK`. Then run the existing
  `blitter_raster_test` (unchanged) and confirm it still passes. Then the armhf
  Docker build (Global Constraints recipe) — clean link.

- [ ] **Step 8: Commit**

```bash
git add gmloader/mister/raster_backend.h gmloader/mister/raster_backend_sw.cpp \
        gmloader/mister/raster_backend_test.cpp gmloader/mister/blitter.cpp Makefile.gmloader
git commit -m "refactor(blitter): extract RasterBackend seam + backend_sw (no behavior change)"
```

---

## Task 4: `backend_mfgpu` skeleton — lifecycle, clear, present; draw falls back to SW

**Files:**
- Create: `gmloader/mister/raster_backend_mfgpu.cpp`
- Modify: `gmloader/mister/raster_backend_test.cpp` (add clear-parity case)
- Modify: `Makefile.gmloader` (`MISTER_SRCS` += mfgpu backend; test target links it + `$(MFGPU_SRC)`)

**Interfaces:**
- Consumes: `blt_emitter_init`, `blt_vtx_buf_init`, `blt_execute`,
  `RasterBackend` (Task 3); `backend_sw` for fallback.
- Produces: `backend_mfgpu` symbol with a working `clear`/`present`/lifecycle;
  `draw` delegates to `backend_sw` (real work lands in Task 5).

- [ ] **Step 1: Write the failing clear-parity test** — extend
  `raster_backend_test.cpp`: clear a 288×216 surface via `backend_mfgpu->clear`
  and, separately, via `backend_sw->clear`; convert both to RGB565 and assert
  every pixel is within ±1 LSB per channel (the tolerance is exact here since
  clear is a flat fill, but the harness uses the same comparator Task 5 needs).
  Add a reusable `rgb565_within1(const RSurface*, const uint16_t *fb565)` helper.

- [ ] **Step 2: Run to verify it fails** — Run
  `make -f Makefile.gmloader raster-backend-test`. Expected: link error —
  `backend_mfgpu` undefined.

- [ ] **Step 3: Implement the mfgpu backend skeleton** —
  `gmloader/mister/raster_backend_mfgpu.cpp`. Owns a `blt_emitter_t` over
  host-side ring/heap/vtx buffers (device wiring to the real DDR ring is Task 6).
  `clear` emits a fabric fill (or, for the host oracle, writes the clear color
  into the RGB565 target that `blt_execute` renders into — match whatever
  `blt_execute` consumes). `draw` delegates to `backend_sw->draw`. `present` is a
  no-op placeholder (fabric scanout is hardware; Task 6). Include the mfgpu
  headers via the `$(MFGPU_INC)` dirs.

```c
#include "raster_backend.h"
extern "C" {
#include "blt_emitter.h"
#include "blitter_ref.h"
}
extern "C" const RasterBackend backend_sw;   /* fallback */
/* static blt_emitter_t g_e; ring/heap/vtx buffers sized for one frame's tris.
 * blt_emitter_init(&g_e, ring, sizeof ring, heap, sizeof heap);
 * blt_vtx_buf_init(&g_e, vtx, sizeof vtx); */

static void mf_frame_begin(void){ /* reset emitter/vtx buffer for the new frame */ }
static void mf_clear(RSurface *d, uint8_t r, uint8_t g, uint8_t b, uint8_t a){
    /* emit fabric fill; on host, fill the RGB565 execute target */
}
static void mf_draw(RSurface *d, const BVtx *v, int n, const RTexture *t, RBlend bl, float ar){
    backend_sw.draw(d, v, n, t, bl, ar);     /* Task 5 replaces with fabric emit */
}
static void mf_present(const RSurface *s){ /* Task 6: device scanout */ }
static void mf_frame_end(void){ /* execute/flush the ring */ }

extern "C" const RasterBackend backend_mfgpu = {
    "mfgpu", mf_frame_begin, mf_clear, mf_draw, mf_present, mf_frame_end,
};
```

- [ ] **Step 4: Build + verify parity** — update the `raster-backend-test`
  target to also compile `raster_backend_mfgpu.cpp` and `$(MFGPU_SRC)` with
  `$(MFGPU_INC)` and `-lm`. Run it. Expected: clear-parity passes (`OK`).

- [ ] **Step 5: armhf link** — run the Docker build. Expected: clean link with
  `backend_mfgpu` + mfgpu objects.

- [ ] **Step 6: Commit**

```bash
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_test.cpp Makefile.gmloader
git commit -m "feat(blitter): backend_mfgpu skeleton (lifecycle+clear+present; draw=SW fallback)"
```

---

## Task 5: `backend_mfgpu.draw` — emit `BLT_OP_TRILIST`, validate vs SW oracle

**Files:**
- Modify: `gmloader/mister/raster_backend_mfgpu.cpp` (real `draw`)
- Create: `gmloader/mister/raster_backend_convert.h` (pure conversion helpers, host-testable)
- Modify: `gmloader/mister/raster_backend_test.cpp` (triangle battery vs oracle)

**Interfaces:**
- Consumes: `blt_push_tris`, `blt_trilist`, `blt_upload_argb4444`,
  `blt_stage_surface`, `blt_execute`; the fixed `BVtx`/`RTexture`/`RBlend` contract.
- Produces: `backend_mfgpu->draw` that emits a fabric triangle list for
  default-framebuffer targets (FBO targets still delegate to SW).

- [ ] **Step 1: Conversion helpers (failing unit test first)** —
  `raster_backend_convert.h`, pure inline functions, plus a test case:
  - `blt_vtx_t bvtx_to_blt(const BVtx*, int tex_w, int tex_h)`:
    `x = lround(v->x*16)`, `y = lround(v->y*16)` (12.4 signed);
    `u = lround(clampf(v->u,0,1) * tex_w * 16)`, `v = lround(clampf(v->v,0,1) * tex_h * 16)`
    (texel 12.4); `rgba = BLT_RGBA(lround(v->r*255), lround(v->g*255),
    lround(v->b*255), lround(v->a*255))` (match the packing in `blitter_ref.h`:
    `r | g<<8 | b<<16 | a<<24`).
  - `uint8_t rblend_to_blt(RBlend)`: `RB_NONE→BLT_BLEND_COPY`,
    `RB_ALPHA→BLT_BLEND_PALPHA`, `RB_PREMULT→BLT_BLEND_PALPHA` (premult noted as
    an approximation — see design note), `RB_ADD→BLT_BLEND_ADD`.
  Test: assert a known BVtx maps to the expected `blt_vtx_t` fields and each
  RBlend maps to the expected enum.

- [ ] **Step 2: Run to verify it fails** — Run
  `make -f Makefile.gmloader raster-backend-test`. Expected: fail (helpers/asserts new).

- [ ] **Step 3: Implement `draw`** — in `raster_backend_mfgpu.cpp`:
  1. If `dst` is not the default framebuffer (an FBO/render-target surface),
     delegate to `backend_sw.draw` and return (approved FBO fallback — decide
     the "is default fb" test with blitter.cpp; a bool passed at frame setup or a
     surface-pointer compare against `g_defSurf`).
  2. Stage the texture: convert `RTexture` (RGBA8888/RGBA4444) → ARGB4444
     `uint16_t[]`, `blt_upload_argb4444(&g_e, px, t->w, t->h)`, then
     `blt_stage_surface(&g_e, &ref)`.
  3. Convert the `triCount*3` `BVtx` → `blt_vtx_t[]` via `bvtx_to_blt`;
     `entry_off = blt_push_tris(&g_e, verts, triCount)`.
  4. `blt_trilist(&g_e, ref, rblend_to_blt(blend), /*colorkey*/0,
     /*alpha*/255, entry_off, triCount)`.

- [ ] **Step 4: Oracle test (triangle battery)** — for each case in a table
  (opaque tri, alpha tri, additive tri, multi-tri quad, non-axis-aligned tri,
  1×1 and N×M textures), render two ways into a 288×216 target:
  - **SW:** `backend_sw.draw` into an RGBA8888 `RSurface`, then `Blitter_ToRGB565`.
  - **Fabric model:** emit via `backend_mfgpu.draw`, then `blt_execute(fb565, …)`.
  Assert `rgb565_within1(sw565, fb565)` for every pixel. On mismatch, dump the
  first differing pixel (x,y, both values) to aid debugging.

- [ ] **Step 5: Verify** — Run `make -f Makefile.gmloader raster-backend-test`.
  Expected: all battery cases pass within ±1 LSB. Then the armhf Docker build —
  clean link.

- [ ] **Step 6: Commit**

```bash
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_convert.h \
        gmloader/mister/raster_backend_test.cpp
git commit -m "feat(blitter): backend_mfgpu draw emits BLT_OP_TRILIST; validated vs SW oracle (±1 LSB 565)"
```

> **Design note — RB_PREMULT:** GM's premultiplied-alpha source-over
> (`dst = src + dst*(1-a)`) has no exact MFGPU blend enum; `BLT_BLEND_PALPHA`
> (straight source-over) is used as an approximation. If a battery case with
> premult exceeds the ±1 tolerance, either (a) pre-divide alpha during texture
> staging, or (b) keep RB_PREMULT on the SW fallback for now and log it. Record
> the decision in the commit.

---

## Task 6: Colorkey texture staging for 1-bit-alpha (palette) sprites

**Files:**
- Modify: `gmloader/mister/raster_backend_mfgpu.cpp` (texel staging derives a colorkey from transparent texels; `draw` emits `BLT_BLEND_COLORKEY` for cutout textures)
- Modify: `gmloader/mister/raster_backend_test.cpp` (add a 1-bit-alpha texture battery)

**Interfaces:**
- Consumes: `blt_upload`, `blt_trilist` (`colorkey` param), `BLT_BLEND_COLORKEY`, `blt_execute`, the `RTexture` alpha channel.
- Produces: `backend_mfgpu.draw` renders hard-edged (alpha ∈ {0,255}) sprite transparency identically (±1 LSB) to the SW oracle.

**Rationale:** the golden fabric samples RGB565 with no per-texel alpha (see the
texture-alpha finding), but `blt_tri.c` HAS `BLT_BLEND_COLORKEY`
(`if(texel!=h->colorkey)*dp=src`). Maldita is a 256-color palette game with
1-bit transparency, so mapping transparent texels to a colorkey reproduces its
sprite cutouts exactly. For hard-edged textures this is pixel-identical to the
SW oracle's per-texel-alpha result, so it is host-validatable.

- [ ] **Step 1: Failing test** — in `raster_backend_test.cpp` add battery cases
  with a texture whose alpha is strictly 0 or 255: an 8×8 with a 1-texel
  transparent border, and a checkerboard-alpha 4×4. Render via `backend_sw.draw`
  (per-texel alpha → transparent texels not written) and via `backend_mfgpu.draw`,
  then `rgb565_within1`. Expected FAIL today: mfgpu drops alpha, so transparent
  texels render opaque.

- [ ] **Step 2: Run to verify it fails** — `make -f Makefile.gmloader raster-backend-test`.
  Expected: the new keyed cases mismatch (opaque where SW is transparent).

- [ ] **Step 3: Colorkey-aware staging** — in `raster_backend_mfgpu.cpp`:
  - Define `static const uint16_t MF_COLORKEY = 0xF81F;` (magenta).
  - In the texel→565 conversion: if the source texel's alpha `< 128`, output
    `MF_COLORKEY`; else convert RGB→565 and, if the opaque result equals
    `MF_COLORKEY`, nudge it (`result ^= 0x0020;` — flip one green LSB) so an
    opaque texel can never collide with the key. Track `bool has_key` = any
    texel emitted the key.

- [ ] **Step 4: Colorkey-aware draw** — when `has_key` AND every vertex alpha in
  the triangle list is ≈opaque (`min vtx.a >= 254`), emit
  `blt_trilist(&g_e, tex, BLT_BLEND_COLORKEY, /*colorkey=*/MF_COLORKEY, /*alpha=*/255, entry_off, ntris)`.
  Otherwise keep the Task 5 path (`rblend_to_blt(bl)` with `colorkey=0`).
  Document the known limitation: a *faded* cutout sprite (keyed texture with
  vtx.a<254) can't combine colorkey + const-alpha in one fabric pass — it falls
  back to CONST_ALPHA (no cutout) for now; soft/faded transparency is the future
  per-texel-alpha RTL item, out of scope here.

- [ ] **Step 5: Verify** — `make -f Makefile.gmloader raster-backend-test`.
  Expected: all cases pass ±1 LSB, including the 1-bit-alpha keyed cases. Then
  the armhf Docker build — clean link.

- [ ] **Step 6: Commit**

```bash
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_test.cpp
git commit -m "feat(blitter): colorkey texture staging for 1-bit-alpha sprites (BLT_BLEND_COLORKEY); validated vs SW oracle"
```

---

## Task 7: Back-end selection + on-device bring-up

**Files:**
- Modify: `gmloader/mister/raster_backend.h` / `raster_backend_sw.cpp`
  (make `RasterBackend_Select` env-driven)
- Modify: `gmloader/mister/raster_backend_mfgpu.cpp` (wire the real DDR ring +
  scanout `present` on device)
- Modify: findings doc + `.superpowers/sdd/progress.md`

**Interfaces:**
- Consumes: everything above; the device DDR ring base (from the mfgpu/blitter
  design — `0x3B000000` region per the fabric contract).
- Produces: a runtime-selectable renderer on hardware.

- [ ] **Step 1: Selector** — `RasterBackend_Select` returns `&backend_mfgpu`
  when `GMLOADER_RASTER=mfgpu` (env), else `&backend_sw` (default, safe). Add a
  host test asserting both env values pick the right `->name`.

- [ ] **Step 2: Device ring wiring** — in `backend_mfgpu.cpp`, when running on
  device (MISTER build), point the emitter ring/heap at the mmap'd DDR region
  used by the fabric (mirror how `gmloader/mister` maps DDR today); `present`
  triggers/ň awaits fabric scanout. Guard host vs device with the existing
  MiSTer build macro.

- [ ] **Step 3: Build + deploy** — armhf Docker build; back up the device binary
  (`ssh root@192.168.20.81 'cp -n /media/fat/games/gmloader/gmloader{,.bak}'`),
  scp the new binary.

- [ ] **Step 4: Bring-up run** — launch Maldita with `GMLOADER_RASTER=mfgpu`,
  capture the log. Success = boots, no SIGSEGV/SIGILL, draws advance
  (frame counter increments). Compare against `GMLOADER_RASTER=sw` for the same
  scene. Record observed behavior/fps in the findings doc.

- [ ] **Step 5: Update findings + ledger + commit**

```bash
git add docs/superpowers/findings/2026-07-13-mfgpu-phase0-findings.md
git commit -m "feat(blitter): runtime-select mfgpu vs sw backend + on-device bring-up"
```
Then in `mister-gmloader`: bump `external/gmloader-next` to the new tip + commit.

---

## Self-review

- **Coverage:** the user's approved direction — extract a `RasterBackend`
  interface (Task 3), software + fabric implementations behind it (Tasks 3/4/5),
  FBO→SW fallback (Task 5 step 3), SW-as-oracle validation (Task 5 step 4),
  device selection (Task 6) — is fully mapped.
- **No greenfield `mfgpu_gl*`:** the decode layer is explicitly off-limits; we
  reuse `Blitter_On*` and `BVtx`/`RTexture`/`RBlend`.
- **Type consistency:** `RasterBackend` vtable, `bvtx_to_blt`/`rblend_to_blt`,
  and the `blt_*` signatures are used identically across tasks.
- **Honest validation bar:** present-space RGB565 ±1 LSB is stated in Global
  Constraints and applied in Tasks 4–5; bit-exactness is scoped to inside mfgpu.
- **Open detail for the implementer to confirm from headers (not placeholders):**
  exact `blt_push_tris` return/args and `blt_execute` argument list — both are
  documented adjacent APIs in the vendored headers; each task names the header
  and line to read.

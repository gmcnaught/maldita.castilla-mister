# Application surface as a second BRAM render target — Implementation Plan (step 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the GameMaker application surface a fabric render-target surface — rendered into on the FPGA and sampled as a texture — composited over the WORK framebuffer in correct layer order, so the game scene runs on the fabric and the display updates every frame (reaches the title screen).

**Architecture:** Add a "bind render target" command (`BLT_OP_SET_TARGET`) and a "sample the render-target surface" flag (`BLT_F_SRC_SURFACE`) to the blitter protocol. Implement the semantics **software-first** in the C reference model (`blitter_ref.c` / `blt_execute`), gate it with host parity tests, then wire the gmloader backend to emit it and mirror it in RTL (a second BRAM surface + a texel-source mux), verified bit-exact against the same reference in Icarus sim. Finally bring up on device.

**Tech Stack:** C (mfgpu host emitter + reference model), C++ (gmloader raster backend), SystemVerilog + Icarus Verilog (`fpga/rtl`, `fpga/sim`), Quartus 17.0.x (RBF), armhf cross-build (gmloader), MiSTer @ `192.168.20.81`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-17-maldita-appsurface-bram-render-target-design.md`. Every task's requirements implicitly include it.
- **Reference-model-first, bit-exact discipline:** the RTL is verified bit-exact (±1 LSB RGB565) against the C reference model (`3rdparty/mfgpu/refmodel/blitter_ref.c`, mirrored to the sim golden `fpga/sim/blt_tri.c`). Any protocol/semantics change lands in the reference model + host oracle FIRST, then RTL matches it. Never change RTL semantics without the reference moving in lockstep.
- **Wire format:** commands are 32 bytes (`BLT_CMD_BYTES=32`, `blt_wire.h`). `blt_pack_cmd`/`blt_unpack_cmd` are the only encoders. Host structs are little-endian to match the wire.
- **Surface format:** RGB565, 16-bit lanes, MiSTer output 320×240 (`MISTER_WIDTH`/`MISTER_HEIGHT`). Framebuffer qword index = `y*80 + (x>>2)`, lane = `x[1:0]` (`comp_fbram.sv`).
- **Fabric ctrl regs:** `C_SUBMIT=0 C_CMDCOUNT=1 C_TARGET=2 C_CLEAR=3 C_FLAGS=4 C_DONE=5 C_STATUS=6 C_SRCSEL=7`, qword-addressed at DDR `0x3B000000`; ring at `0x3B000040`, SRC heap at `0x3B080000` (`raster_backend_mfgpu.cpp:205-214`).
- **Quartus:** 17.0.x only. **Sim:** `cd fpga/sim && ./run_sims.sh [tb_name]` (Icarus, PASS/FAIL markers).
- **Device:** screenshots via `echo screenshot > /dev/MiSTer_cmd` → `/media/fat/screenshots/Maldita Castilla/*.png`; gmloader launcher `/media/fat/Scripts/gmloader_diag.sh --preset fabric`; profiling env `GMLOADER_BLITTER_PROF=1 GMLOADER_DRAW_TRACE=1 GMLOADER_MFSUBMIT_STAT=1`.
- **Step-1 scope cuts (do NOT implement here):** more than one extra surface (effect surfaces stay on the SW fallback), SDRAM-spilled/tiled/larger-than-BRAM surfaces, and post-process shaders on the surface→screen blit (detect and fall back to SW for that frame). These are steps 2/3 (tracked tasks).

---

## File Structure

**Protocol / emitter (`gmloader-next/3rdparty/mfgpu/host/`)**
- `blt_wire.h` — add `BLT_OP_SET_TARGET`, `BLT_F_SRC_SURFACE`; pack/unpack the target id.
- `blt_emitter.h` / `blt_emitter.c` — `blt_set_target()`; `flags` param path for `BLT_F_SRC_SURFACE` on TRILIST.
- `test_emitter.c` — round-trip encode/decode tests.

**Reference model (`gmloader-next/3rdparty/mfgpu/refmodel/`)**
- `blitter_ref.h` / `blitter_ref.c` — `blt_execute`: multi-surface target state; `BLT_OP_SET_TARGET` handling; texel source = render-target surface when `BLT_F_SRC_SURFACE`.
- `test_blitter_ref.c` — two-pass scene parity test.

**Host backend (`gmloader-next/gmloader/mister/`)**
- `blitter.cpp` / `blitter.h` — identify the application-surface FBO; expose it to the backend.
- `raster_backend_mfgpu.cpp` — route aliased-FBO draws to the surface target, emit the surface→screen blit as a fabric draw, retire the SW/stale-cache path for that surface.
- `raster_backend_test.cpp` — parity test for the two-pass scene through the real emit path.

**RTL (`maldita.castilla-mister/fpga/rtl/`)**
- `comp_fbram.sv` — a second, off-screen 1W1R surface (no scan buffer).
- `blitter_defs.vh` — target-id / surface constants.
- `blitter_top.sv` — `BLT_OP_SET_TARGET` decode + target-select mux on the composite write/read port; texel-source mux (surface vs SDRAM) in the `S_TRI_*` path.
- `fpga/sim/` — `blt_tri.c` golden mirror; new `tb_blitter_surface_src.sv`, extend `tb_blitter_system_pipe.sv`.

**Docs**
- `docs/superpowers/plans/2026-07-17-maldita-appsurface-bram-render-target.md` (this file) — Task 1 appends a "Frame-graph findings" appendix.

---

## Task 1: Confirm the per-frame surface/draw graph on device

Empirical inputs the rest of the plan is parameterized on. The existing per-draw `BLIT draw#` trace is capped at the first frames (`LOG_FIRST`); we need a representative *steady-state* frame plus explicit FBO/target/source info.

**Files:**
- Modify: `gmloader-next/gmloader/mister/blitter.cpp` (draw-trace block ~`:530-538`)
- Appends findings to: this plan file (a new "## Appendix A: Frame-graph findings" section)

**Interfaces:**
- Produces (constants consumed by Tasks 4–8):
  - `APPSURF_DETECT` — the exact rule identifying the application-surface FBO.
  - `APPSURF_W`, `APPSURF_H` — used region of the app surface (≤ 320×240).
  - `BLIT_BLEND` — blend mode of the surface→screen draw; `BLIT_HAS_SHADER` — bool.
  - `EFFECT_FBOS` — list of any other FBOs (stay on SW).
  - `LAYER_ORDER` — confirmed sequence {scene→surface, backgrounds→WORK, surface→WORK}.

- [ ] **Step 1: Add a one-shot full-frame draw-graph dump.** In `blitter.cpp`, gate a dump on `getenv("GMLOADER_FRAMEGRAPH")`: when set, log EVERY draw (not just `LOG_FIRST`) for frames `N..N+2` of steady state, including `g_curFBO`, the FBO's color-attachment tex id (`g_fboColorTex[g_curFBO]`), `g_boundTex2D`, blend, `g_vpX/Y/W/H`, and the decoded screen rect. Also log each `Blitter_OnBindFramebuffer`/`Blitter_OnFramebufferTexture2D`.

```cpp
// blitter.cpp — inside handle_draw(), replace the `g_drawNo <= LOG_FIRST` guard with:
static int fg = -1;
if (fg < 0) { const char *e = getenv("GMLOADER_FRAMEGRAPH"); fg = (e && *e) ? atoi(e) : 0; }
bool fg_win = fg && g_frameNo >= fg && g_frameNo < fg + 3;   // g_frameNo bumped in Blitter_PresentDefault
if (g_drawNo <= LOG_FIRST || fg_win) {
    GLuint fbotex = g_curFBO ? g_fboColorTex[g_curFBO] : 0;
    fprintf(stderr, "FG f=%d d#%llu fbo=%u fbotex=%u srctex=%u blend=%s vp=[%d,%d,%d,%d] scr=[%.0f,%.0f..%.0f,%.0f]\n",
        g_frameNo, (unsigned long long)g_drawNo, g_curFBO, fbotex, g_boundTex2D, blend_name(),
        g_vpX,g_vpY,g_vpW,g_vpH, decoded?minx:0,decoded?miny:0,decoded?maxx:0,decoded?maxy:0);
}
```
Add a `static int g_frameNo` in the `namespace` block and `g_frameNo++` in `Blitter_PresentDefault()`.

- [ ] **Step 2: Build gmloader (armhf) and deploy.** Follow the existing build path (see `deploy.py`); deploy only the engine binary.

Run: `cd gmloader-next && <existing armhf build> && cd ../maldita.castilla-mister && ./deploy.py --engine-only` (confirm the flag in `deploy.py`; else full `./deploy.py`).

- [ ] **Step 3: Capture a steady-state frame graph.** SSH to the device, launch with the dump enabled at a frame well past boot:

Run: `ssh root@192.168.20.81 'cd /media/fat/games/gmloader && GMLOADER_FRAMEGRAPH=600 setsid /media/fat/Scripts/gmloader_diag.sh --preset fabric >/tmp/gm.out 2>&1 & sleep 60; grep "^FG " /tmp/gmloader.log | tail -60'`
Expected: 2–3 frames of `FG` lines showing every draw's fbo/target/source/blend/rect.

- [ ] **Step 4: Derive and record the constants.** From the `FG` dump, identify: which FBO id recurs as a render target and later appears as `srctex` in a `fbo=0` fullscreen draw (that is the application surface — `APPSURF_DETECT`); its used W×H; the blend of the `fbo=0` draw that samples it (`BLIT_BLEND`); whether that draw uses a non-default shader program (`BLIT_HAS_SHADER` — compare `g_curProgram` to the scene program); any other FBO ids (`EFFECT_FBOS`); and the within-frame order (`LAYER_ORDER`). Write them into "Appendix A" of this file.

- [ ] **Step 5: Commit.**

```bash
cd maldita.castilla-mister
git add docs/superpowers/plans/2026-07-17-maldita-appsurface-bram-render-target.md
git add ../gmloader-next/gmloader/mister/blitter.cpp
git commit -m "diag: full-frame draw-graph dump (GMLOADER_FRAMEGRAPH); record appsurface frame graph"
```

**Gate:** if `LAYER_ORDER` or `BLIT_HAS_SHADER` contradicts the spec's assumption (plain textured/alpha blit, surface composited last over backgrounds), STOP and revise the spec before continuing.

---

## Task 2: Protocol — `BLT_OP_SET_TARGET` + `BLT_F_SRC_SURFACE`

Add the two protocol primitives to the wire format and emitter. Pure encode/decode; no semantics yet.

**Files:**
- Modify: `gmloader-next/3rdparty/mfgpu/host/blt_wire.h`
- Modify: `gmloader-next/3rdparty/mfgpu/host/blt_emitter.h`, `blt_emitter.c`
- Test: `gmloader-next/3rdparty/mfgpu/host/test_emitter.c`

**Interfaces:**
- Produces:
  - `#define BLT_OP_SET_TARGET 12` (next free opcode after the existing set — confirm max in `blt_wire.h`), carrying target id in `blt_cmd_t.color` low byte.
  - `#define BLT_F_SRC_SURFACE 0x10` (a `flags` bit, distinct from existing `BLT_F_*`).
  - `#define BLT_TARGET_WORK 0`, `BLT_TARGET_APPSURF 2` (matches RTL `target_buf`).
  - `int blt_set_target(blt_emitter_t *e, int target_id);` — emits one SET_TARGET command.
  - `blt_trilist(...)` gains no new signature; callers OR `BLT_F_SRC_SURFACE` into the existing `flags` param.

- [ ] **Step 1: Write the failing test.** In `test_emitter.c`, add:

```c
static int test_set_target_roundtrip(void) {
    uint8_t buf[BLT_CMD_BYTES];
    blt_cmd_t c = {0}; c.opcode = BLT_OP_SET_TARGET; c.color = BLT_TARGET_APPSURF;
    blt_pack_cmd(&c, buf);
    blt_cmd_t d = {0}; blt_unpack_cmd(buf, &d);
    if (d.opcode != BLT_OP_SET_TARGET) { printf("FAIL opcode %u\n", d.opcode); return 1; }
    if ((d.color & 0xFF) != BLT_TARGET_APPSURF) { printf("FAIL target %u\n", d.color); return 1; }
    printf("PASS set_target_roundtrip\n"); return 0;
}
```
Register it in `main()`'s test list.

- [ ] **Step 2: Run it, verify it fails to compile.**

Run: `cd gmloader-next/3rdparty/mfgpu/host && make test_emitter && ./test_emitter`
Expected: compile error — `BLT_OP_SET_TARGET` / `BLT_TARGET_APPSURF` undefined.

- [ ] **Step 3: Add the defines + emitter helper.** In `blt_wire.h` add the opcode/flag/target defines. In `blt_emitter.c`:

```c
int blt_set_target(blt_emitter_t *e, int target_id) {
    blt_cmd_t c = {0};
    c.opcode = BLT_OP_SET_TARGET;
    c.color  = (uint16_t)target_id;   /* low byte carries the target id on the wire */
    return blt_emit_cmd(e, &c);        /* same append path blt_fill/blt_blit use */
}
```
Declare it in `blt_emitter.h`. (If the append helper has a different name, match `blt_fill`'s implementation.)

- [ ] **Step 4: Run the test, verify PASS.**

Run: `cd gmloader-next/3rdparty/mfgpu/host && make test_emitter && ./test_emitter`
Expected: `PASS set_target_roundtrip` and all existing tests still PASS.

- [ ] **Step 5: Commit.**

```bash
git add gmloader-next/3rdparty/mfgpu/host/{blt_wire.h,blt_emitter.h,blt_emitter.c,test_emitter.c}
git commit -m "mfgpu: BLT_OP_SET_TARGET + BLT_F_SRC_SURFACE wire encoding + blt_set_target"
```

---

## Task 3: Reference model — target switching + surface-as-source

Give `blt_execute` (the golden) the semantics: a `SET_TARGET` switches the composite destination among surfaces; a TRILIST with `BLT_F_SRC_SURFACE` samples texels from the render-target surface instead of the SDRAM heap.

**Files:**
- Modify: `gmloader-next/3rdparty/mfgpu/refmodel/blitter_ref.c`, `blitter_ref.h`
- Test: `gmloader-next/3rdparty/mfgpu/refmodel/test_blitter_ref.c`

**Interfaces:**
- Consumes: `BLT_OP_SET_TARGET`, `BLT_F_SRC_SURFACE`, `BLT_TARGET_*` (Task 2).
- Produces: `blt_execute` composites into `fb` for `BLT_TARGET_WORK` and into an internal second surface buffer for `BLT_TARGET_APPSURF`; `BLT_F_SRC_SURFACE` draws read that second surface as their texture source. Surface dims come from `APPSURF_W×APPSURF_H` (Task 1); model it as a fixed 320×240 buffer (superset) to avoid stride math.

- [ ] **Step 1: Write the failing test.** In `test_blitter_ref.c`, a two-pass scene: pass A renders a solid 8×8 magenta quad into `APPSURF` at (0,0); pass B (`SET_TARGET WORK`) draws a fullscreen quad sampling `APPSURF` with `BLT_F_SRC_SURFACE`, `BLEND_COPY`. Assert `fb[0]` == magenta and `fb` outside the 8×8 == the WORK clear color.

```c
static int test_surface_src(void) {
    uint16_t fb[320*240];
    /* build a ring: SET_TARGET APPSURF; TRILIST(magenta quad -> appsurf);
       SET_TARGET WORK; TRILIST(fullscreen quad, BLT_F_SRC_SURFACE, COPY). */
    blt_cmd_t cmds[/*N*/]; int n = build_surface_src_scene(cmds);   /* helper in this test file */
    blt_surface_heap_t heap = { g_heap, sizeof g_heap, NULL, NULL };
    blt_execute(fb, &heap, cmds, n);
    uint16_t magenta = rgb565(255,0,255);
    if (fb[0] != magenta) { printf("FAIL px0=%04x want %04x\n", fb[0], magenta); return 1; }
    if (fb[320*8] == magenta) { printf("FAIL row8 should not be magenta\n"); return 1; }
    printf("PASS surface_src\n"); return 0;
}
```

- [ ] **Step 2: Run it, verify it fails.**

Run: `cd gmloader-next/3rdparty/mfgpu/refmodel && make test_blitter_ref && ./test_blitter_ref`
Expected: FAIL — `SET_TARGET` unhandled (composites to `fb`), so `fb[0]` is not magenta.

- [ ] **Step 3: Implement multi-target + surface-source in `blt_execute`.** Add a second static `uint16_t appsurf[320*240]` buffer and a `dst = (target==APPSURF) ? appsurf : fb` pointer updated on `BLT_OP_SET_TARGET`. In the TRILIST texel fetch, when `cmd.flags & BLT_F_SRC_SURFACE`, sample `appsurf[v*320+u]` instead of the heap page at `src_off`. Keep all blend/colorkey math identical.

```c
/* blitter_ref.c — sketch inside the command loop */
static uint16_t appsurf[320*240];
uint16_t *dst = fb;                       /* default target = WORK/fb */
...
case BLT_OP_SET_TARGET:
    dst = (c->color & 0xFF) == BLT_TARGET_APPSURF ? appsurf : fb;
    break;
case BLT_OP_TRILIST: {
    int from_surface = (c->flags & BLT_F_SRC_SURFACE) != 0;
    /* per fragment: */
    uint16_t texel = from_surface ? appsurf[ty*320 + tx]
                                  : heap_texel(heap, c->src_off, tx, ty, c->src_stride);
    blend_into(dst, x, y, texel, c->blend_mode, c->colorkey, c->alpha);
    break;
}
```

- [ ] **Step 4: Run the test, verify PASS (and existing refmodel tests still PASS).**

Run: `cd gmloader-next/3rdparty/mfgpu/refmodel && make test_blitter_ref && ./test_blitter_ref`
Expected: `PASS surface_src`, no regressions.

- [ ] **Step 5: Commit.**

```bash
git add gmloader-next/3rdparty/mfgpu/refmodel/{blitter_ref.c,blitter_ref.h,test_blitter_ref.c}
git commit -m "mfgpu refmodel: SET_TARGET multi-surface + BLT_F_SRC_SURFACE sampling"
```

---

## Task 4: Host — identify the application-surface FBO

Detect, in `blitter.cpp`, which FBO is the application surface, using `APPSURF_DETECT` from Task 1 (the FBO whose color texture is later drawn as a fullscreen quad to the default framebuffer).

**Files:**
- Modify: `gmloader-next/gmloader/mister/blitter.cpp`, `blitter.h`
- Test: `gmloader-next/gmloader/mister/blitter_raster_test.cpp` (add a unit case) or a new `blitter_appsurf_test.cpp`.

**Interfaces:**
- Produces: `GLuint Blitter_AppSurfaceFBO(void);` (0 if none yet) and `GLuint Blitter_AppSurfaceTex(void);` — the identified FBO id and its color texture id. Detection updates once the fullscreen-blit-of-an-FBO-texture pattern is seen.

- [ ] **Step 1: Write the failing test.** Drive the shadow hooks to simulate one frame: bind FBO 7, attach tex 6, draw into it; bind FBO 0, draw a fullscreen quad sampling tex 6. Assert `Blitter_AppSurfaceFBO()==7` and `Blitter_AppSurfaceTex()==6`.

```cpp
TEST(appsurf_detect) {
    Blitter_OnBindFramebuffer(0, 7); Blitter_OnFramebufferTexture2D(0, 6);
    /* ...draw into FBO 7... */
    Blitter_OnBindFramebuffer(0, 0);
    /* fullscreen quad sampling tex 6 over [0,0..320,240] -> handle_draw */
    ASSERT_EQ(Blitter_AppSurfaceFBO(), 7u);
    ASSERT_EQ(Blitter_AppSurfaceTex(), 6u);
}
```

- [ ] **Step 2: Run it, verify it fails.**

Run: `cd gmloader-next && <host test build for blitter_raster_test> && ./blitter_raster_test`
Expected: FAIL — `Blitter_AppSurfaceFBO` undefined / returns 0.

- [ ] **Step 3: Implement detection.** In `handle_draw`, when `g_curFBO==0` and the sampled `g_boundTex2D` is a value present in `g_fboColorTex` (i.e., it is some FBO's color attachment) and the draw covers the full viewport, record `g_appSurfFbo = <that fbo>`, `g_appSurfTex = g_boundTex2D`. Expose accessors.

```cpp
// blitter.cpp (namespace)
static GLuint g_appSurfFbo = 0, g_appSurfTex = 0;
// in handle_draw, after decode, before rasterize:
if (g_curFBO == 0 && decoded == count) {
    for (auto &kv : g_fboColorTex)
        if (kv.second == g_boundTex2D && maxx-minx >= g_rw-1 && maxy-miny >= g_rh-1) {
            g_appSurfFbo = kv.first; g_appSurfTex = kv.second; break;
        }
}
// exported:
GLuint Blitter_AppSurfaceFBO(void){ return g_appSurfFbo; }
GLuint Blitter_AppSurfaceTex(void){ return g_appSurfTex; }
```
Declare both in `blitter.h`.

- [ ] **Step 4: Run the test, verify PASS.**

Run: `cd gmloader-next && ./blitter_raster_test`
Expected: PASS, no regressions.

- [ ] **Step 5: Commit.**

```bash
git add gmloader-next/gmloader/mister/{blitter.cpp,blitter.h,blitter_raster_test.cpp}
git commit -m "gmloader: identify GM application-surface FBO (fullscreen-blit-of-FBO-texture)"
```

---

## Task 5: Host — route aliased draws to the surface, emit the blit, retire SW/stale-cache

Wire the mfgpu backend: draws into the app-surface FBO render on the fabric into `BLT_TARGET_APPSURF`; the surface→screen blit becomes a `SET_TARGET WORK` + `BLT_F_SRC_SURFACE` TRILIST. Remove the SW fallback and stale-texture staging for that surface.

**Files:**
- Modify: `gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp` (`mf_draw` `:462`, `mf_frame_begin`/`mf_device_submit`)
- Modify: `gmloader-next/gmloader/mister/blitter.cpp:484` (pass app-surface context into the backend `draw` call)
- Test: `gmloader-next/gmloader/mister/raster_backend_test.cpp`

**Interfaces:**
- Consumes: `Blitter_AppSurfaceFBO/Tex` (Task 4); `blt_set_target`, `BLT_F_SRC_SURFACE` (Task 2); reference semantics (Task 3).
- Produces: for a frame containing {scene→appsurf, backgrounds→WORK, appsurf→WORK}, the emitted ring executed by `blt_execute` yields a `fb` bit-exact to the SW reference of the same scene.

- [ ] **Step 1: Write the failing parity test.** In `raster_backend_test.cpp`, construct the two-pass scene through the **real** backend entry points (as the existing tests do): set the app-surface FBO, draw a sprite into it, then draw it fullscreen to DEF over a cleared background; run the accumulated ring through `blt_execute`; compare to a `backend_sw` render of the same draws. Assert bit-exact (±1 LSB).

- [ ] **Step 2: Run it, verify it fails.**

Run: `cd gmloader-next && ./raster_backend_test`
Expected: FAIL — today FBO draws go to SW and the blit samples a staged texture; the emitted ring has no SET_TARGET/surface-source, so `blt_execute` output differs.

- [ ] **Step 3: Implement routing in `mf_draw`.** Replace the unconditional FBO→SW fallback (`raster_backend_mfgpu.cpp:467`) with app-surface-aware routing:

```cpp
// mf_draw: d->rgba identifies the target surface (blitter.cpp passes it).
bool dst_is_appsurf = (Blitter_AppSurfaceFBO() != 0) && (d->fbo == Blitter_AppSurfaceFBO());
bool src_is_appsurf = (Blitter_AppSurfaceTex() != 0) && (tex_key == Blitter_AppSurfaceTex());

if (g_defRGBA && d->rgba != g_defRGBA && !dst_is_appsurf) { backend_sw.draw(...); return; } // other FBOs -> SW (scope)

if (dst_is_appsurf && g_cur_target != MF_TARGET_APPSURF) { blt_set_target(&g_e, BLT_TARGET_APPSURF); g_cur_target = MF_TARGET_APPSURF; }
else if (!dst_is_appsurf && g_cur_target != MF_TARGET_WORK) { blt_set_target(&g_e, BLT_TARGET_WORK); g_cur_target = MF_TARGET_WORK; }

uint8_t extra_flags = src_is_appsurf ? BLT_F_SRC_SURFACE : 0;
// ...existing texel-staging path SKIPPED when src_is_appsurf (no blt_upload/blt_stage for the surface)...
blt_trilist(&g_e, tex, blend_mode, colorkey, /*alpha=*/255, eoff, triCount, existing_flags | extra_flags);
```
Add `d->fbo` to `RSurface` (set in `blitter.cpp`'s `get_render_target`) so the backend knows which FBO a target is. Reset `g_cur_target` to `MF_TARGET_WORK` in `mf_frame_begin`.

- [ ] **Step 4: Run the parity test, verify PASS.**

Run: `cd gmloader-next && ./raster_backend_test`
Expected: PASS bit-exact; existing tests still PASS.

- [ ] **Step 5: Commit.**

```bash
git add gmloader-next/gmloader/mister/{raster_backend_mfgpu.cpp,blitter.cpp,blitter.h,raster_backend_test.cpp}
git commit -m "gmloader: route app-surface draws to fabric surface + emit SET_TARGET/SRC_SURFACE blit"
```

**Milestone:** the host now emits a correct fabric ring for the real frame; `blt_execute` proves it correct in software. Remaining work makes the RTL match.

---

## Task 6: RTL — second BRAM surface + `SET_TARGET` decode/target-select

Add an off-screen 1W1R BRAM surface and route the compositor's write/read to it when the active target is `APPSURF`.

> RTL steps specify exact modules, ports, behavior, testbench, and the golden gate. Gate-level SystemVerilog is authored against the sim during execution; the PASS condition is bit-exactness vs the `blitter_ref` golden, so correctness is enforced by the test, not by transcribed code.

**Files:**
- Modify: `fpga/rtl/comp_fbram.sv` (add an off-screen surface bank, or a parallel `comp_surfram.sv`)
- Modify: `fpga/rtl/blitter_top.sv` (`BLT_OP_SET_TARGET` decode near `:180-196` op localparams and the command FSM `:700-704` target_buf handling; mux composite `fb_wr_*`/`fb_rd_*` between WORK and surface)
- Modify: `fpga/rtl/blitter_defs.vh` (surface constants)
- Test: `fpga/sim/tb_fbram.sv` (extend) or new `fpga/sim/tb_surfram.sv`

**Interfaces:**
- Consumes: `BLT_OP_SET_TARGET` (Task 2), `target_buf==2` semantics.
- Produces: when `target_buf==BLT_TARGET_APPSURF`, composite writes/reads address the surface bank; scanout/snapshot are unaffected (surface is never scanned). WORK path byte-identical to today when target is 0/1.

- [ ] **Step 1: Write the failing sim.** New `tb_surfram.sv`: drive a SET_TARGET=APPSURF, write a known pattern via the composite port, SET_TARGET=WORK, write a different pattern; read both back and assert the surface and WORK banks hold their respective patterns independently. Print `RESULT: PASS`/`FAIL`.

- [ ] **Step 2: Run it, verify it fails.**

Run: `cd fpga/sim && ./run_sims.sh tb_surfram`
Expected: FAIL/compile error — no surface bank / SET_TARGET decode yet.

- [ ] **Step 3: Implement the surface bank + target mux.** Add the off-screen surface storage (1W1R, `APPSURF_W*APPSURF_H` sized to `comp_fbram`'s qword layout; no scan/snapshot copy). Decode `BLT_OP_SET_TARGET` to set `target_buf`; mux the `comp_fbram` composite write/read address+enable between WORK and surface on `target_buf`.

- [ ] **Step 4: Run the sim, verify PASS + no regressions in the fbram suite.**

Run: `cd fpga/sim && ./run_sims.sh tb_surfram tb_fbram tb_fbram_snapshot`
Expected: all `RESULT: PASS`.

- [ ] **Step 5: Commit.**

```bash
git add fpga/rtl/{comp_fbram.sv,blitter_top.sv,blitter_defs.vh} fpga/sim/tb_surfram.sv
git commit -m "rtl: off-screen BRAM surface + BLT_OP_SET_TARGET target select"
```

---

## Task 7: RTL — texel sample-surface-as-texture (`BLT_F_SRC_SURFACE`)

Give the `S_TRI_*` texel fetch a second source: read the surface bank when the TRILIST header carries `BLT_F_SRC_SURFACE`, else the existing SDRAM path.

**Files:**
- Modify: `fpga/rtl/blitter_top.sv` (TRILIST header decode; `S_TRI_GOTTEX`/texel-fetch region ~`:919-923`, `:163-174`)
- Modify: `fpga/sim/blt_tri.c` + `fpga/sim/gen_tri_golden.c` (mirror `BLT_F_SRC_SURFACE` from `blitter_ref.c`, Task 3, so the golden matches)
- Test: new `fpga/sim/tb_blitter_surface_src.sv`

**Interfaces:**
- Consumes: surface bank (Task 6), `BLT_F_SRC_SURFACE` (Task 2), refmodel semantics (Task 3).
- Produces: a TRILIST with `BLT_F_SRC_SURFACE` samples texels from the surface bank; output bit-exact to `blt_execute` for the same command.

- [ ] **Step 1: Write the failing sim.** `tb_blitter_surface_src.sv`: pre-load the surface bank with a known image (via the composite port or a sim backdoor), submit a fullscreen TRILIST with `BLT_F_SRC_SURFACE`+`BLEND_COPY` targeting WORK, and compare the WORK bank to a golden produced by `blt_tri.c`/`blitter_ref` for the identical inputs. Assert bit-exact.

- [ ] **Step 2: Run it, verify it fails.**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_surface_src`
Expected: FAIL — texel fetch ignores `BLT_F_SRC_SURFACE`, samples SDRAM, mismatches golden.

- [ ] **Step 3: Implement the texel-source mux.** Decode `BLT_F_SRC_SURFACE` from the TRILIST header; when set, the per-fragment texel read addresses the surface bank (u,v → surface qword/lane) instead of issuing the `sdram_fb_cache` P_SRC read. Preserve colorkey/alpha/blend behavior. Update `blt_tri.c`/`gen_tri_golden.c` to mirror Task 3's reference so the golden encodes the same semantics.

- [ ] **Step 4: Run the sim + the trilist suite, verify PASS.**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_surface_src tb_blitter_trilist_pipe tb_blitter_trilist_calpha tb_blitter_trilist_key`
Expected: all `RESULT: PASS` (surface-src correct; existing SDRAM-source trilists unregressed).

- [ ] **Step 5: Commit.**

```bash
git add fpga/rtl/blitter_top.sv fpga/sim/{blt_tri.c,gen_tri_golden.c,tb_blitter_surface_src.sv}
git commit -m "rtl: texel sample-surface-as-texture (BLT_F_SRC_SURFACE); golden mirror"
```

---

## Task 8: RTL — full-frame integration sim (render-into-surface → sample-over-WORK)

Prove the whole per-frame flow bit-exact against `blt_execute` for a representative scene, and confirm STA/fit with the new BRAM surface + texel mux.

**Files:**
- Modify: `fpga/sim/tb_blitter_system_pipe.sv` (add a two-pass scene case)
- Modify (if needed): `fpga/rtl/blitter_top.sv` (command-stream ordering: SET_TARGET mid-ring, ensure the surface write completes before the sampling pass — the existing serialized submit model already orders commands; add a barrier only if the sim shows a hazard)

**Interfaces:**
- Consumes: Tasks 6 + 7.
- Produces: for the Task-1 frame graph reduced to {clear appsurf; sprite→appsurf; clear WORK; bg→WORK; appsurf→WORK}, the RTL WORK+scan output equals `blt_execute` of the same ring.

- [ ] **Step 1: Write the failing sim.** Extend `tb_blitter_system_pipe.sv` with the two-pass scene (mirroring `test_blitter_ref.c`'s scene from Task 3); golden = `blt_execute` output for the same ring. Assert bit-exact over the full 320×240.

- [ ] **Step 2: Run it, verify it fails (or passes if Tasks 6–7 already suffice).**

Run: `cd fpga/sim && ./run_sims.sh tb_blitter_system_pipe`
Expected: FAIL if a mid-ring target/hazard issue exists; else PASS (then Step 3 is a no-op).

- [ ] **Step 3: Fix ordering/hazard if needed.** If the sampling pass reads the surface before the render pass's writes land, add the minimal barrier so `SET_TARGET WORK` following surface writes waits for the surface composite to drain (analogous to the retired `dst_barrier` pattern noted in `blitter_top.sv:116`).

- [ ] **Step 4: Run the full sim suite, verify PASS.**

Run: `cd fpga/sim && ./run_sims.sh`
Expected: entire suite `PASS` (no regressions).

- [ ] **Step 5: Build the RBF and check STA/fit.**

Run: `cd fpga && ./build_maldita.sh` (Quartus 17.0.x)
Expected: fit succeeds; STA meets timing (the surface bank + texel mux fit the M10K budget — if not, reclaim from texel-cache trims per spec and re-run). Record slack.

- [ ] **Step 6: Commit.**

```bash
git add fpga/sim/tb_blitter_system_pipe.sv fpga/rtl/blitter_top.sv
git commit -m "rtl: full-frame surface render+sample integration sim; bit-exact vs blt_execute"
```

---

## Task 9: Device bring-up and verification

Deploy RBF + gmloader and confirm the fix end-to-end.

**Files:** none (build + deploy + observe). Uses `deploy.py`, `gmloader_diag.sh`.

**Interfaces:** Consumes all prior tasks.

- [ ] **Step 1: Deploy.**

Run: `cd maldita.castilla-mister && gh run download -n maldita-rbf -D _Other  # or local build_maldita.sh output` then `./deploy.py` (RBF + engine, sha1-verified).

- [ ] **Step 2: Go/no-go probe (unchanged contract).**

Run: `scp ../gmloader-next/tools/fabric_probe.armhf root@192.168.20.81:/tmp/ && ssh root@192.168.20.81 /tmp/fabric_probe.armhf 5`
Expected: `C_DONE=... OK` + magenta triangle on blue (regression check that the base path still works).

- [ ] **Step 3: Full run + observe the display updates.**

Run: `ssh root@192.168.20.81 'cd /media/fat/games/gmloader && setsid /media/fat/Scripts/gmloader_diag.sh --preset fabric >/tmp/gm.out 2>&1 & sleep 40'`
then two screenshots ~15s apart:
`ssh root@192.168.20.81 'echo screenshot > /dev/MiSTer_cmd; sleep 16; echo screenshot > /dev/MiSTer_cmd'` and `scp` both.
Expected: the two screenshots have **different** MD5s (display is animating, not frozen), and the image is a coherent Cursed Castilla intro/title — not the black+garbage frozen frame.

- [ ] **Step 4: Confirm scene is on the fabric + perf.**

Run: `ssh root@192.168.20.81 'grep -E "BLITPROF|MFSUBMIT" /tmp/gmloader.log | tail -6'`
Expected: `to=0` (no fabric timeouts); the software `raster=` bucket drops materially (scene now fabric-side); frame time improves vs the ~60ms baseline. Record before/after.

- [ ] **Step 5: Reach the title screen.** Let it run ~2 min; screenshot; confirm it advances past the intro to the title screen (the original failure mode is gone).

- [ ] **Step 6: Commit any deploy/doc updates + update the tracking task.**

```bash
git add -A && git commit -m "deploy: app-surface fabric render target verified on device (reaches title)"
```

**Definition of done:** display animates every frame and reaches the Cursed Castilla title screen; screenshot MD5s change over time; `to=0`; software `raster` bucket materially reduced; sim suite + host parity tests green; STA/fit met.

---

## Self-review

- **Spec coverage:** second BRAM surface (Task 6), target select (Tasks 2/6), sample-surface-as-texture (Tasks 3/7), host identify (Task 4), host route + emit blit + retire SW/stale-cache (Task 5), protocol C_TARGET/source-select (Task 2), per-frame data flow (Tasks 5/8), coordinate/layer confirmation (Task 1), testing host-parity + sim + device (Tasks 3/5/7/8/9), scope cuts honored (effect surfaces→SW in Task 5, shader fallback flagged Task 1/5). All spec sections map to a task.
- **Reference-first ordering:** semantics land in `blitter_ref.c`/`blt_execute` (Task 3) and are proven at the host level (Task 5) before RTL (Tasks 6–8) must match — matching the repo's bit-exact discipline.
- **Empirical dependencies** (surface size, detection rule, blend, shader presence, layer order) are isolated in Task 1 and named as constants the later tasks consume, rather than guessed inline.
- **RTL caveat:** Tasks 6–8 specify module/ports/behavior/testbench/golden rather than transcribed gate-level Verilog; correctness is enforced by bit-exact sim vs the Task-3 reference. This is deliberate (fabricated Verilog would be unverified), and is the one place the "full code in every step" ideal yields to the repo's golden-gated sim methodology.

## Appendix A: Frame-graph findings (filled in by Task 1)

_TODO(Task 1): record APPSURF_DETECT, APPSURF_W×H, BLIT_BLEND, BLIT_HAS_SHADER, EFFECT_FBOS, LAYER_ORDER here._

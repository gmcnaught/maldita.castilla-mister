# MFGPU Phase 0 + Phase 1 Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove, entirely in CI (no hardware), that a fixed-function FPGA renderer can turn GameMaker draw batches into correct blended pixels — by adding a screen-space textured-triangle op to the blitter's refmodel + emitter + RTL sim, and an A9 geometry front-end (`libmfgpu`) that transforms GM batches into that op.

**Architecture:** The A9 does geometry (matrix transform, cull, fixed-point); the fabric does pixels (rasterize screen-space textured triangles, interpolate U/V/RGBA, fetch texel, modulate, blend). We extend the existing `mister-fpga-blitter` display-list: a new `BLT_OP_TRILIST` header command (reusing the `tl_buf` entry-buffer pattern already used by `BLT_OP_TILELIST_RES`) points at a buffer of 16-byte vertices, 3 per triangle. The C reference model (`blt_raster_tri`) is the golden spec; the RTL must match it bit-exactly via the existing `sim/` per-scenario diff harness.

**Tech Stack:** C99 (refmodel, emitter, libmfgpu — host-testable, the CI spine), SystemVerilog + Icarus Verilog (`iverilog`/`vvp`) for RTL sim, ARM NEON (optional accel in libmfgpu). Existing test pattern: per-directory `make test`.

## Global Constraints

- **License header:** every new file starts with the repo's GPL-3.0 header, matching existing files in the same directory (copy verbatim from a sibling file).
- **Command word stays 32 bytes:** `blt_cmd_t` must remain exactly 32 bytes (8×u32). `BLT_OP_TRILIST` reuses existing fields; it must not grow the struct. There is a `static_assert(sizeof(blt_cmd_t)==32,...)` — keep it passing.
- **Refmodel is golden:** RTL correctness is defined as bit-exact match to `blt_raster_tri` on the sim scenarios. No RTL task is "done" until its sim scenario prints `RESULT: PASS`.
- **Framebuffer:** on-chip, 320×240 RGB565 (`BLT_FB_W=320`, `BLT_FB_H=240`) — Phase 1 stays on-chip; no SDRAM-resident framebuffers in this plan.
- **Reuse, don't reinvent:** use the existing blend helpers (`blt_blend565`, `blt_add565`, `blt_mul565`, `blt_tint565`), the `blt_alloc` heap, and the `tl_buf` entry-buffer mechanism. Confirm each helper's exact signature in `refmodel/blitter_ref.h` before calling it.
- **Fixed-point contract:** screen X/Y are signed **12.4** (`>>4` = pixel). Texel U/V are unsigned **12.4** texel coordinates. Per-vertex color is RGBA8888 packed `r | g<<8 | b<<16 | a<<24`.
- **Commit granularity:** one commit per task (the final step of each task). Commit messages use Conventional Commits (`feat:`, `test:`, `chore:`).

---

## Part A — Phase 0: De-risk (investigation spikes)

These four tasks are **spikes**, not TDD code. Each produces a concrete finding written to a single findings doc. They gate the *follow-on* integration plan (interceptor + RBF), not Part B/C — so Part B/C can proceed in parallel. Deliverable of Part A: `docs/superpowers/findings/2026-07-13-mfgpu-phase0-findings.md`.

### Task A1: Capture the software-GL baseline for Maldita Castilla

**Files:**
- Create: `docs/superpowers/findings/2026-07-13-mfgpu-phase0-findings.md`

- [ ] **Step 1:** Deploy the armhf PortMaster Maldita Castilla port (`PortMaster-New/ports/maldita.castilla/`) onto the MiSTer via the existing gmloader + software-GL (Mesa) path used previously. Confirm it launches, shows video, and responds to controls.
- [ ] **Step 2:** Measure and record the framerate on a representative gameplay scene (not a menu). Use the existing DDR fps counter or on-screen timing; record the method used.
- [ ] **Step 3:** Write to the findings doc under a heading `## A1 Baseline`: the measured fps (expected ~1 fps), the exact port version/md5, the launch command, and the fps-measurement method. This is the before-number the whole project is judged against.
- [ ] **Step 4: Commit**
```bash
git add docs/superpowers/findings/2026-07-13-mfgpu-phase0-findings.md
git commit -m "chore: record Maldita software-GL baseline (Phase 0 A1)"
```

### Task A2: Determine Maldita's internal render resolution

**Files:**
- Modify: `docs/superpowers/findings/2026-07-13-mfgpu-phase0-findings.md`

- [ ] **Step 1:** Determine the game's internal `application_surface` / room render resolution. Two independent methods, do both and cross-check: (a) inspect `game.droid` room + surface dimensions using UndertaleModLib (the `6feetunder` repo's tooling pattern under `tools/`), and (b) instrument the runner at load to log `window_get_width/height` and `surface_get_width/height` of the application surface.
- [ ] **Step 2:** Record under `## A2 Resolution`: the internal render resolution, the output/window resolution, and a yes/no decision on whether the internal res fits the on-chip 320×240 RGB565 framebuffer budget. If it exceeds 320×240, note the exact dimensions so the follow-on plan can decide (scaler-upscale vs SDRAM path).
- [ ] **Step 3: Commit**
```bash
git add -A && git commit -m "chore: record Maldita internal render resolution (Phase 0 A2)"
```

### Task A3: Pin the interception point

**Files:**
- Modify: `docs/superpowers/findings/2026-07-13-mfgpu-phase0-findings.md`

- [ ] **Step 1:** Evaluate the two interception options against the actual armhf runner: (a) a **GLES2 draw-interposer** — an `LD_PRELOAD`/loader-injected shim exporting `glDrawElements`/`glDrawArrays`/`glBindTexture`/`glUniformMatrix4fv`/`glBlendFunc` — vs (b) hooking the runner's **internal vertex-batch flush** symbol. Inspect the runner `.so` (symbols, and whether gmloader-next can resolve/patch the batch-flush) to judge stability across GM versions.
- [ ] **Step 2:** Decide and record under `## A3 Interception`: the chosen option, and — critically — the **exact per-batch data available at that boundary** mapped onto the `mfgpu_batch_t` fields defined in Task C1 (vertex array layout + stride, index buffer presence, how the MVP matrix is obtained, how the bound texture page + its dimensions are obtained, how blend mode is obtained). If any `mfgpu_batch_t` field is *not* available at the chosen boundary, note it — Task C1's struct is the contract and may need adjustment.
- [ ] **Step 3:** Confirm the vertex attribute format the runner actually submits (position component count, whether UVs are normalized 0..1 page coords, color format). Record it — Task C2's transform depends on it.
- [ ] **Step 4: Commit**
```bash
git add -A && git commit -m "chore: pin MFGPU interception point + batch schema (Phase 0 A3)"
```

### Task A4: Audit custom-shader exposure

**Files:**
- Modify: `docs/superpowers/findings/2026-07-13-mfgpu-phase0-findings.md`

- [ ] **Step 1:** Extract the shader inventory from `game.droid` (UndertaleModLib shader chunk) and grep the game's GML for `shader_set(`. List every custom shader and, for each, whether it's used in the gameplay hot path or only in menus/effects.
- [ ] **Step 2:** Record under `## A4 Shaders`: the list, and a fabric-eligible vs software-fallback classification per shader. If Maldita uses zero custom shaders (expected for old GM), state that explicitly — it means Phase 1 needs no fallback path for this canary.
- [ ] **Step 3: Commit**
```bash
git add -A && git commit -m "chore: audit Maldita custom-shader usage (Phase 0 A4)"
```

---

## Part B — Fabric raster core (TDD against the existing harness)

All of Part B is host- and sim-testable with no hardware. Work in `mister-fpga-blitter/`.

### Task B1: Define the `BLT_OP_TRILIST` command + vertex struct

**Files:**
- Modify: `refmodel/blitter_ref.h` (add opcode, `blt_vtx_t`, RGBA macro, `blt_raster_tri` decl)
- Modify: `host/blt_wire.h` (document the TRILIST header field mapping)
- Test: `refmodel/test_blitter_ref.c` (add a sizeof/asserts test)

**Interfaces:**
- Produces:
  - `#define BLT_OP_TRILIST 8`
  - `typedef struct { int16_t x, y; uint16_t u, v; uint32_t rgba; uint32_t _rsvd; } blt_vtx_t;` (16 bytes)
  - `#define BLT_RGBA(r,g,b,a) ((uint32_t)(uint8_t)(r) | ((uint32_t)(uint8_t)(g)<<8) | ((uint32_t)(uint8_t)(b)<<16) | ((uint32_t)(uint8_t)(a)<<24))`
  - `void blt_raster_tri(uint16_t *fb, const blt_surface_heap_t *heap, const blt_cmd_t *h, const blt_vtx_t *tris, int ntris);`
  - **TRILIST header field mapping** (into `blt_cmd_t`): `opcode`=BLT_OP_TRILIST; `blend_mode`=BLT_BLEND_*; `format`=BLT_FMT_* (texture page); `src_off`=tex page base offset; `src_stride`=tex row stride bytes; `src_x`=tex width (texels); `src_y`=tex height (texels); `w`=triangle count; `dst_x`=`entry_off & 0xFFFF`; `dst_y`=`(entry_off>>16) & 0xFFFF` (byte offset of the first vertex in the entry buffer); `colorkey`=RGB565 key (COLORKEY mode); `alpha`=global alpha (0..255, usually 255).

- [ ] **Step 1: Write the failing test** — append to `refmodel/test_blitter_ref.c`:
```c
static void test_trilist_layout(void){
    assert(sizeof(blt_vtx_t) == 16);
    assert(BLT_OP_TRILIST == 8);
    blt_vtx_t v = { .x=1, .y=2, .u=3, .v=4, .rgba=BLT_RGBA(10,20,30,40), ._rsvd=0 };
    assert((v.rgba & 0xff)==10 && ((v.rgba>>24)&0xff)==40);
    printf("test_trilist_layout OK\n");
}
```
Call `test_trilist_layout();` from `main()` in that file.
- [ ] **Step 2: Run to verify it fails** — Run: `cd refmodel && make test`. Expected: compile error (`BLT_OP_TRILIST` / `blt_vtx_t` undefined).
- [ ] **Step 3: Implement** — in `refmodel/blitter_ref.h`, immediately after the last `#define BLT_OP_*` line, add `#define BLT_OP_TRILIST 8`. Add the `BLT_RGBA` macro near the other pixel macros, the `blt_vtx_t` typedef after `blt_cmd_t`, and the `blt_raster_tri` forward declaration. In `host/blt_wire.h`, add a comment block documenting the header field mapping above.
- [ ] **Step 4: Run to verify it passes** — Run: `cd refmodel && make test`. Expected: `test_trilist_layout OK` and all existing tests still pass.
- [ ] **Step 5: Commit**
```bash
git add refmodel/blitter_ref.h host/blt_wire.h refmodel/test_blitter_ref.c
git commit -m "feat: define BLT_OP_TRILIST command and blt_vtx_t (16B)"
```

### Task B2: Reference triangle rasterizer (`blt_raster_tri`)

This is the golden spec. It must be deterministic and integer-only in its inside-test and interpolation so the RTL can match bit-exactly.

**Files:**
- Create: `refmodel/blt_tri.c`
- Create: `refmodel/blt_tri.h`
- Modify: `refmodel/Makefile` (add `blt_tri.c` to the objects/test build)
- Test: `refmodel/test_blt_tri.c`

**Interfaces:**
- Consumes: `blt_vtx_t`, `blt_cmd_t`, `blt_surface_heap_t`, `blt_blend565`, `blt_add565`, `blt_mul565`, `blt_tint565`, `BLT_FB_W`, `BLT_FB_H` (all from `blitter_ref.h`).
- Produces: `blt_raster_tri` (definition).

- [ ] **Step 1: Write the failing test** — `refmodel/test_blt_tri.c`:
```c
/* GPL-3.0 header (copy from a sibling refmodel file) */
#include "blitter_ref.h"
#include "blt_tri.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* 1x1 white RGB565 texture at heap offset 0, so texel modulate == vertex color. */
static blt_surface_heap_t mk_white_tex(uint8_t *mem){
    mem[0]=0xff; mem[1]=0xff;               /* RGB565 0xFFFF = white, little-endian */
    blt_surface_heap_t h; memset(&h,0,sizeof h); h.base=mem; return h;
}
static blt_cmd_t mk_hdr(uint8_t blend){
    blt_cmd_t c; memset(&c,0,sizeof c);
    c.opcode=BLT_OP_TRILIST; c.blend_mode=blend; c.format=BLT_FMT_RGB565;
    c.src_off=0; c.src_stride=2; c.src_x=1; c.src_y=1; c.alpha=255;
    return c;
}
#define V(px,py,cr,cg,cb,ca) (blt_vtx_t){ (int16_t)((px)<<4),(int16_t)((py)<<4),0,0, BLT_RGBA(cr,cg,cb,ca),0 }

static void test_solid_red_quad_copy(void){
    uint8_t tex[2]; blt_surface_heap_t heap = mk_white_tex(tex);
    uint16_t fb[BLT_FB_W*BLT_FB_H]; memset(fb,0,sizeof fb);
    blt_cmd_t h = mk_hdr(BLT_BLEND_COPY);
    /* axis-aligned 10x10 quad at (5,5), two tris, pure red */
    blt_vtx_t tris[6] = {
        V(5,5,255,0,0,255),  V(15,5,255,0,0,255),  V(15,15,255,0,0,255),
        V(5,5,255,0,0,255),  V(15,15,255,0,0,255), V(5,15,255,0,0,255),
    };
    blt_raster_tri(fb, &heap, &h, tris, 2);
    /* interior pixel (10,10) must be red 0xF800; a pixel outside (0,0) must be 0 */
    assert(fb[10*BLT_FB_W+10]==0xF800);
    assert(fb[0]==0x0000);
    /* pixel just outside the right edge (15,10) must NOT be filled (top-left rule, exclusive) */
    assert(fb[10*BLT_FB_W+15]==0x0000);
    printf("test_solid_red_quad_copy OK\n");
}

static void test_alpha_blend_half(void){
    uint8_t tex[2]; blt_surface_heap_t heap = mk_white_tex(tex);
    uint16_t fb[BLT_FB_W*BLT_FB_H];
    for(int i=0;i<BLT_FB_W*BLT_FB_H;i++) fb[i]=0x001F; /* blue background */
    blt_cmd_t h = mk_hdr(BLT_BLEND_CONST_ALPHA);
    blt_vtx_t tris[6] = {
        V(0,0,255,0,0,128),  V(20,0,255,0,0,128),  V(20,20,255,0,0,128),
        V(0,0,255,0,0,128),  V(20,20,255,0,0,128), V(0,20,255,0,0,128),
    };
    blt_raster_tri(fb, &heap, &h, tris, 2);
    uint16_t got = fb[10*BLT_FB_W+10];
    uint16_t expect = blt_blend565(0xF800, 0x001F, 128);
    assert(got==expect);
    printf("test_alpha_blend_half OK\n");
}

int main(void){ test_solid_red_quad_copy(); test_alpha_blend_half();
    printf("ALL blt_tri tests OK\n"); return 0; }
```
- [ ] **Step 2: Run to verify it fails** — Run: `cd refmodel && cc -I. -DBLT_FB_W=320 -DBLT_FB_H=240 blt_tri.c blitter_ref.c test_blt_tri.c -o /tmp/t_tri && /tmp/t_tri`. Expected: link error (`blt_raster_tri` undefined) — `blt_tri.c` is still empty.
- [ ] **Step 3: Implement** — `refmodel/blt_tri.h`:
```c
/* GPL-3.0 header */
#ifndef BLT_TRI_H
#define BLT_TRI_H
#include "blitter_ref.h"
void blt_raster_tri(uint16_t *fb, const blt_surface_heap_t *heap,
                    const blt_cmd_t *h, const blt_vtx_t *tris, int ntris);
#endif
```
`refmodel/blt_tri.c` — the full deterministic rasterizer (top-left rule, integer barycentric, round-to-nearest interpolation):
```c
/* GPL-3.0 header */
#include "blt_tri.h"
#include <stdint.h>

#define SUB 4
#define ONE (1<<SUB)
#define HALF (ONE>>1)

static int64_t edge(int64_t ax,int64_t ay,int64_t bx,int64_t by,int64_t cx,int64_t cy){
    return (bx-ax)*(cy-ay) - (by-ay)*(cx-ax);
}
/* round-to-nearest signed divide, den>0 */
static int64_t divr(int64_t num, int64_t den){
    return (num>=0) ? (num + den/2)/den : -(((-num) + den/2)/den);
}
/* top-left rule: an edge a->b is "inside" on E==0 iff it is a top or left edge */
static int top_left(int64_t ax,int64_t ay,int64_t bx,int64_t by){
    return (ay==by && bx<ax) /*top*/ || (by>ay) /*left*/;
}
static uint16_t tex_nearest(const blt_surface_heap_t *heap, const blt_cmd_t *h,
                            int u_fx, int v_fx){
    int tw=h->src_x, th=h->src_y;
    int tu=(u_fx+HALF)>>SUB, tv=(v_fx+HALF)>>SUB;
    if(tu<0)tu=0; else if(tu>=tw)tu=tw-1;
    if(tv<0)tv=0; else if(tv>=th)tv=th-1;
    const uint8_t *p = heap->base + h->src_off + (uint32_t)tv*h->src_stride + (uint32_t)tu*2u;
    return (uint16_t)(p[0] | (p[1]<<8));
}

void blt_raster_tri(uint16_t *fb, const blt_surface_heap_t *heap,
                    const blt_cmd_t *h, const blt_vtx_t *tris, int ntris){
    for(int t=0;t<ntris;t++){
        const blt_vtx_t *a=&tris[t*3+0], *b=&tris[t*3+1], *c=&tris[t*3+2];
        int64_t x0=a->x,y0=a->y, x1=b->x,y1=b->y, x2=c->x,y2=c->y;
        int64_t area = edge(x0,y0,x1,y1,x2,y2);
        if(area==0) continue;
        if(area<0){ const blt_vtx_t*tb2=b; b=c; c=tb2;
            int64_t tx=x1,ty=y1; x1=x2;y1=y2;x2=tx;y2=ty; area=-area; }
        int64_t lx = (x0<x1?(x0<x2?x0:x2):(x1<x2?x1:x2));
        int64_t hx = (x0>x1?(x0>x2?x0:x2):(x1>x2?x1:x2));
        int64_t ly = (y0<y1?(y0<y2?y0:y2):(y1<y2?y1:y2));
        int64_t hy = (y0>y1?(y0>y2?y0:y2):(y1>y2?y1:y2));
        int minx=(int)(lx>>SUB), maxx=(int)((hx+ONE-1)>>SUB);
        int miny=(int)(ly>>SUB), maxy=(int)((hy+ONE-1)>>SUB);
        if(minx<0)minx=0; if(miny<0)miny=0;
        if(maxx>=BLT_FB_W)maxx=BLT_FB_W-1; if(maxy>=BLT_FB_H)maxy=BLT_FB_H-1;
        int64_t bias0 = top_left(x1,y1,x2,y2)?0:-1; /* edge opposite vertex a (b->c) */
        int64_t bias1 = top_left(x2,y2,x0,y0)?0:-1; /* opposite b (c->a) */
        int64_t bias2 = top_left(x0,y0,x1,y1)?0:-1; /* opposite c (a->b) */
        for(int py=miny;py<=maxy;py++){
            int64_t sy=((int64_t)py<<SUB)|HALF;
            for(int px=minx;px<=maxx;px++){
                int64_t sx=((int64_t)px<<SUB)|HALF;
                int64_t w0=edge(x1,y1,x2,y2,sx,sy)+bias0;
                int64_t w1=edge(x2,y2,x0,y0,sx,sy)+bias1;
                int64_t w2=edge(x0,y0,x1,y1,sx,sy)+bias2;
                if(w0<0||w1<0||w2<0) continue;
                int u=(int)divr(w0*a->u + w1*b->u + w2*c->u, area);
                int v=(int)divr(w0*a->v + w1*b->v + w2*c->v, area);
                int cr=(int)divr(w0*(a->rgba&0xff)+w1*(b->rgba&0xff)+w2*(c->rgba&0xff),area);
                int cg=(int)divr(w0*((a->rgba>>8)&0xff)+w1*((b->rgba>>8)&0xff)+w2*((c->rgba>>8)&0xff),area);
                int cb=(int)divr(w0*((a->rgba>>16)&0xff)+w1*((b->rgba>>16)&0xff)+w2*((c->rgba>>16)&0xff),area);
                int ca=(int)divr(w0*((a->rgba>>24)&0xff)+w1*((b->rgba>>24)&0xff)+w2*((c->rgba>>24)&0xff),area);
                uint16_t texel=tex_nearest(heap,h,u,v);
                uint16_t src=blt_tint565(texel,(uint8_t)cr,(uint8_t)cg,(uint8_t)cb);
                uint16_t *dp=&fb[py*BLT_FB_W+px];
                int ea=(ca*h->alpha)/255;
                switch(h->blend_mode){
                  case BLT_BLEND_COPY:        *dp=src; break;
                  case BLT_BLEND_CONST_ALPHA: *dp=blt_blend565(src,*dp,(uint8_t)ea); break;
                  case BLT_BLEND_ADD:         *dp=blt_add565(src,*dp); break;
                  case BLT_BLEND_MULTIPLY:    *dp=blt_mul565(src,*dp); break;
                  case BLT_BLEND_COLORKEY:    if(texel!=h->colorkey)*dp=src; break;
                  default:                    *dp=src; break;
                }
            }
        }
    }
}
```
> **Note for the implementer:** verify the exact signatures of `blt_blend565`/`blt_tint565`/`blt_add565`/`blt_mul565` and the `blt_surface_heap_t` member name (`base` vs other) in `refmodel/blitter_ref.h`, and adapt the calls if they differ. The blend helpers already define the repo's canonical rounding — do not reimplement them.
- [ ] **Step 4: Run to verify it passes** — Run: `cd refmodel && cc -I. -DBLT_FB_W=320 -DBLT_FB_H=240 blt_tri.c blitter_ref.c test_blt_tri.c -o /tmp/t_tri && /tmp/t_tri`. Expected: `ALL blt_tri tests OK`.
- [ ] **Step 5:** Wire `blt_tri.c` + `test_blt_tri` into `refmodel/Makefile` so `make test` builds and runs it. Run `cd refmodel && make test`; expected: the new test runs green alongside existing ones.
- [ ] **Step 6: Commit**
```bash
git add refmodel/blt_tri.c refmodel/blt_tri.h refmodel/test_blt_tri.c refmodel/Makefile
git commit -m "feat: reference textured-triangle rasterizer (blt_raster_tri)"
```

### Task B3: Dispatch `BLT_OP_TRILIST` from `blt_execute`

**Files:**
- Modify: `refmodel/blitter_ref.c` (add the `BLT_OP_TRILIST` case to `blt_execute`)
- Test: `refmodel/test_blt_tri.c` (add an end-to-end display-list test)

**Interfaces:**
- Consumes: `blt_raster_tri`; the same entry-buffer resolution mechanism `blt_execute` already uses for `BLT_OP_TILELIST_RES`.
- Produces: `blt_execute` now renders TRILIST commands. The entry buffer base is threaded into `blt_execute` the same way the tile-list entry buffer already is — **confirm by reading the existing `BLT_OP_TILELIST_RES` case and mirror it exactly.**

- [ ] **Step 1: Write the failing test** — add to `refmodel/test_blt_tri.c` a test that builds a `blt_cmd_t[]` with one TRILIST header whose `dst_x/dst_y` encode `entry_off=0`, places two triangles in an entry buffer, calls `blt_execute(fb, &heap, cmds, 1)` (matching the existing signature, including however the entry buffer is passed), and asserts the same interior-pixel result as `test_solid_red_quad_copy`. Name it `test_trilist_via_execute`.
- [ ] **Step 2: Run to verify it fails** — Run: `cd refmodel && make test`. Expected: FAIL — `blt_execute` ignores opcode 8, interior pixel stays 0.
- [ ] **Step 3: Implement** — in `refmodel/blitter_ref.c`, add to the `blt_execute` opcode switch:
```c
case BLT_OP_TRILIST: {
    uint32_t entry_off = (uint32_t)(uint16_t)cmd->dst_x
                       | ((uint32_t)(uint16_t)cmd->dst_y << 16);
    const blt_vtx_t *tris = (const blt_vtx_t *)(ENTRY_BUF_BASE + entry_off);
    blt_raster_tri(fb, heap, cmd, tris, (int)cmd->w);
    break;
}
```
Replace `ENTRY_BUF_BASE` with the exact expression the existing `BLT_OP_TILELIST_RES` case uses to reach the entry buffer.
- [ ] **Step 4: Run to verify it passes** — Run: `cd refmodel && make test`. Expected: `test_trilist_via_execute OK`, all green.
- [ ] **Step 5: Commit**
```bash
git add refmodel/blitter_ref.c refmodel/test_blt_tri.c
git commit -m "feat: dispatch BLT_OP_TRILIST in blt_execute"
```

### Task B4: Emitter — vertex buffer + `blt_trilist()`

**Files:**
- Modify: `host/blt_emitter.h` (add `vtx_buf`/`vtx_cap`/`vtx_used` to `blt_emitter_t`; declare `blt_vtx_buf_init`, `blt_push_tris`, `blt_trilist`)
- Modify: `host/blt_emitter.c` (implement them; reset `vtx_used` in `blt_begin_frame`)
- Test: `host/test_emitter.c` (or the existing emitter test file)

**Interfaces:**
- Consumes: `blt_emitter_t`, `blt_surface_ref_t`, the ring-append helper the emitter already uses for header commands, `blt_execute`.
- Produces:
  - `void blt_vtx_buf_init(blt_emitter_t *e, void *vtx_buf, size_t vtx_cap);`
  - `uint32_t blt_push_tris(blt_emitter_t *e, const blt_vtx_t *tris, int ntris);` — bump-appends `ntris*3` vertices to `vtx_buf`, returns the byte offset of the first vertex (the `entry_off`). Returns `0xFFFFFFFF` on overflow.
  - `int blt_trilist(blt_emitter_t *e, blt_surface_ref_t tex, uint8_t blend, uint16_t colorkey, uint8_t alpha, uint32_t entry_off, int ntris);` — emits one TRILIST header into the ring using the field mapping from Task B1. Returns 0 on success, non-zero on ring overflow.

- [ ] **Step 1: Write the failing test** — in the emitter test, init an emitter with a ring + heap + a `vtx_buf`, upload a 1×1 white texture via `blt_upload`, `blt_push_tris` the two-triangle red quad from Task B2, `blt_trilist(...)`, then run the emitted ring through `blt_execute` into a fresh FB and assert `fb[10*BLT_FB_W+10]==0xF800`. Name it `test_emit_trilist_roundtrip`.
- [ ] **Step 2: Run to verify it fails** — Run: `cd host && make test`. Expected: compile error (functions undeclared).
- [ ] **Step 3: Implement** — add the three fields to `blt_emitter_t`; implement `blt_vtx_buf_init` (store ptr/cap, zero `vtx_used`), `blt_push_tris` (bounds-check against `vtx_cap`, `memcpy`, advance `vtx_used`, return old offset), `blt_trilist` (populate a `blt_cmd_t` per the Task B1 mapping and append it via the existing ring-append helper). In `blt_begin_frame`, add `e->vtx_used = 0;` next to the existing `tl_used = 0;` reset.
- [ ] **Step 4: Run to verify it passes** — Run: `cd host && make test`. Expected: `test_emit_trilist_roundtrip OK`, all green.
- [ ] **Step 5: Commit**
```bash
git add host/blt_emitter.h host/blt_emitter.c host/test_emitter.c
git commit -m "feat: emitter vertex buffer + blt_trilist()"
```

### Task B5: RTL — `blt_tri` rasterizer module + sim scenario

The acceptance test is a **bit-exact sim diff against the refmodel**, following the existing `sim/` convention. Full SystemVerilog is written by the implementer to match `blt_raster_tri`; this task specifies the module interface, the algorithm to mirror, the scenario wiring, and the pass gate.

**Files:**
- Create: `rtl/blt_tri.sv` (raster datapath, instantiated by `blitter_top`)
- Modify: `rtl/blitter_top.sv` (decode `BLT_OP_TRILIST`; fetch header + vertices; drive `blt_tri`; write blended pixels to the FB via the existing FB write port)
- Modify: `sim/gen_vectors.c` (add `tri` scenarios: reuse the refmodel to produce `fb_expected.hex`)
- Modify: `sim/tb_blitter.sv` (add the `tri` scenario names to the scenario table)
- Modify: `sim/Makefile` if scenario lists are enumerated there

**Interfaces:**
- Consumes: the ring/entry-buffer read ports and FB write port already present in `blitter_top`; the DDR/heap model in `sim/`.
- Produces: RTL that renders `BLT_OP_TRILIST` identically to `blt_raster_tri`.
- **Algorithm to mirror (must match refmodel exactly):** integer edge functions in 12.4; CCW-normalize (swap b,c if area<0); pixel-center sampling at `(px<<4)|8`; top-left rule via the `-1` bias on non-top-left edges; inside iff all three biased edges ≥ 0; per-attribute interpolation `divr(w0*A0+w1*A1+w2*A2, area)` with round-to-nearest (`divr` in Task B2); nearest texel with clamp; the same blend-mode switch reusing the existing RTL blend functions used by `BLT_OP_BLIT`.

- [ ] **Step 1: Add the failing sim scenario** — in `sim/gen_vectors.c`, add scenarios `tri_copy` and `tri_alpha` mirroring the two Task B2 tests: build the same display list (header + entry buffer), write the DDR/heap init hex, and produce `fb_expected.hex` by calling `blt_execute` (the refmodel is already linked into `gen_vectors`). Add both names wherever `tb_blitter.sv` enumerates scenarios.
- [ ] **Step 2: Run to verify it fails** — Run: `cd sim && make test`. Expected: the `tri_copy`/`tri_alpha` scenarios print `RESULT: FAIL` (RTL doesn't yet decode opcode 8, so the FB stays cleared and mismatches `fb_expected.hex`).
- [ ] **Step 3: Implement the RTL** — write `rtl/blt_tri.sv` implementing the algorithm above; instantiate and wire it into `rtl/blitter_top.sv` under a new `BLT_OP_TRILIST` decode branch (header fetch → vertex fetch from the entry buffer at `entry_off` → per-pixel datapath → FB write). Keep the FB write port and blend functions shared with the existing blit path (DRY).
- [ ] **Step 4: Run to verify it passes** — Run: `cd sim && make test`. Expected: `tri_copy` and `tri_alpha` both print `RESULT: PASS`, and every pre-existing scenario still passes.
- [ ] **Step 5: Commit**
```bash
git add rtl/blt_tri.sv rtl/blitter_top.sv sim/gen_vectors.c sim/tb_blitter.sv sim/Makefile
git commit -m "feat: RTL BLT_OP_TRILIST rasterizer, bit-exact vs refmodel"
```

### Task B6: Coverage scenarios — rotation, overlap, textured, clip

Locks correctness on the cases GM actually produces. Each is a refmodel golden + RTL sim diff.

**Files:**
- Modify: `refmodel/test_blt_tri.c` (add golden assertions)
- Modify: `sim/gen_vectors.c`, `sim/tb_blitter.sv` (add matching scenarios)

**Interfaces:** consumes everything from B2–B5. Produces no new API — only tests.

- [ ] **Step 1: Add refmodel golden tests** — add to `test_blt_tri.c`: (a) `test_rotated_quad` — a 45°-rotated textured quad using a 4×4 checkerboard texture (build it in the heap), asserting a handful of known interior/edge texel results; (b) `test_overlap_order` — two overlapping alpha quads, asserting the overlap pixel equals sequential-blend of both; (c) `test_offscreen_clip` — a triangle straddling the left edge (negative X), asserting no out-of-bounds write and correct edge pixels; (d) `test_additive` — `BLT_BLEND_ADD` two quads, asserting saturating add at the overlap.
- [ ] **Step 2: Run to verify** — Run: `cd refmodel && make test`. Expected: all four new tests pass (they define the goldens).
- [ ] **Step 3: Mirror as sim scenarios** — add `tri_rot`, `tri_overlap`, `tri_clip`, `tri_add` to `sim/gen_vectors.c` + `sim/tb_blitter.sv`, each producing `fb_expected.hex` from the refmodel.
- [ ] **Step 4: Run to verify RTL matches** — Run: `cd sim && make test`. Expected: all four print `RESULT: PASS`. Fix RTL rounding/clip until they do — the sim diff is the arbiter.
- [ ] **Step 5: Commit**
```bash
git add refmodel/test_blt_tri.c sim/gen_vectors.c sim/tb_blitter.sv
git commit -m "test: TRILIST coverage — rotation, overlap, clip, additive"
```

---

## Part C — A9 geometry front-end (`libmfgpu`)

New host library. It transforms GM batches into `BLT_OP_TRILIST` display lists via the Part B emitter. Fully host-testable end-to-end (batch → libmfgpu → emitter → `blt_execute` → golden framebuffer).

### Task C1: `libmfgpu` skeleton + batch schema

**Files:**
- Create: `libmfgpu/mfgpu.h` (public API + `mfgpu_batch_t`, `mfgpu_in_vtx_t`)
- Create: `libmfgpu/mfgpu.c` (context init/frame lifecycle)
- Create: `libmfgpu/Makefile` (build + test; link against `../host` and `../refmodel`)
- Test: `libmfgpu/test_mfgpu.c`

**Interfaces:**
- Produces:
```c
typedef struct { float x, y, z, u, v; uint32_t rgba; } mfgpu_in_vtx_t; /* GM-batch vertex, model space; u,v normalized 0..1 page coords */
typedef struct {
    const mfgpu_in_vtx_t *verts; int nverts;
    const uint16_t *indices; int nindices;   /* NULL => sequential triangles */
    float mvp[16];                            /* column-major 4x4 (GLES convention) */
    uint32_t tex_off; uint16_t tex_w, tex_h, tex_stride; uint8_t tex_format;
    uint8_t blend;                            /* BLT_BLEND_* */
    int screen_w, screen_h;                   /* viewport, for cull + NDC->screen */
} mfgpu_batch_t;
typedef struct mfgpu_ctx mfgpu_t;
mfgpu_t *mfgpu_create(blt_emitter_t *e);
void     mfgpu_frame_begin(mfgpu_t *m);
int      mfgpu_submit_batch(mfgpu_t *m, const mfgpu_batch_t *b);  /* 0 = ok */
void     mfgpu_frame_end(mfgpu_t *m);
void     mfgpu_destroy(mfgpu_t *m);
```
> `mfgpu_batch_t` is the **contract with the future interceptor** (Phase 0 Task A3). If A3 finds a field is unavailable at the chosen boundary, reconcile here before Part C proceeds.

- [ ] **Step 1: Write the failing test** — `libmfgpu/test_mfgpu.c` that `#include "mfgpu.h"`, calls `mfgpu_create`/`mfgpu_frame_begin`/`mfgpu_frame_end`/`mfgpu_destroy` and asserts non-NULL context. (Compiles-and-links smoke test.)
- [ ] **Step 2: Run to verify it fails** — Run: `cd libmfgpu && make test`. Expected: undefined references.
- [ ] **Step 3: Implement** — the header above; `mfgpu_ctx` holds the `blt_emitter_t*`; lifecycle functions forward to `blt_begin_frame`/`blt_end_frame`. `mfgpu_submit_batch` returns 0 and does nothing yet (filled in C2/C3). Write the `Makefile` mirroring `host/Makefile`, adding `-I../host -I../refmodel` and the needed objects.
- [ ] **Step 4: Run to verify it passes** — Run: `cd libmfgpu && make test`. Expected: smoke test passes.
- [ ] **Step 5: Commit**
```bash
git add libmfgpu/mfgpu.h libmfgpu/mfgpu.c libmfgpu/Makefile libmfgpu/test_mfgpu.c
git commit -m "feat: libmfgpu skeleton + mfgpu_batch_t schema"
```

### Task C2: Vertex transform (MVP → screen-space 12.4)

**Files:**
- Create: `libmfgpu/mfgpu_xform.h`, `libmfgpu/mfgpu_xform.c`
- Modify: `libmfgpu/Makefile`
- Test: `libmfgpu/test_xform.c`

**Interfaces:**
- Produces: `void mfgpu_xform_vtx(const float mvp[16], const mfgpu_in_vtx_t *in, blt_vtx_t *out, int screen_w, int screen_h, uint16_t tex_w, uint16_t tex_h);` — applies the column-major MVP, performs the perspective divide (`w`), maps NDC `[-1,1]` → screen `[0,screen_w]×[0,screen_h]` with Y flip (GLES Y-up → framebuffer Y-down), rounds to 12.4; converts normalized UV → 12.4 texel coords (`u*tex_w`, `v*tex_h`); copies `rgba`.

- [ ] **Step 1: Write the failing test** — assert three known transforms: (a) identity MVP, a vertex at NDC (−1,−1) with a 320×240 viewport → screen (0, 240) in 12.4 (i.e. `out.x==0`, `out.y==240<<4`); (b) NDC (0,0) → screen center (160<<4, 120<<4); (c) UV (0.5,0.25) with tex 64×64 → `out.u==(32<<4)`, `out.v==(16<<4)`.
- [ ] **Step 2: Run to verify it fails** — Run: `cd libmfgpu && make test`. Expected: undefined reference / assertion fail.
- [ ] **Step 3: Implement** — the matrix×vector (column-major: `clip.x = m[0]*x+m[4]*y+m[8]*z+m[12]`, etc.), perspective divide by `clip.w` (guard `w==0`), NDC→screen with Y-flip, `lround(coord*16)` into `int16_t`, UV→texel `lround(u*tex_w*16)`. Provide a scalar implementation; a NEON path may be added later behind the same signature (out of scope here).
- [ ] **Step 4: Run to verify it passes** — Run: `cd libmfgpu && make test`. Expected: all three transform cases pass.
- [ ] **Step 5: Commit**
```bash
git add libmfgpu/mfgpu_xform.h libmfgpu/mfgpu_xform.c libmfgpu/test_xform.c libmfgpu/Makefile
git commit -m "feat: libmfgpu vertex transform (MVP -> screen 12.4)"
```

### Task C3: Batch assembly + cull → display list (end-to-end golden)

**Files:**
- Modify: `libmfgpu/mfgpu.c` (implement `mfgpu_submit_batch`)
- Test: `libmfgpu/test_mfgpu.c` (add the end-to-end golden)

**Interfaces:**
- Consumes: `mfgpu_xform_vtx`, `blt_push_tris`, `blt_trilist`, `blt_execute`.
- Produces: `mfgpu_submit_batch` — transforms all vertices, assembles triangles (indexed or sequential), **culls** triangles fully outside `[0,screen_w]×[0,screen_h]` (2D bbox test) and back-faces/degenerates (zero area), pushes surviving triangles via `blt_push_tris`, emits one `blt_trilist` header per batch.

- [ ] **Step 1: Write the failing test** — build an identity-MVP batch of one textured quad (2 tris, 4 verts + indices) over a 1×1 white texture uploaded via the emitter; `mfgpu_frame_begin` → `mfgpu_submit_batch` → `mfgpu_frame_end`; run the emitter's ring through `blt_execute`; assert the quad's interior pixel is the vertex color. Add a second case: a batch entirely off-screen (all verts at NDC > 1) emits **zero** triangles (assert `vtx_used` unchanged / FB untouched).
- [ ] **Step 2: Run to verify it fails** — Run: `cd libmfgpu && make test`. Expected: FAIL — `mfgpu_submit_batch` is still a no-op, interior pixel stays 0.
- [ ] **Step 3: Implement** — `mfgpu_submit_batch`: allocate a temp `blt_vtx_t` array (`nverts`), `mfgpu_xform_vtx` each; iterate triangles (indices or sequential triples); for each, bbox-cull against the viewport and skip zero-area; append survivors to a scratch tri array; if any survive, `blt_push_tris` + `blt_trilist` with the batch's tex/blend. Free scratch.
- [ ] **Step 4: Run to verify it passes** — Run: `cd libmfgpu && make test`. Expected: both cases pass — the on-screen quad renders, the off-screen batch emits nothing.
- [ ] **Step 5: Commit**
```bash
git add libmfgpu/mfgpu.c libmfgpu/test_mfgpu.c
git commit -m "feat: libmfgpu batch assembly + cull -> TRILIST display list"
```

---

## Follow-on (NOT in this plan)

These depend on Phase-0 findings and hardware bring-up, and get their own plan once Part A + Part B + Part C are green:

- **Phase 1c — GM interceptor:** wire the boundary chosen in Task A3 (GLES2 interposer or batch-flush hook) in `gmloader-next` to build `mfgpu_batch_t` and call `mfgpu_submit_batch`.
- **Phase 1d — RBF + hardware bring-up:** synthesize `blt_tri.sv` into the core, wire scanout through `video_mixer`/ascal, run Maldita on hardware, measure fps vs the Task A1 baseline, mandatory visual check on analog + HDMI, keep the CI timing gate green.

---

## Self-Review

**1. Spec coverage** (against `2026-07-12-mfgpu-gles-fpga-renderer-design.md`):
- Decision 1 (fixed-function 2D, software fallback): fixed-function path = Part B/C; fallback classification seeded by Task A4; fallback *implementation* is a Phase-2/follow-on concern (correctly deferred). ✓
- Decision 2 (staged intercept): Part A3 pins it; interceptor is the follow-on plan. ✓
- Decision 3 (Maldita canary): Tasks A1–A4, and the follow-on 1d. ✓
- Decision 4 (on-chip 320×240, scaler upscale): Global Constraints + A2; scanout wiring is follow-on 1d. ✓
- Decision 5 (A9 front-end / fabric back-end): Part C (front-end) + Part B (back-end). ✓
- Command protocol (§5): Task B1 (header mapping), B4 (emit). ✓
- Data flow (§6): B (fabric) + C (A9) cover steps 3–4; steps 1–2 (runner→batch) = follow-on interceptor. ✓
- Testing strategy (§8): unit (B2/B4/C2), golden-image (B6), integration (C3), refmodel↔RTL diff (B5/B6); end-to-end-on-HW = follow-on 1d. ✓
- Risks (§10): R1 → A3; R2 → A2; R4 → A4; R3/R5/R6 → follow-on 1d (hardware). ✓

**2. Placeholder scan:** No TBD/TODO/"add error handling". The two intentional "confirm exact signature / mirror the existing case" notes (B2 blend helpers, B3 entry-buffer base) point at named existing code the implementer reads — not vague instructions. RTL (B5) gives a precise algorithm + bit-exact sim gate rather than full SV, per the repo's refmodel-is-spec convention.

**3. Type consistency:** `blt_vtx_t` (16B, B1) used identically in B2/B3/B4/C2/C3. `blt_trilist`/`blt_push_tris`/`blt_vtx_buf_init` signatures defined in B4, consumed in C3. `mfgpu_batch_t`/`mfgpu_in_vtx_t`/`mfgpu_xform_vtx`/`mfgpu_submit_batch` defined in C1/C2, consumed in C3. TRILIST header field mapping defined once (B1) and reused (B4 emit, B3 decode, B5 RTL decode). `entry_off` packed into `dst_x`/`dst_y` consistently in B1/B3/B4. ✓

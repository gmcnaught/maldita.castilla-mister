# Maldita Core — TRILIST Fabric Rasterizer (Phase 1d) Design

**Date:** 2026-07-14
**Repos:** `maldita.castilla-mister` (core RTL — the bulk) + `gmloader-next` (opcode renumber, STAGE emission co-requisite)
**Status:** approved (design), pending implementation plan
**Supplements / corrects:** `2026-07-14-maldita-fabric-offload-design.md` — specifically its false premise that *"the contract already matches — the core decodes `OP_TRILIST`."* It does not; this spec is the missing core-RTL task that offload plan assumed away.

## Context — the premise that broke

The fabric-offload design assumed the Maldita core's `blitter_top` already
rasterizes `OP_TRILIST` into `comp_fbram`, so its Task 5 called the core work
"minimal, timing only." Root-cause investigation (2026-07-14) disproved this:

- There are **two divergent forks of `blitter_top.sv`**. The gmloader/mfgpu one
  (`3rdparty/mfgpu`, 524-line spike) has `OP_TRILIST=8` + a `blt_tri` rasterizer
  but no SDRAM/on-chip-FB. The **device** Solarus/Maldita one (1224 lines) has
  STAGE/SDRAM/`comp_fbram` but **no triangle rasterizer at all**.
- On the device, **opcode 8 = `OP_BGPLANE_WRITE`**, so the probe's `OP_TRILIST=8`
  was silently decoded as a plane-bake — it never touched the framebuffer, hence
  the uniform-blue screen (`C_DONE=1`, `C_STATUS=0`).
- `blt_tri.sv` was written upstream in `mister-fpga-blitter` and **never
  back-ported / wired into the Maldita core.**

The strategy (fabric = GPU; TRILIST → `comp_fbram` → scanout; STAGE textures to
SDRAM) is unchanged and correct. This spec covers **wiring a first-class,
perf-optimal triangle rasterizer into the Maldita `blitter_top`.**

## Target & workload (the exact feature surface — no more)

Target game: **Maldita Castilla** (GameMaker) via gmloader. Measured workload
(`backend_mfgpu` + `GMLOADER_DRAW_TRACE`):

- **~4–5 draws/frame, all `GL_TRIANGLES`, textured quads (2 tris each) ⇒ ~10
  triangles/frame.** 320×240 = 76,800 px. Backend hard caps (≤~2730 tris, ≤2048
  cmds) are far above real frames.
- **Blend modes emitted:** `COPY`, `CONST_ALPHA` (rides per-vertex alpha),
  `ADD`, and `COLORKEY` (1-bit cutout for palette sprites). **Not** used: PALPHA,
  MULTIPLY, command-tint (`BLT_F_COLORMOD`).
- **Textures:** always **RGB565**, nearest, no per-texel alpha. Vertex color
  modulates the texel (`blt_tint565`). Untextured draws use a 1×1 white page.

**Budget (`blitter-feasibility.md`):** 1 px/clk @100 MHz ≈ 7.7 ms/full-frame;
4 px/clk ≈ 1.9 ms; DDR bandwidth 3×+ headroom. So **60 fps is comfortably
reachable at 1 px/clk *on-chip*** for this workload. "Perf-optimal" here means
**eliminating the spike's per-pixel DDR round-trips** (44–66% of cycles per
`lessons-learned.md`), NOT SIMD. 4 px/clk would be over-engineering (YAGNI).
The real risks are timing-closure of triangle setup and hiding SDRAM texel
latency — not throughput. **Target 60 fps, hard floor 30 fps.**

## Architecture

```
OP_TRILIST(10)
  └─▶ VERTEX FETCH  (DDR master — free; comp_pipeline retired it)
        └─▶ SETUP (once/triangle): edge coeffs, 1/area reciprocal,
                   attribute gradients (du/dx,dv/dx,dr/dx… + per-row steps)
              └─▶ EDGE-WALK (incremental, ~1 px/clk): per covered pixel emit
                    (u,v) + interpolated (r,g,b,a); bbox/span traversal
                    ├─▶ TEXEL: SDRAM P_SRC read (sdram_fb_cache), nearest
                    └─▶ BLEND: blt_tri blend core (kept literally) — texel×vtx
                          tint → COPY/KEY/CALPHA/ADD
                          └─▶ comp_fbram RMW → vblank snapshot → scanout
```

### Component 1 — Triangle front-end (NEW; the perf content)

Replaces `blt_tri.sv`'s per-pixel coverage/interpolation — which recomputes 3×
64-bit edge functions + **six divides by area per pixel** (`blt_tri.sv:98-110`,
the sim-equivalence model) — with an **incremental edge-walk**:

- **Setup (once/triangle):** signed area (CCW-normalize), **`1/area` reciprocal**
  (fixed-point), the three edge functions' `dw/dx`,`dw/dy`, and attribute
  gradients for `u,v,r,g,b,a`. This moves the only divides out of the per-pixel
  path.
- **Walk:** bbox scan with incremental `w0/w1/w2 += dwdx` per x-step and `+= dwdy`
  per row; coverage = all `w≥0` (top-left rule preserved). Interpolated
  attributes stepped by adds; `u,v` = attribute×`1/area` via multiply (no divide).
- **Interface:** consumes decoded `c_*` (tex base/stride/w/h, blend, colorkey,
  alpha) + fetched vertices; emits a per-pixel stream `{px,py,u,v,r,g,b,a,valid}`.
- **Verification:** **±1 LSB against `blt_tri.c`** golden (the project's accepted
  tolerance). `blt_tri.sv`/`blt_tri.c` remain the golden oracle; the six existing
  RTL sim scenarios (`tri_copy/alpha/overlap/add/clip/rot`) are the base battery,
  extended for the incremental path.

### Component 2 — Texel fetch (REUSE the device source path)

- Read texels from **SDRAM via the `P_SRC` port** (`sdram_fb_cache` ch5), the same
  source path `comp_pipeline` uses — keeping texel traffic **off the f2h bus**.
- Access is a **scattered (u,v) gather**, not a contiguous row, so
  `comp_src_linebuf` (row-oriented) is a weak fit. Default: **per-pixel `P_SRC`
  reads** (64-bit beat = 4 texels), latency hidden by `sdram_fb_cache`'s own
  caching (spatially-coherent samples mostly hit) + front-end pipelining. Revisit
  a small texel cache only if profiling demands.
- **Requires STAGE:** textures must be SDRAM-resident, so `backend_mfgpu` must emit
  `BLT_OP_STAGE` (the offload plan's Task 3) — a **hard co-requisite** landing with
  this path. (Today `backend_mfgpu` keeps textures in the DDR heap and emits no
  STAGE; that is the current gap, not the target.)

### Component 3 — Blend (KEEP blt_tri's blend; evaluate comp_mixer)

- Keep `blt_tri.sv`'s combinational **blend core** (`:121-148`: texel×interpolated
  vtx-color tint → COPY/KEY/CALPHA/ADD) — cheap, and **golden-exact by
  construction** (it *is* `blt_tri.c`'s blend), so the host oracle stays valid with
  zero refmodel divergence.
- **`comp_mixer` reuse is gated on an early equivalence spike:** prove
  `comp_mixer` is **±1 LSB equivalent** to `blt_tri.c`'s blend over the 4 used
  modes; if it holds, switch blend to `comp_mixer` and delete the duplicate; else
  keep `blt_tri` blend. Do not adopt `comp_mixer` blind — it would move the oracle.

### Component 4 — Destination + bus integration (REUSE + mux)

- Composite into on-chip **`comp_fbram`** via its RMW port (single-word, 4 px/qword,
  1-cycle read latency; addr `y*80+(x>>2)`, lane `x[1:0]`), then the existing vblank
  WORK→SCAN snapshot scans it out. No per-pixel DDR.
- The triangle FSM is a **third bus owner** (`tri_busy`, mirroring `pipe_busy`
  bookkeeping): add it at the mux points — DDR `mem_*` (`blitter_top.sv:1196`),
  `P_SRC` `p0_*` (`:1207`), `comp_fbram` read 3-way→4-way (`:1181`), and a **new
  `fb_wr` write mux** (`:1065`, currently comp_pipeline-only). One op runs at a time
  (ring is serial), so this is arbitration, not concurrency.
- **Vertex fetch** uses the DDR master (`comp_pipeline` retired it). Vertices are
  low-volume (~60 qwords/frame); single-beat or a small burst — not perf-critical.

## Opcode renumber & ABI (8 → 10)

Device opcodes 0–9 are taken; `OP_TRILIST` moves to **10**. gmloader's consumer
never hardcodes `8` (uses the `BLT_OP_*` symbol), so the change is symbol-clean:

1. `mister-fpga-blitter/refmodel/blitter_ref.h:88` — canonical enum → 10.
2. `mister-fpga-blitter/rtl/blitter_top.sv:66` — device localparam (context; the
   *Maldita* device decode is what actually ships).
3. `mister-fpga-blitter/refmodel/test_blitter_ref.c:223` + `docs/.../plans/2026-07-13-mfgpu-phase0-1-core.md:103` — `==8` asserts → 10.
4. `mister-fpga-blitter/host/blt_wire.h:97` — wire-doc comment.

Maldita `blitter_defs.vh`/`blitter_top.sv` decode gains an `OP_TRILIST=10` branch
dispatching to the new `S_TRI_*` states; the TRILIST header reuses the existing
`dst_x|dst_y<<16 = vertex byte offset`, `w = tri count` convention.

## Scope change — remove the 5 Castilla ops (this change)

Maldita is repurposed as the **gmloader/GLES GPU only**; the Solarus-engine ops are
vestigial fork baggage never emitted by gmloader. Remove, in this change:
`OP_TILELIST(5)`, `OP_TILELIST_RES(6)`, `OP_FRT_UPLOAD(7)`, `OP_BGPLANE_WRITE(8)`,
`OP_CLUT_UPLOAD(9)` — their `S_*` FSMs, decode branches, and any now-dead support
modules (FRT/CFT/CLUT BRAMs, bgplane bake). Keep the shared render datapath used by
FILL/STAGE/TRILIST (`comp_pipeline`/`comp_mixer`/`comp_fbram`/`sdram_fb_cache`
ch1 STAGE + ch5 P_SRC).

`OP_BLIT(3)` is **retained** even though gmloader emits only FILL+TRILIST(+STAGE):
it is the *same* `comp_pipeline` rectangular-composite datapath that the required
`OP_FILL` already needs, so its decode branch is a one-liner that costs effectively
nothing and preserves a general rect-blit primitive. (Drop it too only if strict
minimality is later wanted.) Net final opcode set: `NOP,END,FILL,BLIT,STAGE,TRILIST`.

## Verification

- **Simunit:** extend the RTL-vs-C bit-exact harness (`tb_blitter`, `gen_vectors`)
  with the incremental front-end; the six `tri_*` scenarios pass **±1 LSB vs
  `blt_tri.c`** (front-end may diverge from the divide-model within 1 LSB; goldens
  regenerated accordingly). Add textured-quad + COLORKEY + CONST_ALPHA(vtx-alpha) +
  ADD scenarios matching the gmloader modes.
- **Host oracle:** `raster-backend-test` stays ±1 LSB (unaffected by the RTL if
  blt_tri blend is kept; if comp_mixer is adopted, the refmodel is updated first).
- **On device:** first-slice single textured triangle, then a Maldita scene, via
  the offload plan's device present + MiSTer Remote capture.
- **Perf:** `GMLOADER_DRAW_TRACE` frame time and/or fabric busy counters confirm
  ≥30 fps (target 60).

## Risks

- **Timing closure of the reciprocal/setup** — mitigate with a pipelined/iterative
  divider amortized once per triangle (~10/frame, negligible).
- **SDRAM texel latency stalls** — mitigate via `sdram_fb_cache` hits + pipelining;
  fall back to a small texel cache only if measured.
- **Incremental vs divide-model rounding** — bounded to ±1 LSB by design; verified.
- **Castilla-op removal regressing the shared datapath** — the removed FSMs are
  peers of the shared core; delete FSMs/decode only, keep `comp_*`/`sdram_fb_cache`.

## Out of scope

- gmloader-side offload plumbing beyond STAGE emission (offload plan Tasks 2,4,5).
- 320×224 scanout timing (offload plan Task 5).
- The #13 heap-corruption crash.
- 4 px/clk SIMD / bilinear / PALPHA / MULTIPLY / ARGB4444 / PAL8 (unused by GM path).

## Success criteria

1. Maldita `blitter_top` decodes `OP_TRILIST=10` and rasterizes textured triangles
   into `comp_fbram`, ±1 LSB vs `blt_tri.c` in simunit over all `tri_*` + gmloader
   -mode scenarios.
2. Texels sampled from SDRAM (STAGE-resident); no per-pixel f2h texel/dst traffic.
3. The 5 Castilla ops removed; final op set `NOP,END,FILL,BLIT,STAGE,TRILIST`;
   RBF builds green on the Windows Quartus CI with clean STA.
4. On device: a fabric-rendered Maldita triangle/scene at ≥30 fps (target 60).

## Open questions for the plan

- Reciprocal precision/format for `1/area` that keeps interpolation ±1 LSB.
- Exact `S_TRI_*` state encoding and the 4th `fb_wr` mux insertion.
- Whether the `comp_mixer` equivalence spike collapses blend to `comp_mixer`.
- Vertex-buffer DDR location under the removed-ops opcode map (reuse SRC-heap-
  relative offset as the spike does, or a dedicated region).

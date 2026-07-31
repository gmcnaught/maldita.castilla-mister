# MFGPU — An FPGA GLES Renderer for a 32-bit gmloader Engine on MiSTer

**Date:** 2026-07-12
**Status:** Design approved; ready for Phase-1 implementation planning.
**Author:** gmcnaught (with Claude)

---

## 1. Goal

Run GameMaker (GLES2) games on MiSTer FPGA at playable framerates by supplying the
**missing GPU in fabric**, the same way PortMaster runs gmloader on low-power SBCs by
leaning on the device GPU. On MiSTer's Cyclone V there is no GPU: gmloader's GLES calls
fall to Mesa software rasterization (softpipe/llvmpipe) at ~1 fps. **MFGPU** (MiSTer FPGA
GPU) replaces that software rasterizer with an FPGA pixel back-end.

The stack the user named — **an FPGA renderer + gl4es + gmloader-next → a 32-bit gmloader
engine for MiSTer** — maps to: gmloader-next loads the app, gl4es is the API-compat shim
(desktop-GL → GLES2, Phase 2), and **MFGPU is the GPU backend** that gl4es / the GM runner
draw into.

**Success metric:** *Maldita Castilla* @ 320×240 rendering through the fabric at a playable
framerate (≥30 fps target, 60 fps stretch) with clean analog + HDMI output — i.e. the game
that ran at 1 fps on software now runs.

---

## 2. Approved decisions (the forks we resolved)

| # | Fork | Decision | Rationale |
|---|------|----------|-----------|
| 1 | Fidelity | **GameMaker-shaped fixed-function 2D accelerator**, presented as GLES2, with a **software fallback** for anything the fabric can't do. Programmable shader GPU is an explicit v2. | ~90% of GM titles are fixed-function (textured/transformed/blended quads); a full programmable pipeline (Beasley path) is far more RTL/area/timing risk on a Cyclone V. Fallback keeps "unsupported" = slow-but-correct, not broken. |
| 2 | Interception point | **Staged**: Phase 1 intercepts GM drawing at the lowest *stable* boundary and feeds the fabric directly; Phase 2 builds a general GLES2/EGL driver on the same fabric+transport. | De-risks the big fabric bet before the big software bet; gets a real game on screen soonest; sidesteps GLSL for the fixed-function fast path. |
| 3 | Canary | **Maldita Castilla** (Phase 1). *6 Feet Under* = simplest-bring-up fallback. *Undertale* = Phase-1b stretch. | The PortMaster Maldita port is **already armhf**, `rtr`, gmloader/GLES, low-res pixel-art (on-chip), and is literally the 1fps-on-softpipe game that motivated the project. Its armhf runner eliminates the runner-packaging blocker that affects the aarch64 6 Feet Under port. |
| 4 | Framebuffer / scanout | **Compose on-chip at the internal `application_surface` resolution (≤~320×240); delegate final upscale to MiSTer's hardware scaler** (`video_mixer`/ascal). SDRAM-resident framebuffers deferred to the high-res path. | Pixel-art GM games render a low-res internal surface then upscale — the expensive compositing is low-res and fits on-chip BRAM, dodging the SDRAM-scanout / analog-vsync bandwidth risk that regressed the earlier SDRAM-burst work. |
| 5 | A9 ↔ fabric split | **A9 front-end, fabric pixel back-end.** A9 (NEON) does transform / clip / cull → emits screen-space textured triangles; fabric does edge/UV/RGBA interpolation, texel fetch, modulate, blend, framebuffer. | Bottleneck is O(pixels), not O(vertices). A9 transform ≈ <1 ms/frame even for heavy scenes; moving it to fabric would cost ~20–40 DSPs + a bug-prone clipper stolen from the pixel throughput that actually matters. Reuses the blitter's "A9 builds display list, fabric consumes" model. |

---

## 3. Architecture

```
  GM runner (.so, armhf)  ── GLES2 calls ──┐         [Phase 2: any GLES2/GL app]
                                            │
  ┌─────────────────────────────────────────────────────────────┐
  │  Host lowering                                                │
  │   Phase 1: GM interceptor  ── OR ──  Phase 2: libGLESv2/libEGL │
  │        └── both call ▼                                        │
  │   libmfgpu  (A9 + NEON geometry front-end)                    │
  │     transform · cull/clip · fixed-point · emit display list   │
  └─────────────────────────────┬───────────────────────────────┘
                                 │  DDR ring @ 0x3B00_0000 + doorbell  (reused from blitter)
  ┌─────────────────────────────▼───────────────────────────────┐
  │  MFGPU fabric  (RTL — pixel back-end)                         │
  │   ring reader → tri setup → raster (edge/UV/RGBA interp)      │
  │        → texel fetch → modulate → blend → framebuffer         │
  └─────────────────────────────┬───────────────────────────────┘
                                 │  on-chip FB (≤~320×240)  → scanout
                          MiSTer video_mixer / ascal  → HDMI + analog (free upscale)
```

**One line:** the A9 turns GM's draw batches into screen-space textured triangles; the
fabric turns triangles into blended pixels; MiSTer's existing scaler turns the low-res
framebuffer into display output.

MFGPU is an **evolution of the existing blitter** (`mister-fpga-blitter`), not a greenfield
GPU. The blitter already does textured axis-aligned spans with COPY/KEY/ALPHA/PALPHA/ADD/MUL/
tint into an on-chip framebuffer with scanout; MFGPU adds an interpolating **triangle**
rasterizer and (later) memory-resident render targets.

---

## 4. Components

Each unit has one purpose, a defined interface, and stated dependencies.

1. **MFGPU fabric** — *RTL, new engine in `mister-fpga-blitter`.*
   - **Does:** consume the display-list ring; rasterize screen-space triangles with per-pixel
     U/V/RGBA interpolation; texel fetch; modulate by vertex RGBA; blend into framebuffer;
     scanout.
   - **Interface:** DDR ring of 32-byte command words + doorbell; on-chip framebuffer → MiSTer
     video.
   - **Reuses:** ring reader, arbiter, blend/comp pipeline, scanout, `blt_alloc` DDR heap.
   - **New:** triangle setup (edge functions), U/V/RGBA interpolators, texel address-gen.
     Nearest filtering first; bilinear in Phase 2.

2. **Reference model + sims** — *host C, in repo.*
   - **Does:** bit-exact C model of the rasterizer; Verilator/Icarus compare RTL vs refmodel
     per-pixel. Extends the existing refmodel / `blt_alloc_test` harness.
   - **Depends on:** the command-protocol definition (§5).

3. **libmfgpu** — *host lib, C + NEON.*
   - **Does:** A9 geometry front-end — matrix×vertex, 2D bbox cull, fixed-point conversion,
     display-list emit + doorbell.
   - **Interface:** a small C API called by both the Phase-1 interceptor and the Phase-2
     driver — the **shared waist** of the design.
   - **Depends on:** the DDR ring transport.

4. **GM interceptor** — *Phase 1, in `gmloader-next`.*
   - **Does:** capture GM's drawing at the lowest stable boundary — a minimal **GLES2
     draw-interposer** (`glDrawElements`/`glDrawArrays` + bound texture + MVP uniform + blend
     state) is the version-robust default; hooking the runner's internal batch-flush is a
     lower-overhead alternative if it proves stable (Phase 0 decides — see Risk 1). Translates
     captured batches → libmfgpu calls.
   - **Depends on:** libmfgpu; gmloader-next's patching/loading.

5. **GLES2/EGL driver** — *Phase 2.*
   - **Does:** export the GL API generically (`libEGL` + `libGLESv2`); state machine; lower
     `glDraw*` to libmfgpu; default pipeline in fabric, custom shaders → software fallback.
   - **Reuses:** a GL front-end (Mesa Gallium pipe driver or gl4es) for state + GLSL where
     sane. The Phase-1 interposer is a strict subset of this, so effort carries forward.

6. **MiSTer core integration** — *RBF.*
   - **Does:** wire MFGPU scanout into `video_mixer`/ascal; CONF_STR; hybrid ARM/FPGA build.
   - **Depends on:** HYBRID-CORE-GUIDE build process; RBF CI (`raetro/quartus:17.0`).

---

## 5. Command protocol

Extends the blitter's 32-byte ring word. A small fixed op set covering GM's fast path:

| Op | Payload | Notes |
|----|---------|-------|
| `BIND_TARGET` | fb base, W, H, format | on-chip FB (Phase 1); memory surface (Phase 2) |
| `BIND_TEX` | page base, W, H, format | GM atlas page in memory |
| `SET_BLEND` | mode | normal / add / sub / max / mul / tint |
| `TRI` | 3× {x.12.4, y.12.4, u.16, v.16, rgba8888} | screen-space, fixed-point |
| `RECT` | axis-aligned fast-path (optional) | reuses the blitter's existing span path |
| `PRESENT` | — | end-of-frame; triggers scanout swap |

Because vertices arrive **already in screen-space fixed-point**, the fabric never sees a
float or a matrix — the reason Option A keeps the RTL small.

---

## 6. Data flow (per frame, Phase 1)

1. GM runner issues draws → accumulates an internal vertex batch.
2. Interceptor fires on batch flush (texpage/blend change or frame end); reads batch +
   current MVP + blend state.
3. **libmfgpu (A9/NEON):** transform vertices → screen space (fixed-point), cull off-screen
   triangles, emit `BIND_TEX` / `SET_BLEND` / `TRI` into the DDR ring; ring the doorbell.
4. **MFGPU fabric:** per triangle → edge setup + rasterize; per pixel → interpolate U/V/RGBA,
   fetch texel from the atlas page, modulate by vertex RGBA, blend into the framebuffer.
5. On `PRESENT` (frame end / `application_surface` flip): scanout the framebuffer to MiSTer
   video; the MiSTer scaler upscales to display.

---

## 7. Software-fallback / error model

Every draw is **classified fabric-eligible vs fallback at emit time on the A9.**
Principle: *unsupported degrades to slow-but-correct or logged-skip — never hang or corrupt.*

- **Unsupported blend/state** → emulate on A9 in libmfgpu (rare).
- **Custom fragment shader** → software fallback. Preferred form (Phase 2): software renders
  the shader's output to a **small scratch texture in memory**, and the fabric composites it
  as a normal textured quad — avoiding full-framebuffer readback (the documented "readback
  churn" trap). Phase-1 simpler form: detect shader batches, route to the existing software
  blitter path, or logged-skip.
- **Hard errors** (ring overflow, malformed command) → fabric raises a status/error register;
  A9 polls, logs, and drops the frame rather than hang. Ring working-set stays bounded via the
  `blt_alloc` free-list (the map-transition-overflow fix).

---

## 8. Testing strategy

- **Unit:** refmodel bit-exact vs RTL, per-pixel, per-op; randomized triangle fuzzing
  (verts/uv/color/blend) refmodel↔RTL. Extends `blt_alloc_test`.
- **Golden-image:** refmodel renders known scenes (rotated textured quad, overlapping alpha,
  additive) → PNG; RTL sim diffed against it.
- **Integration:** libmfgpu on A9 emits a display list → fabric sim → matches refmodel for the
  same list.
- **End-to-end:** Maldita on hardware — **mandatory visual check on real analog + HDMI**
  (the "counters lie about video" lesson) + fps via DDR counter.
- **CI:** RBF build via `raetro/quartus:17.0` in GitHub Actions + **timing-closure gate kept
  green** (MFGPU must not regress the video path).

---

## 9. Phased build plan

**Phase 0 — de-risk (no fabric yet).** Cheap, high-information:
- Bring up the armhf Maldita gmloader stack on MiSTer via the existing software-GL path →
  confirm it loads, controls work, and **capture the 1 fps baseline** (the before-number).
- Confirm Maldita's **internal render resolution** (instrument the runner / inspect
  `game.droid` room + surface sizes) → verify on-chip fit.
- **Pin the interception point** (Risk 1) — the biggest Phase-1 unknown: GLES2 interposer vs
  internal batch-flush hook.
- Audit `game.droid` for `shader_set` usage (custom-shader exposure).

**Phase 1 — fabric + hook (the core bet):**
- 1a. MFGPU fabric MVP: triangle raster + nearest texel + ALPHA/ADD blend + on-chip FB +
  scanout — **refmodel & sims green before HW.**
- 1b. libmfgpu A9 front-end: transform / cull / fixed-point / emit.
- 1c. Interceptor: GM batches → libmfgpu → ring.
- 1d. RBF integration + on-HW bring-up: Maldita renders via fabric; measure fps vs baseline;
  visual check analog + HDMI.
- **Gate:** playable Maldita @ 320×240 (≥30 fps target, 60 fps stretch), clean analog + HDMI.

**Phase 1b — Undertale (stretch):** exercises `surface_*` effects and proves the
compose-320×240 → MiSTer-scaler-upscale path on a target title.

**Phase 2 — generalize:** bilinear + remaining blend modes; memory-resident render targets
(surfaces); the general GLES2/EGL driver on libmfgpu; software shader-fallback; gl4es on top
for desktop-GL apps (e.g. OpenBOR).

**Phase 3 (optional, distant):** programmable fragment core (Beasley path) only if
shader-heavy titles justify the area — added as a separate fragment stage without disturbing
the back-end.

---

## 10. Risks & mitigations

1. **Interception-point stability (biggest).** Hooking the runner's internal batch-flush
   symbol is fragile across GM versions. **Mitigation / likely answer:** a minimal **GLES2
   draw-interposer** (capture `glDrawElements` + bound texture + MVP uniform) is far more
   version-robust and is a strict subset of the Phase-2 driver, so the effort carries forward.
   Phase 0 decides.
2. **Internal resolution > on-chip budget.** Mitigate by composing at the internal
   `application_surface` resolution; if a title truly renders high-res, isolate it to the
   deferred SDRAM path (the analog-scanout problem, already understood).
3. **Fabric timing / analog regression** (the SDRAM-burst saga). Keep scanout on-chip in
   Phase 1; CI timing gate; mandatory visual analog check; leave the video-path timing
   untouched.
4. **Custom shaders in the canaries.** Audit `game.droid` in Phase 0 (old-GM Maldita likely
   uses none); classify + fallback.
5. **Fabric throughput / overdraw.** Profile-first; measure early; RECT fast-path +
   static-layer flattening (existing levers) if needed.
6. **armhf runner availability.** Resolved for Maldita (port is armhf); a per-title concern
   for other candidates (e.g. the aarch64 6 Feet Under port needs an armhf runner).

---

## 11. Repo layout

- **`mister-fpga-blitter`** (private) — MFGPU fabric + refmodel + sims + libmfgpu.
- **`gmloader-next`** — interposer/hook backend calling libmfgpu.
- **MiSTer core repo** — RBF integration.
- **This spec** — `docs/superpowers/specs/`.

---

## 12. Out of scope (YAGNI for now)

- Programmable GLSL shader execution in fabric (Phase 3 only, if justified).
- Full 3D GLES2 (perspective, depth-heavy geometry, hardware T&L in fabric).
- High-resolution (>~320×240 internal) SDRAM-resident framebuffers (deferred; opens the
  analog-scanout problem).
- Non-GameMaker engines (OpenBOR etc.) — a Phase-2 beneficiary via gl4es, not a Phase-1 goal.

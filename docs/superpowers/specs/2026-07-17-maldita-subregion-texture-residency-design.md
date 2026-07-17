# Design: Per-sprite-quad sub-region texture residency

**Status:** approved (design; no code written yet)
**Date:** 2026-07-17
**Target:** `gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp` (+ its host parity tests). **Host-only** — no RTL, no protocol, no cross-team.
**Predecessor:** the app-surface BRAM render target (`2026-07-17-maldita-appsurface-bram-render-target`) is implemented, bit-exact in sim, and deployed to device. Device bring-up hit a texture-heap overflow that this fixes; the RTL/fabric are correct and unchanged.

## Problem (measured on device — do NOT re-derive)

Routing the scene to the fabric means the scene's **source** textures must be staged into the fabric SRC heap. Measured steady-state via `GMLOADER_MFGPU_HEAPLOG` instrumentation (currently uncommitted in `raster_backend_mfgpu.cpp`):

- **Working set = 20 MB**: three large sheets pinned simultaneously in one frame — key5 2048² (8 MB) + key7 1024×2048 (4 MB) + key6 2048² (8 MB).
- **Heap cap = `MF_DEV_SRC_CAP` ≈ 14.62 MB** (`MF_DEV_TLBUF_OFF − MF_DEV_SRC_OFF`). Every steady frame overflows (`evicted=0` — all three are pinned this frame, so nothing is eligible to evict), the emitter drops the frame, `C_SUBMIT` freezes at 1, and the display never advances.
- **UV coverage:** the two 8 MB sheets are sampled at only **1.3–5.9%** per frame; key7 at 76–86%. The **per-sprite-quad (2-triangle) footprint is a constant ~1.5–3% of the page** — the per-draw-call bbox (10–85%) is inflated only because a single draw batches multiple sprites scattered across the atlas.

**Root cause:** `stage_texture()` stages the **entire atlas page** (`blt_upload` of the full `w×h`) even when a draw samples one tiny sprite cell.

## Goal / non-goals

**Goal:** stage only the sub-region each sprite-quad actually samples, so the per-frame texture working set fits the ~14.62 MB heap (projected **~4.2 MB**, huge margin), unblocking on-device rendering through to the title screen — while staying bit-exact to the current whole-page render.

**Non-goals:** RTL/protocol changes; growing the fixed 16 MB DDR SRC window (an RTL/STA/cross-team fallback, to be reached for only if per-quad residency proves insufficient — unlikely given the margin); the step 2/3 render-target ladder.

## Design (all in `raster_backend_mfgpu.cpp`)

1. **Split each draw into sprite-quads.** In `mf_draw`, partition `triCount` into 2-triangle groups (GameMaker's sprite-quad emission unit). Each quad is staged + emitted independently.
2. **Per-quad crop + UV rebase.** For each quad compute the tight UV bounding box (min/max u,v over its 6 vertices), stage only that cropped sub-rect of the source texture (reuse the existing rect-walking conversion in `mf_texel565`, just changing the copy bounds), and rebase the quad's UVs into the sub-rect's origin before `bvtx_to_blt`.
3. **Re-key the residency cache.** `MfTexEntry`'s key becomes `(tex_id, quantized UV rect)` instead of `tex_id`. Grow `MF_TEX_CACHE_N` (more, smaller entries).
4. **One TRILIST per quad** (or per contiguous same-cell group). Frames have only ~5–8 draws, so dozens of tiny TRILISTs is fine; watch ring `cmd_count`.
5. **Unaffected paths.** `BLT_F_SRC_SURFACE` (app-surface) draws still skip staging entirely (verified clean). Vertex/blend math is otherwise unchanged.

## Key decisions

- **Granularity = per-sprite-quad**, NOT per-draw-call bbox — established by measurement (per-draw bbox is inflated by batched scattered sprites; per-quad is a stable ~1.5–3%).
- **Cache key = `(tex_id, quantized UV rect)`.** Quantize the bbox out to a small grid (**default 8 px, tunable**) so animated sprites at fixed atlas cells remain stable cache hits across frames rather than re-staging on sub-pixel UV jitter. (Approved default; start quantized, revisit only if device shows thrash.)
- **Fallback = whole-(cropped-)page staging** when a draw isn't clean tri-pairs, is degenerate, or a quad's bbox is ~the whole page — safe and never worse than current behavior. The game's scene draws are all tri-pairs (measured `tris=2/4/6`), so the fast path always hits; the fallback is a correctness safety net.
- **Cache capacity:** grow `MF_TEX_CACHE_N` (**default 256, tunable**) since entries are now more numerous and smaller.

## Correctness

- UVs rebased into the cropped sub-rect origin so the fabric's (NEAREST) texel fetch resolves to the same texels. Include a **1-texel margin / clamp** on the cropped bbox so a quad's max-UV edge texel is never cropped off (off-by-one guard around the existing rasterizer sample convention, incl. the documented +HALF sample-point bias).
- The cropped-and-rebased render MUST be bit-exact (±1 LSB RGB565) to the current whole-page render for the same draw — this is the parity-test invariant.

## Testing

- **Host parity** (`raster_backend_test.cpp`, new cases against the `blt_execute` oracle): (a) a draw sampling a small sub-region of a large page — per-quad-cropped output == whole-page output; (b) a multi-sprite batched draw sampling different cells of the same page; (c) a near-full-page draw (fallback path); (d) edge/margin sprites (the +HALF/clamp guard). All bit-exact.
- **Device re-verify** (`GMLOADER_MFGPU_HEAPLOG`): per-frame working set < ~5 MB, no `cannot fit` / `frame dropped`, `C_SUBMIT` climbs, screenshots change over time and reach the title screen; capture fps.

## Risks / tuning knobs

- **Cache thrash** if UV quantization is too fine or `MF_TEX_CACHE_N` too small → device `HEAPLOG` upload-count tells us; tune the two knobs.
- **Non-sprite geometry** (odd tri counts, big single triangles) → the whole-page fallback covers it; verify no scene draw silently overflows via the fallback.
- **Command/ring overhead** from more, smaller TRILISTs → negligible at ~5–8 draws/frame; watch `cmd_count` doesn't approach the ring cap.

## Files

- `gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp` — `mf_draw` quad split + per-quad crop/rebase; `stage_texture` cache key; `MfTexEntry`; `MF_TEX_CACHE_N`; keep the `GMLOADER_MFGPU_HEAPLOG` diag toggle (committed) for device re-verify.
- `gmloader-next/gmloader/mister/raster_backend_test.cpp` — the parity cases above.

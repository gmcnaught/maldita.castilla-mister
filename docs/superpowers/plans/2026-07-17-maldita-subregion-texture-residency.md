# Per-sprite-quad sub-region texture residency — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:team-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Stage only the UV sub-region each sprite-quad samples (instead of the whole 2048² atlas page), so the per-frame fabric texture working set drops from ~20 MB to ~4 MB and fits the ~14.62 MB device SRC heap — unblocking on-device rendering to the title screen, bit-exact to the current whole-page path.

**Architecture:** Host-only change to the mfgpu emitter (`raster_backend_mfgpu.cpp`). `mf_draw` splits each draw into 2-triangle sprite-quads; each quad's tight UV bbox is cropped out of the source texture, staged as a small page, and the quad's UVs are rebased into that cropped page. The residency cache is re-keyed `(tex_id, quantized UV rect)`. Verified bit-exact against the current whole-page render via the `blt_execute` host oracle, then re-verified on device.

**Tech Stack:** C++ (gmloader host backend), the mfgpu host emitter/reference model (C), host-native make tests, MiSTer device @ `192.168.20.81`.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-17-maldita-subregion-texture-residency-design.md`.
- **Host-only:** no RTL, no wire-protocol change, no `mister-fpga-blitter` change. Everything is in `gmloader-next/gmloader/mister/`.
- **Bit-exact discipline:** every rendering change must be ±1 LSB RGB565 identical to the current whole-page render for the same draw, proven by a host parity test against `blt_execute` (the same oracle `raster_backend_test.cpp` already uses).
- **UV convention:** `BVtx.u/.v` are normalized (0–1). `bvtx_to_blt(v, tw, th)` = `clamp(uv,0,1)*tw*16` → a **12.4 fixed-point absolute pixel** coord in the `tw×th` page. Fabric sampling is NEAREST with a `+HALF` sample-point bias (see `blt_tri.c`); a cropped bbox must include a 1-texel margin so the max-UV edge texel isn't cropped off.
- **Device heap:** `MF_DEV_SRC_CAP ≈ 14.62 MB`. Measured overflow working set = 20 MB (key5 2048² 8 MB + key7 1024×2048 4 MB + key6 2048² 8 MB); per-quad footprint ~1.5–3% of a page.
- **Tuning defaults (spec):** UV-rect quantization grid = 8 px; `MF_TEX_CACHE_N` = 256. Both tunable via device `HEAPLOG`.
- **Build/test:** host tests `cd gmloader-next && make -f Makefile.gmloader raster-backend-test && ./<binary>` (and siblings); engine armhf via Docker (`Dockerfile.gmloader-build`); PATH needs `/opt/homebrew/bin`. Device: `deploy.py`, `load_core` via `/dev/MiSTer_cmd`, `gmloader_diag.sh --preset fabric`, screenshots, `busybox devmem 0x3B000000 32`.

---

## Task 1: Commit the HEAPLOG diagnostic + baseline

impl-engine's `GMLOADER_MFGPU_HEAPLOG` instrumentation (per-upload / per-fail / per-frame-pinned-set / per-quad-UV-bbox logging) is currently **uncommitted** in the working tree. It is the measurement tool for the device re-verify and contains the per-quad UV-bbox math the core task reuses. Land it first as a committed, off-by-default toggle.

**Files:**
- Modify/commit: `gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp` (the existing uncommitted HEAPLOG block)

**Interfaces:**
- Produces: `mf_heaplog_on()` (env `GMLOADER_MFGPU_HEAPLOG=1`, cached), and `HEAPLOG …` stderr lines. Zero cost when off.

- [ ] **Step 1: Review the uncommitted diff** in `raster_backend_mfgpu.cpp` — confirm the HEAPLOG block is gated on `mf_heaplog_on()` (no overhead when unset), computes per-upload bytes, per-frame pinned-set total, and per-quad UV bbox, and touches nothing else.
- [ ] **Step 2: Build + host tests unaffected.**

Run: `cd gmloader-next && make -f Makefile.gmloader raster-backend-test && ./<raster-backend-test binary>`
Expected: existing 20/21 cases pass unchanged (HEAPLOG off by default).
- [ ] **Step 3: Commit.**

```bash
cd gmloader-next && git add gmloader/mister/raster_backend_mfgpu.cpp
git commit -m "diag: GMLOADER_MFGPU_HEAPLOG — per-upload/frame/quad texture-heap logging"
```

---

## Task 2: Per-quad split + crop-stage + UV rebase + sub-region cache

The core. Split each draw into sprite-quads; stage each quad's cropped UV bbox; rebase its UVs; cache by `(tex_id, quantized rect)`.

**Files:**
- Modify: `gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp` (`MfTexEntry`, `MF_TEX_CACHE_N`, `stage_texture`, `mf_draw`)
- Test: `gmloader-next/gmloader/mister/raster_backend_test.cpp`

**Interfaces:**
- Consumes: `bvtx_to_blt`, `blt_upload`, `blt_push_tris`, `blt_trilist`, the `g_texcache`/`stage_texture` machinery.
- Produces: `stage_texture_region(tex_key, t, u0,v0,u1,v1, &has_key)` returning a `blt_surface_ref_t` for the cropped sub-rect; a `MfTexEntry` keyed by `(key, rx,ry,rw,rh)`; `mf_draw` emits one TRILIST per quad with rebased UVs.

- [ ] **Step 1: Write the failing parity test.** In `raster_backend_test.cpp`, add `case_subregion_matches_wholepage`: build a large (e.g. 512×512) source texture with a distinctive pattern; issue one quad that samples a small sub-region (e.g. UV [0.1,0.2]×[0.3,0.4]); render it through the mfgpu backend into a framebuffer; render the identical draw through the pre-change whole-page path (or `backend_sw`); assert the two framebuffers are bit-exact (±1 LSB) over the drawn region.

```cpp
TEST(case_subregion_matches_wholepage) {
    RTexture big = make_pattern_texture(512, 512);
    BVtx quad[6] = /* two tris sampling UV sub-rect [0.1,0.2]x[0.3,0.4], dst somewhere on screen */;
    render_mfgpu(&fb_new, quad, /*tris=*/2, &big, RB_NONE);
    render_reference_wholepage(&fb_ref, quad, 2, &big, RB_NONE);  // sw or pre-change path
    ASSERT_BITEXACT(fb_new, fb_ref);   // ±1 LSB
}
```

- [ ] **Step 2: Run it, verify it fails.**

Run: `cd gmloader-next && make -f Makefile.gmloader raster-backend-test && ./<binary>`
Expected: FAIL — `stage_texture_region`/quad-split not implemented; still stages whole page (or the new symbol is undefined).

- [ ] **Step 3: Implement the crop-stage helper.** Add `stage_texture_region()` mirroring `stage_texture()` but converting only the sub-rect `[u0..u1)×[v0..v1)` (in texels, computed from normalized UV × t->w/h, expanded by a 1-texel margin and clamped to `[0,t->w)×[0,t->h)`) into `g_texscratch`, then `blt_upload(&g_e, g_texscratch, rw, rh, rw*2)`. Reuse the per-texel `mf_texel565` conversion, just over the cropped bounds:

```cpp
// rect in texels (with +1 margin, clamped)
int rx = clampi((int)floorf(u0 * t->w) - 1, 0, t->w-1);
int ry = clampi((int)floorf(v0 * t->h) - 1, 0, t->h-1);
int rx1 = clampi((int)ceilf (u1 * t->w) + 1, 1, t->w);
int ry1 = clampi((int)ceilf (v1 * t->h) + 1, 1, t->h);
int rw = rx1 - rx, rh = ry1 - ry;
for (int y = 0; y < rh; y++)
  for (int x = 0; x < rw; x++)
    g_texscratch[(size_t)y*rw + x] = mf_texel565(t, rx+x, ry+y, &has_key);
blt_surface_ref_t ref = blt_upload(&g_e, g_texscratch, rw, rh, rw*2);
```

- [ ] **Step 4: Re-key the cache.** Extend `MfTexEntry` with `uint16_t rx, ry, rw, rh;` and match on `(key, rx,ry,rw,rh)` in the cache scan; bump `MF_TEX_CACHE_N` to 256. `stage_texture_region` records the rect in the entry.

- [ ] **Step 5: Split the draw + rebase UVs in `mf_draw`.** Replace the single `stage_texture`+`blt_trilist` with a loop over quads (`for q in 0..triCount/2`, 6 verts each): compute the quad's UV bbox, call `stage_texture_region`, rebase each of the 6 vertices' UVs into the cropped page — convert the vertex to a cropped-page pixel coord by subtracting the rect origin — and emit one TRILIST for the quad. Rebase (bvtx_to_blt reads normalized UV × page-dims, so pass the cropped dims and pre-shift UV to the rect origin):

```cpp
// per vertex: absolute texel = uv * t->w ; cropped-page uv' = (abs - rx) / rw
float u_abs = clamp01(v[i].u) * t->w, v_abs = clamp01(v[i].v) * t->h;
BVtx r = v[i]; r.u = (u_abs - rx) / (float)rw; r.v = (v_abs - ry) / (float)rh;
g_vtxscratch[k] = bvtx_to_blt(&r, rw, rh);   // now addresses the cropped page
```

- [ ] **Step 6: Run the parity test, verify PASS + existing suite unregressed.**

Run: `cd gmloader-next && make -f Makefile.gmloader raster-backend-test && ./<binary>`
Expected: `case_subregion_matches_wholepage` PASS bit-exact; existing 20/21 cases still pass.

- [ ] **Step 7: Add a batched-multi-sprite parity case.** One draw with `tris=4` sampling two *different* sub-rects of the same page (mirrors the real key5 batching): assert bit-exact vs whole-page, and (via HEAPLOG or `g_upload_count`) that two small regions staged, not the full page.

- [ ] **Step 8: Run + commit.**

```bash
cd gmloader-next && make -f Makefile.gmloader raster-backend-test && ./<binary>   # all pass
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_test.cpp
git commit -m "mfgpu: per-sprite-quad sub-region staging + UV rebase + (tex,rect) cache"
```

---

## Task 3: Fallback + edge correctness

Cover the non-fast-path cases so nothing renders wrong or silently re-overflows.

**Files:**
- Modify: `gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp` (`mf_draw` fallback branch)
- Test: `gmloader-next/gmloader/mister/raster_backend_test.cpp`

**Interfaces:**
- Consumes: Task 2's quad path.
- Produces: a fallback in `mf_draw` — when `triCount` is not an even number of tri-pairs, or a quad's cropped rect ≥ ~90% of the page, stage/emit the whole (cropped-to-bbox) page as before.

- [ ] **Step 1: Write failing tests.** Add `case_fallback_odd_tricount` (a `tris=3` draw renders bit-exact vs whole-page), `case_nearfullpage` (a quad whose UV bbox covers ~the whole page renders bit-exact and doesn't crop-thrash), and `case_edge_sprite` (a sprite whose UV bbox touches the texture's max row/col — verifies the +1-texel margin/clamp so the edge texel isn't dropped). Assert bit-exact for all.

- [ ] **Step 2: Run, verify they fail** (fallback/margin not handled). Command as Task 2 Step 2.

- [ ] **Step 3: Implement the fallback + margin.** In `mf_draw`: if `triCount % 2 != 0` (or a quad's bbox area ≥ 0.9·page), route that quad/draw through the original whole-page `stage_texture` path (which Task 2 must leave intact). Ensure the crop-rect margin/clamp from Task 2 Step 3 handles max-edge texels.

- [ ] **Step 4: Run, verify PASS + full suite green.** Command as Task 2 Step 6.

- [ ] **Step 5: Commit.**

```bash
cd gmloader-next && git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/raster_backend_test.cpp
git commit -m "mfgpu: sub-region fallback (non-quad / near-full-page) + edge-texel margin"
```

---

## Task 4: Device re-verify (bring-up)

Rebuild the engine, deploy to the current RBF (RTL unchanged), and confirm the heap fits and the game reaches the title screen.

**Files:** none (build + deploy + observe). Uses the Docker engine build, `deploy.py`, the device runbook.

**Interfaces:** Consumes Tasks 1–3.

- [ ] **Step 1: Build the engine (armhf) via Docker** from the sub-region HEAD.

Run: `PATH=/opt/homebrew/bin:$PATH <docker build per Dockerfile.gmloader-build>` → confirm `gmloader-next/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf` produced clean.

- [ ] **Step 2: Deploy engine only** (RBF is unchanged from the current on-device `MalditaCastilla_20260717.rbf`).

Run: `cd maldita.castilla-mister && ./deploy.py --no-rbf --no-content` (or `--engine-only`; confirm flags).

- [ ] **Step 3: Run with HEAPLOG and confirm the working set fits.**

Run: `ssh root@192.168.20.81 'cd /media/fat/games/gmloader && GMLOADER_MFGPU_HEAPLOG=1 setsid /media/fat/Scripts/gmloader_diag.sh --preset fabric >/tmp/gm.out 2>&1 & sleep 40; grep -E "frame-end|cannot fit|HEAPLOG at-fail" /tmp/gmloader.log | tail'`
Expected: **no** `cannot fit` / `frame dropped`; per-frame pinned set well under 14.62 MB (projected ~4 MB); `busybox devmem 0x3B000000 32` (C_SUBMIT) climbing.

- [ ] **Step 4: Confirm the display advances to the title screen.**

Run: two screenshots ~15 s apart (`echo screenshot > /dev/MiSTer_cmd`), `scp` both, compare MD5.
Expected: **different** MD5s (display animating, not frozen); the image is a coherent Cursed Castilla intro/title, not the black+garbage frozen frame. Let it run ~2 min and confirm it reaches the title screen. Capture `BLITPROF` fps.

- [ ] **Step 5: Record + commit any deploy notes; update the ledger.**

```bash
git add -A && git commit -m "deploy: sub-region residency verified on device (reaches title, heap fits)"
```

**Definition of done:** on device, no heap overflow, `C_SUBMIT` climbs, screenshots change over time and reach the Cursed Castilla title screen; host parity suite green; sub-region path bit-exact vs whole-page.

---

## Self-review

- **Spec coverage:** quad split (Task 2 Step 5), per-quad crop (Task 2 Step 3), UV rebase (Task 2 Step 5), `(tex_id, quantized rect)` cache + `MF_TEX_CACHE_N` (Task 2 Step 4), fallback (Task 3), edge/margin (Task 2 Step 3 + Task 3), HEAPLOG diag (Task 1), host parity tests (Tasks 2/3), device re-verify (Task 4), tuning knobs surfaced (Global Constraints + Task 4). All spec sections map to a task.
- **Bit-exact ordering:** every rendering change is gated by a parity test vs the whole-page path before it lands.
- **No RTL/protocol dependency:** entirely in `gmloader-next`; the on-device RBF is unchanged, so Task 4 is engine-only redeploy.
- **Placeholder note:** the raster-backend-test binary name and the exact Docker build invocation are environment-specific — resolve from `gmloader-next/Makefile.gmloader` and `Dockerfile.gmloader-build`/`deploy.py` at execution time (same as the prior plan's Task 1).

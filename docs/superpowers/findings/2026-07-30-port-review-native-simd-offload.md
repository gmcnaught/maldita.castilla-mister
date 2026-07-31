# Port review: native-support duplication, NEON gaps, FPGA-offload candidates

**Scope:** everything `gmcnaught/gmloader-next@master` (e3fccae) adds over
`JohnnyonFlame/gmloader-next@master` (522d964) — 95 files, +15,436/−296 — plus the
non-doc contents of `mister-gmloader@master` (226918f).
**Method:** static reading of the diff in review worktrees
(`../wt-gmloader-review`, `../wt-mgml-review`). **No profiling was run for this
review.** Cost claims below are inspection-derived (loop trip counts × call
sites), not profile-attributed. Where BLITPROF already measures a site, that is
called out.

Merge-base check: `git merge-base HEAD upstream/master` == `522d964` == upstream
head, so our master is a strict superset; the diff below is entirely ours.

---

## 1. Novel implementation where the ported-to system has native support

### 1.1 Two software-GLES provisioning mechanisms (`3rdparty/gles2-sw/`)
**Observed.** `Makefile.gmloader` links `-lGLES_sw` against a vendored 87,516-byte
`3rdparty/gles2-sw/libGLES_sw.so`. Its own `README.md` states it is a *stub*
("enough to satisfy the MiSTer link ... a stopgap only") and lists building Mesa
llvmpipe as the intended replacement. Meanwhile `mister-gmloader/runtime/mesa/`
already ships a real software GLES stack (`libEGL.so.1`, `libGLESv2.so.2`,
`libglapi.so.0`, `swrast_dri.so`) and the engine *requires* it at runtime —
without `LD_LIBRARY_PATH=$GMDIR/mesa` it dies in `eglInitialize`.

**Inferred.** The vendored stub is a build-time artifact duplicating a runtime
dependency that is already satisfied by Mesa. Two sources of "software GLES" that
can disagree, one of which is a non-functional placeholder in version control.

**Action candidate:** drop the vendored `.so`, link against the same Mesa the
device actually loads (or make the link weak/dlopen-based). Removes an 87 KB
binary from git and one class of "which GL am I actually running?" ambiguity.

### 1.2 Hand-written bilinear downscale vs. the core's hardware scaler
**Observed.** `gmloader/mister/frame_capture.cpp:99-135` implements a fixed-point
bilinear downscale ("matching the OpenBOR `patch_sdl_dummy.py` approach exactly"),
running per destination pixel × 4 channels on the A9.

**Native alternatives, in order of preference:**
1. The MiSTer framework's `ascal` (reached via `video_freak` / the `MISTER_FB`
   framebuffer interface) scales arbitrary source geometry in hardware, for free.
2. SDL2's `SDL_BlitScaled` / `SDL_RenderCopy` with a scaled destination rect.

**Inferred.** This path only executes when the blitter does not own the frame
(`main.cpp:1109-1136`), i.e. the GL fallback — so it is not on the shipping fabric
path. It remains a maintained software reimplementation of hardware the target
board already has.

### 1.3 Bespoke DDR3 framebuffer contract vs. `MISTER_FB`
**Observed.** `gmloader/mister/native_video_writer.c` defines a private DDR3
layout at `0x3A000000` (ctrl word, two RGB565 buffers, audio ring) consumed by a
bespoke `openbor_video_reader.sv`. The MiSTer framework has native support for
exactly this shape: `MISTER_FB` with `FB_BASE`/`FB_FORMAT`/`FB_STRIDE`, RGB565
among the supported formats, and ascal performing scaling *and* format conversion
in hardware on the way to the scaler. Per the existing sysmem analysis, the core
exposes a third 128-bit f2h port (`vbuf`) intended for ascal that the core does
not currently drive.

**Inferred.** The largest structural duplication in the port. Caveat that keeps
this from being an automatic "rip it out": the shipping fabric back-end
(`backend_mfgpu`) bypasses `NativeVideoWriter` entirely — the blitter composites
into on-chip BRAM and self-scans-out (`main.cpp:1094-1101`). So the `0x3A`
writer today binds only the SW/GL fallbacks, while the reader RTL and DDR region
are still carried in the core.

**Action candidate:** decide explicitly whether the `0x3A` writer + reader are
retired in favour of `MISTER_FB` for the fallback paths, or documented as
deliberately bespoke because the fabric path needs the reader anyway for
JOY/beacon words (`joy_ddr_reader.cpp` reads `0x3BF40000` from that same block).

### 1.4 Checked and NOT a defect — the joy-DDR input round trip
`gmloader/input.cpp:302-340` drives `yoyo_gamepads[]` from a mask the FPGA writes
into DDR3 rather than from SDL. That looks like HPS→core→DDR3→HPS, but the
in-code justification is correct: Main_MiSTer holds the exclusive evdev grab, so
SDL cannot see the pad. One real loss, though: `yoyo_gamepads[p].axis[a] = 0.0`
hardcodes all four analog axes to zero on both the shm and ddr transports. If any
GM code reads an axis, it gets a dead stick.

### 1.5 Checked and NOT worth changing
- `mister_native_audio.cpp:403` hand-rolls a saturating mix instead of
  `SDL_MixAudioFormat`. SDL's implementation is also scalar and applies a volume
  scale we do not want. Keep.
- `blitter_raster.cpp` re-implements a triangle rasterizer. That is the port, not
  a duplication.
- Audio resampling is already off the A9 (`native_audio_writer.h:32`,
  `NA_SAMPLE_RATE 22050` handed to `gm_audio.sv`'s SRC). Correctly done.

---

## 2. SIMD / NEON opportunities

### 2.0 Prerequisite finding: NEON is enabled for exactly one object file
> **FIXED 2026-07-30**, branch `perf/neon-flag-scope` (gmloader-next), uncommitted.
> `-march=armv7-a -mfpu=neon-vfpv3` now applies to all of `gmloader/mister/`
> (split `%.cpp.o: CXXFLAGS` / `%.c.o: CFLAGS`). Verified by ARM cross-build:
> 13 objects carry `Tag_Advanced_SIMD_arch: NEONv1`, `gmloader/main.cpp.o` and
> `thunks/libc/*.o` stay `VFPv3-D16` with no SIMD tag. 0 errors, 0 new warnings.
> The rest of §2 is now unblocked.

**Observed.** `Makefile.gmloader:68`:

```make
build/${ARCH}/gmloader/mister/blitter_raster.cpp.o: CXXFLAGS += -march=armv7-a -mfpu=neon-vfpv3
```

That is the only place NEON is enabled. `grep -rln "arm_neon|__ARM_NEON"` over
`gmloader/ thunks/ tools/` returns exactly one file: `blitter_raster.cpp`. Every
other translation unit compiles with the Debian armhf default (`vfpv3-d16`, no
NEON), so `__ARM_NEON` is undefined there and any intrinsics added would silently
compile out. `OPTM ?= -O2` on GCC 10 (bullseye, per
`.github/scripts/build_mister_arm.sh`) does not enable `-ftree-vectorize`, so
there is no auto-vectorization anywhere either.

**Consequence:** every item in §2.1–§2.7 requires the flag scope to widen first
(per-file rules like line 68, or a `mister/`-wide rule). Prefer explicit
intrinsics over hoping `-O3 -ftree-vectorize` finds these loops; the Cortex-A9's
NEON unit is not IEEE-clean for single-precision, so float loops will not
auto-vectorize without `-ffast-math`, which is not acceptable in the rasterizer's
bit-exact paths.

### 2.1 `Blitter_ToRGB565` — `gmloader/mister/blitter.cpp:680-698`
RGBA8888 → RGB565 with a per-row vertical flip, 288×216 = 62,208 px every frame
on the SW back-end. Scalar, three byte loads + two shifts + two ors + a 16-bit
store per pixel. NEON: `vld4q_u8` (16 px), `vshrn`/`vsri` to pack, `vst1q_u16` ×2.
This site is already instrumented — BLITPROF's `present=` field is exactly this
function, so the win is measurable before and after with no new tooling.

### 2.2 `FrameCapture_ConvertToRGB565` — `frame_capture.cpp:142-162`
Byte-for-byte the same conversion as §2.1, duplicated. Same NEON treatment; also
a straight de-duplication candidate (one shared `rgba8888_to_rgb565()` helper,
with the flip as an optional stride sign).

### 2.3 Bilinear downscale — `frame_capture.cpp:105-135`
Innermost `for (c = 0; c < 4; c++)` over four channels of four neighbours. The
whole 4-tap blend vectorizes cleanly 8 px/iteration with `vmull_u8`/`vshrn_n_u16`.
Only worth doing if §1.2 is resolved as "keep the software path".

### 2.4 Texture-upload passes — `blitter.cpp:224-241`
Two full-texture scalar passes per `glTexImage2D`:
- `:224-226` opacity scan — strided `s[i*4+3] != 255` byte test with early-out.
  NEON: `vld4q_u8` + `vminq_u8` reduction over 16 texels, early-out preserved at
  block granularity.
- `:233-235` RGBA8888 → RGBA4444 pack (`g_tex16` path) — `vshrn_n_u16`/`vsri`
  friendly.

Measured by BLITPROF's `texup=` field. Note this fires on `glTexImage2D` only;
`Blitter_OnTexSubImage2D` is a no-op (`blitter.cpp:374`), so for a game that
uploads once at load this is startup cost, not steady-state.

### 2.5 Fabric texel staging — `raster_backend_mfgpu.cpp:1644-1650` and `:1715-1720`
> **DONE 2026-07-30**, branch `perf/neon-flag-scope`, uncommitted. Both loops now
> call one extracted `mf_stage_texels()`; RGBA8888 runs 8 texels/iteration
> (`vld4.8` confirmed in the armhf object), RGBA4444 + tail stay scalar. Host
> test `make mf-stage-texels-test`; 6 mutations killed incl. all three Rec.601
> luma weights. **Win is UNMEASURED — `stage_texture` has no host-side timer.**
The hottest remaining host-side pixel loop on the *shipping* path:

```c
for (y…) for (x…) {
    uint16_t px = mf_texel565(t, x, y, &has_key);   // :404, per-texel call
    g_texscratch[y*rw + x] = px;
    if (!mf_texel_is_dark(px)) mask_only = false;   // :1619, Rec.601 luma per texel
}
```

Per texel: an unswitched format test, a 4-byte gather, an alpha threshold, a 565
pack, a colorkey collision fixup, and a luma dot product. All of it vectorizes —
hoist the `RTEX_RGBA4444` vs `RGBA8888` branch out of the loop, then `vld4q_u8` →
pack → `vceqq_u16` for the key → `vmull_u8`/`vshrn` for luma → `vmaxvq`-style
reduce for `mask_only`. Runs on every texture-cache miss and every re-stage after
an eviction, so under the cache pressure the eviction counters already track
(`g_evict_attempts`, `g_cachefull_drops`) it is per-frame, not per-load.

### 2.6 `Blitter_ClearSurface` — `blitter_raster.cpp:128-136`
> **DONE 2026-07-30**, same branch. memset / NEON 64 B-per-iteration / 32-bit
> tail. Also added the missing `blitter-raster-test` target — that whole test
> file had no Makefile rule and had never been run. 4 mutations killed.
Byte-at-a-time: four 8-bit stores per pixel, no word store, no `memset`, no NEON —
in a file that *is* compiled with NEON. Cheapest fix in the review: `memset` when
`r==g==b==a`, otherwise a 32-bit word fill, otherwise `vst1q_u32` ×4. (SW path
only; the fabric path clears via `blt_fill`, see §3.4.)

### 2.7 Gaps inside the existing NEON rasterizer — `blitter_raster.cpp:265-279`
The vector path is gated to `(blend == RB_NONE || blend == RB_ALPHA) && !q.fmt16`:
- `RB_PREMULT` and `RB_ADD` fall to scalar `blend_pixel` (`:74-81`). Both are
  simple enough to add to `blend8_alpha_neon`.
- RGBA4444 is excluded entirely — the format chosen specifically to halve gather
  cost is the one that loses vectorization. A 16-bit gather + `vshl`/`vsri`
  nibble-replicate expansion would cover it.

### 2.8 Low value, listed for completeness
- `raster_backend_convert.h:41-51` — 6 × `lroundf` + 2 clamps per vertex, scalar,
  in a non-NEON TU. ~680 vertices/frame at the measured 228 tri/frame. Small, but
  free once the flag scope widens.
- `mister_native_audio.cpp:403-404` — `vqaddq_s16`, 8 samples/iteration. Only
  engages with ≥2 simultaneous tracks.

---

## 3. A9 work that could move to the FPGA

### 3.1 RGBA→RGB565 conversion inside `STAGE` (strongest candidate)
**Observed.** On the fabric path a texture is touched three times before the
blitter sees it:
1. `store_texture` (`blitter.cpp:239-240`) `memcpy`s an RGBA8888 CPU copy.
2. `stage_texture`/`stage_texture_region` converts it per texel to RGB565 into
   `g_texscratch` (§2.5).
3. `mf_upload_and_cache:1551` `blt_upload`s that scratch into `g_srcdram`, then
   `:1576` `blt_stage` emits `BLT_OP_STAGE`, which the fabric executes as a
   DDR3→SDRAM DMA at the same offset.

**Inferred.** Step 3 already moves the bytes in hardware. Adding a source-format
field to `STAGE` (RGBA8888 in DDR3 → RGB565 written to SDRAM) would delete step 2
from the A9 entirely and let step 1's buffer be the DMA source directly. Cost on
the fabric side: 2× the DDR3 read bytes for a staged page, plus a pack stage in
the STAGE datapath. Cost saved on the A9: one full per-texel pass plus one full
`g_texscratch` write per staged page.

### 3.2 Colorkey folding and the `mask_only` classification
`mf_texel565:418-421` turns sub-128 alpha into the `0xF81F` sentinel and nudges
colliding opaque texels; `mf_texel_is_dark:1619-1622` computes a Rec.601 luma per
texel to decide `mask_only`. Both are per-texel predicates over the same stream
the STAGE DMA would already be walking under §3.1 — the sentinel substitution is a
mux, and `mask_only` is a single reduce bit the DMA could return in a status word.
Doing these on the A9 is only necessary because the A9 is the one touching the
texels.

### 3.3 Present-time 565 conversion and vertical flip (SW path)
`Blitter_ToRGB565` (§2.1) does the flip by walking source rows backwards. A flip
is an address-generation sign in `openbor_video_reader.sv`, free in RTL, and the
565 pack likewise. **Check before acting:** the Y-flip question was already
settled once — the flip lives at the app-surface composite and the reader stays
FORWARD. Re-introducing a reader-side flip would double-flip the fabric path.
Treat this as "if the SW path is kept, convert in the reader", not as a free win.

### 3.4 Already offloaded — do not re-litigate
- Clear: `mf_clear:1426` emits `blt_fill`. Only the SW fallback
  (`Blitter_ClearSurface`) still clears on the CPU.
- Audio resample: `gm_audio.sv` SRC, `NA_SAMPLE_RATE 22050` on the wire.
- Scanout/present: the fabric composites to BRAM and self-scans-out; `main.cpp`
  correctly does nothing on that path.
- Coverage estimation (`mf_clip_tri_area`, double-precision Sutherland-Hodgman
  per triangle) is env-gated behind `GMLOADER_MFSUBMIT_STAT` (`:1810`) and does
  not run in production. Correct as-is.

### 3.5 Bilinear downscale
See §1.2 — ascal is the hardware that does this. Filed under offload as well as
under native-support duplication because either resolution removes the same loop.

---

## Suggested ordering

| # | Item | Path affected | Effort | Notes |
|---|------|---------------|--------|-------|
| 1 | §2.0 widen NEON flag scope | all | trivial | unblocks everything in §2 |
| 2 | §2.6 `Blitter_ClearSurface` | SW | trivial | one-line `memset`/word fill |
| 3 | §2.5 NEON texel staging | **fabric** | medium | only §2 item on the shipping path |
| 4 | §3.1 RGBA→565 in `STAGE` | **fabric** | RTL + host | deletes §2.5 rather than speeding it |
| 5 | §2.1/§2.2 NEON + dedup 565 convert | SW/GL | small | BLITPROF `present=` measures it |
| 6 | §1.1 drop vendored `libGLES_sw.so` | build | small | hygiene, not perf |
| 7 | §1.3 `MISTER_FB` decision | core | large | decide, then document either way |

§3.1 supersedes §2.5 — if the fabric does the conversion, there is no host loop
left to vectorize. Do §2.5 only if §3.1 is deferred, or as the measurement
baseline that justifies §3.1.

# MFGPU Phase 0 Findings

Investigation results that gate the follow-on plan (gmloader interceptor + RBF
bring-up). Canary: **Maldita Castilla**, the PortMaster armhf port
(`ports/maldita.castilla`), running via gmloader-next on a MiSTer (DE10-Nano)
at `192.168.20.81`.

Port artifacts:
- `game.droid` — 49 MB, md5 `d12515353e1daddce3ac74af33201609`
- `malditacastilla.apk` (armeabi-v7a runner + assets)
- device deploy: `/media/fat/games/gmloader/` (gmloader binary, `mygame.apk`,
  `saves/game.droid`, Mesa software GL under `mesa/` + `mesa.softpipe/`)

---

## A1 Baseline

**Target metric:** Maldita's frame rate when its GLES2 draws fall to Mesa
software rasterization (softpipe) — the wall the FPGA renderer exists to remove.

**Established baseline (prior profiling):** **~1 fps** on pure Mesa softpipe.
The bottleneck is **software texture sampling (~57% of frame time)**, not
vertex transform or shader frills (vertex simplification yielded ~0 gain). This
is consistent with the MFGPU design thesis: move the pixel back-end
(interpolate + texel fetch + modulate + blend + framebuffer) onto the fabric.

**Live re-measurement (2026-07-13): the `GetDefaultFrameBuffer` crash is FIXED
and verified on real hardware. A live softpipe fps is still pending (below).**

Fixed on the working `mister-sdl-buffer-output` branch of `gmloader-next`
(`8d183e6`, `gmloader/classes/RunnerJNILib.{h,cpp}`). Verified on-device against
the full MiSTer build (10.4 MB, byte-comparable to the known-good deploy):
- `grep -c "does not have static method GetDefaultFrameBuffer"` -> **0** (was present every run before the fix).
- `grep -icE "illegal instruction|SIGILL|SIGSEGV"` -> **0**. The runner boots, links `libyoyo.so`, loads the APK + `game.droid`, and inits SDL/GL without faulting (it crashed within ~2 frames before).

**Build/source lesson (resolved).** An earlier attempt SIGILL'd because it was
built from the bare `master` checkout that `mister-gmloader` had vendored --
which lacks the MiSTer-integration commits (native video, the software-GLES
`libGLES_sw` link, extra libc thunks). Those live on the
`mister-sdl-buffer-output` branch (= `master` + those commits + this crash fix).
Building that branch with the canonical image (`gmloader-armhf-build:bullseye`,
`MISTER_BUILD=1`) yields the working binary; the submodule now tracks it. The
earlier "7 unthunked variadic libc symbols" theory was a symptom of the wrong
source, not a toolchain bug.

**Softpipe fps still pending.** On the pure-softpipe path (`GMLOADER_BLITTER=0`)
the game boots but does not reach steady render within an 80 s window -- one
`Start Frame`, then it sits loading/compositing 2048x2048 texture pages. This
matches softpipe being glacially slow exactly where prior profiling put the
bottleneck (texture sampling), and Maldita's auto-load pause. A clean live
number needs a multi-minute run and/or input to reach the attract loop. **The
prior ~1 fps figure stands as the design baseline.**

**Method (for when the deployment is fixed):**
```sh
ssh root@192.168.20.81
cd /media/fat/games/gmloader
export LD_LIBRARY_PATH="$PWD/mesa:$PWD"
GMLOADER_BLITTER=0 GMLOADER_FPS=1 ./gmloader -c gmloader.json 2>&1 | tee /tmp/gml_sw.log
# read fps from the log once past the title into the auto-attract gameplay loop
```

**Root cause (diagnosed in our source).** The gmloader runtime is our fork
[`gmloader-next`](../../../external/gmloader-next). Its `RunnerJNILib` registers
the native methods the YoYo runner calls back into, via a
`RunnerJNILibNativeMethods` table (`gmloader/classes/RunnerJNILib.cpp`):
GetAppID, GetSaveFileName, ExpandCompressedFile, iCadeEventDispatch,
registerGamepadConnected, initGLFuncs, canFlip, GCMPushResult. **This game's
`libyoyo.so` calls `GetDefaultFrameBuffer`, which is *not* in the table** →
"Class RunnerJNILib does not have static method GetDefaultFrameBuffer" → the
runner gets a null method and derefs it → SIGSEGV. The runner version is newer
than what this `RunnerJNILib` was written against.

**Action for the follow-on plan (Phase 1c/1d):** the crash gate is cleared and
the working build path + branch are established. Remaining A1 work: run softpipe
long enough (or drive input) to log a live fps that replaces the ~1 fps citation
-- not a blocker for the interceptor, which validates against the golden
`blt_execute` oracle rather than the live fps.
---

## A2 Resolution

**Internal render resolution: 288×216** (exact 4:3; the game's name string is
`maldita_castilla_arcade_cabinet`). Three independent signals agree with zero
deviation:
1. **GEN8** `defaultWindowWidth/Height` = 288×216 (payload +0x3c/+0x40).
2. **All 71 rooms** — every room's width/height and every view/camera viewport
   is exactly 288×216. No oversized/scrolling rooms (the game scrolls the
   camera over larger background art, not oversized rooms).
3. **Startup room** `init_values` (room[0]) = 288×216.

GameMaker's `application_surface` defaults to the base/window size = 288×216.

**Fits the on-chip 320×240 RGB565 framebuffer budget? YES.**
- 288 ≤ 320 and 216 ≤ 240.
- 288×216×2 B = 124,416 B ≈ 121.5 KiB, under the 320×240 budget (153,600 B).
- **Note:** the buffer is 288 wide, not 320 — the RBF should either use a
  288-wide stride or pad to the 320 on-chip framebuffer. Upscale to HDMI/analog
  is delegated to MiSTer's hardware scaler (ascal/video_freak), as designed.

This confirms the "compose on-chip at internal ≤320×240" scanout decision holds
for the canary — no SDRAM-framebuffer path needed.

---

## A3 Interception

**Chosen boundary: the GLES2 API, inside our own `gmloader-next` — retarget the
GLES draw thunks. (Option A, and it's already the architecture.)**

The critical realization: gmloader-next *is* the GLES provider. The Android
YoYo runner (`libyoyo.so`) links against Android `GLESv2`; gmloader-next's ELF
loader resolves those imports against a symbol table it owns:

- `thunks/khronos/gles2.cpp` builds `symtable_gles2[2048]`, mapping each GLES
  symbol name to a glad function pointer (`PTR_RESOLVE(x)` →
  `resolve_thunked<&glad_##x>` → `SDL_GL_GetProcAddress` → Mesa softpipe / gl4es).
- `loader/so_util.cpp` `hook_symbol()`/`hook_symbols()` patches the runner's
  import table (GOT) to point at those entries.

So **every** `glDrawArrays` / `glDrawElements` / `glBindTexture` /
`glUniformMatrix4fv` / `glBlendFunc` / `glVertexAttribPointer` / `glBufferData`
the runner issues already flows through code we control. The MFGPU hook is to
register our own interceptor functions for the draw calls (and lightweight
state-tracking wrappers for the others) in place of the glad pointers — no
`LD_PRELOAD`, no game-internal symbol dependence. This is the most stable
boundary: it is the *GLES2 API contract*, invariant across GM runner versions,
not a fragile internal batch-flush symbol.

**Why not option B (internal batch-flush hook):** the GM runner's internal
vertex-batch flush is a private, unexported, version-specific symbol in
`libyoyo.so`; hooking it would be brittle and re-break on every runner update.
The GLES2 boundary gives the same per-batch data with none of that fragility.

**Batch-data mapping (`mfgpu_batch_t` ← GLES2 state at the draw call):**

| field | source at the interception boundary |
|---|---|
| `verts` / `nverts` | the array bound via `glVertexAttribPointer` (position/uv/color attribs) + the count from `glDrawArrays(mode,first,count)` or the deref'd `glDrawElements` range. GM 2D batches interleave `{x,y, u,v, rgba}` — matches `mfgpu_in_vtx_t` directly. |
| `indices` / `nindices` | `glDrawElements(mode,count,type,indices)` args; NULL for `glDrawArrays` (sequential). |
| `mvp[16]` | the last `glUniformMatrix4fv` to the world/projection uniform (track by tracking `glUseProgram` + the MVP uniform location). |
| `tex_off`, `tex_w`, `tex_h`, `tex_stride`, `tex_format` | the currently-bound 2D texture from `glBindTexture(GL_TEXTURE_2D, id)` tracking; dimensions from the `glTexImage2D` that defined `id`. MFGPU stages GM texture pages into the fabric's source heap and maps `id → tex_off`. |
| `blend` | `glBlendFunc`/`glBlendFuncSeparate` state → mapped to `BLT_BLEND_*` (GM's normal/add/subtract/max modes). |
| `screen_w` / `screen_h` | `glViewport` (or the fixed 288×216 internal surface from A2). |

**At-risk field:** the exact vertex attribute layout/stride (which attrib index
is position vs uv vs color, and whether the runner uses client-side arrays vs a
VBO + `glBufferData` + offset) must be read from the live runner. This is being
confirmed by a symbol/import analysis of `libyoyo.so` (whether it emits
`glDrawArrays` vs `glDrawElements`, and client arrays vs VBOs) — see the note
below; it does **not** change the chosen boundary, only the vertex-fetch detail
in the Task C1 contract.

> Runner `.so` import specifics (glDraw* variants, VBO vs client arrays) —
> corroborating evidence pending from the runner symbol analysis; fold in when
> available.

---

## A4 Shaders

**Custom GM shaders: ZERO.** The `SHDR` chunk is present in `game.droid` but its
payload is exactly 4 bytes = a `uint32` count of **0** (chunk offset 360340,
len 4). GameMaker always emits the chunk even with no custom shaders. Corroborated
by `strings game.droid | grep -iE 'shd|shader'`: no `shader_set(` calls, no
`sh_`/`shd_` shader asset names — only the literal `SHDR` chunk tag and the
`display_set_gui_size` GML symbol as noise.

**Implication: Phase 1 needs NO software-shader fallback for this canary.** All
rendering goes through GameMaker's built-in batch/default shaders, which the
FPGA fixed-function renderer replaces wholesale. There are no game-specific
fragment programs to emulate or fall back to.

**Do not conflate** the 48 `.glsl` files in the deployed `shaders/` dir with
custom shaders — those are gl4es-generated translations of GM's *built-in*
pipeline shaders, confirmed non-custom by the authoritative `SHDR` count of 0.

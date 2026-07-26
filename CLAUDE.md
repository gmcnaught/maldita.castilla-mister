# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A MiSTer FPGA core that runs the GameMaker game **Cursed Castilla ("Maldita Castilla")** via **gmloader** (a userspace loader running on the ARM/HPS side, not the FPGA), with the game's 2D rendering **offloaded to a custom FPGA triangle rasterizer/blitter** (the "mfgpu" fabric). It is **not a cycle-accurate core** — the FPGA is used as a GPU for the GameMaker engine. Reasoning about "why is nothing rendering" almost always spans the host engine *and* the fabric, so identify which side a symptom lives on before digging.

## Multi-repo topology (the #1 non-obvious thing)

Three sibling repos under `~/MisterFPGA-Projects/`:

- **`maldita.castilla-mister/`** (this repo) — the FPGA core. `fpga/rtl/` is the **canonical RTL** that builds the RBF; `fpga/sim/` holds Icarus testbenches + the C golden; `deploy.py`; `docs/superpowers/{specs,plans}/`.
- **`../gmloader-next/`** — the **engine** (host C++, cross-built armhf). Key files: `gmloader/mister/blitter.cpp` (intercepts the game's GLES2 calls — the "GL-shadow" layer), `raster_backend_mfgpu.cpp` (the fabric backend + DDR command emitter), `raster_backend_sw.cpp` (software-rasterizer fallback). `3rdparty/mfgpu/` is a **git submodule**.
- **`../mister-fpga-blitter/`** — the **protocol + C reference model** (`refmodel/blitter_ref.c` = `blt_execute`, `host/blt_wire.h`, `host/blt_emitter.c`). Branch `trilist-opcode-10`. This repo is vendored into `gmloader-next` as the `3rdparty/mfgpu` submodule.

**Golden coupling:** `fpga/sim/gen_tri_golden.mk` sets `REFMODEL := ../../../mister-fpga-blitter/refmodel` — the sim golden compiles the reference model from the **sibling checkout**. So a protocol/refmodel change flows: land in `mister-fpga-blitter` → bump the `gmloader-next` submodule pointer → **sync the sibling checkout** (`git -C ../mister-fpga-blitter fetch ../gmloader-next/3rdparty/mfgpu <branch> && git merge --ff-only`) so the sim golden regenerates against it.

## Reference-model-first, bit-exact discipline

The RTL is verified **bit-exact (±1 LSB RGB565)** against the C reference model (`blitter_ref.c`/`blt_execute`, mirrored to the sim golden `fpga/sim/blt_tri.c`). **Any protocol or rendering-semantics change lands in the reference model + host emitter FIRST, then the RTL matches it** — never move RTL semantics without the reference moving in lockstep.

## Build / test / deploy

- **RTL sim (the correctness gate):** `cd fpga/sim && ./run_sims.sh [tb_name]` (Icarus). Pre-existing failures that are NOT your change: `tb_scanout_fbram`, `tb_audio_burst_wedge`; `--tier=nightly` additionally has pre-existing `FABRIC-ASSERT` failures on the `tb_blitter_trilist_*` benches. Regenerate goldens with `make -f gen_tri_golden.mk` (compiles `REFMODEL`).
- **Engine (host, armhf):** Docker via `../gmloader-next/Dockerfile.gmloader-build` → binary at `../gmloader-next/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf` (deploy.py's default path). Host-native unit tests: `make test` in `../gmloader-next/3rdparty/mfgpu/{host,refmodel}`, and `make -f Makefile.gmloader raster-backend-test` (and siblings) in `../gmloader-next`.
- **RBF (Quartus, ~12 min):** GitHub Actions `.github/workflows/build-rbf.yml`, self-hosted **Windows** runner, **Quartus 17.0 Lite only** (newer Quartus is incompatible). Triggers on push touching `fpga/**` (excluding `fpga/sim`, `fpga/scripts`, `fpga/docs`). Fetch the result with `gh run download <id> -n maldita-rbf -D _Other`; STA lives in the `quartus-reports` artifact → `output_files/Maldita.sta.summary`. The fabric `emu` clock is **placement-fragile** and frequently closes slightly negative (~−0.02 to −0.7 ns) — the design still runs on hardware (violating paths degrade gracefully, e.g. occasional wrong-tint pixels); the worst path is usually `pll_hdmi` (the MiSTer framework's HDMI/ascal scaler, out of scope).
- **Deploy:** `./deploy.py [--no-content]` — copies the newest `_Other/MalditaCastilla_*.rbf` + the engine binary (sha1-verified) to `root@192.168.20.81`. `--no-content` skips the 49 MB `game.droid`.

## Device (MiSTer @ `192.168.20.81`, SSH-key/passwordless)

- **Load the core** (deploy.py does NOT do this): `echo "load_core /media/fat/_Other/MalditaCastilla_YYYYMMDD.rbf" > /dev/MiSTer_cmd`.
- **Run the game:** loading the core is enough — MiSTer's **Master_Daemon (Frontier)** watches `/tmp/CORENAME` and auto-runs `/media/fat/games/Maldita Castilla/_handler.sh` (source: `games/Maldita Castilla/_handler.sh`, installed by `deploy.py`; the directory name must equal the `CONF_STR` setname exactly). Log → `/media/fat/logs/MalditaCastilla/maldita.log`. To run it by hand instead: `cd /media/fat/games/gmloader && /media/fat/Scripts/gmloader_diag.sh --preset fabric` (log → `/tmp/gmloader.log`). The fabric path REQUIRES both `GMLOADER_BLITTER=2` and `GMLOADER_RASTER=mfgpu` (`--preset fabric` sets them + profiling env); setting only one silently falls back to the software rasterizer.
- **Do NOT re-enable the `main=` wrapper** (`MiSTer.ini [Maldita Castilla] main=…/MiSTer_Maldita`) without a plan that first fixes its contract debt. A `main=` binary *replaces* MiSTer's `main()` and inherits its obligations — chiefly the scheduler's per-iteration `while (!is_fpga_ready(1)) fpga_wait_to_reset();` (`scheduler.cpp` `scheduler_co_poll`). The wrapper hand-rolls `main()`'s `#else` branch, which is **dead code** (`USE_SCHEDULER` is unconditional, `scheduler.h:4`), and spawns the engine at `maldita_wrapper.cpp:143` **before** its first readiness check at `:157`. Device-measured 2026-07-25 on `.62`, same RBF/engine/classifier: **wrapper 3/5 frame-1 wedges vs stock main 0/5**. The wrapper's features (OSD Reset, joystick SHM, crash-respawn) are unavailable on the handler path — that is the known tradeoff.
- **Go/no-go probe:** `../gmloader-next/tools/fabric_probe.armhf` (scp to `/tmp`) submits one magenta triangle on blue directly to the fabric — proves the composite→scanout path independent of the game.
- **Screenshot:** `echo screenshot > /dev/MiSTer_cmd` → newest PNG in `/media/fat/screenshots/Maldita Castilla/` (320×224). This is a reliable observable of the actual fabric scanout — compare MD5s across time to tell "frozen" from "animating".
- **Peek fabric registers:** `busybox devmem 0x3B000000 32` (C_SUBMIT — climbing means frames are being submitted). `dd` on `/dev/mem` is blocked (CONFIG_STRICT_DEVMEM); use `devmem` (mmap).

## Fabric architecture (the GPU model)

- **DDR blitter region @ `0x3B000000`** (fixed 16 MB window): an 8-qword **control block** (qword-addressed: `C_SUBMIT=0 CMDCOUNT=1 TARGET=2 CLEAR=3 FLAGS=4 DONE=5 STATUS=6 SRCSEL=7`), the command **ring @ +0x40**, and the **SRC texture heap @ +0x80000 (~14.75 MB)**. The host writes the control block, rings the doorbell (`C_SUBMIT`), and polls `C_DONE` for the matching sequence.
- **Memory tiers:** DDR3 (host↔fabric ring + texture inbox) → **SDRAM** (staged texture pages; textures are copied DDR3→SDRAM via `BLT_OP_STAGE`, and the TRILIST texel fetch samples SDRAM) → **on-chip BRAM** (the compositor framebuffer `comp_fbram.sv`: a **WORK** buffer + a **SCAN** buffer, snapshot-copied at vblank for tear-free scanout). `openbor_video_reader.sv` scans out the BRAM and has a **stale-frame watchdog** (blanks to black if the frame counter stalls ~0.5 s).
- **Rasterizer:** `blitter_top.sv` — the `S_TRI_*` FSM is a **draw-order triangle rasterizer** (NOT scanline/line-buffer; `jtframe_lfbuf` does not fit it). C reference: `blt_tri.c` / `blt_raster_tri`.
- **Wire protocol** (`blt_wire.h`, 32-byte commands, `blt_pack_cmd`/`blt_unpack_cmd`): opcodes `NOP/END/FILL/BLIT/STAGE/TILELIST(_RES)/FRT_UPLOAD/TRILIST=10/SET_TARGET=11`; `flags` is a full `uint8_t` — `HFLIP/VFLIP/COLORKEY/STAGE_DST/SRC_SDRAM/SRC_FB/COLORMOD=0x40/SRC_SURFACE=0x80` (all 8 bits used).

## Current work & roadmap

Per-feature specs/plans live in `docs/superpowers/{specs,plans}/`; the durable multi-session execution ledger is `.superpowers/sdd/progress.md` (read it after any interruption — it records completed tasks + the commits that back them). Current feature: **"app-surface as a second BRAM render target" (step 1)** — the GameMaker *application surface* becomes a fabric render-target (`SET_TARGET`/`BLT_F_SRC_SURFACE`), so the scene renders on the FPGA rather than the software rasterizer (this fixes the original "frozen before the title screen" bug, which was a never-invalidated stale render-target texture). Implementation is done and bit-exact in sim; device bring-up found a **texture-heap overflow** (scene spritesheets exceed the ~14.75 MB SRC heap) whose fix is **per-sprite-quad sub-region texture staging** (host-only). Ladder: step 2 = N BRAM surfaces (effect surfaces); step 3 = SDRAM-spilled/tiled render targets for larger sets.

## Gotchas

- **Spawned teammates/subagents do NOT inherit the interactive PATH.** Homebrew tools (`docker`, `iverilog`, `vvp`, `python3`) are at `/opt/homebrew/bin` — prepend it (`export PATH="/opt/homebrew/bin:$PATH"`) or use full paths.
- **GL texture ids are recycled** across GameMaker room transitions — never key persistent host state on a raw GL tex id without invalidating it on `glDeleteTexture`/re-upload.
- The gmloader `3rdparty/mfgpu` submodule and the sibling `mister-fpga-blitter` checkout are the **same repo**; keep them in sync (see Golden coupling above).

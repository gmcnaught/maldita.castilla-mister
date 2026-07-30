# Restart prompt — Maldita fabric wedge / render corruption

Paste the block below into a fresh session. Recall these memories first:
`fabric-hang-comp-fb-dma-active`, `scanout-startup-deadlock-comp-fb-dma`,
`two-orthogonal-vertical-flips`, `host-crash-double-linked-list`.

---

We're debugging the Maldita Castilla MiSTer core (gmloader + FPGA blitter). Use
`superpowers:systematic-debugging`. Read the memories above and
`.superpowers/sdd/progress.md` (gitignored, local, holds the full trail) before acting.

## SOLVED — do not re-investigate

**The wrapper is a working Main_MiSTer replacement.** Video, OSD and controller input
all work with the engine running, and the OSD is unaffected by the game's rendering.
Merged @45e404f.

- **"No signal / no OSD" was `recover_fabric()`'s `fpga_core_reset()` pulse.** That resets
  the WHOLE core — including its video timing generator and the DDR-scanout double-buffer
  handshake — tearing down the video config `user_io_init()` had just applied. Removed in
  6c8ead0. `zero_fabric_ctrl()` was kept (DDR writes only, cannot affect video).
- This very likely also explains the long-standing **"wrapper wedges at frame 1 while the
  traditional launch is healthy, same RBF"** asymmetry that refuted the fill_busy watchdog
  hypothesis. The core reset ran only on the wrapper path. The watchdog itself is sound
  defense-in-depth at zero timing cost — keep it.
- **DO NOT re-add per-core init to the wrapper.** `user_io_init()` already calls
  `cfg_parse()` (user_io.cpp:1456), `video_init()` (:1498), `load_volume()` (:1500) and sets
  `mgl_get()->done = 1` (:1742, under `!mgl_get()->count`). The sibling wrappers
  (`../sonic-mania-mister`, `../3s-mister-arm`) carry a `*_core_context.cpp` only because
  they *conditionally skip* full `user_io_init`; we never do. Adding it cost a wrong fix and
  a revert (ddba57b / f7c1d9b) — the second `video_init()` caused a visible display flash.
- **Engine heap corruption is fixed** (`../gmloader-next-feat2-input`, branch
  `feat/sdl-input`, @59dffa5 + @27b0fd4, LOCAL). The GameMaker runner strcpy's
  `"<save_dir><file>"` into a fixed ~34-byte buffer; it *asks* to be bounds-checked via
  `__strcpy_chk`, but `thunks/libc/fortify.cpp` `#define`s `__check_buffer_access` and
  `__fortify_fatal` to nothing, so the copy runs unbounded. Fix: `/s` symlink to the real
  save dir, hand the runner the short path. Measured: 3-char path clean; 14/19/32/60 all
  overflow. Note `/` is mounted READ-ONLY, so an existing correct link must be reused, not
  recreated. Deliberately still open: the fortify no-ops (enabling real bounds checks may
  turn other currently-survivable overflows into hard aborts).

## Observability you now have (previous sessions were blind)

- `/media/fat/games/gmloader/logs/engine.log` — the engine's stdout/stderr (O_APPEND, so it
  survives crash-respawn).
- `/media/fat/games/gmloader/logs/wrapper.log` — the wrapper's own output.
  **The framework reconfigures stdio inside `user_io_init()`, silently swallowing `printf`
  afterwards** — wrapper messages use `write(2)` (`wlog()`). Do not "fix" this back to
  printf; a swallowed printf once made a healthy loop look like a hang.
- **Isolation flags** (touch/rm on device, no rebuild): `NOENGINE` = framework loop only, no
  child; `NORECOVER` = skip the control-block zeroing. Independent. This is what pinned the
  core reset — use the same one-variable-at-a-time method.
- ASan engine build: `make -f Makefile.gmloader ... ASAN=1` (`-static-libasan`; the rootfs has
  no libasan.so). Run with `ASAN_OPTIONS=quarantine_size_mb=8:detect_leaks=0` — the 256 MB
  default quarantine will not fit in 492 MB RAM. `gmloader.asan` may still be on the device.
- gdb is on the device and the engine has full debug info. The wrapper is stripped: attach,
  then subtract the PIE load base from `/proc/<pid>/maps` before `addr2line` against
  `build/mister-wrapper-hps/src/bin/MiSTer_Maldita.elf`.

## THE REMAINING BUG (start here)

**Frames complete for a while, then progressively fail.** Affects BOTH launch paths, so it is
not wrapper-related. Video evidence (18 extracted frames): correct scene → content dropping
out → severe vertical **downward** colour smearing → watchdog blanks to black. Downward
column streaking from the last good row = the frame was **abandoned partway**, leaving stale
repeated column data below the stall point. Matches the host log exactly:

    backend_mfgpu: fabric submit timeout (submit=3776 done=3727 status=0)

**So the "graphical tearing / garbage tiles" and the fabric wedge are ONE bug, not two.**

Prime suspect (diagnosed in an earlier session, still unconfirmed):
`blitter_top.sv:1600` — `surf_rd_en = appsurf_active ? cr_en : tri_surf_rd_en`. The hard mux
starves the triangle path's surface-texel reads whenever `comp_target==APPSURF`, so the
prefetch queue never drains and `S_TRI_PIX` stalls on its `!pf_empty` exit condition
(`blitter_top.sv:1419`). The engine already warns about exactly this
(`raster_backend_mfgpu.cpp` ~L723).

Options:
1. **Host-side (cheaper, try first):** never leave `comp_target==APPSURF` while emitting
   `SRC_SURFACE` triangles — bind WORK first.
2. **RTL:** round-robin the shared `surf_rd` port instead of the hard mux. Reference-model-first
   discipline applies — check the C golden's arbitration before touching `blitter_top.sv`, and
   the full sim suite must stay bit-exact.

Confirm before fixing: extend the SOLARUS_DBG_PROBES block to publish `pf_empty`, pf occupancy,
`appsurf_active` and the `surf_rd` grant during the stall. Publish somewhere readable **while
wedged** — C_STATUS is written only at S_WR_STATUS (frame completion), so it is unreadable
during a true wedge.

## Separate, minor
Thin garbage bands at the extreme left/right edges, present even in otherwise-correct frames.
Possibly a fencepost in the clear width, or a horizontal analogue of the known
`openbor_video_reader.sv` `V_ACTIVE=240` vs 224-displayed-lines mismatch. Not the main bug.

## Device cheatsheet
- `root@192.168.20.81` (passwordless). Peek regs: `busybox devmem <addr> 32`.
  C_SUBMIT `0x3B000000`, C_DONE `0x3B000028`, C_STATUS `0x3B000030`, wedge probe A
  `0x3B00003C`, B `0x3B000034`, scanout ctrl `0x3BF40000`, reader DIAG `0x3BFF0000`.
- **Scanout frame counter `0x3BFB0018`** (+ frame period in clk_sys cycles at `0x3BFB001C`).
  `C_DONE` counts FABRIC completions; this counts DISPLAYED frames. Take a delta over a
  window: `scanout fps = (n1-n0)/seconds`; `ms = devmem 0x3BFB001C / 98437.5`. Defined in
  `fpga/rtl/openbor_video_reader.sv` (`SCANFRM_ADDR`), gated by `tb_reader_ddr`.
- Load the core from the MiSTer menu under `_Other` (the `main=` hook in `MiSTer.ini`
  `[Maldita Castilla]` launches the wrapper). `load_core` via `/dev/MiSTer_cmd` behaves the same.
- Check `ps | grep /media/fat/MiSTer` before trusting `load_core` — if the frontend is not
  running, `load_core` blocks silently.
- Screenshot: `echo screenshot > /dev/MiSTer_cmd` → newest PNG in
  `/media/fat/screenshots/Maldita Castilla/`. A ~1 KB PNG is the blanked (black) frame;
  identical MD5s across time mean frozen, not animating.
- `build-hps.sh` re-clones upstream Main_MiSTer on **every** run and `rm -rf`s the source tree
  first, so a flaky network breaks the build and destroys the tree. Expect that failure mode.

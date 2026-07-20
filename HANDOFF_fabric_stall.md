# Restart prompt — Maldita fabric stall / scanout debug

Paste the block below into a fresh session (the `superpowers` memory files carry the
detail; this is the kickoff). Recall these memories first: `fabric-hang-comp-fb-dma-active`,
`scanout-startup-deadlock-comp-fb-dma`, `two-orthogonal-vertical-flips`,
`host-crash-double-linked-list`.

---

We're debugging the Maldita Castilla MiSTer core (gmloader + FPGA blitter). Use
`superpowers:systematic-debugging`. Read the memory files named above before acting.

## What's already established (do NOT re-derive)

**ROOT CAUSE of the intermittent fabric stall (the "freezes"): the blitter rasterizer
wedges in `S_TRI_PIX` on its exit condition `!pf_empty`.**
- `blitter_top.sv:1419`: `if ((pa==A_DONE)&&(pb==B_IDLE)&&pf_empty&&!fill_busy) state<=S_TRI_NEXT;`
- Device wedge probe (word A @ `0x3B00003C` = `0x000001F2`) showed at the deepest dwell:
  state=50=`S_TRI_PIX`, pa=7=`A_DONE`, pb=0=`B_IDLE`, fill_busy=0, max_fill_run≈0; bbox
  (word B @ `0x3B000034`) = 319×239 (normal). Three of four exit terms satisfied →
  **`pf_empty` is the blocker**: the prefetch queue (`pf_head/pf_wr/pf_rd`) isn't draining.
- `pf` drains by issuing `surf_rd` surface-texel reads (`tri_surf_rd_en`, ~L1242), but
  `blitter_top.sv:1600` `surf_rd_en = appsurf_active ? cr_en : tri_surf_rd_en` — when
  `comp_target==APPSURF` the tri's `surf_rd` is preempted → `pf` can't drain → wedge.
  This IS the engine's documented warning (`../gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp`
  ~L723: `surf_rd` "starves silently if comp_target==APPSURF and SRC_SURFACE both active").
- Ruled out (by probes): comp_fb_dma copy stall (peak_copy_cyc pinned ~0xA676), texel-fetch
  stall (fill_busy/max_fill_run≈0), runaway geometry (bbox normal), S_SNAP/vblank as the
  primary (was a shorter run's artifact).

**Already SHIPPED on `milestone-a` (all sim-verified):**
1. **Y-flip — SUPERSEDED, read carefully.** An earlier reader-side flip
   (`openbor_video_reader.sv:813` → `(V_ACTIVE-1-display_line)`, dd06c2b) was **reverted** by
   e338f3c. The reader is now FORWARD: display row N shows framebuffer row N. The flip belongs
   at the composite, where the bottom-origin convention actually enters — GameMaker's
   app-surface COMPOSITE quad (GL FBO convention), handled in `raster_backend_mfgpu.cpp`'s
   `src_is_appsurf` branch (gmloader-next e010e04). WORK is top-down by construction
   (`tri_dpidx = tpy*FB_W + tpx`). Measured on device via GMLOADER_MFGPU_UVLOG: v@top=0.8438 >
   v@bot=0.0000, 801/801 composite draws flipped, 533/533 scene→appsurf draws upright.
   This line flipped three times (25af92b → 94fc48d → dd06c2b) — the signature of compensating
   at the wrong layer. **Do not re-flip the reader.** Do NOT touch engine `mf_vflip` either
   (separate, correct texture flip).
   - Open loose end: `openbor_video_reader.sv` uses `V_ACTIVE=240` but
     `openbor_video_timing.sv` displays 224 lines (:187 vs :50). Forward addressing does not
     depend on the pivot, so this is latent — but the dead `display_line == V_ACTIVE-1` branch
     at :843 (first_frame_loaded) shares that root and was deliberately left alone.
2. comp_fb_dma startup-deadlock **watchdog** (SKIP_MAX=32) — verified: boot `ctrl` climbs with
   no manual nudge. Fixes the intermittent black-screen boot lottery.
3. Debug probes (SOLARUS_DBG_PROBES): comp_fb_dma peak_copy_cyc @ `0x3BF40004`; blitter wedge
   probe word A @ `0x3B00003C` `{max_fill_run[23:8],_,fill_busy,pb[3:0],pa[2:0],state[5:0]}`,
   word B @ `0x3B000034` `{maxy,maxx}`.

**Separately known:** host `corrupted double-linked list` glibc crash — KNOWN intermittent
host-side bug (freezes/blanks when it dies; `sub==done` frozen distinguishes it from a fabric
stall where `done<sub`). Not caused by RTL.

## Next steps (pick up here)

1. **Confirm** the `pf_empty` diagnosis with a v3 probe: capture `pf_empty`, pf occupancy,
   `appsurf_active`, and the `surf_rd` grant during the wedge (extend the SOLARUS_DBG_PROBES
   block in blitter_top; publish in a spare control-block hi word like word A/B). Build via CI
   (push to the branch), deploy, read on device.
2. **Fix** (reference-model discipline: surf_rd arbitration is device-only RTL, not the golden
   path). Options, pick after confirming:
   - Arbitrate the shared `surf_rd` port (round-robin cr_en vs tri_surf_rd_en) so tri reads can
     drain `pf` even while `comp_target==APPSURF`, instead of the hard mux at L1600.
   - OR host-side: ensure the engine never leaves `comp_target==APPSURF` while emitting
     `SRC_SURFACE` triangles (bind WORK first).
   - OR make the S_TRI_PIX exit not deadlock when pf holds preempted surface reads.
3. Verify on device: fabric stall gone (`done` tracks `sub`, no `fabric submit timeout` in
   `/tmp/gmloader.log`), and check whether the render corruption (scattered tiles) also clears
   (same app-surface texel path — may be linked).

## Device / build cheatsheet
- Device `root@192.168.20.81` (passwordless). Peek regs: `busybox devmem <addr> 32`.
  C_SUBMIT `0x3B000000`, C_DONE `0x3B000028`, wedge A `0x3B00003C`, wedge B `0x3B000034`,
  scanout ctrl `0x3BF40000`, comp_fb_dma peak_copy `0x3BF40004`, reader DIAG `0x3BFF0000`.
- Reload core: `echo "load_core /media/fat/_Other/MalditaCastilla_YYYYMMDD.rbf" > /dev/MiSTer_cmd`.
  Launch game (detach cleanly to avoid SSH reset): `cd /media/fat/games/gmloader &&
  setsid /media/fat/Scripts/gmloader_diag.sh --preset fabric >/tmp/gl.log 2>&1 </dev/null &`.
- RTL sim gate: `cd fpga/sim && export PATH="/opt/homebrew/bin:$PATH" && ./run_sims.sh`
  (pre-existing fail: `tb_audio_burst_wedge`). Probe-path compile: add `-D SOLARUS_DBG_PROBES`.
- RBF build: push to `milestone-a` → GitHub Actions (self-hosted Windows, ~12 min);
  `gh run download <id> -n maldita-rbf -D _Other`; then `./deploy.py --no-content`.
  NOTE: RBF filename is date-based — `rm -f` the stale local `_Other/MalditaCastilla_<today>.rbf`
  before re-downloading or the extract fails and deploy pushes a stale bitstream.
- **Device is STALE**: still on RBF 20260719 (build 31e4cd8) — that bitstream PREDATES the
  y-flip fix (e338f3c) and the probe revert (d8e95fe), so it will still show the whole-frame
  inversion. Redeploy from milestone-a build 29729001802 before drawing any device conclusions.
  Note d8e95fe turned SOLARUS_DBG_PROBES back OFF, so the wedge probes at `0x3B00003C` /
  `0x3B000034` are NOT live in that build — re-enable the define to land the v3 probe.

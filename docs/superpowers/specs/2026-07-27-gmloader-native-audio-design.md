# gmloader native audio — DDR3 ring to the FPGA, aligned with the Solarus port

Date: 2026-07-27
Status: design approved, not yet implemented.

## Problem

The gmloader/Maldita core is silent. `Maldita.sv:808` ties `AUDIO_L`/`AUDIO_R` to
zero, and the reader is instantiated with `SCANOUT_ONLY(1'b1)` (`Maldita.sv:1047`),
which gates the audio-ring DDR path off. On the host side gmloader has
`gmloader/mister/native_video_writer.c` but no audio counterpart; its PCM goes to
SDL2, and MiSTer's Linux exposes no sound card, so SDL almost certainly falls back
to its `dummy` driver and the audio is produced and discarded.

Meanwhile both sibling ports already solved this. OpenBOR and Solarus push 48 kHz
stereo S16 into a DDR3 ring that the FPGA drains — no ALSA, no Linux sound kernel.
The RTL that does it is *already vendored* in
`maldita.castilla-mister/fpga/rtl/openbor_video_reader.sv`; it is only switched off.

## Why it is switched off

Maldita made the audio addresses `FB_QW_BASE`-relative, then relocated
`FB_QW_BASE` to `29'h077E8000` (0x3BF40000) so the fabric framebuffer would sit
above gmloader's texture heap. That pushed `AUDIO_RING_ADDR` to
`FB_QW_BASE + 0x1A000` = 0x3C010000, past the end of the 16 MiB host mapping at
0x3B000000. Solarus and OpenBOR never had this problem because they do not
parameterize the audio map at all.

## Decisions

### 1. Standardize the audio map on the Solarus decision

Solarus hard-codes absolute localparams (`openbor_video_reader.sv:144-158`), and
`native_audio_writer.c` mirrors them as `NA_DDR_PHYS_BASE 0x3A000000` +
`NA_RING_OFFSET 0x000D0000`. OpenBOR is identical. Maldita adopts the same
absolute constants so all three ports share one audio memory map:

```
AUDIO_WR_ADDR   = 29'h07400006   // 0x3A000030  (was FB_QW_BASE + 6)
AUDIO_RD_ADDR   = 29'h07400007   // 0x3A000038  (was FB_QW_BASE + 7)
AUDIO_RING_ADDR = 29'h0741A000   // 0x3A0D0000  (was FB_QW_BASE + 0x1A000)
```

Ring is 64 KiB = 16,384 stereo S16 frames. `CTRL`/`JOY`/`BUF0`/`BUF1` stay
`FB_QW_BASE`-relative at 0x3BF40000 — video and joystick are untouched. The
0x3A region is dead in fabric builds (`comp_fb_dma` owns the framebuffer, so
`native_video_writer`'s double-buffer there is unused), and decoupling audio from
`FB_QW_BASE` means a future framebuffer relocation cannot break audio again.

`tb_audio_burst_wedge.sv` already hard-codes `AUDIO_RING_LO = 29'h0741A000`, so
the existing sim matches this map with no edit.

### 2. Intercept at a single SDL-shaped shim inside gmloader

gmloader's audio funnels into SDL2 at three places. Rather than patch SDL2 or
hook only one of them, one shim replaces the SDL device calls at all three, so
every producer reaches the ring and all the code lives in gmloader-next.

```
GameMaker runner ──JNI──> AudioTrack shim ─push─┐
FMOD (USE_FMOD=1) ──> FMOD_SDL MixCallback ─pull┤
Kit player (cutscenes) ──> video_ffmpeg ────push┘
                                                 │  per-track SDL_AudioStream
                                                 │  (rate/format → 48k stereo S16)
                                                 v
                                    [pump thread, core 1]
                                                   used = Cap − Free
                                                   if used < TARGET_FILL:
                                                     mix active tracks
                                                     NativeAudioWriter_Submit(...)
                                                   else nanosleep(1 ms)
                                                 │
                                                 v
              DDR ring 0x3A0D0000 (64 KiB / 16,384 frames)
              wr_ptr 0x3A000030 (ARM)  ·  rd_ptr 0x3A000038 (FPGA)
                                                 │
                        openbor_video_reader ST_POLL_AUDIO_WR → ST_PLAN_AUDIO
                        → ST_READ_AUDIO_RING (≤256 B bursts) → ST_WRITE_AUDIO_RD
                                                 │
                        dual-clock FIFO (ddr_clk → CLK_AUDIO 24.576 MHz)
                                                 v
                                          AUDIO_L / AUDIO_R
```

Two properties of the existing call sites drive the shim's shape:

- **FMOD is pull, not push.** `FMOD_SDL.c:280` sets
  `want.callback = FMOD_SDL_MixCallback` and expects the device to ask for
  frames. So a track has two fill modes: push tracks hand us buffers, pull tracks
  get their callback invoked by the pump.
- **`AudioTrack::write` under `WRITE_BLOCKING` spins on
  `SDL_GetQueuedAudioSize(...) != 0`** (`media_AudioTrack.cpp:88-92`). That is the
  runner's real back-pressure and must keep working. The shim's queued-size query
  reports **only what is still in the track's staging stream**, not what the pump
  has already moved into the ring, so the ring remains the cushion (the analogue
  of SDL's device buffer) and the runner paces against the true 48 kHz drain
  instead of blocking the cushion to zero and stuttering.

### 3. Ring-driven pump thread, pinned to A9 core 1

Solarus's `SOLARUS_AUDIO_THREAD` loop, with the same refill-to-fixed-level
property: long-run render rate equals drain rate equals 48 kHz, so no pitch drift
and it self-primes. Same constants as
`solarus-mister/patches/mister/mister_native_audio.cpp:56-57,105`:
`TARGET_FILL_FRAMES = 4800` (~100 ms cushion) and a per-pass cap of
`MAX_FRAMES = 4096` (16 KiB).

Pinning is justified by device conditions specific to gmloader, not copied
blindly. `raster_backend_mfgpu.cpp` pure-spins on `C_DONE` by default
(`GMLOADER_MFGPU_POLL_US` = 0, ~25,000 uncached reads per frame; the comment at
line 425 keeps the knob because the spin "does idle a core that otherwise spins
at 100%"). The only other threads are `blitter_raster.cpp`'s worker pool, which is
fork-join — workers sleep on a condvar while the main thread blocks in
`pool_wait` — and is driven only by the *software* raster backend. So under the
fabric backend core 1 has no resident load, and an unpinned pump would be at the
scheduler's mercy against a 100%-spinning sibling. `WRITE_BLOCKING` compounds
this: the runner's spin only clears once the pump drains staging, so a descheduled
pump lengthens the game thread's block, which slows frames, which delays the pump
further.

- Pump → core 1, main thread → core 0, via `pthread_setaffinity_np`.
- Guarded on `sysconf(_SC_NPROCESSORS_ONLN) >= 2`, else run unpinned.
- Behind `GMLOADER_AUDIO_PIN` (default on) so it can be A/B'd, and so the
  software-raster fallback — where the worker pool genuinely wants both cores —
  can turn it off.

Two honest limits, to be settled by measurement rather than assertion:

1. Pinning fixes *core* contention, not *bus* contention. The C_DONE spin issues
   ~25k uncached DDR reads per frame; the pump adds its own uncached traffic
   (192 KB/s of ring writes plus pointer reads), and the FPGA-side reader bursts
   arrive through `ddr_blitter_arb`. These still collide at the memory
   controller. If audio breaks up in a way pinning does not fix, the
   pre-measured lever is `GMLOADER_MFGPU_POLL_US=250` — it cut poll traffic 12×
   for ~2 ms of frame time, inside scene-to-scene variation.
2. "Core 1 is idle" is inferred from reading the code, not measured. The device
   pass confirms it with `top -H`.

## Components

### `gmloader/mister/native_audio_writer.{c,h}`

Lifted essentially verbatim from `solarus-mister/patches/mister/`. Owns
`/dev/mem` mapped at `NA_DDR_PHYS_BASE 0x3A000000`, ring at `+0x000D0000`,
`NA_RING_BYTES 0x00010000`. API unchanged: `Init` / `Shutdown` / `IsActive` /
`Submit` / `FreeFrames` / `CapacityFrames`. Single-producer, never blocks, drops
the tail on overflow, full `__sync_synchronize()` before publishing `wr_ptr`.

Knows nothing about SDL or gmloader. Depends only on libc and `/dev/mem`.

### `gmloader/mister/mister_native_audio.{cpp,h}`

The shim, and the only component that knows about both sides. Holds a small fixed
table of tracks; each track is `{SDL_AudioSpec desired, SDL_AudioStream *conv,
fill mode, active}`. Public surface is deliberately SDL-shaped so the call sites
barely change:

| Call site | today | after |
|---|---|---|
| `media_AudioTrack.cpp:40` | `SDL_OpenAudioDevice` | `MisterAudio_Open(&desired)` |
| `media_AudioTrack.cpp:87` | `SDL_QueueAudio` | `MisterAudio_Queue` |
| `media_AudioTrack.cpp:91` | `SDL_GetQueuedAudioSize` | `MisterAudio_QueuedBytes` (staging only) |
| `media_AudioTrack.cpp:58,64` | `SDL_PauseAudioDevice` | `MisterAudio_Pause` |
| `media_AudioTrack.cpp:70` | `SDL_ClearQueuedAudio` | `MisterAudio_Clear` |
| `FMOD_SDL.c:288` | `SDL_OpenAudioDevice` w/ callback | `MisterAudio_Open` (pull mode, stores `want.callback`) |
| `video_ffmpeg.cpp:152,309` | open + queue | the same two shim calls |

The pump lives here: ring-driven loop, one non-recursive mutex guarding
track-table lifetime against the mix, `nanosleep(1 ms)` when the ring is topped
up. Pull tracks have their callback invoked from the pump; push tracks are read
out of their stream. Mixing is a saturating S16 sum, skipped entirely when
exactly one track is active — the common case.

The shim also sets `SDL_AUDIODRIVER=dummy` explicitly before `SDL_Init` so the
existing `SDL_Init(... | SDL_INIT_AUDIO ...)` at `main.cpp:506` can neither fail
for want of a device nor grab a real one.

### RTL

Two files:

- `fpga/rtl/openbor_video_reader.sv` — the three audio localparams become the
  absolute constants above; `audio_wake` drops its `!SCANOUT_ONLY` term.
  `SCANOUT_ONLY` continues to gate the ioctl/cart and vsync-writeback paths.
- `fpga/Maldita.sv` — `AUDIO_L`/`AUDIO_R` driven from `nv_audio_l`/`nv_audio_r`
  instead of zero; the reader's `.audio_l`/`.audio_r` connected instead of `()`.
  `.clk_audio(CLK_AUDIO)` is already wired.

## Failure modes

**`/dev/mem` unavailable.** `NativeAudioWriter_Init()` fails, the shim stays
inactive, and `MisterAudio_*` forward to the real SDL calls they replaced —
silence in practice, but gmloader still runs. Mirrors the existing precedent at
`main.cpp:700`. Logged once at startup, never per-call.

**Nothing playing.** The FIFO read side holds its last sample when
`audio_fifo_empty` (`openbor_video_reader.sv:1160` has no `else` branch), so an
empty ring parks the DAC at a DC offset. The pump therefore submits zeros when no
track is active or all are paused. Silence is explicit, never implicit.

**Producer outruns realtime.** `SDL_AudioStream` grows on demand, so each track's
staging is capped at 500 ms; past that `MisterAudio_Queue` refuses the write and
bumps a dropped-frames counter. `WRITE_BLOCKING` already back-pressures the runner
and FMOD's pull mode cannot overproduce by construction, so this is a backstop —
a non-zero counter on device is a bug signal and is logged.

**Ring overflow.** Cannot originate from the pump, which refills *to*
`TARGET_FILL` bounded by `FreeFrames()`. `Submit()` keeps OpenBOR's drop-the-tail
behaviour as a last resort.

**Rate/format mismatch.** Invisible to callers: the shim accepts whatever spec is
requested and returns `obtained == desired` verbatim, converting internally. So
`AudioTrack`'s `desired.samples` arithmetic (`media_AudioTrack.cpp:35`) and FMOD's
`SDL_AUDIO_ALLOW_*_CHANGE` negotiation see exactly what they see today.

**Lifetime.** One non-recursive mutex guards the track table against the mix —
Solarus's `audio_mutex` role. `MisterAudio_Close` and `Clear` take it; the pump
holds it across a mix pass. Shutdown stops and joins the pump *before*
`NativeAudioWriter_Shutdown()` unmaps, so no mix can be in flight over a dead
mapping.

**FPGA-side wedge.** Already covered: `TIMEOUT_MAX` is armed on
`ST_WAIT_AUDIO_RING` (`openbor_video_reader.sv:958`) and `tb_audio_burst_wedge.sv`
regresses the short-burst case. No new RTL risk, but that test moves from dormant
to load-bearing.

## Verification

**Host.** Unit-test `native_audio_writer.c` against a regular file standing in for
`/dev/mem` — the pattern `joy_shm_reader_test.cpp` already uses. Cover wrap-around
at the 64 KiB boundary, `FreeFrames`/`CapacityFrames` accounting, the reserved-frame
`wr == rd means empty` invariant, and tail-drop on overflow. Separately, a shim
test driving push and pull tracks through a fake clock to assert mix correctness,
the staging cap, and silence-on-idle.

**RTL sim.** `tb_audio_burst_wedge.sv` green (no edit needed — it already targets
`29'h0741A000`), plus the scanout regressions, to prove that re-enabling the audio
FSM's DDR traffic does not disturb line fetch. That arbiter interaction is the
part least suited to discovering on hardware.

**Bitstream.** Windows Quartus runner, per the established path. Compare STA slack
against the current build rather than only checking that it passes — the audio FSM
adds states and a DDR consumer to an already tight design.

**Device (`.62`, analog VGA unit).** Title-screen music is reachable despite the
game-not-progressing blocker. Gates:

1. Audio is audible and clean at the title screen.
2. `busybox devmem 0x3A000030` and `0x3A000038` both advance and wrap with a
   steady gap ≈ `TARGET_FILL` — Solarus's ring-health probe.
3. `top -H` shows the pump on core 1 and the game thread on core 0 — this also
   settles whether "core 1 is idle" was right.
4. fps A/B against the current silent build. If audio costs frames,
   `GMLOADER_MFGPU_POLL_US=250` is the pre-measured lever.
5. Clean exit — pump joined, no hang on core swap.

Acceptance: audible and clean at the title screen, ring pointers healthy, pump on
core 1, no fps regression outside scene-to-scene variation, clean shutdown.

## Work isolation

Both siblings are mid-flight on `feat/native-288x216` (maldita has uncommitted
Task-5 sim work), so this runs in separate worktrees branched from `master`:

```
gmloader-next            wt-gmloader-audio   feat/native-audio  <- master
maldita.castilla-mister  wt-maldita-audio    feat/native-audio  <- master
```

Audio is orthogonal to the 288x216 geometry work, so it stays independently
mergeable and the device RBF is built from a known-good base.
`openbor_video_reader.sv` is touched by both branches but in disjoint regions
(audio localparams and audio FSM vs FB dims and strides), so the eventual merge
should be clean.

The superproject (`mister-gmloader`) bumps both submodule pins once the branches
land. Per project memory, `deploy.py` builds the engine from a *sibling checkout*,
not the submodule — so the device pass must pass `--engine` explicitly and md5 the
deployed binary.

## Out of scope

- The title-screen / game-not-progressing blocker. Audio is verified at the title
  screen; reaching in-game scenes is a separate investigation.
- Any change to the video or joystick DDR map. Those stay `FB_QW_BASE`-relative.
- MT32-pi / I2S capture, retired with native video and not revived here.

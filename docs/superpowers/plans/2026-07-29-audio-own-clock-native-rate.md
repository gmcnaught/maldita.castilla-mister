# Audio: own clock, own DDR channel, native 22.05 kHz

**Branches:** `maldita.castilla-mister@feat/audio-own-clock` (worktree `wt-maldita-audioclk`,
based on `origin/milestone-a` @ 5fe0115) and `gmloader-next@feat/audio-native-rate`
(worktree `wt-gmloader-audioclk`, based on `origin/master` @ ee7e21e).

## Why the current path drifts

**Observed.** Audio is drained by an FSM *inside* `openbor_video_reader`
(`fpga/rtl/openbor_video_reader.sv`, states `ST_POLL_AUDIO_WR` … `ST_WRITE_AUDIO_RD`,
~152 lines). It shares the video scanout DDR master through `ddr_blitter_arb` m0 on
`clk_sys` (`fpga/Maldita.sv:1102`), bursting up to 1024 B into a 1024-deep `dcfifo`
whenever `audio_fifo_wrusedw < 640`, stolen from video idle windows. The `clk_audio`
side pops one frame per `aud_tick` at a *fixed* 48 kHz (`clk_audio/512`).

Refill is best-effort and open-loop; drain is a fixed rate. When refill loses the race
the pop is spent on an empty FIFO (`aud_uf_cnt`), so the *effective* rate falls below
48 kHz. That is exactly the `-1.44%` deficit / 700 underflows-per-second that
`fix/audio-refill-throughput` (merged as `5fe0115`) tuned down to `-0.013%` by
quadrupling the burst. Tuned, not structurally fixed.

**MiSTer's ALSA path does it the other way round.** `fpga/sys/alsa.sv`:

- Its own DDR read channel — `ddr_svc` ch0 on the `ram2` port
  (`fpga/sys/sys_top.v:664-693`), `.ch0_burst(1)`, single 64-bit word per request.
  Nothing to do with the core's DDRAM master.
- Runs entirely in `clk_audio` (24.576 MHz). No CDC, no dcfifo.
- Closed-loop consumer clock (`alsa.sv:145-155`):
  `acc += 48000 + {hurryup,6'd0}`, with `hurryup ∈ {0,1,2,4}` ramped from the
  `buf_wptr - buf_rptr` backlog (`alsa.sv:90-100`). The consumer *slews to the
  producer's actual long-run rate*, so drift cannot accumulate.

That closed loop is the property being ported. The dedicated channel is what makes the
loop's assumption (a fetch always lands before the next sample tick) hold.

## Target architecture

New `fpga/rtl/gm_audio.sv`, structurally `alsa.sv`, in `clk_audio`:

```
gm_audio #(CLK_RATE=24576000, SRC_RATE=22050, RING_BYTES=65536)
  ram_address[31:3] / ram_data[63:0] / ram_req / ram_ready   -> ddr_svc ch0
  pcm_l / pcm_r                                              -> audio_out core_l/core_r
```

**Ring map (unchanged, absolute — see [[maldita-reader-contract-addresses]]):**
ring `0x3A0D0000` (64 KiB), `audio_wr_ptr` `0x3A000030`, `audio_rd_ptr` `0x3A000038`.

**Pointer transport.** `alsa.sv` gets `buf_addr/len/wptr` free over SPI from
Main_MiSTer. We have no such agent — gmloader writes DDR directly — so `gm_audio`
polls `audio_wr_ptr` on its *own* channel (one 64-bit read, budgeted below). Base and
length are compile-time constants, so only `wr_ptr` moves.

**Fractional resampler replaces both the fixed tick and the host resampler.** Output
runs at exactly 48 kHz (`clk_audio/512`). A phase accumulator scaled so 1.0 = 65536:

```
inc      = INC_NOM + {hurryup, 4'd0}          // INC_NOM = round(65536*22050/48000) = 30106
phase   += inc                                 // per 48 kHz tick
advance  = phase[16]                           // inc < 1.0, so 0 or 1 source frames
frac     = phase[15:0]
out      = s0 + (((s1 - s0) * frac) >>> 16)    // linear, one 17x16 mul per channel
```

One accumulator does interpolation *and* rate matching: `hurryup` adds to `inc`, which
is the same closed loop `alsa.sv` runs, expressed in the resampler's own units.

- `INC_NOM = 30106` vs the exact `30105.6` → +6.1e-6 relative, ~0.13 Hz at 22050. Below
  the loop's correction granularity, and the loop absorbs it anyway.
- Slew range: `hurryup ∈ {0,1,2,4}` × 16 → up to +64/30106 = **+0.21%**. Producer-faster
  only, matching `alsa.sv`'s asymmetry — a slow producer is absorbed by the hold.

**Bandwidth.** 22050 frames/s = 11025 qwords/s = one read per ~2230 `clk_audio` cycles,
plus a `wr_ptr` poll per 512 ticks (~1 ms). ch1 (HDMI palette) is dormant here —
`MISTER_DISABLE_PALETTE1=1`, `fpga/Maldita.qsf:19`. Effectively an uncontended channel.

## Why this is the quality-neutral version

Feeding a 22.05 kHz zero-order hold into `core_l/core_r` would put images from 11 kHz
up, suppressed only by whatever `audio_filter` profile the user happens to enable —
and `aud_mix_top` (`fpga/sys/audio_out.v:225-250`) sums `linux_audio` **unfiltered**,
so the alsa port is not an option either. The linear interpolator above removes that
regression, so dropping `SDL_AudioStream` costs no audio quality while removing an A9
resampler from the frame budget.

`gm_audio.pcm_l/r` therefore drives `audio_out`'s `core_l/core_r` (which does get the
IIR + DC blocker), **not** `alsa_l/r`.

## Tasks

### T1 — `fpga/rtl/gm_audio.sv`
New module per above. `got_first` startup behaviour from `alsa.sv:113-117` (on the
first non-empty backlog, jump `rptr` to `wptr`, dropping stale ring contents).
A 4-entry qword staging buffer ahead of the interpolator so DDR latency and ch1
arbitration can never stall a sample tick.

### T2 — `fpga/sim/tb_gm_audio.sv`
Icarus TB against a behavioural `ddr_svc` + ring model. Non-vacuous gates:
1. **Rate lock:** producer writes at 22050 ± 0.15%; over 5 simulated seconds
   `rptr` advance matches production to < 1 frame, and `hurryup` settles non-zero
   only when the producer is fast.
2. **Interpolation correctness:** a 1 kHz sine in the ring comes out at 48 kHz with
   THD below the linear-interp bound; a DC ramp comes out exactly linear.
3. **Starvation:** producer stops → output holds, no wraparound garbage, and recovery
   re-locks without a `got_first` re-sync.
4. **Wrap:** `rptr` crossing the 64 KiB boundary is sample-continuous.

### T3 — `fpga/sys/sys_top.v` + `fpga/Maldita.qsf`
Add `MISTER_DISABLE_ALSA=1` to the qsf (frees ch0; `alsa.sv`, its SPI master, and its
ch0 wiring all drop out via the existing `ifndef` guards at `sys_top.v:679,1646,1662`).
Instantiate `gm_audio` under `MALDITA_CORE`, drive `ddr_svc` ch0, and source
`audio_out`'s `core_l/core_r` from it instead of emu's `AUDIO_L/R`.

Consequence to state plainly: Linux/Main_MiSTer ALSA audio (menu beeps) goes silent in
this core. Nothing in the gmloader path used it — native audio bypasses the sound
kernel entirely.

### T4 — strip the audio FSM from `openbor_video_reader.sv`
Delete states `ST_POLL_AUDIO_WR`/`ST_WAIT_AUDIO_WR`/`ST_PLAN_AUDIO`/`ST_READ_AUDIO_RING`/
`ST_WAIT_AUDIO_RING`/`ST_WRITE_AUDIO_RD`/`ST_AUD_STATS`, the `dcfifo`, the
`AUDIO_REFILL_*`/`AUDIO_BURST_*` params, the tier-2 counters and `AUDIO_STAT_ADDR`, and
the `clk_audio`/`audio_l`/`audio_r` ports. Update `fpga/Maldita.sv:859-866,1102+`.

Secondary win: the video FSM gets its idle windows back — this is bandwidth returned to
the 60 fps budget, not just a cleanup.

### T5 — host: native rate (`wt-gmloader-audioclk`)
- `native_audio_writer.h:26` `NA_SAMPLE_RATE` 48000 → 22050.
- `mister_native_audio.cpp:32` `kTargetFillFrames` 4800 → `NA_SAMPLE_RATE/10` (the
  constant is 100 ms of audio; hardcoding 4800 silently became 218 ms at the new rate).
- `mister_native_audio.cpp:26` staging-cap comment, and the `48000 Hz` banner at :176.
- Everything else already derives from `NA_SAMPLE_RATE`.
- Tracks opened at 22050 make `SDL_AudioStream` an identity copy; ffmpeg cutscene audio
  at 44.1 kHz still converts, which is correct and rare.
- `mister_native_audio_test.cpp` — re-baseline the 48000 assumptions at :55,:62,:176.

### T6 — verify
- **Assumption to close first (cheap, decisive):** the shim already logs
  `track N opened: %d Hz` (`mister_native_audio.cpp:236`). Confirm on device that the
  game's track really is 22050 before trusting `SRC_RATE`. If it is 44100, `SRC_RATE`
  and `INC_NOM` change and nothing else does.
- Host suite green (T2/T5). Icarus battery green.
- Quartus on the Windows runner (see [[maldita-rbf-build-uses-windows-runner]]).
  Check `grep 276007 *.map.rpt` for M10K uninference in the new staging buffer — the
  rule from [[native-audio-sta-regression]]: a `ramstyle` array's read must never be
  nested in an FSM case arm.
- Device: ring deficit and underflow rate should be *structurally* zero, not tuned.
  A soak on .81 with the handler off and the correct cwd
  ([[manual-device-testing-needs-handler-off-and-correct-cwd]]), sole engine instance
  ([[native-audio-does-not-wedge-the-fabric]]).

## Open items

- Sustained-silence DC: `gm_audio` holds the last sample when starved, like `alsa.sv`.
  The host pump already submits silence continuously so the ring never empties, which
  keeps this unreachable in practice. Not gold-plating it in this pass; noted.

---

## Status 2026-07-29 — PAUSED (user decision)

Code-complete and deployed to `.62` (RBF `MalditaCastilla_f348626.rbf`). T1-T5
done; T6 partially done.

**Closed on hardware.** The game's track really is `22050 Hz, 2 ch, push`, so
`SRC_RATE`/`INC_NOM` are correct. `rd_ptr` advances and wraps; ring occupancy is
stable at ~6940 B (~1735 frames) and neither drains nor pins. STA `-0.159` /
TNS `-0.317` (baseline `5fe0115` was `-0.167` / `-0.329`), ALMs 15,655 vs 16,107,
M10K clean apart from the pre-existing `xq_mem`. Sim 51/51.

**Two defects found by device testing, not by sim.** Both are recorded because
each was a gap in method, not just in code:

1. **Missing `rd_ptr` writeback** (fixed, `f348626`). The port of `alsa.sv`
   covered the inbound `wr_ptr` poll and missed the outbound half, so
   gmloader's `FreeFrames()` saw a ring that never drained. Sim could not catch
   it because the TB's pump read `dut.rptr` — the DUT's private pointer —
   instead of the published one. Gate E and the pump rewrite close that.

2. **Audible starvation artifact** (OPEN). Drain measures **21,872.9 f/s =
   99.20%** of 22,050. −0.80% exceeds the slew loop's total authority of
   ±0.21% (±4 × `SLEW_STEP`16 / 30106), so most of it is `st_empty` holds
   repeating samples. Occupancy of 1735 frames rules out the ring; prime
   suspect is the 4-qword staging buffer (8 frames ≈ 0.36 ms) against DDR3
   latency that ram1/vbuf/refresh still perturb even though `gm_audio` owns
   ram2.

**Next step is instrumentation, not a fix.** The tier-2 counters
(`aud_uf_cnt`, `aud_fifo_min`, `AUDIO_STAT_ADDR`) were deleted with the old FSM
and `gm_audio` has no equivalent, so neither starvation count nor `slew` is
readable from the device. Add a stats publish job to the existing FSM first —
otherwise choosing between "deepen `ST_DEPTH` 4→16" and "widen `SLEW_STEP`" is
guesswork. This repo has been burned twice before by fixing a statically-inferred
cause without a counter.

**Do not merge, and do not deploy to `.81`** (production) in this state.

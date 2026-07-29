# Audio/video sync + playback-rate diagnostics

Branch: `diag/audio-sync` (worktree `../wt-maldita-audiosync`), based on `milestone-a` @ 64b7272.
Status: **Phase 1 (root-cause investigation) — instrumentation only. No fixes in this branch.**
Symptom under investigation: audio is not synchronised to video, and plays at the wrong speed.

This plan deliberately stops at *measurement*. Every mechanism listed in "Candidate
mechanisms" is a hypothesis; none has been confirmed on hardware. The tiers below are
ordered cheapest-decisive-first so Tier 0 alone eliminates roughly half of them.

---

## 1. The clock chain (Observed, from code)

Read end-to-end so the rate arithmetic is on the record.

| Stage | Rate | Source |
|---|---|---|
| Game (GameMaker) PCM producer | caller-declared `sampleRateInHz` | `jni/classes/media_AudioTrack.cpp:35` |
| Rate/format conversion | `SDL_AudioStream` → 48 000 Hz stereo S16 | `mister_native_audio.cpp:204-206` |
| Staging cap | 500 ms (`kStagingCapBytes`) | `mister_native_audio.cpp:27-28` |
| Pump target ring fill | 4 800 frames = 100 ms | `mister_native_audio.cpp:32` |
| DDR ring | 64 KiB = 16 384 frames, 1 frame reserved → 16 383 usable | `native_audio_writer.c:30`, `:112-116` |
| DDR mapping | `/dev/mem` `O_SYNC` (uncached) + `__sync_synchronize()` before `wr_ptr` | `native_audio_writer.c:51`, `:144` |
| FPGA ring drain (DDR→FIFO) | bursts ≤ 256 B, armed when FIFO `wrusedw < 384` qwords | `openbor_video_reader.sv:185`, `:458-462` |
| FPGA FIFO → `AUDIO_L/R` | `clk_audio`/512 = 24.576 MHz/512 = **48 000.00 Hz exactly** | `openbor_video_reader.sv:1205-1222` |
| MiSTer `audio_out` | samples `AUDIO_L/R`, `AUDIO_S=1`, `AUDIO_MIX=0` | `fpga/Maldita.sv:231`, `:813-815`; `fpga/sys/sys_top.v:1624` |
| Video scanout | 380 × 262 @ 53.693 MHz ÷ 9 = 5.9659 MHz → **59.923 Hz**, free-running | `openbor_video_timing.sv:51-62`, `openbor_video_top.sv:8` |

Two consequences that fall straight out of this table:

1. **Video scanout is free-running and never waits for the engine.** The 59.923 Hz
   output re-scans whatever is in the BRAM/DDR framebuffer. Engine frame rate and
   display frame rate are decoupled; there is no vsync lock in either direction.
2. **The audio sink rate is fixed and open-loop at 48 000 Hz**, but the *pump* is
   closed-loop on ring occupancy (`PumpOnce` tops up **to** a level, so long-run
   submit rate == long-run drain rate). Pitch is therefore exact **iff** the ring
   actually drains at 48 kHz and the producer keeps up. Both of those are the things
   to measure.

## 2. Candidate mechanisms (unconfirmed — this is the hypothesis list, not findings)

- **H1 — FIFO starvation stretches the audio.** On `aud_tick` with
  `audio_fifo_empty`, `openbor_video_reader.sv:1240-1252` *holds the previous sample
  and does not pop*. Sustained starvation makes the effective drain rate < 48 kHz, i.e.
  audio literally plays slow and accumulates lag behind video. Audio is the *lowest*
  priority requester in the reader FSM (`:626-646`, `:816-821`) and shares DDR with the
  blitter through `ddr_blitter_arb`. Tier 0 measures this directly.
- **H2 — silence-fill displaces real audio.** `PumpOnce` zeroes `g_mixbuf` and submits
  the shortfall as silence on *every* pass, not only when the ring is near dry
  (`mister_native_audio.cpp:311-347`). Any pass where staging is momentarily empty
  injects silence that permanently displaces later real samples. If the producer runs
  at 26 fps-equivalent instead of real time, ~half the stream becomes silence — audible
  as stutter/"wrong speed" at correct pitch. Tier 1 measures the silence fraction.
- **H3 — the blocking write throttles the game loop.** `AudioTrack::write` with
  `WRITE_BLOCKING` spins on `SDL_Delay(0)` until staging is **completely** empty
  (`media_AudioTrack.cpp:133-148`), not until it drops below a watermark. On a 2-core
  DE10-Nano where the fabric backend already pure-spins on `C_DONE`, that couples video
  pacing to audio drain. Tier 1 measures the spin time and the calling thread.
- **H4 — latency, not rate.** Up to 500 ms staging + 100 ms ring = 600 ms of audio
  behind the frame that triggered it, against a video path with its own (different)
  latency. That is a sync error even when every rate is perfect. Tier 1 measures
  steady-state occupancy of both.
- **H5 — the game itself is running slow.** If GameMaker's fixed-step logic runs at
  ~26 fps while streamed music plays in real time, gameplay and music diverge with no
  audio-subsystem defect at all. This is what the parallel `perf/60fps-*` work targets;
  Tier 1's engine-fps counter tells us how much of the symptom it will absorb.

H1/H5 produce "slow"; H2 produces "choppy"; H3/H4 produce "offset". The user-visible
symptom mixes these, so the measurements must separate them rather than a fix guessing.

## 3. Tier 0 — decisive, no rebuild (device shell)

Answers one question: **is the FPGA actually draining the ring at 48 000 Hz?** That
single number splits H1 from everything else.

Method: sample `rd_ptr` (0x3A000038) and `wr_ptr` (0x3A000030) on a fixed interval and
unwrap modulo 64 KiB.

- Ring wraps every 65536 / 192000 B/s = **341 ms**, so the sample interval must be
  ≤ 150 ms or a wrap is indistinguishable from a stall. `busybox devmem` per sample in a
  shell loop is too coarse and too jittery — build `tools/audio_ring_probe.armhf`
  (mmap `/dev/mem`, `CLOCK_MONOTONIC`, 100 ms cadence, N seconds), same pattern as the
  existing `tools/fabric_probe.c`.
- Report per interval and cumulative:
  - `drain_hz` = Δ`rd_ptr` (unwrapped) / 4 / Δt — **expect 48000.0 ± 5**
  - `submit_hz` = Δ`wr_ptr` (unwrapped) / 4 / Δt
  - `occupancy_frames` = ((wr − rd) & 0xFFFF) / 4 — expect ~4800, stable

Decision table:

| Observation | Reading | Next |
|---|---|---|
| `drain_hz` ≈ 48000, occupancy stable ≈ 4800 | Stream rate is correct; H1 dead | Tier 1 (H2/H3/H4/H5) |
| `drain_hz` < 48000 | FPGA FIFO starvation confirmed (H1) | Tier 2 |
| occupancy pinned near 0, `submit_hz` < 48000 | Producer starvation (H2/H5) | Tier 1 |
| occupancy pinned near 16383 | Drain stalled / pointer-protocol fault | Tier 2 |

Run it three ways so DDR contention is a controlled variable: idle at the title screen,
during gameplay, and with `GMLOADER_RASTER=sw` (software rasterizer, fabric mostly idle).

## 4. Tier 1 — host instrumentation (engine rebuild, no RBF)

Counters + a once-per-second line to `maldita.log`. Gate behind
`GMLOADER_AUDIO_STATS=1` so ship builds are unaffected.

`gmloader/mister/mister_native_audio.cpp`:
- `frames_submitted_total`; `frames_silence_total` (frames submitted on passes where
  `mixed == 0`, plus the zero-padded tail when `got < want_bytes`) → **silence fraction**
- pump passes/sec, and passes returning 0
- per-track: frames contributed, `SDL_AudioStreamAvailable` min/max/mean
- `g_dropped` (already tracked — just publish it; non-zero is a bug signal per the header)

`gmloader/mister/native_audio_writer.c`:
- ring occupancy min/max/mean, submits that were clamped by `FreeFrames()`

`jni/classes/media_AudioTrack.cpp`:
- per-track `write()` calls/sec and source bytes/sec (→ producer's real-time rate ratio)
- cumulative time in the `WRITE_BLOCKING` spin, and `pthread_self()` of the caller vs the
  main thread — this is what confirms or kills H3
- the `desired` spec actually requested (freq/format/channels/`samples`)

Video-side counterpart in the same log line, so sync is measurable and not inferred:
- engine frame submits/sec (`C_SUBMIT` delta) vs the fixed 59.923 Hz scanout
- GameMaker logic fps

Derived numbers to read off: silence fraction, producer real-time ratio
(`bytes/sec ÷ (freq × frame_bytes)`), audio latency (`staging + ring` in ms), and
audio-fps vs video-fps.

## 5. Tier 2 — RTL counters (only if Tier 0 shows `drain_hz` < 48000)

Costs an RBF rebuild (~12 min, Quartus 17.0 Lite, Windows runner). In
`openbor_video_reader.sv`, CDC to `ddr_clk` and publish into a debug qword (the existing
beacon at 0x3A070010 is the precedent):

- `aud_underflow_cnt` — `aud_tick && audio_fifo_empty`. **Non-zero ⇒ H1 confirmed**, and
  the count is exactly the number of stretched samples.
- `aud_fifo_min_occupancy` — headroom margin over the run
- `aud_burst_cnt`, `aud_backoff_cnt` (`avail == 0` path, `:1013-1016`),
  `aud_plan_zero_cnt` (`:1022`), and time-stuck in `ST_WAIT_AUDIO_RING`

Sim gate to add alongside: extend `fpga/sim/tb_audio_burst_wedge.sv` (currently PASS —
the "pre-existing failure" note in CLAUDE.md is stale, verified 2026-07-28) with a rate
assertion: with a continuously-fed ring, exactly 48 frames pop per simulated
millisecond and `aud_underflow_cnt == 0`. That turns H1 into a regression test rather
than a device observation.

## 6. Out of scope for this branch

No fix lands here. Once Tier 0/1 identify the mechanism, the fix goes on its own branch
and rebases onto whatever the `perf/60fps-*` cycle produces — H5's magnitude in
particular is not knowable until that cycle lands.

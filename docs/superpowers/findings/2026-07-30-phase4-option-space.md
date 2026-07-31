# Phase 4 option space — three tracks, and the DDR options under them

**Date:** 2026-07-30
**Status:** options register, not a plan. Nothing here is committed to.
**Context:** Phase 3 shipped 46.3 → 55.6 fps (fabric 19.30 → 16.20 ms). This
records the reframing and the platform research that came out of the Phase 3
retrospective, so Phase 4 planning starts from it.

## The reframing: track host and fabric capability independently

Previously we optimized one aggregate number (fabric ms) against one gate. The
better decomposition, per the project owner:

1. **Host production** must reach ≥60 fps (more is fine).
2. **Fabric processing** must reach ≥60 fps (more is fine).
3. **DDR traffic** must not artificially limit either.

Applying it to the Stage B measurements changes the priority order:

| Track | Quiet scene today | Arrival today |
|---|---|---|
| Host production | work ≈ 8–10 ms (`logic` 5.9–7.9 + `raster` 2.3) → **capable of 60** | same host work |
| Fabric processing | 16.20 ms = **61.7 fps → already clears 60** | 21.37 ms = 46.8 fps → **1.28× short** |
| Delivered | 18.00 ms = 55.6 fps | ~23 ms ≈ 43 fps |

**On the quiet scene both tracks already individually clear 60 fps.** The 55.6 we
deliver is neither track's capability — it is the **1.89 ms exposed host tail**,
i.e. the serialization between them (period ≈ fabric + exposed host). That
indicts the old `fabric ≤ 14.80 ms` gate: it was asking the fabric to absorb the
host's coupling cost. Closing ~1.4 ms of coupling reaches 60 fps on quiet with
the **already-deployed bitstream**.

The genuine Track-2 gap is the arrival scene, and opaque cull is the only lever
sized to reach it (66 % quiet / 75 % arrival of covered px are opaque-occluded).

## Track 3: what the platform docs say, checked against our RTL

### Verified against our source

- **Our SDRAM texel latency is at the platform floor.** JTFRAME's measured MiSTer
  SDRAM latency is 9 min / 11–12 avg / ~33 max cycles at 96 MHz; our device miss
  cost is ~12 cycles. `texwait` can therefore only improve via **fewer misses**,
  never faster fetches. Closes that line of inquiry.
- **The blitter's DDR3 FSM traffic is single-beat.** `blitter_top.sv:2454`:
  `assign mem_burstcnt = pipe_busy_q ? p_mem_burstcnt : 8'd1;`. The framework doc
  states DDR3 latency is *"something like 20 cycles @ 100 MHz… but it can be way
  longer"* and that *"higher burst counts are recommended"*. ~106 command groups
  × 4 qwords/frame = ~424 separate round-trips, each paying full latency. This is
  the leading suspect for the **1.53 ms unattributed `ovhd` residual** (device
  2.32 vs 0.795 accounted), which is fixed-per-submit and immune to every dpath
  lever — the residual's measured signature matches. **Needs a counter to confirm
  attribution before acting.**
  (For contrast the scanout reader does it right: one `LINE_BURST` = 72-qword
  burst per scanline, `openbor_video_reader.sv:930`.)
- **DDR3 is shared with the HPS, and our HPS runs a full game engine.** Most
  cores' HPS is near-idle; ours runs gmloader (game logic, texture staging,
  present/capture). **Host memory traffic is therefore a fabric performance
  lever** — a Track-1/Track-3 coupling invisible to any fabric-only measurement.
- **`DDRAM_BUSY` is a pure request inhibit**: *"Request signals can remain
  asserted; they'll be accepted when DDRAM_BUSY deasserts."* Held requests are
  legal at the framework boundary; our reader re-polls. Our internal arbiter's
  busy has different semantics, so this needs care — noted, not prescribed.
- **The framework gives no multi-master arbitration guidance at all.** Our
  `ddr_blitter_arb` + `f2h_slot_mux` is bespoke, which is consistent with its
  failure history (poll-before-issue livelock, late-f2h-beat mis-steer, startup
  wedge). That subsystem warrants more instrumentation than the rest.
- SDRAM refreshes every 64 µs regardless of core clock (~6,300 cycles at
  98.4375 MHz) — a periodic stall we model nowhere.

### Option A — use the hardware arbiter instead of ours

The Cyclone V hard memory controller has a Multi-Port Front End that arbitrates
FPGA-side ports **in hardware** (up to 6 command ports, programmable priority /
QoS). We are not obliged to arbitrate in fabric.

`sys_top.v:676` states it directly:

> `sysmem exposes exactly three f2h ports -- ram1 (emu DDRAM), ram2, vbuf`
> `(ascal) -- so this IS the dedicated channel; a fourth would mean regenerating`
> `the Platform Designer system.`

Current allocation:

| Port | Width | Owner |
|---|---|---|
| `ram1` | 64-bit | **blitter + scanout reader**, sharing via our `ddr_blitter_arb` |
| `ram2` | 64-bit | `gm_audio` — given the port **outright** in the audio phase |
| `vbuf` | **128-bit** | `ascal`; `sys_top.v:669` says this core **deliberately does not set `MISTER_FB`** |

The precedent is ours: the audio phase moved `gm_audio` to its own port so "the
audio path cannot be contended by construction," **deleting** an arbiter
(`ddr_svc`) rather than improving one. The same argument applies to the two
masters still contending on `ram1` — precisely the two whose arbitration produced
our three worst bugs. `vbuf` is double-width and appears idle.

**To verify before believing:** (a) that `ascal` issues no `vbuf` traffic with
`MISTER_FB` unset (the comment says its palette channel is dead code — confirm
with a counter); (b) whether MPFE default port priorities suit a hard-real-time
scanout reader or need QoS programming from the HPS.

### Option B — the lightweight HPS-to-FPGA bridge for control traffic

LWH2F: 32-bit at `0xFF200000`, 2 MB span, low bandwidth but low, **deterministic**
latency — it bypasses the DDR round trip.

**Good fit: the control block.** `raster_backend_mfgpu.cpp:779` records that *"the
3-vsync latency is notice/DDR-visibility, not the fabric"* — our doorbell path is
host → DDR3 → fabric f2h read, paying DDR3 latency in both directions purely to
*notify*. Moving doorbell / ring pointers / `C_DONE` behind the LW bridge cuts
that to a bus transaction and removes the traffic from the DDR3 arbiter.

**Poor fit: the command/vertex ring.** It fits by size (~14 KB/frame vs 2 MB), but
LW writes are uncached single 32-bit CPU transactions: ~3,600 writes/frame at
~100–200 ns ≈ **0.4–0.7 ms of host time to save fabric time** — trading Track 1
for Track 2, plausibly a net loss. Measure before committing. If bulk staging
should leave DDR3, the full-width H2F bridge is the right vehicle, not LW.

### How the options compose

Dedicated f2h ports fix **contention** for bulk traffic; the LW bridge fixes
**latency** for control traffic. Neither needs the run-ahead we currently use to
hide both. Today we have three stacked run-aheads — double-buffered arenas, the
deferred `C_DONE` await, and the 8-pixel texel prefetch — each hiding a latency
rather than removing it. They are also why the frame limiter's cost stayed
invisible through Phase 2: slack absorbs mistakes until it doesn't.

**Cost caveat on both:** they mean editing `sys_top.v` / the Platform Designer
system, which MiSTer says to keep read-only and sync from upstream. Reallocating
the three ports that already exist does **not** require regenerating Qsys; a
fourth port would.

## Unmeasured, per track

- **Track 1:** host standalone throughput has never been measured — only its
  exposed remainder (1.89 ms).
- **Track 3:** no per-master DDR3 occupancy or stall attribution exists; the
  1.53 ms `ovhd` residual has no instrument pointing at it.
- **Track 2:** well instrumented (the real-cache stream bench predicted device
  fabric to +0.31 % and texwait to +1.1 %).

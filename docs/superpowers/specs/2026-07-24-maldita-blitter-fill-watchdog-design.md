# Blitter texel-fetch (`fill_busy`) self-heal watchdog — Design

**Date:** 2026-07-24
**Component:** `fpga/rtl/blitter_top.sv` (RTL-only; the fabric rasterizer)
**Status:** Approved design → implementation plan next.

## Problem

On device, the fabric **wedges at frame 1** under the supervisor-wrapper launch path
(`MiSTer_Maldita`, `main=` armed): `C_SUBMIT` climbs while `C_DONE` stays `0` — the
blitter accepts a command batch but never completes it, so the title screen never
renders. Traditional launch (stock MiSTer, `main=` disabled) renders correctly.

### Root cause (isolated 2026-07-24 — see the progress ledger for the full A/B)

The wedge is **diagnosis #1**: a lost `p0_ok` SDRAM texel-fetch strobe. In
`blitter_top.sv` a texel fill latches `fill_busy` (`:1240` prefetch / `:1306` demand)
and is cleared *only* by the always-listening catcher when `p0_ok` returns (`:1111`).
If that 1-cycle strobe is lost, `fill_busy` stays high forever, the `pb` consume
sub-FSM parks in `B_WAIT`, and there is **no timeout** — a permanent hang. Control
block at the wedge: `CMDCOUNT=0xB`, `SUBMIT=0x14B`, `DONE=0`, `STATUS=0` (a real
11-command batch, blitter hung mid-batch).

Host-side isolation refuted **every** toggleable cause (boot reset-pulse, settle
timing, `user_io_init`, loop `fpga_wait_to_reset`, gmloader env, `status[19]`, loop
extras, OSD-visible, kbd-reset, dual-process contention). The lost strobe is
**reliably triggered** by the wrapper's FPGA/video/clock bring-up (a different
Main_MiSTer than device-stock) perturbing the placement-fragile emu-clock / SDRAM
timing — below the resolution of any host fix. Therefore the fix belongs in RTL: a
**trigger-independent liveness watchdog** that self-heals the lost-`p0_ok` hang
regardless of what perturbs the first fill.

## Goals / non-goals

- **Goal:** the blitter never hangs permanently on a lost `p0_ok`; it self-heals and
  the frame completes.
- **Goal:** zero behavior change on the healthy path — every existing sim golden stays
  bit-exact.
- **Goal:** device-observable so we can confirm it fired and distinguish a one-shot
  boot race from a broken timing regime.
- **Non-goal:** fixing the *trigger* (the wrapper's framework bring-up). The watchdog
  makes the manifestation harmless; pinning the exact framework difference is separate,
  lower-priority follow-up.
- **Non-goal:** any reference-model, host (gmloader), or protocol change. RTL-only.

## Design

### 1. Watchdog counter + synthetic completion

Add an **always-compiled** (NOT `ifdef`-gated — distinct from the existing debug-only
`fill_run` diag at `:567`) saturating counter in the main FSM `always @(posedge clk)`
block:

```
// increments while a fill is in flight and its strobe hasn't returned
if (fill_busy && !p0_ok)
    wd_stall <= (wd_stall == WD_TIMEOUT) ? wd_stall : wd_stall + 1'b1;
else
    wd_stall <= '0;                      // fill completed, or no fill outstanding
```

`wire wd_fire = (wd_stall == WD_TIMEOUT);` — a 1-cycle pulse the cycle the count
saturates (the next cycle `fill_busy` is cleared, so `wd_stall` resets).

Extend the always-listening catcher (`S_TRI_PIX`, currently `:1111`) with a second
branch that **mimics a real fill completion using the stale slot data**:

```
if (fill_busy && p0_ok) begin            // real completion (unchanged, keeps priority)
    tq_data[fill_slot]  <= p0_dout;
    tq_tag[fill_slot]   <= fill_tag;
    tq_valid[fill_slot] <= 1'b1;
    fill_busy           <= 1'b0;
end else if (fill_busy && wd_fire) begin // watchdog self-heal (synthetic hit, stale data)
    // tq_data[fill_slot] intentionally left as-is (stale/reset value)
    tq_tag[fill_slot]   <= fill_tag;
    tq_valid[fill_slot] <= 1'b1;
    fill_busy           <= 1'b0;
    wd_fire_count <= (wd_fire_count == 24'hFFFFFF) ? wd_fire_count : wd_fire_count + 1'b1;
end
```

After the synthetic completion, `pb` leaves `B_WAIT` → `B_LOOK` re-reads → `B_FILL`
sees `tq_valid && tag match` → **HIT** on the stale texel → the pixel blends and the
walk continues. Cost: a small number of wrong-colored texels for as long as the fault
persists; the FSM never hangs. Covers both fill sites (prefetch and demand); the
surface path (`tri_src_surface`, no `fill_busy`) is untouched.

`p0_ok` keeps priority in the `if/else`, so a real fill landing on the same cycle as
`wd_fire` completes normally and is never double-counted.

### 2. Threshold

`localparam WD_TIMEOUT = 13'd4096;` (~42 µs @ ~98 MHz emu clock). ~30× the sim stub's
worst fill latency (miss = 140 cyc) and far above any legitimate device fill, so it
never false-fires; small enough that recovery is imperceptible. Single-line tuning
knob. `wd_stall` is `[12:0]`.

### 3. Observability

`reg [23:0] wd_fire_count;` — saturating, reset **only** on `rst` (cumulative since
core load, so a single devmem read answers "did it ever fire, and how much").

Published in **`C_STATUS.low` bits `[31:8]`** at `S_WR_STATUS` (`:1476`), preserving
the existing `[1:0]` OSD-mirror bits (`osd_restart_pending`, `osd_fps_on`); bits
`[7:2]` stay 0. The `C_STATUS.hi` half (`perf_texwait_cyc`, host profiling) is
unchanged.

Device read: `wd_fires = (devmem 0x3B000030 >> 8) & 0xFFFFFF`.

Interpretation:
- `wd_fires == 0` steady-state (title renders) → the fault didn't recur; nominal.
- `wd_fires` climbs a little at boot then holds → **one-shot boot race; watchdog is the
  real fix.**
- `wd_fires` climbs every frame (+ low fps) → **broken timing regime; the watchdog is
  masking a deeper problem** (emu clock pushed into a bad regime) — needs a different
  fix, not this one.

Note: `C_STATUS` is written only at frame completion. That is fine — the watchdog's
purpose is to *enable* completion, so the count publishes exactly when it becomes
readable. If frames still never complete, `C_DONE` stays `0` and that itself signals
the watchdog didn't recover.

### 4. Reference model & bit-exactness

The C golden (`fpga/sim/blt_tri.c` / `blt_raster_tri`) models no SDRAM latency and no
`p0_ok` handshake — it is a functional rasterizer. A liveness watchdog that only ever
fires on a hardware strobe loss has **no reference-model counterpart** and changes no
rendering semantics. This does **not** violate the reference-model-first discipline
(which governs rendering semantics, not hardware liveness).

Bit-exactness is preserved by construction: with `WD_TIMEOUT = 4096 ≫ 140`, the
watchdog **never fires** in any existing bench (the P_SRC sim stub always returns
`p0_ok` within ~140 cyc), so `wd_fire` is never asserted, the catcher's new branch is
never taken, and every `tb_blitter_trilist_*` golden stays byte-identical. No
refmodel, host, or golden `.hex` change.

### 5. Testing (TDD)

**New targeted bench** proving the watchdog (sim cannot reproduce the real device race,
so we inject it):

- Add a **"withhold `p0_ok`" knob** to the P_SRC sim stub (`fpga/sim/`): for a
  designated fill, drop the `p0_ok` strobe (never return it), emulating the lost-strobe
  fault.
- **RED:** without the watchdog (or with it disabled), the FSM hangs on that fill →
  bench hits its cycle cap / never reaches `C_DONE`.
- **GREEN:** with the watchdog, `fill_busy` is force-cleared at `WD_TIMEOUT`, `pb`
  proceeds, the frame reaches `C_DONE`, and `wd_fire_count == 1`. Assert the recovered
  texel resolves as a HIT (forward progress), not a re-hang.

**Regression / bit-exact gate:** re-run the full suite (`./run_sims.sh`) — all
`tb_blitter_trilist_*` and `tb_blitter_system_pipe` stay bit-exact (watchdog never
fires; goldens unchanged). Pre-existing failures unchanged (`tb_scanout_fbram`,
`tb_audio_burst_wedge`; nightly `FABRIC-ASSERT`).

### 6. STA / footprint

Added logic: one ~13-bit counter, one equality compare, one 24-bit saturating counter,
and one extra branch in the `S_TRI_PIX` catcher. Tiny in area, but the emu clock is
placement-fragile (habitually closes slightly negative). Watch items for the RBF build:
- Keep `wd_fire` off the critical path — it is a compare of a **registered** counter
  against a **constant**, feeding the catcher's `tq_valid`/`tq_data` write; do not chain
  it through the wide tag mux.
- Confirm the `C_STATUS.low[31:8]` publish adds no new critical path at `S_WR_STATUS`.
- Accept the usual emu-clock STA reckoning at build time (runs-on-hardware band); it is
  not expected to worsen materially from a counter + compare.

## Definition of done

1. `blitter_top.sv` watchdog implemented as above; elaborates clean.
2. New withhold-`p0_ok` bench: RED without watchdog → GREEN with (frame completes,
   `wd_fire_count==1`).
3. Full `./run_sims.sh` bit-exact: all trilist/system goldens byte-identical; only the
   known pre-existing failures remain.
4. Windows RBF build fits + STA on the emu clock reported (runs-on-hw band acceptable).
5. Device: deploy RBF, launch via the **wrapper** (the wedging path), confirm the title
   screen renders and `C_DONE` tracks `C_SUBMIT`; read `wd_fire_count` and record
   one-shot vs constant.

## Out of scope

- The wrapper / framework trigger itself (separate, lower-priority follow-up).
- Any host (gmloader), reference-model, protocol, or golden change.
- Broader SDRAM-arbiter or emu-clock timing rework (only relevant if the device shows
  the "constant firing" regime, which would reopen the diagnosis).

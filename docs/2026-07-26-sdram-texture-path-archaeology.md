# Git archaeology: SDRAM texture path — TRILIST texels return garbage

**Date:** 2026-07-26
**Branch:** `fix/launch-via-master-daemon-handler`
**Scope:** read-only history investigation. No code changes were made.

## Symptom under investigation (device-measured)

A 128×128 texture filled entirely with `0xFFFF` is staged via `BLT_OP_STAGE`
(same-offset: `SDRAM[off] = DDR3[off]`) and then sampled by a `TRILIST`.
**Not one texel comes back correct.** Rendered values are garbage (`0x59FF`,
`0x591F`, `0x5900`, `0x00FF`, `0x001F`, `0x009F`, … 24 distinct values) and are
**constant across each texture row** — the `u`/column index does not change the
fetched data at all, only `v`/row does.

> An earlier framing of this bug as "high byte zeroed / `& 0x00FF`" was an
> artifact of a tiny 8×8 texture and is **withdrawn**.

### Already proven and excluded (do not re-investigate)

- Host/DDR3 side is perfect — DDR3 at the texture address (`0x3B0A0000`) reads
  `0xFFFFFFFF` across the full 32 KiB.
- Geometry/rasterisation is perfect (clean triangle edges).
- Clear / composite / `comp_fb_dma` / DDR framebuffer / `openbor_video_reader` /
  scanout are perfect (clear colour arrives bit-exact, including full red `0xF800`).
- STAGE addressing contract agrees host↔RTL: host `blt_stage()` sets `flags=0`,
  so `blitter_top.sv:966` uses `stage_sdram_off = c_src_off` (same-offset).
- `stage_barrier` / `stage_barrier_busy` are correctly wired in `fpga/Maldita.sv`.
- `SRC_QW` (`0x07610000` = `0x3B080000`) matches the host's `MF_SRC_OFF`.
- `SDRAM_AW=25` (128 MB) is correct — both devices physically have 128 MB SDRAM.

---

## Q1 — Any commit that plausibly breaks the STAGE write or P_SRC read path?

**No. Explicitly: none found.**

- `fpga/rtl/sdram_fb_cache.sv` has **3 commits in its entire history**:
  - `f566755` (fork)
  - `8bb4883` (widen ch5 P_SRC cache 2→8 lines, `SRC_BLOCKS`)
  - `dddbbad` (revert of the above)

  I diffed `8bb4883` ↔ `dddbbad` line by line — it is an **exact, clean revert**,
  zero residue.

- `git log -S` on `dqm`, `wdsn`, `stage_wdsn`, `src_sdram_din64`, `stage_addr`,
  `XL_MODE` → **only the fork commit** `f566755`.
- `fpga/rtl/ddr_blitter_arb.sv` and `fpga/rtl/ddram.sv`: **untouched since the fork**.
- `fpga/rtl/jtframe/*`: **untouched since the fork**.
- Scanned every RTL diff since 2026-07-16 for byte/word-slicing changes
  (`[15:8]`, `[7:0]`, `{8'd0,…}`) on the texel path — nothing.
- Read the texel address generator (`blitter_top.sv:1248-1271`). It is correct:
  - `texbyte = c_src_off + tex_row + (itu_q<<<1)`
  - `tex_row = itv_q[15:0] * c_src_stride` (32-bit; no overflow at stride 256 × v 127)
  - the surface / SDRAM `tex_lane_q` assignments live in **separate `if`/`else`
    branches** — not a last-write-wins hazard.

---

## Q2 — Last known-good textured rendering ON HARDWARE

Two baselines, both from `.superpowers/sdd/progress.md`:

### Weak baseline (128-byte texture) — ledger line 112

`MalditaCastilla_20260717` = commit **`7a61ec2`**

> *"fabric_probe = GO (magenta triangle, MD5 ba4a6f0d identical to investigation)."*

Only an 8×8 = 128-byte texture. Proves very little.

### Strong baseline (real game atlases) — ledger line 179 — **use this one**

RBF **`830e83a2`**, CI build **29648446975**, ≈ commit **`6f06a9c`**, **2026-07-18**

> *"READER-TASK 3 DEVICE: SUCCESS — CURSED CASTILLA TITLE SCREEN RENDERS ON
> HARDWARE. … shot2 = TITLE SCREEN ("CASTILLA" gold logo + sword + flanking
> dragons, "PRESS START"). GEOMETRY CORRECT."*
> STA: **emu general[0] = +0.266 CLOSED — "healthiest of the whole effort"**;
> FIT M10K 423/553.

Ledger line 134 confirms normal SDRAM heap samples were rendering at that point:
*"BORDER (normal heap sample, tex6) RENDERS = orange edges."*

**Consequence:** large-texture staging through ch1 → SDRAM → ch5 demonstrably
worked on hardware on 2026-07-18, with 2048² atlases — far beyond ch1's 512-byte
capacity.

> ### Retracted hypothesis
> An interim hypothesis that **"ch1 eviction/writeback never worked"** is
> **refuted** by the above and should be discarded. The underlying verification
> gaps are real (see Appendix) but they are *not* this regression.

**Fault window: `6f06a9c` (2026-07-18) → HEAD.** Roughly 17 RTL commits.

---

## Q3 — Sanity-check: "nothing on the SDRAM texture path changed since the fork"

**Agreed on the direct SDRAM path.** Independently confirmed: `MISTER=0`,
`SDRAM_AW=25`, `sdram_fb_cache.sv` last touched at `dddbbad`, `fpga/rtl/jtframe/*`
untouched, `ddr_blitter_arb.sv` / `ddram.sv` untouched, PLL / `pll.qip` /
`fpga/sys` untouched.

**However, three things touch SDRAM behaviour indirectly, and one is on the
texel path.**

### (a) `.qsf` *did* change after the fork

- `cdd8e29` **defined `MISTER_FB=1` in `Maldita.qsf`** — ledger line 161 flags this
  explicitly: *"was deliberately UNSET — reverses prior config"*.
- `6f06a9c` removed `VGA_SCALER=0`.
- `7cb722f` / `d8e95fe` / `698dc8a` / `d019207` flip `SOLARUS_DBG_PROBES`.

These change what gets compiled → different fit/placement. On a
**placement-fragile emu clock** that directly moves SDRAM capture timing.
Compare current STA against `830e83a2`'s **+0.266**; CLAUDE.md notes recent
builds close **−0.02 to −0.7 ns**.

### (b) The DDR-scanout pivot — biggest indirect risk

"The SDRAM path is unchanged" hides this: **`BLT_OP_STAGE` reads its source from
DDR3**, through `ddr_blitter_arb`.

```
blitter_top.sv  S_STAGE_RD:
    bm_addr <= `SRC_QW + ((stage_off + stage_byte) >> 3);
```

`cdd8e29` / `6f06a9c` added `comp_fb_dma` as a **new DDR3 arbiter client** and
converted `openbor_video_reader` to **80-beat DDR bursts per scanline**. If
STAGE's DDR3 *read* is starved or mis-served under that new load, garbage is
written into SDRAM — and downstream that is indistinguishable from "SDRAM was
never written".

> The DDR3 dump at `0x3B0A0000` proves the **host** wrote `0xFFFF`. It does
> **not** prove the fabric's STAGE read returned it.

### (c) `efdf5e0` — the fill_busy watchdog is on the texel path and post-baseline

Landed 2026-07-24. On timeout it deliberately marks the texel-cache slot **VALID
with the correct tag but STALE `tq_data`** (`blitter_top.sv:1156-1161`, comment:
*"tq_data intentionally left unwritten"*). Under the heavier DDR/arbiter load
from (b), a late `p0_ok` would poison the texel cache with plausible-looking
garbage. This fits "garbage values, but structured" better than unwritten DRAM
does.

**Free decisive measurement — `b80d380` already publishes the counter:**

```sh
busybox devmem 0x3B000030      # wd_fires = (value >> 8) & 0xFFFFFF
```

Per the design note (ledger line 325):

| Reading | Meaning |
|---|---|
| `0` or boot-only | watchdog is innocent — look elsewhere |
| climbing every frame | texel fetch is timing out; the watchdog is manufacturing the garbage texels |

One command splits (c) from everything else.

---

## Suggested next steps, ranked

1. **Read `wd_fire_count` on the failing device** — one command, splits the
   hypothesis space immediately.
2. **Build an RBF at `6f06a9c`** (known-good, STA +0.266) and run the 128×128
   repro.
   - If it renders → bisect `6f06a9c`→HEAD (only ~17 commits).
   - If it *also* fails → the bug is in the **host/engine or the probe**, not the
     RTL. Note the DDR3 dump only clears the host's *write*, not `blt_stage()`'s
     size/offset arguments.
3. **Compare current STA vs `830e83a2`'s +0.266** on the emu clock.
4. Independently, close the coverage gaps below. They will not find *this* bug,
   but as it stands no test would ever catch a real one.

---

## Appendix — verification gaps found (real, but not this regression)

### ch1 (STAGE write channel) is a 2-line, 256-byte-per-line write-back cache

- `fpga/rtl/sdram_fb_cache.sv:56-57` — `RO_BLOCKS = 2`, `RO_BLKSIZE = 256`
- `:416` — `.BLOCKS1 ( RO_BLOCKS ), .BLKSIZE1 ( RO_BLKSIZE ), .DW1 ( 64 )`
- `jtframe_cache.sv:59-61` — `WAYS = BLOCKS<4 ? BLOCKS : 4` ⇒ WAYS=2, SETS=1

⇒ **ch1 total capacity = 512 bytes**, fully associative. Note the geometry is
named for *read-only* channels (`:55` — *"P_SCAN/P_SRC are small read-only
caches"*); ch1 — a **write-back** channel — reuses it. P_DST by contrast gets
`DST_BLOCKS=8 × DST_BLKSIZE=1024`.

### Nothing has ever exercised an eviction on it

| Test | Staged payload | Evictions |
|---|---|---|
| `tb_stage_psrc.sv:33` | `NQW = 16; // 128 bytes` | **0** |
| `tb_stage_psrc_sameframe.sv:43` | `NQW = 16; // 128 bytes` | **0** |
| `tb_sdram_fb_cache_xl.sv:107` | `.stage_wr(1'b0)` — **ch1 tied off** | n/a |
| HW probe `fabric_probe.c:152` | 8×8 RGB565 = **128 bytes** | **0** |
| Failing case | 128×128 = **32 KiB = 128 lines** | **~126** |

Those two `tb_stage_psrc*` benches are the *only* ones that drive a real
`BLT_OP_STAGE` through `blitter_top` into a real `sdram_fb_cache`.

### No testbench co-simulates TRILIST with a real SDRAM

`grep -c sdram_fb_cache fpga/sim/tb_blitter_trilist_*.sv` → **0 for all five**.
`tb_blitter_system_pipe` mentions `sdram_fb_cache` in a **comment only**; its
P_SRC is a behavioural latency model over `schip.store`, and it states
*"BLT_OP_STAGE is inert in this regression"*.

### `FULL1=1` (XL) on the write channel is never simulated

`tb_sdram_fb_cache_xl` is the only bench running `SDRAM_AW=25` — i.e. the only
config that is actually synthesised (`Maldita.sv:448`) — and it ties ch1 off
entirely.

### Suggested test work

- `tb_stage_psrc.sv:33` — raise `NQW` from `16` to `4096` (32 KiB) to force
  ~126 ch1 evictions.
- `tb_sdram_fb_cache_xl.sv:107` — drive ch1 instead of tying it off, to cover
  `FULL1` in the shipped config.
- Add a TRILIST bench built on the real `sdram_fb_cache`.

---

## Also noted (not the cause of this bug)

`MISTER` is `0` and has been since the fork. Downgraded as a suspect here — it
would corrupt *bytes*, not produce row-constant data. Recording it anyway
because it is a latent inconsistency:

- `Maldita.sv:443` declares *"Requires the 128MB SDRAM module."*
- `tb_sdram_fb_cache_xl.sv:26` — *"Two 64MB mt48 models split by the controller's
  `sel_chip` (MiSTer 128MB …)"*.
- `jtframe_sdram64_bank.v:70-73` — `SDRAM_A[12:11]` and `SDRAM_DQML/H` *"can be
  joined together thru an OR operation at a higher level. This makes it possible
  to short the pins of the SDRAM, **as done in the MiSTer 128MB module**"*.
- `jtframe_burst_io.v:81` — `assign {sdram_dqmh, sdram_dqml} = MISTER ? sdram_a[12:11] : dqm;`
- `Maldita.sv:445-447` records a prior HW A/B where `MISTER=1` was **NULL**
  (*"Reverted to MISTER=0 (validated for 64MB)"*) — but that A/B was chasing
  "overworld 2nd-die garbage", not this symptom.

Worth a one-line A/B at some point; it does not explain the current bug.

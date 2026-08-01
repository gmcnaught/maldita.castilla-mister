# Present latency and CPU offload — where the time actually is, and what DMA buys

**Date:** 2026-08-01
**Status:** research only. No code changed, no device run, no sim run.
**Method:** static reading of `fpga/rtl/`, `external/gmloader-next` (pin
`d6d97eb`) and `mister-fpga-blitter` (`c4407e4`), plus arithmetic over
measurements already recorded in `findings/2026-07-31-phase4-w3.md` and
`bench-results/`.
**Convention:** every claim is tagged **[OBS]** (read from source or a logged
measurement), **[DER]** (arithmetic over those), or **[UNK]**.

---

## 0. Headline

**The single biggest lever is a DMA lever, and it is in our own RTL.**
`comp_fb_dma` — the WORK→DDR framebuffer copy the blitter blocks on every frame
— moves **one qword every two clocks** because its WORK read is
single-outstanding with a 2-cycle valid pipe. That is not a bandwidth limit, an
arbitration limit or a DDR3 limit; it is a four-line handshake in
`comp_fb_dma.sv:164-167`.

| quantity | value | provenance |
|---|---:|---|
| copy size | 15552 qwords (124 KiB) | `comp_fb_dma.sv:13` **[OBS]** |
| issue cadence | 1 qword / **2** clk | `comp_fb_dma.sv:164-167` **[OBS]**, traced in §2.1 |
| ⇒ predicted copy time @ 98.4375 MHz | **0.3160 ms** | **[DER]** |
| measured `snap` (median, 8 windows) | **0.327 ms**, IQR 0.322–0.330 | W3 §10.3, §18.2 **[OBS]** |
| model accounts for | **96.6 %** of the measured window | **[DER]** |
| cadence at 1 qword / clk | **0.1580 ms** | **[DER]** |

W3 recorded that the measured doorbell dead window "is ~2.1× the **0.158 ms**
`S_SNAP` design figure … so `S_SNAP` runs materially longer than designed"
(W3 §0) and left the cause unattributed. **The cause is the 2-cycle issue
cadence, and 0.158 ms is exactly the 1-qword-per-clock figure the design note
assumed.** The factor of 2 is not mysterious; it is in the RTL.

Against a **0.320 ms** gate miss (W3 §13), halving this copy is worth **~0.158 ms
— half the gap — with no host change, no Qsys regeneration and no new f2h port.**

Everything else in this document is smaller, further away, or already ruled out.

---

## 1. "Present latency" is two different numbers, and only one is instrumented

### 1.1 Period (throughput) — measured, and the phase-4 subject **[OBS]**

Heavy-B, W3 bitstream `2509573`: `period` **17.008 ms** (58.80 fps) against the
16.6882 ms scanout period — missed by 0.320 ms (W3 §13.2). Decomposition:

```
period 17.008 = fabric frame 16.410 + notice 0.529
notice 0.529 = snap 0.327 + detect 0.146 + (unattributed floor) − pub 0.000
```

`notice` **is** the entire remaining gap (W3 §15.3).

### 1.2 End-to-end input→photon — **never measured** **[UNK]**

No instrument in either repo reports it. The chain, from the code:

| stage | cost | source |
|---|---|---|
| joy mask staleness — reader writes JOY once per display vblank, host reads at loop top | 0–16.69 ms | `openbor_video_reader.sv:600-608`, `input.cpp:306-339` **[OBS]** |
| `Process()` + draw emit + doorbell | inside the frame | `main.cpp:1086-1092` **[OBS]** |
| fabric rasterize | 16.410 ms | W3 §18.1 **[OBS]** |
| `S_SNAP_*` copy to DDR | 0.327 ms | §0 **[OBS]** |
| **reader adoption** — `ST_CHECK_CTRL` latches `buf_base_addr` **once per frame** and holds it | **0–16.69 ms** | `openbor_video_reader.sv:786-793` **[OBS]** |
| scanout of the row in question | 0–16.69 ms | **[OBS]** |

**[DER]** Mean ≈ **42 ms**, worst case ≈ **67 ms** — about 2.5 to 4 display
frames. Roughly **16.6 ms of that mean is pure phase**: two independent
free-running boundaries (joy write, buffer adoption) that the render loop is not
aligned to.

**This is the number a player feels, and no phase so far has targeted it.**
Phase 4 optimised §1.1. The two are not the same problem and the levers differ
(§4).

---

## 2. The DMA finding, in full

### 2.1 Why it is 2 cycles per qword **[OBS] → [DER]**

`comp_fb_dma.sv:164-167`:

```systemverilog
wire wr_accept = hold_valid & ~mem_busy;
wire hold_free = ~hold_valid | wr_accept;
wire cap_fire  = rd_v2 & hold_free;
wire can_issue = (rptr < NQW) & (~rd_busy | cap_fire);
```

Steady-state trace, starting with `rd_busy=0`, `hold_valid=0`:

| clk | `rd_busy` | `rd_v1` | `rd_v2` | `cap_fire` | `can_issue` | action |
|---:|:--:|:--:|:--:|:--:|:--:|---|
| 0 | 0 | 0 | 0 | 0 | **1** | issue read; `rd_busy←1`, `rd_v1←1` |
| 1 | 1 | 1 | 0 | 0 | **0** | `rd_v2←1` (`:228`); **bubble** |
| 2 | 1 | 0 | 1 | 1 | **1** | capture into hold; issue next read |

So a read is issued on even clocks only — **1 qword per 2 clocks**, sustained.
`comp_fbram`'s `rd_qword` is a *registered* 1-cycle read
(`comp_fbram.sv:29-33`), so the second cycle is the single-outstanding
`rd_busy` interlock, not memory latency.

**[DER]** 15552 × 2 = 31104 clk ÷ 98.4375 MHz = **0.31598 ms**.
Measured `snap` median **0.327 ms**. Residual **0.011 ms** (≈1080 clk) covers
`S_WR_WAIT` bus accept, `S_SNAP_WAIT`, `S_SNAP_BUSY` and bus stalls — and `snap`
is documented as arming at `S_WR_DONE` *entry*, so it is an upper bound by
construction (W3 §10.2).

### 2.2 It is not a bandwidth or contention problem **[DER]**

124,416 B/frame × 59.92 Hz = **7.45 MB/s**. On a 64-bit f2h port at 98.4375 MHz
(787 MB/s theoretical) that is under 1 %. And the 0.011 ms residual bounds *all*
bus stalling for the whole copy — so `f2h_slot_mux`'s escape logic is already
doing its job. **The bottleneck is entirely internal to `comp_fb_dma`.**

### 2.3 The blitter blocks on all of it **[OBS]**

`blitter_top.sv:2641`:

```systemverilog
S_SNAP_DRAIN: if (!fb_dma_busy) state<=S_POLL_SUBMIT;
```

The FSM does nothing else — in particular it does **not** poll `C_SUBMIT`. Since
`C_DONE` is written at `S_WR_DONE`, *before* the snapshot, the host's await has
already returned and the host has already rung the next doorbell while the fabric
sits here. That is precisely the dead window Stage A measured behaviourally as
`K = 0.335 ms` (W3 §0) — two instruments, one mechanism, now with a root cause.

### 2.4 Three fixes, in increasing order of cost

**(a) Pipeline the WORK read — `comp_fb_dma` only. [DER] ~−0.158 ms.**
Issue every clock behind a 2-deep skid, keeping `mem_burstcnt = 8'd1`. Whether
the f2h write path accepts a beat per clock at burstcnt=1 is the one thing this
needs a bench to answer (`tb_comp_fb_dma`); if it does not, the win is partial
and (b) becomes required rather than optional. Note this change makes `mem_wr`
high *more* of the time, which **tightens** `f2h_slot_mux`'s worst-case bound
(`f2h_slot_mux.sv:86-93`) rather than loosening it.

**(b) Burst the writes — `mem_burstcnt` > 1.** The arbiter already supports it
(`ddr_blitter_arb.sv:257-260`; the reader bursts 72 qwords per scanline,
`openbor_video_reader.sv:201`). **Blocked by a stated safety argument:**
`f2h_slot_mux.sv:76-80` derives its combinational-owner safety from
comp_fb_dma being a single-beat writer that re-presents the same beat when the
slot is revoked, and `:86-93` explicitly says *"if comp_fb_dma ever gains … a
burst mode, this bound grows with it and must be re-derived."* Do (a) first.

**(c) Poll `C_SUBMIT` during the drain. [DER] up to ~−0.146 ms, small diff.**
The control-block prologue (`S_GOT_CMDCNT` … `S_GOT_CLEAR`), the command fetch,
the decode and `blt_tri_setup` all read DDR/SDRAM and **never touch the WORK
buffer**; only the first pixel write does. So the drain could overlap the entire
front of the next frame. The minimal version is a `submit_pending` latch set in
`S_SNAP_DRAIN`, which recovers `detect` (0.146 ms measured, W3 §18) for a few
lines of RTL. (a) and (c) attack the same 0.47 ms from opposite ends and should
be sized together, not summed naively.

**[UNK]** Whether `S_SNAP` can be removed entirely by double-buffering WORK.
`comp_fbram.sv:9-17` states WORK **persists across frames** for the incremental
draw model, and the second on-chip buffer is already spent on the app-surface
render target. A third full-size buffer is 125 KiB of M10K. Not costed here.

---

## 3. Taking work off the CPU — what is real

### 3.1 The uncomfortable framing first **[OBS]**

On the binding scene `blocked = 100 %` (W3 §18.2; `MFSEAM … blocked=100%` in
`bench-results/20260730-175503---preset_fabric.log`). **The host is entirely
hidden behind the fabric there.** Removing host work buys *zero* frame rate on
the scene that misses the gate.

Where the host does bind, the dominant term is the GameMaker VM, not our code:
the same log shows `DRAWTRACE … logic=15.6ms` against `BLITPROF … raster=1.1`.
`logic` is `Process()` minus blitter time — the interpreter. Not ours to offload.

So CPU offload is a **latency and headroom** argument here, not a frame-rate
argument. Ranked accordingly.

### 3.2 §3.1 of the port review, reframed — RGBA→565 inside `BLT_OP_STAGE`

`findings/2026-07-30-port-review-native-simd-offload.md` §3.1 already identifies
this as the strongest offload. **The reframing this research adds:** as written
it does not pay for itself, because the RGBA8888 master lives in *host* RAM
(`blitter.cpp:239-240`), so a format-converting STAGE still needs someone to put
RGBA into DDR3 — 2× the bytes we copy today.

It pays only in the form: **upload the RGBA8888 master into the DDR3 heap once at
`glTexImage2D`, then every per-region stage becomes a pure fabric DMA with zero
A9 texel work.** That converts per-frame CPU into a one-time cost and deletes
both `mf_stage_texels` and `upload16`'s per-row memcpy from the steady state.

**[OBS] It collides head-on with heap capacity.** RGBA masters are 2× the RGB565
pages, and the SRC heap is ~14.75 MiB (`MF_DEV_SRC_CAP`,
`raster_backend_mfgpu.cpp:902-903`) — already overflowing, which is why
per-sprite-quad sub-region staging exists (CLAUDE.md, current feature). Verdict:
**architecturally right, currently blocked by the heap.** Revisit after
sub-region residency lands, not before.

### 3.3 The uncached-store cost — unmeasured, and PL330 will not rescue it

**[OBS]** The emitter binds directly to the `/dev/mem` mapping
(`raster_backend_mfgpu.cpp:1428-1430`), so `blt_push_tris` (`blt_emitter.c:561`)
and `upload16` (`:58-60`) memcpy straight into it.

**[DER]** Heavy-B per frame: 228 tris × 3 × 16 B (`blitter_ref.h:285-290`) =
10,944 B of vertices, plus 46.8 commands × 32 B ≈ 1,498 B of ring ≈ **12.4 KiB
of uncached stores per frame**.

**[OBS/DER]** `mmap("/dev/mem", O_SYNC)` over the FPGA-reserved window maps as
**strongly-ordered memory, not write-combining**: ARM's `phys_mem_access_prot`
only upgrades `O_SYNC` to `pgprot_writecombine` when `pfn_valid(pfn)` holds, and
takes the `pgprot_noncached` branch otherwise. Consequence: **no store merging,
no burst formation — every store is its own AXI beat.** There is no flag to
flip; write-combining is not reachable through `/dev/mem` for this region.

**[OBS] The `pfn_valid()` premise now has a device-side witness.** Main_MiSTer
bounds-checks every core-visible address against `[0x20000000, 0x40000000)`
(`vendor/Main_MiSTer/user_io.cpp:717`, `:921`, `:2794`) — the 512 MiB carved out
of the DE10-Nano's 1 GiB for the fabric. Both `0x3A000000` and `0x3B000000` sit
inside it, outside the kernel's memblock. **[DER]** So an `O_SYNC`
vs. no-`O_SYNC` A/B over either region compares two *identical* mappings: the
first branch is taken both times and the `O_SYNC` test is never reached. Any
bandwidth figure produced by such an A/B measures nothing about `O_SYNC`.

**[UNK]** `pgprot_noncached` on ARM is `L_PTE_MT_UNCACHED` (strongly-ordered),
not merely unbuffered, so a hypothetical WC mapping could plausibly be several
times faster. Not verified against the MiSTer kernel tree, which is not checked
out here. *Decisive and cheap:* on device, `cat /proc/iomem` (is `0x3A000000`
inside a "System RAM" range?) and `cat /proc/cmdline` (`mem=`).

That makes it the one place a real DMA controller (the HPS PL330) would
genuinely help — and it is **blocked by the same wall the f2h-IRQ review already
priced**: `CONFIG_UIO is not set`
(`findings/2026-07-31-f2h-irq-vsync-review.md` §1), and dmaengine has no
userspace API. A kernel module + DTS + kernel rebuild, off the stock MiSTer
update path, for both test units.

**Do the cheap thing first: measure it.** There is no host timer on the DDR
store today — BLITPROF's `raster` covers transform and cull, not the copy. One
`clock_gettime` pair around `blt_push_tris`/`blt_trilist` costs nothing and
settles whether 12.4 KiB of Device-memory stores is 30 µs or 300 µs. **If it is
under ~100 µs, close this line permanently.**

### 3.3a Scoping trap — the big noncached blit is on the path that does not ship

**[OBS]** The largest single write into a noncached mapping in either repo is
`NativeVideoWriter_WriteFrame`'s one-shot `memcpy` of `NV_FRAME_BYTES` =
**124,416 B** (`native_video_writer.c:43`, `:108`), with a capture-and-convert
variant moving RGBA 248,832 + RGB565 124,416 ≈ 373 KiB.

**[OBS]** It does not run on the shipping path. `main.cpp:1094-1101` skips it
explicitly: *"the 0x3A DDR writer is the software producer, unused on the fabric
path."* Any per-frame cost derived from those byte counts belongs to
`preset_sw` / the GL fallback, **not** to `backend_mfgpu`.

**[DER] Where the fabric path *is* exposed** is `upload16`'s per-row memcpy on a
texture-cache **miss**: a 512×512 RGB565 page is 512 KiB of strongly-ordered
stores in a single frame. `texup = 0.0` in steady state
(`bench-results/20260730-175503---preset_fabric.log`), so this is a **spike on
room transitions, not a rate** — the shape of a hitch, not of a frame-rate loss.
That is the one host-mapping cost on the shipping path worth a timer, and it is
the same loop §3.2 would delete outright.

**[OBS] Side catch.** `native_video_writer.c:123` credits its
write-before-doorbell ordering to *"strongly-ordered device memory (O_SYNC +
MAP_SHARED)"*. Per the analysis above the strong ordering comes from
`pfn_valid()` being false, **not** from `O_SYNC` — the comment is correct by
accident, and would silently stop being correct if that region ever entered the
kernel's map. `raster_backend_mfgpu.cpp` (`mf_ctrl_barrier`) and
`native_audio_writer.c:135-150` do not rely on this; they issue an explicit
`__sync_synchronize()`. Only this one site does.

### 3.4 Already settled — do not re-open

- **`C_DONE` poll pressure.** A/B'd at 0/50/250/1000 µs; coarsening never lowered
  `notice` and the pure spin is at the host-side floor (W3 §0, §4). ~25 000
  uncached reads/frame is ~0.4 % of DDR transaction capacity **[DER]** — the
  measurement and the arithmetic agree.
- **f2h IRQ for vsync.** Rejected with reasons
  (`findings/2026-07-31-f2h-irq-vsync-review.md` §7).
- **h2f_lw bridge.** No bridge is instantiated; enabling one means regenerating
  Qsys (same doc §8).
- **NEON texel staging** — done 2026-07-30; the rest of §2 in the port review is
  SW/GL-path only.

---

## 4. Latency levers that are not DMA and are not measured

**(L1) Snapshot-to-adoption phase. [UNK], and it is worth a probe.**
The reader adopts a new buffer once per frame (`openbor_video_reader.sv:786-793`).
A snapshot completing just *after* that point waits a full 16.69 ms to be seen.
The render loop free-runs against it, so **[DER]** the phase is uniform and the
mean cost is ~8.3 ms — half a display frame of pure latency, invisible to
`period` and therefore invisible to every phase-4 instrument.

*Cost to find out:* one device run. Stamp `SCANFRM` (already mapped and read,
`raster_backend_mfgpu.cpp:3194-3202`) at the moment `C_DONE` lands and histogram
the phase. If it clusters badly, the fix is a host-side nudge to the `fcap`
release point — no RTL.

**(L2) Joy-mask staleness.** Same shape at the input end: the reader writes JOY
once per display vblank, the host reads at loop top. 0–16.69 ms **[DER]**.
Cheaper to fix in the reader (write JOY more than once per frame) than in the
host.

**(L3) The 7.7 % residual frame-1 wedge** (W3 §16 item 11) is not a latency
lever, but it is what makes every device bench session expensive. Flagged
because it taxes all of the above.

---

## 5. Recommended order

| # | Item | Where | Expected | Confidence |
|---|---|---|---|---|
| 1 | Pipeline `comp_fb_dma`'s WORK read (§2.4a) | RTL, 1 file | **−0.158 ms** | high — arithmetic matches measurement to 3.4 % |
| 2 | Poll `C_SUBMIT` during `S_SNAP_DRAIN` (§2.4c) | RTL, small | up to −0.146 ms | medium — overlaps #1, size together |
| 3 | Snapshot-to-adoption phase probe (§4 L1) | host, probe only | up to −8 ms *latency* | unknown, cheap to learn |
| 4 | Time the uncached DDR stores (§3.3) | host, 2 timestamps | closes or opens a line | free |
| 5 | Burst `comp_fb_dma` writes (§2.4b) | RTL + re-derive `f2h_slot_mux` | second-order after #1 | blocked on #1's bench |
| 6 | RGBA-master-in-DDR3 + converting STAGE (§3.2) | RTL + host | deletes host texel work | blocked on heap capacity |

Items 1 and 2 are the only two sized against the 0.320 ms gate miss. Item 3 is
the only one that addresses what §1.2 calls the number a player feels.

---

## 6. Unknown

1. Whether the f2h write path accepts a beat per clock at `burstcnt = 1`
   (gates the size of §2.4a). *Answered by:* `tb_comp_fb_dma` with a realistic
   `mem_busy` model.
2. The true snapshot-to-adoption phase distribution (§4 L1).
3. The real cost of 12.4 KiB/frame of Device-memory stores (§3.3).
4. Whether WORK can be double-buffered within the remaining M10K budget, which
   would remove `S_SNAP` from the critical path entirely rather than shortening
   it (§2.4).
5. End-to-end input→photon, measured rather than derived (§1.2). No instrument
   exists; the derivation here is arithmetic over component measurements and has
   never been checked against a camera or a logic capture.

## Sources

- `fpga/rtl/comp_fb_dma.sv` — copy size `:13`, `mem_burstcnt = 8'd1` `:161`,
  the issue handshake `:164-167`, the `rd_v1→rd_v2` shift `:228`.
- `fpga/rtl/comp_fbram.sv` — WORK persistence and the registered 1-cycle read
  `:9-17`, `:29-33`.
- `fpga/rtl/blitter_top.sv` — `S_SNAP_*` `:2631-2641`, the blocking drain
  `:2641`.
- `fpga/rtl/f2h_slot_mux.sv` — single-beat dependency `:76-80`, the bound that
  must be re-derived for bursts `:86-93`.
- `fpga/rtl/ddr_blitter_arb.sv:257-260`, `fpga/rtl/openbor_video_reader.sv:201`
  — burst support already present.
- `fpga/rtl/openbor_video_reader.sv:786-793` — once-per-frame buffer adoption.
- `findings/2026-07-31-phase4-w3.md` — `period`/`frame`/`notice` §13, §18;
  `snap` median and IQR §10.3, §18.2; the 0.158 ms design figure and the
  unattributed 2.1× §0.
- `findings/2026-07-31-f2h-irq-vsync-review.md` — `CONFIG_UIO`, bridge absence.
- `findings/2026-07-30-port-review-native-simd-offload.md` §3.1 — the STAGE
  offload this document reframes.
- `external/gmloader-next` @ `d6d97eb`: `raster_backend_mfgpu.cpp:902-903`,
  `:1428-1430`, `:3194-3202`; `main.cpp:1086-1092`, `:1094-1101`;
  `native_video_writer.c:43`, `:108`, `:123`; `native_audio_writer.c:135-150`.
- `vendor/Main_MiSTer/user_io.cpp:717`, `:921`, `:2794` — the
  `[0x20000000, 0x40000000)` fabric window, the `pfn_valid()` witness in §3.3.
- `mister-fpga-blitter` @ `c4407e4`: `host/blt_emitter.c:58-60`, `:561`;
  `refmodel/blitter_ref.h:285-290`.

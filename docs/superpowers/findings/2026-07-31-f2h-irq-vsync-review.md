# Review — would an FPGA→HPS IRQ beat DDR signalling for vsync?

Date: 2026-07-31. Scope: evaluation only, no code changed.

**Verdict: no, not for vsync, and not on the current bottleneck.** The mechanism
exists and is already plumbed on MiSTer, but what it would replace costs ~1.2 µs
and does not block, while the term that actually binds the frame budget
(`notice`, 0.56 ms) is a *completion* signal whose dominant half runs in the
opposite direction to an f2h IRQ.

---

## 1. Observed — the IRQ path exists and reaches userspace today

| layer | evidence |
|---|---|
| fabric | `maldita.castilla-mister/fpga/sys/sys_top.v:574` — `wire [63:0] f2h_irq = {video_sync, HDMI_TX_VS};` into `cyclonev_hps_interface_interrupts` |
| device tree | `Linux-Kernel_MiSTer/arch/arm/boot/dts/socfpga_cyclone5_de10_nano.dts:86-92` — `MiSTer_fb` node, `interrupts = <0 40 1>` (GIC SPI 40 = f2h IRQ **0**) |
| driver | `drivers/video/fbdev/MiSTer_fb.c:48-52,96-125` — `wait_queue_head_t vs_wait`, `irq_handler` → `wake_up_interruptible`, exposed as `FBIO_WAITFORVSYNC` |

So a blocking userspace vsync wait is available now, with no RTL and no kernel
work: `ioctl(fd_fb0, FBIO_WAITFORVSYNC, &n)`.

Two limits on that:

- **Only IRQ 0 is claimed.** `f2h_irq[1] = video_sync` (the programmable
  scanline trigger, `sys_top.v:1628-1638`) has no DT node and no consumer.
- **`CONFIG_UIO is not set`** (`arch/arm/configs/MiSTer_defconfig:3197`). A
  second consumer therefore needs a custom kernel module *plus* a DTS change
  *plus* a kernel rebuild — off the stock MiSTer update path, for both test
  units.

## 2. Observed — IRQ 0 is the wrong timebase for this core

`HDMI_TX_VS` is driven from the ascal/OSD chain in the `clk_hdmi` domain
(`sys_top.v:1377,1394`). It is the **HDMI output** frame boundary, not the
core's video timing. `.62` runs analog RGB with `vga_scaler=0`, so pacing the
game loop off IRQ 0 would pace it against a different clock from the one the
game is actually displayed on. The correct boundary is `video_sync`
(`f2h_irq[1]`) — the unclaimed one.

## 3. Observed — what DDR signalling for vsync actually costs

The frame cap reads the scanout instrument at `SCANFRM_ADDR = 0x3BFB0018`
(`raster_backend_mfgpu.cpp:2578-2606`): two uncached 32-bit loads inside a
region already mmapped. Measured cost of one such load, recorded in
`main.cpp:133-141`: **~1.2 µs**.

An `FBIO_WAITFORVSYNC` round trip is an ioctl + `wait_event_interruptible_timeout`
+ IRQ + wakeup + reschedule on an 800 MHz Cortex-A9 — tens of µs before
userspace runs again. Replacing the poll makes *notice latency worse*, and its
only real benefit (yielding the core) is priced below.

## 4. Observed — there is no spin to reclaim on the scenes that bind

1. **The cap is a leaky bucket, not a per-frame wait** (`main.cpp:58-102`). When
   the loop period ≥ the scanout period, boundaries arrive faster than they are
   spent and **zero frames wait**. Phase 4 Stage A measured `frame` at
   17.21–18.02 ms against a 16.6882 ms period — i.e. on exactly the scenes that
   miss 60 fps, the cap already never blocks. There is nothing there for an IRQ
   to make cheaper.
2. **Poll pressure was already A/B'd and is not what the fabric waits on**
   (`raster_backend_mfgpu.cpp:806-816`): 120 s per arm, same RBF and scene,
   `poll_us=0` (~25 000 polls/frame) → fabric 30.6 ms; `poll_us=250` (~2 095
   polls/frame) → 32.6 ms. A 12× cut in DDR poll traffic bought no speedup and
   no fewer stalls. The one genuine benefit of blocking — idling a core that
   otherwise spins at 100 % — is already obtainable with `GMLOADER_MFGPU_POLL_US`
   / `GMLOADER_FCAP_POLL_US` and was measured as *not* free.

## 5. Inferred — the adjacent idea (IRQ on C_DONE) is also mostly blocked

`notice` (host-observed doorbell→C_DONE wait minus the fabric's own busy count)
is the binding host-side term: median **0.56 ms**, of which ~0.158 ms is
`S_SNAP_WAIT`→`S_SNAP_DRAIN` by design, leaving ~0.40 ms split between *host→fabric
doorbell detection* and *fabric→host DDR visibility*
(`findings/2026-07-30-phase4-stage-a-seam.md` §8). That split is **unmeasured** —
Stage C of the W3 spec exists to attribute it.

An f2h IRQ only addresses the fabric→host half. Two reasons to expect that half
is small:

- 0.40 ms ≈ 39 000 clk_sys cycles. DDR3 write-visibility effects are ~100 ns
  scale, three orders of magnitude below that.
- The host→fabric half has a concrete mechanism: the blitter detects a new
  submit by looping `S_POLL_SUBMIT → S_POLL_DONE → S_CHK_NEW`, **two DDR reads
  per iteration** (`blitter_top.sv:1266-1278`), arbitrated against the reader's
  line fetches on the shared f2h port. That is the direction an f2h IRQ cannot
  touch, and the direction the cycle budget points at.

If Stage C's counter shows the residual is fabric→host after all, an f2h IRQ
becomes worth revisiting — it is a sideband that skips the DDR read path
entirely. Until then it is a fix aimed at the smaller, unconfirmed half.

## 6. Unknown

- The doorbell/visibility split inside the ~0.40 ms residual (Stage C).
- Whether `video_sync`'s scanline trigger tracks the core's frame boundary
  closely enough to pace on, given `vs_line` is set by Main_MiSTer.

## 7. Action

None taken. Recommendation: leave the vsync path on DDR polling; do not spend
kernel/DTS work on `f2h_irq[1]`. Keep the f2h-IRQ option filed against Stage C's
attribution result, not against vsync.

---

## 8. Follow-up — the lightweight bridge instead?

**Naming first, because it changes the answer.** There is no "lightweight f2h".
The lightweight bridge is **h2f_lw** (0xFF200000): **HPS is master, FPGA is
slave**, 32-bit AXI-lite, PIO register access. It is not DMA and the fabric
cannot push data over it. The fabric-masters-into-HPS-memory path is f2sdram —
which is what the design already uses.

**Observed: no bridge is instantiated.** `sysmem.sv:391-403` instantiates
`cyclonev_hps_interface_fpga2hps` and `cyclonev_hps_interface_hps2fpga` with
`port_size_config = 2'b11` (disabled stubs, no AXI signals routed), and there is
**no `hps2fpga_light_weight` primitive at all**. `sysmem_HPS_fpga_interfaces`
(`sysmem.sv:241-296`) exposes only `f2h_sdram0/1/2`, the reset requests and
`h2f_user0_clk`. MiSTer's "sysmem_lite" is f2sdram-only by construction.

The DTS marks `fpga_bridge0/1/2` `status = "okay"`
(`socfpga_cyclone5_de10_nano.dts:194-204`), so the kernel un-gates bridges the
fabric does not implement — an access to 0xFF200000 today faults or hangs.
Enabling one means **regenerating the Qsys system**, which is precisely the cost
the audio phase avoided (reallocating existing ports ≠ regenerating Qsys).

**The merit is asymmetric, and the useful half is the doorbell:**

| direction | verdict |
|---|---|
| host→fabric **doorbell** | **Architecturally right.** Today the blitter detects a submit by looping `S_POLL_SUBMIT → S_POLL_DONE → S_CHK_NEW`, two DDR reads per iteration, arbitrated against the reader's line fetches (`blitter_top.sv:1266-1278`). An h2f_lw register write is visible in the fabric in 1–2 cycles and deletes both the loop and its arbiter contention. |
| fabric→host **status** | **No gain.** An A9 uncached read through L3 to h2f_lw is ~1 µs, against the ~1.2 µs uncached DDR load it would replace (`main.cpp:133-141`). Same order; the bridge clock-domain crossing eats the saving. |

**The stronger form is a different port.** If the goal is making the host's
`C_DONE` read cheap, the lever is the **f2h/ACP** master (fabric writes
coherently into L2, host read becomes a cache hit rather than an uncached DDR
load), not h2f_lw. Also absent from `sysmem.sv`, same Qsys cost.

**Ceiling and gate.** Every variant here attacks `notice`, so the arithmetic
ceiling is ~0.40 ms (0.56 median minus the ~0.158 `S_SNAP` drain, which none of
these touch). W3 needs ≥0.35 ms from `notice`, so it is *arithmetically* in
range — but only if the residual is doorbell detection, which is **unmeasured**.
W3 Stage A's doorbell-delay sweep costs one device run and answers exactly that.
Run it before funding any Qsys work.

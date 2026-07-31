# f2sdram_safe_terminator accepts commands it never forwards

Date: 2026-07-31. Branch: `fix/f2h-ready-backpressure`. Base: `perf/phase4-w3` @ 73f7631.

**Status: fixed in RTL, gated in sim, NOT yet validated on hardware.** See §6 for
the device protocol and §5 for what this does and does not explain.

---

## 1. Observed — Main_MiSTer's RBF init is not missing a step

The starting hypothesis was that this port, having begun as a Main_MiSTer fork,
skips part of the bring-up sequence. It does not. `load_core` on
`/dev/MiSTer_cmd` reaches stock `fpga_load_rbf`
(`Main_MiSTer/input.cpp:5884-5887`), which runs the sequence in full
(`fpga_io.cpp:379-393, 460-500`):

```
fpga_core_reset(1)   // gp_out[31:30]=01 -> sys_top.v:589-593 -> reset_req
  ...read the RBF off SD (tens of ms)...
do_bridge(0)         // fpgaportrst=0, brg_mod_reset=7, remap=1
socfpga_load()
do_bridge(1)         // fpgaportrst=0x3FFF, brg_mod_reset=0, remap=0x19
```

`fpgaportrst` is written *before* `brg_mod_reset` is released, so port-enable
ordering is correct, and the RBF read between `fpga_core_reset(1)` and
`do_bridge(0)` gives the terminator a wide window to finish transactions. The
`main=` wrapper is not on the shipping path (`games/Maldita Castilla/_handler.sh`).

## 2. Observed — the defect is in our own fabric, in a vendored MiSTer file

`fpga/sys/f2sdram_safe_terminator.sv`. While `terminating` is set, the bus mux
stops forwarding commands:

```systemverilog
read_master  = read_terminating;    // 0 in the ordinary case
write_master = write_terminating;
```

but waitrequest was a straight passthrough:

```systemverilog
assign waitrequest_slave = waitrequest_master;
```

On Avalon-MM a command is **accepted** on any cycle it is asserted with
waitrequest low. So a fabric master issuing in that window saw `read && !waitrequest`
— taken — for a command that never reached the port, and then waited forever for
a `readdatavalid` that was never requested. Silent loss, no backpressure, no error.

## 3. Observed — the window is real on this core, and recurring

`reset` (sysmem_lite `reset_out`) reaches `emu` **asynchronously**, while the
terminator's `rst_req_sync` is that same signal **double-registered onto
`ram1_clk`** (`sys/sysmem.sv:60-65`). The terminator therefore stays locked for
~3 cycles *after* the fabric has already left reset.

The blitter's `C_SUBMIT` poll issues its first f2h read immediately out of reset
(`S_POLL_SUBMIT -> S_POLL_DONE -> S_CHK_NEW`, two DDR reads per iteration). Every
read landing in the skew window is lost. That is the documented frame-1
signature: `C_SUBMIT` climbing while `C_DONE` stays 0.

Two details worth keeping:

- **Not at first boot.** Both the `lock_stage` and `terminating` assignments are
  gated on `init_reset_deasserted`, which is 0 until reset is first released. The
  terminator is transparent through the power-on window. The exposure is on
  *subsequent* reset assertions — i.e. every `fpga_core_reset` pulse.
- **No upstream core hits it.** Stock `ram1` has one master, `ddram.sv` driven
  from `emu`, which issues on demand. Maldita is the first MiSTer core to put a
  free-running poller on f2h, so the implicit contract ("do not touch f2h while
  reset is asserted") was never stated because nothing could violate it.

## 4. Action — backpressure instead of swallow

```systemverilog
assign waitrequest_slave = waitrequest_master | (terminating & ~read_terminating);
```

The window becomes a stall; the master's own Avalon handshake retries once the
lock clears, so nothing is lost.

`& ~read_terminating` is required. In that state the terminator is completing the
master's **own** read on its behalf, and the master must see the accept — blocking
it there would leave `read_slave` asserted and issue a duplicate command the
moment `terminating` drops.

The fix reaches the arbiter with no further RTL: `waitrequest_slave` →
`ram1_waitrequest` → `DDRAM_BUSY` → `ddr_blitter_arb.ddram_busy`, and both
`rdr_acc` and `blt_acc` already require `~ddram_busy` (`rtl/ddr_blitter_arb.sv:115-116`).

**Gate:** `fpga/sim/tb_f2sdram_term_swallow.sv`, watched fail then pass.

| test | old RTL | fixed |
|---|---|---|
| T1 normal read returns its beat | ok | ok |
| T1 no swallowed command outside the reset window | ok | ok |
| T2 locked terminator does not swallow a read command | **FAIL** | ok |
| T3 the backpressured read completes after unlock | ok | ok |
| T4 interrupted 4-beat write burst still completes | ok | ok |

T4 guards the module's original purpose against the change. Full suite 55/55
gating, 0 failures.

The module was previously **unsimulatable** under Icarus — localparams used
before declaration, `always_comb` driving implicit wires. Fixing that is the rest
of the diff. Note the toolchain squeeze: Quartus Lite 17.0 rejects `localparam`
in the parameter port list (Error 10170) and Icarus will not bind a body
localparam used in the port list above it, so the two derived widths are spelled
inline — the only form both parsers accept.

## 5. Unknown — what this does NOT establish

- **No hardware evidence.** Sim proves the protocol violation is gone; it does
  not prove this is the device's frame-1 wedge. The wedge rate before/after is
  unmeasured.
- **The "f2h dead until reboot" mode is probably separate.** A wedge that
  survives core reloads and clears only on a power cycle matches the terminator's
  own header (lines 11-38): a burst torn mid-transaction leaves the SDRAM
  Controller Subsystem in an illegal state clearable only via `permodrst` /
  HPS cold-warm reset. That is a *different* mechanism from command swallowing,
  and this fix does not obviously address it.
- **A specific open lead on that second mode:** the terminator drains only
  **write** bursts. For reads its comment punts — *"Even not knowing reading is
  in progress or not... it will finish at some point, and no need to do
  nothing"* (paraphrased, lines 182-184) — an assumption written for a
  single-outstanding master. `ddr_blitter_arb.sv:100-111` deliberately keeps **up
  to 8 read commands outstanding**. Whether that is benign at reconfiguration is
  untested. The arb's own `flush` path (`:148-153`), which drops expectations
  while beats may still be in flight, is the other candidate.

## 6. Device protocol for whoever validates this

`.62` was **in use by another agent** on 2026-07-31, so measurement was deferred.
An earlier attempt on that unit is void for that reason, and its instrument was
wrong besides — recorded here so it is not repeated:

- `grep -c ... || echo 0` emits **two** lines on no-match (grep prints `0` and
  exits 1). Swallow the status inside the remote shell.
- A single `devmem` of `C_SUBMIT` is **not** a wedge oracle: the engine's reclaim
  path re-zeroes it, so a wedged board reads `submit=0 done=0` and scores clean.
  Use the engine log's `submit timeout` line.
- **Reboot between trials, not just a core reload.** The f2h-dead state survives
  reloads, so reload-only trials are correlated — one wedge contaminates the rest
  of the run and the rate means nothing.
- `scripts/mister_run.sh` defaults to `root@192.168.20.81`, the **production**
  unit. Always pass `MISTER_HOST` explicitly.
- `mister_run.sh launch` retries internally (`MAX_WEDGE_ATTEMPTS=3`), which hides
  the raw per-load outcome. Drive `load_core` directly for a rate measurement.

Both arms want the same protocol on the same unit from the same boot-fresh state,
differing only in bitstream: baseline `MalditaCastilla_73f7631` (W3, the build
showing the symptom) vs this branch's build. Report the two modes separately —
frame-1 wedge rate, and whether any trial leaves f2h dead across a reload.

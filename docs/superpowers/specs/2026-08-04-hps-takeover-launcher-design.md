# HPS Takeover Launcher — Design

**Date:** 2026-08-04
**Status:** Proposed (research + design; nothing here has run on hardware)
**Scope:** Replace "Master_Daemon spawns the engine as a child of a running
Main_MiSTer" with "the engine owns the HPS", modelled on `skmp/DreamSTer`.
**Prompted by:** the desire to stop competing with `Main_MiSTer` for the two
Cortex-A9 cores, and to unlock the class of host-side optimizations being landed
in the sibling `mamester` project ([PR #5][mamester-pr5]).

**Convention** (borrowed from mamester's review docs, because it earns its
keep here): claims are tagged **[OBS]** (read from source), **[DER]** (derived
from those), **[UNK]** (open, needs a device run).

[mamester-pr5]: https://github.com/gmcnaught/mamester/pull/5

---

## 0. Headline

Today the engine is a guest on a machine `Main_MiSTer` owns. Every host-side
lever we would like to pull — both CPU cores, the cpufreq governor, a
write-combining mapping of the DDR window, exclusive access to the gamepads,
an interrupt instead of a poll — is either taken by `Main_MiSTer` or unavailable
because it is still resident. The proposal is to take the machine.

**The key structural insight, and the reason this is not the `main=` wrapper
again:** the wrapper (`MiSTer_Maldita`) tried to gain control by *becoming*
`main()`, and thereby inherited every obligation `main()` owes the core —
chiefly the scheduler's per-iteration `while (!is_fpga_ready(1))
fpga_wait_to_reset();` guard, which it did not honour before spawning the engine
(`maldita_wrapper.cpp:143` spawn, `:157` first readiness check). Device-measured
2026-07-25: **wrapper 3/5 frame-1 wedges vs stock main 0/5** (CLAUDE.md).

A takeover inverts that. We let stock `Main_MiSTer` do exactly the job it is
good at — load the RBF, satisfy the readiness contract, configure ascal/HDMI,
load the scaler and gamma tables — and only *then* remove it, once the engine is
demonstrably alive on the fabric. **We inherit none of `main()`'s obligations
because we never take its place; we outlive it.** That is a strictly weaker
coupling than the wrapper, not a stronger one.

| | Today (handler) | `main=` wrapper (reverted) | **Takeover (this design)** |
|---|---|---|---|
| Who runs `main()`'s FPGA contract | stock `Main_MiSTer` | our fork, incorrectly | stock `Main_MiSTer`, then nobody needs to |
| CPU available to the engine | 2 cores, shared | 2 cores, shared | **2 cores, exclusive** |
| cpufreq / governor | MiSTer's | MiSTer's | **ours** |
| DDR mapping type | `/dev/mem`, strongly-ordered | same | **`/dev/mem_wc`, write-combining** |
| Gamepad ownership | MiSTer's exclusive evdev grab | same | **ours (evdev/SDL direct)** |
| OSD / core switch | works | works | **gone — must be replaced** |
| Blast radius if it goes wrong | none | frame-1 wedge | **box needs a power cycle if restore fails** |

---

## 1. What DreamSTer actually does

**[OBS]** `skmp/DreamSTer` `Scripts/DreamSTer.sh` (a Python curses app despite
the `.sh` name), read at `main` 2026-08-04. Its README is blunt: *"it kills the
MiSTer process, takes over the fpga, launches minicast and re-loads menu.rbf /
re-starts MiSTer once done"*, and *"is not a MiSTer core."*

The mechanism, in order (`DreamSTer.sh:2123-2270`):

1. **Widen affinity.** `os.sched_setaffinity(0, {0, 1})` — with the in-source
   note that *"MiSTer launches Scripts-menu entries pinned to core 1 via
   taskset"*. **[DER]** A launcher inherits whatever affinity mask its spawner
   had; that is a trap worth checking on our own path too (§6.1).
2. **Identify the victim precisely.** `detect_parent_mister()` reads
   `/proc/<ppid>/exe` and only accepts it if the basename matches
   `/media/fat/MiSTer`; otherwise it falls back to `killall MiSTer`.
3. **Kill it.** `SIGTERM`, poll `/proc/<pid>/stat` for up to 2 s (treating `Z`
   as gone), then `SIGKILL`.
4. **Take the hardware.** `insmod mem_wc.ko`, `load_fpga_bitstream polly2.rbf`,
   `setup_hdmi`, then run the emulator.
5. **Optionally overclock.** `scaling_governor=performance`,
   `scaling_max_freq=1000000` (1 GHz vs the stock 800 MHz), restored in a
   `finally:`.
6. **Always restore.** `finally: restart_mister()` — reload `menu.rbf`, then
   re-exec `/media/fat/MiSTer` detached (`start_new_session=True`). The module
   docstring is emphatic: MiSTer *"is ALWAYS restarted when the script exits, on
   every path."*
7. **Fake the core name.** It writes `DREAMCAST` into `/tmp/CORENAME` at import
   time, so the rest of the MiSTer ecosystem sees a loaded core.

**[DER] Two of the seven steps do not transfer.** Step 4's `load_fpga_bitstream`
+ `setup_hdmi` exist because polly2 is *"Written from scratch — NO MiSTer
framework components"* (`polly2-rtl/sys_top.v:5`), so DreamSTer must init the
ADV7513 itself. Our `sys_top` is the stock framework: HDMI is configured by an
RTL I²C master, ascal is in the fabric, and the RBF is loaded by MiSTer's own
core loader from the OSD. Step 7 is likewise unnecessary — `Master_Daemon`
already puts the real `Maldita Castilla` in `/tmp/CORENAME`, which is how our
handler gets invoked at all.

**The transferable core is steps 1, 2, 3, 5 and 6** — and step 6 is the one that
carries all the risk.

---

## 2. Why we can take over *late*, and why that matters

**[DER]** DreamSTer must kill MiSTer *first*, because it is about to load a
bitstream MiSTer cannot talk to. We are not: our RBF is a conventional framework
core and MiSTer loads it correctly. So we can invert the order:

```
core load (MiSTer)  →  handler  →  engine starts  →  engine proven live  →  kill MiSTer
                                                                              ↑
                                          everything MiSTer owed the core is already done
```

**Late takeover buys three things the DreamSTer ordering cannot:**

1. **The readiness contract is satisfied by the process that owns it.** The
   frame-1 wedge signature (`C_SUBMIT` climbs, `C_DONE` stays 0 forever — the
   `G_BLT_RD` arbiter jam the handler's `sleep 2` already guards against) is a
   *core-load-time* hazard. By the time we kill MiSTer the fabric has completed
   frames.
2. **A liveness gate makes the whole feature fail-safe.** If the engine does not
   reach a proven-live state within a timeout, **we simply do not take over**,
   and the session degrades to exactly today's behaviour with MiSTer intact. A
   bad engine build cannot cost the user their box.
3. **We never reimplement video setup.** ascal config, scaler coefficients,
   gamma tables and the HDMI PLL are all established at core load and live in
   fabric registers/BRAM. **[UNK]** Whether *anything* in that set needs ongoing
   HPS service (the strongest candidate is `video.cpp`'s adaptive
   `vsync_adjust` re-tuning) is §6.2's device question. Our scanout is
   free-running at 59.923 Hz and never waits for the host, so the expectation is
   "no", but the expectation is not evidence.

**Liveness gate, concretely.** `C_DONE` at `0x3B000028` (the control block's
`DONE` qword) advancing across a sample interval is the same signal the phase-2
perf work used as its ground truth, and `busybox devmem` can read it from shell
(CLAUDE.md — `dd` on `/dev/mem` is blocked by `CONFIG_STRICT_DEVMEM`). Two
successive increases means the host is submitting *and* the fabric is retiring.

---

## 3. The blocking dependency: input dies with MiSTer

**This is the one thing that makes the takeover a two-repo change rather than a
shell script.**

**[OBS]** Input reaches the game through the *fabric*, not through Linux:

```
Pad → Main_MiSTer (exclusive evdev grab) → hps_io joystick_0/1 live wires
    → openbor_video_reader.sv (ST_POLL_CTRL → ST_WRITE_JOY0/1)
    → 0x3BF40008 / 0x3BF40018 → JoyDdr_ReadMask() → yoyo_gamepads[]
```

(`docs/architecture/05-data-flows.md` §2, `03-components-engine.md:160-180`.)

**[DER]** Kill `Main_MiSTer` and the `joystick_0/1` wires hold their last value
forever. The engine keeps reading a **well-formed but frozen mask** — precisely
the "input death" failure mode already recorded for the `ST_IDLE`-starvation bug
(`openbor_video_reader.sv:740-748`): *"a controller that works for a moment at
boot and then does nothing, with no error anywhere."*

**[OBS]** And it will not self-heal. `update_inputs()` (`input.cpp:306-339`)
latches its transport once: `JoyShm_Init()` and `JoyDdr_Init()` are each
attempted exactly once, and raw SDL `GameController` polling is reached **only
if neither is active** (`:318-339`). `JoyDdr_Init()` is an `mmap` of a DDR
address — it will keep succeeding with MiSTer dead. So the DDR transport wins
the selection and then delivers a frozen mask.

**[DER] Therefore the engine needs a forced transport selection** — a knob that
makes `sdl` win outright rather than being a fallback of last resort. The good
news is that the SDL path already exists and is already the third arm of the
same selector (the `JOYSRC transport=shm|ddr|sdl` log line at `input.cpp:310-317`
names all three), and with MiSTer gone the exclusive evdev grab is released, so
SDL can actually open the pads. **[DER]** It should also be *lower* latency:
evdev → SDL → `yoyo_gamepads[]` in-process, versus today's
HPS→fabric→DDR→`mmap` round trip that is only sampled once per scanout frame.

**[DER] A pleasant side effect: this supersedes three shelved features.** The
joy-SHM contract (feat #0), the SDL-input-SHM bridge (feat #2) and OSD Reset
(feat #4) all existed to route MiSTer-authoritative input and OSD events into
the engine through the wrapper. Under takeover there is no MiSTer to be
authoritative, and the engine reads the pads directly. The shm channel becomes
dead weight, and `docs/superpowers/specs/2026-07-20-maldita-host-supervisor-integration-design.md`
is superseded by this document for everything except its `Load Quest` removal
(feat #3, already landed).

---

## 4. What else we lose, and what replaces it

| Lost with `Main_MiSTer` | Impact | Replacement |
|---|---|---|
| **Gamepad input** | fatal | forced SDL/evdev transport (§3) — **blocking** |
| **OSD / exit-to-menu** | fatal for a shipped build | restore-on-engine-exit + an engine-side quit chord (Phase 3) |
| **`/dev/MiSTer_cmd`** | loses `screenshot` — CLAUDE.md's most reliable scanout observable | keep a `MALDITA_TAKEOVER=0` diagnostic mode; longer term, capture from the reader's FB double-buffer in the engine |
| **Core switching** | can't leave without restoring | restore path (§5) |
| **Linux/ALSA audio** | already gone — `gm_audio` bypasses ALSA entirely | none needed (`2026-07-29-audio-own-clock-native-rate.md:114`) |
| **Config/mount persistence** | `SC0` mount was already removed (feat #3) | none needed |
| **MiSTer's `is_fpga_ready` watchdog** | nobody re-arms the FPGA on a fabric fault | the reader's own stale-frame watchdog still blanks to black; a wedged fabric now needs the restore path rather than an OSD reset |

**[DER] The screenshot loss deserves emphasis** because it is a *development*
regression, not a user-facing one: comparing screenshot MD5s across time is how
this project distinguishes "frozen" from "animating". Any takeover mode must
therefore stay opt-in and A/B-able against the non-takeover path, or we lose the
instrument we would use to evaluate it.

---

## 5. The restore contract

**This is the highest-risk surface in the design.** A takeover that fails to
restore leaves a user staring at a dead core with no OSD, and no way back except
the power switch.

Non-negotiables, mirroring DreamSTer's `finally:`:

1. **Restore runs on every exit path.** `trap … EXIT INT TERM HUP` in shell,
   covering: engine exit (clean or crash), `Master_Daemon`'s `kill_child` on a
   core change, and the handler being killed by hand.
2. **Restore is idempotent and best-effort.** Every step is
   failure-tolerant — a failed `menu.rbf` load must not prevent the `MiSTer`
   re-exec, which is the step that actually gives the user their box back.
3. **Restore restores everything it changed**, in reverse: cpufreq governor and
   `scaling_max_freq` first (cheap, local), then the FPGA/menu, then MiSTer.
4. **Never take over unless we can restore.** If `/media/fat/MiSTer` is not
   executable, or we could not identify the MiSTer process, do not kill anything.
5. **A re-entry guard.** Restoring MiSTer means MiSTer reloads a core; if it
   reloads *this* core, `Master_Daemon` fires the handler again, which takes
   over again — a loop that would be very hard to break from the couch. A
   timestamp stamp file that suppresses takeover for N seconds after a restore
   turns that into a single degraded (but playable, and exitable) session.

**[UNK]** Whether re-exec'ing `/media/fat/MiSTer` reloads `menu.rbf` by itself,
or whether the FPGA must be reloaded first as DreamSTer does. DreamSTer needs
the explicit reload because polly2 is not a framework core and MiSTer cannot
talk to it; our core *is* one, so MiSTer may come up on top of it and simply
work. §6.3 settles it on device. Until it is settled, the restore path attempts
the menu reload and continues regardless.

**[UNK]** How `Main_MiSTer` is supervised on this device — whether an init
script respawns it (in which case `kill` starts a fight) or it is a one-shot
(DreamSTer's design implies one-shot). §6.4.

---

## 6. Open questions, in the order they should be answered on device

### 6.1 Is the prize real? *(measure before building anything)*

**[UNK]** How much CPU `Main_MiSTer` actually costs us. It is a polling
scheduler; the engine's frame period is ~27.3 ms against a 16.7 ms target
(`2026-07-29-maldita-60fps-phase2-host-lever.md`), so host CPU is the live
bottleneck and even a few percent is bankable — but "a few percent" and "a
core" are very different justifications for this much risk.

**A zero-risk A/B exists and should be run first:** `kill -STOP` the MiSTer pid
during confirmed gameplay, sample the `C_DONE` period over ≥30 s, `kill -CONT`.
`SIGSTOP` takes MiSTer off the run queue without touching its evdev grab, its
mappings, or the FPGA — and input freezes for the duration exactly as it would
under a real takeover, which makes it a *faithful* preview of the CPU effect and
an unfaithful one of nothing else. Also worth capturing: `top -b -n1` for
MiSTer's steady-state share, and the handler's inherited affinity mask
(`taskset -p $$`) — DreamSTer's core-1 pinning discovery (§1.1) may have an
analogue on the `Master_Daemon` path.

### 6.2 Does anything in the video pipeline need ongoing HPS service?

Run the §6.1 `SIGSTOP` for 60 s and watch for drift, resync or blanking. A
`SIGSTOP` that visibly disturbs video is a red flag for the whole design; a
clean one is strong (not conclusive) evidence that ascal/HDMI are set-and-forget.

### 6.3 Does re-exec'ing `/media/fat/MiSTer` restore the menu on its own? (§5)

### 6.4 Is `Main_MiSTer` respawned by an init supervisor? (§5)

### 6.5 Is `0x3B000000` inside a `/proc/iomem` "System RAM" range?

Not needed for the takeover itself, but it is the gate on the `mem_wc`
write-combining work (§7) — the same question mamester's review left open, and
one `cat` answers it for both projects.

---

## 7. What the takeover unlocks (the actual point)

Ordered by expected value per unit of risk. None of these are in scope for the
takeover itself; they are why it is worth doing.

1. **Write-combining DDR via `mem_wc`.** mamester measured **89.5 MB/s** for an
   uncached `/dev/mem` memcpy into the fabric window versus **540.5 MB/s**
   cached, and traced it to ARM's `phys_mem_access_prot()` returning
   `pgprot_noncached` (Strongly-Ordered) for any pfn outside memblock —
   `O_SYNC` never gets a look in. `mem_wc.ko` is a ~120-line driver that sets
   `pgprot_writecombine` unconditionally. **[DER] Our exposure is larger than
   mamester's**: they push one 384 KB frame per frame; we push texture staging
   into a ~14.75 MB SRC heap plus per-frame ring and vertex traffic, and
   sub-region texture residency exists specifically because that path is
   expensive. This is the single biggest host-side lever visible today.
   It carries mamester's three ordering prerequisites, unchanged and
   non-negotiable: `dsb sy` (not `__sync_synchronize()`, which lowers to
   `dmb ish` and does not order against the f2h SDRAM ports), keep the doorbell
   page strongly-ordered via a page-exact `MAP_FIXED` overlay, and make the
   barriers unconditional rather than gated on which `open()` won.
   **[DER] A takeover is not strictly required to `insmod` a module** —
   mamester does it from an ordinary handler — but it removes the last
   objection to shipping one, since a takeover session already owns the box.
2. **cpufreq: `performance` governor + 800 → 1000 MHz.** DreamSTer's overclock,
   restored on exit. ~25 % more host CPU on a host-CPU-bound workload, for a
   thermal risk the user opts into.
3. **Both cores, exclusively.** The audio pump is already pinned to core 1 and
   the main thread to core 0 (`2026-07-27-gmloader-native-audio-design.md:121`),
   which is a *sharing* arrangement forced by MiSTer's presence. With MiSTer
   gone the pinning can be re-derived from what the engine actually needs.
4. **Lower-latency input**, as a side effect of §3's forced SDL transport.
5. **Later, and only with a kernel module of our own:** an interrupt instead of
   the `C_DONE` poll, and a PL330 DMA path for texture staging (blocked today by
   `CONFIG_UIO is not set` and dmaengine having no userspace API).

---

## 8. Explicitly out of scope

**Full DreamSTer parity — a from-scratch `sys_top` with private f2sdram masters
and our own scanout — is not proposed and should not be.** polly2's three
private Avalon masters and its 128-bit SPG scanout replace ascal, the OSD, the
scaler and the analog path; that is a different project's answer to a different
constraint. Our `openbor_video_reader.sv` feeding `arcade_video`/ascal is the
right shape, and nothing in polly2 argues otherwise. **This design takes
DreamSTer's HPS-side ownership model and none of its fabric-side one.**

Also out of scope: reviving the `main=` wrapper (superseded — §0), and any
change to the fabric, the wire protocol, or the reference model. **The takeover
is a launch-path and host-process change only.** No RTL, no `blt_wire.h`, no
golden regeneration.

---

## 9. Deliverables

| Repo | What |
|---|---|
| `maldita.castilla-mister` | takeover harness in the launch path (`games/Maldita Castilla/`), opt-in and default-off; `deploy.py` support; this design + its plan |
| `gmloader-next` | forced input-transport selection (§3) — **blocking for a playable takeover**; later, the `mem_wc` mapping and barriers in `raster_backend_mfgpu.cpp` |
| `mister-fpga-blitter` | nothing. The protocol does not move. |

## Sources

- `skmp/DreamSTer` @ `main`, 2026-08-04: `README.md`;
  `Scripts/DreamSTer.sh:2123-2149` (parent detection), `:2150-2168` (kill),
  `:2175-2190` (restore), `:2210-2240` (launch, `insmod`, cpufreq),
  `:2244-2270` (`main()`, affinity, `finally`).
- `gmcnaught/mamester` PR #5: `docs/dreamster-ddr-channel-review.md` (the
  `mem_wc` mechanism, the three ordering fixes, the `pfn_valid` argument);
  `docs/present-latency-and-cpu-offload.md` §1 (89.5 vs 540.5 MB/s).
- This repo: `CLAUDE.md` (wrapper wedge measurement, `devmem`, screenshot);
  `games/Maldita Castilla/_handler.sh`; `docs/architecture/05-data-flows.md` §2
  and `03-components-engine.md:160-180` (input transports);
  `docs/superpowers/specs/2026-07-20-maldita-host-supervisor-integration-design.md`
  (the wrapper design this supersedes);
  `docs/superpowers/plans/2026-07-29-maldita-60fps-phase2-host-lever.md`
  (the 27.3 ms period and `C_DONE` as ground truth).

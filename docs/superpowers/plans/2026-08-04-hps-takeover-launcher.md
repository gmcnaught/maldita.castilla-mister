# HPS Takeover Launcher — Plan

> **For agentic workers:** REQUIRED READING: `docs/superpowers/specs/2026-08-04-hps-takeover-launcher-design.md`.
> Steps use checkbox (`- [ ]`) syntax for tracking. Tasks are ordered so that the
> cheapest evidence comes first and nothing irreversible happens before it.

**Goal:** the engine owns the HPS. `Main_MiSTer` loads the core, satisfies its
FPGA-readiness contract, configures video — and is then removed, leaving both
Cortex-A9 cores, the cpufreq governor, the gamepads and the DDR mapping type to
us.

**Architecture:** late takeover, liveness-gated, always-restore. See the design
doc §2 and §5; the restore contract is the part that must not be compromised.

**Tech Stack:** bash (device launch path, this repo), C++ engine
(`gmloader-next`, armhf Docker cross-build), device `.62` for bring-up.

## Global Constraints

- **`.62` ONLY for every device step in Phases 0–4.** `.81` is production and a
  failed restore there costs a power cycle mid-session.
- **No RTL, no wire-protocol, no reference-model change.** This is a launch-path
  and host-process change (design §8). If a task starts wanting to touch
  `fpga/rtl/` or `blt_wire.h`, it is the wrong task.
- **Takeover is opt-in and default-off until Phase 5.** The non-takeover path
  must stay byte-identical in behaviour, because it is the A/B baseline *and*
  the only path with `/dev/MiSTer_cmd screenshot` — this project's most reliable
  scanout observable (design §4).
- **Every device session that enables takeover must be reachable by SSH before
  it starts.** With MiSTer dead and input not yet ported (Phase 2), SSH is the
  only way out.
- Evidence for any perf claim is the `C_DONE` period at `0x3B000028` over ≥30 s
  of screenshot-confirmed gameplay, per
  `docs/superpowers/plans/2026-07-29-maldita-60fps-phase2-host-lever.md`. Never
  `wait_ms`, never DRAW_TRACE `frame`.

---

## Phase 0 — Measure the prize before building anything

**Nothing in this phase changes a file.** If `Main_MiSTer` turns out to cost
~nothing, Phases 1–5 are not worth their risk and the design's §7 levers should
be pursued from the ordinary handler path instead (mamester does exactly that
for `mem_wc`).

### Task 0.1: `SIGSTOP` A/B

- [ ] Start the game normally on `.62`, confirm animation via two screenshot MD5s.
- [ ] Sample the `C_DONE` period for ≥30 s (`busybox devmem 0x3B000028 32`).
- [ ] `kill -STOP $(pidof MiSTer)`; re-sample for ≥30 s; `kill -CONT`.
- [ ] Record both periods and the delta in `docs/superpowers/findings/`.

`SIGSTOP` is a faithful preview of the **CPU** effect and of nothing else: it
does not release the evdev grab, so input freezes exactly as it will under a
real takeover — expect that, do not report it as a regression.

### Task 0.2: The cheap hypothesis, before the expensive one

Source reading (design §2a.1) turned up that `Main_MiSTer` pins its main worker
to **core 1** (`main.cpp:44-48`) and its offload thread to core 0 — and our
audio pump is pinned to **core 1** too. The contention is a specific two-way
fight, not diffuse load.

- [ ] A/B the audio pump on core 0 vs core 1, MiSTer untouched. If most of the
      `SIGSTOP` win arrives from moving one thread, that is a one-line change
      against a multi-repo architectural one — take it first and re-baseline
      the takeover against the new number.

### Task 0.3: Collateral observations, same session

- [ ] `top -b -n1` — MiSTer's steady-state CPU share.
- [ ] `taskset -p $$` from inside `_handler.sh` — is the handler inheriting a
      single-core mask, as DreamSTer found for Scripts entries (design §1.1)?
- [ ] Hold the `SIGSTOP` for 60 s and watch the display for drift, resync or
      blanking — the design's §6.2 question about whether ascal/HDMI need
      ongoing HPS service.
- [ ] `cat /proc/iomem | grep -i "system ram"` and `cat /proc/cmdline` — settles
      §6.5 for the `mem_wc` work in Phase 4, and costs 30 s here.
- [ ] `ps w | grep -i mister` and `ls /etc/init.d/` — is MiSTer respawned by a
      supervisor (§6.4)? This decides whether Phase 3 can kill it at all.

**Gate:** do not start Phase 2 or 3 until 0.1 shows a period improvement worth
the risk. Phase 1 is cheap enough to land regardless, as it is inert when off.

---

## Phase 1 — The takeover harness (this repo) — **LANDED**

Implemented in this commit. Inert unless explicitly enabled.

- [x] `games/Maldita Castilla/mister_takeover.sh` — parent detection, kill,
      liveness gate, cpufreq, restore, re-entry guard.
- [x] `games/Maldita Castilla/launch.sh` (renamed from `_handler.sh`
      2026-08-05, see Phase 1b) — branch to the takeover runner when enabled;
      the `exec ./gmloader` path is unchanged when it is not.
- [x] `Scripts/MalditaCastilla.sh` — the daemon-free entry point (design §2a):
      `load_core` down `/dev/MiSTer_cmd`, wait for `/tmp/CORENAME`, `exec`
      `launch.sh`.
- [x] `deploy.py` — ship `mister_takeover.sh` and the Scripts launcher;
      `--takeover` / `--no-takeover` manage the on-device `takeover.env` marker.
- [x] `tools/mister-takeover/test_takeover.sh` — 18 host tests.

### Task 1.1: Review the restore contract against design §5

- [ ] Confirm by reading: restore runs on **every** exit path
      (`trap … EXIT INT TERM HUP`), every step is failure-tolerant, the
      `MiSTer` re-exec is last and unconditional, and takeover is refused
      outright when the MiSTer binary is missing or the process could not be
      identified.
- [ ] Confirm the re-entry guard: a restore stamps a file, and a handler
      invocation within `MALDITA_TAKEOVER_REENTRY_S` of that stamp runs
      **without** takeover rather than looping.

### Task 1.2: Bring up the daemon-free launcher (takeover still disarmed)

This is separable from the takeover and worth landing on its own — it is what
removes `Master_Daemon` from the launch path.

**Superseded in part by Phase 1b:** this task assumed the daemon could stay
installed and simply not be used. It cannot — see the design addendum. The
launcher is renamed off the daemon's discovery predicate, so "does it still work
with the daemon stopped" is no longer the question; "does the daemon still see
us at all" is.

- [x] Scripts → `MalditaCastilla` with the core NOT loaded: core loads, engine
      runs, `launch.log` carries the step trace (`.62`, 2026-08-05).
- [x] Stop `Master_Daemon` entirely and confirm the launcher still works —
      verified, and now the permanent arrangement rather than a test case.
- [ ] Repeat with the core ALREADY loaded — the launcher should skip
      `load_core` and go straight to `launch.sh`.
- [ ] Repeat with `fb_terminal=0` in `MiSTer.ini`. That is the `popen` path,
      where our stdout is MiSTer's pipe and MiSTer `_exit(0)`s mid-load
      (design §2a fact 4) — if the redirect-before-load is wrong, this is the
      configuration that shows it as a SIGPIPE death. **Not yet run.**
- [ ] Confirm the negative: with takeover disarmed, loading a different core
      from the OSD leaves the engine running (the documented tradeoff). Record
      what that actually looks like on screen.

### Task 1b: Rename off `Master_Daemon`'s discovery predicate — **LANDED**

Forced by device measurement; full rationale in the design addendum.

- [x] `_handler.sh` → `launch.sh`, with both callers
      (`Scripts/MalditaCastilla.sh`, `maldita_hook.cpp`) updated.
- [x] `deploy.py` installs `launch.sh` and **hard-fails** if it cannot delete a
      device's `_handler.sh`; it no longer kills/restarts the daemon at all.
- [x] `scripts/mister_run.sh` — was relying on the daemon to spawn the engine
      after its own `load_core`, so it would have benched nothing. Now waits for
      `/tmp/CORENAME` and starts `launch.sh` itself.
- [x] Release bundle ships `Scripts/MalditaCastilla.sh` (otherwise the bundle
      contains a launcher nothing can invoke); both manifests updated.
- [x] Verified on `.62` with the daemon RUNNING: Scripts entry yields exactly
      **one** engine, where the pre-rename build yielded two.

### Task 1.3: Dry-run the harness with the kill disabled

- [ ] Deploy to `.62` with `MALDITA_TAKEOVER=1` and
      `MALDITA_TAKEOVER_DRYRUN=1` (logs every step, kills nothing).
- [ ] Verify the log shows: MiSTer identified by pid **and** exe path, the
      liveness gate passing on a healthy engine, and a full restore sequence on
      exit.
- [ ] Verify with a *deliberately broken* engine (rename `gmloader.json`) that
      the liveness gate **times out and refuses to take over**, leaving MiSTer
      alive — the fail-safe property from design §2.

---

## Phase 2 — Engine input transport (`gmloader-next`) — **blocking**

Without this, a real takeover is unplayable: `JoyDdr_Init()` keeps succeeding
against a DDR window nobody is writing any more, so the engine latches the DDR
transport and reads a frozen mask forever (design §3).

### Task 2.1: Force the transport by environment

- [ ] Add `GMLOADER_JOY=sdl|ddr|shm|auto` (default `auto` = today's exact
      precedence) to `update_inputs()` (`input.cpp:306-339`).
- [ ] `sdl` must **skip `JoyDdr_Init()`/`JoyShm_Init()` entirely**, not merely
      lose to them — the bug is that DDR *succeeds*.
- [ ] The existing `JOYSRC transport=` line must report the forced choice; it is
      the only in-band evidence of which channel is live.
- [ ] Host-native unit test: with the env var set, the SDL arm is selected even
      when a DDR mapping is available.

### Task 2.2: Verify SDL actually opens the pads once MiSTer is gone

- [ ] On `.62`, with MiSTer killed by hand and the engine launched over SSH with
      `GMLOADER_JOY=sdl`: confirm `JOYSRC transport=sdl` and that the pad moves
      the character.
- [ ] Confirm the pad is *not* openable with MiSTer alive (it holds an exclusive
      evdev grab, `05-data-flows.md` §2) — this documents why the two changes
      must ship together.

### Task 2.3: Wire it into the takeover path

- [ ] `mister_takeover.sh` exports `GMLOADER_JOY=sdl` when takeover is armed,
      and leaves it unset otherwise.

---

## Phase 3 — First real takeover on `.62`

**Do not start until Phase 0 gated it and Phase 2 landed.** Have an SSH session
open and confirmed working before enabling.

### Task 3.1: Bring-up

- [ ] Enable takeover on `.62` (no dry-run), load the core, confirm gameplay and
      pad input.
- [ ] Confirm MiSTer is actually gone (`pidof MiSTer` empty) and video is
      unaffected.
- [ ] Measure the `C_DONE` period and compare against both the Phase 0 baseline
      and the Phase 0 `SIGSTOP` figure. The takeover number should match the
      `SIGSTOP` number; a gap means something else changed.

### Task 3.2: Exercise every restore path

Each of these must end with a usable MiSTer menu, verified from the couch and
not just over SSH:

- [ ] engine exits cleanly
- [ ] engine crashes (`kill -SEGV`)
- [ ] handler is killed (`kill` the handler pid — simulates `Master_Daemon`'s
      `kill_child`)
- [ ] handler is `kill -9`'d — the one path where the `trap` cannot run.
      **Document what state this leaves the box in**; if it is unrecoverable,
      that is a shipping blocker and needs a watchdog (Task 5.2).

And the restore's two-step sequence specifically (design §5): the restarted
MiSTer comes up **on our core**, and only the follow-up `load_core menu.rbf`
gets the user to the menu.

- [ ] Confirm the restarted MiSTer does come up rather than hitting
      `is_fpga_ready(1)` false and quitting with "Bye bye".
- [ ] Confirm the `menu.rbf` request lands and MiSTer `app_restart()`s into the
      menu.
- [ ] Confirm no path blocks on the FIFO write (a hang here is a hung box —
      the guard is `pidof` + settle + `timeout`).

### Task 3.3: Prove the re-entry guard

- [ ] After a restore, if MiSTer reloads the Maldita core, confirm the second
      handler invocation runs **without** takeover and the session is exitable.

---

## Phase 4 — Spend what the takeover bought

Independent of each other; take them in expected-value order (design §7). Each
gets its own A/B against the Phase 3 number.

### Task 4.1: cpufreq

- [ ] Enable `MALDITA_TAKEOVER_GOVERNOR=1` (`performance`, 800 → 1000 MHz) and
      re-measure. Confirm restore puts both values back on every exit path.

### Task 4.2: `mem_wc` write-combining — the big one

- [ ] Vendor `mem_wc.ko` (GPL-2.0, from `skmp/minicast`) under `tools/mister/`
      with its build recipe, as mamester did.
- [ ] **Ordering fixes first, unconditionally** — they are correct under both
      mappings and their absence is a silent, intermittent corruption:
      `dsb sy` (not `__sync_synchronize()`) before every doorbell store in
      `raster_backend_mfgpu.cpp`; keep the control-block page strongly-ordered
      via a page-exact `MAP_FIXED` overlay.
- [ ] Only then move the SRC heap / ring / vertex pages onto `/dev/mem_wc`,
      with a `/dev/mem` fallback so a stale module costs frame rate and nothing
      else.
- [ ] Sanity check that the mapping actually changed: under a real WC mapping
      NEON stores should **overtake** `memcpy`, inverting the strongly-ordered
      result. If they do not, the mapping did not take.

### Task 4.3: Re-derive thread affinity

- [ ] With both cores exclusively ours, re-examine the audio-pump-on-core-1 /
      main-on-core-0 split, which was chosen while sharing with MiSTer.

---

## Phase 4b — Cores-browser entry via a minimal `main=` wrapper (optional)

Only if the Scripts-menu entry is not good enough on usability grounds. The
Cores browser lists `.rbf`/`.mra`/`.mgl` only and `main=` is the sole per-core
exec hook, so this is the one route to an `_Other/` entry without a resident
watcher (design §2b). **Do not start this before Phase 3 is green** — it is a
usability upgrade on a working system, not a prerequisite for one.

### Task 4b.1: Rebuild the overlay around upstream's `main()` — **LANDED**

- [x] **Deleted `maldita_main.cpp`**, and removed the Makefile's
      `$(filter-out main.cpp, …)` so upstream `main()` is built. The readiness
      contract is now correct by construction rather than by review.
- [x] One readiness-gated fork, hooked from `scheduler.cpp` immediately after
      `scheduler_wait_fpga_ready()` — a 95-line vendored file rather than
      `user_io.cpp`'s 4363.
- [x] Dropped `maldita_joy_shm.*`, `maldita_osd.*`, `maldita_wrapper.*`,
      `input.{cpp,h}`, `user_io.{cpp,h}` and the respawn logic. Overlay: 13
      files / ~12 000 lines -> 5 files / ~350.
- [x] `PR_SET_PDEATHSIG` removed from the child — it would kill the engine when
      the takeover kills the wrapper. Regression-guarded by
      `test_survives_parent_death()`, verified to fail with the flag restored.
- [x] `MISTER_PROC_NAMES` in `mister_takeover.sh`, so the takeover recognises
      `MiSTer_Maldita` and does not silently refuse to arm.
- [x] `maldita_hook.cpp` honours the takeover restore stamp, suppressing the
      *spawn* (not just the takeover) so a restore can reach the menu.
- [x] `build-hps.sh` asserts the overlay is upstream + added lines only — the
      guard against a silently stale vendored `scheduler.cpp`.
- [x] `make -C tools/mister-wrapper/test` — host-native tests for the child.

### Task 4b.2: Re-run the measurement that killed the last wrapper — **the gate**

Everything above is unproven until this passes. Build first:
`tools/mister-wrapper/build-hps.sh` (Docker armhf cross-build), then deploy with
`--main-wrapper`.

- [ ] 5× frame-1 wedge test on `.62`, same RBF and engine, against the stock-main
      baseline. The reverted wrapper scored **3/5 wedges vs stock main 0/5**;
      anything but 0/5 means the readiness contract is still not being honoured
      and the wrapper goes back on the shelf.

### Task 4b.3: Ship the entry — **LANDED (untested on device)**

- [x] `_Other/Maldita Castilla.mgl` pointing at the dated RBF, so the visible
      Cores-browser name is stable across builds. `deploy.py` rewrites its
      `<rbf>` to whichever RBF it just installed.
- [x] `deploy.py --main-wrapper` writes the `[Maldita Castilla] main=` line;
      without the flag an active line is still commented out, because the
      wrapper is not yet device-proven.
- [ ] Confirm both entry points still work: Cores browser via `main=`, and the
      Scripts launcher, without either interfering with the other.

---

## Phase 5 — Make it shippable, or decide not to ship it

### Task 5.1: An exit path that does not need SSH

- [ ] An engine-side quit chord (e.g. Start+Select held 2 s) that exits the
      engine cleanly, which the harness already turns into a full restore.

### Task 5.2: Decide the default

- [ ] If Phase 3.2's `kill -9` case is unrecoverable, either add a watchdog that
      restores MiSTer when the handler disappears, or keep takeover opt-in
      permanently and say so in the README.
- [ ] Restore the screenshot observable under takeover, or document that
      `MALDITA_TAKEOVER=0` is the required mode for any diagnostic session
      (design §4).

### Task 5.3: Retire what this supersedes

- [ ] Mark `2026-07-20-maldita-host-supervisor-integration-design.md` superseded
      for feats #0, #2 and #4 (design §3).
- [ ] Decide the fate of `vendor/Main_MiSTer` + `tools/mister-wrapper/`, and of
      the joy-shm transport in the engine, once takeover is the default.

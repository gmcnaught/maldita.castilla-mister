# Fabric startup wedge — investigation handoff

> ## RESOLVED 2026-07-27 (same-day follow-up session)
>
> **Root cause:** the blitter parks forever on its FIRST `C_SUBMIT` poll read.
> The read is accepted by the f2h port inside the core-load bring-up window but
> its response beat never returns; `S_RD_WAIT` had no timeout, so `rd_issued`
> stayed 1 and `C_DONE` was never written. The arb self-heals lost beats
> (FLUSH_QUIET_MAX ~10.6 ms) — no master did. Solarus is immune because its only
> fabric DDR master (the reader) starts at first vblank and retries on timeout;
> the blitter polls from µs after reset with no retry.
>
> **The "single most important clue" below was a red herring.** `C_SUBMIT`
> "halting at 21/33" is the host's reclaim loop: one increment per
> 200 ms-timeout + 60-frame-drop cycle, sampled at a fixed trial time. The
> daemon/hand difference is elapsed-runtime, not command-stream position.
>
> **Ruled out by 22 instrumented launches on .62:** stale DDR content
> (pre-zeroed control block wedges identically; a stale-mismatch boot ran
> fine), teardown-under-load (quiesced teardown, same rate), settle time,
> `FPGAPORTRST` re-pulse mid-wedge (no revival — nothing re-issues the read),
> and 288x216 (as this doc already established).
>
> **Fix:** `maldita.castilla-mister` branch `probe/wedge-live-dbg` — S_RD_WAIT
> reissue watchdog (`RW_WD_MAX = 2^22-1` ≈ 42.6 ms, deliberately > the arb's
> flush window so a reissue can never pair with a stale expectation), sim gate
> `tb_blitter_rdwait_reissue`, plus a reader-published liveness beacon at
> `0x3BFB0010` ({blitter dbg, beacon_cnt}) for any future park. First device
> validation: 9/10 OK vs 50% same-day baseline; final validation in flight.
> Rider fix: the .62 input death (JOY writeback starved with `ST_IDLE`) —
> JOY chain re-anchored at `ST_POLL_CTRL`.
>
> **Address trap that cost hours:** the reader-contract words live at
> `FB_QW_BASE = 0x3BF40000` (ctrl/joy/beacon; vsync word is dead in ship —
> `SCANOUT_ONLY(1'b1)`). `0x3A000000` (`VCTRL_QW`) is the RETIRED blitter-side
> word; devmem forensics at `0x3A07xxxx` read unrelated memory.

**Written:** 2026-07-27, end of the native-288x216 session
**For:** the next session, which will hunt this specifically
**Status:** open, reproducible, **pre-existing** (NOT caused by native-288x216)
**Unit:** `.62` = `root@192.168.20.62` (hostname `misterCade`, analog/tri-sync CRT). `.81` was recorded 2026-07-26 as wedging on reconfigure — do not use it.

---

## The symptom

On roughly half of core launches, the engine renders but the fabric never
acknowledges a single submit. The display stays black.

```
backend_mfgpu: fabric submit timeout (submit=2 done=0 status=0 waited=200ms)
backend_mfgpu: fabric still on seq=2 - frame dropped (ring left intact; 61 dropped)
backend_mfgpu: fabric never acked seq=2 after 60 frames - reclaiming the ring
```

Control-block state at the halt (`busybox devmem`):

| field | addr | wedged | healthy |
|---|---|---|---|
| `C_SUBMIT` | `0x3B000000` | halts at a fixed value | climbs to 0x300–0x470+ |
| `C_DONE` | `0x3B000028` | **stays `0x00000000`** | tracks submit |
| `C_STATUS` | `0x3B000030` | `0x00000000` | `0x00000000` |

## The single most important clue

**The halt point is fixed, and it differs by launch method:**

- launched by the **daemon/handler**: submit halts at **`0x15` (21)**, ~40 timeouts
- launched **by hand** over ssh: submit halts at **`0x21` (33)**, ~65 timeouts

Consistent within a method across independent trials. That is not a random
race — it is a **deterministic point in the startup command stream**. The
fabric accepts N submits, then stops acking, at a reproducible N.

So the productive question is not "where is the race?" but **"what does the
Nth submit do that the previous N-1 did not?"** Candidates worth checking in
order:

1. the first **heap wrap** / first eviction in the SRC heap bump allocator
2. the first **TRILIST carrying `BLT_F_SRC_SURFACE` (0x80)** — texels sampled
   from the APPSURF surface rather than the SDRAM heap
3. the first **`OP_SET_TARGET` switch to `BLT_TARGET_APPSURF` (2)** after WORK
4. the first command that crosses a ring-buffer boundary

The ring content at the halt decodes as **valid, well-formed commands** — I
checked. Sample from a wedged run (`cmd`, then 8 u32s):

```
cmd0 @0x3B000040: 0x0000000B ...                      SET_TARGET, target=2 (APPSURF)
cmd1 @0x3B000060: 0x00000002 .. 0x00D80120 ..         w=0x120=288, h=0xD8=216
cmd3 @0x3B0000A0: 0x0000000A 0x0009A7C8 0x01220244    TRILIST
cmd7 @0x3B000120: 0x8000000A ...                      TRILIST | BLT_F_SRC_SURFACE
```

So this is not command corruption. The fabric stops consuming valid work.

## What it is NOT

- **Not caused by native-288x216.** Measured via the documented daemon path,
  4 trials each:

  | pair | result |
  |---|---|
  | new engine (288) + new 288 RBF | 1 ok / 3 wedge |
  | old engine (320) + old `floortex` RBF — fully pre-change | **0 ok / 4 wedge** |

  Identical signature (`submit=0x15`, `C_DONE=0`). The new pair is if anything
  marginally better; at n=4 treat as equal.

- **Not the `fabric_ready` fix regressing in our code.** There is no
  `fabric_ready` symbol anywhere — I searched every `gmloader-next` branch with
  `git log --all -S'fabric_ready'` and the production RTL. What that name refers
  to is **stock MiSTer main's** scheduler guard,
  `while (!is_fpga_ready(1)) fpga_wait_to_reset();` in `scheduler.cpp`
  `scheduler_co_poll`, cited at `_handler.sh:11-12`. It stays effective by NOT
  replacing main with the `main=` wrapper, plus the handler's 2 s FPGA settle
  (`_handler.sh:49-53`). `deploy.py`'s comment records the measurement behind
  that choice: **wrapper 3/5 frame-1 wedges vs stock main 0/5**, same RBF and
  engine, 2026-07-25. Today the daemon path wedges 3–4 of 4, so either that 0/5
  was luck at n=5 or something regressed after 2026-07-25. **Worth bisecting.**

- **Not a settle-time problem.** Trials waited 18–25 s after `load_core`, far
  beyond the handler's 2 s. Wedge rate unchanged.

## Two traps that will waste your time — both bit me

1. **The Master_Daemon races your launch.** It watches `/tmp/CORENAME` and runs
   `games/<CORENAME>/_handler.sh`. Any script that issues `load_core` makes the
   daemon launch its *own* `./gmloader` beside yours — two processes on the same
   `/dev/mem`, control block and ring. The healthy-looking `submit == C_DONE`
   samples I collected were most likely the *daemon's* instance driving the
   fabric while the one under test was wedged. Tells: more than one
   `./gmloader -c gmloader.json` in `ps`; `maldita handler: reaping a
   pre-existing gmloader before relaunch` in `/tmp/master_daemon.log`.
   **Assert exactly one gmloader process inside every trial**, not once at the start.

2. **`bin_dir` follows the executable.** Run the engine from `/tmp` and it looks
   for `libGLES_sw.so` and `mesa/` there, fails with `Cannot load
   libGLES_sw.so`, never renders, never submits — which reads as "no wedge".
   Copy each engine INTO `/media/fat/games/gmloader/` under its own name and run
   it from that directory.

Also: `submit` and `C_DONE` are read non-atomically, so a fast healthy run can
sample `done == submit + 1`. Require `|submit - done| <= 1` to call it healthy,
or you will log false wedges.

And note `_handler.sh:67`: *"always test via the daemon, not by hand."* Hand
launches give a *different* halt point (33 vs 21), so they are measuring
something subtly different. Prefer the daemon path for anything comparative.

## Reproduction

Harnesses left on the device (they do not survive a reflash — recreate from here):

- `/tmp/dtrial.sh <engine-src> <rbf> <n>` — **daemon path** (correct method):
  bounces to menu, swaps the engine into the handler's fixed path
  `/media/fat/games/gmloader/gmloader`, loads the core, lets the handler launch
  it, then samples. Asserts one process; classifies OK / WEDGE / NOSUBMIT / INVALID.
- `/tmp/trial2.sh <engine-path> <rbf> <n>` — hand-launch variant.
- `/tmp/dump_ctl.sh` — dumps the 8 control-block qwords (low u32 each).
- `/tmp/dump_ring.sh <n>` — dumps n ring commands (4 qwords / 32 B each) from `0x3B000040`.

Engines parked on the device for A/B:

| path | md5 | what |
|---|---|---|
| `/media/fat/games/gmloader/gmloader.288` | `fc6ab2d306ef126d3f7db99fc649b642` | clean 288x216 build (native-288x216 branch) |
| `/media/fat/games/gmloader/gmloader.old` | `6d2c8fc10c4a169b0c79af5f4fb61544` | pre-change 320x240 build |
| `/media/fat/games/gmloader/gmloader` | — | whatever the handler launches; keep it = the build under test |

RBFs: `/media/fat/_Other/MalditaCastilla_20260727.rbf` (288, md5
`5d46782b77ef4a37566a775865c16ba7`) and `MalditaCastilla_floortex.rbf` (pre-change 320).

**A geometry rebuild needs `rm -rf build/arm-linux-gnueabihf` first** —
`MISTER_WIDTH` arrives via `-D` flags and make cannot invalidate `.o` files on a
flag change, so an incremental build silently mixes geometries and a matching
md5 will not catch it.

## Control-block map

Qword-strided from `BLTCTRL = 0x3B000000`, low u32 of each 8-byte qword:

| qword | byte addr | field |
|---|---|---|
| 0 | `0x3B000000` | `C_SUBMIT` |
| 1 | `0x3B000008` | `C_CMDCOUNT` |
| 2 | `0x3B000010` | `C_TARGET` |
| 3 | `0x3B000018` | `C_CLEAR` |
| 4 | `0x3B000020` | `C_FLAGS` |
| 5 | `0x3B000028` | `C_DONE` |
| 6 | `0x3B000030` | `C_STATUS` |
| 7 | `0x3B000038` | `C_SRCSEL` (bit0 srcsel, bit1 `C_PIPE`, bits[15:8] throttle) |

Ring starts at `0x3B000040`; SRC heap at `0x3B080000`. Definitions:
`maldita.castilla-mister/fpga/rtl/blitter_defs.vh` and the `MF_*` enum in
`gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp:351`.

## Suggested first moves

1. Instrument the host to log the **decoded command stream for submits N-2..N**
   at the known halt points (21 daemon / 33 hand). Identify what is structurally
   new about the Nth.
2. Get a fabric-side view: the core has `SOLARUS_DBG_PROBES` (a
   `probe/fabric-park-state` build exists in the maldita CI history) — bring the
   blitter FSM state out so you can see *where* it parks rather than only that
   `C_DONE` never moves.
3. Bisect the `0/5 → 3-4/4` change since 2026-07-25 if the probes do not
   immediately explain it.
4. Check `fix/arb-owner-fifo` actually landed on `milestone-a` and is in the
   RBF you are testing — prior notes name arb beat mis-steering as the root
   cause of a related park.

## Related durable notes

`~/.claude/projects/-Users-gmcnaught-MisterFPGA-Projects-mister-gmloader/memory/`:
`maldita-fabric-park-diagnosis.md`, `manual-device-testing-needs-handler-off-and-correct-cwd.md`,
`geometry-changes-need-clean-rebuild.md`, `maldita-stale-frame-watchdog-blanks-display.md`,
`on-device-bench-harness-and-baseline.md`, `maldita-gmloader-game-not-progressing.md`.
Full session trail: `mister-gmloader/.superpowers/sdd/progress.md`.

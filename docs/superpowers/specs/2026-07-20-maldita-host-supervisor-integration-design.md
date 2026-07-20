# Maldita Castilla — Host Supervisor & Core-Side Integration Design

**Date:** 2026-07-20
**Status:** Approved (brainstorming)
**Scope:** Four core-side integration-testing features, delivered as one contract + four feature branches.

## Motivation

To make Maldita Castilla / gmloader integration testing reproducible and unattended, the
core needs host-side ownership of the engine process, MiSTer-authoritative input, and an
OSD-driven restart — plus removal of the vestigial single-game "load quest" affordance.
Today the engine is launched by hand (`gmloader_diag.sh --preset fabric`), input comes
straight from SDL's own controller DB (the MiSTer OSD input map is decorative), there is
no automatic teardown on core unload, and an intermittent glibc "corrupted double-linked
list" crash presents as an unobservable freeze rather than a measurable process death.

## The four features

1. **Engine lifecycle tied to core load/exit** — a patched `Main_MiSTer` fork
   (`MiSTer_Maldita`) forks/execs `gmloadernext.armhf`, supervises it, and tears it down on
   core unload.
2. **SDL controller integration (MiSTer-authoritative)** — the wrapper publishes a
   normalized joystick mask into POSIX shared memory; the engine reads it instead of
   SDL's own controller backend, so the OSD `J1`/`jn` map is the single source of truth.
3. **Remove `SC0,SOL,Load Quest`** — dead single-game mount slot, deleted from CONF_STR.
4. **`Restart Quest` → `Reset` + engine restart** — the wrapper takes the OSD T-bit and
   respawns the engine in place (RBF stays loaded).

## Reference implementations surveyed

- **sonic-mania-mister** (`vendor/Main_MiSTer/sonicmania_wrapper.cpp`) — the template for
  the whole approach: `MiSTer.ini` `main=` selects a patched Main_MiSTer fork that
  `fork()`+`execve()`s the engine, supervises it with `waitpid(WNOHANG)` while running the
  MiSTer UI stack in the gap, publishes a `/dev/shm` joy mask (`mister_joy_shm.h`), and
  takes OSD T-bits via `user_io_status_trigger_take()` for Reset/Restart.
- **MiSTer_OpenBOR_7533** — the alternative lifecycle (external `Master_Daemon` +
  `_handler.sh` keyed on `/tmp/CORENAME`) and the DDR-mailbox input path. **Rejected** in
  favour of the sonic-mania approach because three of the four features converge on the
  supervisor.
- **gmloader-next** (`gmloader/input.cpp:227-242`) — already opens SDL2 GameControllers;
  #2's engine-side work replaces that path with the SHM reader.

## Architecture

```
MiSTer.ini  [Maldita Castilla]  main=MiSTer_Maldita
        │
        └─► MiSTer_Maldita  (patched Main_MiSTer fork, vendored in this repo)
                 │  fork() + execve()          ├─ publishes /dev/shm joy mask   (#2)
                 │  PR_SET_PDEATHSIG           ├─ polls OSD T-bit → restart      (#4)
                 ▼  waitpid(WNOHANG) loop      └─ respawn-on-crash + backoff     (#1)
            gmloadernext.armhf  ──DDR ring──►  Maldita RBF (fabric @ 0x3B000000)
```

### New files in this repo

```
vendor/Main_MiSTer/                # vendored upstream, plain directory (NOT a submodule)
vendor/Main_MiSTer.UPSTREAM.md     # pinned upstream commit + re-sync instructions
  maldita_main.cpp                 # replaces upstream main.cpp (affinity, offload, run)
  maldita_wrapper.cpp              # supervisor loop; wires the three units together
  maldita_child.cpp                # fork/exec/signal/reap one engine process
  maldita_joy_shm.cpp              # own the SHM segment; publish the mask
  maldita_osd.cpp                  # take T-bits, set status, drive Reset
  mister_joy_shm.h                 # THE CONTRACT (see below)
tools/mister-wrapper/
  build-hps.sh                     # armhf build, reuses gmloader-next's Docker image
  main-mister-overlay.files        # explicit overlay file list (mirrors sonic-mania's 13)
  Makefile.full.maldita
```

### Deliberate departures from the sonic-mania template

1. **No `Menu_MiSTer` fork.** Sonic-mania's core *is* a Menu_MiSTer fork, so its CONF_STR
   lives in `menu.sv`. Maldita is a standalone core with its own `fpga/Maldita.sv`; the
   CONF_STR stays where it is. Nothing to vendor for the menu.
2. **No `main-mister-full-menu.patch` initially.** That 30-line patch removes the "Core"
   OSD entry so users can't hot-swap cores under the running game. Polish, not
   correctness — deferred to keep the initial diff overlay-files-only and easy to re-sync
   against upstream. Revisit if core-swap-under-game proves to be a real hazard in testing.

### Module boundaries (why the wrapper is split four ways)

Sonic-mania's `sonicmania_wrapper.cpp` is 3000+ lines. To keep units independently
understandable and testable, and so #2/#4 don't contend on one function body:

| Unit               | Responsibility                                  | Depends on                     |
|--------------------|-------------------------------------------------|--------------------------------|
| `maldita_child`    | fork/exec/signal/reap one engine process        | POSIX only                     |
| `maldita_joy_shm`  | own the SHM segment; publish the mask           | `mister_joy_shm.h`, `input.cpp`|
| `maldita_osd`      | take T-bits, set status, drive Reset            | `user_io.cpp`                  |
| `maldita_wrapper`  | the supervisor loop; wires the three together   | all of the above               |

`maldita_child` and `maldita_joy_shm` have **no MiSTer dependency** and are unit-testable
host-native on a dev Mac.

## The contract (`mister_joy_shm.h`)

Lands on `milestone-a` as a single small prep commit **before** any feature branch, so all
four branches can be written in parallel against it.

```c
#define MALDITA_JOY_SHM_PATH    "/dev/shm/maldita-joy"
#define MALDITA_JOY_SHM_MAGIC   0x4D414C44u   /* "MALD" */
#define MALDITA_JOY_SHM_VERSION 1u
#define MALDITA_JOY_MAX_PLAYERS 2

typedef struct {
    uint32_t magic;        /* MALDITA_JOY_SHM_MAGIC once initialised */
    uint32_t version;      /* MALDITA_JOY_SHM_VERSION */
    uint32_t generation;   /* ++ on each engine respawn; engine may ignore */
    uint32_t joy_mask[MALDITA_JOY_MAX_PLAYERS];
} MalditaJoyShm;
```

- Path is passed to the engine via env var `GMLOADER_JOY_SHM` (never hardcoded engine-side;
  clean fallback when unset).
- **Concurrency:** each `joy_mask[i]` is a naturally-aligned `uint32_t` → single-word
  reads/writes are atomic on ARMv7. No lock/seqlock. `magic`/`version` written once at
  setup, before the engine is spawned. `generation` bumps on each respawn.
- **Reset is deliberately NOT in the contract.** #4 is consumed entirely inside the
  wrapper (take T-bit → SIGTERM child → respawn); from the engine's side a restart is
  indistinguishable from a crash-respawn. Contract stays input-only.

### Button bit layout (CONF_STR `J1,Sword,Action,Item 1,Item 2,Pause` / `jn,A,B,X,Y,Start`)

| bit  | meaning                    |
|------|----------------------------|
| 0–3  | right, left, down, up      |
| 4    | Sword                      |
| 5    | Action                     |
| 6    | Item 1                     |
| 7    | Item 2                     |
| 8    | Pause                      |

**UNVERIFIED — must be confirmed on hardware.** Derived from OpenBOR's
`control_patch.c:41-74`, whose comments describe a *post-`jn`-remap* layout that differs
from Maldita's `jn` line. First-run verification (see Testing) logs the raw mask and
presses each button to confirm/correct this table. The `version` field exists so a layout
correction is a versioned change.

## Crash policy (#1)

**Respawn in place with bounded retry, then halt-and-preserve.**

- Engine exits non-zero → log `exit_code` + `crash_count`, respawn with backoff, RBF stays
  loaded (soak tests survive the intermittent double-linked-list crash; yields a crash-rate
  metric).
- 3 crashes inside a short window → **give up**: halt (engine stays dead), leave the RBF
  loaded so the fabric registers at `0x3B000000` remain peekable via `devmem` for
  post-mortem (`C_SUBMIT`/`C_DONE` at the moment of death). RBF-stays-loaded is what lets a
  host-side crash be distinguished from a fabric wedge — the distinction the existing crash
  memory says is currently hard to make.
- Engine exits cleanly / core unloads → normal teardown (SIGTERM child, return to menu).
- `PR_SET_PDEATHSIG(SIGTERM)` ensures the engine dies if the wrapper dies abruptly.

## Branch plan & sequencing

| #  | Branch                    | Repo                  | Touches                                                        |
|----|---------------------------|-----------------------|---------------------------------------------------------------|
| 0  | *(direct on milestone-a)* | this                  | `mister_joy_shm.h` only — the contract                        |
| 3  | `feat/drop-sol-mount`     | this                  | `fpga/Maldita.sv`                                             |
| 1  | `feat/wrapper-lifecycle`  | this                  | `vendor/**`, `tools/mister-wrapper/**`, `maldita_child/wrapper` |
| 2  | `feat/sdl-input`          | this **+** gmloader-next | `maldita_joy_shm.cpp` here; `gmloader/input.cpp` there     |
| 4  | `feat/osd-reset`          | this                  | `fpga/Maldita.sv`, `maldita_osd.cpp`                          |

**Sequence:** contract (#0) → **#3 immediately** (independent, 3-line deletion) → **#1**
(longest pole: vendoring + armhf pipeline) → **#2 and #4 in parallel off #1**.

### Conflict surface (named up front)

- **(a) #3 and #4 both edit the CONF_STR block** (`fpga/Maldita.sv:269-284`): #3 deletes
  the `SC0,SOL` line; #4 rewrites the `TJ,Restart Quest` line. Adjacent lines in one
  `localparam`. Mitigation: land #3 first, branch #4 off the result.
- **(b) The supervisor loop is the shared spine.** #1 lands the loop with both downstream
  hooks already present and **inert**:

  ```c
  maldita_joy_publish(child_pid);        /* no-op until #2 */
  maldita_osd_poll(child_pid, &restart); /* no-op until #4 */
  ```

  Then #2 and #4 each implement one file and change nothing in the loop — making the
  worktree isolation real rather than nominal.

### Dependencies (honest)

- **#3** — fully independent, can land today.
- **#2 engine-side** (gmloader-next) — independent, can start immediately against the
  contract; already a separate checkout.
- **#2 publisher half** and **#4** — need #1's scaffolding to *compile*, not to be
  *written*. True critical path is #1. The contract shrinks what's blocked to "the final
  compile", not "the design and the code".

## Existing plumbing this obsoletes

`fpga/Maldita.sv:942` `osd_restart = status[19] // mirrored to ARM` and the
`blitter_top.sv` `S_WR_STATUS` → `C_STATUS` low32 mirror were built to carry the Restart
trigger to the ARM side over the fabric control block. With the wrapper in place, the T-bit
is taken directly via `user_io_status_trigger_take()` — earlier and more reliably than the
fabric round-trip. **#4 should treat the `status[19]` mirror as dead plumbing for Reset**
and may remove it. Note `status[20]` (FPS overlay) may still want the mirror — verify
before deleting the whole `S_WR_STATUS` path.

## Testing & verification

### Host-native unit tests (dev Mac, no MiSTer) — new `maldita-wrapper-test` target

- `maldita_child` — stub child (`/bin/sleep`, crash-on-exit stub): reap detected, SIGTERM
  forwarded, `PR_SET_PDEATHSIG` set, crash-count increments, backoff fires,
  give-up-after-N halts. The crash-policy logic is proven here without hardware.
- `maldita_joy_shm` — create segment, write masks, `mmap` from a second process, assert
  magic/version/round-trip. Proves the contract independent of `input.cpp`.

### On-device gates

1. **#3** — OSD no longer shows "Load Quest"; game still boots.
2. **#1** — `main=MiSTer_Maldita`, load core → engine auto-launches (no manual
   `gmloader_diag.sh`); unload → engine dies (no orphan `gmloadernext` via `ps`). Kill
   engine → respawn + `crash_count` in log; kill 3× fast → halt.
3. **#2** — **bit-map verification**: log raw `joy_mask`, press each button, confirm/correct
   the layout table. Then in-game input works; opening the OSD zeroes input (no leak).
4. **#4** — OSD "Reset" → engine restarts (fresh process, RBF stays loaded, `generation`
   increments), game returns to start state.

### Soak test (the payoff)

With #1's respawn policy live, run overnight; read `crash_count` / mean-time-between-crashes
from the wrapper log — turning the known intermittent double-linked-list crash from an
anecdote into a measured rate. This metric is the concrete deliverable justifying the
supervisor.

## Risks

- **Button bit layout is unverified** (see contract) — first-run hardware step corrects it;
  `version` field absorbs the change.
- **#1 carries build-infrastructure risk** the other three don't: `MiSTer_Maldita` must
  build armhf. Mitigated by reusing gmloader-next's existing Docker cross-build pattern
  (`Dockerfile.gmloader-build`). If it slips, #2/#4's *final integration* slips with it, but
  their code — written against the contract — does not.
- **Contract churn** would break the parallel-branch premise. Kept minimal (magic + version
  + generation + 2× mask) specifically to avoid this.

## Out of scope

- FPGA audio / joystick-framework integration (deferred per existing project memory).
- `main-mister-full-menu.patch` (core-swap lockout) — deferred polish.
- Analog stick passthrough — the contract carries digital masks only.
- Any change to the fabric rasterizer / rendering path.

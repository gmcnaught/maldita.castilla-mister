# Feature 0 — Joy-SHM Contract Header Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the `mister_joy_shm.h` shared-memory contract on `milestone-a` as a single small commit, so the four feature branches can be written in parallel against a frozen interface.

**Architecture:** A header-only C struct + constants defining the `/dev/shm/maldita-joy` segment. No behaviour, no build wiring — this file exists to be `#include`d by the wrapper (producer, feat #1/#2) and the engine reader (consumer, feat #2). It commits to `milestone-a` directly, NOT a feature branch, because every branch depends on it.

**Tech Stack:** C header, POSIX shared memory conventions.

## Global Constraints

- Magic value `0x4D414C44u` (`"MALD"`), version `1`, path `/dev/shm/maldita-joy`, env var `GMLOADER_JOY_SHM`.
- 2 players max (`MALDITA_JOY_MAX_PLAYERS = 2`).
- `joy_mask[i]` must be a naturally-aligned `uint32_t` (atomic single-word access on ARMv7; no lock).
- This commit lands on branch `milestone-a` directly. Do NOT create a feature branch.
- Spec: `docs/superpowers/specs/2026-07-20-maldita-host-supervisor-integration-design.md` § "The contract".

---

### Task 1: Create the contract header

**Files:**
- Create: `vendor/Main_MiSTer/mister_joy_shm.h`

**Interfaces:**
- Consumes: nothing.
- Produces: `MalditaJoyShm` struct (fields `magic`, `version`, `generation`, `joy_mask[2]`), and macros `MALDITA_JOY_SHM_PATH`, `MALDITA_JOY_SHM_MAGIC`, `MALDITA_JOY_SHM_VERSION`, `MALDITA_JOY_MAX_PLAYERS`. Every other feature branch `#include`s this file.

- [ ] **Step 1: Write the header**

Create `vendor/Main_MiSTer/mister_joy_shm.h` with exactly this content:

```c
#ifndef MISTER_JOY_SHM_H
#define MISTER_JOY_SHM_H

/*
 * Maldita Castilla MiSTer — host↔engine joystick shared-memory contract.
 *
 * The MiSTer_Maldita wrapper (producer) publishes a normalized per-player
 * button mask here each frame; gmloadernext (consumer) mmaps it read-only and
 * translates it into yoyo_gamepads[] button state. See spec
 * docs/superpowers/specs/2026-07-20-maldita-host-supervisor-integration-design.md.
 *
 * Bit layout of joy_mask[i] (MiSTer standard digital joystick order, then the
 * CONF_STR J1 buttons "Sword,Action,Item 1,Item 2,Pause"):
 *   bit0=right bit1=left bit2=down bit3=up
 *   bit4=Sword bit5=Action bit6=Item1 bit7=Item2 bit8=Pause
 * NOTE: the mapping from these bits onto the engine's gamepad button indices
 * is verified on hardware (feat #2), not assumed.
 */

#include <stdint.h>

#define MALDITA_JOY_SHM_PATH    "/dev/shm/maldita-joy"
#define MALDITA_JOY_SHM_MAGIC   0x4D414C44u   /* "MALD" */
#define MALDITA_JOY_SHM_VERSION 1u
#define MALDITA_JOY_MAX_PLAYERS 2

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MalditaJoyShm {
    uint32_t magic;                            /* MALDITA_JOY_SHM_MAGIC once initialised */
    uint32_t version;                          /* MALDITA_JOY_SHM_VERSION */
    uint32_t generation;                       /* ++ on each engine respawn; consumer may ignore */
    uint32_t joy_mask[MALDITA_JOY_MAX_PLAYERS];/* naturally-aligned; atomic single-word access */
} MalditaJoyShm;

#ifdef __cplusplus
}
#endif

#endif /* MISTER_JOY_SHM_H */
```

- [ ] **Step 2: Verify it compiles standalone as both C and C++**

Run:
```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
printf '#include "vendor/Main_MiSTer/mister_joy_shm.h"\nint main(void){MalditaJoyShm s; s.magic=MALDITA_JOY_SHM_MAGIC; s.joy_mask[MALDITA_JOY_MAX_PLAYERS-1]=0; return (int)s.joy_mask[0];}\n' > /tmp/jc.c
cc  -std=c11   -Wall -Wextra -c /tmp/jc.c -o /tmp/jc.o  && echo "C OK"
c++ -std=c++14 -Wall -Wextra -x c++ -c /tmp/jc.c -o /tmp/jcpp.o && echo "C++ OK"
```
Expected: both print `OK`, no warnings.

- [ ] **Step 3: Assert struct layout is what the contract promises**

Run:
```bash
printf '#include "vendor/Main_MiSTer/mister_joy_shm.h"\n#include <stddef.h>\n_Static_assert(sizeof(MalditaJoyShm)==20,"size");\n_Static_assert(offsetof(MalditaJoyShm,joy_mask)==12,"joy_off");\n_Static_assert(offsetof(MalditaJoyShm,joy_mask[0])%%4==0,"align");\nint main(void){return 0;}\n' > /tmp/jl.c
cc -std=c11 -c /tmp/jl.c -o /tmp/jl.o && echo "LAYOUT OK"
```
Expected: `LAYOUT OK` (5 × uint32 = 20 bytes; joy_mask at offset 12; 4-byte aligned).

- [ ] **Step 4: Commit on milestone-a**

```bash
git add vendor/Main_MiSTer/mister_joy_shm.h
git commit -m "feat: joy-shm host<->engine contract header (milestone-a)

Freezes the /dev/shm/maldita-joy struct so feat #1/#2/#4 branches build
against a stable interface. Header-only, no behaviour."
```

Confirm you are on `milestone-a` before committing: `git branch --show-current` must print `milestone-a`.

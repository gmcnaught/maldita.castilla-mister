# Feature 2 — MiSTer-Authoritative Input via `/dev/shm` Mask Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the MiSTer OSD the single authoritative input source. The wrapper publishes a normalized per-player button mask into `/dev/shm/maldita-joy`; the engine reads it and drives `yoyo_gamepads[]` from it, instead of SDL's own controller backend.

**Architecture:** Two halves against feat #0's frozen contract. **Producer half (this repo):** fill the inert `maldita_joy_shm.cpp` stub with the real open/mmap/publish, and overlay a patched `input.cpp` that exposes `input_get_joy_mask`/`input_set_joy_passthrough` (these are sonic-mania additions, not stock upstream). **Consumer half (gmloader-next):** a new `joy_shm_reader.cpp` that mmaps the segment read-only and translates the mask into `yoyo_gamepads[slot].buttons[]` edge-states, wired into `update_inputs()` while keeping the `SDL_PollEvent` pump alive. The mask-bit → gamepad-button mapping table is verified on hardware.

**Tech Stack:** C++14 (wrapper), C++17 host tests, SDL2 (engine, evdev backend stays present), POSIX `mmap`.

## Global Constraints

- Branch/worktree (this repo): `feat/sdl-input` off `milestone-a` — but its producer half only *compiles* once feat #1's scaffolding (`maldita_joy_shm.{h,cpp}` stubs, overlay manifest, build driver) is on the branch. Rebase `feat/sdl-input` onto feat #1's tip before Task 3, or branch it from feat #1. The engine half (gmloader-next) is independent and can start immediately.
- gmloader-next branch: `feat/sdl-input` (same name, sibling repo `../gmloader-next`).
- Contract is frozen: `MalditaJoyShm { magic, version, generation, joy_mask[2] }`, path `/dev/shm/maldita-joy`, env `GMLOADER_JOY_SHM`, magic `0x4D414C44`, version `1`. Do NOT change `mister_joy_shm.h`.
- Keep the `SDL_PollEvent` pump in `update_inputs()` (`gmloader/input.cpp:206-290`) — it drives `SDL_QUIT`, keyboard, window focus, hotplug. Only REPLACE the SDL-button-fill (`:292-362`).
- Engine consumes edge-states: `yoyo_gamepads[slot].buttons[j]` is a `double` holding `GAMEPAD_BUTTON_STATE_*` (-1/0/1/2), indexed by SDL controller-button position (0=A,1=B,2=X,3=Y,4=LS,5=RS,6=LT,7=RT,8=Back,9=Start,10=LStick,11=RStick,12=DpadUp,13=DpadDown,14=DpadLeft,15=DpadRight). The reader writes RAW held/neutral, then reuses the existing `update_button()` edge machine (`gmloader/input.cpp:74-85`).
- New mister source goes under `gmloader/mister/` and is added to `MISTER_SRCS` (`../gmloader-next/Makefile.gmloader:103`), gated by `MISTER_BUILD=1`/`MISTER_NATIVE_VIDEO`.
- armhf build: `docker run --rm -v "$(pwd):/src" -w /src gmloader-armhf-build:bullseye make -f Makefile.gmloader ARCH=arm-linux-gnueabihf MISTER_BUILD=1 MISTER_NATIVE_VIDEO=1 -j"$(nproc)"` → `build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf`.
- Homebrew tools for agents: `export PATH="/opt/homebrew/bin:$PATH"`.
- Spec: `docs/superpowers/specs/2026-07-20-maldita-host-supervisor-integration-design.md` § feature 2 + "Button bit layout".

---

## Part A — Producer half (this repo, `feat/sdl-input` on top of feat #1)

### Task 1: Fill the joy-shm publisher (host-native TDD)

**Files:**
- Modify: `vendor/Main_MiSTer/maldita_joy_shm.cpp` (replace the inert stub body)
- Create: `tools/mister-wrapper/test/maldita_joy_shm_test.cpp`

**Interfaces:**
- Consumes: `mister_joy_shm.h` (feat #0); MiSTer symbols `input_get_joy_mask(uint32_t*, int)` and `input_set_joy_passthrough(int)` (provided by the overlay in Task 2, stubbed in the host test).
- Produces: real bodies for `maldita_joy_open`, `maldita_joy_publish`, `maldita_joy_bump_generation`, `maldita_joy_close` (signatures frozen by feat #1's `maldita_joy_shm.h`). No change to the supervisor loop.

- [ ] **Step 1: Create the worktree on top of feat #1**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git worktree add -b feat/sdl-input ../maldita-feat2-input feat/wrapper-lifecycle
cd ../maldita-feat2-input
test -f vendor/Main_MiSTer/maldita_joy_shm.cpp && echo "scaffolding present" || echo "MISSING — land feat #1 first"
```
Expected: `scaffolding present`.

- [ ] **Step 2: Write the failing publisher test**

Create `tools/mister-wrapper/test/maldita_joy_shm_test.cpp`:
```c
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include "mister_joy_shm.h"
#include "maldita_joy_shm.h"

// --- stubs standing in for MiSTer input.cpp symbols (real ones added in Task 2) ---
static uint32_t g_test_mask[MALDITA_JOY_MAX_PLAYERS] = {0};
extern "C" void input_get_joy_mask(uint32_t *masks, int n) {
    for (int i = 0; i < n; i++) masks[i] = g_test_mask[i];
}
extern "C" void input_set_joy_passthrough(int) { }

static int fails = 0;
#define CHECK(c) do { if(!(c)){printf("FAIL %s (line %d)\n",#c,__LINE__);fails++;} } while(0)

static MalditaJoyShm *map_ro(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    MalditaJoyShm *p = (MalditaJoyShm*)mmap(NULL, sizeof(MalditaJoyShm), PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    return (p == MAP_FAILED) ? NULL : p;
}

int main(void) {
    char path[] = "/tmp/maldita-joy-test";
    setenv("MALDITA_JOY_SHM_PATH", path, 1);   // test path override
    unlink(path);

    CHECK(maldita_joy_open() == true);
    MalditaJoyShm *ro = map_ro(path);
    CHECK(ro != NULL);
    CHECK(ro->magic == MALDITA_JOY_SHM_MAGIC);
    CHECK(ro->version == MALDITA_JOY_SHM_VERSION);

    // Publish a known mask when OSD is not visible → mirrored to SHM.
    g_test_mask[0] = 0x110; g_test_mask[1] = 0x0;   // Pause(0x100)|Action(0x20)? just a bit pattern
    maldita_joy_publish(0);
    CHECK(ro->joy_mask[0] == 0x110);

    // OSD visible → masks zeroed (no input leak into the game).
    maldita_joy_publish(1);
    CHECK(ro->joy_mask[0] == 0x0);

    // Generation bumps on respawn.
    uint32_t g0 = ro->generation;
    maldita_joy_bump_generation();
    CHECK(ro->generation == g0 + 1);

    // Env var was exported for the engine.
    CHECK(getenv("GMLOADER_JOY_SHM") != NULL);

    maldita_joy_close();
    if (fails) { printf("%d checks FAILED\n", fails); return 1; }
    printf("maldita_joy_shm publisher OK\n");
    return 0;
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/maldita-feat2-input
c++ -std=c++17 -Ivendor/Main_MiSTer tools/mister-wrapper/test/maldita_joy_shm_test.cpp vendor/Main_MiSTer/maldita_joy_shm.cpp -o /tmp/mjt && /tmp/mjt
```
Expected: FAIL (the inert stub returns `false` from `maldita_joy_open`, so the first CHECK fails).

- [ ] **Step 4: Replace the stub with the real publisher**

Overwrite `vendor/Main_MiSTer/maldita_joy_shm.cpp`:
```c
#include "maldita_joy_shm.h"
#include "mister_joy_shm.h"

#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

/* MiSTer input.cpp API (added by the overlay in Task 2). */
extern "C" void input_get_joy_mask(uint32_t *masks, int n);
extern "C" void input_set_joy_passthrough(int on);

static MalditaJoyShm *g_shm = 0;

static const char *shm_path(void) {
    const char *o = getenv("MALDITA_JOY_SHM_PATH");   /* test-only override */
    return (o && *o) ? o : MALDITA_JOY_SHM_PATH;
}

bool maldita_joy_open(void) {
    const char *path = shm_path();
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return false;
    bool ok = (ftruncate(fd, sizeof(MalditaJoyShm)) == 0);
    if (ok) {
        g_shm = (MalditaJoyShm*)mmap(0, sizeof(MalditaJoyShm),
                                     PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (g_shm == MAP_FAILED) { g_shm = 0; ok = false; }
    }
    close(fd);
    if (!ok) return false;

    g_shm->magic      = MALDITA_JOY_SHM_MAGIC;
    g_shm->version    = MALDITA_JOY_SHM_VERSION;
    g_shm->generation = 0;
    memset(g_shm->joy_mask, 0, sizeof(g_shm->joy_mask));

    setenv("GMLOADER_JOY_SHM", path, 1);
    input_set_joy_passthrough(1);   /* export the MiSTer-normalized mask */
    return true;
}

void maldita_joy_publish(int osd_visible) {
    if (!g_shm) return;
    uint32_t masks[MALDITA_JOY_MAX_PLAYERS];
    if (osd_visible) {
        memset(masks, 0, sizeof(masks));         /* no input leak while OSD is up */
    } else {
        input_get_joy_mask(masks, MALDITA_JOY_MAX_PLAYERS);
    }
    for (int i = 0; i < MALDITA_JOY_MAX_PLAYERS; i++)
        g_shm->joy_mask[i] = masks[i];           /* single-word atomic store */
}

void maldita_joy_bump_generation(void) { if (g_shm) g_shm->generation++; }

void maldita_joy_close(void) {
    if (g_shm) { munmap(g_shm, sizeof(MalditaJoyShm)); g_shm = 0; }
}
```

- [ ] **Step 5: Run the test to verify it passes**

```bash
c++ -std=c++17 -Ivendor/Main_MiSTer tools/mister-wrapper/test/maldita_joy_shm_test.cpp vendor/Main_MiSTer/maldita_joy_shm.cpp -o /tmp/mjt && /tmp/mjt
```
Expected: `maldita_joy_shm publisher OK`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add vendor/Main_MiSTer/maldita_joy_shm.cpp tools/mister-wrapper/test/maldita_joy_shm_test.cpp
git commit -m "feat: real /dev/shm joy publisher + host round-trip test"
```

### Task 2: Overlay `input.cpp` additions (`input_get_joy_mask` + passthrough)

**Files:**
- Create: `vendor/Main_MiSTer/input.cpp` (overlay of upstream input.cpp + the two additions)
- Create: `vendor/Main_MiSTer/input.h` (overlay declaring the two functions)
- Modify: `tools/mister-wrapper/main-mister-overlay.files` (add `input.cpp`, `input.h`)

**Interfaces:**
- Consumes: upstream input.cpp internals (`joy_mask[]`, `autofire_mask[]`).
- Produces: `void input_get_joy_mask(uint32_t*, int)` and `void input_set_joy_passthrough(int)` for the publisher (Task 1) to link against at armhf build time.

- [ ] **Step 1: Vendor the upstream input.cpp/input.h at the pinned commit**

The overlay must start from the exact upstream file so only the additions differ. Fetch them from the prepared source tree (feat #1's `build-hps.sh --prepare-source` populates `build/mister-wrapper-hps/src/`):
```bash
tools/mister-wrapper/build-hps.sh --prepare-source
cp build/mister-wrapper-hps/src/input.cpp vendor/Main_MiSTer/input.cpp
cp build/mister-wrapper-hps/src/input.h   vendor/Main_MiSTer/input.h
```
(These are the pinned-commit originals before overlay. We now edit our copies to add the two functions, and adding them to the manifest makes them win over the fetched originals.)

- [ ] **Step 2: Port the two additions from sonic-mania**

Reference: `/Users/gmcnaught/MisterFPGA-Projects/sonic-mania-mister/vendor/Main_MiSTer/input.cpp`. Port exactly these additions (search that file for the identifiers):
1. The file-static export buffer + passthrough flag and the `input_joy_passthrough` branch in the poll that fills `joy_mask_export[i] = joy_mask[i] | autofire_mask[i]` (sonic-mania `input.cpp:6025-6038`).
2. `void input_set_joy_passthrough(int on)` (sonic-mania `input.cpp:6596`).
3. `void input_get_joy_mask(uint32_t *masks, int n)` returning `joy_mask_export[]` (sonic-mania `input.cpp:6584`).

Add matching declarations to `vendor/Main_MiSTer/input.h`:
```c
void input_set_joy_passthrough(int on);
void input_get_joy_mask(uint32_t *masks, int n);
```
Do NOT port sonic-mania's OSD-zeroing entanglement beyond what's needed — the publisher already zeroes on `osd_visible` (Task 1), so you only need the passthrough export path, not sonic-mania's SHM-side gate.

- [ ] **Step 3: Add input.cpp/input.h to the overlay manifest**

Append to `tools/mister-wrapper/main-mister-overlay.files`:
```
input.cpp
input.h
```

- [ ] **Step 4: Cross-compile the wrapper to prove the symbols resolve**

```bash
export PATH="/opt/homebrew/bin:$PATH"
tools/mister-wrapper/build-hps.sh
file build/mister-wrapper-hps/MiSTer_Maldita
```
Expected: `ELF ... ARM`. The link now resolves `input_get_joy_mask`/`input_set_joy_passthrough` from the overlaid input.cpp; the real `maldita_joy_publish` compiles into the binary. Fix any port mismatch (e.g. `joy_mask` array arity) by matching the upstream field names.

- [ ] **Step 5: Commit**

```bash
git add vendor/Main_MiSTer/input.cpp vendor/Main_MiSTer/input.h tools/mister-wrapper/main-mister-overlay.files
git commit -m "feat: overlay input.cpp — export MiSTer joy mask for the publisher"
```

---

## Part B — Consumer half (`../gmloader-next`, branch `feat/sdl-input`)

### Task 3: Joy-shm reader + mask→button mapping (host-native TDD)

**Files:**
- Create: `../gmloader-next/gmloader/mister/joy_shm_reader.h`
- Create: `../gmloader-next/gmloader/mister/joy_shm_reader.cpp`
- Create: `../gmloader-next/gmloader/mister/joy_shm_reader_test.cpp`
- Modify: `../gmloader-next/Makefile.gmloader` (add `MISTER_SRCS` entry + `joy-shm-test` target)

**Interfaces:**
- Consumes: the contract struct. Copy `mister_joy_shm.h` into gmloader-next OR reference it — see Step 1.
- Produces:
  - `bool JoyShm_Init(void)` — read `GMLOADER_JOY_SHM`, mmap RO, validate magic/version. `false` if unset/invalid.
  - `bool JoyShm_IsActive(void)`
  - `uint32_t JoyShm_ReadMask(int player)` — 0 if inactive/out-of-range
  - `void JoyShm_MaskToButtons(uint32_t mask, unsigned char raw16[16])` — **the hardware-verified mapping table** (pure)
  - `void JoyShm_Shutdown(void)`

- [ ] **Step 1: Create the gmloader-next worktree and bring in the contract header**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
git worktree add -b feat/sdl-input ../gmloader-next-feat2-input HEAD
cd ../gmloader-next-feat2-input
# Copy the frozen contract header into the engine tree (single source of truth is
# feat #0; this is a vendored copy — keep the struct byte-identical).
cp /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister/vendor/Main_MiSTer/mister_joy_shm.h gmloader/mister/mister_joy_shm.h
```

- [ ] **Step 2: Write the failing reader test**

Create `gmloader/mister/joy_shm_reader_test.cpp`:
```c
#include <stdio.h>
#include "joy_shm_reader.h"

static int fails = 0;
#define CHECK(c) do { if(!(c)){printf("FAIL %s (line %d)\n",#c,__LINE__);fails++;} } while(0)

int main(void) {
    unsigned char b[16];

    // Directions (MiSTer bits 0..3) map to SDL DPAD slots 15/14/13/12.
    JoyShm_MaskToButtons(1u<<0, b); CHECK(b[15]==1);   // right → DPAD_RIGHT
    JoyShm_MaskToButtons(1u<<1, b); CHECK(b[14]==1);   // left  → DPAD_LEFT
    JoyShm_MaskToButtons(1u<<2, b); CHECK(b[13]==1);   // down  → DPAD_DOWN
    JoyShm_MaskToButtons(1u<<3, b); CHECK(b[12]==1);   // up    → DPAD_UP

    // Buttons (MiSTer bits 4..8) map to SDL face/Start slots.
    JoyShm_MaskToButtons(1u<<4, b); CHECK(b[0]==1);    // Sword  → A
    JoyShm_MaskToButtons(1u<<5, b); CHECK(b[1]==1);    // Action → B
    JoyShm_MaskToButtons(1u<<6, b); CHECK(b[2]==1);    // Item1  → X
    JoyShm_MaskToButtons(1u<<7, b); CHECK(b[3]==1);    // Item2  → Y
    JoyShm_MaskToButtons(1u<<8, b); CHECK(b[9]==1);    // Pause  → Start

    // Unpressed bits stay 0.
    JoyShm_MaskToButtons(1u<<4, b); CHECK(b[1]==0 && b[15]==0);

    if (fails) { printf("%d checks FAILED\n", fails); return 1; }
    printf("joy_shm_reader mapping OK\n");
    return 0;
}
```

- [ ] **Step 3: Write the reader header + implementation**

Create `gmloader/mister/joy_shm_reader.h`:
```c
#ifndef JOY_SHM_READER_H
#define JOY_SHM_READER_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
bool     JoyShm_Init(void);
bool     JoyShm_IsActive(void);
uint32_t JoyShm_ReadMask(int player);
void     JoyShm_MaskToButtons(uint32_t mask, unsigned char raw16[16]);
void     JoyShm_Shutdown(void);
#ifdef __cplusplus
}
#endif
#endif
```
Create `gmloader/mister/joy_shm_reader.cpp`:
```c
#include "joy_shm_reader.h"
#include "mister_joy_shm.h"

#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

static const MalditaJoyShm *g_shm = 0;

/* Hardware-verified mapping: MiSTer joy_mask bit -> SDL controller button slot.
 * SDL slot order: 0=A 1=B 2=X 3=Y 4=LS 5=RS 6=LT 7=RT 8=Back 9=Start
 *                 10=LStick 11=RStick 12=DpadUp 13=DpadDown 14=DpadLeft 15=DpadRight */
void JoyShm_MaskToButtons(uint32_t mask, unsigned char raw16[16]) {
    memset(raw16, 0, 16);
    raw16[15] = (mask >> 0) & 1u;  /* right  -> DPAD_RIGHT */
    raw16[14] = (mask >> 1) & 1u;  /* left   -> DPAD_LEFT  */
    raw16[13] = (mask >> 2) & 1u;  /* down   -> DPAD_DOWN  */
    raw16[12] = (mask >> 3) & 1u;  /* up     -> DPAD_UP    */
    raw16[0]  = (mask >> 4) & 1u;  /* Sword  -> A          */
    raw16[1]  = (mask >> 5) & 1u;  /* Action -> B          */
    raw16[2]  = (mask >> 6) & 1u;  /* Item1  -> X          */
    raw16[3]  = (mask >> 7) & 1u;  /* Item2  -> Y          */
    raw16[9]  = (mask >> 8) & 1u;  /* Pause  -> Start      */
}

bool JoyShm_Init(void) {
    const char *path = getenv("GMLOADER_JOY_SHM");
    if (!path || !*path) return false;
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    const MalditaJoyShm *p = (const MalditaJoyShm*)mmap(0, sizeof(MalditaJoyShm),
                                                        PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return false;
    if (p->magic != MALDITA_JOY_SHM_MAGIC || p->version != MALDITA_JOY_SHM_VERSION) {
        munmap((void*)p, sizeof(MalditaJoyShm));
        return false;
    }
    g_shm = p;
    return true;
}

bool JoyShm_IsActive(void) { return g_shm != 0; }

uint32_t JoyShm_ReadMask(int player) {
    if (!g_shm || player < 0 || player >= MALDITA_JOY_MAX_PLAYERS) return 0;
    return g_shm->joy_mask[player];   /* single-word atomic load */
}

void JoyShm_Shutdown(void) {
    if (g_shm) { munmap((void*)g_shm, sizeof(MalditaJoyShm)); g_shm = 0; }
}
```

- [ ] **Step 4: Add the host-test target and run it (fails first, then passes)**

Add to `../gmloader-next-feat2-input/Makefile.gmloader` after the `blitter-appsurf-test` target:
```make
.PHONY: joy-shm-test
joy-shm-test:
	c++ -std=c++17 -DMISTER_NATIVE_VIDEO=1 -Igmloader/mister -Igmloader -I. \
	  gmloader/mister/joy_shm_reader_test.cpp \
	  gmloader/mister/joy_shm_reader.cpp \
	  -lm -o /tmp/jst && /tmp/jst
```
Run before writing impl to see RED (temporarily rename the .cpp to force the failure, or trust Step 2/3 ordering); then:
```bash
export PATH="/opt/homebrew/bin:$PATH"
make -f Makefile.gmloader joy-shm-test
```
Expected: `joy_shm_reader mapping OK`, exit 0.

- [ ] **Step 5: Register the source for the armhf build**

In `../gmloader-next-feat2-input/Makefile.gmloader:103`, append `gmloader/mister/joy_shm_reader.cpp` to the `MISTER_SRCS` list:
```make
MISTER_SRCS = gmloader/mister/native_video_writer.c gmloader/mister/frame_capture.cpp gmloader/mister/draw_trace.cpp gmloader/mister/blitter.cpp gmloader/mister/blitter_raster.cpp gmloader/mister/raster_backend_sw.cpp gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/joy_shm_reader.cpp
```

- [ ] **Step 6: Commit**

```bash
git add gmloader/mister/joy_shm_reader.h gmloader/mister/joy_shm_reader.cpp gmloader/mister/joy_shm_reader_test.cpp gmloader/mister/mister_joy_shm.h Makefile.gmloader
git commit -m "feat: joy_shm_reader — mmap /dev/shm mask + mask->button mapping + test"
```

### Task 4: Wire the reader into `update_inputs()`

**Files:**
- Modify: `../gmloader-next-feat2-input/gmloader/input.cpp` (init the reader; replace the SDL button-fill when active; keep the SDL_PollEvent pump)

**Interfaces:**
- Consumes: `JoyShm_Init/IsActive/ReadMask/MaskToButtons` (Task 3), `update_button()` (`input.cpp:74`), `yoyo_gamepads[]` (`gamepad.cpp:10`).
- Produces: engine input driven by the MiSTer mask when `GMLOADER_JOY_SHM` is set; unchanged SDL behaviour otherwise.

- [ ] **Step 1: Initialise the reader once**

Near the top of `update_inputs()` (or in the engine init that runs before the main loop, `gmloader/main.cpp` before the `while` at `:563`), add a one-time init. Simplest: a file-static guard in `input.cpp`:
```c
#ifdef MISTER_NATIVE_VIDEO
#include "mister/joy_shm_reader.h"
static int g_joyshm_ready = -1;   // -1 = untried, 0 = inactive, 1 = active
#endif
```

- [ ] **Step 2: Replace the SDL button-fill when the mask is active**

Wrap the SDL button-fill block (`gmloader/input.cpp:292-362`, the `for (i ... sdl_controllers ...)` loop) so that when the joy-shm mask is active it drives player 0 from the mask instead. Insert BEFORE that loop:
```c
#ifdef MISTER_NATIVE_VIDEO
    if (g_joyshm_ready == -1) g_joyshm_ready = JoyShm_Init() ? 1 : 0;
    if (g_joyshm_ready == 1) {
        for (int p = 0; p < MALDITA_JOY_MAX_PLAYERS; p++) {
            uint32_t mask = JoyShm_ReadMask(p);
            unsigned char raw[16];
            JoyShm_MaskToButtons(mask, raw);
            yoyo_gamepads[p].is_available = 1;
            for (int j = 0; j < 16; j++)
                yoyo_gamepads[p].buttons[j] =
                    (double)update_button(raw[j], (int)yoyo_gamepads[p].buttons[j]);
            for (int a = 0; a < 4; a++) yoyo_gamepads[p].axis[a] = 0.0;
        }
    } else
#endif
    {
        // ... existing SDL button-fill loop (unchanged) ...
    }
```
Leave the `SDL_PollEvent` pump (`:206-290`) and its `SDL_QUIT`/keyboard handling completely intact — it runs every frame regardless of the branch above. `MALDITA_JOY_MAX_PLAYERS` comes from `mister/mister_joy_shm.h`; add `#include "mister/mister_joy_shm.h"` under the existing MiSTer include.

- [ ] **Step 3: Build armhf and confirm it compiles**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next-feat2-input
export PATH="/opt/homebrew/bin:$PATH"
docker run --rm -v "$(pwd):/src" -w /src gmloader-armhf-build:bullseye \
  make -f Makefile.gmloader ARCH=arm-linux-gnueabihf MISTER_BUILD=1 MISTER_NATIVE_VIDEO=1 \
    LLVM_INC="/usr/arm-linux-gnueabihf/include /usr/arm-linux-gnueabihf/include/c++/10/arm-linux-gnueabihf" \
    -j"$(nproc)"
file build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf
```
Expected: `ELF ... ARM`. (Build the image first if absent: `docker build -f Dockerfile.gmloader-build -t gmloader-armhf-build:bullseye .`.)

- [ ] **Step 4: Commit**

```bash
git add gmloader/input.cpp
git commit -m "feat: drive yoyo_gamepads from /dev/shm joy mask when active (keeps SDL pump)"
```

### Task 5: Hardware bit-map verification (the spec's flagged unknown)

**Files:** none (device procedure); may result in a one-line edit to `JoyShm_MaskToButtons`.

- [ ] **Step 1: Add a raw-mask debug log behind an env flag**

In `joy_shm_reader.cpp`, gate a one-line `fprintf(stderr, "joyshm p%d mask=0x%03x\n", p, mask)` behind `getenv("GMLOADER_JOY_SHM_DEBUG")` (read once into a static, per the `getenv is not free` convention at `raster_backend_sw.cpp:52`). Rebuild armhf.

- [ ] **Step 2: On device, confirm each button's bit**

Deploy both binaries (wrapper + engine). With `GMLOADER_JOY_SHM_DEBUG=1`, press each physical button in turn and read `/tmp/gmloader.log`:
- Confirm dir/Sword/Action/Item1/Item2/Pause set the bits the contract table claims (bit0..bit8).
- Confirm each maps to the intended in-game action. If Maldita's action for a given SDL slot differs (e.g. Sword should be the game's attack, which may not be gamepad button A), adjust the target slot in `JoyShm_MaskToButtons` and re-run the host test with the corrected expectation.

- [ ] **Step 3: If the table changed, bump the contract note (not the struct)**

If a mapping slot changed, update the comment in `JoyShm_MaskToButtons` and the matching CHECK in `joy_shm_reader_test.cpp`. The struct/magic/version do NOT change (the bit *positions* in the mask are unchanged; only which SDL slot each drives). Commit:
```bash
git commit -am "fix: correct mask->button slot mapping per hardware verification"
```

- [ ] **Step 4: Record the device gates in the PR**

Track (spec § Testing #3): in-game input works from a controller; opening the OSD zeroes input (character stops moving) — proving the `osd_visible` gate. Do not close the feature until both pass on hardware.

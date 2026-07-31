# gmloader Native Audio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the gmloader/Maldita MiSTer core working audio by routing every gmloader PCM producer into the DDR3 ring the FPGA already knows how to drain.

**Architecture:** The RTL is already vendored and only switched off. Three changes: (1) Maldita's audio DDR addresses go back to the absolute Solarus/OpenBOR constants, decoupled from `FB_QW_BASE`, and the `SCANOUT_ONLY` gate is dropped; (2) gmloader gets `native_audio_writer.{c,h}` copied from Solarus, writing 48 kHz stereo S16 into the ring at 0x3A0D0000; (3) a single SDL-shaped shim replaces the SDL device calls at gmloader's three audio call sites and feeds the writer from a ring-driven pump thread pinned to A9 core 1.

**Tech Stack:** C11 / C++17, SDL2 (`SDL_AudioStream` for rate+format conversion), pthreads, SystemVerilog, Icarus Verilog, Quartus Lite 17.0.

**Spec:** `docs/superpowers/specs/2026-07-27-gmloader-native-audio-design.md`

## Global Constraints

- Ring geometry is fixed and must match RTL exactly: ring at physical `0x3A0D0000`, `NA_RING_BYTES = 0x00010000` (64 KiB = 16,384 stereo frames), `wr_ptr` at `0x3A000030` (ARM writes), `rd_ptr` at `0x3A000038` (FPGA writes).
- Sink format is always 48 kHz, 2 channels, `AUDIO_S16SYS`, 4 bytes per frame. Never negotiate this outward — callers see their own requested spec back.
- Pump constants match Solarus (`solarus-mister/patches/mister/mister_native_audio.cpp:56-57,105`): `TARGET_FILL_FRAMES = 4800` (~100 ms), `MAX_FRAMES = 4096`.
- All affinity code is `#ifdef __linux__`-guarded — host tests run on macOS where `cpu_set_t` does not exist.
- Host tests must not require `/dev/mem`, root, or a real audio device.
- Never touch the video or joystick DDR map. `CTRL`/`JOY`/`BUF0`/`BUF1` stay `FB_QW_BASE`-relative at 0x3BF40000.
- Engine commits go to `gmloader-next`, RTL commits to `maldita.castilla-mister`, and only the submodule pin bump goes to `mister-gmloader`.

## Prerequisites — worktrees

Both siblings are mid-flight on `feat/native-288x216`, so this work runs in fresh worktrees branched from `master`. Create them via the `superpowers:using-git-worktrees` skill, or directly:

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next
git fetch origin && git worktree add -b feat/native-audio \
  /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-audio origin/master

cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister
git fetch origin && git worktree add -b feat/native-audio \
  /Users/gmcnaught/MisterFPGA-Projects/wt-maldita-audio origin/milestone-a
```

**Correction to the spec's Work Isolation section:** `maldita.castilla-mister` has
no `master` branch. Its default is `origin/milestone-a` (`origin/HEAD ->
origin/milestone-a`, currently `26b1f5c`), which is also the branch point of
`feat/native-288x216`. `gmloader-next` does have `master` (`b691764`), so only the
maldita side changes.

Verified safe on that base: `milestone-a`'s `fpga/sim/run_sims.sh` does not invoke
`gen_tri_golden.mk`, so the battery reads committed golden `.hex` files and does
**not** reach the sibling `gmloader-next` refmodel. (On `feat/native-288x216` it
does, via `gen_tri_golden.mk:27`, which would be a 288×216-vs-320×240 dims clash —
not a hazard for this branch.)

Throughout this plan, `$GM` = `/Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-audio` and `$MAL` = `/Users/gmcnaught/MisterFPGA-Projects/wt-maldita-audio`.

**Critical:** `deploy.py:88` sets `ENGINE_DEFAULT` to `gmloader-next/build/.../gmloadernext.armhf` — the *sibling checkout*, not this worktree and not the submodule. Task 8 therefore passes `--engine` explicitly and md5-verifies. Deploying without it ships the wrong binary.

## File Structure

**gmloader-next (`$GM`)**

| File | Responsibility |
|---|---|
| `gmloader/mister/native_audio_writer.h` (create) | Ring writer API. No SDL, no gmloader types. |
| `gmloader/mister/native_audio_writer.c` (create) | `/dev/mem` map, SPSC ring writer. Copied from Solarus + a test seam. |
| `gmloader/mister/native_audio_writer_test.c` (create) | Host test for ring accounting and wrap. |
| `gmloader/mister/mister_native_audio.h` (create) | Shim API: SDL-shaped track surface + pump seam. |
| `gmloader/mister/mister_native_audio.cpp` (create) | Track table, conversion, mix, pump, thread, pinning. |
| `gmloader/mister/mister_native_audio_test.cpp` (create) | Host test for tracks, mix, pump, staging cap. |
| `jni/classes/media_AudioTrack.cpp` (modify) | Swap 5 SDL device calls for shim calls. |
| `3rdparty/FMOD_SDL/FMOD_SDL.c` (modify) | Swap device open/close for shim, pull mode. |
| `gmloader/video_ffmpeg.cpp` (modify) | Swap device open/queue for shim. |
| `gmloader/main.cpp` (modify) | Force `SDL_AUDIODRIVER=dummy`; init/shutdown the shim. |
| `Makefile.gmloader` (modify) | Add sources to `MISTER_SRCS`; add two test targets. |

**maldita.castilla-mister (`$MAL`)**

| File | Responsibility |
|---|---|
| `fpga/rtl/openbor_video_reader.sv` (modify) | 3 localparams to absolute; drop `!SCANOUT_ONLY` from `audio_wake`. |
| `fpga/Maldita.sv` (modify) | Declare `nv_audio_l/r`, connect reader outputs, drive `AUDIO_L/R`. |

---

### Task 1: Ring writer + host test

**Files:**
- Create: `$GM/gmloader/mister/native_audio_writer.h`
- Create: `$GM/gmloader/mister/native_audio_writer.c`
- Create: `$GM/gmloader/mister/native_audio_writer_test.c`
- Modify: `$GM/Makefile.gmloader:129` (add to `MISTER_SRCS`), and append a test target after line 240

**Interfaces:**
- Consumes: nothing.
- Produces: `NativeAudioWriter_Init(void) -> bool`, `NativeAudioWriter_Shutdown(void) -> void`, `NativeAudioWriter_IsActive(void) -> bool`, `NativeAudioWriter_Submit(const int16_t *frames, size_t frame_count) -> size_t`, `NativeAudioWriter_FreeFrames(void) -> size_t`, `NativeAudioWriter_CapacityFrames(void) -> size_t`. Constants `NA_SAMPLE_RATE 48000`, `NA_CHANNELS 2`, `NA_BYTES_PER_FRAME 4`.

Note: `Submit` is copied verbatim from Solarus. The only change from the Solarus original is the `GMLOADER_AUDIO_DDR` test seam in `Init`, mirroring `joy_ddr_reader.cpp:23-33`.

- [ ] **Step 1: Write the header**

Create `$GM/gmloader/mister/native_audio_writer.h`:

```c
//
//  Native Audio DDR3 Writer -- gmloader MiSTer
//
//  Pushes 48 kHz stereo S16 PCM into a DDR3 ring buffer drained by the FPGA
//  (openbor_video_reader's audio FSM). No ALSA, no Linux sound kernel.
//
//  Memory map (must match openbor_video_reader.sv):
//    0x3A000030  audio_wr_ptr  (32-bit byte offset into ring; ARM writes)
//    0x3A000038  audio_rd_ptr  (32-bit byte offset into ring; FPGA writes)
//    0x3A0D0000  audio ring    (65,536 bytes = 16,384 stereo frames)
//
//  Copyright (C) 2026 -- GPL-3.0
//

#ifndef NATIVE_AUDIO_WRITER_H
#define NATIVE_AUDIO_WRITER_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NA_SAMPLE_RATE      48000
#define NA_CHANNELS         2
#define NA_BYTES_PER_FRAME  4   /* 2 ch * int16 */

/// Map the DDR3 region and zero the ring + both pointers.
/// GMLOADER_AUDIO_DDR overrides /dev/mem with a regular file (host tests).
/// Returns true on success. Safe to call repeatedly.
bool NativeAudioWriter_Init(void);

/// Zero the write pointer, unmap, close the fd.
void NativeAudioWriter_Shutdown(void);

/// True once Init() has succeeded.
bool NativeAudioWriter_IsActive(void);

/// Submit stereo S16 frames. Returns frames actually written; the tail of an
/// oversized batch is dropped rather than overwriting unread samples.
/// Never blocks, never sleeps. Single-producer only.
size_t NativeAudioWriter_Submit(const int16_t *frames, size_t frame_count);

/// Free space in the ring, in stereo frames.
size_t NativeAudioWriter_FreeFrames(void);

/// Usable ring capacity in stereo frames (the maximum FreeFrames can return).
/// used = CapacityFrames() - FreeFrames().
size_t NativeAudioWriter_CapacityFrames(void);

#ifdef __cplusplus
}
#endif

#endif
```

- [ ] **Step 2: Write the failing test**

Create `$GM/gmloader/mister/native_audio_writer_test.c`:

```c
// Host test for the DDR3 audio ring writer. GMLOADER_AUDIO_DDR points the
// writer at a regular file standing in for the /dev/mem region, the same
// seam joy_ddr_reader.cpp uses. Needs no root and no FPGA.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "native_audio_writer.h"

static int fails = 0;
#define CHECK(c) do { if(!(c)){printf("FAIL %s (line %d)\n",#c,__LINE__);fails++;} } while(0)

#define REGION_SIZE 0x00100000u
#define WR_OFF      0x00000030u
#define RD_OFF      0x00000038u
#define RING_OFF    0x000D0000u
#define RING_BYTES  0x00010000u

static const char *PATH = "/tmp/gmloader-audio-ddr-test";
static volatile uint8_t *g_map = NULL;

// Create a 1 MiB file and map it so the test can act as the FPGA: read the
// write pointer, and advance the read pointer to simulate draining.
static void make_region(void) {
    int fd = open(PATH, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); exit(1); }
    if (ftruncate(fd, REGION_SIZE) != 0) { perror("ftruncate"); exit(1); }
    void *p = mmap(NULL, REGION_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) { perror("mmap"); exit(1); }
    g_map = (volatile uint8_t *)p;
    setenv("GMLOADER_AUDIO_DDR", PATH, 1);
}

static uint32_t wr_ptr(void) { return *(volatile uint32_t *)(g_map + WR_OFF); }
static void set_rd_ptr(uint32_t v) { *(volatile uint32_t *)(g_map + RD_OFF) = v; }

int main(void) {
    make_region();
    CHECK(NativeAudioWriter_Init());
    CHECK(NativeAudioWriter_IsActive());

    // Capacity reserves one frame so wr == rd unambiguously means empty.
    const size_t cap = NativeAudioWriter_CapacityFrames();
    CHECK(cap == (RING_BYTES - 4u) / 4u);          // 16383
    CHECK(NativeAudioWriter_FreeFrames() == cap);  // empty at init

    // A small submit lands at offset 0 and advances wr_ptr by frames*4.
    int16_t buf[8];
    for (int i = 0; i < 8; ++i) buf[i] = (int16_t)(100 + i);
    CHECK(NativeAudioWriter_Submit(buf, 4) == 4);
    CHECK(wr_ptr() == 16);
    CHECK(memcmp((const void *)(g_map + RING_OFF), buf, 16) == 0);
    CHECK(NativeAudioWriter_FreeFrames() == cap - 4);

    // The FPGA drains everything: free space returns to capacity.
    set_rd_ptr(16);
    CHECK(NativeAudioWriter_FreeFrames() == cap);

    // Overflow drops the tail instead of overwriting unread samples.
    static int16_t big[20000 * 2];
    memset(big, 0x5A, sizeof(big));
    size_t wrote = NativeAudioWriter_Submit(big, 20000);
    CHECK(wrote == cap);                 // clamped to free space, not 20000
    CHECK(NativeAudioWriter_FreeFrames() == 0);

    // Wrap-around: park the write pointer 8 bytes shy of the ring end, then
    // submit 4 frames (16 bytes) so the copy must split 8/8.
    set_rd_ptr(wr_ptr());
    CHECK(NativeAudioWriter_FreeFrames() == cap);
    const uint32_t start = wr_ptr();                      // 12 after the above
    const uint32_t to_edge = (RING_BYTES - 8u) - start;   // 65516 bytes
    CHECK(to_edge % 4 == 0);
    static int16_t pad[16384 * 2];
    memset(pad, 0, sizeof(pad));
    CHECK(NativeAudioWriter_Submit(pad, to_edge / 4) == to_edge / 4);
    CHECK(wr_ptr() == RING_BYTES - 8u);
    set_rd_ptr(wr_ptr());

    int16_t wrapbuf[8];
    for (int i = 0; i < 8; ++i) wrapbuf[i] = (int16_t)(-1 - i);
    CHECK(NativeAudioWriter_Submit(wrapbuf, 4) == 4);
    CHECK(memcmp((const void *)(g_map + RING_OFF + RING_BYTES - 8),
                 wrapbuf, 8) == 0);
    CHECK(memcmp((const void *)(g_map + RING_OFF),
                 (const uint8_t *)wrapbuf + 8, 8) == 0);
    CHECK(wr_ptr() == 8u);

    // Degenerate inputs are no-ops, not crashes.
    CHECK(NativeAudioWriter_Submit(NULL, 4) == 0);
    CHECK(NativeAudioWriter_Submit(buf, 0) == 0);

    // Shutdown clears the write pointer and deactivates.
    NativeAudioWriter_Shutdown();
    CHECK(!NativeAudioWriter_IsActive());
    CHECK(wr_ptr() == 0);
    CHECK(NativeAudioWriter_Submit(buf, 4) == 0);   // inactive: no write

    munmap((void *)g_map, REGION_SIZE);
    unlink(PATH);
    printf(fails ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", fails);
    return fails ? 1 : 0;
}
```

- [ ] **Step 3: Add the test target and run it to verify it fails**

Append to `$GM/Makefile.gmloader` (after the `joy-shm-test` target, currently ending at line 240):

```makefile

.PHONY: native-audio-writer-test
native-audio-writer-test:
	cc -std=c11 -O0 -g -Igmloader/mister \
	  gmloader/mister/native_audio_writer_test.c \
	  gmloader/mister/native_audio_writer.c \
	  -o /tmp/nawt && /tmp/nawt
```

Run: `cd $GM && make -f Makefile.gmloader native-audio-writer-test`
Expected: FAIL — `native_audio_writer.c` does not exist yet, so the compile errors with `No such file or directory`.

- [ ] **Step 4: Write the implementation**

Create `$GM/gmloader/mister/native_audio_writer.c`:

```c
//
//  Native Audio DDR3 Writer -- gmloader MiSTer
//
//  48 kHz stereo S16 -> DDR3 ring -> FPGA audio reader -> AUDIO_L/R.
//  ARM advances the wr pointer after each submit; the FPGA writes the rd
//  pointer as it drains. Both are 32-bit byte offsets modulo RING_BYTES.
//  Submit() never blocks -- it drops the tail on overflow.
//
//  Lifted from solarus-mister/patches/mister/native_audio_writer.c so all
//  three MiSTer ports share one audio memory map. The only addition is the
//  GMLOADER_AUDIO_DDR test seam (cf. joy_ddr_reader.cpp).
//
//  Copyright (C) 2026 -- GPL-3.0
//

#include "native_audio_writer.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define NA_DDR_PHYS_BASE    0x3A000000u
#define NA_DDR_REGION_SIZE  0x00100000u   /* 1 MB -- shared with video writer */
#define NA_WR_PTR_OFFSET    0x00000030u
#define NA_RD_PTR_OFFSET    0x00000038u
#define NA_RING_OFFSET      0x000D0000u
#define NA_RING_BYTES       0x00010000u   /* 64 KiB, must match RTL */
#define NA_RING_MASK        (NA_RING_BYTES - 1u)

static int                 mem_fd = -1;
static volatile uint8_t   *ddr_base = NULL;
static volatile uint32_t  *wr_ptr_reg = NULL;
static volatile uint32_t  *rd_ptr_reg = NULL;
static volatile uint8_t   *ring_base = NULL;
static uint32_t            local_wr_ptr = 0;

bool NativeAudioWriter_Init(void) {
    if (ddr_base) return true;

    /* GMLOADER_AUDIO_DDR points a host test at a regular file standing in for
     * the /dev/mem region; on device the real physical region is mapped. */
    const char *override_path = getenv("GMLOADER_AUDIO_DDR");
    off_t off;
    if (override_path && *override_path) {
        mem_fd = open(override_path, O_RDWR);
        off = 0;
    } else {
        mem_fd = open("/dev/mem", O_RDWR | O_SYNC);
        off = (off_t)NA_DDR_PHYS_BASE;
    }
    if (mem_fd < 0) {
        perror("NativeAudioWriter: open");
        return false;
    }

    ddr_base = (volatile uint8_t *)mmap(NULL, NA_DDR_REGION_SIZE,
        PROT_READ | PROT_WRITE, MAP_SHARED, mem_fd, off);
    if (ddr_base == MAP_FAILED) {
        perror("NativeAudioWriter: mmap");
        ddr_base = NULL;
        close(mem_fd);
        mem_fd = -1;
        return false;
    }

    wr_ptr_reg = (volatile uint32_t *)(ddr_base + NA_WR_PTR_OFFSET);
    rd_ptr_reg = (volatile uint32_t *)(ddr_base + NA_RD_PTR_OFFSET);
    ring_base  = ddr_base + NA_RING_OFFSET;

    /* Start the FPGA at rd == wr == 0. Zeroing the ring is optional but
     * avoids audible garbage if the FPGA drains before the first submit. */
    memset((void *)ring_base, 0, NA_RING_BYTES);
    *wr_ptr_reg = 0;
    *rd_ptr_reg = 0;
    local_wr_ptr = 0;

    fprintf(stderr,
        "NativeAudioWriter: ring %u bytes @ 0x%08X, wr=0x%08X, rd=0x%08X\n",
        NA_RING_BYTES, NA_DDR_PHYS_BASE + NA_RING_OFFSET,
        NA_DDR_PHYS_BASE + NA_WR_PTR_OFFSET,
        NA_DDR_PHYS_BASE + NA_RD_PTR_OFFSET);
    return true;
}

void NativeAudioWriter_Shutdown(void) {
    if (ddr_base) {
        if (wr_ptr_reg) *wr_ptr_reg = 0;
        munmap((void *)ddr_base, NA_DDR_REGION_SIZE);
        ddr_base = NULL;
    }
    wr_ptr_reg = NULL;
    rd_ptr_reg = NULL;
    ring_base  = NULL;
    local_wr_ptr = 0;
    if (mem_fd >= 0) {
        close(mem_fd);
        mem_fd = -1;
    }
}

bool NativeAudioWriter_IsActive(void) {
    return ddr_base != NULL;
}

size_t NativeAudioWriter_FreeFrames(void) {
    if (!ddr_base) return 0;
    uint32_t rd = *rd_ptr_reg;
    uint32_t wr = local_wr_ptr;
    /* Free bytes = RING - 4 - (wr - rd) mod RING (one frame reserved so
     * wr == rd unambiguously means "empty"). */
    uint32_t used = (wr - rd) & NA_RING_MASK;
    uint32_t free_bytes = (NA_RING_BYTES - 4u) - used;
    return free_bytes / NA_BYTES_PER_FRAME;
}

size_t NativeAudioWriter_CapacityFrames(void) {
    return (NA_RING_BYTES - 4u) / NA_BYTES_PER_FRAME;
}

size_t NativeAudioWriter_Submit(const int16_t *frames, size_t frame_count) {
    if (!ddr_base || !frames || frame_count == 0) return 0;

    size_t max_frames = NativeAudioWriter_FreeFrames();
    if (frame_count > max_frames) frame_count = max_frames;
    if (frame_count == 0) return 0;

    uint32_t write_bytes = (uint32_t)(frame_count * NA_BYTES_PER_FRAME);
    uint32_t offset = local_wr_ptr & NA_RING_MASK;
    uint32_t tail_space = NA_RING_BYTES - offset;

    const uint8_t *src = (const uint8_t *)frames;

    if (write_bytes <= tail_space) {
        memcpy((void *)(ring_base + offset), src, write_bytes);
    } else {
        memcpy((void *)(ring_base + offset), src, tail_space);
        memcpy((void *)ring_base, src + tail_space, write_bytes - tail_space);
    }

    /* Ensure ring writes land before the wr_ptr the FPGA polls advances. */
    __sync_synchronize();

    local_wr_ptr = (local_wr_ptr + write_bytes) & NA_RING_MASK;
    *wr_ptr_reg = local_wr_ptr;

    return frame_count;
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd $GM && make -f Makefile.gmloader native-audio-writer-test`
Expected: `RESULT: PASS`, exit 0. The `NativeAudioWriter: ring 65536 bytes @ 0x3A0D0000, ...` banner on stderr is expected.

- [ ] **Step 6: Add the writer to the MiSTer build**

In `$GM/Makefile.gmloader:129`, add `gmloader/mister/native_audio_writer.c` to `MISTER_SRCS`. The line becomes:

```makefile
MISTER_SRCS = gmloader/mister/native_video_writer.c gmloader/mister/native_audio_writer.c gmloader/mister/frame_capture.cpp gmloader/mister/draw_trace.cpp gmloader/mister/blitter.cpp gmloader/mister/blitter_raster.cpp gmloader/mister/raster_backend_sw.cpp gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/joy_shm_reader.cpp gmloader/mister/joy_ddr_reader.cpp
```

- [ ] **Step 7: Commit**

```bash
cd $GM
git add gmloader/mister/native_audio_writer.h gmloader/mister/native_audio_writer.c \
        gmloader/mister/native_audio_writer_test.c Makefile.gmloader
git commit -m "feat(mister): DDR3 audio ring writer, shared map with Solarus/OpenBOR"
```

---

### Task 2: Shim track table — open, queue, drain accounting

**Files:**
- Create: `$GM/gmloader/mister/mister_native_audio.h`
- Create: `$GM/gmloader/mister/mister_native_audio.cpp`
- Create: `$GM/gmloader/mister/mister_native_audio_test.cpp`
- Modify: `$GM/Makefile.gmloader` (append a test target)

**Interfaces:**
- Consumes: everything Task 1 produces.
- Produces: `MisterAudioTrack` (an `int`; `0` means failure, mirroring `SDL_AudioDeviceID`), `MisterAudio_Init`, `MisterAudio_Shutdown`, `MisterAudio_IsActive`, `MisterAudio_Open(const SDL_AudioSpec *desired, SDL_AudioSpec *obtained) -> MisterAudioTrack`, `MisterAudio_Close(MisterAudioTrack)`, `MisterAudio_Queue(MisterAudioTrack, const void *data, uint32_t len) -> int` (0 ok, -1 refused), `MisterAudio_QueuedBytes(MisterAudioTrack) -> uint32_t`, `MisterAudio_Clear(MisterAudioTrack)`, `MisterAudio_Pause(MisterAudioTrack, int pause_on)`, `MisterAudio_DroppedFrames(void) -> uint64_t`. Task 3 adds `MisterAudio_PumpOnce`; Task 4 adds the thread controls.

This task builds the track table and conversion only — no mixing, no pump. `MisterAudio_Init` maps the writer; audio is not yet audible.

- [ ] **Step 1: Write the header**

Create `$GM/gmloader/mister/mister_native_audio.h`:

```cpp
//
//  MiSTer native audio shim -- gmloader
//
//  Replaces the SDL audio *device* for every gmloader PCM producer
//  (android.media.AudioTrack, FMOD_SDL, video_ffmpeg) with a sink that mixes
//  into the DDR3 ring the FPGA drains. SDL is still used for rate/format
//  conversion via SDL_AudioStream -- only the device is replaced.
//
//  Callers see their own requested spec back verbatim; the 48 kHz stereo S16
//  sink format is never negotiated outward.
//
//  Copyright (C) 2026 -- GPL-3.0
//

#ifndef MISTER_NATIVE_AUDIO_H
#define MISTER_NATIVE_AUDIO_H

#include <SDL2/SDL.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Track handle. 0 == failure, mirroring SDL_AudioDeviceID.
typedef int MisterAudioTrack;

#define MISTER_AUDIO_MAX_TRACKS      4
#define MISTER_AUDIO_STAGING_CAP_MS  500

/// Map the DDR ring. Returns false if /dev/mem is unavailable, in which case
/// IsActive() stays false and callers must fall back to real SDL devices.
bool MisterAudio_Init(void);

/// Close all tracks and unmap. Idempotent.
void MisterAudio_Shutdown(void);

/// True when the ring is mapped and the shim owns the audio path.
bool MisterAudio_IsActive(void);

/// Open a track. If desired->callback is non-NULL the track is PULL mode and
/// the pump invokes that callback; otherwise it is PUSH mode and the caller
/// feeds it with MisterAudio_Queue. `obtained` (if non-NULL) is filled with
/// exactly `desired`, so callers see no format change.
MisterAudioTrack MisterAudio_Open(const SDL_AudioSpec *desired,
                                  SDL_AudioSpec *obtained);
void MisterAudio_Close(MisterAudioTrack t);

/// Push PCM in the track's own format. Returns 0 on success, -1 if refused
/// because staging is already at MISTER_AUDIO_STAGING_CAP_MS.
int MisterAudio_Queue(MisterAudioTrack t, const void *data, uint32_t len);

/// Bytes still staged for this track, in 48 kHz stereo S16 bytes. Reports
/// ONLY staging -- audio already moved into the ring counts as consumed, so
/// the ring keeps acting as the latency cushion.
uint32_t MisterAudio_QueuedBytes(MisterAudioTrack t);

void MisterAudio_Clear(MisterAudioTrack t);
void MisterAudio_Pause(MisterAudioTrack t, int pause_on);

/// Frames refused by the staging cap since Init. Non-zero on device is a bug
/// signal, not normal operation.
uint64_t MisterAudio_DroppedFrames(void);

#ifdef __cplusplus
}
#endif

#endif
```

- [ ] **Step 2: Write the failing test**

Create `$GM/gmloader/mister/mister_native_audio_test.cpp`:

```cpp
// Host test for the SDL-shaped audio shim. Uses the GMLOADER_AUDIO_DDR file
// seam so no /dev/mem is needed, and never opens a real audio device.
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "mister_native_audio.h"
#include "native_audio_writer.h"

static int fails = 0;
#define CHECK(c) do { if(!(c)){printf("FAIL %s (line %d)\n",#c,__LINE__);fails++;} } while(0)

#define REGION_SIZE 0x00100000u
#define RD_OFF      0x00000038u

static const char *PATH = "/tmp/gmloader-audio-shim-test";
static volatile uint8_t *g_map = NULL;

static void make_region(void) {
    int fd = open(PATH, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror("open"); exit(1); }
    if (ftruncate(fd, REGION_SIZE) != 0) { perror("ftruncate"); exit(1); }
    void *p = mmap(NULL, REGION_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) { perror("mmap"); exit(1); }
    g_map = (volatile uint8_t *)p;
    setenv("GMLOADER_AUDIO_DDR", PATH, 1);
    // Task 4 adds a pump thread that starts inside MisterAudio_Init. Keep it
    // off for the deterministic sections below -- a background pump racing the
    // test's own MisterAudio_PumpOnce() calls would make them flaky. Task 4
    // re-enables it for its own Init/Shutdown cycle at the end.
    setenv("GMLOADER_AUDIO_PUMP_THREAD", "0", 1);
}

// Stand in for the FPGA drain: mark the whole ring consumed.
static void drain_ring(void) {
    *(volatile uint32_t *)(g_map + RD_OFF) =
        *(volatile uint32_t *)(g_map + 0x30u);
}

int main(void) {
    make_region();
    CHECK(MisterAudio_Init());
    CHECK(MisterAudio_IsActive());

    // A push track at the sink's own format opens and echoes its spec back.
    SDL_AudioSpec want, got;
    SDL_zero(want);
    want.freq = 48000;
    want.format = AUDIO_S16SYS;
    want.channels = 2;
    want.samples = 1024;
    want.callback = NULL;
    MisterAudioTrack t = MisterAudio_Open(&want, &got);
    CHECK(t != 0);
    CHECK(got.freq == 48000 && got.format == AUDIO_S16SYS && got.channels == 2);
    CHECK(got.samples == 1024);           // caller's arithmetic is preserved

    // Queued bytes reflect staging only, and start empty.
    CHECK(MisterAudio_QueuedBytes(t) == 0);

    // 480 frames in == 1920 bytes staged (no conversion at 48k stereo S16).
    static int16_t pcm[480 * 2];
    for (int i = 0; i < 480 * 2; ++i) pcm[i] = (int16_t)(i & 0x7FFF);
    CHECK(MisterAudio_Queue(t, pcm, sizeof(pcm)) == 0);
    CHECK(MisterAudio_QueuedBytes(t) == sizeof(pcm));

    // Clear drops staging.
    MisterAudio_Clear(t);
    CHECK(MisterAudio_QueuedBytes(t) == 0);

    // A 44.1 kHz mono track is resampled and upmixed: 441 frames in should
    // stage roughly 480 frames of 48 kHz stereo. Allow a small resampler
    // tolerance rather than asserting an exact count.
    SDL_AudioSpec want44;
    SDL_zero(want44);
    want44.freq = 44100;
    want44.format = AUDIO_S16SYS;
    want44.channels = 1;
    want44.samples = 512;
    MisterAudioTrack t44 = MisterAudio_Open(&want44, NULL);
    CHECK(t44 != 0);
    static int16_t mono[441];
    memset(mono, 0, sizeof(mono));
    CHECK(MisterAudio_Queue(t44, mono, sizeof(mono)) == 0);
    const uint32_t staged = MisterAudio_QueuedBytes(t44);
    CHECK(staged > 460 * 4 && staged < 500 * 4);

    // Staging cap: flooding a track past 500 ms is refused, not buffered.
    static int16_t flood[48000 * 2];
    memset(flood, 0, sizeof(flood));
    int refusals = 0;
    for (int i = 0; i < 4; ++i)
        if (MisterAudio_Queue(t, flood, sizeof(flood)) != 0) refusals++;
    CHECK(refusals > 0);
    CHECK(MisterAudio_DroppedFrames() > 0);
    // The cap is checked before a put, so staging tops out at one oversized
    // batch beyond it -- bounded, which is the point, rather than unbounded.
    CHECK(MisterAudio_QueuedBytes(t) <= 256000u);

    // Closing frees the slot so a later open succeeds.
    MisterAudio_Close(t);
    MisterAudio_Close(t44);
    CHECK(MisterAudio_QueuedBytes(t) == 0);            // stale handle is inert
    MisterAudioTrack t2 = MisterAudio_Open(&want, NULL);
    CHECK(t2 != 0);
    MisterAudio_Close(t2);

    drain_ring();
    MisterAudio_Shutdown();
    CHECK(!MisterAudio_IsActive());

    munmap((void *)g_map, REGION_SIZE);
    unlink(PATH);
    printf(fails ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", fails);
    return fails ? 1 : 0;
}
```

- [ ] **Step 3: Add the test target and run it to verify it fails**

Append to `$GM/Makefile.gmloader`:

```makefile

.PHONY: native-audio-shim-test
native-audio-shim-test:
	c++ -std=c++17 -O0 -g -Igmloader/mister $(shell pkg-config sdl2 --cflags) \
	  gmloader/mister/mister_native_audio_test.cpp \
	  gmloader/mister/mister_native_audio.cpp \
	  gmloader/mister/native_audio_writer.c \
	  $(shell pkg-config sdl2 --libs) -o /tmp/mnat && /tmp/mnat
```

Run: `cd $GM && make -f Makefile.gmloader native-audio-shim-test`
Expected: FAIL — `mister_native_audio.cpp` does not exist, compile errors.

- [ ] **Step 4: Write the implementation**

Create `$GM/gmloader/mister/mister_native_audio.cpp`:

```cpp
//
//  MiSTer native audio shim -- gmloader
//
//  See mister_native_audio.h. This file owns the track table and the
//  conversion streams; the pump and its thread are added on top.
//
//  Copyright (C) 2026 -- GPL-3.0
//

#include "mister_native_audio.h"
#include "native_audio_writer.h"

#include <pthread.h>
#include <stdio.h>
#include <string.h>

namespace {

// 500 ms of the sink format: 48000 * 4 * 500 / 1000.
const uint32_t kStagingCapBytes =
    (uint32_t)NA_SAMPLE_RATE * NA_BYTES_PER_FRAME * MISTER_AUDIO_STAGING_CAP_MS / 1000u;

struct Track {
    bool             open;
    bool             paused;
    bool             pull;          // callback-driven (FMOD) vs queue-driven
    SDL_AudioSpec    spec;          // exactly what the caller asked for
    SDL_AudioStream *conv;          // caller format -> 48k stereo S16
};

Track     g_tracks[MISTER_AUDIO_MAX_TRACKS];
bool      g_active = false;
uint64_t  g_dropped = 0;

// Guards the track table against the pump's mix pass. Non-recursive, never
// nested -- the same role as Solarus's audio_mutex.
pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

Track *track_of(MisterAudioTrack t) {
    if (t <= 0 || t > MISTER_AUDIO_MAX_TRACKS) return nullptr;
    Track *tr = &g_tracks[t - 1];
    return tr->open ? tr : nullptr;
}

}  // namespace

bool MisterAudio_Init(void) {
    if (g_active) return true;
    memset(g_tracks, 0, sizeof(g_tracks));
    g_dropped = 0;
    if (!NativeAudioWriter_Init()) {
        fprintf(stderr,
            "MisterAudio: /dev/mem unavailable, falling back to SDL devices\n");
        return false;
    }
    g_active = true;
    fprintf(stderr, "MisterAudio: native audio active (48000 Hz stereo S16)\n");
    return true;
}

void MisterAudio_Shutdown(void) {
    pthread_mutex_lock(&g_lock);
    for (int i = 0; i < MISTER_AUDIO_MAX_TRACKS; ++i) {
        if (g_tracks[i].conv) SDL_FreeAudioStream(g_tracks[i].conv);
        g_tracks[i].conv = nullptr;
        g_tracks[i].open = false;
    }
    g_active = false;
    pthread_mutex_unlock(&g_lock);
    NativeAudioWriter_Shutdown();
}

bool MisterAudio_IsActive(void) { return g_active; }

MisterAudioTrack MisterAudio_Open(const SDL_AudioSpec *desired,
                                  SDL_AudioSpec *obtained) {
    if (!g_active || !desired) return 0;

    SDL_AudioStream *conv = SDL_NewAudioStream(
        desired->format, desired->channels, desired->freq,
        AUDIO_S16SYS, NA_CHANNELS, NA_SAMPLE_RATE);
    if (!conv) {
        fprintf(stderr, "MisterAudio: SDL_NewAudioStream failed: %s\n",
                SDL_GetError());
        return 0;
    }

    pthread_mutex_lock(&g_lock);
    int slot = -1;
    for (int i = 0; i < MISTER_AUDIO_MAX_TRACKS; ++i)
        if (!g_tracks[i].open) { slot = i; break; }
    if (slot < 0) {
        pthread_mutex_unlock(&g_lock);
        SDL_FreeAudioStream(conv);
        fprintf(stderr, "MisterAudio: no free track slot\n");
        return 0;
    }

    Track *tr = &g_tracks[slot];
    tr->open   = true;
    tr->paused = true;              // SDL opens devices paused
    tr->pull   = (desired->callback != nullptr);
    tr->spec   = *desired;
    tr->conv   = conv;
    pthread_mutex_unlock(&g_lock);

    // Echo the request back verbatim so caller-side arithmetic is unchanged.
    if (obtained) *obtained = *desired;

    fprintf(stderr, "MisterAudio: track %d open (%d Hz, %d ch, %s)\n",
            slot + 1, desired->freq, desired->channels,
            tr->pull ? "pull" : "push");
    return slot + 1;
}

void MisterAudio_Close(MisterAudioTrack t) {
    pthread_mutex_lock(&g_lock);
    Track *tr = track_of(t);
    if (tr) {
        if (tr->conv) SDL_FreeAudioStream(tr->conv);
        tr->conv = nullptr;
        tr->open = false;
        tr->paused = true;
    }
    pthread_mutex_unlock(&g_lock);
}

int MisterAudio_Queue(MisterAudioTrack t, const void *data, uint32_t len) {
    if (!data || len == 0) return 0;
    pthread_mutex_lock(&g_lock);
    Track *tr = track_of(t);
    if (!tr || tr->pull) { pthread_mutex_unlock(&g_lock); return -1; }

    if ((uint32_t)SDL_AudioStreamAvailable(tr->conv) >= kStagingCapBytes) {
        g_dropped += len / NA_BYTES_PER_FRAME;
        pthread_mutex_unlock(&g_lock);
        return -1;
    }
    int rc = SDL_AudioStreamPut(tr->conv, data, (int)len);
    pthread_mutex_unlock(&g_lock);
    return rc == 0 ? 0 : -1;
}

uint32_t MisterAudio_QueuedBytes(MisterAudioTrack t) {
    pthread_mutex_lock(&g_lock);
    Track *tr = track_of(t);
    uint32_t n = tr ? (uint32_t)SDL_AudioStreamAvailable(tr->conv) : 0u;
    pthread_mutex_unlock(&g_lock);
    return n;
}

void MisterAudio_Clear(MisterAudioTrack t) {
    pthread_mutex_lock(&g_lock);
    Track *tr = track_of(t);
    if (tr) SDL_AudioStreamClear(tr->conv);
    pthread_mutex_unlock(&g_lock);
}

void MisterAudio_Pause(MisterAudioTrack t, int pause_on) {
    pthread_mutex_lock(&g_lock);
    Track *tr = track_of(t);
    if (tr) tr->paused = (pause_on != 0);
    pthread_mutex_unlock(&g_lock);
}

uint64_t MisterAudio_DroppedFrames(void) { return g_dropped; }
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd $GM && make -f Makefile.gmloader native-audio-shim-test`
Expected: `RESULT: PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
cd $GM
git add gmloader/mister/mister_native_audio.h gmloader/mister/mister_native_audio.cpp \
        gmloader/mister/mister_native_audio_test.cpp Makefile.gmloader
git commit -m "feat(mister): audio shim track table + SDL_AudioStream conversion"
```

---

### Task 3: Pump pass — mix, pull tracks, silence on idle

**Files:**
- Modify: `$GM/gmloader/mister/mister_native_audio.h` (add `MisterAudio_PumpOnce`)
- Modify: `$GM/gmloader/mister/mister_native_audio.cpp` (add the pump)
- Modify: `$GM/gmloader/mister/mister_native_audio_test.cpp` (add pump assertions)

**Interfaces:**
- Consumes: everything Tasks 1-2 produce.
- Produces: `MisterAudio_PumpOnce(void) -> size_t` (frames submitted this pass). Task 4's thread calls it in a loop; the test calls it directly, which is why it is a public seam rather than a static.

The pump exists as a separate callable so it is testable without a thread and without wall-clock timing.

- [ ] **Step 1: Add the declaration**

In `$GM/gmloader/mister/mister_native_audio.h`, insert before `MisterAudio_DroppedFrames`:

```cpp
/// Run one pump pass: top the ring back up to TARGET_FILL by mixing every
/// active, unpaused track. Returns the frames submitted. Submits silence when
/// nothing is playing -- the FPGA FIFO holds its last sample when starved, so
/// an empty ring would park the DAC at a DC offset.
/// The pump thread calls this in a loop; tests call it directly.
size_t MisterAudio_PumpOnce(void);
```

- [ ] **Step 2: Write the failing test**

In `$GM/gmloader/mister/mister_native_audio_test.cpp`, insert this block immediately before the `// Closing frees the slot ...` comment:

```cpp
    // --- Pump ------------------------------------------------------------
    // Start clean: drop the flood staged above and drain what the ring holds.
    MisterAudio_Clear(t);
    MisterAudio_Clear(t44);
    drain_ring();

    // With every track paused the pump still feeds the ring, so the DAC sees
    // real silence rather than a held DC level.
    CHECK(MisterAudio_PumpOnce() > 0);
    CHECK(NativeAudioWriter_FreeFrames() < NativeAudioWriter_CapacityFrames());

    // Reaching TARGET_FILL (4800) takes more than one pass because each is
    // capped at MAX_FRAMES (4096). Pump until topped up, then a further pass
    // must be a no-op.
    for (int i = 0; i < 8 && MisterAudio_PumpOnce() > 0; ++i) {}
    CHECK(MisterAudio_PumpOnce() == 0);

    // Unpause and stage a known full-scale ramp; the pump must consume it.
    drain_ring();
    MisterAudio_Pause(t, 0);
    static int16_t tone[2400 * 2];
    for (int i = 0; i < 2400 * 2; ++i) tone[i] = 1000;
    CHECK(MisterAudio_Queue(t, tone, sizeof(tone)) == 0);
    CHECK(MisterAudio_QueuedBytes(t) == sizeof(tone));
    CHECK(MisterAudio_PumpOnce() > 0);
    CHECK(MisterAudio_QueuedBytes(t) == 0);       // staging drained into ring

    // Two unpaused tracks sum. Feed both the same constant and check the ring
    // holds the doubled value, saturating rather than wrapping.
    drain_ring();
    MisterAudio_Pause(t44, 0);
    SDL_AudioSpec want2;
    SDL_zero(want2);
    want2.freq = 48000; want2.format = AUDIO_S16SYS; want2.channels = 2;
    want2.samples = 1024;
    MisterAudioTrack tb = MisterAudio_Open(&want2, NULL);
    CHECK(tb != 0);
    MisterAudio_Pause(tb, 0);
    static int16_t loud[480 * 2];
    for (int i = 0; i < 480 * 2; ++i) loud[i] = 20000;
    CHECK(MisterAudio_Queue(t, loud, sizeof(loud)) == 0);
    CHECK(MisterAudio_Queue(tb, loud, sizeof(loud)) == 0);
    const uint32_t wr_before =
        *(volatile uint32_t *)(g_map + 0x30u) & 0xFFFFu;
    CHECK(MisterAudio_PumpOnce() > 0);
    // 20000 + 20000 saturates to 32767, never wraps to a negative sample.
    const int16_t *ring =
        (const int16_t *)(const void *)(g_map + 0x000D0000u + wr_before);
    CHECK(ring[0] == 32767);
    CHECK(ring[1] == 32767);
    MisterAudio_Close(tb);
    MisterAudio_Pause(t44, 1);
    MisterAudio_Pause(t, 1);
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd $GM && make -f Makefile.gmloader native-audio-shim-test`
Expected: FAIL to compile — `MisterAudio_PumpOnce` is declared but not defined, so the link errors with `undefined symbol`.

- [ ] **Step 4: Write the implementation**

In `$GM/gmloader/mister/mister_native_audio.cpp`, add to the anonymous namespace, after `kStagingCapBytes`:

```cpp
// Solarus's constants (mister_native_audio.cpp:56-57,105): keep ~100 ms of
// audio queued in the ring, and never render more than 16 KiB in one pass.
const size_t kTargetFillFrames = 4800;
const size_t kMaxFramesPerPass = 4096;

int16_t g_mixbuf[kMaxFramesPerPass * NA_CHANNELS];
int16_t g_tmpbuf[kMaxFramesPerPass * NA_CHANNELS];
// Scratch for pull tracks, in the TRACK's format. Sized for the worst case
// this shim accepts: 4 bytes/frame at the highest rate any caller asks for.
uint8_t g_pullbuf[kMaxFramesPerPass * 8];

int16_t sat_add_s16(int16_t a, int16_t b) {
    int32_t s = (int32_t)a + (int32_t)b;
    if (s >  32767) return  32767;
    if (s < -32768) return -32768;
    return (int16_t)s;
}

// Ask a pull track's callback for enough source bytes to cover `want_bytes`
// of sink output, and push the result through its converter.
void fill_pull_track(Track *tr, int want_bytes) {
    const int src_frame_bytes = SDL_AUDIO_BITSIZE(tr->spec.format) / 8 *
                                tr->spec.channels;
    if (src_frame_bytes <= 0) return;

    // Sink frames -> source frames, rounded up.
    const int want_frames = want_bytes / NA_BYTES_PER_FRAME;
    long src_frames = ((long)want_frames * tr->spec.freq + NA_SAMPLE_RATE - 1) /
                      NA_SAMPLE_RATE;
    long src_bytes = src_frames * src_frame_bytes;
    if (src_bytes > (long)sizeof(g_pullbuf)) src_bytes = sizeof(g_pullbuf);
    if (src_bytes <= 0) return;

    // Callbacks expect a fully-initialised buffer; SDL guarantees silence.
    SDL_memset(g_pullbuf, SDL_AUDIO_ISSIGNED(tr->spec.format) ? 0 : 0x80,
               (size_t)src_bytes);
    tr->spec.callback(tr->spec.userdata, g_pullbuf, (int)src_bytes);
    SDL_AudioStreamPut(tr->conv, g_pullbuf, (int)src_bytes);
}
```

Then add the public function at the end of the file:

```cpp
size_t MisterAudio_PumpOnce(void) {
    if (!g_active) return 0;

    const size_t cap  = NativeAudioWriter_CapacityFrames();
    const size_t freeF = NativeAudioWriter_FreeFrames();
    const size_t used = cap - freeF;
    if (used >= kTargetFillFrames) return 0;

    size_t want = kTargetFillFrames - used;
    if (want > kMaxFramesPerPass) want = kMaxFramesPerPass;
    if (want > freeF) want = freeF;
    if (want == 0) return 0;

    const int want_bytes = (int)(want * NA_BYTES_PER_FRAME);

    pthread_mutex_lock(&g_lock);

    // Silence is the floor, not the absence of a submit: the FPGA FIFO holds
    // its last sample when starved, so a dry ring parks the DAC at a DC level.
    memset(g_mixbuf, 0, (size_t)want_bytes);

    int mixed = 0;
    for (int i = 0; i < MISTER_AUDIO_MAX_TRACKS; ++i) {
        Track *tr = &g_tracks[i];
        if (!tr->open || tr->paused || !tr->conv) continue;

        if (tr->pull && SDL_AudioStreamAvailable(tr->conv) < want_bytes)
            fill_pull_track(tr, want_bytes);

        int got = SDL_AudioStreamGet(tr->conv,
                                     mixed == 0 ? g_mixbuf : g_tmpbuf,
                                     want_bytes);
        if (got <= 0) {
            // A track with nothing available contributes silence, exactly as
            // an underrunning SDL device would. g_mixbuf was zeroed at the top
            // of the pass, so there is nothing to do here.
            continue;
        }
        if (mixed == 0) {
            // First contributor wrote straight into the mix buffer; zero any
            // shortfall so the tail is silence rather than stale samples.
            if (got < want_bytes)
                memset((uint8_t *)g_mixbuf + got, 0, (size_t)(want_bytes - got));
        } else {
            const int n = got / 2;   // samples, not frames
            for (int s = 0; s < n; ++s)
                g_mixbuf[s] = sat_add_s16(g_mixbuf[s], g_tmpbuf[s]);
        }
        ++mixed;
    }

    pthread_mutex_unlock(&g_lock);

    return NativeAudioWriter_Submit(g_mixbuf, want);
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd $GM && make -f Makefile.gmloader native-audio-shim-test`
Expected: `RESULT: PASS`, exit 0.

- [ ] **Step 6: Commit**

```bash
cd $GM
git add gmloader/mister/mister_native_audio.h gmloader/mister/mister_native_audio.cpp \
        gmloader/mister/mister_native_audio_test.cpp
git commit -m "feat(mister): ring-driven pump pass with saturating mix and silence floor"
```

---

### Task 4: Pump thread and core-1 pinning

**Files:**
- Modify: `$GM/gmloader/mister/mister_native_audio.h` (thread controls)
- Modify: `$GM/gmloader/mister/mister_native_audio.cpp` (thread, pinning, lifecycle)
- Modify: `$GM/gmloader/mister/mister_native_audio_test.cpp` (thread assertions)

**Interfaces:**
- Consumes: `MisterAudio_PumpOnce` from Task 3.
- Produces: `MisterAudio_ThreadActive(void) -> bool`. `MisterAudio_Init` now starts the thread; `MisterAudio_Shutdown` stops and joins it before unmapping.

Pinning is Linux-only. On macOS the guard compiles out and the thread runs unpinned, which is what the host test exercises.

- [ ] **Step 1: Add the declaration**

In `$GM/gmloader/mister/mister_native_audio.h`, insert after the `MisterAudio_PumpOnce` declaration:

```cpp
/// True when the pump thread is running. False when Init() failed, when
/// GMLOADER_AUDIO_PUMP_THREAD=0, or when the platform reports fewer than 2
/// cores -- in the last case the caller must drive MisterAudio_PumpOnce().
bool MisterAudio_ThreadActive(void);
```

- [ ] **Step 2: Write the failing test**

The test already sets `GMLOADER_AUDIO_PUMP_THREAD=0` in `make_region()` (Task 2), so every deterministic assertion above runs with no background pump. Add the thread coverage as its own Init/Shutdown cycle.

In `$GM/gmloader/mister/mister_native_audio_test.cpp`, add `#include <time.h>` to the includes, and insert this immediately after the existing `CHECK(MisterAudio_IsActive());` near the top:

```cpp
    // Deterministic sections run with the pump thread disabled.
    CHECK(!MisterAudio_ThreadActive());
```

Then replace the final teardown block — the `drain_ring(); MisterAudio_Shutdown(); CHECK(!MisterAudio_IsActive());` lines — with:

```cpp
    drain_ring();
    MisterAudio_Shutdown();
    CHECK(!MisterAudio_IsActive());
    CHECK(!MisterAudio_ThreadActive());

    // --- Thread ----------------------------------------------------------
    // A second cycle with the pump thread enabled: it must keep the ring fed
    // with nobody calling PumpOnce, and must join cleanly on shutdown.
    setenv("GMLOADER_AUDIO_PUMP_THREAD", "1", 1);
    CHECK(MisterAudio_Init());
    CHECK(MisterAudio_ThreadActive());
    drain_ring();
    struct timespec nap = { 0, 50 * 1000 * 1000 };   // 50 ms
    nanosleep(&nap, NULL);
    CHECK(NativeAudioWriter_FreeFrames() < NativeAudioWriter_CapacityFrames());
    MisterAudio_Shutdown();
    CHECK(!MisterAudio_ThreadActive());
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd $GM && make -f Makefile.gmloader native-audio-shim-test`
Expected: FAIL to link — `MisterAudio_ThreadActive` undefined.

- [ ] **Step 4: Write the implementation**

In `$GM/gmloader/mister/mister_native_audio.cpp`, add these includes at the top:

```cpp
#include <atomic>
#include <sched.h>      /* cpu_set_t / CPU_SET, under _GNU_SOURCE */
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
```

Add to the anonymous namespace:

```cpp
pthread_t g_pump_tid;
// ATOMIC, not a plain bool: this is the pump loop's exit condition. A plain
// non-atomic flag read in a spin loop may legally be hoisted out of the loop by
// the compiler, so the pump could never observe Shutdown()'s store and would
// hang the join forever.
std::atomic<bool> g_pump_running{false};

// Pin a thread to one core. Linux-only; a no-op elsewhere (host tests).
void pin_to_core(pthread_t th, int cpu) {
#ifdef __linux__
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (pthread_setaffinity_np(th, sizeof(set), &set) != 0)
        fprintf(stderr, "MisterAudio: pin to core %d failed\n", cpu);
#else
    (void)th; (void)cpu;
#endif
}

bool pinning_enabled(void) {
    const char *v = getenv("GMLOADER_AUDIO_PIN");
    if (v && v[0] == '0') return false;
    return sysconf(_SC_NPROCESSORS_ONLN) >= 2;
}

// GMLOADER_AUDIO_PUMP_THREAD=0 keeps the pump off the clock so a caller (the
// host test) can drive MisterAudio_PumpOnce() deterministically.
bool pump_thread_enabled(void) {
    const char *v = getenv("GMLOADER_AUDIO_PUMP_THREAD");
    return !(v && v[0] == '0');
}

void *pump_main(void *) {
    // Ring-driven: the FPGA drain is the clock. PumpOnce refills TO a fixed
    // level, so the long-run submit rate equals the 48 kHz drain rate and the
    // pitch is exact. Sleep only when there is nothing to do.
    const struct timespec idle = { 0, 1000 * 1000 };   // 1 ms
    while (g_pump_running.load(std::memory_order_acquire)) {
        if (MisterAudio_PumpOnce() == 0)
            nanosleep(&idle, nullptr);
    }
    return nullptr;
}
```

Note: `pin_to_core` needs `_GNU_SOURCE` for `pthread_setaffinity_np`. Add this as the **first line** of the file, before any include:

```cpp
#define _GNU_SOURCE 1
```

In `MisterAudio_Init`, replace the two lines `g_active = true;` / `fprintf(stderr, "MisterAudio: native audio active ...` with:

```cpp
    g_active = true;

    if (!pump_thread_enabled()) {
        fprintf(stderr, "MisterAudio: pump thread disabled by env\n");
    } else {
        g_pump_running = true;
        if (pthread_create(&g_pump_tid, nullptr, pump_main, nullptr) != 0) {
            g_pump_running = false;
            fprintf(stderr, "MisterAudio: pump thread failed to start\n");
        } else if (pinning_enabled()) {
            // The fabric backend pure-spins on C_DONE by default and pegs the
            // thread it runs on, so keep the pump off that core entirely.
            pin_to_core(g_pump_tid, 1);
            pin_to_core(pthread_self(), 0);
            fprintf(stderr,
                    "MisterAudio: pump pinned to core 1, main to core 0\n");
        }
    }

    fprintf(stderr, "MisterAudio: native audio active (48000 Hz stereo S16)\n");
```

In `MisterAudio_Shutdown`, add this as the **first** statement, before the mutex is taken:

```cpp
    // Join before anything is torn down: no mix may be in flight over a dead
    // mapping. Mirrors Solarus stopping the thread at the top of Sound::quit().
    if (g_pump_running.exchange(false, std::memory_order_release)) {
        pthread_join(g_pump_tid, nullptr);
    }
```

Add the accessor at the end of the file:

```cpp
bool MisterAudio_ThreadActive(void) {
    return g_pump_running.load(std::memory_order_acquire);
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd $GM && make -f Makefile.gmloader native-audio-shim-test`
Expected: `RESULT: PASS`, exit 0, and no hang at shutdown.

- [ ] **Step 6: Verify the pin knob compiles out cleanly**

Run: `cd $GM && GMLOADER_AUDIO_PIN=0 make -f Makefile.gmloader native-audio-shim-test`
Expected: `RESULT: PASS`. On macOS the pinning banner never prints either way; the point of this run is that the env path is exercised.

- [ ] **Step 7: Commit**

```bash
cd $GM
git add gmloader/mister/mister_native_audio.h gmloader/mister/mister_native_audio.cpp \
        gmloader/mister/mister_native_audio_test.cpp
git commit -m "feat(mister): pump thread pinned to A9 core 1, joined before unmap"
```

---

### Task 5: Wire the three call sites and cross-build

**Files:**
- Modify: `$GM/jni/classes/media_AudioTrack.cpp` (lines 40, 58, 64, 70, 87, 91)
- Modify: `$GM/gmloader/video_ffmpeg.cpp` (lines 152, 309, plus close)
- Modify: `$GM/3rdparty/FMOD_SDL/FMOD_SDL.c` (line 288 and the matching close)
- Modify: `$GM/gmloader/main.cpp` (line ~506 and shutdown)
- Modify: `$GM/Makefile.gmloader:129` (add the shim to `MISTER_SRCS`)

**Interfaces:**
- Consumes: the full shim API from Tasks 2-4.
- Produces: no new symbols. This task makes the shim load-bearing.

Every edit is guarded so non-MiSTer builds are untouched: when `MisterAudio_IsActive()` is false the original SDL call runs. On MiSTer that fallback path means silence (the dummy driver), which is the documented `/dev/mem`-unavailable behaviour.

- [ ] **Step 1: Route the AudioTrack shim**

In `$GM/jni/classes/media_AudioTrack.cpp`, add to the includes:

```cpp
#include "mister_native_audio.h"
```

Replace line 40 (`deviceId = SDL_OpenAudioDevice(NULL, 0, &desired, &obtained, 0);`) with:

```cpp
    nativeTrack = MisterAudio_IsActive() ? MisterAudio_Open(&desired, &obtained) : 0;
    deviceId = nativeTrack ? 0 : SDL_OpenAudioDevice(NULL, 0, &desired, &obtained, 0);
```

Add `MisterAudioTrack nativeTrack;` to the class in `$GM/jni/classes/media_AudioTrack.h`, and `#include "mister_native_audio.h"` there too.

Replace the bodies of `play`, `stop`, `release` and the queue/wait in `write`:

```cpp
void AudioTrack::play(JNIEnv *env, jobject obj, jclass clazz)
{
    AudioTrack *track = (AudioTrack*)obj;
    track->playing = 1;
    if (track->nativeTrack) MisterAudio_Pause(track->nativeTrack, 0);
    else SDL_PauseAudioDevice(track->deviceId, 0);
}

void AudioTrack::stop(JNIEnv *env, jobject obj, jclass clazz)
{
    AudioTrack *track = (AudioTrack*)obj;
    track->playing = 0;
    if (track->nativeTrack) MisterAudio_Pause(track->nativeTrack, 1);
    else SDL_PauseAudioDevice(track->deviceId, 1);
}

void AudioTrack::release(JNIEnv *env, jobject obj, jclass clazz)
{
    AudioTrack *track = (AudioTrack*)obj;
    if (track->nativeTrack) {
        // Android's AudioTrack.release() frees the underlying resources and the
        // object must not be used afterwards, so free the slot. The existing SDL
        // mapping only cleared the queue and never closed -- harmless with SDL,
        // where devices are cheap, but MISTER_AUDIO_MAX_TRACKS is 4, so never
        // closing would exhaust the table after the 4th AudioTrack a game
        // creates and silently kill all later audio.
        MisterAudio_Close(track->nativeTrack);
        track->nativeTrack = 0;
    } else {
        SDL_ClearQueuedAudio(track->deviceId);
    }
}
```

**Why this differs from the other four call sites**, which preserve existing
behaviour exactly: `jni/classes/media_AudioTrack.cpp` has no destructor and calls
`SDL_CloseAudioDevice` nowhere, so today every `AudioTrack` leaks its device for
the process lifetime. SDL tolerates that; a fixed 4-slot table does not. Mapping
`release()` to `Close` is also closer to real Android semantics than the current
clear-only mapping.

The residual risk is a runner that keeps using an `AudioTrack` after calling
`release()` — already undefined behaviour on Android. That degrades safely here:
`track_of()` returns `nullptr` for a freed slot, so `Queue`/`Pause`/`QueuedBytes`
on a stale handle are inert no-ops rather than crashes or cross-track writes. If
device testing in Task 8 shows audio stopping after a scene change, this mapping
is the first thing to suspect — revert it to `MisterAudio_Clear` and raise
`MISTER_AUDIO_MAX_TRACKS` instead.

In `write` (the 4-arg overload), replace the `SDL_QueueAudio` call and the blocking-wait loop:

```cpp
    int ret;
    if (track->nativeTrack)
        ret = MisterAudio_Queue(track->nativeTrack, (void*)where, sizeInBytes);
    else
        ret = SDL_QueueAudio(track->deviceId, (void*)where, sizeInBytes);

    if (track->playing == 0)
        AudioTrack::play(env, obj, clazz);

    if (writeMode == WRITE_BLOCKING) {
        // Waits on STAGING only -- audio already moved into the DDR ring counts
        // as consumed, so the ring stays the latency cushion and the runner
        // paces against the real 48 kHz drain.
        do {
            SDL_Delay(0);
        } while (track->nativeTrack
                    ? MisterAudio_QueuedBytes(track->nativeTrack)
                    : SDL_GetQueuedAudioSize(track->deviceId));
    }
```

- [ ] **Step 2: Route video_ffmpeg**

In `$GM/gmloader/video_ffmpeg.cpp`, add `#include "mister/mister_native_audio.h"` to the includes, add a file-scope `static MisterAudioTrack video_audiotrack = 0;`, then replace line 152:

```cpp
    video_audiotrack = MisterAudio_IsActive()
        ? MisterAudio_Open(&wanted_spec, &audio_spec) : 0;
    video_audiodev = video_audiotrack
        ? 0 : SDL_OpenAudioDevice(NULL, 0, &wanted_spec, &audio_spec, 0);
    if (video_audiotrack) MisterAudio_Pause(video_audiotrack, 0);
    else SDL_PauseAudioDevice(video_audiodev, 0);
```

and replace the `SDL_QueueAudio(video_audiodev, video_audiobuf, ret);` at line 309:

```cpp
                if (video_audiotrack)
                    MisterAudio_Queue(video_audiotrack, video_audiobuf, ret);
                else
                    SDL_QueueAudio(video_audiodev, video_audiobuf, ret);
```

The file has exactly four other `video_audiodev` uses. Give each the same two-branch treatment:

```cpp
// line 173 — teardown
    if (video_audiotrack) MisterAudio_Close(video_audiotrack);
    else SDL_CloseAudioDevice(video_audiodev);

// line 178 — reset the handle (add the track alongside)
    video_audiodev = NULL;
    video_audiotrack = 0;

// line 189 — pause
    if (video_audiotrack) MisterAudio_Pause(video_audiotrack, 1);
    else SDL_PauseAudioDevice(video_audiodev, 1);

// line 199 — resume
    if (video_audiotrack) MisterAudio_Pause(video_audiotrack, 0);
    else SDL_PauseAudioDevice(video_audiodev, 0);

// line 305 — backlog query that paces the decoder
    int queued = video_audiotrack
        ? (int)MisterAudio_QueuedBytes(video_audiotrack)
        : SDL_GetQueuedAudioSize(video_audiodev);
```

- [ ] **Step 3: Route FMOD_SDL — SKIPPED, verified not in the build**

Pre-flight check discharged the plan's own condition ("check `USE_FMOD` in the build
before spending time on it"): the MiSTer Docker recipe passes only `ARCH`,
`MISTER_BUILD=1` and `MISTER_NATIVE_VIDEO=1` — never `USE_FMOD=1` — so the
`ifeq (${USE_FMOD},1)` block at `Makefile.gmloader:100-106` never fires, and
`3rdparty/fmod` is not even checked out. `gmloader/fmod.cpp:1` is `#ifdef USE_FMOD`,
so the whole FMOD path compiles to nothing on MiSTer.

Skip this step. Do not edit `3rdparty/FMOD_SDL/FMOD_SDL.c` and do not touch that
submodule. The shim's pull-track support (Task 3) stays — it costs nothing and is
what a future `USE_FMOD=1` build would need — but no call site is wired to it now.

<details><summary>Retained for a future FMOD-enabled build (not part of this plan)</summary>

`$GM/3rdparty/FMOD_SDL/FMOD_SDL.c` is C and vendored. Add `#include "mister_native_audio.h"` after the existing includes, add `MisterAudioTrack native;` to the `FMOD_SDL_Device` struct, and replace the `SDL_OpenAudioDevice` at line 288:

```c
	device->native = MisterAudio_IsActive() ? MisterAudio_Open(&want, &have) : 0;
	device->device = device->native ? 0 : SDL_OpenAudioDevice(
		(selecteddriver == 0) ?
			NULL :
			SDL_GetAudioDeviceName(selecteddriver - 1, 0),
		0,
		&want,
		&have,
		(
			SDL_AUDIO_ALLOW_FREQUENCY_CHANGE |
			SDL_AUDIO_ALLOW_CHANNELS_CHANGE |
			SDL_AUDIO_ALLOW_FORMAT_CHANGE
		)
	);
```

`want.callback` is already set at line 280, so `MisterAudio_Open` classifies this as a pull track and the pump drives `FMOD_SDL_MixCallback` — no other change to FMOD's data flow. Three other `device->device` uses need the two-branch treatment:

```c
/* line 301 — the open-failed check must not reject a native track (0 is a
   valid device->device value once native is in use). */
	if (!device->native && device->device < 0)

/* lines 324 and 342 — teardown, both sites identical */
	if (device->native) MisterAudio_Close(device->native);
	else SDL_CloseAudioDevice(device->device);
```

Also unpause after open: FMOD expects the device running, so add
`if (device->native) MisterAudio_Pause(device->native, 0);` next to the existing
`SDL_PauseAudioDevice` call that follows the open.

</details>

- [ ] **Step 4: Initialise the shim in main.cpp**

In `$GM/gmloader/main.cpp`, add `#include "mister/mister_native_audio.h"`, then immediately **before** the `SDL_Init` at line 506:

```cpp
#ifdef MISTER_NATIVE_VIDEO
    // The FPGA owns the audio path; MiSTer's Linux has no sound card. Pin SDL
    // to the dummy driver so SDL_Init can neither fail for want of a device
    // nor grab one, then bring the DDR ring up.
    setenv("SDL_AUDIODRIVER", "dummy", 1);
#endif
```

and immediately **after** the successful `SDL_Init`:

```cpp
#ifdef MISTER_NATIVE_VIDEO
    fprintf(stderr, "SDL audio driver: %s\n",
            SDL_GetCurrentAudioDriver() ? SDL_GetCurrentAudioDriver() : "(none)");
    if (!MisterAudio_Init())
        warning("MisterAudio: /dev/mem unavailable, using SDL fallback\n");
#endif
```

Then at `main.cpp:847`, immediately before `SDL_Quit();`:

```cpp
#ifdef MISTER_NATIVE_VIDEO
    MisterAudio_Shutdown();
#endif
    SDL_Quit();
```

- [ ] **Step 5: Add the shim to the MiSTer build**

In `$GM/Makefile.gmloader:129`, add `gmloader/mister/mister_native_audio.cpp` to `MISTER_SRCS`, right after `native_audio_writer.c`.

- [ ] **Step 6: Verify the host tests still pass**

Run:
```bash
cd $GM
make -f Makefile.gmloader native-audio-writer-test
make -f Makefile.gmloader native-audio-shim-test
make -f Makefile.gmloader joy-shm-test
```
Expected: three `RESULT: PASS` lines, all exit 0.

- [ ] **Step 7: Cross-build for armhf**

Run:
```bash
cd $GM
/opt/homebrew/bin/docker build -f Dockerfile.gmloader-build -t gmloader-armhf-build:bullseye .
/opt/homebrew/bin/docker run --rm -v "$(pwd):/src" -w /src \
  gmloader-armhf-build:bullseye \
  make -f Makefile.gmloader ARCH=arm-linux-gnueabihf MISTER_BUILD=1 \
    MISTER_NATIVE_VIDEO=1 \
    "LLVM_INC=/usr/arm-linux-gnueabihf/include /usr/arm-linux-gnueabihf/include/c++/10/arm-linux-gnueabihf" \
    -j"$(nproc)"
ls -l build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf
```
Expected: a clean build producing `gmloadernext.armhf`. Warnings are acceptable; errors are not.

- [ ] **Step 8: Commit**

```bash
cd $GM
git add jni/classes/media_AudioTrack.cpp jni/classes/media_AudioTrack.h \
        gmloader/video_ffmpeg.cpp gmloader/main.cpp Makefile.gmloader
git commit -m "feat(mister): route AudioTrack and ffmpeg audio into the DDR ring"
```

`3rdparty/FMOD_SDL` must be untouched — confirm with `git status --short 3rdparty/`
before committing.

---

### Task 6: RTL — absolute audio map, un-gate, wire to AUDIO_L/R

**Files:**
- Modify: `$MAL/fpga/rtl/openbor_video_reader.sv:159-160`, `:164`, `:436-438`
- Modify: `$MAL/fpga/Maldita.sv:805-810`, `:1046`, `:1086-1089`
- Test: `$MAL/fpga/sim/tb_audio_burst_wedge.sv` (no edit needed — it already targets `29'h0741A000`)

**Interfaces:**
- Consumes: the ring geometry from Task 1 — `0x3A000030` / `0x3A000038` / `0x3A0D0000`, 64 KiB.
- Produces: a core whose `AUDIO_L`/`AUDIO_R` are driven by the reader's audio FIFO.

`audio_wake` at line 438 is the **only** gate: line 617 dispatches `ST_POLL_AUDIO_WR` on it with no further condition. `SCANOUT_ONLY` keeps gating the ioctl/cart and vsync-writeback paths and must not be removed.

- [ ] **Step 1: Run the audio testbench first, to see it pass against the gated design**

Run: `cd $MAL/fpga/sim && ./run_sims.sh tb_audio_burst_wedge`
Expected: PASS. This is the baseline — the bench instantiates the reader directly, so it exercises the audio FSM even though `Maldita.sv` gates it.

- [ ] **Step 2: Make the audio addresses absolute**

In `$MAL/fpga/rtl/openbor_video_reader.sv`, replace lines 159-160:

```systemverilog
// [audio-map] The audio triplet is ABSOLUTE, not FB_QW_BASE-relative: it is the
// shared map Solarus and OpenBOR use (openbor_video_reader.sv:144-158 there), so
// all three ports agree and a future framebuffer relocation cannot strand the
// ring outside the host's mapped window again.
localparam [28:0] AUDIO_WR_ADDR   = 29'h07400006;  // 0x3A000030
localparam [28:0] AUDIO_RD_ADDR   = 29'h07400007;  // 0x3A000038
```

and line 164:

```systemverilog
localparam [28:0] AUDIO_RING_ADDR = 29'h0741A000; // 0x3A0D0000, 64 KiB ring
```

- [ ] **Step 3: Un-gate the audio fetch**

In the same file, replace lines 436-438:

```systemverilog
// [audio-map] The ring is back at its absolute address and inside the host's
// mapping, so SCANOUT_ONLY no longer gates this path. SCANOUT_ONLY still gates
// the ioctl/cart and vsync-writeback paths -- do not remove it there.
wire        audio_wake        = enable_ddr && audio_fifo_low && (audio_backoff == 20'd0);
```

- [ ] **Step 4: Wire the core outputs**

In `$MAL/fpga/Maldita.sv`, replace lines 805-810:

```systemverilog
// [native-audio] The FPGA owns the audio path again: openbor_video_reader drains
// the DDR3 ring the HPS loader fills (0x3A0D0000) into a dual-clock FIFO on
// CLK_AUDIO. MT32pi I2S capture stays retired.
wire [15:0] nv_audio_l, nv_audio_r;
assign AUDIO_L = nv_audio_l;
assign AUDIO_R = nv_audio_r;
assign AUDIO_S = 1;
```

and replace lines 1086-1089 in the `u_reader` instantiation:

```systemverilog
	// native audio: DDR3 ring -> dual-clock FIFO -> AUDIO_L/R
	.clk_audio      (CLK_AUDIO),
	.audio_l        (nv_audio_l),
	.audio_r        (nv_audio_r),
```

Also update the stale comment at `Maldita.sv:1069` (`ioctl/audio HPS-I/O DEFERRED — tied off (SCANOUT_ONLY gates the audio path internally)`) to read `ioctl HPS-I/O DEFERRED — tied off; audio is LIVE (absolute ring map)`.

- [ ] **Step 5: Re-run the audio testbench**

Run: `cd $MAL/fpga/sim && ./run_sims.sh tb_audio_burst_wedge`
Expected: PASS — the short-burst wedge guard (`TIMEOUT_MAX` armed at `openbor_video_reader.sv:958`) still recovers with the new addresses.

- [ ] **Step 6: Run the full sim suite to check the arbiter interaction**

Run: `cd $MAL/fpga/sim && ./run_sims.sh`
Expected: the same PASS/FAIL set as before the change. Re-enabling the audio FSM adds a DDR consumer that shares `ddr_blitter_arb` with scanout and the blitter, so the scanout benches are the real gate here — any new failure in `tb_scanout_*` or `tb_blitter_system_pipe` means the audio traffic is stealing line-fetch bandwidth and must be resolved before building a bitstream. `tb_profile` is SKIP and `tb_comp_replay` / `tb_blitter_trilist_sdram` are NONGATING; ignore those.

- [ ] **Step 7: Commit**

```bash
cd $MAL
git add fpga/rtl/openbor_video_reader.sv fpga/Maldita.sv
git commit -m "rtl: absolute audio ring map, un-gate the audio FSM, drive AUDIO_L/R"
```

---

### Task 7: Build the RBF and check timing

**Files:**
- No source changes. Consumes Task 6's commit.

**Interfaces:**
- Consumes: the `feat/native-audio` branch of `maldita.castilla-mister`.
- Produces: `_Other/MalditaCastilla_<date>.rbf` for Task 8.

- [ ] **Step 1: Push the branch so the runner can see it**

```bash
cd $MAL && git push -u origin feat/native-audio
```

- [ ] **Step 2: Dispatch the Windows Quartus build**

The canonical build is the self-hosted Windows runner (`.github/workflows/build-rbf.yml:61`, `runs-on: [self-hosted, windows]`). The Linux Docker job in the same workflow is a fallback and must not be substituted.

```bash
cd $MAL
gh workflow run build-rbf.yml --ref feat/native-audio
gh run watch
```
Expected: the `self-hosted, windows` job succeeds and uploads the `maldita-rbf` artifact.

- [ ] **Step 3: Compare timing against the current build**

Download the `quartus-reports` artifact and read the STA summary.

```bash
cd $MAL
gh run download --name quartus-reports --dir /tmp/qr-audio
grep -rn "Slack" /tmp/qr-audio | head -20
```
Expected: worst-case setup slack no worse than the pre-audio baseline for this branch's base commit. The audio FSM adds states and a DDR consumer to an already tight design, so a *pass* is not sufficient — record the number and compare. If slack regresses materially, stop and report before deploying; do not proceed to the device on a marginal fit.

- [ ] **Step 4: Fetch the RBF**

```bash
cd $MAL
gh run download --name maldita-rbf --dir _Other/
ls -l _Other/MalditaCastilla_*.rbf
```

- [ ] **Step 5: Commit the RBF if the repo tracks it**

```bash
cd $MAL
git status --short _Other/
# If the new RBF shows as untracked and siblings are tracked:
git add _Other/MalditaCastilla_*.rbf
git commit -m "rbf: native audio build"
```

---

### Task 8: Device verification on the superstation (.81)

**Files:**
- No source changes.

**Interfaces:**
- Consumes: Task 5's `gmloadernext.armhf` and Task 7's RBF.
- Produces: the acceptance evidence.

**Target changed by the project owner (2026-07-27):** `root@192.168.20.81`, the
superstation / bench unit — **not** `.62`. This is `deploy.py:74`'s default
`HOST`, so no `--host` override is needed. It also carries the existing bench
harness (`scripts/mister_run.sh`) used for timed A/B runs, which suits the fps
gate better than `.62` did.

The unit must be **fully configured to launch Maldita Castilla via the
Master_Daemon handler, not by replacing `Main_MiSTer`.** Step 0 establishes that
before anything is measured.

- [ ] **Step 0: Configure daemon launch and confirm it is the active mechanism**

MiSTer's Master_Daemon (Frontier) watches `/tmp/CORENAME` and runs
`/media/fat/games/Maldita Castilla/_handler.sh` when the core loads. The older
mechanism — a `main=` line under `[Maldita Castilla]` in `MiSTer.ini` — REPLACED
`Main_MiSTer` and did not honour its FPGA-readiness contract. `deploy.py`
comments out any such line automatically, but verify rather than assume:

```bash
ssh root@192.168.20.81 "grep -n -A3 '\[Maldita Castilla\]' /media/fat/MiSTer.ini; \
  ls -l '/media/fat/games/Maldita Castilla/_handler.sh'; \
  pgrep -a Master_Daemon"
```

Expected: any `main=` line is commented out or absent; `_handler.sh` exists and is
executable; `Master_Daemon` is running. If `_handler.sh` is missing, the deploy in
Step 1 installs it — re-run this check afterwards and do not proceed until all
three hold.

Per project memory, handler launch has previously dropped the joy-shm input
bridge, which needs three legs alive (producer, shm file, reader). Input is not
required for the title-screen audio gate, so a dead pad does **not** block this
task — but note it in the results rather than silently working around it.

- [ ] **Step 1: Deploy, pointing explicitly at the worktree binary**

`deploy.py:88` defaults `ENGINE_DEFAULT` to the *sibling* `gmloader-next` checkout,
which is not this worktree. Pass `--engine` or the wrong binary ships.

```bash
cd $MAL
./deploy.py --no-content \
  --engine /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-audio/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf
```

- [ ] **Step 2: Verify the deployed binary is the one just built**

```bash
md5 /Users/gmcnaught/MisterFPGA-Projects/wt-gmloader-audio/build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf
ssh root@192.168.20.81 "md5sum /media/fat/games/Maldita\ Castilla/gmloader"
```
Expected: identical digests. If they differ, the deploy picked up a stale engine — fix before drawing any conclusion from the run.

- [ ] **Step 3: Load the core and confirm the audio path came up**

Load the core from the MiSTer menu (do not ssh-launch the engine — an ssh-launched run dies on disconnect). Then read the log:

```bash
ssh root@192.168.20.81 "tail -40 /tmp/gmloader.log"
```
Expected, in order: `SDL audio driver: dummy`, `NativeAudioWriter: ring 65536 bytes @ 0x3A0D0000, wr=0x3A000030, rd=0x3A000038`, `MisterAudio: native audio active (48000 Hz stereo S16)`, `MisterAudio: pump pinned to core 1, main to core 0`, and a `MisterAudio: track 1 open (... push)` once the game starts producing sound.

- [ ] **Step 4: Gate 1 — audible**

Listen at the title screen. Expected: music audible and clean — no crackle, no dropouts, no wrong pitch. The game-not-progressing blocker keeps in-game scenes out of reach; the title screen is the gate.

- [ ] **Step 5: Gate 2 — ring health**

```bash
ssh root@192.168.20.81 "for i in 1 2 3 4 5; do echo -n 'wr='; busybox devmem 0x3A000030; echo -n 'rd='; busybox devmem 0x3A000038; sleep 1; done"
```
Expected: both advance and wrap, with a roughly steady gap of ~19200 bytes (4800 frames × 4). A gap collapsing toward 0 means the pump is losing to the drain; a gap pinned at the ring size means the FPGA is not draining.

- [ ] **Step 6: Gate 3 — thread placement**

```bash
ssh root@192.168.20.81 "top -H -b -n 1 | head -20"
```
Expected: two gmloader threads, one showing load on CPU 1 (the pump) and the game thread on CPU 0. This is also the measurement that confirms or refutes the plan's assumption that core 1 was idle.

- [ ] **Step 7: Gate 4 — fps A/B**

Record fps with audio enabled, then with the shim disabled (rename `/dev/mem` access is not an option, so use the pin knob and a fallback run):

```bash
# A: audio on, pinned (as deployed)
ssh root@192.168.20.81 "grep -a 'fps=' /tmp/gmloader.log | tail -20"
# B: audio on, unpinned
ssh root@192.168.20.81 "echo 'GMLOADER_AUDIO_PIN=0' >> '/media/fat/games/Maldita Castilla/diag.env'"
# reload the core, then re-read fps
```
Expected: A within scene-to-scene variation of the pre-audio baseline (~13 fps). If audio costs frames, try `GMLOADER_MFGPU_POLL_US=250` in `diag.env` — a pre-measured lever that cut poll traffic 12× for ~2 ms of frame time.

- [ ] **Step 8: Gate 5 — clean shutdown**

Swap to another core from the MiSTer menu, then back.
Expected: no hang. The pump is joined before the mapping is torn down, so a hang here points at the shutdown ordering in Task 4.

- [ ] **Step 9: Record the results**

Append the five gate outcomes, the fps numbers, and the STA slack from Task 7 to `$MAL/docs/superpowers/plans/2026-07-27-gmloader-native-audio-results.md` and commit. If any gate failed, record what failed and stop — do not bump submodule pins on a failing device run.

---

### Task 9: Bump the superproject pins

**Files:**
- Modify: `mister-gmloader/external/gmloader-next` (submodule pin)
- Note: `maldita.castilla-mister` is not a submodule of `mister-gmloader`; only `gmloader-next` and `mister-fpga-blitter` are (`.gitmodules`).

**Interfaces:**
- Consumes: merged `feat/native-audio` branches from Tasks 5 and 6, and a passing Task 8.

- [ ] **Step 1: Merge both feature branches**

```bash
cd $GM && git push -u origin feat/native-audio
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next && gh pr create \
  --base master --head feat/native-audio \
  --title "feat(mister): native audio via DDR3 ring" \
  --body "Implements docs/superpowers/specs/2026-07-27-gmloader-native-audio-design.md"

cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister && gh pr create \
  --base master --head feat/native-audio \
  --title "rtl: absolute audio ring map, un-gate the audio FSM" \
  --body "Implements docs/superpowers/specs/2026-07-27-gmloader-native-audio-design.md"
```

- [ ] **Step 2: Bump the pin**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git submodule update --remote external/gmloader-next
git add external/gmloader-next
git commit -m "bump: gmloader-next native audio (DDR3 ring)"
```

- [ ] **Step 3: Verify the pin moved to the merged commit**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/mister-gmloader
git submodule status external/gmloader-next
cd external/gmloader-next && git log --oneline -1
```
Expected: the pin is the merge commit on `gmloader-next`'s `master`, not a feature-branch commit.

- [ ] **Step 4: Clean up the worktrees**

```bash
cd /Users/gmcnaught/MisterFPGA-Projects/gmloader-next && git worktree remove $GM
cd /Users/gmcnaught/MisterFPGA-Projects/maldita.castilla-mister && git worktree remove $MAL
```

---

## Known risks

- **Pull-track callback runs while `g_lock` is held** (`mister_native_audio.cpp`, `fill_pull_track` call site). A re-entrant callback — one that called back into any `MisterAudio_*` function — would deadlock on the non-recursive mutex. Inert today: `pull` is only set when `desired->callback != nullptr`, and FMOD, the only pull producer, is dropped from this plan (`USE_FMOD` is never set in the MiSTer build), so no code path reaches `fill_pull_track` at all. **This must be resolved before any future task wires a real pull producer** — either by snapshotting the track under the lock and invoking the callback unlocked, or by documenting a hard no-reentrancy contract on the callback. Raised independently by the Task 3 implementer and reviewer.

- **Arbiter bandwidth.** Re-enabling the audio FSM puts a third consumer on `ddr_blitter_arb` alongside scanout and the blitter, on a path already readback-bound at ~13 fps. Task 6 Step 6 is the early warning; Task 8 Step 7 is the measurement.
- ~~**`3rdparty/FMOD_SDL` is a submodule.**~~ Resolved pre-flight: `USE_FMOD` is never set in the MiSTer build, `3rdparty/fmod` is absent, and `gmloader/fmod.cpp` is `#ifdef USE_FMOD`. Task 5 Step 3 is skipped and the submodule stays untouched.
- **Paused tracks and `WRITE_BLOCKING`.** The pump does not drain paused tracks, so a caller that queues to a paused track and then blocks on `QueuedBytes` would spin forever. This exactly matches SDL's own behaviour, and `AudioTrack::write` calls `play()` before it blocks, so the path is safe today — but it is the failure mode to suspect if the game ever hangs in an audio write.

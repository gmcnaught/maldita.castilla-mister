# MFGPU Device-Ring Vertical Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `backend_mfgpu` render on the real FPGA fabric — publish the emitted command ring to DDR `0x3B000000`, stage one texture (`OP_STAGE`, DDR→SDRAM same-offset), emit one `OP_TRILIST`, bump `submit_seq`, poll `done_seq` (`C_DONE`) — and verify the fabric-composited frame on-device.

**Architecture:** A new self-contained `blt_device` module (`gmloader/mister/blt_device.{c,h}`) `mmap`s `/dev/mem` at `0x3B000000` and performs the `blitter-protocol.md` §3 handshake. `backend_mfgpu`'s emit path is unchanged; under `#ifdef MISTER_BUILD` its terminal `mf_frame_end` calls `blt_device_submit` instead of the software `blt_execute` (which survives only as the host-test oracle), and its `stage_texture` miss-path additionally emits `blt_stage(off,size)` so the fabric's SDRAM texel fetch resolves. `main.cpp` skips the NativeVideoWriter handoff for the fabric path (the core scans out its own on-chip BRAM).

**Tech Stack:** C11 + C++17, `gmloader/mister/*`, vendored `3rdparty/mfgpu` (mfgpu-fork of `mister-fpga-blitter`, `OP_TRILIST=10`), armhf cross-build via `gmloader-armhf-build:bullseye` Docker, MiSTer DE10-Nano at `192.168.20.81`, core RBF `maldita.castilla-mister` branch `milestone-a`.

## Global Constraints

- **Work in `external/gmloader-next`** on branch `mister-sdl-buffer-output` (the MiSTer-integrated branch; `master` lacks MiSTer integration and will not build). After device work, bump the `external/gmloader-next` submodule pointer in `mister-gmloader`.
- **Device wire contract (verified against `maldita.castilla-mister/fpga/rtl` @ `milestone-a`):** control block base `0x3B000000`; ring `0x3B000040` (32 B/cmd, walk-until-`OP_END`); DDR source heap `SRC_QW = 0x3B080000`; device DDR heap window ends at `0x3BF40000` (**15,466,496 bytes** usable). Control qwords (one u32 in the low 32 bits of each 8-byte qword): `submit_seq`@0, `cmd_count`@1, `target_buf`@2, `clear_color`@3, `flags`@4, `done_seq`@5 (`C_DONE`), `status`@6. Hi-32 of `C_DONE` = `perf_frame_cyc`, hi-32 of `C_STATUS` = `perf_pipe_cyc` (diagnostic only).
- **Handshake:** write ring + heap + `cmd_count`/`target`/`clear`/`flags`, then write `submit_seq` **last** with a store-release barrier; poll `done_seq` until `== submit_seq`. On this core `C_STATUS` low-32 is OSD-mirror bits, **not** an error latch — completion = `done_seq` match; failure = timeout.
- **Texture source is SDRAM, unconditional.** `OP_TRILIST` fetches texels from SDRAM at byte offset `= src_off = tex.off` (not gated on `C_SRCSEL` or any flag). Vertices are read from DDR at `SRC_QW + entry_off` (no staging). Therefore the device path MUST emit **`blt_stage(tex.off, size)`** (same-offset: `SDRAM[off]=DDR[SRC_QW+off]`) before the `blt_trilist` whose `src_off == tex.off` — **never** `blt_stage_surface`/`blt_stage_to` (decoupled `sdram_off` mismatches the emitter's `src_off=tex.off` → renders black).
- **`backend_sw` and the host parity battery stay byte-identical.** The device path is entirely under `#ifdef MISTER_BUILD`; the host build keeps `blt_execute` as the oracle so `raster_backend_test.cpp` is unchanged and still passes.
- **Proven `/dev/mem` mmap pattern (mirror `gmloader/mister/native_video_writer.c`):** `open("/dev/mem", O_RDWR | O_SYNC)`; `mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, fd, phys_base)`; `volatile` pointers into the map; strongly-ordered device memory (O_SYNC + MAP_SHARED) gives ARM store ordering, and we add an explicit `__sync_synchronize()` before the doorbell.
- **Design note (deviation from spec §5.1):** `blt_device` lives in `gmloader/mister/`, not the mfgpu submodule — it is MiSTer-specific `/dev/mem` I/O following the `native_video_writer.c` precedent, not engine-agnostic emitter code, and this avoids submodule-commit coupling.
- **armhf link recipe (per task that builds):**
  ```bash
  /opt/homebrew/bin/docker run --rm -v "$(pwd):/src" -w /src gmloader-armhf-build:bullseye bash -c '
    touch thunks/thunk_gen_dyn.h
    make -f Makefile.gmloader ARCH=arm-linux-gnueabihf MISTER_BUILD=1 MISTER_NATIVE_VIDEO=1 \
      "LLVM_INC=/usr/arm-linux-gnueabihf/include /usr/arm-linux-gnueabihf/include/c++/10/arm-linux-gnueabihf" \
      -j$(nproc)'
  # Artifact: build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf
  ```

---

## Task 1: Initialize the mfgpu submodule + baseline host tests green

**Files:**
- Modify (checkout only): `external/gmloader-next/3rdparty/mfgpu` (submodule, currently an uninitialized gitlink)

**Interfaces:**
- Produces: a working tree where `3rdparty/mfgpu/host/blt_emitter.h`, `blt_wire.h`, `refmodel/blitter_ref.h` resolve (so later tasks compile), and the existing host test target passes as a baseline.

- [ ] **Step 1: Initialize the submodule**

Run (from `external/gmloader-next`):
```bash
git submodule update --init 3rdparty/mfgpu
```
Expected: `3rdparty/mfgpu` populates with `host/`, `refmodel/`, `libmfgpu/`. If network to `git@github.com:gmcnaught/mister-fpga-blitter.git` is unavailable, ask the user to init it (it is required to build).

- [ ] **Step 2: Confirm the ABI constants are present**

Run:
```bash
grep -nE 'BLT_OP_TRILIST|BLT_OP_STAGE|BLT_CMD_BYTES' 3rdparty/mfgpu/refmodel/blitter_ref.h 3rdparty/mfgpu/host/blt_wire.h
```
Expected: `BLT_OP_TRILIST = 10`, `BLT_OP_STAGE = 4`, and `BLT_CMD_BYTES` defined (32). This confirms the checked-out commit matches the RTL contract.

- [ ] **Step 3: Baseline host test**

Run:
```bash
make -f Makefile.gmloader raster-backend-test
```
Expected: the existing battery prints all-pass (sw-equivalence, clear-parity, TRILIST, colorkey, FBO fallback, cache/eviction). This is the regression baseline the device work must not disturb.

- [ ] **Step 4: Commit** (only if the submodule pointer changed; a bare `--init` of the pinned commit needs no commit)

```bash
git add 3rdparty/mfgpu
git commit -m "chore: initialize 3rdparty/mfgpu submodule for device-ring work" || echo "nothing to commit"
```

---

## Task 2: `blt_device` transport module (host-testable)

**Files:**
- Create: `external/gmloader-next/gmloader/mister/blt_device.h`
- Create: `external/gmloader-next/gmloader/mister/blt_device.c`
- Create: `external/gmloader-next/gmloader/mister/blt_device_test.c`
- Modify: `external/gmloader-next/Makefile.gmloader` (add a `blt-device-test` host target)

**Interfaces:**
- Consumes: `blt_emitter_t` (`3rdparty/mfgpu/host/blt_emitter.h`), `BLT_CMD_BYTES` (`blt_wire.h`).
- Produces:
  - `int blt_device_open(blt_device_t *d);` — mmap `/dev/mem` @ `0x3B000000` (16 MiB); returns `0` or `-errno`.
  - `int blt_device_open_at(blt_device_t *d, void *region, size_t size);` — test seam; use a caller region instead of `/dev/mem`.
  - `int blt_device_submit(blt_device_t *d, const blt_emitter_t *e, uint32_t heap_len, int timeout_ms);` — publish ring + `heap[0,heap_len)`, write control block, bump `submit_seq`, poll `done_seq`. Returns `0`, `-ETIMEDOUT`, or `-ENOSPC`.
  - `void blt_device_close(blt_device_t *d);`

- [ ] **Step 1: Write the header** — `gmloader/mister/blt_device.h`

```c
#ifndef BLT_DEVICE_H
#define BLT_DEVICE_H
/* MiSTer /dev/mem transport for the mfgpu fabric command ring (0x3B000000).
 * Publishes a blt_emitter_t's ring + source heap to DDR and drives the
 * submit_seq/done_seq doorbell handshake (docs/blitter-protocol.md §3). */
#include <stddef.h>
#include <stdint.h>
#include "blt_emitter.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int               fd;        /* /dev/mem fd, or -1 for a test region        */
    volatile uint8_t *base;      /* mapped 16 MiB block @ 0x3B000000            */
    size_t            size;      /* mapped size                                 */
    int               owns_map;  /* 1 => munmap on close; 0 => caller-owned     */
} blt_device_t;

int  blt_device_open(blt_device_t *d);
int  blt_device_open_at(blt_device_t *d, void *region, size_t size);
int  blt_device_submit(blt_device_t *d, const blt_emitter_t *e,
                       uint32_t heap_len, int timeout_ms);
void blt_device_close(blt_device_t *d);

#ifdef __cplusplus
}
#endif
#endif /* BLT_DEVICE_H */
```

- [ ] **Step 2: Write the failing test** — `gmloader/mister/blt_device_test.c`

```c
/* Host unit test for blt_device: exercises the publish/handshake mechanics over
 * a malloc'd region (no /dev/mem, no fabric). A "fabric" that completes is
 * simulated by pre-setting done_seq == the submit value the transport will
 * write, so the poll matches immediately; the timeout path leaves it stale. */
#include "blt_device.h"
#include "blt_wire.h"     /* BLT_CMD_BYTES */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

/* Mirror the control-block qword indices (low u32 of each 8-byte qword). */
enum { QW_SUBMIT=0, QW_CMDCOUNT=1, QW_CLEAR=3, QW_FLAGS=4, QW_DONE=5 };
#define OFF_RING 0x40u
#define OFF_HEAP 0x80000u

static uint32_t rd32(const uint8_t *base, int qw) {
    uint32_t v; memcpy(&v, base + (size_t)qw * 8, 4); return v;
}

static int test_publish_and_complete(void) {
    enum { REGION = 0x90000 };                 /* 576 KiB: ctrl+ring+a little heap */
    uint8_t *region = (uint8_t *)calloc(1, REGION);

    /* Build a tiny ring: one FILL + END, via a real emitter. */
    static uint8_t ring[4096]; static uint8_t heap[4096]; static uint8_t vtx[1024];
    blt_emitter_t e; blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_vtx_buf_init(&e, vtx, sizeof vtx);
    blt_begin_frame(&e, 0, 0, 0);
    blt_fill(&e, 0, 0, 8, 8, 0xF800);          /* red fill */
    blt_end_frame(&e);                         /* appends END, bumps submit_seq to 1 */

    blt_device_t d;
    if (blt_device_open_at(&d, region, REGION) != 0) { printf("open_at FAIL\n"); return 0; }

    /* Simulate a fabric that will have completed: pre-set done_seq to the value
     * submit will write (e.submit_seq). */
    memcpy(region + (size_t)QW_DONE * 8, &e.submit_seq, 4);

    int rc = blt_device_submit(&d, &e, /*heap_len=*/64, /*timeout_ms=*/50);
    if (rc != 0) { printf("submit rc=%d FAIL\n", rc); return 0; }

    /* Ring bytes landed at OFF_RING. */
    if (memcmp(region + OFF_RING, ring, (size_t)e.cmd_count * BLT_CMD_BYTES) != 0) {
        printf("ring bytes mismatch FAIL\n"); return 0; }
    /* Control fields written. */
    if (rd32(region, QW_CMDCOUNT) != (uint32_t)e.cmd_count) { printf("cmd_count FAIL\n"); return 0; }
    if (rd32(region, QW_SUBMIT)   != e.submit_seq)          { printf("submit FAIL\n");    return 0; }
    blt_device_close(&d);
    free(region);
    return 1;
}

static int test_timeout(void) {
    enum { REGION = 0x90000 };
    uint8_t *region = (uint8_t *)calloc(1, REGION);
    static uint8_t ring[4096]; static uint8_t heap[4096]; static uint8_t vtx[1024];
    blt_emitter_t e; blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_vtx_buf_init(&e, vtx, sizeof vtx);
    blt_begin_frame(&e, 0, 0, 0); blt_fill(&e, 0, 0, 8, 8, 0xF800); blt_end_frame(&e);
    blt_device_t d; blt_device_open_at(&d, region, REGION);
    /* done_seq left at 0 != submit_seq(1) => must time out. */
    int rc = blt_device_submit(&d, &e, 64, /*timeout_ms=*/2);
    blt_device_close(&d); free(region);
    if (rc != -ETIMEDOUT) { printf("expected -ETIMEDOUT got %d FAIL\n", rc); return 0; }
    return 1;
}

static int test_heap_window(void) {
    enum { REGION = 0x90000 };
    uint8_t *region = (uint8_t *)calloc(1, REGION);
    static uint8_t ring[4096]; static uint8_t heap[4096]; static uint8_t vtx[1024];
    blt_emitter_t e; blt_emitter_init(&e, ring, sizeof ring, heap, sizeof heap);
    blt_vtx_buf_init(&e, vtx, sizeof vtx);
    blt_begin_frame(&e, 0, 0, 0); blt_fill(&e, 0, 0, 8, 8, 0xF800); blt_end_frame(&e);
    blt_device_t d; blt_device_open_at(&d, region, REGION);
    /* heap_len beyond the device window must be rejected. */
    int rc = blt_device_submit(&d, &e, /*heap_len=*/16u*1024*1024, /*timeout_ms=*/2);
    blt_device_close(&d); free(region);
    if (rc != -ENOSPC) { printf("expected -ENOSPC got %d FAIL\n", rc); return 0; }
    return 1;
}

int main(void) {
    if (!test_publish_and_complete()) { printf("blt_device: publish/complete FAIL\n"); return 1; }
    if (!test_timeout())              { printf("blt_device: timeout FAIL\n");          return 1; }
    if (!test_heap_window())          { printf("blt_device: heap-window FAIL\n");      return 1; }
    printf("blt_device OK (publish/complete, timeout, heap-window)\n");
    return 0;
}
```

- [ ] **Step 3: Add the host test target** — in `Makefile.gmloader`, after the existing `raster-backend-test` target:

```make
blt-device-test:
	cc -std=c11 -Igmloader/mister $(MFGPU_INC) \
	  gmloader/mister/blt_device_test.c \
	  gmloader/mister/blt_device.c \
	  $(MFGPU_DIR)/host/blt_emitter.c $(MFGPU_DIR)/host/blt_alloc.c \
	  -o /tmp/bdt && /tmp/bdt
```

- [ ] **Step 4: Run to verify it fails**

Run: `make -f Makefile.gmloader blt-device-test`
Expected: link error — `blt_device_open_at`, `blt_device_submit`, `blt_device_close` undefined (`blt_device.c` not written yet).

- [ ] **Step 5: Implement `blt_device.c`** — `gmloader/mister/blt_device.c`

```c
#include "blt_device.h"
#include "blt_wire.h"       /* BLT_CMD_BYTES */
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>

/* Device DDR layout (docs/blitter-protocol.md §2, verified vs milestone-a RTL). */
#define BD_PHYS_BASE   0x3B000000u
#define BD_MAP_SIZE    (16u * 1024 * 1024)          /* 16 MiB region              */
#define BD_OFF_CTRL    0x00000u
#define BD_OFF_RING    0x00040u
#define BD_OFF_HEAP    0x80000u                      /* SRC_QW = 0x3B080000        */
#define BD_HEAP_END    0xF40000u                     /* 0x3BF40000 - BD_PHYS_BASE  */
#define BD_HEAP_WINDOW (BD_HEAP_END - BD_OFF_HEAP)   /* 15,466,496 usable bytes    */
#define BD_RING_WINDOW (BD_OFF_HEAP - BD_OFF_RING)   /* 512 KiB - 0x40             */

/* Control-block qword indices (low u32 of each 8-byte qword). */
#define QW_SUBMIT   0
#define QW_CMDCOUNT 1
#define QW_TARGET   2
#define QW_CLEAR    3
#define QW_FLAGS    4
#define QW_DONE     5
#define QW_STATUS   6

static inline volatile uint32_t *ctrl32(const blt_device_t *d) {
    return (volatile uint32_t *)(d->base + BD_OFF_CTRL);
}
/* low 32 of qword `qw` lives at u32 index qw*2; hi 32 at qw*2+1. */
static inline void cwr(const blt_device_t *d, int qw, uint32_t v) { ctrl32(d)[(size_t)qw*2] = v; }
static inline uint32_t crd(const blt_device_t *d, int qw)         { return ctrl32(d)[(size_t)qw*2]; }
static inline uint32_t crd_hi(const blt_device_t *d, int qw)      { return ctrl32(d)[(size_t)qw*2+1]; }

int blt_device_open(blt_device_t *d) {
    if (!d) return -EINVAL;
    memset(d, 0, sizeof *d);
    d->fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (d->fd < 0) return -errno;
    void *m = mmap(NULL, BD_MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                   d->fd, (off_t)BD_PHYS_BASE);
    if (m == MAP_FAILED) { int e = -errno; close(d->fd); d->fd = -1; return e; }
    d->base = (volatile uint8_t *)m;
    d->size = BD_MAP_SIZE;
    d->owns_map = 1;
    return 0;
}

int blt_device_open_at(blt_device_t *d, void *region, size_t size) {
    if (!d || !region) return -EINVAL;
    memset(d, 0, sizeof *d);
    d->fd = -1;
    d->base = (volatile uint8_t *)region;
    d->size = size;
    d->owns_map = 0;
    return 0;
}

int blt_device_submit(blt_device_t *d, const blt_emitter_t *e,
                      uint32_t heap_len, int timeout_ms) {
    if (!d || !d->base || !e) return -EINVAL;
    uint32_t ring_bytes = (uint32_t)e->cmd_count * BLT_CMD_BYTES;
    if (ring_bytes > BD_RING_WINDOW) return -ENOSPC;
    if (heap_len   > BD_HEAP_WINDOW) return -ENOSPC;

    /* 1. ring (packed 32B commands incl. the trailing END). */
    memcpy((void *)(d->base + BD_OFF_RING), e->ring, ring_bytes);
    /* 2. one source region: vertices (low, read from DDR) + texture staging
     *    source (high, copied to SDRAM by OP_STAGE). */
    if (heap_len) memcpy((void *)(d->base + BD_OFF_HEAP), e->heap, heap_len);
    /* 3. control fields (all but the doorbell). */
    cwr(d, QW_CMDCOUNT, (uint32_t)e->cmd_count);
    cwr(d, QW_TARGET,   (uint32_t)e->target_buf);
    cwr(d, QW_CLEAR,    (uint32_t)e->clear_color);
    cwr(d, QW_FLAGS,    e->flags);
    /* 4. doorbell: submit_seq LAST, store-release. */
    __sync_synchronize();
    cwr(d, QW_SUBMIT, e->submit_seq);
    __sync_synchronize();
    /* 5. poll done_seq == submit_seq (this core has no C_STATUS error latch). */
    long budget_us = (long)timeout_ms * 1000;
    while (crd(d, QW_DONE) != e->submit_seq) {
        if (budget_us <= 0) {
            fprintf(stderr,
                "blt_device: submit timeout (submit=%u done=%u frame_cyc=%u pipe_cyc=%u)\n",
                e->submit_seq, crd(d, QW_DONE), crd_hi(d, QW_DONE), crd_hi(d, QW_STATUS));
            return -ETIMEDOUT;
        }
        usleep(50);
        budget_us -= 50;
    }
    return 0;
}

void blt_device_close(blt_device_t *d) {
    if (!d) return;
    if (d->owns_map && d->base && d->base != (volatile uint8_t *)MAP_FAILED)
        munmap((void *)d->base, d->size);
    if (d->fd >= 0) close(d->fd);
    d->base = NULL; d->fd = -1; d->owns_map = 0;
}
```

- [ ] **Step 6: Run to verify it passes**

Run: `make -f Makefile.gmloader blt-device-test`
Expected: `blt_device OK (publish/complete, timeout, heap-window)`

- [ ] **Step 7: Commit**

```bash
git add gmloader/mister/blt_device.h gmloader/mister/blt_device.c \
        gmloader/mister/blt_device_test.c Makefile.gmloader
git commit -m "feat(mfgpu): blt_device /dev/mem ring transport (publish+doorbell+done poll)"
```

---

## Task 3: `backend_mfgpu` emits `OP_STAGE` on cache-miss (device build only)

**Files:**
- Modify: `external/gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp` (`stage_texture` miss path)

**Interfaces:**
- Consumes: `blt_stage(blt_emitter_t*, uint32_t off, uint32_t size)` (`blt_emitter.h`), the existing `stage_texture` / `blt_upload` path, `blt_surface_ref_t` (`.off`, `.size`, `.stride`, `.h`).
- Produces: on the device build, every freshly-uploaded texture page is `OP_STAGE`d DDR→SDRAM at the same offset, so a later `blt_trilist` (which writes `src_off = tex.off`) resolves its SDRAM texel fetch. Host build unchanged (oracle reads DDR directly).

- [ ] **Step 1: Locate the miss path** — in `raster_backend_mfgpu.cpp`, `stage_texture()`, immediately after the successful upload block:

```c
    blt_surface_ref_t ref = blt_upload(&g_e, g_texscratch, tw, th, tw * 2);
    while (!ref.valid && evict_one_lru()) ref = blt_upload(&g_e, g_texscratch, tw, th, tw * 2);
    if (!ref.valid) { *out_has_key = false; return ref; }  // frame drops, correct
    g_e.overflow = ov_before;
    g_upload_count++;
```

- [ ] **Step 2: Emit the same-offset stage right after the upload succeeds** — insert after the `g_upload_count++;` line:

```c
#ifdef MISTER_BUILD
    // Device fabric samples TRILIST texels from SDRAM at src_off == ref.off.
    // Stage same-offset (SDRAM[off] = DDR[off]) so the texel fetch resolves.
    // blt_trilist writes src_off = tex.off (NOT sdram_off), so the decoupled
    // blt_stage_surface path would render black — use blt_stage(off,size).
    {
        uint32_t tex_bytes = (uint32_t)ref.stride * ref.h;   // packed page bytes
        if (blt_stage(&g_e, ref.off, tex_bytes) != 0)
            fprintf(stderr, "backend_mfgpu: blt_stage overflow (off=%u) - frame may drop\n",
                    ref.off);
    }
#endif
```

- [ ] **Step 3: Build the host test to confirm no host-build behavior change**

Run: `make -f Makefile.gmloader raster-backend-test`
Expected: full battery still all-pass. (`MISTER_BUILD` is not defined for the host test target, so the `blt_stage` call is compiled out — the oracle path is byte-identical.)

- [ ] **Step 4: Confirm the stage compiles under the device macro** (compile-only smoke, no device)

Run:
```bash
cc -std=c11 -DMISTER_BUILD -Igmloader/mister $(MFGPU_INC) -fsyntax-only \
   -x c++ gmloader/mister/raster_backend_mfgpu.cpp && echo "MISTER_BUILD syntax OK"
```
Expected: `MISTER_BUILD syntax OK` (real link happens in Task 5; this catches macro-guarded typos now).

- [ ] **Step 5: Commit**

```bash
git add gmloader/mister/raster_backend_mfgpu.cpp
git commit -m "feat(mfgpu): emit same-offset OP_STAGE per texture on device (SDRAM texel fetch)"
```

---

## Task 4: Wire device submit into `mf_frame_end` + skip NativeVideoWriter for the fabric path

**Files:**
- Modify: `external/gmloader-next/gmloader/mister/raster_backend_mfgpu.cpp` (`mf_frame_end`, include, statics, heap-length helper)
- Modify: `external/gmloader-next/gmloader/main.cpp:577-590` (skip NativeVideoWriter handoff under `MISTER_BUILD`)

**Interfaces:**
- Consumes: `blt_device_open`, `blt_device_submit` (Task 2); `blt_end_frame`; the `g_texcache`/`g_e`/`MF_VTX_REGION` state (existing).
- Produces: on the device build, `mf_frame_end` publishes the frame to the fabric and blocks on `done_seq`; `main.cpp` no longer hands `g_fb565` to NativeVideoWriter for the mfgpu backend (the core scans out its own BRAM).

- [ ] **Step 1: Include the transport + add device statics** — near the top of `raster_backend_mfgpu.cpp`, in the `extern "C"` include block, add `#include "blt_device.h"`; and after the `g_inited` declaration add:

```c
#ifdef MISTER_BUILD
static blt_device_t  g_dev;
static bool          g_dev_open = false;
#endif
```

- [ ] **Step 2: Add the heap-publish-length helper** — before `mf_frame_end`, add:

```c
#ifdef MISTER_BUILD
// Bytes of g_srcdram to publish to the device DDR heap: the vertex region
// [0, MF_VTX_REGION) plus every resident texture page (offsets >= MF_VTX_REGION).
// The high-water over the live cache covers both (vtx_used <= MF_VTX_REGION <=
// any texture offset). Keeps the copy well inside the 15.2MB DDR heap window.
static uint32_t mf_heap_publish_len(void) {
    uint32_t hi = MF_VTX_REGION;
    for (int i = 0; i < MF_TEX_CACHE_N; i++)
        if (g_texcache[i].used) {
            uint32_t end = g_texcache[i].ref.off + g_texcache[i].ref.size;
            if (end > hi) hi = end;
        }
    return hi;
}
#endif
```

- [ ] **Step 3: Split `mf_frame_end` into device-submit vs host-oracle** — replace the current `mf_frame_end` body:

```c
static void mf_frame_end(void) {
    blt_end_frame(&g_e);
    if (g_e.overflow) {
        fprintf(stderr, "backend_mfgpu: emitter overflow this frame - frame dropped\n");
        return;   // nothing safe to submit/execute this frame
    }
#ifdef MISTER_BUILD
    // ── Device: publish the ring to the fabric and wait for C_DONE. ──────────
    if (!g_dev_open) {
        int rc = blt_device_open(&g_dev);
        if (rc != 0) {
            fprintf(stderr, "backend_mfgpu: blt_device_open failed (%d) - frame dropped\n", rc);
            return;
        }
        g_dev_open = true;
    }
    int rc = blt_device_submit(&g_dev, &g_e, mf_heap_publish_len(), /*timeout_ms=*/100);
    if (rc != 0)
        fprintf(stderr, "backend_mfgpu: blt_device_submit rc=%d - frame dropped\n", rc);
#else
    // ── Host: software-execute the ring into g_fb565 (parity-test oracle). ───
    memset(g_fb565, 0, sizeof g_fb565);
    int n = g_e.cmd_count;
    if (n > MF_MAX_CMDS) n = MF_MAX_CMDS;
    for (int i = 0; i < n; i++)
        blt_unpack_cmd(g_ring + (size_t)i * BLT_CMD_BYTES, &g_cmds[i]);
    blt_surface_heap_t heap = { g_srcdram, sizeof g_srcdram, nullptr, nullptr };
    blt_execute(g_fb565, &heap, g_cmds, n);
#endif
}
```

(The `memset g_fb565` that used to run before the overflow check is intentionally
dropped from the device path — `g_fb565` is unused on device.)

- [ ] **Step 4: Skip the NativeVideoWriter handoff for the device fabric path** — in `main.cpp`, replace the `if (RasterBackend_Select() == &backend_mfgpu) { ... }` block at `:577-590` with:

```c
            if (RasterBackend_Select() == &backend_mfgpu) {
#ifdef MISTER_BUILD
              // Device fabric path: present() (inside Blitter_PresentDefault
              // above) already submitted the ring to the fabric, which
              // composites into on-chip BRAM and scans itself out. Nothing to
              // hand to NativeVideoWriter (that 0x3A DDR path is the software
              // producer, unused here).
              (void)0;
#else
              // Non-device (SDL preview) mfgpu build: g_fb565 came from
              // blt_execute; scan it out directly (RGB565, no Blitter_ToRGB565).
              int fb_w = 0, fb_h = 0;
              const uint16_t* fb565 = RasterBackend_MFGPU_GetFB565(&fb_w, &fb_h);
              const int vis_w = (fb_w < MISTER_WIDTH) ? fb_w : MISTER_WIDTH;
              const int vis_h = (fb_h < MISTER_HEIGHT) ? fb_h : MISTER_HEIGHT;
              NativeVideoWriter_WriteFrame(fb565, vis_w, vis_h, fb_w * 2);
#endif
            } else {
```

(Leave the `else`/software-blitter branch that follows — `:591-597` — unchanged.)

- [ ] **Step 5: Host test still green** (the `#else` oracle path is what the test exercises)

Run: `make -f Makefile.gmloader raster-backend-test`
Expected: full battery all-pass — the host build compiles the `#else` branches, so `mf_frame_end` still runs `blt_execute` and the parity battery is unchanged.

- [ ] **Step 6: Commit**

```bash
git add gmloader/mister/raster_backend_mfgpu.cpp gmloader/main.cpp
git commit -m "feat(mfgpu): device frame_end submits to fabric; skip NativeVideoWriter (BRAM scanout)"
```

---

## Task 5: armhf cross-build + Makefile wiring

**Files:**
- Modify: `external/gmloader-next/Makefile.gmloader` (add `blt_device.c` to `MISTER_SRCS`)

**Interfaces:**
- Consumes: everything above. No new symbols.
- Produces: a clean armhf device binary `build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf` linking `blt_device` + the mfgpu objects.

- [ ] **Step 1: Add `blt_device.c` to the MiSTer sources** — in `Makefile.gmloader`, append `gmloader/mister/blt_device.c` to the `MISTER_SRCS` list:

```make
MISTER_SRCS = gmloader/mister/native_video_writer.c gmloader/mister/frame_capture.cpp gmloader/mister/draw_trace.cpp gmloader/mister/blitter.cpp gmloader/mister/blitter_raster.cpp gmloader/mister/raster_backend_sw.cpp gmloader/mister/raster_backend_mfgpu.cpp gmloader/mister/blt_device.c
```

- [ ] **Step 2: armhf cross-build** — run the Global-Constraints Docker recipe (from `external/gmloader-next`).

Expected: clean link → `build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf`. The `.bss` remains ~40 MB (the existing `g_srcdram`/`g_texscratch`); the new module adds only code.

- [ ] **Step 3: Confirm the device transport symbols linked**

Run:
```bash
docker run --rm -v "$(pwd):/src" -w /src gmloader-armhf-build:bullseye bash -c \
  'arm-linux-gnueabihf-nm build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf | grep -E "blt_device_(open|submit|close)"'
```
Expected: the three symbols appear (defined, `T`).

- [ ] **Step 4: Commit**

```bash
git add Makefile.gmloader
git commit -m "build(mfgpu): link blt_device into the armhf MiSTer binary"
```

---

## Task 6: Deploy the RBF + on-device bring-up + verification

**Files:**
- Modify: `external/gmloader-next/.superpowers/sdd/progress.md` (findings)
- Modify: `mister-gmloader` (bump `external/gmloader-next` submodule pointer)

**Interfaces:**
- Consumes: the armhf binary (Task 5); the built `milestone-a` RBF for the Maldita core.
- Produces: recorded on-hardware evidence that one staged texture renders as an `OP_TRILIST` on the fabric.

- [ ] **Step 1: Deploy the `milestone-a` RBF** (prerequisite — the fabric triangle FSM must be on the device, else the doorbell poll times out). Copy the built core RBF to the device's core location and load it. Confirm which RBF path the device boots; verify the core is the `milestone-a` build before proceeding. (Ask the user for the exact RBF artifact path / deploy target if unknown — this is the built-but-undeployed bitstream.)

- [ ] **Step 2: Back up + deploy the binary**

```bash
cd external/gmloader-next
ssh root@192.168.20.81 'ps w | grep -q "[g]mloader -c" && pkill -9 -f "gmloader -c"; \
  cp -n /media/fat/games/gmloader/gmloader /media/fat/games/gmloader/gmloader.pre-fabric.bak'
scp build/arm-linux-gnueabihf/gmloader/gmloadernext.armhf root@192.168.20.81:/media/fat/games/gmloader/gmloader
ssh root@192.168.20.81 'chmod +x /media/fat/games/gmloader/gmloader'
```

- [ ] **Step 3: Fabric bring-up run** — launch with the mfgpu backend and capture the log:

```bash
ssh root@192.168.20.81 'cd /media/fat/games/gmloader && \
  GMLOADER_RASTER=mfgpu \
  LD_LIBRARY_PATH=/media/fat/games/gmloader/mesa:/media/fat/games/gmloader \
  ./gmloader -c gmloader.json 2>&1 | head -120'
```
Expected: boots, no SIGSEGV/SIGILL, and **no** `blt_device_submit rc=` / `submit timeout` lines — i.e. `done_seq` advances every frame (the fabric answered the doorbell). If timeouts appear, the RBF is wrong/undeployed or the heap/opcode base is off — stop and diagnose (do not claim success).

- [ ] **Step 4: Confirm the doorbell handshake from the device shell** — while it runs (or scripted), read the control block:

```bash
ssh root@192.168.20.81 'busybox devmem 0x3B000000 32; busybox devmem 0x3B000028 32'
# 0x3B000000 = submit_seq (qw0);  0x3B000028 = done_seq (qw5, 5*8=0x28)
```
Expected: `submit_seq` and `done_seq` are equal and both advancing between reads — the fabric is consuming frames.

- [ ] **Step 5: Visual verification (mandatory — "counters lie about video")** — capture the on-screen frame via MiSTer Remote and compare to the refmodel's render of the same one-triangle scene:

```bash
curl -s -X POST http://192.168.20.81:8182/api/screenshots >/dev/null
sleep 1
curl -s http://192.168.20.81:8182/api/screenshots | tail -c 400
```
Expected: the captured frame shows the fabric-composited textured triangle (matching the refmodel RGB565 render within ±1 LSB). The user eyeballs the image to confirm it is the fabric output, not a stale/black frame. Note the screenshot path for the ledger.

- [ ] **Step 6: Record findings + bump the submodule pointer**

Append a dated section to `external/gmloader-next/.superpowers/sdd/progress.md`: RBF deployed, armhf link clean, `done_seq` advancing with no timeouts, screenshot result, and that the pre-existing ~24-draw crash (blocker (a)) remains the next task. Then:

```bash
cd external/gmloader-next
git add .superpowers/sdd/progress.md
git commit -m "docs(sdd): device-ring vertical slice on-hardware results (fabric OP_TRILIST)"
git push   # if the branch tracks a remote
cd ../..
git add external/gmloader-next
git commit -m "chore: bump gmloader-next to device-ring fabric vertical slice"
```

---

## Self-Review

**Spec coverage:**
- Spec §1/§4 (publish ring, doorbell, poll done) → Task 2 (`blt_device`). ✓
- Spec §3 wire contract (bases, control qwords, handshake) → Global Constraints + Task 2 code. ✓
- Spec §5.2 "emit OP_STAGE, SDRAM texel source" → Task 3 (`blt_stage` same-offset), grounded by the RTL reconciliation (unconditional-SDRAM, same-offset). ✓
- Spec §5.2 "device frame_end submits; present bypasses NativeVideoWriter" → Task 4. ✓
- Spec §5.3 build/submodule → Task 1 (submodule) + Task 5 (link). ✓
- Spec §6 testing (host oracle unchanged; blt_device host unit; on-device bring-up + screenshot) → Task 2 test, Task 3/4 host-green steps, Task 6. ✓
- Spec §7 prereqs (RBF deploy step 0; no sw fallback; timeout error model) → Task 6 Step 1; Task 4 (`#ifdef` device-only, drop-on-fail); Task 2 (`-ETIMEDOUT`, no status latch). ✓
- Spec §8 out-of-scope (dirty-range, heap-window reconciliation, FBO fallback) → not implemented; heap-window guard present (`-ENOSPC`) and `mf_heap_publish_len` keeps the slice inside the window. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. The only user-dependent item is the exact RBF artifact path (Task 6 Step 1), flagged explicitly rather than guessed.

**Type consistency:** `blt_device_t` fields (`fd`/`base`/`size`/`owns_map`) and the four API signatures are identical across the header (Task 2 Step 1), implementation (Step 5), test (Step 2), and callers (Task 4). `blt_stage(e, off, size)`, `blt_end_frame`, `blt_surface_ref_t.{off,size,stride,h}`, and control qword indices (`QW_SUBMIT=0`…`QW_STATUS=6`) match the emitter header and the verified RTL contract. `mf_heap_publish_len()` returns `uint32_t`, consumed as `heap_len` by `blt_device_submit`. ✓

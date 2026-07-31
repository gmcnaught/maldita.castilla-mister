# MFGPU Device-Ring Vertical Slice — Drive the Real Fabric

**Date:** 2026-07-15
**Status:** Design approved; ready for implementation planning.
**Author:** gmcnaught (with Claude)
**Phase:** 1d (on-hardware fabric bring-up)

---

## 1. Goal

Make `backend_mfgpu` render on the **real FPGA fabric** instead of software-
rasterizing on the A9. Concretely: publish the emitted command ring to the
device DDR region at `0x3B000000`, stage one texture (`OP_STAGE`, DDR→SDRAM),
emit one `OP_TRILIST`, ring the doorbell (`submit_seq`), wait `done_seq`
(`C_DONE`), and verify the fabric-composited frame on-device (MiSTer Remote
screenshot vs the refmodel).

**Success:** with the `milestone-a` RBF deployed and `GMLOADER_RASTER=mfgpu`,
one staged texture drawn as an `OP_TRILIST` reaches the fabric, `done_seq`
advances with `status == 0`, and the on-screen result matches the refmodel's
RGB565 render of the same scene within ±1 LSB.

---

## 2. Current state (the gap)

Everything upstream of the wire already works and is host-validated. On a draw,
`backend_mfgpu` builds a correct ring — `blt_fill` / `blt_upload` /
`blt_push_tris` / `blt_trilist` — into `g_ring` (64 KiB) and `g_srcdram`
(vertex region + 32 MiB texture heap). The problem is the terminal step:

- **`mf_frame_end` today calls `blt_execute()`** — the *software* reference
  rasterizer — into `g_fb565`, and `main.cpp` scans `g_fb565` out through
  NativeVideoWriter. **The fabric is never touched, even on the A9.**
- **No device transport exists.** There is no `/dev/mem`, `mmap`, or devmem
  anywhere in the mfgpu host library. `blt_emitter.c` deliberately stops at
  "build the ring in host RAM"; its header states *"the caller publishes ring +
  control block to DDR and bumps the doorbell"* — that caller has never been
  written.

The `milestone-a` core RBF closes the loop in hardware (built, **not yet
deployed** to `192.168.20.81`):

- `OP_STAGE`(4) copies a DDR3 region into SDRAM (`blitter_top.sv` §issue-19).
- `OP_TRILIST`(10) composites textured triangles into **on-chip BRAM**
  (`comp_fbram`), sampling texels from **SDRAM** via the `P_SRC` port.
- The core snapshots WORK→SCAN at vblank and **scans out its own BRAM FB**
  (`fbram_scan_adapter` → `openbor_video_reader`).
- On completion the fabric writes `done_seq` at control qword 5 (`C_DONE`) and
  `status` at qword 6.

**Consequence:** in the fabric path the frame appears via the *core's* scanout —
**not** through `g_fb565` / NativeVideoWriter.

---

## 3. The wire contract (from the deployed RTL + `blitter-protocol.md`)

Verified against `maldita.castilla-mister/fpga/rtl/blitter_defs.vh` +
`blitter_top.sv` (branch `milestone-a`) and the mfgpu-fork host emitter
(`mister-fpga-blitter` @ `6d166f5`, "renumber BLT_OP_TRILIST 8→10"). **The ABI
is already reconciled** — `OP_TRILIST = 10` and `OP_STAGE = 4` on both the RTL
and host sides; the opcode-8 collision with device `BGPLANE_WRITE` was resolved
before this slice.

**DDR region `0x3B000000`, 16 MiB (HW-verified reserved-safe):**

| Phys base    | Size      | Purpose                                   |
|--------------|-----------|-------------------------------------------|
| `0x3B000000` | 0x40      | control block (8 × qword)                 |
| `0x3B000040` | 512 KiB   | command ring (32 B/command, walk-to-END)  |
| `0x3B080000` | ~15.2 MiB | texture upload heap (DDR source for STAGE)|

**Control block (one u32 per qword; qword = 8 bytes):**

| Qword | Name         | Writer | Meaning                                   |
|-------|--------------|--------|-------------------------------------------|
| 0     | `submit_seq` | ARM    | doorbell: bumped last, after ring in DDR  |
| 1     | `cmd_count`  | ARM    | valid commands in the ring this frame     |
| 3     | `clear_color`| ARM    | RGB565; filled first if `flags.CLEAR`     |
| 4     | `flags`      | ARM    | bit0 CLEAR-before-list                     |
| 5     | `done_seq`   | fabric | set = `submit_seq` when frame composited (`C_DONE`) |
| 6     | `status`     | fabric | 0 = OK; nonzero = error latch              |

Diagnostic: the core publishes live `fabric_busy`/`pipe_busy` in the **high 32
bits** of the `C_DONE` / `C_STATUS` qwords (readable at `C_DONE+4` /
`C_STATUS+4`) — useful for post-mortem when a poll times out.

**Handshake (§3 of `blitter-protocol.md`, unchanged across every core
revision):** host writes ring + control fields, then bumps `submit_seq` **last
with store-release ordering**; the fabric composites when
`submit_seq != done_seq`, then sets `done_seq = submit_seq`. Single frame in
flight.

**Texture source is SDRAM.** The fabric TRILIST walk fetches texels from SDRAM,
not the DDR heap. A texture must be `OP_STAGE`d (DDR→SDRAM) before an
`OP_TRILIST` that samples it; the per-command `BLT_F_SRC_SDRAM` (0x10) flag
selects the SDRAM source. The host emitter already models this:
`blt_stage_surface(e, &ref)` emits the STAGE and fills `ref.sdram_off`
(idempotent — `BLT_ALLOC_FAIL` sentinel until first staged).

---

## 4. Architecture

```
 backend_mfgpu (unchanged emit)         blt_device (NEW)              milestone-a fabric
 ------------------------------         ----------------              ------------------
 clear/draw -> blt_fill/upload/         mmap /dev/mem @0x3B000000
   stage_surface/push_tris/trilist  ->  memcpy ring -> +0x40
   builds g_ring + g_srcdram            memcpy tex heap -> +0x80000
                                        write cmd_count/clear/flags
 mf_frame_end (device build):           write submit_seq LAST (dmb) --> walk ring to END
   blt_device_submit(&g_e) ----------->                                 OP_STAGE: DDR->SDRAM
                                        poll done_seq==submit_seq  <---  OP_TRILIST: SDRAM tex
                                        read status                      -> composite to BRAM
                                                                         set done_seq / status
                                                                    at vblank: WORK->SCAN --> core scanout --> HDMI/analog
```

The **only new code** is `blt_device` — a self-contained `/dev/mem` transport in
the mfgpu submodule. `backend_mfgpu`'s emit path is untouched; its terminal step
swaps `blt_execute` for `blt_device_submit` in the device build. The staging
call (`blt_stage_surface`) is added to the miss path so `OP_STAGE` is emitted.

---

## 5. Components

### 5.1 `blt_device` — device transport (NEW)

*Location:* `host/blt_device.c` + `host/blt_device.h` in the mfgpu submodule
(`git@github.com:gmcnaught/mister-fpga-blitter`). It belongs beside
`blt_emitter.c` (which stops exactly where this begins), has **zero**
gmloader/GLES dependencies, and is independently testable/reusable.

```c
typedef struct {
    int       fd;            /* /dev/mem */
    void     *base;          /* mmap of the 16 MiB region @ 0x3B000000 */
    size_t    map_size;
    volatile uint32_t *ctrl; /* base + 0x00000  */
    uint8_t          *ring;  /* base + 0x00040  */
    uint8_t          *heap;  /* base + 0x80000  */
    uint32_t  submit_seq;    /* host-side shadow, monotonic */
} blt_device_t;

int  blt_device_open (blt_device_t *d);                 /* 0 ok; <0 errno */
int  blt_device_submit(blt_device_t *d, blt_emitter_t *e, int timeout_ms);
void blt_device_close(blt_device_t *d);
```

- **`open`:** `open("/dev/mem", O_RDWR|O_SYNC)`, `mmap` 16 MiB at page-aligned
  `0x3B000000`; derive `ctrl`/`ring`/`heap` pointers. Fail loud (device path has
  no software fallback — see §7).
- **`submit`:** the §3 handshake, in order:
  1. `memcpy` the emitter ring (`e->cmd_count * BLT_CMD_BYTES`) into `ring`.
  2. `memcpy` the emitter's **whole used `g_srcdram` extent** into `heap` — this
     single region holds *both* the TRILIST **vertex entries** (low, referenced
     by `entry_off`) *and* the texture **staging source** (high, referenced by
     `OP_STAGE`'s `src_off`). The fabric reads vertices from this DDR region
     directly (no staging for vertices); only textures get copied on to SDRAM by
     `OP_STAGE`, after which TRILIST samples texels from `sdram_off`. So the DDR
     heap base the region is published to **must equal the base the RTL uses for
     TRILIST `entry_off` and `OP_STAGE` `src_off`** — confirm that base against
     `blitter_top.sv` / `blitter_defs.vh` during planning (candidate:
     `0x3B080000`; the ring/heap bases are coupled constants that deploy with the
     RBF). Slice scope: copy the whole used extent; a dirty-range optimization is
     a later item.
  3. Write `ctrl[C_CMDCOUNT]`, `ctrl[C_CLEAR]`, `ctrl[C_FLAGS]`.
  4. `__sync_synchronize()` (ARM `dmb`), then write
     `ctrl[C_SUBMIT] = ++d->submit_seq` — the doorbell, released last.
  5. Poll `ctrl[C_DONE]` until `== d->submit_seq` or `timeout_ms` elapses
     (bounded spin with a short `usleep`); on timeout, log `C_DONE`/`C_STATUS`
     incl. the hi-32 busy diag and return an error. Return `ctrl[C_STATUS]`
     nonzero as an error latch.
- **`close`:** `munmap` + `close`.

*Dependencies:* `blt_emitter.h` (reads `cmd_count`, ring bytes, heap span),
`blitter_defs`-style qword offsets (mirror `C_SUBMIT..C_STATUS`). No libc beyond
`fcntl`/`sys/mman`/`unistd`/`string`.

### 5.2 `backend_mfgpu` — terminal-step + staging change

- **`mf_frame_end` (`#ifdef MISTER_BUILD`):** call `blt_device_submit(&g_e, …)`
  instead of `blt_execute`. Host build keeps `blt_execute` verbatim (the test
  oracle — §6). One process-lifetime `blt_device_open` (lazy, on first submit);
  a submit failure logs and drops the frame.
- **`present`:** device build does **not** hand `g_fb565` to NativeVideoWriter;
  the fabric BRAM is the scanout. `present` waits for submit completion (already
  done inside `blt_device_submit`) and returns.
- **`stage_texture` miss path:** after `blt_upload`, call
  `blt_stage_surface(&g_e, &ref)` so an `OP_STAGE` is emitted and `ref.sdram_off`
  is populated; the cached `MfTexEntry.ref` carries the SDRAM offset for reuse.
  Confirm during planning that `blt_trilist` sets `BLT_F_SRC_SDRAM` when its
  `tex` ref is staged (else set it explicitly). Gated to the device build so the
  host oracle keeps sampling the DDR heap via `blt_execute`.

### 5.3 Build / submodule

- Initialize the `3rdparty/mfgpu` submodule (uninitialized gitlink `7ce8e7f4`)
  at the TRILIST=10 commit; add `host/blt_device.c` to `MFGPU_SRC`.
- No new `MISTER_SRCS`; `blt_device` compiles into the existing mfgpu objects.

---

## 6. Testing strategy

- **Host (unchanged, must stay green):** `raster_backend_test.cpp`'s ±1 LSB
  parity battery runs in the **host build**, where `mf_frame_end` still calls
  `blt_execute`. `blt_device` is device-only code; it is not linked into the
  host test. This preserves the entire existing validation surface.
- **`blt_device` unit (host, no hardware):** point `open` at an anonymous
  `mmap`/`malloc` region (a compile-time seam or a test-only `_map_at`) and
  assert `submit` lays down ring + heap bytes, writes the control qwords in the
  right slots, and writes `submit_seq` last. A stub "fabric" that sets
  `done_seq = submit_seq` proves the poll succeeds; a stub that never does proves
  the timeout path. No `/dev/mem`.
- **On-device bring-up:**
  1. **Deploy the `milestone-a` RBF** to `192.168.20.81` (prerequisite — §7).
  2. Run Maldita with `GMLOADER_RASTER=mfgpu`; capture the log. Success = boots,
     no SIGSEGV/SIGILL, and `done_seq` advances (no submit timeouts) with
     `status == 0`.
  3. **Visual check — mandatory** ("counters lie about video"): MiSTer Remote
     screenshot (`http://192.168.20.81:8182/api/screenshots`) of the on-screen
     frame vs the refmodel's RGB565 render of the same one-triangle scene, ±1
     LSB. User eyeballs the image.

---

## 7. Prerequisites, risks, error model

- **RBF deploy is step 0.** The `milestone-a` bitstream is built but not on the
  device; without it the doorbell poll times out. Deploy before any bring-up run.
- **No software fallback in the device path (by decision).** Dropping the
  software-execute path early means `backend_mfgpu` on device is fabric-only:
  `blt_device_open`/`submit` failures **log and drop the frame** (never hang,
  never silently software-render). `GMLOADER_RASTER=sw` remains the separate,
  unaffected pure-software selector for comparison.
- **Display coexistence — resolved by the drop.** The new core scans out the
  fabric BRAM FB. Because we no longer keep a runtime sw/fabric dual-mode on one
  binary, bring-up goes straight to fabric; the earlier worry about whether the
  NativeVideoWriter (`0x3A…`) path still displays on this RBF is moot for the
  slice. (If a `GMLOADER_RASTER=sw` display check on the *new* RBF is later
  wanted, tracing the core's video-source mux is a separate task.)
- **`status != 0`** = ring overflow / error latch → log (with the hi-32 diag)
  and drop the frame.
- **Single frame in flight; blocking poll** is acceptable for bring-up.
  Pipelining frame N+1 build against fabric composite of N is a later item.

---

## 8. Out of scope (YAGNI for this slice)

- Dirty-range heap upload (copy only changed texture bytes) — copy the whole
  used extent for now.
- Reconciling the 32 MiB host texture heap against the ~15.2 MiB device DDR heap
  window (DDR-as-bounce-buffer staging into permanent SDRAM, per the
  atlas-staging design). The one-texture slice's used extent fits the window;
  the full-frame path does not and is a later item.
- Non-blocking / double-buffered submit (build N+1 while fabric runs N).
- Removing the per-draw FBO / `RB_PREMULT` fallback from `mf_draw` (unrelated
  churn; not exercised by the one-triangle slice).
- Tracing the core video-source mux for sw-vs-fabric A/B on the new RBF.
- The pre-existing ~24-draw crash (blocker (a)) — orthogonal, unchanged.

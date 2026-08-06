# `mem_wc` — a write-combining `/dev/mem` for the fabric window

Vendored from [skmp/minicast](https://github.com/skmp/minicast/tree/main/mem_wc)
(GPL-2.0), where it gives DreamSTer's Dreamcast VRAM window a write-combining
mapping, by way of [`gmcnaught/mamester#5`](https://github.com/gmcnaught/mamester/pull/5),
which is where the analysis, the bench and the prebuilt object come from. The
driver source here is unmodified; only this README and the integration are ours.

## What problem it solves

Everything the host hands the fabric goes through the 16 MB DDR window at
`0x3B000000` — the command rings and, far more importantly, the SRC texture heap
that `blt_upload()` fills with a per-row `memcpy`
(`3rdparty/mfgpu/host/blt_emitter.c`). Measured on `.81`, kernel `5.15.1-MiSTer`,
with mamester's `tools/mister/ddr-write-bench`:

```
memcpy -> /dev/mem      80.3 MB/s     (O_SYNC and no-O_SYNC identical)
memcpy -> /dev/mem_wc  813.9 MB/s     10.1x
memcpy -> cached RAM   552.6 MB/s
```

The window is *slower than DRAM and slower than cache* because of its memory
type, not the bus. ARM's `phys_mem_access_prot()` (`arch/arm/mm/mmu.c`):

```c
if (!pfn_valid(pfn))             return pgprot_noncached(vma_prot);   /* Strongly-Ordered */
else if (file->f_flags & O_SYNC) return pgprot_writecombine(vma_prot);
return vma_prot;                                                       /* cacheable */
```

`/proc/iomem` on this board reports `System RAM` as `00000000-1fefffff`, so
`0x3B000000` is outside the kernel's memblock, `pfn_valid()` is false, and
**every** `/dev/mem` mapping of it takes the first branch. No argument to
`/dev/mem` yields write-combining. Strongly-Ordered (`L_PTE_MT_UNCACHED`) stores
cannot merge, so each one is its own bus transaction and the path is
transaction-latency bound.

This driver never asks `pfn_valid()`. It sets `pgprot_writecombine()`
(`L_PTE_MT_BUFFERABLE`, Normal Non-Cacheable) unconditionally and calls
`remap_pfn_range()`. Stores merge into full bursts.

**Where this shows up in Maldita.** Not in steady-state gameplay: with the
texture-residency cache warm, `BLITPROF` reports `texup=0.0ms`. It shows up
wherever the heap has to be refilled — startup, room transitions, and the
per-sprite-quad sub-region staging that fixes the SRC-heap overflow, which
deliberately trades heap footprint for upload traffic. The ~20 MB spritesheet set
that overflows the 14.75 MB heap is **250 ms** of stores at 80 MB/s and **25 ms**
at 814.

## Which pages, exactly

`raster_backend_mfgpu.cpp`'s `mf_map_wc_overlay()` overlays only the half of the
window that is host-write / fabric-read, page-exactly:

```
0x3B000000..+0x001000  BLTCTRL: C_SUBMIT doorbell, C_DONE/C_STATUS polled   strongly-ordered
0x3B001000..+0x080000  ring A (from 0x1000) + ring B                        write-combining
0x3B080000..+0xF40000  SRC texture heap                                     write-combining
0x3BF40000..end        tilelist buf + SCANFRM (fabric-written)              strongly-ordered
```

Three independent reasons for those boundaries, all in the code comments:

- **The doorbell must not be write-combined.** One 32-bit store with no traffic
  behind it to force a drain; under WC it can sit in the write buffer while
  `blitter_top.sv`'s prologue polls a stale `C_SUBMIT`.
- **`C_DONE`/`C_STATUS` are written by the fabric** and polled by us. The whole
  control page stays as it was rather than reasoning about NC read behaviour on
  a location another master owns.
- **No page is mapped at two memory types.** The `MAP_FIXED` overlay *replaces*
  the strongly-ordered pages rather than aliasing them; a mismatched alias is
  architecturally unpredictable on ARMv7.

Ring A begins `0x40` into page 0 behind BLTCTRL, so its first `0xFC0` bytes
(~126 of ~8190 commands) stay strongly-ordered — ~1.5 % of ring capacity, in
exchange for the window staying two linear pointers.

### Windows deliberately left alone

`0x3A000000` — the native-video control word, the joystick words the fabric
writes, and the 64 KB audio ring at `0x3A0D0000` — stays strongly-ordered in
full. It is mapped by three separate call sites
(`native_video_writer.c`, `native_audio_writer.c`, `joy_ddr_reader.cpp`), which
is three chances to create the alias the rule above forbids, and the audio ring
moves 192 KB/s. There is nothing there worth the risk.

**If you ever do WC-map it, `native_audio_writer.c`'s `__sync_synchronize()`
before the `wr_ptr` publish has to become `dsb sy` first** — see the barrier note
below. It is correct today only because the strongly-ordered memory type is doing
the ordering for it.

## The barrier this requires

`__sync_synchronize()` lowers to `dmb ish` on ARMv7 — *inner-shareable*, the A9
cluster's own coherency domain. The fabric reaches DDR through the f2h SDRAM
ports, outside that domain, so `dmb ish` never ordered host stores against
`blitter_top.sv`'s reads at all. That was harmless only because the
strongly-ordered memory type did the ordering by itself.

Under the WC overlay it stops being harmless: Normal-NC stores sit in the write
buffer until something drains them, and an SO doorbell store is not ordered
against earlier Normal-NC stores either. `mf_ctrl_barrier()` is therefore
`MF_FENCE()` = `dsb sy`, unconditional on both mappings. Failure mode if it
regresses: a torn frame every few thousand publishes, which reads as a
rasterizer bug.

**Invariant:** exactly one `dsb sy` in `raster_backend_mfgpu.cpp`, on the publish
path. Check it the way it was checked when it landed:

```sh
arm-linux-gnueabihf-objdump -d build/arm-linux-gnueabihf/gmloader/mister/raster_backend_mfgpu.cpp.o \
  | grep -cE '\bdsb\b.*sy'      # 1
```

## Build

Needs the MiSTer kernel source prepared for out-of-tree modules, built with the
same toolchain the kernel used (`arm-none-linux-gnueabihf-gcc 10.2.1` for
5.15.1-MiSTer — check `/proc/version` on your device).

```sh
# 1. Matching kernel source
git clone https://github.com/MiSTer-devel/Linux-Kernel_MiSTer
cd Linux-Kernel_MiSTer
# check out the commit that produces the device's kernel version

# 2. Prepare it with the DEVICE'S OWN config so vermagic matches
scp root@<device>:/proc/config.gz . && zcat config.gz > .config
export ARCH=arm
export CROSS_COMPILE=/opt/gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf/bin/arm-none-linux-gnueabihf-
make olddefconfig
make modules_prepare

# 3. Build
cd /path/to/maldita.castilla-mister/tools/mister-mem-wc
make KDIR=/path/to/Linux-Kernel_MiSTer
```

Produces `mem_wc.ko`. The running kernel has `CONFIG_MODVERSIONS` and
`CONFIG_MODULE_SIG` off, so there is no symbol-CRC matching and no signing —
**only the vermagic string has to match**, which building against the same
source + `.config` guarantees.

## Prebuilt

`prebuilt/` holds one committed object per kernel release:

```
prebuilt/mem_wc-5.15.1-MiSTer.ko     5.3 KB, vermagic "5.15.1-MiSTer SMP mod_unload ARMv7 p2v8"
```

Committed rather than left to every user to build, because building it needs a
full kernel tree, the device's `/proc/config.gz` and a cross toolchain — and
"optional" would otherwise mean "off for everyone". The GPL-2.0 source sits next
to it, so shipping the object alongside it is exactly what the licence asks for.

**Named for its vermagic on purpose.** The kernel refuses a module whose vermagic
does not match exactly, so a MiSTer kernel update must turn into "there is no
object for this release, say so and carry on", never "ship the 5.15.1 object to a
6.x kernel and let `insmod` fail in the field". `deploy.py` matches on the
device's `uname -r` for that reason. After building against a new kernel:

```sh
make prebuilt KDIR=/path/to/Linux-Kernel_MiSTer   # strips + names it by vermagic
git add prebuilt/mem_wc-<release>.ko
```

`mem_wc.ko` at the top of this directory is a local build and stays gitignored.

## Install

`deploy.py` ships `prebuilt/mem_wc-$(uname -r).ko` to
`/media/fat/games/Maldita Castilla/mem_wc.ko`, and prints which kernel it wanted
if there is no match. It is never fatal.
`games/Maldita Castilla/mem_wc_load.sh`, sourced by the launcher, loads it
restricted to this core's own window:

```sh
insmod mem_wc.ko phys_base=0x3B000000 phys_size=0x01000000
```

That loader **reloads an already-present module** rather than reusing it, and
that is not paranoia: mamester loads this same driver restricted to
`0x3A000000+4MiB`, and a previous session's instance survives its core being
unloaded. `/dev/mem_wc` existing therefore does not mean it will accept our
window — with the wrong allowlist the `mmap` returns `EPERM` and the engine
falls back for no reason. `rmmod` fails safely if anything still holds it.

Manually:

```sh
insmod mem_wc.ko phys_base=0x3B000000 phys_size=0x01000000
dmesg | tail -1        # "mem_wc: loaded, restricted to [0x3b000000, 0x3c000000)"
ls -l /dev/mem_wc
```

## It is optional, on purpose

`mf_map_wc_overlay()` tries `/dev/mem_wc` and falls back to the strongly-ordered
`/dev/mem` mapping (the pattern is minicast's, `_vmem.cpp:22-38`). A MiSTer
kernel update invalidates the module's vermagic and `insmod` starts failing on
users' machines — that must cost frame rate, not boot. `mf_ddr_map()` logs which
mapping it got:

```
backend_mfgpu: DDR window 0x3b000000+16MiB, rings+heap write-combined (/dev/mem_wc)
backend_mfgpu: DDR window 0x3b000000+16MiB, rings+heap strongly-ordered (/dev/mem)
```

and every `MFSUBMIT` line carries `ddr=write-combined|strongly-ordered`, so an
A/B table cannot be mislabelled by a module that quietly failed to load.

`GMLOADER_NO_WC=1` forces the fallback without unloading the module — that is
the A/B arm.

### One trap worth knowing about

`MAP_FIXED` unmaps its target range **before** the driver's `.mmap` runs. A
rejected overlay — this module loaded with an allowlist that misses our window
returns `-EPERM` — would leave a *hole* from `0x3B001000` to `0x3BF40000` rather
than the strongly-ordered mapping we started from, and the next `blt_upload()`
takes `SIGSEGV` inside the heap allocator, at an address the allocator computed
correctly. `mf_map_wc_overlay()` therefore probes at a scratch address first,
`munmap`s, and only then commits.

## Verifying it actually worked

Two levels.

**The silicon** — mamester's `tools/mister/ddr-write-bench` prints the `memcpy`
rate through `/dev/mem_wc` against the rate through `/dev/mem`, into the same
physical bytes with the same instructions. Only the page attribute differs, so a
large ratio has nowhere to come from except the memory type. Measured on `.81`:
**80.3 → 813.9 MB/s, 10.1×**.

**The engine** — A/B `GMLOADER_NO_WC=1` against the default, on a **scene
transition**, with `GMLOADER_MFGPU_HEAPLOG=1` to see the uploads. Do not run this
on `ingame-stage1` steady state and conclude anything: `texup` is already 0.0 ms
there, and both arms will measure the same because neither is uploading.

**Do not "improve" the bench into a NEON-vs-`memcpy` check.** An earlier version
of it looked for hand-written NEON to overtake glibc `memcpy` under WC, on the
theory that the transaction-latency bound was all that held 128-bit stores back.
It is not: glibc's ARM `memcpy` is itself NEON with prefetch and better alignment
handling, so it wins under *both* memory types (`memcpy` 813.9 vs `neon` 556.0
write-combined). That check reported failure on a module that was working.

#!/bin/sh
#
# Load skmp/minicast's mem_wc driver, restricted to OUR fabric window, so the
# engine's rings and SRC texture heap can be mapped write-combining instead of
# strongly-ordered.
#
# SOURCED (not exec'd) by launch.sh before it starts the engine. Deliberately a
# separate file: launch.sh already carries a long preamble about who is allowed
# to start the engine, and none of that has anything to do with memory types.
#
# WHY. ARM's phys_mem_access_prot() (arch/arm/mm/mmu.c) hands any /dev/mem mmap
# pgprot_noncached() -- Strongly-Ordered -- when pfn_valid() is false, and only
# reaches the O_SYNC test that would give pgprot_writecombine() when it is true.
# /proc/iomem on this board puts System RAM at 0x00000000-0x1fefffff, so
# 0x3B000000 is outside the kernel's memblock and ALWAYS takes the first branch:
# no argument to /dev/mem yields write-combining. Strongly-Ordered stores cannot
# merge, so each one is its own bus transaction. Measured on .81 with mamester's
# tools/mister/ddr-write-bench, kernel 5.15.1-MiSTer:
#
#   memcpy -> /dev/mem       80.3 MB/s
#   memcpy -> /dev/mem_wc   813.9 MB/s      10.1x
#
# WHOLLY OPTIONAL, AND THAT IS THE POINT. mem_wc is built out-of-tree against
# one MiSTer kernel's vermagic, so a MiSTer update makes insmod start failing on
# users' machines. raster_backend_mfgpu.cpp's mf_map_wc_overlay() falls back to
# the strongly-ordered /dev/mem mapping on its own, so a failure here must cost
# frame rate and nothing else. Hence: no error checking, no exit path, and every
# command below swallows its own stderr.

_mwc_ko="$HANDLER_DIR/mem_wc.ko"
_mwc_base=0x3B000000       # MF_DEV_PHYS_BASE  (raster_backend_mfgpu.cpp)
_mwc_size=0x01000000       # MF_DEV_MAP_SIZE, 16 MiB

if [ -f "$_mwc_ko" ]; then
    # A module left loaded by ANOTHER core is the common case, not an edge case:
    # mamester loads the same driver restricted to 0x3A000000+4MiB, and a
    # previous session's instance survives its core being unloaded. That
    # allowlist excludes our window, so /dev/mem_wc existing does NOT mean it
    # will accept our mmap -- it would return -EPERM and the engine would fall
    # back for no reason. Reload it with our range if nothing else holds it;
    # rmmod fails safely (refcount) if something does.
    if [ -e /dev/mem_wc ]; then
        rmmod mem_wc 2>/dev/null
    fi
    if [ ! -e /dev/mem_wc ]; then
        insmod "$_mwc_ko" phys_base=$_mwc_base phys_size=$_mwc_size 2>/dev/null
    fi
fi

if [ -e /dev/mem_wc ]; then
    echo "mem_wc: loaded ($(dmesg | grep -c 'mem_wc: loaded') load events)" \
        >> "$LOGDIR/maldita.log" 2>/dev/null
else
    echo "mem_wc: not available -- DDR stays strongly-ordered" \
        >> "$LOGDIR/maldita.log" 2>/dev/null
fi

unset _mwc_ko _mwc_base _mwc_size

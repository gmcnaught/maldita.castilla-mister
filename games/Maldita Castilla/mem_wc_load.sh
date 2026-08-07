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

# TWO NAMES, because two things install this file. deploy.py matches the
# device's `uname -r` against tools/mister-mem-wc/prebuilt/ on the HOST and
# writes the winner as plain mem_wc.ko. The release bundle cannot do that --
# it is assembled once, for every device -- so it ships the prebuilt objects
# under their vermagic names and the match happens here instead. Vermagic name
# first so a deploy.py install onto a device that also has a bundle's objects
# still gets the one deploy.py deliberately chose.
#
# On a kernel neither path has an object for, both tests fail and _mwc_ko names
# a file that does not exist -- which is the intended outcome, not a gap. The
# module carries one tree's vermagic and insmod refuses any other, so "no
# object for this kernel" has to mean "say so and carry on" rather than "try
# the 5.15.1 object on a 6.x kernel".
_mwc_ko="$HANDLER_DIR/mem_wc-$(uname -r).ko"
[ -f "$_mwc_ko" ] || _mwc_ko="$HANDLER_DIR/mem_wc.ko"
_mwc_base=0x3B000000       # MF_DEV_PHYS_BASE  (raster_backend_mfgpu.cpp)
_mwc_size=0x01000000       # MF_DEV_MAP_SIZE, 16 MiB

# NEVER rmmod A MODULE WE DID NOT LOAD. This script used to reload an
# already-present mem_wc with our window, on the reasoning that mamester loads
# the same driver restricted to 0x3A000000+4MiB, that instance survives its core
# being unloaded, and its allowlist would make our mmap return -EPERM.
#
# That reload HUNG .81 on 2026-08-06, hard enough to need a power cycle. The
# evidence: maldita.log contained only launch.sh's header line and none of the
# lines below, and the last kernel message was "mem_wc: unloaded" -- so the
# rmmod succeeded and the box did not survive what followed.
#
# The reasoning was wrong in one specific place. `lsmod` showed refcount 0, and
# I read that as "nobody is using it". It only means "nobody has the device node
# OPEN". file_operations.owner holds a module reference for the lifetime of the
# FILE DESCRIPTOR, not of the mapping: a process that mmaps /dev/mem_wc and then
# closes the fd leaves a live remap_pfn_range VMA behind with no reference
# keeping the module loaded. Unloading under that is a dangling VMA.
#
# .62 never showed it because it has never run another core's instance to
# unload -- the "it worked on the test rig" that made this look safe.
#
# So: load it only when nothing else has. If a foreign instance is present, our
# mmap gets -EPERM and mf_map_wc_overlay() falls back to the strongly-ordered
# mapping on its own. That costs upload bandwidth on a machine that recently ran
# mamester. It cannot hang anyone, and that is the whole trade.
if [ -f "$_mwc_ko" ] && [ ! -e /dev/mem_wc ]; then
    insmod "$_mwc_ko" phys_base=$_mwc_base phys_size=$_mwc_size 2>/dev/null
    _mwc_ours=1
fi

# Three outcomes, deliberately distinguished. "present, not ours" is the one
# that matters: the engine will log strongly-ordered and the reason is here,
# not in the engine.
if [ ! -e /dev/mem_wc ]; then
    # Split, because these two want different things from the reader: a missing
    # object for this kernel is a build/packaging fact (nothing is wrong with
    # the device), whereas insmod refusing an object we DID ship is the case
    # worth a dmesg look.
    if [ -f "$_mwc_ko" ]; then
        _mwc_note="insmod $_mwc_ko failed (see dmesg) -- DDR stays strongly-ordered"
    else
        _mwc_note="no module for kernel $(uname -r) -- DDR stays strongly-ordered"
    fi
elif [ "$_mwc_ours" = 1 ]; then
    _mwc_note="loaded for [$_mwc_base, +$_mwc_size)"
else
    _mwc_note="already loaded by something else -- leaving it alone; if its \
allowlist excludes our window the engine falls back to strongly-ordered"
fi
echo "mem_wc: $_mwc_note" >> "$LOGDIR/maldita.log" 2>/dev/null
unset _mwc_ours _mwc_note

unset _mwc_ko _mwc_base _mwc_size

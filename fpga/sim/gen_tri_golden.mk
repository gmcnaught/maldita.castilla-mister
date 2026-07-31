# gen_tri_golden.mk — host cc build for the BLT_OP_TRILIST golden-vector
# generator (see gen_tri_golden.c's header comment for the ddr.hex/exp.hex
# layout contract that fpga/sim/vectors/*.hex must satisfy).
#
# Usage (from fpga/sim):
#   make -f gen_tri_golden.mk            # build ./gen_tri_golden
#   make -f gen_tri_golden.mk vectors    # build + regenerate all 5 scenarios
#   make -f gen_tri_golden.mk clean
#
# ── CONTRACT PIN (2026-07-26) ────────────────────────────────────────────────
# REFMODEL used to be the SIBLING checkout ../../../mister-fpga-blitter, which
# tracks a MOVING branch. On 2026-07-24 that branch took 2bab201 ("Sync contract
# code from solarus-mister"), which inserted BGPLANE_WRITE=8 / CLUT_UPLOAD=9 /
# SPRITELIST=10 / TILEMAP=11 and thereby renumbered:
#     BLT_OP_TRILIST     10 -> 12
#     BLT_OP_SET_TARGET  11 -> 13
# The RTL (rtl/blitter_defs.vh) and the shipped engine BOTH still speak 10/11
# (the gmloader submodule pointer was never bumped), so regenerating goldens
# from the sibling would have silently emitted vectors encoding TRILIST as 12 —
# an opcode this fabric decodes as nothing — turning the bit-exact gate into a
# check of the WRONG contract while still "passing".
#
# Read the gmloader-next refmodel instead: it is the exact source the engine binary is
# compiled from, so the golden and the device share one contract, and contract-check below
# enforces that agreement on every generator build.
#
# CAVEAT (be honest about what this path is): maldita is NOT a submodule of mister-gmloader,
# so this resolves to the SIBLING WORKING CHECKOUT of gmloader-next on whatever branch it
# happens to be on — it is NOT pinned by a recorded commit pointer. Since contract-check
# joined run_sims.sh, the whole battery hard-fails at step 0 if that checkout drifts or is
# absent (a fresh clone without it runs ZERO testbenches). Pinning this properly is an open
# follow-up.
REFMODEL  := ../../../gmloader-next/3rdparty/mfgpu/refmodel
RTLDEFS   := ../rtl/blitter_defs.vh
CC        ?= cc
CFLAGS    ?= -O2 -Wall

SCENARIOS := tri_copy tri_key tri_calpha tri_add tri_quad tri_surface tri_uvfull tri_missdst tri_surfalpha

.PHONY: all vectors clean contract-check stream-vectors stream-vectors-heavy
all: gen_tri_golden gen_system_golden gen_tri_stream

# Refuse to build a golden generator whose refmodel disagrees with the RTL on
# the opcodes the vectors encode. Without this the only symptom of a contract
# drift is a bit-exact suite that quietly stops testing the shipped fabric.
contract-check:
	@test -f $(REFMODEL)/blitter_ref.h || { \
	  echo "ERROR: refmodel not found at $(REFMODEL)"; \
	  echo "       (expected the gmloader-next submodule; run git submodule update --init there)"; \
	  exit 1; }
	@fail=0; for op in TRILIST SET_TARGET; do \
	  c=`grep "BLT_OP_$$op" $(REFMODEL)/blitter_ref.h | grep '=' | head -1 | grep -o '= *[0-9][0-9]*' | grep -o '[0-9][0-9]*'`; \
	  r=`grep "define OP_$$op" $(RTLDEFS) | head -1 | sed "s/.*8'd//" | grep -o '^[0-9][0-9]*'`; \
	  if [ -z "$$c" ] || [ -z "$$r" ]; then \
	    echo "ERROR: could not extract OP_$$op (refmodel='$$c' rtl='$$r')"; fail=1; \
	  elif [ "$$c" != "$$r" ]; then \
	    echo "ERROR: contract drift on BLT_OP_$$op — refmodel=$$c but RTL=$$r"; fail=1; \
	  fi; \
	done; \
	if [ $$fail -ne 0 ]; then \
	  echo "       REFMODEL = $(REFMODEL)"; \
	  echo "       Goldens generated now would NOT match the fabric. Fix the pin"; \
	  echo "       (or land the renumber in the RTL) before regenerating vectors."; \
	  exit 1; \
	fi; \
	echo "contract-check: refmodel and RTL agree on TRILIST/SET_TARGET"
	@cw=$$(sed -n 's/#define BLT_FB_WIDTH[[:space:]]*\([0-9]*\).*/\1/p' $(REFMODEL)/blitter_ref.h); \
	ch=$$(sed -n 's/#define BLT_FB_HEIGHT[[:space:]]*\([0-9]*\).*/\1/p' $(REFMODEL)/blitter_ref.h); \
	vw=$$(sed -n 's/`define FB_W[[:space:]]*\([0-9]*\).*/\1/p' $(RTLDEFS)); \
	vh=$$(sed -n 's/`define FB_H[[:space:]]*\([0-9]*\).*/\1/p' $(RTLDEFS)); \
	if [ -z "$$cw" ] || [ -z "$$vw" ] || [ -z "$$ch" ] || [ -z "$$vh" ]; then \
	  echo "CONTRACT DIMS: could not extract (c=$$cw x $$ch, v=$$vw x $$vh)"; \
	  echo "       The \\([0-9]*\\) captures match the EMPTY string, so a root that stops"; \
	  echo "       being a bare integer would otherwise compare '' == '' and PASS vacuously."; \
	  exit 1; \
	fi; \
	if [ "$$cw" != "$$vw" ] || [ "$$ch" != "$$vh" ]; then \
	  echo "CONTRACT DIMS MISMATCH: refmodel $$cw x $$ch vs blitter_defs.vh $$vw x $$vh"; exit 1; \
	fi; echo "contract-check dims OK ($$cw x $$ch)"

gen_tri_golden: gen_tri_golden.c blt_tri.c | contract-check
	$(CC) $(CFLAGS) -I $(REFMODEL) -o $@ gen_tri_golden.c

# [app-surface v1] Task 8 full-frame integration golden: a two-pass ring executed
# by the reference blt_execute() (surface render + sample). Emits the ring + vertex
# heap + the golden WORK framebuffer for tb_blitter_system_pipe.sv's surface phase.
gen_system_golden: gen_system_golden.c blt_tri.c | contract-check
	$(CC) $(CFLAGS) -I $(REFMODEL) -o $@ gen_system_golden.c

# [Phase 3A Task 5] Stream-replay generator: same ring/vertex packing and golden
# emission as gen_tri_golden, but the scene comes from a CAPTURED DEVICE draw
# stream (an MFTRACE text file) instead of a hand-written scenario. Single-source
# like its sibling (blt_tri.c / blitter_ref.c arrive by #include), so blt_tri.c is
# a prerequisite but NOT a second file on the cc line.
gen_tri_stream: gen_tri_stream.c blt_tri.c | contract-check
	$(CC) $(CFLAGS) -I $(REFMODEL) -o $@ gen_tri_stream.c

vectors: gen_tri_golden gen_system_golden
	mkdir -p vectors
	for s in $(SCENARIOS); do ./gen_tri_golden $$s; done
	./gen_system_golden

# ── stream-replay vectors ────────────────────────────────────────────────────
# TRACEDIR points at the committed device captures (Task 3). Only stream_quiet_f0
# is COMMITTED (it is what tb_blitter_trilist_stream.sv loads by default and what
# run_sims.sh gates on); the other frames are ~700 KiB each and are regenerated on
# demand:
#   make -f gen_tri_golden.mk stream-vectors                    # quiet frame 0
#   ./gen_tri_stream $(TRACEDIR)/mftrace-quiet.txt 1 stream_quiet_f1
#   ./gen_tri_stream $(TRACEDIR)/mftrace-arrival.txt 3 stream_arrival_f3
# then run the tb against one with -DSTREAM_VEC='"stream_quiet_f1"' (see the tb header).
# Same "sibling working checkout, not a recorded pin" caveat as REFMODEL above:
# the captures live in the mister-gmloader bundler repo, not in this one. Nothing
# at TB RUN time needs them (the committed vectors/*.hex are self-contained) — the
# path is only needed to REGENERATE vectors.
TRACEDIR := ../../../mister-gmloader/docs/superpowers/findings/data
stream-vectors: gen_tri_stream
	mkdir -p vectors
	./gen_tri_stream $(TRACEDIR)/mftrace-quiet.txt 0 stream_quiet_f0

# [Phase 4 Stage B] The heavy scene is the gate anchor (cov_px ~213,358, device
# frame 18.02 ms pre-W2). Committed like stream_quiet_f0 because run_sims.sh
# gates on it; regenerate with this target if the capture is ever re-taken.
#
# The input trace (mftrace-heavy-b.txt) is NOT recorded under the default
# TRACEDIR above — it lives wherever Task 2/5's capture was taken and is
# passed explicitly on the command line, e.g.:
#   make -f gen_tri_golden.mk stream-vectors-heavy \
#     TRACEDIR=/path/to/the/capture/dir
# Frame index 0 (gen_tri_stream's --frame arg) selects the FIRST distinct
# f= value in file order, which for this capture is device frame f=1890 —
# the first frame of the f=1890..1960 gate-anchor plateau (all measured at
# cov_px=213358; confirmed with scripts/mftrace_analyze.py
# --expect-covered 213358, not from any engine console log — a live
# MFSUBMIT log line for the same n=1890 is known to disagree with the
# trace's own f=1890 outside the plateau).
#
# HONESTY NOTE: MFTRACE only records triangle groups (MFTRACE G / MFTRACE
# V); it has no fill/clear commands. gen_tri_stream.c therefore synthesizes
# exactly ONE full-screen clear itself via the control-block path. The real
# device issues roughly THREE full-extent clears per frame, so this vector
# is not a like-for-like model of the device's clear cost — one synthesized
# clear here vs ~3 on hardware. That gap is for a later calibration task,
# not this one.
#
# PROVENANCE: this committed vector was captured PRE-W2 (before the engine-side
# deferred-clear elision landed). That capture is still valid post-W2 without
# regeneration: W2 only removes redundant full-screen clears, MFTRACE never
# recorded clears in the first place (only triangle groups, per the HONESTY
# NOTE above), and a device A/B on the same scene proved `tri`, `dpath`,
# `texwait` and `cov_px` bit-identical pre- vs post-W2. Device fabric frame for
# this scene is 18.02 ms pre-W2 / 16.68 ms post-W2 — see the tb headers for the
# full comparison; calibrate against 16.68 ms going forward.
stream-vectors-heavy: gen_tri_stream
	mkdir -p vectors
	./gen_tri_stream $(TRACEDIR)/mftrace-heavy-b.txt 0 stream_heavy_f0

clean:
	rm -f gen_tri_golden gen_system_golden gen_tri_stream

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

.PHONY: all vectors clean contract-check
all: gen_tri_golden gen_system_golden

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

vectors: gen_tri_golden gen_system_golden
	mkdir -p vectors
	for s in $(SCENARIOS); do ./gen_tri_golden $$s; done
	./gen_system_golden

clean:
	rm -f gen_tri_golden gen_system_golden

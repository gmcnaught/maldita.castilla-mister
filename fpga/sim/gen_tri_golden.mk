# gen_tri_golden.mk — host cc build for the BLT_OP_TRILIST golden-vector
# generator (see gen_tri_golden.c's header comment for the ddr.hex/exp.hex
# layout contract that fpga/sim/vectors/*.hex must satisfy).
#
# Usage (from fpga/sim):
#   make -f gen_tri_golden.mk            # build ./gen_tri_golden
#   make -f gen_tri_golden.mk vectors    # build + regenerate all 5 scenarios
#   make -f gen_tri_golden.mk clean
#
# mister-fpga-blitter is assumed to be a sibling checkout of this repo (same
# path this file's header comment and the sdd task brief use):
#   cc -O2 -I ../../../mister-fpga-blitter/refmodel -o gen_tri_golden gen_tri_golden.c
REFMODEL  := ../../../mister-fpga-blitter/refmodel
CC        ?= cc
CFLAGS    ?= -O2 -Wall

SCENARIOS := tri_copy tri_key tri_calpha tri_add tri_quad

.PHONY: all vectors clean
all: gen_tri_golden

gen_tri_golden: gen_tri_golden.c blt_tri.c
	$(CC) $(CFLAGS) -I $(REFMODEL) -o $@ gen_tri_golden.c

vectors: gen_tri_golden
	mkdir -p vectors
	for s in $(SCENARIOS); do ./gen_tri_golden $$s; done

clean:
	rm -f gen_tri_golden

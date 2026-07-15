/*
 *  gen_tri_golden.c — per-scenario DDR-init + expected-framebuffer generator
 *  for BLT_OP_TRILIST (the golden textured-triangle rasterizer).
 *
 *  THIS FILE'S OUTPUT IS A CONTRACT. The Task-5 RTL testbench (expected to be
 *  a TRILIST-flavoured clone of fpga/sim/tb_blitter_copy_pipe.sv) MUST load
 *  <scen>_ddr.hex into the SAME `mem[]` array at the SAME offsets documented
 *  below, and diff comp_fbram against <scen>_exp.hex. Read this header before
 *  writing that testbench.
 *
 *  ===========================================================================
 *  1. vectors/<scen>_ddr.hex — sparse $readmemh image of the testbench mem[]
 *  ===========================================================================
 *
 *  tb_blitter_copy_pipe.sv declares:
 *      localparam [28:0] WBASE = 29'h07400000;                  // == VCTRL_QW (real)
 *      localparam        MEMQW = (`SRC_QW - WBASE) + 29'h8000;  // SRC window + 32Ki headroom
 *      reg [63:0] mem [0:MEMQW-1];
 *  and indexes mem[] directly by (real qword address - WBASE) -- e.g. it
 *  writes the control block at mem[32'h200000] and the ring at
 *  mem[32'h200008], and its behavioral-DDR beat logic subtracts the SAME
 *  WBASE from bt_addr before indexing mem[].
 *
 *  Deriving the SAME offsets from fpga/rtl/blitter_defs.vh (the real HW map;
 *  all `_QW constants there are QWORD addresses, i.e. byte_addr>>3):
 *      WBASE     = VCTRL_QW    = 29'h07400000
 *      CTRL_OFF  = BLTCTRL_QW - WBASE = 0x07600000 - 0x07400000 = 0x200000
 *      RING_OFF  = RING_QW    - WBASE = 0x07600008 - 0x07400000 = 0x200008
 *                  (== CTRL_OFF+8 -- the ring is CONTIGUOUS with the 8-qword
 *                  control block, exactly as BLTCTRL_QW+8 == RING_QW in HW)
 *      SRC_OFF   = SRC_QW     - WBASE = 0x07610000 - 0x07400000 = 0x210000
 *
 *  This generator's <scen>_ddr.hex uses these SAME three offsets, laid out as:
 *
 *      @200000                     (CTRL_OFF -- 8 qwords, one control field each)
 *        +0 C_SUBMIT   = 1
 *        +1 C_CMDCOUNT = 2                       (TRILIST header + END)
 *        +2 C_TARGET   = 0                       (BUF0)
 *        +3 C_CLEAR    = 0x001f                  (blue RGB565 -- the scene bg)
 *        +4 C_FLAGS    = 1                       (bit0 = CLEAR-before-list. comp_fbram
 *                                                  is on-chip BRAM, NOT preloaded from this
 *                                                  DDR image, so the hw CLEAR path is the
 *                                                  ONLY way to establish the blue bg that
 *                                                  <scen>_exp.hex below assumes as its start
 *                                                  state -- see blitter_top.sv's S_CLEAR_*.)
 *        +5 C_DONE     = 0
 *        +6 C_STATUS   = 0
 *        +7 C_SRCSEL/C_PIPE = 0                  (defaults; comp_pipeline is already the
 *                                                  sole renderer -- see blitter_top.sv)
 *      @200008                     (RING_OFF -- immediately follows the control block;
 *                                   one command = 32 bytes = 4 qwords, packed little-
 *                                   endian per the wire layout in
 *                                   mister-fpga-blitter/host/blt_wire.h's blt_pack_cmd
 *                                   (reproduced locally here as pack_cmd(), since the
 *                                   documented host build command only -I's refmodel/):
 *                                     u32[0] = opcode | blend<<8 | format<<16 | flags<<24
 *                                     u32[1] = src_off
 *                                     u32[2] = src_stride | src_x<<16
 *                                     u32[3] = w | h<<16
 *                                     u32[4] = src_y
 *                                     u32[5] = (u16)dst_x | (u16)dst_y<<16
 *                                     u32[6] = colorkey | alpha<<16 | _pad[2]<<24
 *                                     u32[7] = color | _pad[0]<<16 | _pad[1]<<24
 *        cmd0 (4 qwords): opcode=BLT_OP_TRILIST(10), blend_mode=<scenario>,
 *                         format=BLT_FMT_RGB565, src_off=0 (texture at SRC_OFF+0),
 *                         src_stride/src_x/src_y = texture geometry (8x8, 16B/row),
 *                         w=ntris, dst_x|dst_y<<16=EOFF (vertex-array byte offset,
 *                         see below), colorkey=<scenario>, alpha=<scenario hdr alpha>
 *        cmd1 (4 qwords): opcode=BLT_OP_END(1), every other field 0
 *      @210000                     (SRC_OFF -- source surface heap)
 *        +0     8x8 RGB565 texture, 128 bytes = 16 qwords, row-major
 *        +0x80  ntris*3 blt_vtx_t vertices (16 bytes each), one triangle per
 *               consecutive triple (a,b,c) -- EOFF==0x80 for every scenario
 *               here (one 8x8 texture page always precedes the verts)
 *
 *  Everything outside these three windows is left at the testbench's own
 *  reset value (0): $readmemh's "@addr" directive repositions the write
 *  pointer only, so a huge mem[] (MEMQW ~ 0x218000 qwords in the real tb) never
 *  needs a multi-megabyte hex dump -- this generator emits ONLY the qwords it
 *  actually sets, prefixed by an "@addr" line per contiguous window.
 *
 *  ===========================================================================
 *  2. vectors/<scen>_exp.hex — golden framebuffer, ONE RGB565 value per line
 *  ===========================================================================
 *
 *  76800 (= 320*240) lines, pixel-linear order: line index = y*320+x, each
 *  line a 4-hex-digit RGB565 value. Computed by calling blt_raster_tri() --
 *  THE golden math the RTL blt_tri module must reproduce bit-for-bit -- over
 *  the SAME scene onto an all-blue (0x001f) cleared field. That is: this file
 *  models "framebuffer contents after hw CLEAR, after the TRILIST command",
 *  matching exactly what the control block above asks the fabric to do.
 *
 *  comp_fbram itself is addressed as one qword (4 RGB565 lanes) per (y,x>>2):
 *  qword index = y*80+(x>>2), lane = x&3 (see tb_blitter_copy_pipe.sv's `check`
 *  task). The Task-5 testbench is expected to $readmemh this file into a
 *  same-shaped uint16 fb[320*240] array and compare fb[y*320+x] against
 *  fbram.bank{x&3}[y*80+(x>>2)].
 *
 *  ===========================================================================
 *  Scenarios (argv[1])
 *  ===========================================================================
 *    tri_copy   - one triangle, solid white 8x8 texture tinted magenta by the
 *                 (uniform) per-vertex color, BLT_BLEND_COPY (opaque).
 *    tri_key    - one triangle, texture split black|green (left|right half),
 *                 BLT_BLEND_COLORKEY keying out the black half (cutout to the
 *                 blue background), untinted (white vertex color).
 *    tri_calpha - one triangle, solid white texture tinted magenta, per-vertex
 *                 ALPHA varies (64/160/255) across the 3 verts, header alpha=255
 *                 (no extra attenuation) so the vertex alpha alone drives the
 *                 BLT_BLEND_CONST_ALPHA blend against the blue background.
 *    tri_add    - one triangle, solid white texture tinted dim magenta,
 *                 BLT_BLEND_ADD (saturating per-channel add) over blue.
 *    tri_quad   - TWO triangles (one TRILIST header, w=2) sharing an edge to
 *                 form an axis-aligned quad, sampling a 4-quadrant 8x8 checker
 *                 texture across the whole quad, BLT_BLEND_COPY, untinted --
 *                 proves the two-triangle seam lines up pixel-for-pixel.
 *
 *  GPL-3.0.
 */
#include "blitter_ref.h"
/* blt_tri.c's blt_raster_tri() calls the RGB565 blend helpers (blt_tint565 /
 * blt_blend565 / blt_add565 / blt_mul565 / blt_rgb565); those bodies live in
 * blitter_ref.c, not the header. The documented build command is single-
 * source (`cc ... gen_tri_golden.c`, no second .c on the link line), so pull
 * blitter_ref.c in the same way the brief has us pull in blt_tri.c. */
#include "blitter_ref.c"
#include "blt_tri.c"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

/* ---- windowed sim offsets (qword units, relative to WBASE) -- see header -- */
#define WBASE     0x07400000u   /* == VCTRL_QW (real); tb subtracts this from bt_addr */
#define CTRL_OFF  0x00200000u   /* BLTCTRL_QW(real) - WBASE                            */
#define RING_OFF  0x00200008u   /* RING_QW(real)    - WBASE  (== CTRL_OFF+8)           */
#define SRC_OFF   0x00210000u   /* SRC_QW(real)     - WBASE                            */

#define FB_W  320
#define FB_H  240
#define BLUE  0x001Fu           /* RGB565 blue -- the scene clear color                */
#define EOFF  0x80u             /* vertex-array byte offset within the SRC heap        */

/* ---- 32-byte on-wire command packing (mirrors host/blt_wire.h::blt_pack_cmd,
 * reproduced locally since the documented build only -I's refmodel/) --------- */
#define BLT_CMD_BYTES 32
static void wr32(uint8_t *p, uint32_t v) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); p[2]=(uint8_t)(v>>16); p[3]=(uint8_t)(v>>24); }
static void pack_cmd(const blt_cmd_t *c, uint8_t out[BLT_CMD_BYTES]) {
    wr32(out+0,  (uint32_t)c->opcode | ((uint32_t)c->blend_mode<<8) |
                 ((uint32_t)c->format<<16) | ((uint32_t)c->flags<<24));
    wr32(out+4,  c->src_off);
    wr32(out+8,  (uint32_t)c->src_stride | ((uint32_t)c->src_x<<16));
    wr32(out+12, (uint32_t)c->w | ((uint32_t)c->h<<16));
    wr32(out+16, (uint32_t)c->src_y);
    wr32(out+20, (uint32_t)(uint16_t)c->dst_x | ((uint32_t)(uint16_t)c->dst_y<<16));
    wr32(out+24, (uint32_t)c->colorkey | ((uint32_t)c->alpha<<16) | ((uint32_t)c->_pad[2]<<24));
    wr32(out+28, (uint32_t)c->color | ((uint32_t)c->_pad[0]<<16) | ((uint32_t)c->_pad[1]<<24));
}

/* ---- scene state -------------------------------------------------------- */
static uint8_t   heap[4096];
static uint32_t  heap_len = 0;
static blt_vtx_t verts[6];
static int       ntris = 0;
static blt_cmd_t hdr;
static uint16_t  fb[FB_W*FB_H];

static blt_vtx_t VTX(int px, int py, int u, int v, uint8_t cr, uint8_t cg, uint8_t cb, uint8_t ca) {
    blt_vtx_t t;
    t.x = (int16_t)(px*16); t.y = (int16_t)(py*16);
    t.u = (uint16_t)u;      t.v = (uint16_t)v;
    t.rgba = (uint32_t)cr | ((uint32_t)cg<<8) | ((uint32_t)cb<<16) | ((uint32_t)ca<<24);
    t._rsvd = 0;
    return t;
}

/* 8x8 solid-color RGB565 texture at heap offset 0. */
static void tex_solid8(uint16_t val) {
    for (int i=0;i<64;i++) { heap[i*2]=(uint8_t)val; heap[i*2+1]=(uint8_t)(val>>8); }
    if (heap_len < 128) heap_len = 128;
}
/* 8x8 texture, left 4 cols = `key`, right 4 cols = `show` (for the COLORKEY scenario). */
static void tex_halfkey(uint16_t key, uint16_t show) {
    for (int y=0;y<8;y++) for (int x=0;x<8;x++) {
        uint16_t c = (x<4) ? key : show;
        size_t o = (size_t)(y*8+x)*2;
        heap[o]=(uint8_t)c; heap[o+1]=(uint8_t)(c>>8);
    }
    if (heap_len < 128) heap_len = 128;
}
/* 8x8 texture, 4 alternating 4x4 quadrants (for the tri_quad scenario). */
static void tex_checker8(uint16_t a, uint16_t b) {
    for (int y=0;y<8;y++) for (int x=0;x<8;x++) {
        uint16_t c = (((x>>2)+(y>>2))&1) ? b : a;
        size_t o = (size_t)(y*8+x)*2;
        heap[o]=(uint8_t)c; heap[o+1]=(uint8_t)(c>>8);
    }
    if (heap_len < 128) heap_len = 128;
}

/* Place n vertices (n==3 or 6) at the fixed EOFF vertex region. */
static void put_verts(const blt_vtx_t *v, int n) {
    memcpy(verts, v, (size_t)n*sizeof(blt_vtx_t));
    ntris = n/3;
    memcpy(heap+EOFF, v, (size_t)n*sizeof(blt_vtx_t));
    size_t end = EOFF + (size_t)n*sizeof(blt_vtx_t);
    if (heap_len < end) heap_len = (uint32_t)end;
}

static void set_hdr(uint8_t blend, uint16_t tw, uint16_t th, uint16_t stride,
                     uint16_t colorkey, uint8_t alpha) {
    memset(&hdr, 0, sizeof hdr);
    hdr.opcode = BLT_OP_TRILIST;
    hdr.blend_mode = blend;
    hdr.format = BLT_FMT_RGB565;
    hdr.src_off = 0;              /* texture lives at SRC_OFF+0 */
    hdr.src_stride = stride;
    hdr.src_x = tw; hdr.src_y = th;
    hdr.w = (uint16_t)ntris;
    hdr.dst_x = (int16_t)(EOFF & 0xFFFFu);
    hdr.dst_y = (int16_t)(EOFF >> 16);
    hdr.colorkey = colorkey;
    hdr.alpha = alpha;
}

static int build(const char *s) {
    memset(heap, 0, sizeof heap);
    heap_len = 0;

    if (!strcmp(s, "tri_copy")) {
        tex_solid8(0xFFFF);
        blt_vtx_t v[3] = {
            VTX(100,80, 0,0, 255,0,255,255),
            VTX(180,80, 0,0, 255,0,255,255),
            VTX(140,160,0,0, 255,0,255,255),
        };
        put_verts(v,3);
        set_hdr(BLT_BLEND_COPY, 8,8,16, 0, 255);
    } else if (!strcmp(s, "tri_key")) {
        uint16_t key  = blt_rgb565(0,0,0);     /* black -- keyed out            */
        uint16_t show = blt_rgb565(0,255,0);   /* green -- rendered              */
        tex_halfkey(key, show);
        blt_vtx_t v[3] = {
            VTX(100,80,   0,  0, 255,255,255,255),
            VTX(180,80, 128,  0, 255,255,255,255),
            VTX(140,160, 64,128, 255,255,255,255),
        };
        put_verts(v,3);
        set_hdr(BLT_BLEND_COLORKEY, 8,8,16, key, 255);
    } else if (!strcmp(s, "tri_calpha")) {
        tex_solid8(0xFFFF);
        blt_vtx_t v[3] = {
            VTX(100,80, 0,0, 255,0,255, 64),   /* ~25% */
            VTX(180,80, 0,0, 255,0,255,160),   /* ~63% */
            VTX(140,160,0,0, 255,0,255,255),   /* opaque */
        };
        put_verts(v,3);
        set_hdr(BLT_BLEND_CONST_ALPHA, 8,8,16, 0, 255);
    } else if (!strcmp(s, "tri_add")) {
        tex_solid8(0xFFFF);
        blt_vtx_t v[3] = {
            VTX(100,80, 0,0, 128,0,128,255),
            VTX(180,80, 0,0, 128,0,128,255),
            VTX(140,160,0,0, 128,0,128,255),
        };
        put_verts(v,3);
        set_hdr(BLT_BLEND_ADD, 8,8,16, 0, 255);
    } else if (!strcmp(s, "tri_quad")) {
        uint16_t a = blt_rgb565(255,0,0), b = blt_rgb565(0,255,0);
        tex_checker8(a,b);
        blt_vtx_t v[6] = {
            VTX(60,60,   0,  0, 255,255,255,255),
            VTX(180,60, 128,  0, 255,255,255,255),
            VTX(180,180,128,128, 255,255,255,255),
            VTX(60,60,   0,  0, 255,255,255,255),
            VTX(180,180,128,128, 255,255,255,255),
            VTX(60,180,  0,128, 255,255,255,255),
        };
        put_verts(v,6);
        set_hdr(BLT_BLEND_COPY, 8,8,16, 0, 255);
    } else {
        fprintf(stderr, "unknown scenario '%s'\n", s);
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s <scenario>\n", argv[0]); return 2; }
    if (build(argv[1])) return 2;

    /* --- golden framebuffer: blue clear + blt_raster_tri (THE golden math) --- */
    for (int i=0;i<FB_W*FB_H;i++) fb[i] = (uint16_t)BLUE;
    blt_surface_heap_t sh = { heap, heap_len, 0, 0 };
    blt_raster_tri(fb, &sh, &hdr, verts, ntris);

    /* --- ring: TRILIST header + END, wire-packed --- */
    blt_cmd_t end_cmd; memset(&end_cmd, 0, sizeof end_cmd);
    end_cmd.opcode = BLT_OP_END;
    uint8_t w0[BLT_CMD_BYTES], w1[BLT_CMD_BYTES];
    pack_cmd(&hdr, w0);
    pack_cmd(&end_cmd, w1);

    char ddrpath[256], exppath[256];
    snprintf(ddrpath, sizeof ddrpath, "vectors/%s_ddr.hex", argv[1]);
    snprintf(exppath, sizeof exppath, "vectors/%s_exp.hex", argv[1]);

    FILE *fd = fopen(ddrpath, "w");
    if (!fd) { perror("fopen ddr.hex"); return 1; }

    fprintf(fd, "@%x\n", CTRL_OFF);
    uint64_t ctrl[8] = { 1, 2, 0, BLUE, 1, 0, 0, 0 }; /* SUBMIT,CMDCOUNT,TARGET,CLEAR,FLAGS,DONE,STATUS,SRCSEL */
    for (int i=0;i<8;i++) fprintf(fd, "%016llx\n", (unsigned long long)ctrl[i]);
    /* RING_OFF == CTRL_OFF+8: contiguous, no new @addr needed */
    for (int q=0;q<4;q++) { uint64_t v; memcpy(&v, w0+q*8, 8); fprintf(fd, "%016llx\n", (unsigned long long)v); }
    for (int q=0;q<4;q++) { uint64_t v; memcpy(&v, w1+q*8, 8); fprintf(fd, "%016llx\n", (unsigned long long)v); }

    fprintf(fd, "@%x\n", SRC_OFF);
    uint32_t src_qwords = (heap_len + 7u) / 8u;
    for (uint32_t q=0; q<src_qwords; q++) {
        uint64_t v; memcpy(&v, heap+(size_t)q*8, 8);
        fprintf(fd, "%016llx\n", (unsigned long long)v);
    }
    fclose(fd);

    FILE *fe = fopen(exppath, "w");
    if (!fe) { perror("fopen exp.hex"); return 1; }
    for (int i=0;i<FB_W*FB_H;i++) fprintf(fe, "%04x\n", fb[i]);
    fclose(fe);

    printf("gen_tri_golden: scenario=%s ntris=%d heap=%uB -> %s , %s\n",
           argv[1], ntris, (unsigned)heap_len, ddrpath, exppath);
    return 0;
}

/*
 *  gen_system_golden.c — golden generator for the Task 8 full-frame integration
 *  scene (render-into-surface -> sample-over-WORK), computed by the reference
 *  executor blt_execute() so the RTL is diffed bit-exact against it.
 *
 *  The scene is a reduced Task-1 frame graph (mirrors test_blitter_ref.c's
 *  surface-src scene from Task 3), a two-pass ring:
 *    cmd0  SET_TARGET APPSURF
 *    cmd1  FILL teal    fullscreen        -> clear the app-surface
 *    cmd2  FILL magenta 40x40 @(0,0)      -> "sprite" into the app-surface
 *    cmd3  SET_TARGET WORK
 *    cmd4  FILL blue    fullscreen        -> clear WORK
 *    cmd5  FILL green   120xFB_H @(200,0) -> background into WORK (right region;
 *                                            clips to x=200..FB_W-1 at 288 wide)
 *    cmd6  TRILIST 2 tris, quad (0,0)-(160,240), UV==position, BLT_F_SRC_SURFACE,
 *          (the quad's y=240 clips to FB_H — deliberate: clipping is under test)
 *          BLEND_COPY                      -> sample the app-surface over WORK (left region)
 *    cmd7  END
 *  So the final WORK is: left = app-surface sampled (teal + the magenta sprite,
 *  with the rasterizer's +1 texel sample offset), a strip of the blue clear, and
 *  the green background on the right — every layer observable.
 *
 *  LAYER_ORDER honored: SET_TARGET(WORK) precedes the BLT_F_SRC_SURFACE draw; the
 *  self-referential combo (target==APPSURF while sampling SRC_SURFACE) is NOT built.
 *
 *  Outputs (mem[] window offsets == tb_blitter_system_pipe.sv):
 *    vectors/sys_surface_ddr.hex : @200008 ring (8 cmds x 4 qw) + @210000 heap (verts)
 *    vectors/sys_surface_exp.hex : FB_W*FB_H RGB565, line = y*FB_W+x (the golden WORK;
 *                                  62208 @ 288x216)
 *  The testbench sets the control block (cmd_count=8, target=0, flags=0) itself and
 *  bumps submit; only the ring + vertex heap come from the .hex.
 *
 *  GPL-3.0.
 */
#include "blitter_ref.h"
#include "blitter_ref.c"
#include "blt_tri.c"   /* blt_execute() calls blt_raster_tri() (local 6-arg surface mirror) */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#define RING_OFF  0x00200008u   /* RING_QW(real) - WBASE (== BLTCTRL+8)           */
#define SRC_OFF   0x00210000u   /* SRC_QW(real)  - WBASE                          */
/* GEOMETRY: taken from the single C-domain root in blitter_ref.h — never retype a
 * dimension here (native-288x216 single-source rule). gen_tri_golden.mk's
 * contract-check gates this root against the Verilog root (`FB_W/`FB_H). */
#define FB_W  BLT_FB_WIDTH
#define FB_H  BLT_FB_HEIGHT
#define EOFF  0u                /* vertex-array byte offset in the heap (entry_off) */

#define BLT_CMD_BYTES 32
static void wr32(uint8_t *p, uint32_t v){ p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); p[2]=(uint8_t)(v>>16); p[3]=(uint8_t)(v>>24); }
static void pack_cmd(const blt_cmd_t *c, uint8_t out[BLT_CMD_BYTES]){
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

static blt_vtx_t SV(int px, int py){
    blt_vtx_t t;
    t.x = (int16_t)(px<<4); t.y = (int16_t)(py<<4);
    t.u = (uint16_t)(px<<4); t.v = (uint16_t)(py<<4);   /* UV == position (12.4) */
    t.rgba = BLT_RGBA(255,255,255,255);
    t._rsvd = 0;
    return t;
}

int main(void){
    const uint16_t TEAL=0x0410, MAGENTA=0xF81F, BLUE=0x001F, GREEN=0x07E0;

    /* vertex heap: fullscreen-left quad (2 tris), verts at heap offset EOFF=0. */
    blt_vtx_t verts[6] = {
        SV(0,0),   SV(160,0),   SV(160,240),
        SV(0,0),   SV(160,240), SV(0,240),
    };
    uint8_t heap[sizeof verts];
    memcpy(heap, verts, sizeof verts);

    /* the two-pass ring */
    blt_cmd_t c[8]; memset(c, 0, sizeof c);
    int n=0;
    c[n].opcode=BLT_OP_SET_TARGET; c[n].color=BLT_TARGET_APPSURF; n++;               /* cmd0 */
    c[n].opcode=BLT_OP_FILL; c[n].dst_x=0; c[n].dst_y=0; c[n].w=FB_W; c[n].h=FB_H; c[n].color=TEAL; n++;    /* cmd1 */
    c[n].opcode=BLT_OP_FILL; c[n].dst_x=0; c[n].dst_y=0; c[n].w=40;   c[n].h=40;   c[n].color=MAGENTA; n++; /* cmd2 */
    c[n].opcode=BLT_OP_SET_TARGET; c[n].color=BLT_TARGET_WORK; n++;                  /* cmd3 */
    c[n].opcode=BLT_OP_FILL; c[n].dst_x=0;   c[n].dst_y=0; c[n].w=FB_W; c[n].h=FB_H; c[n].color=BLUE;  n++; /* cmd4 */
    c[n].opcode=BLT_OP_FILL; c[n].dst_x=200; c[n].dst_y=0; c[n].w=120;  c[n].h=FB_H; c[n].color=GREEN; n++; /* cmd5 */
    c[n].opcode=BLT_OP_TRILIST; c[n].blend_mode=BLT_BLEND_COPY; c[n].format=BLT_FMT_RGB565;
        c[n].flags=BLT_F_SRC_SURFACE; c[n].alpha=255; c[n].w=2;                       /* 2 triangles */
        c[n].dst_x=(int16_t)(EOFF & 0xFFFF); c[n].dst_y=(int16_t)(EOFF>>16); n++;      /* cmd6 */
    c[n].opcode=BLT_OP_END; n++;                                                      /* cmd7 */

    /* golden WORK: blt_execute of the exact ring (surface built + sampled internally) */
    static uint16_t fb[FB_W*FB_H];
    for (int i=0;i<FB_W*FB_H;i++) fb[i]=0x0000;   /* cmd4 fullscreen-clears anyway */
    blt_surface_heap_t heapdesc = { heap, sizeof heap, NULL, NULL };
    int executed = blt_execute(fb, &heapdesc, c, n);

    /* ---- emit ring + heap ---- */
    FILE *fd = fopen("vectors/sys_surface_ddr.hex", "w");
    if (!fd){ perror("fopen ddr"); return 1; }
    fprintf(fd, "@%x\n", RING_OFF);
    for (int k=0;k<n;k++){
        uint8_t w[BLT_CMD_BYTES]; pack_cmd(&c[k], w);
        for (int q=0;q<4;q++){ uint64_t v; memcpy(&v, w+q*8, 8); fprintf(fd, "%016llx\n",(unsigned long long)v); }
    }
    fprintf(fd, "@%x\n", SRC_OFF);
    uint32_t hq = (uint32_t)((sizeof heap + 7)/8);
    for (uint32_t q=0;q<hq;q++){ uint64_t v=0; memcpy(&v, heap+q*8, (sizeof heap - q*8)>=8?8:(sizeof heap - q*8)); fprintf(fd, "%016llx\n",(unsigned long long)v); }
    fclose(fd);

    /* ---- emit golden framebuffer ---- */
    FILE *fe = fopen("vectors/sys_surface_exp.hex", "w");
    if (!fe){ perror("fopen exp"); return 1; }
    for (int i=0;i<FB_W*FB_H;i++) fprintf(fe, "%04x\n", fb[i]);
    fclose(fe);

    printf("gen_system_golden: executed=%d cmds=%d -> vectors/sys_surface_{ddr,exp}.hex\n", executed, n);
    return 0;
}

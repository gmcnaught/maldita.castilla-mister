/*
 *  gen_tri_stream.c — DDR-init + expected-framebuffer generator that REPLAYS a
 *  captured DEVICE draw stream (an MFTRACE text capture) instead of a synthetic
 *  scenario.
 *
 *  Companion to gen_tri_golden.c, which it is a direct derivative of. What is
 *  REUSED VERBATIM from gen_tri_golden.c (same file, same repo dir):
 *    - the single-source `#include "blitter_ref.h" / blitter_ref.c / blt_tri.c`
 *      build pattern (gen_tri_golden.mk's cc line has no second .c on the link
 *      line, so the refmodel bodies come in by #include);
 *    - the windowed sim offsets WBASE / CTRL_OFF / RING_OFF / SRC_OFF and their
 *      derivation from blitter_defs.vh (see gen_tri_golden.c's header comment —
 *      that comment is THE layout contract and is not restated here);
 *    - wr32() + pack_cmd(): the 32-byte on-wire command packing (mirror of
 *      host/blt_wire.h::blt_pack_cmd);
 *    - the <tag>_ddr.hex emission shape ("@CTRL_OFF" 8 control qwords, ring
 *      contiguous at CTRL_OFF+8, "@SRC_OFF" heap qwords), the <tag>_exp.hex
 *      shape (one RGB565 per line, index = y*FB_W+x), and the surf.hex
 *      app-surface side-channel (backdoor-loaded into comp_fbram's surf banks).
 *  What is NEW here: the MFTRACE parser, the frame selector, the multi-command
 *  ring (one BLT_OP_TRILIST header per captured draw GROUP, not one total), the
 *  compact texture-page remap, and the synthetic texel fill.
 *
 *  ===========================================================================
 *  Input format (Task 3's GMLOADER_MFGPU_TRACE capture)
 *  ===========================================================================
 *    MFTRACE G f=<frame> off=<byte> stride=<byte> texw=<px> texh=<px> fmt=<n>
 *              blend=<n> key=<rgb565> alpha=<n> flags=<n> nt=<tris>
 *    MFTRACE V <x> <y> <u> <v> <rgba-hex>        (nt*3 of them, in order)
 *  x,y are signed 12.4; u,v unsigned 12.4; rgba is r|g<<8|b<<16|a<<24. Frames
 *  are delimited by the `f=` field; --frame N selects the N'th DISTINCT f value
 *  in file order (0-based), which is also submission order.
 *
 *  ===========================================================================
 *  Why the addresses are REMAPPED (and what is preserved)
 *  ===========================================================================
 *  The capture's `off=` values are byte offsets into the DEVICE source heap and
 *  reach ~4.5 MB; the testbench's mem[] SRC window is a few hundred KiB. Each
 *  DISTINCT (off,stride,texw,texh) tuple is therefore interned and given a
 *  COMPACT local offset, and the emitted command header carries the local one.
 *
 *  The remap is not arbitrary. blitter_top.sv's texel qword cache is a
 *  256-entry DIRECT-MAPPED array indexed by qtag[7:0] == (texel_byte_addr>>3)
 *  & 0xFF (TEXQ_N=256, index = b_qtag[TEXQ_AW-1:0]), i.e. a 2048-byte index
 *  period, and the texel byte address is (src_off + tv*stride + tu*2) —
 *  RELATIVE to the SRC heap base on both the device and here. So this generator
 *  places every page at a local offset CONGRUENT TO ITS DEVICE OFFSET MODULO
 *  2048. Page-internal layout (stride, contiguity) is identical by construction.
 *  Result: every cache index and every hit/miss decision the device made is
 *  reproduced exactly, at the cost of <=2047 bytes of padding per page.
 *
 *  ===========================================================================
 *  TEXTURE CONTENT CAVEAT (read this before trusting a number out of the tb)
 *  ===========================================================================
 *  The capture carries texture GEOMETRY but no texel DATA. Referenced pages are
 *  filled with a deterministic address hash (hash8() below). This is sound for
 *  everything the bench measures:
 *    - Bit-exactness is asserted RTL-vs-refmodel over the SAME DDR image (this
 *      generator writes the heap into <tag>_ddr.hex AND hands the identical
 *      bytes to blt_raster_tri), so the golden gate still holds.
 *    - Coverage, state sequencing and every cycle bucket are texel-VALUE
 *      independent. Verified in the RTL, not assumed: the COLORKEY cull is
 *      `b1_we <= !((c_blend==BLEND_KEY) && (texel_q==c_colorkey))` in stage
 *      B_WR (blitter_top.sv ~line 1687) — a keyed-out pixel still traverses
 *      B_WR -> B_WR2 -> B_WR3 and only suppresses fb_wr_en. No cycle depends on
 *      a texel value.
 *    - Cache hit/miss depends on ADDRESSES only, and those are preserved (above).
 *  What the hash CANNOT reproduce is device memory LATENCY: P_SRC here is the
 *  fixed-latency stub model, not sdram_fb_cache + mt48, so absolute `texwait`
 *  is a floor, not a match. That is why calibration reports texwait separately.
 *
 *  ===========================================================================
 *  Usage
 *  ===========================================================================
 *    ./gen_tri_stream <trace.txt> <frame-index> <tag>
 *  emits vectors/<tag>_ddr.hex, vectors/<tag>_exp.hex and the shared
 *  vectors/stream_surf.hex
 *  and prints a one-line summary plus the analyzer-comparable group/tri counts.
 *
 *  GPL-3.0.
 */
#include "blitter_ref.h"
#include "blitter_ref.c"
#include "blt_tri.c"
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

/* ---- windowed sim offsets (qword units, relative to WBASE) -----------------
 * Identical to gen_tri_golden.c's — see its header for the derivation from
 * fpga/rtl/blitter_defs.vh. The testbench MUST use the same three. */
#define WBASE     0x07400000u   /* == VCTRL_QW (real); tb subtracts this from bt_addr */
#define CTRL_OFF  0x00200000u   /* BLTCTRL_QW(real) - WBASE                            */
#define RING_OFF  0x00200008u   /* RING_QW(real)    - WBASE  (== CTRL_OFF+8)           */
#define SRC_OFF   0x00210000u   /* SRC_QW(real)     - WBASE                            */

#define FB_W  BLT_FB_WIDTH
#define FB_H  BLT_FB_HEIGHT

/* Frame clear colour. The captured stream's first opaque draws repaint the
 * whole screen, so this only shows through where nothing is drawn; black keeps
 * an un-drawn pixel visually obvious in a dumped golden. The control block asks
 * for CLEAR-before-list (C_FLAGS bit0) exactly as gen_tri_golden.c does, so the
 * golden below starts from the same field the hw CLEAR path establishes. */
#define CLEARC 0x0000u

/* Texel-cache index period in BYTES: TEXQ_N(256) slots x 8 bytes/qword.
 * See the remap note in the header. Keep in sync with blitter_top.sv's TEXQ_N. */
#define TQ_PERIOD 2048u

/* SRC-window budget. The testbench sizes mem[] as (SRC_QW-WBASE)+SRC_HEADROOM_QW;
 * refuse to emit a heap that would run off the end of it rather than let
 * $readmemh silently drop the tail (which would read back as x and fail the
 * bench's x-trap far from the cause). Must match the tb's headroom. */
#define SRC_HEADROOM_BYTES (0x10000u * 8u)   /* 0x10000 qwords = 512 KiB */

#define MAX_GROUPS 4096
#define MAX_TRIS   16384
#define HEAP_CAP   (2u*1024u*1024u)

/* ---- 32-byte on-wire command packing (copied from gen_tri_golden.c, which in
 * turn mirrors host/blt_wire.h::blt_pack_cmd) -------------------------------- */
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

/* ---- parsed capture ------------------------------------------------------- */
typedef struct {
    uint32_t off, stride, texw, texh, fmt, blend, key, alpha, flags, nt;
    int      vbase;          /* index into verts[] of this group's first vertex */
    uint32_t local_off;      /* remapped texture-page byte offset in the heap   */
    uint32_t voff;           /* vertex-array byte offset in the heap            */
} group_t;

static group_t  groups[MAX_GROUPS];
static int      ngroups = 0;
static blt_vtx_t verts[MAX_TRIS*3];
static int      nverts = 0;

static uint8_t  heap[HEAP_CAP];
static uint32_t heap_len = 0;
static uint16_t fb[FB_W*FB_H];
static uint16_t surface_img[FB_W*FB_H];

/* interned texture pages. local_off starts at NO_OFF (not 0) — the FIRST page
 * legitimately lands at local offset 0, so 0 cannot double as "unplaced". */
#define NO_OFF 0xFFFFFFFFu
typedef struct { uint32_t off, stride, texw, texh, local_off, size; } page_t;
static page_t pages[MAX_GROUPS];
static int    npages = 0;

/* Deterministic byte fill for a referenced texture page. Value depends ONLY on
 * the heap byte offset, so the C golden and the DDR image agree by construction
 * (both are this same `heap` array). Knuth multiplicative + a xorshift so
 * adjacent qwords differ in every byte lane. */
static uint8_t hash8(uint32_t a) {
    uint32_t h = a * 2654435761u;
    h ^= h >> 13; h *= 1274126177u; h ^= h >> 16;
    return (uint8_t)(h >> 5);
}

static uint32_t align_up(uint32_t v, uint32_t a) { return (v + a - 1u) & ~(a - 1u); }

/* Place a page so that (local_off % TQ_PERIOD) == (off % TQ_PERIOD), preserving
 * the direct-mapped texel-cache index the device saw (header note). */
static uint32_t place_congruent(uint32_t cursor, uint32_t off) {
    uint32_t base = align_up(cursor, 8u);
    uint32_t want = off % TQ_PERIOD;
    uint32_t have = base % TQ_PERIOD;
    return base + ((want + TQ_PERIOD - have) % TQ_PERIOD);
}

static int intern_page(uint32_t off, uint32_t stride, uint32_t texw, uint32_t texh) {
    for (int i=0;i<npages;i++)
        if (pages[i].off==off && pages[i].stride==stride &&
            pages[i].texw==texw && pages[i].texh==texh) return i;
    if (npages >= MAX_GROUPS) { fprintf(stderr, "too many pages\n"); exit(2); }
    pages[npages].off=off; pages[npages].stride=stride;
    pages[npages].texw=texw; pages[npages].texh=texh;
    pages[npages].local_off=NO_OFF;
    /* tex_nearest() clamps to [0,texw)x[0,texh), so the highest byte touched is
     * (texh-1)*stride + (texw-1)*2 + 1. The RTL reads the CONTAINING QWORD, so
     * round the extent up to 8. */
    uint32_t sz = (texh ? (texh-1u)*stride : 0u) + (texw ? (texw-1u)*2u + 2u : 0u);
    pages[npages].size = align_up(sz, 8u);
    return npages++;
}

/* ---- MFTRACE parse ------------------------------------------------------- */
/* Fetch one "<key>=<decimal>" field. Matches " <key>=" (with the leading space)
 * so `f=` cannot match inside `off=` and `texw=`/`texh=` cannot match each other.
 * A missing key is a hard error, not a silent 0: a capture-format change must
 * fail here rather than emit a scene with, say, every stride quietly zeroed. */
static uint32_t fld(const char *line, const char *key) {
    char pat[32];
    snprintf(pat, sizeof pat, " %s=", key);
    const char *p = strstr(line, pat);
    if (!p) {
        fprintf(stderr, "ERROR: MFTRACE G line has no '%s=' field: %s", key, line);
        exit(2);
    }
    return (uint32_t)strtoul(p + strlen(pat), NULL, 10);
}

static int parse_frame(const char *path, int want_frame) {
    FILE *f = fopen(path, "r");
    if (!f) { perror(path); return -1; }
    char line[512];
    long seen_ids[4096]; int nseen = 0; int cur = -1; long cur_id = -1;
    int in_wanted = 0;
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "MFTRACE G ", 10)) continue;
        long fid = (long)fld(line, "f");
        if (fid != cur_id) {
            /* A frame id must never REAPPEAR after a different id intervened. The
             * capture is one contiguous block of G/V lines per frame, and the frame
             * INDEX (--frame N) is defined as the N'th distinct id in file order. If
             * a capture ever interleaved frames, the old "already seen -> keep the
             * current index" branch would have silently attributed the second block
             * to whatever frame the cursor happened to be on -- a wrong scene that
             * still passes bit-exactness (the golden is built from the same wrong
             * groups). Hard-fail instead. */
            for (int i=0;i<nseen;i++) if (seen_ids[i]==fid) {
                fprintf(stderr, "ERROR: frame id %ld recurs after frame id %ld — the capture "
                                "interleaves frames, so --frame N is not well defined.\n", fid, cur_id);
                fclose(f); return -1;
            }
            if (nseen >= (int)(sizeof seen_ids / sizeof seen_ids[0])) {
                fprintf(stderr, "ERROR: more than %zu frames in the capture\n",
                        sizeof seen_ids / sizeof seen_ids[0]);
                fclose(f); return -1;
            }
            seen_ids[nseen++] = fid; cur++;
            cur_id = fid;
        }
        in_wanted = (cur == want_frame);
        group_t g; memset(&g, 0, sizeof g);
        g.off    = fld(line, "off");
        g.stride = fld(line, "stride");
        g.texw   = fld(line, "texw");
        g.texh   = fld(line, "texh");
        g.fmt    = fld(line, "fmt");
        g.blend  = fld(line, "blend");
        g.key    = fld(line, "key");
        g.alpha  = fld(line, "alpha");
        g.flags  = fld(line, "flags");
        g.nt     = fld(line, "nt");
        if (in_wanted) {
            if (ngroups >= MAX_GROUPS) { fprintf(stderr, "too many groups\n"); fclose(f); return -1; }
            g.vbase = nverts;
        }
        for (uint32_t k=0; k < g.nt*3; k++) {
            if (!fgets(line, sizeof line, f) || strncmp(line, "MFTRACE V ", 10)) {
                fprintf(stderr, "expected V line: %s", line); fclose(f); return -1;
            }
            if (!in_wanted) continue;
            long x,y,u,v; unsigned long rgba;
            if (sscanf(line+10, "%ld %ld %ld %ld %lx", &x,&y,&u,&v,&rgba) != 5) {
                fprintf(stderr, "bad V line: %s", line); fclose(f); return -1;
            }
            if (nverts >= MAX_TRIS*3) { fprintf(stderr, "too many verts\n"); fclose(f); return -1; }
            blt_vtx_t *vt = &verts[nverts++];
            vt->x = (int16_t)x; vt->y = (int16_t)y;
            vt->u = (uint16_t)u; vt->v = (uint16_t)v;
            vt->rgba = (uint32_t)rgba; vt->_rsvd = 0;
        }
        if (in_wanted && g.nt) groups[ngroups++] = g;
    }
    fclose(f);
    if (cur < want_frame) {
        fprintf(stderr, "trace has only %d frame(s); --frame %d out of range\n", cur+1, want_frame);
        return -1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <mftrace.txt> <frame-index> <tag>\n", argv[0]);
        return 2;
    }
    const char *trace = argv[1];
    int frame = atoi(argv[2]);
    const char *tag = argv[3];

    if (parse_frame(trace, frame)) return 2;
    if (!ngroups) { fprintf(stderr, "frame %d has no draw groups\n", frame); return 2; }

    /* ---- heap layout: texture pages (congruent remap), then vertex arrays --- */
    uint32_t cursor = 0;
    for (int i=0;i<ngroups;i++) {
        group_t *g = &groups[i];
        if (g->flags & BLT_F_SRC_SURFACE) { g->local_off = 0; continue; }  /* no heap page */
        int pi = intern_page(g->off, g->stride, g->texw, g->texh);
        if (pages[pi].local_off == NO_OFF) {
            uint32_t at = place_congruent(cursor, g->off);
            pages[pi].local_off = at;
            cursor = at + pages[pi].size;
        }
        g->local_off = pages[pi].local_off;
    }
    cursor = align_up(cursor, 16u);
    for (int i=0;i<ngroups;i++) {
        groups[i].voff = cursor;
        cursor += groups[i].nt * 3u * 16u;
    }
    heap_len = align_up(cursor, 8u);
    if (heap_len > HEAP_CAP) { fprintf(stderr, "heap overflow (%u B)\n", heap_len); return 2; }
    if (heap_len > SRC_HEADROOM_BYTES) {
        fprintf(stderr, "ERROR: heap %u B exceeds the testbench SRC window (%u B).\n"
                        "       Grow SRC_HEADROOM_QW in tb_blitter_trilist_stream.sv AND\n"
                        "       SRC_HEADROOM_BYTES here together, or the hex tail is dropped.\n",
                heap_len, SRC_HEADROOM_BYTES);
        return 2;
    }

    /* ---- fill referenced texture pages with the deterministic address hash -- */
    memset(heap, 0, heap_len);
    for (int i=0;i<npages;i++)
        for (uint32_t b=0;b<pages[i].size;b++) {
            uint32_t a = pages[i].local_off + b;
            heap[a] = hash8(a);
        }
    /* ---- vertex arrays (16-byte blt_vtx_t, on-wire little-endian) ---------- */
    for (int i=0;i<ngroups;i++) {
        const blt_vtx_t *v = &verts[groups[i].vbase];
        uint8_t *p = heap + groups[i].voff;
        for (uint32_t t=0; t < groups[i].nt*3u; t++) {
            wr32(p+t*16+0,  (uint32_t)(uint16_t)v[t].x | ((uint32_t)(uint16_t)v[t].y << 16));
            wr32(p+t*16+4,  (uint32_t)v[t].u | ((uint32_t)v[t].v << 16));
            wr32(p+t*16+8,  v[t].rgba);
            wr32(p+t*16+12, 0);
        }
    }

    /* ---- app-surface texel source (one captured group per frame carries
     * BLT_F_SRC_SURFACE). The capture has no surface CONTENT either, so use the
     * same deterministic per-pixel pattern gen_tri_golden.c's tri_surface
     * scenario uses; the tb backdoor-loads the identical image into comp_fbram's
     * surf banks, so RTL and refmodel sample the same texels. */
    for (int y=0;y<FB_H;y++) for (int x=0;x<FB_W;x++)
        surface_img[y*FB_W+x] = (uint16_t)((((x*5)&0x1F)<<11) | (((y*3)&0x3F)<<5) | ((x+y)&0x1F));

    /* ---- golden framebuffer: CLEAR, then every group through blt_raster_tri -- */
    for (int i=0;i<FB_W*FB_H;i++) fb[i] = (uint16_t)CLEARC;
    blt_surface_heap_t sh = { heap, heap_len, 0, 0 };
    blt_cmd_t *hdrs = calloc((size_t)ngroups, sizeof(blt_cmd_t));
    if (!hdrs) { perror("calloc"); return 1; }
    for (int i=0;i<ngroups;i++) {
        group_t *g = &groups[i];
        blt_cmd_t *h = &hdrs[i];
        h->opcode     = BLT_OP_TRILIST;
        h->blend_mode = (uint8_t)g->blend;
        h->format     = (uint8_t)g->fmt;
        h->flags      = (uint8_t)g->flags;
        h->src_off    = g->local_off;
        h->src_stride = (uint16_t)g->stride;
        h->src_x      = (uint16_t)g->texw;
        h->src_y      = (uint16_t)g->texh;
        h->w          = (uint16_t)g->nt;
        h->h          = 0;
        h->dst_x      = (int16_t)(g->voff & 0xFFFFu);
        h->dst_y      = (int16_t)(g->voff >> 16);
        h->colorkey   = (uint16_t)g->key;
        h->alpha      = (uint8_t)g->alpha;
        blt_raster_tri(fb, &sh, h, &verts[g->vbase], (int)g->nt, surface_img);
    }

    /* ---- emit ddr.hex ------------------------------------------------------ */
    char path[512];
    snprintf(path, sizeof path, "vectors/%s_ddr.hex", tag);
    FILE *fd = fopen(path, "w");
    if (!fd) { perror(path); return 1; }
    fprintf(fd, "@%x\n", CTRL_OFF);
    /* SUBMIT, CMDCOUNT (ngroups TRILIST + 1 END), TARGET, CLEAR, FLAGS(bit0=clear
     * before list), DONE, STATUS, SRCSEL — same field order as gen_tri_golden.c */
    uint64_t ctrl[8] = { 1, (uint64_t)ngroups + 1u, 0, CLEARC, 1, 0, 0, 0 };
    for (int i=0;i<8;i++) fprintf(fd, "%016llx\n", (unsigned long long)ctrl[i]);
    /* RING_OFF == CTRL_OFF+8: contiguous, no new @addr needed */
    uint8_t w[BLT_CMD_BYTES];
    for (int i=0;i<ngroups;i++) {
        pack_cmd(&hdrs[i], w);
        for (int q=0;q<4;q++) { uint64_t v; memcpy(&v, w+q*8, 8); fprintf(fd, "%016llx\n", (unsigned long long)v); }
    }
    { blt_cmd_t e; memset(&e, 0, sizeof e); e.opcode = BLT_OP_END; pack_cmd(&e, w);
      for (int q=0;q<4;q++) { uint64_t v; memcpy(&v, w+q*8, 8); fprintf(fd, "%016llx\n", (unsigned long long)v); } }
    fprintf(fd, "@%x\n", SRC_OFF);
    for (uint32_t q=0; q < heap_len/8u; q++) {
        uint64_t v; memcpy(&v, heap+(size_t)q*8, 8);
        fprintf(fd, "%016llx\n", (unsigned long long)v);
    }
    fclose(fd);

    /* ---- emit exp.hex / surf.hex ------------------------------------------ */
    snprintf(path, sizeof path, "vectors/%s_exp.hex", tag);
    FILE *fe = fopen(path, "w");
    if (!fe) { perror(path); return 1; }
    for (int i=0;i<FB_W*FB_H;i++) fprintf(fe, "%04x\n", fb[i]);
    fclose(fe);

    /* One SHARED surf.hex, not one per tag: the app-surface pattern is
     * tag-independent (see above), and a 311 KiB byte-identical copy per replayed
     * frame is pure repo weight. */
    snprintf(path, sizeof path, "vectors/stream_surf.hex");
    FILE *fs = fopen(path, "w");
    if (!fs) { perror(path); return 1; }
    for (int i=0;i<FB_W*FB_H;i++) fprintf(fs, "%04x\n", surface_img[i]);
    fclose(fs);

    /* ---- summary (the numbers to cross-check against scripts/mftrace_analyze.py) */
    uint32_t ntris = 0, nsurf = 0;
    for (int i=0;i<ngroups;i++) { ntris += groups[i].nt; if (groups[i].flags & BLT_F_SRC_SURFACE) nsurf++; }
    printf("gen_tri_stream: %s frame=%d tag=%s groups=%d tris=%u surface_groups=%u\n",
           trace, frame, tag, ngroups, ntris, nsurf);
    printf("gen_tri_stream: pages=%d heap=%u B (%u qw)  ring=%d cmds\n",
           npages, heap_len, heap_len/8u, ngroups+1);
    free(hdrs);
    return 0;
}

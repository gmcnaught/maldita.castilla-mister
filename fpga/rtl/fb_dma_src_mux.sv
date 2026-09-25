// fb_dma_src_mux.sv — choose the buffer comp_fb_dma copies out to DDR: WORK or the
// off-screen APP-SURFACE.
//
// [present-from-surface] Every Maldita frame renders into the app surface and then copies it
// 1:1 onto WORK with a full-screen SRC_SURFACE COPY (62,208 px at ~6 cyc/px = ~3.8 ms of the
// frame). The host now drops that copy when it would be an identity and flags the frame's END
// command with BLT_F_SRC_SURFACE; blitter_top latches that into `src_surf`, and this mux points
// the frame-end DMA at the surface bank instead of WORK. Same qword layout (qw = y*72 + x>>2,
// lane = x&3) and the same 1-cycle registered read, so comp_fb_dma is unchanged.
//
// Race-free for the same reason the WORK mux always was: the DMA runs only while `dma_busy`,
// during which blitter_top is parked in S_SNAP_* and issues no WORK or surface reads. `src_surf`
// is latched at OP_END, before the DMA starts, and cannot move until the next END, which the
// blitter cannot reach before the DMA has finished.
//
// Copyright (C) 2026 — GPL-3.0
`default_nettype none
module fb_dma_src_mux #(parameter integer AW = 15) (
    input  wire          dma_busy,       // comp_fb_dma mid-copy
    input  wire          src_surf,       // this frame presents the app surface (latched at END)
    // comp_fb_dma's read request / data
    input  wire          dma_rd_en,
    input  wire [AW-1:0] dma_rd_qw,
    output wire [63:0]   dma_rd_qword,
    // blitter_top's WORK read (compositor RMW) and surface read (RMW / texel sample)
    input  wire          blt_fb_rd_en,
    input  wire [AW-1:0] blt_fb_rd_qw,
    input  wire          blt_surf_rd_en,
    input  wire [AW-1:0] blt_surf_rd_qw,
    // comp_fbram ports
    output wire          fb_rd_en,
    output wire [AW-1:0] fb_rd_qw,
    input  wire [63:0]   fb_rd_qword,
    output wire          surf_rd_en,
    output wire [AW-1:0] surf_rd_qw,
    input  wire [63:0]   surf_rd_qword
);
    wire dma_work = dma_busy & ~src_surf;
    wire dma_surf = dma_busy &  src_surf;
    assign fb_rd_en     = dma_busy ? (dma_work & dma_rd_en) : blt_fb_rd_en;
    assign fb_rd_qw     = dma_busy ? dma_rd_qw : blt_fb_rd_qw;
    assign surf_rd_en   = dma_surf ? dma_rd_en : blt_surf_rd_en;
    assign surf_rd_qw   = dma_surf ? dma_rd_qw : blt_surf_rd_qw;
    assign dma_rd_qword = src_surf ? surf_rd_qword : fb_rd_qword;
endmodule
`default_nettype wire

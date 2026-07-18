// comp_fbram.sv — on-chip framebuffer for the FB-in-BRAM compositor.
//
// 4 lane-banks × 16-bit × FB_QWORDS (=19200 for 320×240 RGB565).
//   qword index = y*80 + (x>>2);  lane = x[1:0].
//
// [DDR-scanout] The on-chip SCAN buffer (sbank0-3) + its snapshot write (snap_*) + scanout
// read (scan_rd_*) ports are RETIRED: scanout now reads a DDR3 framebuffer written by the
// external comp_fb_dma (which the framework's ascal scans out), freeing ~160 M10K. This
// module now holds exactly two on-chip framebuffers:
//   WORK buffer (bank0-3):    composite write (wr_*, lane-selected, 1 px/cyc) + the
//                             compositor's RMW dst read (rd_*). PERSISTS across frames, so
//                             Solarus's incremental/persistence draw model needs no carry-
//                             forward — the prior frame is already here. comp_fb_dma reads
//                             this buffer (via rd_*) at vblank to stream it out to DDR.
//   SURFACE buffer (surf_*):  the off-screen APP-SURFACE render target (app-surface v1).
// Each bank is a clean 1-write/1-read full-width RAM → M10K.
`default_nettype none
module comp_fbram #(
    parameter integer FB_QWORDS = 19200,   // 320*240/4
    parameter integer AW        = 15       // ceil(log2(19200)) = 15
)(
    input  wire          clk,
    // composite write: one pixel (one lane) per cycle
    input  wire          wr_en,
    input  wire [AW-1:0] wr_qw,            // qword index 0..FB_QWORDS-1
    input  wire [1:0]    wr_lane,          // x[1:0]
    input  wire [15:0]   wr_pix,           // RGB565
    // composite RMW read: returns all 4 lanes, registered (1-cyc latency). Also the port
    // comp_fb_dma uses to stream WORK out to the DDR framebuffer at vblank [DDR-scanout].
    input  wire          rd_en,
    input  wire [AW-1:0] rd_qw,
    output wire [63:0]   rd_qword,         // {lane3,lane2,lane1,lane0}
    // ── off-screen APP-SURFACE render target (app-surface v1, plan Task 6) ─────────
    // A second, independent 1W1R full-size surface (same 4-lane-bank qword layout as
    // WORK). The compositor's write/read is routed here by blitter_top when the active
    // render target is APPSURF. It is OFF-SCREEN: never scanned, no scan buffer, no
    // snapshot copy. Ports float UNCONNECTED on the legacy scanout/unit benches — the
    // enable gates make an unconnected (z) enable a no-op (`if (z)` is false), so those
    // benches are unaffected. Task 7 adds a texel read from this surface (surf_rd_*).
    input  wire          surf_wr_en,
    input  wire [AW-1:0] surf_wr_qw,
    input  wire [1:0]    surf_wr_lane,
    input  wire [15:0]   surf_wr_pix,
    input  wire          surf_rd_en,
    input  wire [AW-1:0] surf_rd_qw,
    output wire [63:0]   surf_rd_qword    // {lane3,lane2,lane1,lane0}
);
    // WORK framebuffer: four lane banks (1W1R)
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank0 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank1 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank2 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] bank3 [0:FB_QWORDS-1];

    // composite writes exactly one lane per cycle into the WORK buffer only
    wire we0 = wr_en & (wr_lane == 2'd0);
    wire we1 = wr_en & (wr_lane == 2'd1);
    wire we2 = wr_en & (wr_lane == 2'd2);
    wire we3 = wr_en & (wr_lane == 2'd3);

    always @(posedge clk) if (we0) bank0[wr_qw] <= wr_pix;
    always @(posedge clk) if (we1) bank1[wr_qw] <= wr_pix;
    always @(posedge clk) if (we2) bank2[wr_qw] <= wr_pix;
    always @(posedge clk) if (we3) bank3[wr_qw] <= wr_pix;

    // composite RMW read port (clean registered read → clean M10K inference).
    // NOTE on read-during-write: the blend RMW reads the dest qword for a pixel AHEAD in
    // comp_pipeline while the composite write commits a pixel BEHIND it; mid-row those can
    // share a qword. But the read LANE used by the blend (= read pixel's x[1:0]) is offset
    // from the simultaneously-written lane by the mixer latency, so they never coincide —
    // the only same-address read-during-write hits an UNUSED lane, whose value is discarded.
    // (An explicit write-forward bypass was tried and REVERTED: it gave no functional change
    // and regressed the HDMI PLL path into negative slack. The placement-sensitive path is
    // the fb_rd address mux; the pinned fitter seed gives it margin.)
    reg [15:0] q0, q1, q2, q3;
    always @(posedge clk) if (rd_en) begin
        q0 <= bank0[rd_qw]; q1 <= bank1[rd_qw];
        q2 <= bank2[rd_qw]; q3 <= bank3[rd_qw];
    end
    assign rd_qword = {q3, q2, q1, q0};

    // ── off-screen APP-SURFACE bank (app-surface v1) ─────────────────────────────
    // Independent 1W1R storage, same 4-lane-bank layout as WORK. No scan/snapshot copy
    // (never displayed). Clean 1-write/1-read full-width RAM -> M10K, same as WORK.
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] surf_bank0 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] surf_bank1 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] surf_bank2 [0:FB_QWORDS-1];
    (* ramstyle = "no_rw_check, M10K" *) reg [15:0] surf_bank3 [0:FB_QWORDS-1];

    // composite write into the surface (exactly one lane per cycle). An unconnected
    // surf_wr_en floats to z on legacy benches; `if (z)`/`if (x)` is false -> no write.
    wire sfwe0 = surf_wr_en & (surf_wr_lane == 2'd0);
    wire sfwe1 = surf_wr_en & (surf_wr_lane == 2'd1);
    wire sfwe2 = surf_wr_en & (surf_wr_lane == 2'd2);
    wire sfwe3 = surf_wr_en & (surf_wr_lane == 2'd3);
    always @(posedge clk) if (sfwe0) surf_bank0[surf_wr_qw] <= surf_wr_pix;
    always @(posedge clk) if (sfwe1) surf_bank1[surf_wr_qw] <= surf_wr_pix;
    always @(posedge clk) if (sfwe2) surf_bank2[surf_wr_qw] <= surf_wr_pix;
    always @(posedge clk) if (sfwe3) surf_bank3[surf_wr_qw] <= surf_wr_pix;

    // surface read port (registered, 1-cyc latency) — composite RMW read when APPSURF,
    // and (Task 7) the texel sample of the surface-as-texture.
    reg [15:0] u0, u1, u2, u3;
    always @(posedge clk) if (surf_rd_en) begin
        u0 <= surf_bank0[surf_rd_qw]; u1 <= surf_bank1[surf_rd_qw];
        u2 <= surf_bank2[surf_rd_qw]; u3 <= surf_bank3[surf_rd_qw];
    end
    assign surf_rd_qword = {u3, u2, u1, u0};

    // [DDR-scanout] The former #110 SVA (SCAN snapshot vs scanout read-during-write hazard)
    // is gone with the SCAN buffer: there is no second reader of these banks. The WORK read
    // (rd_*) is a single 1W1R port shared by the compositor RMW and comp_fb_dma (never
    // concurrent — the DMA runs only in vblank while the compositor is idle).
endmodule
`default_nettype wire

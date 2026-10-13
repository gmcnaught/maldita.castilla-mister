// tb_reader_ddr_v240.sv — tb_reader_ddr with OSD Vertical Lines = 240: the timing scans
// all `FB_H lines and the reader must fetch framebuffer rows 0..`FB_H-1 (no `DISP_Y0 offset),
// with every check of the 224-line bench applied unchanged to the full-height window.
`define V_FULL_240
`include "tb_reader_ddr.sv"

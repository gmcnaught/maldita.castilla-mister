// KNOWN-GOOD fixture for the M10K inference gate — must NOT fire.
//
// Same memory, same FSM, but the read lives in its own unconditional `always @(posedge clk)`
// block. This is the shape that actually infers M10K, and the shape blitter_top.sv adopted in
// 476a422 (and that solarus-mister's clut_bram has always used). The write may stay inside the
// FSM — writes in a case arm do not break inference; only the read position does.
//
// This file is the counter-example to ramstyle_bad.sv: together they prove the gate
// discriminates rather than flagging every ramstyle array it sees.
module ramstyle_good (
    input             clk,
    input             rst,
    input      [7:0]  addr,
    input      [63:0] wdata,
    input             we,
    input      [7:0]  waddr,
    output reg [63:0] q
);
    localparam S_IDLE = 2'd0, S_LOOK = 2'd1;
    reg [1:0] state;

    (* ramstyle = "no_rw_check, M10K" *) reg [63:0] mem [0:255];

    // Dedicated, unconditional read port -> clean M10K extraction.
    always @(posedge clk) q <= mem[addr];

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
        end else begin
            case (state)
                S_IDLE: state <= S_LOOK;
                S_LOOK: begin
                    if (we) mem[waddr] <= wdata;   // write in a case arm: allowed
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

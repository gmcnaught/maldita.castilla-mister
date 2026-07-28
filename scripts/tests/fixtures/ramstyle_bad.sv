// KNOWN-BAD fixture for the M10K inference gate — must FIRE.
//
// This is a reduction of blitter_top.sv as it stood at 726c63d (pre-476a422): the read of a
// ramstyle-annotated array nested inside an FSM case arm. Quartus 17.0 reported it as
// "uninferred due to asynchronous read logic" (map.rpt Info 276007) and built the array from
// LABs instead of M10K — 20,480 stray flops, a ~1,735-fanout address bus, and -0.983 ns setup.
//
// Do NOT "fix" this file. It exists to prove the gate still detects the pattern; a gate that
// matched nothing would pass forever and guard nothing.
module ramstyle_bad (
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

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
        end else begin
            if (we) mem[waddr] <= wdata;    // write in a case-free path: fine
            case (state)
                S_IDLE: state <= S_LOOK;
                S_LOOK: begin
                    q     <= mem[addr];     // <-- READ NESTED IN A CASE ARM: the defect
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

// ============================================================================
// pc_reg.v: Program Counter register
// ----------------------------------------------------------------------------
// A single 32-bit register holding the address of the instruction currently
// being executed. On each rising clock edge, it loads `next_pc`. When
// `reset` is asserted (active high), it goes back to address 0.
//
// The next-PC mux (PC+4 vs branch target vs jump target) lives in the
// top-level core, not here. This module is dumb on purpose. It is just
// a flip-flop bank with reset.
// ============================================================================

module pc_reg (
    input  wire        clk,
    input  wire        reset,        // active high, synchronous
    input  wire [31:0] next_pc,
    output reg  [31:0] pc
);

    always @(posedge clk) begin
        if (reset)
            pc <= 32'h0000_0000;
        else
            pc <= next_pc;
    end

endmodule

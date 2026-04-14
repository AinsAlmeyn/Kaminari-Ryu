// ============================================================================
// alu.v: Raijin arithmetic / logic unit
// ----------------------------------------------------------------------------
// Pure combinational. Two 32-bit operands in, one 32-bit result out, plus
// a "zero" flag indicating result == 0 (handy for branch-equal detection
// later, even though branches are decided by a separate comparator).
//
// The ALU does NOT decide which operation to perform. The control unit
// upstream computes the 4-bit `op` selector based on the instruction.
// ============================================================================

`include "raijin_defs.vh"

module alu (
    input  wire [31:0] a,        // operand A (typically rs1 data)
    input  wire [31:0] b,        // operand B (rs2 data, or sign-extended imm)
    input  wire [3:0]  op,       // operation selector. See raijin_defs.vh

    output wire [31:0] result,
    output wire        zero      // 1 when result == 32'h0
);

    // ----------------------------------------------------------------
    // Compute every candidate result in parallel. The synthesizer turns
    // the case below into a mux that picks one of these wires.
    // The wires we don't pick still get computed in hardware. That is
    // unavoidable in combinational logic, and it is fine.
    // ----------------------------------------------------------------

    wire [31:0] add_result  = a + b;
    wire [31:0] sub_result  = a - b;
    wire [31:0] and_result  = a & b;
    wire [31:0] or_result   = a | b;
    wire [31:0] xor_result  = a ^ b;

    // Shifts use only the lower 5 bits of B (shift amount = "shamt").
    // The spec is explicit: a 32-bit value cannot meaningfully shift by
    // more than 31 positions.
    wire [31:0] sll_result  = a << b[4:0];
    wire [31:0] srl_result  = a >> b[4:0];

    // SRA needs arithmetic (sign-preserving) right shift. In Verilog the
    // `>>>` operator only does arithmetic shifts when applied to a SIGNED
    // operand. Hence the $signed() cast.
    wire [31:0] sra_result  = $signed(a) >>> b[4:0];

    // SLT compares as signed integers; SLTU as unsigned.
    // Verilog's default `<` is unsigned, so we cast for SLT.
    wire [31:0] slt_result  = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
    wire [31:0] sltu_result = (a < b)                   ? 32'd1 : 32'd0;

    // ----------------------------------------------------------------
    // Mux : pick the result corresponding to the requested op.
    // The default branch returns 0. If the control unit ever feeds us
    // an undefined op, the result is well-defined (and easy to spot in
    // a waveform).
    // ----------------------------------------------------------------
    reg [31:0] result_mux;
    always @(*) begin
        case (op)
            `ALU_OP_ADD  : result_mux = add_result;
            `ALU_OP_SUB  : result_mux = sub_result;
            `ALU_OP_AND  : result_mux = and_result;
            `ALU_OP_OR   : result_mux = or_result;
            `ALU_OP_XOR  : result_mux = xor_result;
            `ALU_OP_SLL  : result_mux = sll_result;
            `ALU_OP_SRL  : result_mux = srl_result;
            `ALU_OP_SRA  : result_mux = sra_result;
            `ALU_OP_SLT  : result_mux = slt_result;
            `ALU_OP_SLTU : result_mux = sltu_result;
            default      : result_mux = 32'd0;
        endcase
    end

    assign result = result_mux;
    assign zero   = (result_mux == 32'd0);

endmodule

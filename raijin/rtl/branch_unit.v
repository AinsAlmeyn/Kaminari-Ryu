// ============================================================================
// branch_unit.v: RV32I branch comparator
// ----------------------------------------------------------------------------
// Pure combinational. Compares two 32-bit operands and outputs a single bit
// indicating whether the requested branch condition holds.
//
// This module always computes a result; the upstream core only uses it
// when the control unit raises the `branch` flag (i.e. when the current
// instruction is actually one of BEQ/BNE/BLT/BGE/BLTU/BGEU). Keeping the
// gating outside this module keeps it pure and easy to test in isolation.
// ============================================================================

`include "riscv_defs.vh"

module branch_unit (
    input  wire [31:0] rs1_data,
    input  wire [31:0] rs2_data,
    input  wire [2:0]  funct3,         // selects which branch condition

    output reg         branch_taken    // 1 if the condition holds
);

    always @(*) begin
        case (funct3)
            `FUNCT3_BRANCH_EQUAL :
                branch_taken = (rs1_data == rs2_data);

            `FUNCT3_BRANCH_NOT_EQUAL :
                branch_taken = (rs1_data != rs2_data);

            `FUNCT3_BRANCH_LESS_THAN_SIGNED :
                branch_taken = ($signed(rs1_data) <  $signed(rs2_data));

            `FUNCT3_BRANCH_GREATER_OR_EQUAL_SIGNED :
                branch_taken = ($signed(rs1_data) >= $signed(rs2_data));

            `FUNCT3_BRANCH_LESS_THAN_UNSIGNED :
                branch_taken = (rs1_data <  rs2_data);

            `FUNCT3_BRANCH_GREATER_OR_EQUAL_UNSIGNED :
                branch_taken = (rs1_data >= rs2_data);

            default :
                branch_taken = 1'b0;    // safe default for undefined funct3
        endcase
    end

endmodule

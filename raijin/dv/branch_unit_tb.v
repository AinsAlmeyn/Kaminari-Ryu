// ============================================================================
// branch_unit_tb.v: testbench for the RV32I branch comparator
// ============================================================================

`timescale 1ns / 1ps
`include "riscv_defs.vh"

module branch_unit_tb;

    reg  [31:0] rs1_data;
    reg  [31:0] rs2_data;
    reg  [2:0]  funct3;
    wire        branch_taken;

    integer pass_count = 0;
    integer fail_count = 0;

    branch_unit dut (
        .rs1_data     (rs1_data),
        .rs2_data     (rs2_data),
        .funct3       (funct3),
        .branch_taken (branch_taken)
    );

    task check;
        input [255:0] label;
        input         expected;
        begin
            if (branch_taken === expected) begin
                $display("    PASS : %0s   taken=%0d", label, branch_taken);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %0s   expected %0d, got %0d",
                         label, expected, branch_taken);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("branch_unit_tb.vcd");
        $dumpvars(0, branch_unit_tb);

        $display("================================================");
        $display(" branch_unit_tb : Raijin branch comparator");
        $display("================================================");

        // ============================================================
        // BEQ
        // ============================================================
        $display("\n[Test] BEQ");
        funct3 = `FUNCT3_BRANCH_EQUAL;
        rs1_data = 32'd5; rs2_data = 32'd5; #1;
        check("5 == 5", 1'b1);
        rs1_data = 32'd5; rs2_data = 32'd6; #1;
        check("5 == 6", 1'b0);

        // ============================================================
        // BNE
        // ============================================================
        $display("\n[Test] BNE");
        funct3 = `FUNCT3_BRANCH_NOT_EQUAL;
        rs1_data = 32'd5; rs2_data = 32'd6; #1;
        check("5 != 6", 1'b1);
        rs1_data = 32'd5; rs2_data = 32'd5; #1;
        check("5 != 5", 1'b0);

        // ============================================================
        // BLT (signed)
        // ============================================================
        $display("\n[Test] BLT (signed)");
        funct3 = `FUNCT3_BRANCH_LESS_THAN_SIGNED;
        rs1_data = 32'hFFFFFFFF; rs2_data = 32'd1; #1;     // -1 < 1 ?
        check("-1 < 1 (signed)", 1'b1);
        rs1_data = 32'd1; rs2_data = 32'hFFFFFFFF; #1;     // 1 < -1 ?
        check("1 < -1 (signed)", 1'b0);
        rs1_data = 32'd5; rs2_data = 32'd5; #1;
        check("5 < 5", 1'b0);

        // ============================================================
        // BGE (signed)
        // ============================================================
        $display("\n[Test] BGE (signed)");
        funct3 = `FUNCT3_BRANCH_GREATER_OR_EQUAL_SIGNED;
        rs1_data = 32'd5; rs2_data = 32'd5; #1;
        check("5 >= 5", 1'b1);
        rs1_data = 32'd1; rs2_data = 32'hFFFFFFFF; #1;     // 1 >= -1 ?
        check("1 >= -1 (signed)", 1'b1);
        rs1_data = 32'hFFFFFFFF; rs2_data = 32'd0; #1;     // -1 >= 0 ?
        check("-1 >= 0 (signed)", 1'b0);

        // ============================================================
        // BLTU (unsigned)
        // ============================================================
        $display("\n[Test] BLTU (unsigned)");
        funct3 = `FUNCT3_BRANCH_LESS_THAN_UNSIGNED;
        rs1_data = 32'd1; rs2_data = 32'hFFFFFFFF; #1;     // 1 < 0xFFFFFFFF ?
        check("1 < 0xFFFFFFFF (unsigned)", 1'b1);
        rs1_data = 32'hFFFFFFFF; rs2_data = 32'd1; #1;     // 0xFFFFFFFF < 1 ?
        check("0xFFFFFFFF < 1 (unsigned)", 1'b0);

        // ============================================================
        // BGEU (unsigned)
        // ============================================================
        $display("\n[Test] BGEU (unsigned)");
        funct3 = `FUNCT3_BRANCH_GREATER_OR_EQUAL_UNSIGNED;
        rs1_data = 32'hFFFFFFFF; rs2_data = 32'd1; #1;
        check("0xFFFFFFFF >= 1 (unsigned)", 1'b1);
        rs1_data = 32'd5; rs2_data = 32'd5; #1;
        check("5 >= 5", 1'b1);
        rs1_data = 32'd0; rs2_data = 32'd1; #1;
        check("0 >= 1", 1'b0);

        // ============================================================
        // Default (undefined funct3) -> not taken
        // ============================================================
        $display("\n[Test] undefined funct3 -> not taken");
        funct3 = 3'b010;     // not assigned to any branch
        rs1_data = 32'hDEADBEEF; rs2_data = 32'h12345678; #1;
        check("undefined funct3", 1'b0);

        // ------------------------------------------------------------------
        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

// ============================================================================
// alu_tb.v: testbench for the Raijin ALU
// ----------------------------------------------------------------------------
// Drives every ALU operation with carefully chosen operands, including
// signed/unsigned edge cases, shift boundaries, and zero-result detection.
// ============================================================================

`timescale 1ns / 1ps
`include "raijin_defs.vh"

module alu_tb;

    reg  [31:0] a;
    reg  [31:0] b;
    reg  [3:0]  op;
    wire [31:0] result;
    wire        zero;

    integer pass_count = 0;
    integer fail_count = 0;

    alu dut (
        .a      (a),
        .b      (b),
        .op     (op),
        .result (result),
        .zero   (zero)
    );

    // ------------------------------------------------------------------
    // Generic check task
    // ------------------------------------------------------------------
    task check_result;
        input [255:0] label;
        input [31:0]  expected;
        begin
            if (result === expected) begin
                $display("    PASS : %0s   (got 0x%08h)", label, result);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %0s   expected 0x%08h, got 0x%08h",
                         label, expected, result);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check_zero;
        input [255:0] label;
        input         expected;
        begin
            if (zero === expected) begin
                $display("    PASS : %0s   zero=%0d", label, zero);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %0s   expected zero=%0d, got %0d",
                         label, expected, zero);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("alu_tb.vcd");
        $dumpvars(0, alu_tb);

        $display("================================================");
        $display(" alu_tb : Raijin ALU verification");
        $display("================================================");

        // ============================================================
        // ADD
        // ============================================================
        $display("\n[Test] ADD");
        op = `ALU_OP_ADD;
        a = 32'd10; b = 32'd20; #1;
        check_result("10 + 20", 32'd30);

        a = 32'hFFFFFFFF; b = 32'd1; #1;
        check_result("-1 + 1 (overflow wraps to 0)", 32'd0);
        check_zero  ("zero flag set after wrap", 1'b1);

        a = 32'h7FFFFFFF; b = 32'd1; #1;
        check_result("INT_MAX + 1 → INT_MIN (signed overflow)", 32'h80000000);

        // ============================================================
        // SUB
        // ============================================================
        $display("\n[Test] SUB");
        op = `ALU_OP_SUB;
        a = 32'd50; b = 32'd30; #1;
        check_result("50 - 30", 32'd20);

        a = 32'd5; b = 32'd5; #1;
        check_result("5 - 5", 32'd0);
        check_zero  ("zero flag for equal subtract", 1'b1);

        a = 32'd0; b = 32'd1; #1;
        check_result("0 - 1 (= -1)", 32'hFFFFFFFF);

        // ============================================================
        // AND, OR, XOR
        // ============================================================
        $display("\n[Test] AND / OR / XOR");
        op = `ALU_OP_AND;
        a = 32'hFF00FF00; b = 32'h0F0F0F0F; #1;
        check_result("AND mask", 32'h0F000F00);

        op = `ALU_OP_OR;
        a = 32'hFF00FF00; b = 32'h0F0F0F0F; #1;
        check_result("OR mask", 32'hFF0FFF0F);

        op = `ALU_OP_XOR;
        a = 32'hAAAAAAAA; b = 32'hFFFFFFFF; #1;
        check_result("XOR with all-ones (= bitwise NOT)", 32'h55555555);

        // ============================================================
        // SLL. Shift left logical
        // ============================================================
        $display("\n[Test] SLL");
        op = `ALU_OP_SLL;
        a = 32'h00000001; b = 32'd4; #1;
        check_result("1 << 4", 32'd16);

        a = 32'h00000001; b = 32'd31; #1;
        check_result("1 << 31 (max shift)", 32'h80000000);

        // Only lower 5 bits of b matter. Feed a huge b, expect b[4:0]=0
        a = 32'hDEADBEEF; b = 32'hFFFFFFE0; #1;   // 0xE0 = 1110_0000, low 5 bits = 0
        check_result("shift by b[4:0]=0 ignores upper bits", 32'hDEADBEEF);

        // ============================================================
        // SRL. Shift right logical (zero-fill)
        // ============================================================
        $display("\n[Test] SRL");
        op = `ALU_OP_SRL;
        a = 32'h80000000; b = 32'd1; #1;
        check_result("0x80000000 >> 1 (logical, zero-fill)", 32'h40000000);

        a = 32'hFFFFFFFF; b = 32'd4; #1;
        check_result("all ones >> 4 (logical)", 32'h0FFFFFFF);

        // ============================================================
        // SRA. Shift right arithmetic (sign-fill)
        // ============================================================
        $display("\n[Test] SRA");
        op = `ALU_OP_SRA;
        a = 32'h80000000; b = 32'd1; #1;
        check_result("0x80000000 >>> 1 (arithmetic, sign-fill)", 32'hC0000000);

        a = 32'hFFFFFFF0; b = 32'd2; #1;   // -16 >>> 2 should be -4
        check_result("(-16) >>> 2 = -4", 32'hFFFFFFFC);

        a = 32'h7FFFFFFF; b = 32'd1; #1;   // positive: same as SRL
        check_result("positive >>> 1 acts like SRL", 32'h3FFFFFFF);

        // ============================================================
        // SLT. Signed less-than
        // ============================================================
        $display("\n[Test] SLT (signed)");
        op = `ALU_OP_SLT;
        a = 32'd5; b = 32'd10; #1;
        check_result("5 < 10 → 1", 32'd1);

        a = 32'd10; b = 32'd5; #1;
        check_result("10 < 5 → 0", 32'd0);

        a = 32'hFFFFFFFF; b = 32'd1; #1;   // -1 vs 1
        check_result("-1 < 1 → 1 (signed)", 32'd1);

        a = 32'h80000000; b = 32'h7FFFFFFF; #1;   // INT_MIN vs INT_MAX
        check_result("INT_MIN < INT_MAX → 1", 32'd1);

        // ============================================================
        // SLTU. Unsigned less-than
        // ============================================================
        $display("\n[Test] SLTU (unsigned)");
        op = `ALU_OP_SLTU;
        a = 32'd5; b = 32'd10; #1;
        check_result("5 < 10 → 1", 32'd1);

        a = 32'hFFFFFFFF; b = 32'd1; #1;   // 4G vs 1, unsigned
        check_result("0xFFFFFFFF < 1 → 0 (unsigned)", 32'd0);

        a = 32'd0; b = 32'd1; #1;
        check_result("0 < 1 → 1", 32'd1);

        // ============================================================
        // Default / unknown op → result = 0
        // ============================================================
        $display("\n[Test] unknown op falls back to 0");
        op = 4'd15;
        a = 32'hDEADBEEF; b = 32'h12345678; #1;
        check_result("op=15 returns 0", 32'd0);
        check_zero  ("zero flag set for 0 result", 1'b1);

        // ------------------------------------------------------------------
        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

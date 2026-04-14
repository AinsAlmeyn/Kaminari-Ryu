// ============================================================================
// pc_reg_tb.v: testbench for the program counter register
// ============================================================================

`timescale 1ns / 1ps

module pc_reg_tb;

    reg         clk;
    reg         reset;
    reg  [31:0] next_pc;
    wire [31:0] pc;

    integer pass_count = 0;
    integer fail_count = 0;

    pc_reg dut (
        .clk     (clk),
        .reset   (reset),
        .next_pc (next_pc),
        .pc      (pc)
    );

    // 10 ns clock
    initial clk = 0;
    always #5 clk = ~clk;

    task check;
        input [255:0] label;
        input [31:0]  expected;
        begin
            if (pc === expected) begin
                $display("    PASS : %0s   (got 0x%08h)", label, pc);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %0s   expected 0x%08h, got 0x%08h",
                         label, expected, pc);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("pc_reg_tb.vcd");
        $dumpvars(0, pc_reg_tb);

        $display("================================================");
        $display(" pc_reg_tb : Program counter register");
        $display("================================================");

        // ---- Apply reset for one cycle ----------------------------
        $display("\n[Test] Reset clears PC to 0");
        reset   = 1'b1;
        next_pc = 32'hDEADBEEF;
        @(posedge clk); #1;
        check("PC = 0 after reset", 32'h0000_0000);

        // ---- Release reset, advance PC by 4 each cycle ------------
        $display("\n[Test] Sequential advance (PC += 4)");
        reset = 1'b0;
        next_pc = pc + 32'd4;
        @(posedge clk); #1;
        check("PC = 4 after one tick", 32'h0000_0004);

        next_pc = pc + 32'd4;
        @(posedge clk); #1;
        check("PC = 8 after two ticks", 32'h0000_0008);

        next_pc = pc + 32'd4;
        @(posedge clk); #1;
        check("PC = 12 after three ticks", 32'h0000_000C);

        // ---- Branch jump simulation -------------------------------
        $display("\n[Test] Direct load (branch target)");
        next_pc = 32'h0000_1000;
        @(posedge clk); #1;
        check("PC jumped to 0x1000", 32'h0000_1000);

        next_pc = pc + 32'd4;
        @(posedge clk); #1;
        check("PC advanced past target", 32'h0000_1004);

        // ---- Reset again ------------------------------------------
        $display("\n[Test] Reset mid-execution");
        reset = 1'b1;
        next_pc = 32'h7FFF_FFFF;
        @(posedge clk); #1;
        check("PC back to 0", 32'h0000_0000);

        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

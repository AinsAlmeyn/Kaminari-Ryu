// ============================================================================
// soft_int_tb.v: end-to-end machine-software interrupt test
// ----------------------------------------------------------------------------
// Loads programs/soft_int_test.hex. The program raises MSIP through the CLINT
// MMIO register, the handler clears it and re-raises until TARGET interrupts
// have fired, then writes 1 to tohost and halts.
//
// Verifies:
//   * mem[0x1000] == 1   (tohost flag)
//   * mem[0x1004] == 5   (5 software interrupts dispatched)
//   * cnt_interrupt == 5 (all async, no exceptions)
//   * cnt_exception == 0
// ============================================================================

`timescale 1ns / 1ps

module soft_int_tb;

    reg clk;
    reg reset;

    raijin_core #(
        .IMEM_DEPTH_WORDS (2048),
        .IMEM_INIT_FILE   ("../raijin/programs/soft_int_test.hex"),
        .DMEM_DEPTH_WORDS (2048)
    ) dut (
        .clk   (clk),
        .reset (reset)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    task check;
        input [255:0] label;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                $display("    PASS : %0s   actual=%0d (0x%08h)", label, actual, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %0s   expected=%0d (0x%08h), actual=%0d (0x%08h)",
                         label, expected, expected, actual, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("soft_int_tb.vcd");
        $dumpvars(0, soft_int_tb);

        $display("================================================");
        $display(" soft_int_tb : machine-software interrupt path");
        $display("================================================");

        reset = 1'b1;
        @(posedge clk); @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        repeat (1000) @(posedge clk);

        $display("\n---- Final state ----");
        $display("  PC              = 0x%08h", dut.pc);
        $display("  mem[0x1000]     = %0d  (tohost)", dut.dmem_inst.mem[32'h400]);
        $display("  mem[0x1004]     = %0d  (intr count)", dut.dmem_inst.mem[32'h401]);
        $display("  cnt_interrupt   = %0d", dut.cnt_interrupt);
        $display("  cnt_exception   = %0d", dut.cnt_exception);
        $display("  cnt_trap        = %0d", dut.cnt_trap);

        $display("\n---- Checks ----");
        check("tohost == 1",       dut.dmem_inst.mem[32'h400], 32'd1);
        check("intr count == 5",   dut.dmem_inst.mem[32'h401], 32'd5);
        check("cnt_interrupt==5",  dut.cnt_interrupt[31:0],    32'd5);
        check("cnt_exception==0",  dut.cnt_exception[31:0],    32'd0);

        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

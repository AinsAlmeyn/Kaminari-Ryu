// ============================================================================
// timer_int_tb.v: end-to-end machine-timer interrupt test (v2)
// ----------------------------------------------------------------------------
// Loads programs/timer_int_test.hex. The program:
//   1. Installs a trap handler at 0x400.
//   2. Programs the CLINT mtimecmp to fire ~200 cycles after reset.
//   3. Enables mie.MTIE and mstatus.MIE.
//   4. Enters a busy loop that checks mem[0x1000] (tohost) for the halt flag.
//   5. The handler increments mem[0x1004] (intr count) each tick, schedules
//      the next tick, and after TARGET_TICKS writes 1 to mem[0x1000] (tohost)
//      to end the program.
//
// We verify:
//   * mem[0x1000] == 1         (tohost flag set by handler)
//   * mem[0x1004] == 10        (exactly TARGET_TICKS interrupts fired)
//   * mem[0x1008]  > 0         (main loop ran at least once before done)
//   * cnt_trap    == 10        (core's trap counter matches)
// ============================================================================

`timescale 1ns / 1ps

module timer_int_tb;

    reg clk;
    reg reset;

    raijin_core #(
        .IMEM_DEPTH_WORDS (2048),
        .IMEM_INIT_FILE   ("../raijin/programs/timer_int_test.hex"),
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
                $display("    PASS : %0s   actual=%0d (0x%08h)",
                         label, actual, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %0s   expected=%0d (0x%08h), actual=%0d (0x%08h)",
                         label, expected, expected, actual, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task check_gt;
        input [255:0] label;
        input [31:0]  actual;
        input [31:0]  min_val;
        begin
            if (actual > min_val) begin
                $display("    PASS : %0s   actual=%0d (> %0d)", label, actual, min_val);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %0s   expected > %0d, actual=%0d", label, min_val, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("timer_int_tb.vcd");
        $dumpvars(0, timer_int_tb);

        $display("================================================");
        $display(" timer_int_tb : machine-timer interrupt path");
        $display("================================================");

        reset = 1'b1;
        @(posedge clk); @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // 10 ticks at ~200 cycles each + setup + epilogue = ~2.5K cycles.
        // Budget 5000 cycles to be safe.
        repeat (5000) @(posedge clk);

        $display("\n---- Final state ----");
        $display("  PC            = 0x%08h", dut.pc);
        $display("  mem[0x1000]   = %0d  (tohost)",   dut.dmem_inst.mem[32'h400]);
        $display("  mem[0x1004]   = %0d  (intr count)", dut.dmem_inst.mem[32'h401]);
        $display("  mem[0x1008]   = %0d  (loop iter)",  dut.dmem_inst.mem[32'h402]);
        $display("  cnt_trap      = %0d", dut.cnt_trap);

        $display("\n---- Checks ----");
        check   ("tohost == 1",         dut.dmem_inst.mem[32'h400], 32'd1);
        check   ("intr count == 10",    dut.dmem_inst.mem[32'h401], 32'd10);
        check_gt("loop iter > 0",       dut.dmem_inst.mem[32'h402], 32'd0);
        check   ("cnt_trap == 10",      dut.cnt_trap[31:0],         32'd10);

        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

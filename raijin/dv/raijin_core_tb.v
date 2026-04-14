// ============================================================================
// raijin_core_tb.v: end-to-end test: run the sum_1_to_5 program
// ----------------------------------------------------------------------------
// Loads programs/sum_1_to_5.hex into the core's instruction memory, runs
// for enough cycles to complete the loop and the store, then peeks at the
// internal register file and data memory to verify the program produced
// the expected results.
//
// Hierarchical references (dut.regfile_inst.registers[i]) are simulation
// only. They would not synthesize, but here they let us inspect state
// without exporting debug ports through every module.
// ============================================================================

`timescale 1ns / 1ps

module raijin_core_tb;

    reg clk;
    reg reset;

    raijin_core #(
        .IMEM_DEPTH_WORDS (256),
        .IMEM_INIT_FILE   ("../raijin/programs/sum_1_to_5.hex"),
        .DMEM_DEPTH_WORDS (256)
    ) dut (
        .clk   (clk),
        .reset (reset)
    );

    // 10 ns period
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

    initial begin
        $dumpfile("raijin_core_tb.vcd");
        $dumpvars(0, raijin_core_tb);

        $display("================================================");
        $display(" raijin_core_tb : sum 1..5 program");
        $display("================================================");

        // Hold reset for 2 cycles so PC and registers settle.
        reset = 1'b1;
        @(posedge clk); @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Run for plenty of cycles. The program needs ~22 cycles of useful
        // work then enters the halt loop; 60 cycles is comfortably long.
        repeat (60) @(posedge clk);

        $display("\n---- Final state ----");
        $display("  PC          = 0x%08h", dut.pc);
        $display("  x1  (sum)   = %0d", dut.regfile_inst.registers[1]);
        $display("  x2  (count) = %0d", dut.regfile_inst.registers[2]);
        $display("  x3  (limit) = %0d", dut.regfile_inst.registers[3]);
        $display("  x10 (a0)    = %0d", dut.regfile_inst.registers[10]);
        $display("  mem[0x100]  = %0d", dut.dmem_inst.mem[64]);   // 0x100 / 4 = 64

        $display("\n---- Checks ----");
        check("x1 == 15",          dut.regfile_inst.registers[1],  32'd15);
        check("x2 == 6",           dut.regfile_inst.registers[2],  32'd6);
        check("x3 == 6",           dut.regfile_inst.registers[3],  32'd6);
        check("x10 == 15",         dut.regfile_inst.registers[10], 32'd15);
        check("mem[0x100] == 15",  dut.dmem_inst.mem[64],          32'd15);
        check("PC stuck at 0x020", dut.pc,                         32'h0000_0020);

        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

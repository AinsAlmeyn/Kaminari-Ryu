// ============================================================================
// imem_tb.v: testbench for the instruction memory
// ----------------------------------------------------------------------------
// Preloads a known program from a hex file and verifies sequential fetches.
// ============================================================================

`timescale 1ns / 1ps

module imem_tb;

    reg  [31:0] addr;
    wire [31:0] instruction;

    integer pass_count = 0;
    integer fail_count = 0;

    imem #(
        .DEPTH_WORDS (16),
        .INIT_FILE   ("imem_test.hex")
    ) dut (
        .addr        (addr),
        .instruction (instruction)
    );

    task check;
        input [255:0] label;
        input [31:0]  expected;
        begin
            if (instruction === expected) begin
                $display("    PASS : %0s   (got 0x%08h)", label, instruction);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %0s   expected 0x%08h, got 0x%08h",
                         label, expected, instruction);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("imem_tb.vcd");
        $dumpvars(0, imem_tb);

        $display("================================================");
        $display(" imem_tb : Instruction memory");
        $display("================================================");

        // Sequential reads. Addresses are byte addresses, instructions
        // sit at 4-byte boundaries.
        $display("\n[Test] Sequential fetches");
        addr = 32'h00000000; #1;
        check("addr=0x00 (1st instr)",  32'hDEADBEEF);
        addr = 32'h00000004; #1;
        check("addr=0x04 (2nd instr)",  32'h12345678);
        addr = 32'h00000008; #1;
        check("addr=0x08 (3rd instr)",  32'hCAFEBABE);
        addr = 32'h0000000C; #1;
        check("addr=0x0C (4th instr)",  32'h00000013);    // nop = addi x0,x0,0

        // Bottom 2 bits ignored
        $display("\n[Test] Bottom 2 bits ignored");
        addr = 32'h00000005; #1;        // same as 0x04
        check("addr=0x05 reads same as 0x04", 32'h12345678);
        addr = 32'h00000007; #1;        // same as 0x04
        check("addr=0x07 reads same as 0x04", 32'h12345678);

        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

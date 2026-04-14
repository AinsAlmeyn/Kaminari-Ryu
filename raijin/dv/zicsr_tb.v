// ============================================================================
// zicsr_tb.v: end-to-end test of the Zicsr extension, ECALL trap,
//              and MRET return.
// ============================================================================

`timescale 1ns / 1ps

module zicsr_tb;

    reg clk;
    reg reset;

    raijin_core #(
        .IMEM_DEPTH_WORDS (256),
        .IMEM_INIT_FILE   ("../raijin/programs/zicsr_test.hex"),
        .DMEM_DEPTH_WORDS (256)
    ) dut (
        .clk   (clk),
        .reset (reset)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    task check_mem;
        input [255:0] label;
        input [31:0]  byte_addr;
        input [31:0]  expected;
        reg   [31:0]  actual;
        begin
            actual = dut.dmem_inst.mem[byte_addr >> 2];
            if (actual === expected) begin
                $display("    PASS : %-50s mem[0x%03h]=0x%08h",
                         label, byte_addr, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %-50s mem[0x%03h] expected 0x%08h, got 0x%08h",
                         label, byte_addr, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("zicsr_tb.vcd");
        $dumpvars(0, zicsr_tb);

        $display("================================================");
        $display(" zicsr_tb : Zicsr + trap + MRET");
        $display("================================================");

        reset = 1; @(posedge clk); @(posedge clk);
        @(negedge clk); reset = 0;

        // Plenty of cycles for the program + handler round-trip.
        repeat (200) @(posedge clk);

        $display("\n---- Final state ----");
        $display("  PC = 0x%08h  (expect halt at 0x%h)", dut.pc, 32'h21C);
        $display("  mepc    = 0x%08h", dut.csr_file_inst.mepc);
        $display("  mcause  = 0x%08h", dut.csr_file_inst.mcause);
        $display("  mtvec   = 0x%08h", dut.csr_file_inst.mtvec);
        $display("  mscratch= 0x%08h", dut.csr_file_inst.mscratch);

        $display("\n[Zicsr basic ops]");
        check_mem("CSRRW x3 old mscratch=0",          32'h100, 32'd0);
        check_mem("CSRRW x4 prev=0x1234",             32'h104, 32'h00001234);
        check_mem("CSRRS x6 old mscratch=0xF0",       32'h108, 32'hF0);
        check_mem("CSRRS (rs1=x0) pure read 0xFF",    32'h10C, 32'hFF);
        check_mem("CSRRC x8 old=0xFF",                32'h110, 32'hFF);
        check_mem("mscratch after CSRRC = 0xF0",      32'h114, 32'hF0);

        $display("\n[Zicsr immediate ops]");
        check_mem("CSRRWI x10 old=0xF0",              32'h118, 32'hF0);
        check_mem("CSRRSI x11 old=5",                 32'h11C, 32'd5);
        check_mem("CSRRCI x12 old=7",                 32'h120, 32'd7);

        $display("\n[ECALL / MRET flow]");
        check_mem("pre-ECALL sentinel = 100",         32'h124, 32'd100);
        check_mem("post-MRET sentinel = 42",          32'h128, 32'd42);
        check_mem("trap counter = 1",                 32'h12C, 32'd1);

        // Final CSR snapshot
        $display("\n[CSR final state]");
        if (dut.csr_file_inst.mtvec === 32'h200) begin
            $display("    PASS : mtvec still = 0x200");
            pass_count = pass_count + 1;
        end else begin
            $display("    FAIL : mtvec expected 0x200, got 0x%08h",
                     dut.csr_file_inst.mtvec);
            fail_count = fail_count + 1;
        end

        if (dut.csr_file_inst.mcause === 32'd11) begin
            $display("    PASS : mcause = 11 (ECALL_FROM_M)");
            pass_count = pass_count + 1;
        end else begin
            $display("    FAIL : mcause expected 11, got %0d",
                     dut.csr_file_inst.mcause);
            fail_count = fail_count + 1;
        end

        if (dut.csr_file_inst.mepc === 32'h74) begin
            $display("    PASS : mepc = 0x74 (post-ECALL return addr)");
            pass_count = pass_count + 1;
        end else begin
            $display("    FAIL : mepc expected 0x74, got 0x%08h",
                     dut.csr_file_inst.mepc);
            fail_count = fail_count + 1;
        end

        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

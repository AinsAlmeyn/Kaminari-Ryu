// ============================================================================
// coverage_tb.v: runs coverage_all.s and verifies the result of every
// RV32I instruction our core implements.
// ============================================================================

`timescale 1ns / 1ps

module coverage_tb;

    reg clk;
    reg reset;

    // imem needs depth >= 256 words (program stretches past address 0x200).
    // dmem needs depth >= ~0x400 bytes = 256 words because we use mem[0x300+]
    // for scratch and mem[0x100+] for results.
    raijin_core #(
        .IMEM_DEPTH_WORDS (512),
        .IMEM_INIT_FILE   ("../raijin/programs/coverage_all.hex"),
        .DMEM_DEPTH_WORDS (512)
    ) dut (
        .clk   (clk),
        .reset (reset)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer pass_count = 0;
    integer fail_count = 0;

    // Convert a byte address to a dmem word index.
    function integer widx;
        input [31:0] byte_addr;
        begin
            widx = byte_addr >> 2;
        end
    endfunction

    task check_mem;
        input [255:0] label;
        input [31:0]  byte_addr;
        input [31:0]  expected;
        reg   [31:0]  actual;
        begin
            actual = dut.dmem_inst.mem[widx(byte_addr)];
            if (actual === expected) begin
                $display("    PASS : %-40s mem[0x%03h]=0x%08h",
                         label, byte_addr, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %-40s mem[0x%03h]  expected 0x%08h, got 0x%08h",
                         label, byte_addr, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("coverage_tb.vcd");
        $dumpvars(0, coverage_tb);

        $display("================================================");
        $display(" coverage_tb : RV32I instruction coverage");
        $display("================================================");

        reset = 1'b1;
        @(posedge clk); @(posedge clk);
        @(negedge clk); reset = 1'b0;

        // The program executes a few hundred instructions and then spins
        // on `j halt`. 1500 cycles is more than enough.
        repeat (1500) @(posedge clk);

        $display("\n---- Final PC : 0x%08h ----\n", dut.pc);

        // ------------------------ R-type ------------------------
        $display("[R-type]");
        check_mem("SUB  100-30",            32'h100, 32'd70);
        check_mem("AND  F0 & 33",           32'h104, 32'h30);
        check_mem("OR   F0 | 33",           32'h108, 32'hF3);
        check_mem("XOR  F0 ^ 33",           32'h10C, 32'hC3);
        check_mem("SLT  -1 < 1 signed",     32'h110, 32'd1);
        check_mem("SLTU -1 < 1 unsigned",   32'h114, 32'd0);
        check_mem("SLL  64 << 1",           32'h118, 32'd128);
        check_mem("SRL  64 >> 1",           32'h11C, 32'd32);
        check_mem("SRA  -1 >>> 1",          32'h120, 32'hFFFFFFFF);

        // ------------------------ I-type arith ------------------
        $display("\n[I-type arithmetic]");
        check_mem("SLTI  10 < 20",          32'h124, 32'd1);
        check_mem("SLTI  10 < 5",           32'h128, 32'd0);
        check_mem("SLTI  -1 < 0 signed",    32'h12C, 32'd1);
        check_mem("SLTIU -1 < 1 unsigned",  32'h130, 32'd0);
        check_mem("XORI  10 ^ 15",          32'h134, 32'd5);
        check_mem("ORI   10 | 15",          32'h138, 32'd15);
        check_mem("ANDI  10 & 6",           32'h13C, 32'd2);
        check_mem("SLLI  10 << 3",          32'h140, 32'd80);
        check_mem("SRLI  -16 >> 4 logical", 32'h144, 32'h0FFFFFFF);

        // ------------------------ U-type ------------------------
        $display("\n[U-type]");
        check_mem("LUI+ADDI = 0x12345678",  32'h148, 32'h12345678);
        check_mem("AUIPC at 0x200 -> 0x200", 32'h14C, 32'h00000200);

        // ------------------------ Branches ----------------------
        $display("\n[Branches]");
        check_mem("branch counter = 7",     32'h150, 32'd7);

        // ------------------------ Loads -------------------------
        $display("\n[Loads]");
        check_mem("LB  byte[0] = 0x78",     32'h154, 32'h00000078);
        check_mem("LB  byte[3] = 0x12",     32'h158, 32'h00000012);
        check_mem("LB  signed 0x80",        32'h15C, 32'hFFFFFF80);
        check_mem("LBU unsigned 0x80",      32'h160, 32'h00000080);
        check_mem("LH  signed 0x8000",      32'h164, 32'hFFFF8000);
        check_mem("LHU unsigned 0x8000",    32'h168, 32'h00008000);

        // ------------------------ Stores ------------------------
        $display("\n[Stores]");
        check_mem("SB at byte 2 -> 0x00AB0000", 32'h16C, 32'h00AB0000);
        check_mem("SH at halfword 1 -> 0x07FF0000", 32'h170, 32'h07FF0000);

        // ------------------------ JAL/JALR ----------------------
        $display("\n[JAL/JALR function call]");
        check_mem("add_one(5)  = 6",        32'h174, 32'd6);
        check_mem("add_one(20) = 21",       32'h178, 32'd21);

        // ------------------------ SRAI --------------------------
        $display("\n[SRAI]");
        check_mem("SRAI -16 >>> 4 arithmetic", 32'h17C, 32'hFFFFFFFF);

        // ============================================================
        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

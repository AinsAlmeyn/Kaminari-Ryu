// ============================================================================
// dmem_tb.v: testbench for the data memory (byte/halfword/word, signed/unsigned)
// ============================================================================

`timescale 1ns / 1ps
`include "riscv_defs.vh"

module dmem_tb;

    reg         clk;
    reg  [31:0] addr;
    reg  [31:0] write_data;
    reg         mem_read_en;
    reg         mem_write_en;
    reg  [2:0]  funct3;
    wire [31:0] read_data;

    integer pass_count = 0;
    integer fail_count = 0;

    dmem #(
        .DEPTH_WORDS (16)
    ) dut (
        .clk          (clk),
        .addr         (addr),
        .write_data   (write_data),
        .mem_read_en  (mem_read_en),
        .mem_write_en (mem_write_en),
        .funct3       (funct3),
        .read_data    (read_data)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    task check;
        input [255:0] label;
        input [31:0]  expected;
        begin
            if (read_data === expected) begin
                $display("    PASS : %0s   (got 0x%08h)", label, read_data);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %0s   expected 0x%08h, got 0x%08h",
                         label, expected, read_data);
                fail_count = fail_count + 1;
            end
        end
    endtask

    task do_store;
        input [31:0] a;
        input [31:0] data;
        input [2:0]  f3;
        begin
            @(negedge clk);
            addr         = a;
            write_data   = data;
            funct3       = f3;
            mem_write_en = 1;
            @(posedge clk);
            @(negedge clk);
            mem_write_en = 0;
        end
    endtask

    initial begin
        $dumpfile("dmem_tb.vcd");
        $dumpvars(0, dmem_tb);

        $display("================================================");
        $display(" dmem_tb : Data memory");
        $display("================================================");

        // Initialize all signals
        addr = 0; write_data = 0; mem_read_en = 0; mem_write_en = 0; funct3 = 0;
        #2;

        // ============================================================
        // Word write + word read
        // ============================================================
        $display("\n[Test] SW then LW");
        do_store(32'h0, 32'hDEADBEEF, `FUNCT3_STORE_WORD);
        addr = 32'h0; funct3 = `FUNCT3_LOAD_WORD; #1;
        check("LW reads back DEADBEEF", 32'hDEADBEEF);

        // ============================================================
        // Byte write. Overlay only one byte, leave others intact
        // ============================================================
        $display("\n[Test] SB at offset 1 only modifies that byte");
        do_store(32'h1, 32'h000000AA, `FUNCT3_STORE_BYTE);
        addr = 32'h0; funct3 = `FUNCT3_LOAD_WORD; #1;
        // Original word: 0xDEADBEEF (LE: bytes are EF,BE,AD,DE at offsets 0,1,2,3)
        // After SB to offset 1 with data 0xAA: bytes become EF,AA,AD,DE
        // Word is 0xDEADAAEF
        check("Word now 0xDEADAAEF", 32'hDEADAAEF);

        // ============================================================
        // Byte reads (signed and unsigned) at each offset
        // ============================================================
        $display("\n[Test] LB / LBU at each byte offset");
        addr = 32'h0; funct3 = `FUNCT3_LOAD_BYTE_SIGNED; #1;
        check("LB offset 0 = 0xEF -> sign-ext = 0xFFFFFFEF", 32'hFFFFFFEF);

        addr = 32'h1; funct3 = `FUNCT3_LOAD_BYTE_SIGNED; #1;
        check("LB offset 1 = 0xAA -> sign-ext = 0xFFFFFFAA", 32'hFFFFFFAA);

        addr = 32'h0; funct3 = `FUNCT3_LOAD_BYTE_UNSIGNED; #1;
        check("LBU offset 0 = 0xEF -> zero-ext = 0x000000EF", 32'h000000EF);

        addr = 32'h2; funct3 = `FUNCT3_LOAD_BYTE_UNSIGNED; #1;
        check("LBU offset 2 = 0xAD", 32'h000000AD);

        // ============================================================
        // Halfword write
        // ============================================================
        $display("\n[Test] SH at offset 0");
        do_store(32'h0, 32'h00001234, `FUNCT3_STORE_HALFWORD);
        addr = 32'h0; funct3 = `FUNCT3_LOAD_WORD; #1;
        check("Lower 16b updated to 0x1234, upper 16b 0xDEAD", 32'hDEAD1234);

        $display("\n[Test] SH at offset 2 (upper halfword)");
        do_store(32'h2, 32'h0000ABCD, `FUNCT3_STORE_HALFWORD);
        addr = 32'h0; funct3 = `FUNCT3_LOAD_WORD; #1;
        check("Upper 16b now 0xABCD", 32'hABCD1234);

        // ============================================================
        // Halfword loads, signed and unsigned
        // ============================================================
        $display("\n[Test] LH / LHU sign-extension");
        addr = 32'h0; funct3 = `FUNCT3_LOAD_HALFWORD_SIGNED; #1;
        check("LH lower = 0x1234 (positive)", 32'h00001234);

        addr = 32'h2; funct3 = `FUNCT3_LOAD_HALFWORD_SIGNED; #1;
        // 0xABCD = top bit set -> negative as 16-bit signed
        check("LH upper = 0xABCD -> sign-ext = 0xFFFFABCD", 32'hFFFFABCD);

        addr = 32'h2; funct3 = `FUNCT3_LOAD_HALFWORD_UNSIGNED; #1;
        check("LHU upper = 0xABCD -> zero-ext = 0x0000ABCD", 32'h0000ABCD);

        // ============================================================
        // Different word. Independence
        // ============================================================
        $display("\n[Test] writes to different words are independent");
        do_store(32'h4, 32'hCAFEBABE, `FUNCT3_STORE_WORD);
        addr = 32'h4; funct3 = `FUNCT3_LOAD_WORD; #1;
        check("New word at 0x4 = CAFEBABE", 32'hCAFEBABE);
        addr = 32'h0; funct3 = `FUNCT3_LOAD_WORD; #1;
        check("Word at 0x0 unchanged",      32'hABCD1234);

        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

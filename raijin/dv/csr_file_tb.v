// ============================================================================
// csr_file_tb.v: testbench for the CSR file + trap/MRET logic
// ============================================================================

`timescale 1ns / 1ps
`include "riscv_defs.vh"
`include "raijin_defs.vh"

module csr_file_tb;

    reg         clk;
    reg         reset;
    reg         csr_access_en;
    reg  [11:0] csr_addr;
    reg  [1:0]  csr_op;
    reg  [31:0] csr_wdata;
    reg         csr_write_en;
    wire [31:0] csr_rdata;

    reg         trap_en;
    reg  [31:0] trap_cause;
    reg  [31:0] trap_pc;
    reg  [31:0] trap_tval;
    reg         mret_en;

    wire [31:0] mtvec_out;
    wire [31:0] mepc_out;

    integer pass_count = 0;
    integer fail_count = 0;

    csr_file dut (
        .clk           (clk),
        .reset         (reset),
        .csr_access_en (csr_access_en),
        .csr_addr      (csr_addr),
        .csr_op        (csr_op),
        .csr_wdata     (csr_wdata),
        .csr_write_en  (csr_write_en),
        .csr_rdata     (csr_rdata),
        .trap_en       (trap_en),
        .trap_cause    (trap_cause),
        .trap_pc       (trap_pc),
        .trap_tval     (trap_tval),
        .mret_en       (mret_en),
        .mtvec_out     (mtvec_out),
        .mepc_out      (mepc_out)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    task check;
        input [255:0] label;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                $display("    PASS : %-45s (got 0x%08h)", label, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %-45s expected 0x%08h, got 0x%08h",
                         label, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Clock-safe CSR write task: sets inputs, waits one rising edge, clears.
    task csr_do_write;
        input [11:0] addr;
        input [1:0]  op;
        input [31:0] wd;
        begin
            @(negedge clk);
            csr_access_en = 1'b1;
            csr_addr      = addr;
            csr_op        = op;
            csr_wdata     = wd;
            csr_write_en  = 1'b1;
            @(posedge clk);
            @(negedge clk);
            csr_access_en = 1'b0;
            csr_write_en  = 1'b0;
        end
    endtask

    task csr_do_read;
        input [11:0] addr;
        begin
            @(negedge clk);
            csr_access_en = 1'b1;
            csr_addr      = addr;
            csr_op        = `CSR_OP_WRITE;   // don't care when write_en=0
            csr_write_en  = 1'b0;
            #1;   // combinational settle
        end
    endtask

    task do_trap;
        input [31:0] cause;
        input [31:0] pc;
        input [31:0] tval;
        begin
            @(negedge clk);
            trap_en    = 1'b1;
            trap_cause = cause;
            trap_pc    = pc;
            trap_tval  = tval;
            @(posedge clk);
            @(negedge clk);
            trap_en = 1'b0;
        end
    endtask

    task do_mret;
        begin
            @(negedge clk);
            mret_en = 1'b1;
            @(posedge clk);
            @(negedge clk);
            mret_en = 1'b0;
        end
    endtask

    initial begin
        $dumpfile("csr_file_tb.vcd");
        $dumpvars(0, csr_file_tb);

        $display("================================================");
        $display(" csr_file_tb : CSR file + trap/MRET logic");
        $display("================================================");

        // Initial state
        csr_access_en = 0; csr_addr = 0; csr_op = 0;
        csr_wdata = 0; csr_write_en = 0;
        trap_en = 0; trap_cause = 0; trap_pc = 0; trap_tval = 0;
        mret_en = 0;

        // Reset for 2 cycles
        reset = 1; @(posedge clk); @(posedge clk); @(negedge clk);
        reset = 0;

        // ============================================================
        // Unimplemented CSR reads as zero
        // ============================================================
        $display("\n[Test] unimplemented CSR reads as zero");
        csr_do_read(12'hC00);   // cycle counter -- we don't implement
        check("CSR 0xC00 = 0", csr_rdata, 32'd0);

        // ============================================================
        // CSRRW basic: write, then read back
        // ============================================================
        $display("\n[Test] CSRRW mtvec = 0x1000");
        csr_do_write(`CSR_MTVEC, `CSR_OP_WRITE, 32'h00001000);
        csr_do_read(`CSR_MTVEC);
        check("mtvec = 0x1000", csr_rdata, 32'h00001000);
        check("mtvec_out masks low 2 bits", mtvec_out, 32'h00001000);

        // Low 2 bits should be stripped by mtvec_out
        csr_do_write(`CSR_MTVEC, `CSR_OP_WRITE, 32'h00001003);
        csr_do_read(`CSR_MTVEC);
        check("mtvec raw = 0x1003", csr_rdata, 32'h00001003);
        check("mtvec_out = 0x1000 (low bits stripped)", mtvec_out, 32'h00001000);

        // ============================================================
        // CSRRS (SET) - OR in bits
        // ============================================================
        $display("\n[Test] CSRRS mscratch, 0x0F0F");
        csr_do_write(`CSR_MSCRATCH, `CSR_OP_WRITE, 32'hF000_0000);
        csr_do_write(`CSR_MSCRATCH, `CSR_OP_SET,   32'h0000_0F0F);
        csr_do_read(`CSR_MSCRATCH);
        check("mscratch = F0000F0F", csr_rdata, 32'hF000_0F0F);

        // ============================================================
        // CSRRC (CLEAR) - AND NOT
        // ============================================================
        $display("\n[Test] CSRRC mscratch, 0x00000F00");
        csr_do_write(`CSR_MSCRATCH, `CSR_OP_CLEAR, 32'h0000_0F00);
        csr_do_read(`CSR_MSCRATCH);
        check("mscratch = F000000F (F00 cleared)", csr_rdata, 32'hF000_000F);

        // ============================================================
        // CSRRS with write_en=0 must NOT modify the CSR (spec rule)
        // ============================================================
        $display("\n[Test] write_en=0 means no write (CSRRS with rs1=x0)");
        @(negedge clk);
        csr_access_en = 1'b1;
        csr_addr      = `CSR_MSCRATCH;
        csr_op        = `CSR_OP_SET;
        csr_wdata     = 32'hFFFF_FFFF;     // would corrupt if we wrote
        csr_write_en  = 1'b0;              // but we said "don't write"
        @(posedge clk);
        @(negedge clk);
        csr_access_en = 1'b0;
        csr_do_read(`CSR_MSCRATCH);
        check("mscratch unchanged", csr_rdata, 32'hF000_000F);

        // ============================================================
        // mstatus: only MIE(3) and MPIE(7) are implemented
        // ============================================================
        $display("\n[Test] mstatus MIE / MPIE bits");
        csr_do_write(`CSR_MSTATUS, `CSR_OP_WRITE, 32'hFFFF_FFFF);
        csr_do_read(`CSR_MSTATUS);
        check("mstatus = 0x88 (only MIE/MPIE stuck)", csr_rdata, 32'h0000_0088);

        csr_do_write(`CSR_MSTATUS, `CSR_OP_CLEAR, 32'h0000_0008);  // clear MIE
        csr_do_read(`CSR_MSTATUS);
        check("mstatus = 0x80 (MIE cleared, MPIE stays)", csr_rdata, 32'h0000_0080);

        // ============================================================
        // Trap entry: saves PC, cause, tval; MPIE <= MIE; MIE <= 0
        // ============================================================
        $display("\n[Test] trap entry captures PC / cause / status");
        // Prime MIE = 1 first
        csr_do_write(`CSR_MSTATUS, `CSR_OP_SET, 32'h0000_0008);    // set MIE
        csr_do_read(`CSR_MSTATUS);
        check("pre-trap: MIE=1, MPIE=1 (0x88)", csr_rdata, 32'h0000_0088);

        do_trap(`MCAUSE_ECALL_FROM_M, 32'h0000_2000, 32'h0);
        csr_do_read(`CSR_MEPC);
        check("mepc = 0x2000", csr_rdata, 32'h0000_2000);
        csr_do_read(`CSR_MCAUSE);
        check("mcause = ECALL_FROM_M (11)", csr_rdata, 32'd11);
        csr_do_read(`CSR_MSTATUS);
        // After trap: MIE was 1, becomes MPIE. Old MPIE was 1, gets overwritten.
        // So final: MPIE=1, MIE=0 -> bits 7=1, 3=0 -> 0x80
        check("post-trap: MIE=0, MPIE=1 (0x80)", csr_rdata, 32'h0000_0080);

        // ============================================================
        // MRET: MIE <= MPIE, MPIE <= 1
        // ============================================================
        $display("\n[Test] MRET restores MIE from MPIE");
        do_mret();
        csr_do_read(`CSR_MSTATUS);
        // Before mret: MIE=0, MPIE=1. After: MIE=1, MPIE=1. => 0x88
        check("post-mret: MIE=1, MPIE=1 (0x88)", csr_rdata, 32'h0000_0088);

        // mepc_out reflects mepc for PC mux
        check("mepc_out = 0x2000", mepc_out, 32'h0000_2000);

        // ============================================================
        // mtval handling
        // ============================================================
        $display("\n[Test] mtval captures during trap");
        do_trap(`MCAUSE_ILLEGAL_INSTR, 32'h0000_4000, 32'hDEADBEEF);
        csr_do_read(`CSR_MTVAL);
        check("mtval = 0xDEADBEEF", csr_rdata, 32'hDEADBEEF);
        csr_do_read(`CSR_MCAUSE);
        check("mcause = 2 (illegal instr)", csr_rdata, 32'd2);

        // ============================================================
        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

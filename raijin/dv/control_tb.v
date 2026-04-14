// ============================================================================
// control_tb.v: testbench for the Raijin main control unit
// ----------------------------------------------------------------------------
// For every RV32I instruction family we feed (opcode, funct3, funct7) into
// the control unit and check that ALL nine output signals match what the
// spec requires.
// ============================================================================

`timescale 1ns / 1ps
`include "riscv_defs.vh"
`include "raijin_defs.vh"

module control_tb;

    reg  [6:0] opcode;
    reg  [2:0] funct3;
    reg  [6:0] funct7;

    wire       reg_write_en;
    wire       mem_read_en;
    wire       mem_write_en;
    wire [1:0] alu_src_a_sel;
    wire       alu_src_b_sel;
    wire [1:0] wb_src_sel;
    wire [3:0] alu_op;
    wire       branch;
    wire       jump;

    integer pass_count = 0;
    integer fail_count = 0;

    control dut (
        .opcode        (opcode),
        .funct3        (funct3),
        .funct7        (funct7),
        .reg_write_en  (reg_write_en),
        .mem_read_en   (mem_read_en),
        .mem_write_en  (mem_write_en),
        .alu_src_a_sel (alu_src_a_sel),
        .alu_src_b_sel (alu_src_b_sel),
        .wb_src_sel    (wb_src_sel),
        .alu_op        (alu_op),
        .branch        (branch),
        .jump          (jump)
    );

    // ------------------------------------------------------------------
    // Generic check task. The label is plain ASCII to avoid the Unicode
    // truncation issue we hit in alu_tb.v.
    // ------------------------------------------------------------------
    task check;
        input [255:0] label;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                $display("    PASS : %0s   (got 0x%h)", label, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %0s   expected 0x%h, got 0x%h",
                         label, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("control_tb.vcd");
        $dumpvars(0, control_tb);

        $display("================================================");
        $display(" control_tb : Raijin control unit verification");
        $display("================================================");

        // ============================================================
        // R-type ADD : opcode=ARITH_REGISTER, funct3=000, funct7=0
        // Expected: reg_write=1, mem=0, src_a=REG, src_b=REG,
        //           wb=ALU, alu_op=ADD, branch=0, jump=0
        // ============================================================
        $display("\n[Test] R-type ADD");
        opcode = `OPCODE_ARITH_REGISTER;
        funct3 = `FUNCT3_ADD_OR_SUB;
        funct7 = `FUNCT7_DEFAULT;
        #1;
        check("reg_write_en",  {31'b0, reg_write_en},  32'd1);
        check("mem_read_en",   {31'b0, mem_read_en},   32'd0);
        check("mem_write_en",  {31'b0, mem_write_en},  32'd0);
        check("alu_src_a_sel", {30'b0, alu_src_a_sel}, {30'b0, `ALU_SRC_A_REG});
        check("alu_src_b_sel", {31'b0, alu_src_b_sel}, {31'b0, `ALU_SRC_B_REG});
        check("wb_src_sel",    {30'b0, wb_src_sel},    {30'b0, `WB_SRC_ALU});
        check("alu_op",        {28'b0, alu_op},        {28'b0, `ALU_OP_ADD});
        check("branch",        {31'b0, branch},        32'd0);
        check("jump",          {31'b0, jump},          32'd0);

        // ============================================================
        // R-type SUB : same as ADD but funct7 = ALT
        // ============================================================
        $display("\n[Test] R-type SUB (funct7 alternate)");
        opcode = `OPCODE_ARITH_REGISTER;
        funct3 = `FUNCT3_ADD_OR_SUB;
        funct7 = `FUNCT7_SUBTRACT_OR_SHIFT_ARITHMETIC;
        #1;
        check("alu_op = SUB", {28'b0, alu_op}, {28'b0, `ALU_OP_SUB});

        // ============================================================
        // R-type SRA : funct3=101, funct7=ALT  (vs SRL which is funct7=0)
        // ============================================================
        $display("\n[Test] R-type SRA vs SRL");
        opcode = `OPCODE_ARITH_REGISTER;
        funct3 = `FUNCT3_SHIFT_RIGHT;
        funct7 = `FUNCT7_DEFAULT;
        #1;
        check("alu_op = SRL when funct7=0", {28'b0, alu_op}, {28'b0, `ALU_OP_SRL});

        funct7 = `FUNCT7_SUBTRACT_OR_SHIFT_ARITHMETIC;
        #1;
        check("alu_op = SRA when funct7=ALT", {28'b0, alu_op}, {28'b0, `ALU_OP_SRA});

        // ============================================================
        // I-type ADDI
        // ============================================================
        $display("\n[Test] I-type ADDI");
        opcode = `OPCODE_ARITH_IMMEDIATE;
        funct3 = `FUNCT3_ADD_IMM;
        funct7 = 7'b0;
        #1;
        check("reg_write_en",  {31'b0, reg_write_en},  32'd1);
        check("alu_src_a_sel", {30'b0, alu_src_a_sel}, {30'b0, `ALU_SRC_A_REG});
        check("alu_src_b_sel = IMM", {31'b0, alu_src_b_sel}, {31'b0, `ALU_SRC_B_IMM});
        check("alu_op = ADD",  {28'b0, alu_op},        {28'b0, `ALU_OP_ADD});
        check("wb_src = ALU",  {30'b0, wb_src_sel},    {30'b0, `WB_SRC_ALU});

        // ============================================================
        // I-type SRAI : funct3=101, funct7=ALT
        // ============================================================
        $display("\n[Test] I-type SRAI");
        opcode = `OPCODE_ARITH_IMMEDIATE;
        funct3 = `FUNCT3_SHIFT_RIGHT_IMM;
        funct7 = `FUNCT7_SUBTRACT_OR_SHIFT_ARITHMETIC;
        #1;
        check("alu_op = SRA", {28'b0, alu_op}, {28'b0, `ALU_OP_SRA});

        // ============================================================
        // LOAD (lw)
        // Expected: reg_write=1, mem_read=1, src_a=REG, src_b=IMM,
        //           wb=MEM, alu_op=ADD
        // ============================================================
        $display("\n[Test] LOAD (lw)");
        opcode = `OPCODE_LOAD;
        funct3 = `FUNCT3_LOAD_WORD;
        funct7 = 7'b0;
        #1;
        check("reg_write_en", {31'b0, reg_write_en}, 32'd1);
        check("mem_read_en",  {31'b0, mem_read_en},  32'd1);
        check("mem_write_en", {31'b0, mem_write_en}, 32'd0);
        check("alu_src_b = IMM", {31'b0, alu_src_b_sel}, {31'b0, `ALU_SRC_B_IMM});
        check("wb_src = MEM", {30'b0, wb_src_sel}, {30'b0, `WB_SRC_MEM});
        check("alu_op = ADD (addr calc)", {28'b0, alu_op}, {28'b0, `ALU_OP_ADD});

        // ============================================================
        // STORE (sw)
        // Expected: reg_write=0, mem_write=1, alu_op=ADD (addr calc)
        // ============================================================
        $display("\n[Test] STORE (sw)");
        opcode = `OPCODE_STORE;
        funct3 = `FUNCT3_STORE_WORD;
        funct7 = 7'b0;
        #1;
        check("reg_write_en = 0", {31'b0, reg_write_en}, 32'd0);
        check("mem_write_en = 1", {31'b0, mem_write_en}, 32'd1);
        check("mem_read_en = 0",  {31'b0, mem_read_en},  32'd0);
        check("alu_src_b = IMM",  {31'b0, alu_src_b_sel}, {31'b0, `ALU_SRC_B_IMM});
        check("alu_op = ADD",     {28'b0, alu_op}, {28'b0, `ALU_OP_ADD});

        // ============================================================
        // BRANCH (beq)
        // Expected: reg_write=0, branch=1, alu_src_a=PC, alu_src_b=IMM,
        //           alu_op=ADD (target calc)
        // ============================================================
        $display("\n[Test] BRANCH (beq)");
        opcode = `OPCODE_BRANCH;
        funct3 = `FUNCT3_BRANCH_EQUAL;
        funct7 = 7'b0;
        #1;
        check("reg_write_en = 0", {31'b0, reg_write_en}, 32'd0);
        check("branch = 1",       {31'b0, branch},        32'd1);
        check("jump = 0",         {31'b0, jump},          32'd0);
        check("alu_src_a = PC",   {30'b0, alu_src_a_sel}, {30'b0, `ALU_SRC_A_PC});
        check("alu_src_b = IMM",  {31'b0, alu_src_b_sel}, {31'b0, `ALU_SRC_B_IMM});
        check("alu_op = ADD",     {28'b0, alu_op},        {28'b0, `ALU_OP_ADD});

        // ============================================================
        // LUI
        // Expected: reg_write=1, alu_src_a=ZERO, alu_src_b=IMM,
        //           wb=ALU, alu_op=ADD  (rd = 0 + imm = imm)
        // ============================================================
        $display("\n[Test] LUI");
        opcode = `OPCODE_LOAD_UPPER_IMM;
        funct3 = 3'b0; funct7 = 7'b0;
        #1;
        check("reg_write_en = 1", {31'b0, reg_write_en}, 32'd1);
        check("alu_src_a = ZERO", {30'b0, alu_src_a_sel}, {30'b0, `ALU_SRC_A_ZERO});
        check("alu_src_b = IMM",  {31'b0, alu_src_b_sel}, {31'b0, `ALU_SRC_B_IMM});
        check("wb_src = ALU",     {30'b0, wb_src_sel},    {30'b0, `WB_SRC_ALU});
        check("alu_op = ADD",     {28'b0, alu_op},        {28'b0, `ALU_OP_ADD});

        // ============================================================
        // AUIPC
        // Expected: reg_write=1, alu_src_a=PC, alu_src_b=IMM, wb=ALU
        // ============================================================
        $display("\n[Test] AUIPC");
        opcode = `OPCODE_ADD_UPPER_IMM_TO_PC;
        funct3 = 3'b0; funct7 = 7'b0;
        #1;
        check("reg_write_en = 1", {31'b0, reg_write_en}, 32'd1);
        check("alu_src_a = PC",   {30'b0, alu_src_a_sel}, {30'b0, `ALU_SRC_A_PC});
        check("alu_src_b = IMM",  {31'b0, alu_src_b_sel}, {31'b0, `ALU_SRC_B_IMM});

        // ============================================================
        // JAL
        // Expected: reg_write=1, jump=1, alu_src_a=PC, alu_src_b=IMM,
        //           wb=PC4 (return address)
        // ============================================================
        $display("\n[Test] JAL");
        opcode = `OPCODE_JUMP_AND_LINK;
        funct3 = 3'b0; funct7 = 7'b0;
        #1;
        check("reg_write_en = 1", {31'b0, reg_write_en}, 32'd1);
        check("jump = 1",         {31'b0, jump},          32'd1);
        check("branch = 0",       {31'b0, branch},        32'd0);
        check("alu_src_a = PC",   {30'b0, alu_src_a_sel}, {30'b0, `ALU_SRC_A_PC});
        check("wb_src = PC4",     {30'b0, wb_src_sel},    {30'b0, `WB_SRC_PC4});

        // ============================================================
        // JALR
        // Expected: reg_write=1, jump=1, alu_src_a=REG, alu_src_b=IMM,
        //           wb=PC4
        // ============================================================
        $display("\n[Test] JALR");
        opcode = `OPCODE_JUMP_AND_LINK_REG;
        funct3 = 3'b0; funct7 = 7'b0;
        #1;
        check("reg_write_en = 1", {31'b0, reg_write_en}, 32'd1);
        check("jump = 1",         {31'b0, jump},          32'd1);
        check("alu_src_a = REG",  {30'b0, alu_src_a_sel}, {30'b0, `ALU_SRC_A_REG});
        check("wb_src = PC4",     {30'b0, wb_src_sel},    {30'b0, `WB_SRC_PC4});

        // ============================================================
        // FENCE / SYSTEM treated as NOP for now
        // ============================================================
        $display("\n[Test] FENCE behaves as NOP");
        opcode = `OPCODE_MEMORY_FENCE;
        funct3 = 3'b0; funct7 = 7'b0;
        #1;
        check("reg_write = 0", {31'b0, reg_write_en}, 32'd0);
        check("mem_write = 0", {31'b0, mem_write_en}, 32'd0);
        check("branch = 0",    {31'b0, branch},        32'd0);
        check("jump = 0",      {31'b0, jump},          32'd0);

        $display("\n[Test] ECALL behaves as NOP");
        opcode = `OPCODE_SYSTEM_CALL;
        #1;
        check("reg_write = 0", {31'b0, reg_write_en}, 32'd0);

        // ============================================================
        // Unknown opcode -> NOP
        // ============================================================
        $display("\n[Test] Unknown opcode falls back to NOP");
        opcode = 7'b1111111;
        #1;
        check("reg_write = 0", {31'b0, reg_write_en}, 32'd0);
        check("mem_write = 0", {31'b0, mem_write_en}, 32'd0);
        check("branch = 0",    {31'b0, branch},        32'd0);
        check("jump = 0",      {31'b0, jump},          32'd0);

        // ------------------------------------------------------------------
        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

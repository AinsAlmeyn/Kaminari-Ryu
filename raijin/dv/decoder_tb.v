// ============================================================================
// decoder_tb.v: testbench for the RV32I instruction decoder
// ----------------------------------------------------------------------------
// Feeds known 32-bit instruction patterns into the decoder and checks every
// extracted field plus the sign-extended immediate.
// ============================================================================

`timescale 1ns / 1ps

module decoder_tb;

    reg  [31:0] instruction;
    wire [6:0]  opcode;
    wire [4:0]  rd;
    wire [4:0]  rs1;
    wire [4:0]  rs2;
    wire [2:0]  funct3;
    wire [6:0]  funct7;
    wire [31:0] imm;

    integer pass_count = 0;
    integer fail_count = 0;

    decoder dut (
        .instruction (instruction),
        .opcode      (opcode),
        .rd          (rd),
        .rs1         (rs1),
        .rs2         (rs2),
        .funct3      (funct3),
        .funct7      (funct7),
        .imm         (imm)
    );

    // ------------------------------------------------------------------
    // Generic check task. Compare an actual value to expected, print result
    // ------------------------------------------------------------------
    task check;
        input [255:0] label;
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                $display("    PASS : %0s   (got 0x%08h)", label, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("    FAIL : %0s   expected 0x%08h, got 0x%08h",
                         label, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("decoder_tb.vcd");
        $dumpvars(0, decoder_tb);

        $display("================================================");
        $display(" decoder_tb : RV32I decoder verification");
        $display("================================================");

        // ============================================================
        // R-type :  add x5, x6, x7
        //   funct7=0000000 rs2=00111 rs1=00110 funct3=000 rd=00101 op=0110011
        //   = 0x007302B3
        // ============================================================
        $display("\n[Test 1] R-type : add x5, x6, x7   (0x007302B3)");
        instruction = 32'h007302B3;
        #1;
        check("opcode", {25'b0, opcode}, 32'h0000_0033);  // 0110011
        check("rd",     {27'b0, rd},     32'd5);
        check("rs1",    {27'b0, rs1},    32'd6);
        check("rs2",    {27'b0, rs2},    32'd7);
        check("funct3", {29'b0, funct3}, 32'h0);
        check("funct7", {25'b0, funct7}, 32'h0);
        check("imm (R has none)", imm, 32'd0);

        // ============================================================
        // I-type :  addi x1, x2, -1
        //   imm=111111111111 (-1) rs1=00010 funct3=000 rd=00001 op=0010011
        //   = 0xFFF10093
        // ============================================================
        $display("\n[Test 2] I-type : addi x1, x2, -1   (0xFFF10093)");
        instruction = 32'hFFF10093;
        #1;
        check("opcode", {25'b0, opcode}, 32'h0000_0013);
        check("rd",     {27'b0, rd},     32'd1);
        check("rs1",    {27'b0, rs1},    32'd2);
        check("funct3", {29'b0, funct3}, 32'h0);
        check("imm (sign-extended -1)", imm, 32'hFFFF_FFFF);

        // ============================================================
        // I-type :  addi x5, x0, 100
        //   imm=000001100100 (100) rs1=00000 funct3=000 rd=00101 op=0010011
        //   = 0x06400293
        // ============================================================
        $display("\n[Test 3] I-type : addi x5, x0, 100   (0x06400293)");
        instruction = 32'h06400293;
        #1;
        check("rd",     {27'b0, rd},     32'd5);
        check("rs1",    {27'b0, rs1},    32'd0);
        check("imm (+100)", imm, 32'd100);

        // ============================================================
        // S-type :  sw x6, 8(x5)
        //   imm[11:5]=0000000 rs2=00110 rs1=00101 funct3=010 imm[4:0]=01000 op=0100011
        //   = 0x0062A423
        // ============================================================
        $display("\n[Test 4] S-type : sw x6, 8(x5)   (0x0062A423)");
        instruction = 32'h0062A423;
        #1;
        check("opcode", {25'b0, opcode}, 32'h0000_0023);
        check("rs1",    {27'b0, rs1},    32'd5);
        check("rs2",    {27'b0, rs2},    32'd6);
        check("funct3 (sw)", {29'b0, funct3}, 32'h2);
        check("imm (+8)", imm, 32'd8);

        // ============================================================
        // B-type :  beq x1, x2, +16
        //   imm[12]=0 imm[10:5]=000000 rs2=00010 rs1=00001
        //   funct3=000 imm[4:1]=1000 imm[11]=0 op=1100011
        //   offset = 16 byte = b0_0000_0001_0000 (13 bits)
        //   bits = 0 000000 00010 00001 000 1000 0 1100011
        //   = 0x00208863
        // ============================================================
        $display("\n[Test 5] B-type : beq x1, x2, +16   (0x00208863)");
        instruction = 32'h00208863;
        #1;
        check("opcode", {25'b0, opcode}, 32'h0000_0063);
        check("rs1",    {27'b0, rs1},    32'd1);
        check("rs2",    {27'b0, rs2},    32'd2);
        check("funct3 (beq)", {29'b0, funct3}, 32'h0);
        check("imm (+16)", imm, 32'd16);

        // ============================================================
        // B-type negative offset :  beq x0, x0, -4   (infinite loop)
        //   offset = -4 = 13-bit sign-extended 1_1111_1111_1100
        //   bits = 1 111111 00000 00000 000 1110 1 1100011
        //   = 0xFE000EE3
        // ============================================================
        $display("\n[Test 6] B-type : beq x0, x0, -4   (0xFE000EE3)");
        instruction = 32'hFE000EE3;
        #1;
        check("imm (-4)", imm, 32'hFFFF_FFFC);

        // ============================================================
        // U-type :  lui x5, 0x12345
        //   imm[31:12]=00010010001101000101 rd=00101 op=0110111
        //   = 0x123452B7
        // ============================================================
        $display("\n[Test 7] U-type : lui x5, 0x12345   (0x123452B7)");
        instruction = 32'h123452B7;
        #1;
        check("opcode", {25'b0, opcode}, 32'h0000_0037);
        check("rd",     {27'b0, rd},     32'd5);
        check("imm (0x12345 << 12)", imm, 32'h12345000);

        // ============================================================
        // J-type :  jal x1, +2048
        //   offset = 2048 = 0x800 = imm[11]=1, all other imm bits = 0
        //   inst[31]=0 inst[30:21]=0..0 inst[20]=1 inst[19:12]=0
        //   inst[11:7]=00001 (rd) inst[6:0]=1101111 (jal)
        //   = 0x001000EF
        // ============================================================
        $display("\n[Test 8] J-type : jal x1, +2048   (0x001000EF)");
        instruction = 32'h001000EF;
        #1;
        check("opcode", {25'b0, opcode}, 32'h0000_006F);
        check("rd",     {27'b0, rd},     32'd1);
        check("imm (+2048)", imm, 32'd2048);

        // ============================================================
        // R-type SUB :  sub x5, x6, x7   (funct7 differs from add)
        //   funct7=0100000 rs2=00111 rs1=00110 funct3=000 rd=00101 op=0110011
        //   = 0x407302B3
        // ============================================================
        $display("\n[Test 9] R-type : sub x5, x6, x7   (0x407302B3)");
        instruction = 32'h407302B3;
        #1;
        check("funct7 (alt)", {25'b0, funct7}, 32'h20);  // 0100000 = 0x20

        // ------------------------------------------------------------------
        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0) $display(" ALL TESTS PASSED");
        else                 $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

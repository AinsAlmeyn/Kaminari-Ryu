// ============================================================================
// raijin_defs.vh: Raijin-internal control encodings
// ----------------------------------------------------------------------------
// Constants we invented for our microarchitecture. These are NOT part of
// the RISC-V spec. They only exist inside our CPU. Things like ALU
// operation codes, control-unit selectors, format tags, etc. live here.
//
// Counterpart: riscv_defs.vh holds spec-mandated constants
// (opcodes, funct3/funct7) that we cannot change.
// ============================================================================

`ifndef RAIJIN_DEFS_VH
`define RAIJIN_DEFS_VH

// ============================================================
// ALU operation codes (4 bits - 10 distinct ops, room for growth)
// The control unit will translate (opcode, funct3, funct7) into one
// of these values and feed it to the ALU.
// ============================================================
`define ALU_OP_ADD   4'd0   // a + b
`define ALU_OP_SUB   4'd1   // a. B
`define ALU_OP_AND   4'd2   // a & b
`define ALU_OP_OR    4'd3   // a | b
`define ALU_OP_XOR   4'd4   // a ^ b
`define ALU_OP_SLL   4'd5   // a << b[4:0]                (shift left logical)
`define ALU_OP_SRL   4'd6   // a >> b[4:0]                (shift right logical)
`define ALU_OP_SRA   4'd7   // a >>> b[4:0]               (shift right arithmetic)
`define ALU_OP_SLT   4'd8   // signed:   a < b ? 1 : 0
`define ALU_OP_SLTU  4'd9   // unsigned: a < b ? 1 : 0

// ============================================================
// ALU operand-A source selector (2 bits)
// Picks what feeds the ALU's A input.
// ============================================================
`define ALU_SRC_A_REG    2'd0   // rs1_data        (most arithmetic, loads, stores, JALR)
`define ALU_SRC_A_PC     2'd1   // current PC      (AUIPC, JAL target, branch target)
`define ALU_SRC_A_ZERO   2'd2   // hardwired 0     (LUI: result = 0 + imm = imm)

// ============================================================
// ALU operand-B source selector (1 bit)
// Picks what feeds the ALU's B input.
// ============================================================
`define ALU_SRC_B_REG    1'd0   // rs2_data        (R-type)
`define ALU_SRC_B_IMM    1'd1   // sign-ext. imm   (everything else)

// ============================================================
// Writeback source selector (2 bits)
// Picks which value is written back into the register file.
// ============================================================
`define WB_SRC_ALU       2'd0   // ALU result      (most ops, LUI, AUIPC)
`define WB_SRC_MEM       2'd1   // data memory     (loads)
`define WB_SRC_PC4       2'd2   // PC + 4          (JAL, JALR return address)
`define WB_SRC_CSR       2'd3   // CSR old value   (Zicsr read side of CSRR*)

// ============================================================
// CSR operation code (2 bits). What to do with the new value
// when writing a CSR. The "write" side of every Zicsr instruction
// reduces to one of these three operations.
// ============================================================
`define CSR_OP_WRITE     2'd0   // csr = src                 (CSRRW, CSRRWI)
`define CSR_OP_SET       2'd1   // csr = csr | src           (CSRRS, CSRRSI)
`define CSR_OP_CLEAR     2'd2   // csr = csr & ~src          (CSRRC, CSRRCI)

// ============================================================
// CSR write-source selector (1 bit)
// ============================================================
`define CSR_SRC_REG      1'd0   // rs1 register value
`define CSR_SRC_IMM      1'd1   // 5-bit zimm from inst[19:15]

`endif  // RAIJIN_DEFS_VH

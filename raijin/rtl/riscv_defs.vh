// ============================================================================
// riscv_defs.vh: RV32I instruction encoding constants
// ----------------------------------------------------------------------------
// Raijin (雷神). First model of the Kaminari-Ryū CPU family.
// ISA: RV32I base integer, unprivileged spec.
//
// Every `define here comes directly from the official RISC-V spec:
//   "RISC-V Instruction Set Manual, Volume I: Unprivileged ISA"
//   Chapter 2 ("RV32I Base Integer Instruction Set")
// These values are NOT our choice. They are fixed by the spec so that
// GCC/LLVM-compiled binaries run on our core.
//
// Naming convention:
//   - Long descriptive name on the left (self-documenting).
//   - The short official RISC-V mnemonic on the right, as a comment.
// ============================================================================

`ifndef RISCV_DEFS_VH
`define RISCV_DEFS_VH

// ============================================================
// OPCODES. Bits [6:0] of every 32-bit instruction.
// The decoder looks at these 7 bits first to figure out which
// "family" of instruction we are dealing with.
// ============================================================
`define OPCODE_LOAD_UPPER_IMM         7'b0110111  // LUI  : U-type
`define OPCODE_ADD_UPPER_IMM_TO_PC    7'b0010111  // AUIPC: U-type
`define OPCODE_JUMP_AND_LINK          7'b1101111  // JAL  : J-type
`define OPCODE_JUMP_AND_LINK_REG      7'b1100111  // JALR : I-type
`define OPCODE_BRANCH                 7'b1100011  // BEQ/BNE/BLT/BGE/BLTU/BGEU
`define OPCODE_LOAD                   7'b0000011  // LB/LH/LW/LBU/LHU
`define OPCODE_STORE                  7'b0100011  // SB/SH/SW
`define OPCODE_ARITH_IMMEDIATE        7'b0010011  // ADDI/XORI/ORI/ANDI/SLTI/SLTIU/shifts-imm
`define OPCODE_ARITH_REGISTER         7'b0110011  // ADD/SUB/AND/OR/XOR/SLT/SLTU/shifts
`define OPCODE_MEMORY_FENCE           7'b0001111  // FENCE
`define OPCODE_SYSTEM_CALL            7'b1110011  // ECALL/EBREAK

// ============================================================
// FUNCT3 for BRANCH  (opcode = OPCODE_BRANCH)
// ============================================================
`define FUNCT3_BRANCH_EQUAL                        3'b000  // BEQ
`define FUNCT3_BRANCH_NOT_EQUAL                    3'b001  // BNE
`define FUNCT3_BRANCH_LESS_THAN_SIGNED             3'b100  // BLT
`define FUNCT3_BRANCH_GREATER_OR_EQUAL_SIGNED      3'b101  // BGE
`define FUNCT3_BRANCH_LESS_THAN_UNSIGNED           3'b110  // BLTU
`define FUNCT3_BRANCH_GREATER_OR_EQUAL_UNSIGNED    3'b111  // BGEU

// ============================================================
// FUNCT3 for LOAD  (opcode = OPCODE_LOAD)
// Byte = 8 bit, Halfword = 16 bit, Word = 32 bit.
// "Unsigned" variants zero-extend into the 32-bit register;
// the signed ones sign-extend.
// ============================================================
`define FUNCT3_LOAD_BYTE_SIGNED        3'b000  // LB
`define FUNCT3_LOAD_HALFWORD_SIGNED    3'b001  // LH
`define FUNCT3_LOAD_WORD               3'b010  // LW
`define FUNCT3_LOAD_BYTE_UNSIGNED      3'b100  // LBU
`define FUNCT3_LOAD_HALFWORD_UNSIGNED  3'b101  // LHU

// ============================================================
// FUNCT3 for STORE  (opcode = OPCODE_STORE)
// ============================================================
`define FUNCT3_STORE_BYTE      3'b000  // SB
`define FUNCT3_STORE_HALFWORD  3'b001  // SH
`define FUNCT3_STORE_WORD      3'b010  // SW

// ============================================================
// FUNCT3 for ARITH-IMMEDIATE  (opcode = OPCODE_ARITH_IMMEDIATE)
// These are "register OP immediate → register" operations:
//   rd = rs1 OP imm
// ============================================================
`define FUNCT3_ADD_IMM                     3'b000  // ADDI
`define FUNCT3_SET_LESS_THAN_IMM_SIGNED    3'b010  // SLTI
`define FUNCT3_SET_LESS_THAN_IMM_UNSIGNED  3'b011  // SLTIU
`define FUNCT3_XOR_IMM                     3'b100  // XORI
`define FUNCT3_OR_IMM                      3'b110  // ORI
`define FUNCT3_AND_IMM                     3'b111  // ANDI
`define FUNCT3_SHIFT_LEFT_LOGICAL_IMM      3'b001  // SLLI
`define FUNCT3_SHIFT_RIGHT_IMM             3'b101  // SRLI and SRAI share this; funct7 disambiguates

// ============================================================
// FUNCT3 for ARITH-REGISTER  (opcode = OPCODE_ARITH_REGISTER)
// Register-register R-type: rd = rs1 OP rs2
// Note the shared funct3 codes. Funct7 picks between pairs:
//   ADD vs SUB           (funct3 = 000)
//   SRL vs SRA (shifts)  (funct3 = 101)
// ============================================================
`define FUNCT3_ADD_OR_SUB               3'b000  // ADD / SUB
`define FUNCT3_SHIFT_LEFT_LOGICAL       3'b001  // SLL
`define FUNCT3_SET_LESS_THAN_SIGNED     3'b010  // SLT
`define FUNCT3_SET_LESS_THAN_UNSIGNED   3'b011  // SLTU
`define FUNCT3_XOR                      3'b100  // XOR
`define FUNCT3_SHIFT_RIGHT              3'b101  // SRL / SRA
`define FUNCT3_OR                       3'b110  // OR
`define FUNCT3_AND                      3'b111  // AND

// ============================================================
// FUNCT7. Three distinct values appear in RV32I + RV32M.
// The meaningful bit-30 of the instruction:
//   0 → "normal" operation  (ADD, SRL, SRLI)
//   1 → "alternate" variant (SUB, SRA, SRAI)
// And bit-25 = 1 with bit-30 = 0 marks the M extension family.
// ============================================================
`define FUNCT7_DEFAULT             7'b0000000  // ADD, SRL, SRLI, and most R-type ops
`define FUNCT7_SUBTRACT_OR_SHIFT_ARITHMETIC  7'b0100000  // SUB, SRA, SRAI
`define FUNCT7_M_EXTENSION         7'b0000001  // MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU

// ============================================================
// FUNCT3 for the M extension (opcode = OPCODE_ARITH_REGISTER,
// funct7 = FUNCT7_M_EXTENSION). Same R-type encoding as ADD/SUB
// etc., disambiguated by funct7.
// ============================================================
`define FUNCT3_MUL              3'b000   // MUL    : low  32 bits of (signed   x signed)
`define FUNCT3_MULH             3'b001   // MULH   : high 32 bits of (signed   x signed)
`define FUNCT3_MULHSU           3'b010   // MULHSU : high 32 bits of (signed   x unsigned)
`define FUNCT3_MULHU            3'b011   // MULHU  : high 32 bits of (unsigned x unsigned)
`define FUNCT3_DIV              3'b100   // DIV    : signed   division
`define FUNCT3_DIVU             3'b101   // DIVU   : unsigned division
`define FUNCT3_REM              3'b110   // REM    : signed   remainder
`define FUNCT3_REMU             3'b111   // REMU   : unsigned remainder

// ============================================================
// FUNCT3 for SYSTEM opcode (= OPCODE_SYSTEM_CALL)
// funct3 = 000 is the "privileged/environment" family:
//   ECALL, EBREAK, MRET, WFI, SFENCE. Distinguished by inst[31:20].
// funct3 != 000 is the Zicsr family: CSRRW, CSRRS, CSRRC, and their
//   immediate variants. The CSR address lives in inst[31:20].
// ============================================================
`define FUNCT3_SYSTEM_PRIV      3'b000   // ECALL/EBREAK/MRET/...
`define FUNCT3_CSRRW            3'b001   // atomic read-and-write
`define FUNCT3_CSRRS            3'b010   // atomic read-and-set  (OR)
`define FUNCT3_CSRRC            3'b011   // atomic read-and-clear (AND ~)
`define FUNCT3_CSRRWI           3'b101   // immediate variants. Rs1 field
`define FUNCT3_CSRRSI           3'b110   // is a 5-bit zero-extended imm
`define FUNCT3_CSRRCI           3'b111   //

// Instruction-word constants for privileged SYSTEM ops.
// The full 32-bit encoding matters because they share opcode+funct3=000.
`define INSTR_ECALL             32'h00000073
`define INSTR_EBREAK            32'h00100073
`define INSTR_MRET              32'h30200073   // funct7=0011000, rs2=00010

// ============================================================
// CSR addresses (M-mode subset, RISC-V Privileged spec)
// Full 12-bit address lives in inst[31:20] of every Zicsr instruction.
// ============================================================
`define CSR_MSTATUS    12'h300
`define CSR_MISA       12'h301
`define CSR_MIE        12'h304
`define CSR_MTVEC      12'h305
`define CSR_MSCRATCH   12'h340
`define CSR_MEPC       12'h341
`define CSR_MCAUSE     12'h342
`define CSR_MTVAL      12'h343
`define CSR_MIP        12'h344
`define CSR_MVENDORID  12'hF11
`define CSR_MARCHID    12'hF12
`define CSR_MIMPID     12'hF13
`define CSR_MHARTID    12'hF14

// ============================================================
// Hardware performance counters (read-only in Raijin). RV32
// splits each 64-bit counter into low and high halves.
// Raijin wires four of them to the on-chip instruction-class
// counters (see raijin_core.v):
//   hpmcounter3  -> branch-taken events
//   hpmcounter4  -> load  events
//   hpmcounter5  -> store events
//   hpmcounter6  -> mul/div events
// ============================================================
`define CSR_MHPMCOUNTER3   12'hB03
`define CSR_MHPMCOUNTER4   12'hB04
`define CSR_MHPMCOUNTER5   12'hB05
`define CSR_MHPMCOUNTER6   12'hB06
`define CSR_MHPMCOUNTER3H  12'hB83
`define CSR_MHPMCOUNTER4H  12'hB84
`define CSR_MHPMCOUNTER5H  12'hB85
`define CSR_MHPMCOUNTER6H  12'hB86

// Performance counters. Single-cycle core, so minstret tracks cycles 1:1
// (subtract traps if exact retirement count matters). User-mode aliases
// cycle/time/instret read the same backing flops (RO).
`define CSR_MCYCLE     12'hB00
`define CSR_MCYCLEH    12'hB80
`define CSR_MINSTRET   12'hB02
`define CSR_MINSTRETH  12'hB82
`define CSR_CYCLE      12'hC00
`define CSR_CYCLEH     12'hC80
`define CSR_TIME       12'hC01
`define CSR_TIMEH      12'hC81
`define CSR_INSTRET    12'hC02
`define CSR_INSTRETH   12'hC82

// ============================================================
// Exception cause codes (written into mcause on a synchronous trap).
// See Privileged spec Table 3.6.
// ============================================================
`define MCAUSE_INSTR_MISALIGNED   32'd0
`define MCAUSE_ILLEGAL_INSTR      32'd2
`define MCAUSE_BREAKPOINT         32'd3
`define MCAUSE_LOAD_MISALIGNED    32'd4
`define MCAUSE_STORE_MISALIGNED   32'd6
`define MCAUSE_ECALL_FROM_M       32'd11

// Asynchronous interrupt causes have bit 31 set. Raijin implements
// the two machine-mode lines you would find on any minimal RV32
// embedded core: machine-software (MSIP, bit 3 of mie/mip) and
// machine-timer (MTIP, bit 7).
`define MCAUSE_M_SOFT_INTERRUPT   32'h8000_0003
`define MCAUSE_M_TIMER_INTERRUPT  32'h8000_0007

// WFI (wait-for-interrupt) has the same opcode/funct3 as the
// other privileged SYSTEM ops; inst[31:20] discriminates.
// Full encoding: funct7=0001000, rs2=00101, rs1=00000,
// funct3=000, rd=00000, opcode=1110011 -> 0x10500073.
// inst[31:20] == 12'h105.
`define INSTR_WFI                32'h10500073
`define PRIV_FIELD_WFI           12'h105

// ============================================================
// Register ABI aliases. Just convenience names for register numbers.
// The hardware does not care; these help humans read assembly.
// (RV32I has 32 general-purpose registers: x0 .. x31)
// ============================================================
`define REG_ZERO              5'd0   // x0 : hardwired to zero
`define REG_RETURN_ADDRESS    5'd1   // x1 : ra
`define REG_STACK_POINTER     5'd2   // x2 : sp
`define REG_GLOBAL_POINTER    5'd3   // x3 : gp
`define REG_THREAD_POINTER    5'd4   // x4 : tp

`endif  // RISCV_DEFS_VH

// ============================================================================
// control.v: Raijin main control unit (single-cycle RV32I)
// ----------------------------------------------------------------------------
// Pure combinational. Takes the three "type" fields from the decoder
// (opcode, funct3, funct7) and produces every control signal the datapath
// needs for one clock cycle.
//
// Internally we follow the classic "two-level decode" pattern from
// Patterson & Hennessy:
//
//   Block 1: MAIN DECODER : opcode -> all the binary control flags
//                            (reg_write_en, mem_*_en, alu_src_*_sel,
//                             wb_src_sel, branch, jump)
//   Block 2: ALU DECODER  : opcode + funct3 + funct7 -> 4-bit alu_op
//
// Keeping them in two separate `always @(*)` blocks makes it easy to
// extend later (e.g. adding the M extension only touches block 2).
//
// This module makes NO architectural decisions on its own. Every
// behavior here is dictated by the RV32I spec.
// ============================================================================

`include "riscv_defs.vh"
`include "raijin_defs.vh"

module control (
    input  wire [6:0] opcode,
    input  wire [2:0] funct3,
    input  wire [6:0] funct7,

    // ---- Datapath enables ----------------------------------------------
    output reg        reg_write_en,    // write rd back to the regfile?
    output reg        mem_read_en,     // read from data memory?
    output reg        mem_write_en,    // write to data memory?

    // ---- Datapath multiplexer selectors --------------------------------
    output reg [1:0]  alu_src_a_sel,   // see ALU_SRC_A_* in raijin_defs.vh
    output reg        alu_src_b_sel,   // see ALU_SRC_B_*
    output reg [1:0]  wb_src_sel,      // see WB_SRC_*

    // ---- ALU operation -------------------------------------------------
    output reg [3:0]  alu_op,          // see ALU_OP_* in raijin_defs.vh

    // ---- Control-flow flags --------------------------------------------
    output reg        branch,          // BEQ/BNE/BLT/BGE/BLTU/BGEU
    output reg        jump,            // JAL/JALR (always taken)

    // ---- Zicsr + trap control ------------------------------------------
    // Raised for CSRRW / CSRRS / CSRRC and their immediate variants.
    output reg        csr_access_en,
    output reg [1:0]  csr_op,          // CSR_OP_WRITE / _SET / _CLEAR
    output reg        csr_src_sel,     // CSR_SRC_REG / _IMM (zimm)

    // Raised for the privileged forms of SYSTEM (funct3 = 000). The core
    // disambiguates ECALL / EBREAK / MRET by looking at inst[31:20]
    // directly, so we only expose a single "is this a priv op" signal.
    output reg        is_system_priv,

    // Raised for any RV32M instruction (R-type with funct7 = 7'b0000001).
    // The core uses this to route m_unit's result into the writeback mux,
    // bypassing the ALU. wb_src_sel is left at WB_SRC_ALU since we override
    // at the top level.
    output reg        is_m_op
);

    // ====================================================================
    // BLOCK 1: MAIN DECODER
    // For every opcode we decide the binary flags + the mux selectors.
    // The ALU operation is filled in by Block 2 below; here we only set
    // a sensible default (ADD), since most non-arith opcodes need ADD
    // anyway (effective-address calc, PC+imm, LUI = 0+imm, etc.).
    // ====================================================================
    always @(*) begin
        // Safe defaults. Chosen so an unknown opcode behaves like a NOP.
        reg_write_en   = 1'b0;
        mem_read_en    = 1'b0;
        mem_write_en   = 1'b0;
        alu_src_a_sel  = `ALU_SRC_A_REG;
        alu_src_b_sel  = `ALU_SRC_B_REG;
        wb_src_sel     = `WB_SRC_ALU;
        branch         = 1'b0;
        jump           = 1'b0;
        csr_access_en  = 1'b0;
        csr_op         = `CSR_OP_WRITE;
        csr_src_sel    = `CSR_SRC_REG;
        is_system_priv = 1'b0;
        is_m_op        = 1'b0;

        case (opcode)
            // ----------------------------------------------------------------
            // R-type :  rd = rs1 OP rs2
            // funct7 == 7'b0000001 selects the M extension (mul/div family).
            // We still drive reg_write_en = 1 and let the top-level swap in
            // m_unit's result over the ALU's result via the is_m_op signal.
            // ----------------------------------------------------------------
            `OPCODE_ARITH_REGISTER : begin
                reg_write_en  = 1'b1;
                alu_src_a_sel = `ALU_SRC_A_REG;
                alu_src_b_sel = `ALU_SRC_B_REG;
                wb_src_sel    = `WB_SRC_ALU;
                if (funct7 == `FUNCT7_M_EXTENSION)
                    is_m_op   = 1'b1;
            end

            // ----------------------------------------------------------------
            // I-type arithmetic :  rd = rs1 OP imm
            // ----------------------------------------------------------------
            `OPCODE_ARITH_IMMEDIATE : begin
                reg_write_en  = 1'b1;
                alu_src_a_sel = `ALU_SRC_A_REG;
                alu_src_b_sel = `ALU_SRC_B_IMM;
                wb_src_sel    = `WB_SRC_ALU;
            end

            // ----------------------------------------------------------------
            // I-type load :  rd = MEM[rs1 + imm]
            // ALU computes the effective address (ADD); writeback comes
            // from memory.
            // ----------------------------------------------------------------
            `OPCODE_LOAD : begin
                reg_write_en  = 1'b1;
                mem_read_en   = 1'b1;
                alu_src_a_sel = `ALU_SRC_A_REG;
                alu_src_b_sel = `ALU_SRC_B_IMM;
                wb_src_sel    = `WB_SRC_MEM;
            end

            // ----------------------------------------------------------------
            // S-type store :  MEM[rs1 + imm] = rs2
            // ALU computes the address; rs2 goes to data memory.
            // No register writeback.
            // ----------------------------------------------------------------
            `OPCODE_STORE : begin
                reg_write_en  = 1'b0;
                mem_write_en  = 1'b1;
                alu_src_a_sel = `ALU_SRC_A_REG;
                alu_src_b_sel = `ALU_SRC_B_IMM;
            end

            // ----------------------------------------------------------------
            // B-type branch :  if (rs1 OP rs2) PC = PC + imm
            // ALU computes the branch TARGET (PC + imm). The actual
            // taken/not-taken decision comes from a separate branch_unit.
            // No register writeback.
            // ----------------------------------------------------------------
            `OPCODE_BRANCH : begin
                reg_write_en  = 1'b0;
                alu_src_a_sel = `ALU_SRC_A_PC;
                alu_src_b_sel = `ALU_SRC_B_IMM;
                branch        = 1'b1;
            end

            // ----------------------------------------------------------------
            // U-type LUI :  rd = imm << 12  (= 0 + imm_u)
            // We force ALU A to zero and feed imm through B.
            // ----------------------------------------------------------------
            `OPCODE_LOAD_UPPER_IMM : begin
                reg_write_en  = 1'b1;
                alu_src_a_sel = `ALU_SRC_A_ZERO;
                alu_src_b_sel = `ALU_SRC_B_IMM;
                wb_src_sel    = `WB_SRC_ALU;
            end

            // ----------------------------------------------------------------
            // U-type AUIPC :  rd = PC + (imm << 12)
            // ----------------------------------------------------------------
            `OPCODE_ADD_UPPER_IMM_TO_PC : begin
                reg_write_en  = 1'b1;
                alu_src_a_sel = `ALU_SRC_A_PC;
                alu_src_b_sel = `ALU_SRC_B_IMM;
                wb_src_sel    = `WB_SRC_ALU;
            end

            // ----------------------------------------------------------------
            // J-type JAL :  rd = PC + 4 ; PC = PC + imm
            // ALU computes the jump target (PC + imm); writeback is PC+4.
            // ----------------------------------------------------------------
            `OPCODE_JUMP_AND_LINK : begin
                reg_write_en  = 1'b1;
                alu_src_a_sel = `ALU_SRC_A_PC;
                alu_src_b_sel = `ALU_SRC_B_IMM;
                wb_src_sel    = `WB_SRC_PC4;
                jump          = 1'b1;
            end

            // ----------------------------------------------------------------
            // I-type JALR :  rd = PC + 4 ; PC = (rs1 + imm) & ~1
            // ----------------------------------------------------------------
            `OPCODE_JUMP_AND_LINK_REG : begin
                reg_write_en  = 1'b1;
                alu_src_a_sel = `ALU_SRC_A_REG;
                alu_src_b_sel = `ALU_SRC_B_IMM;
                wb_src_sel    = `WB_SRC_PC4;
                jump          = 1'b1;
            end

            // ----------------------------------------------------------------
            // FENCE : behaves as NOP in this minimal core (no memory
            // ordering needed for a single-core in-order pipeline).
            // ----------------------------------------------------------------
            `OPCODE_MEMORY_FENCE : begin
                // all defaults - NOP
            end

            // ----------------------------------------------------------------
            // SYSTEM opcode fans out to two distinct behaviors:
            //   funct3 == 000 -> ECALL / EBREAK / MRET  (is_system_priv)
            //   funct3 != 000 -> Zicsr  (CSRRW / CSRRS / CSRRC and their
            //                            immediate variants)
            // For Zicsr we must write `rd` with the OLD csr value, so
            // reg_write_en = 1 (the regfile already drops writes to x0).
            // ----------------------------------------------------------------
            `OPCODE_SYSTEM_CALL : begin
                case (funct3)
                    `FUNCT3_SYSTEM_PRIV : begin
                        is_system_priv = 1'b1;     // ECALL/EBREAK/MRET
                    end

                    `FUNCT3_CSRRW : begin
                        csr_access_en = 1'b1;
                        csr_op        = `CSR_OP_WRITE;
                        csr_src_sel   = `CSR_SRC_REG;
                        reg_write_en  = 1'b1;
                        wb_src_sel    = `WB_SRC_CSR;
                    end
                    `FUNCT3_CSRRS : begin
                        csr_access_en = 1'b1;
                        csr_op        = `CSR_OP_SET;
                        csr_src_sel   = `CSR_SRC_REG;
                        reg_write_en  = 1'b1;
                        wb_src_sel    = `WB_SRC_CSR;
                    end
                    `FUNCT3_CSRRC : begin
                        csr_access_en = 1'b1;
                        csr_op        = `CSR_OP_CLEAR;
                        csr_src_sel   = `CSR_SRC_REG;
                        reg_write_en  = 1'b1;
                        wb_src_sel    = `WB_SRC_CSR;
                    end
                    `FUNCT3_CSRRWI : begin
                        csr_access_en = 1'b1;
                        csr_op        = `CSR_OP_WRITE;
                        csr_src_sel   = `CSR_SRC_IMM;
                        reg_write_en  = 1'b1;
                        wb_src_sel    = `WB_SRC_CSR;
                    end
                    `FUNCT3_CSRRSI : begin
                        csr_access_en = 1'b1;
                        csr_op        = `CSR_OP_SET;
                        csr_src_sel   = `CSR_SRC_IMM;
                        reg_write_en  = 1'b1;
                        wb_src_sel    = `WB_SRC_CSR;
                    end
                    `FUNCT3_CSRRCI : begin
                        csr_access_en = 1'b1;
                        csr_op        = `CSR_OP_CLEAR;
                        csr_src_sel   = `CSR_SRC_IMM;
                        reg_write_en  = 1'b1;
                        wb_src_sel    = `WB_SRC_CSR;
                    end
                    default : begin
                        // unrecognized funct3 under SYSTEM -> NOP defaults
                    end
                endcase
            end

            default : begin
                // unknown opcode -> NOP (defaults already set above)
            end
        endcase
    end

    // ====================================================================
    // BLOCK 2: ALU DECODER
    // Picks the 4-bit ALU operation. For most opcodes ADD is the right
    // choice (address calculation, PC+imm, LUI, etc.). The interesting
    // cases are the two arithmetic opcode families:
    //   OPCODE_ARITH_REGISTER  : funct3 + funct7 fully determine the op
    //   OPCODE_ARITH_IMMEDIATE : funct3 alone for most, funct7 only for shifts
    // ====================================================================
    always @(*) begin
        alu_op = `ALU_OP_ADD;   // default. Works for loads/stores/jumps/LUI/etc.

        case (opcode)
            // ----------------------------------------------------------------
            // R-type. Pick ADD/SUB/AND/OR/XOR/SLL/SRL/SRA/SLT/SLTU
            // ----------------------------------------------------------------
            `OPCODE_ARITH_REGISTER : begin
                case (funct3)
                    `FUNCT3_ADD_OR_SUB :
                        alu_op = (funct7 == `FUNCT7_SUBTRACT_OR_SHIFT_ARITHMETIC)
                                 ? `ALU_OP_SUB : `ALU_OP_ADD;
                    `FUNCT3_SHIFT_LEFT_LOGICAL    : alu_op = `ALU_OP_SLL;
                    `FUNCT3_SET_LESS_THAN_SIGNED  : alu_op = `ALU_OP_SLT;
                    `FUNCT3_SET_LESS_THAN_UNSIGNED: alu_op = `ALU_OP_SLTU;
                    `FUNCT3_XOR                   : alu_op = `ALU_OP_XOR;
                    `FUNCT3_SHIFT_RIGHT :
                        alu_op = (funct7 == `FUNCT7_SUBTRACT_OR_SHIFT_ARITHMETIC)
                                 ? `ALU_OP_SRA : `ALU_OP_SRL;
                    `FUNCT3_OR                    : alu_op = `ALU_OP_OR;
                    `FUNCT3_AND                   : alu_op = `ALU_OP_AND;
                    default                       : alu_op = `ALU_OP_ADD;
                endcase
            end

            // ----------------------------------------------------------------
            // I-type arithmetic. Same funct3 set as R-type, except SUB
            // does not exist in immediate form; funct7 only matters for
            // the shift-immediate distinguishing SRLI vs SRAI.
            // ----------------------------------------------------------------
            `OPCODE_ARITH_IMMEDIATE : begin
                case (funct3)
                    `FUNCT3_ADD_IMM                    : alu_op = `ALU_OP_ADD;
                    `FUNCT3_SET_LESS_THAN_IMM_SIGNED   : alu_op = `ALU_OP_SLT;
                    `FUNCT3_SET_LESS_THAN_IMM_UNSIGNED : alu_op = `ALU_OP_SLTU;
                    `FUNCT3_XOR_IMM                    : alu_op = `ALU_OP_XOR;
                    `FUNCT3_OR_IMM                     : alu_op = `ALU_OP_OR;
                    `FUNCT3_AND_IMM                    : alu_op = `ALU_OP_AND;
                    `FUNCT3_SHIFT_LEFT_LOGICAL_IMM     : alu_op = `ALU_OP_SLL;
                    `FUNCT3_SHIFT_RIGHT_IMM :
                        alu_op = (funct7 == `FUNCT7_SUBTRACT_OR_SHIFT_ARITHMETIC)
                                 ? `ALU_OP_SRA : `ALU_OP_SRL;
                    default                            : alu_op = `ALU_OP_ADD;
                endcase
            end

            // ----------------------------------------------------------------
            // Everything else uses ADD (effective addresses, PC+imm,
            // LUI = 0+imm, AUIPC = PC+imm, branch target, JAL/JALR target).
            // ----------------------------------------------------------------
            default : alu_op = `ALU_OP_ADD;
        endcase
    end

endmodule

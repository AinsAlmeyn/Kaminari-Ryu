// ============================================================================
// decoder.v: RV32I instruction decoder
// ----------------------------------------------------------------------------
// Pure combinational module. Takes a raw 32-bit instruction word and pulls
// out the structured fields:
//  . Opcode, rs1, rs2, rd, funct3, funct7  (always at the same bit
//     positions across all formats. Extracted unconditionally)
//  . Imm (sign-extended 32-bit immediate, constructed per format)
//
// This module makes NO execution decisions. It does not say "write the
// register file" or "do an addition". A separate control unit will do that
// using the fields we expose here.
// ============================================================================

`include "riscv_defs.vh"

module decoder (
    input  wire [31:0] instruction,

    // Common fields. Present at the same bit positions in every format.
    // Some of them are meaningless for certain opcodes (e.g. rs2 in a U-type
    // instruction); the consumer is responsible for ignoring them.
    output wire [6:0]  opcode,
    output wire [4:0]  rd,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [2:0]  funct3,
    output wire [6:0]  funct7,

    // Sign-extended 32-bit immediate. Construction depends on the format,
    // which we infer from the opcode below.
    output wire [31:0] imm,

    // ---- Zicsr helpers (valid only when opcode == OPCODE_SYSTEM_CALL) --
    // csr_addr lives in inst[31:20] for every CSRR* instruction.
    // zimm    is the 5-bit field at inst[19:15], zero-extended to 32 bit,
    //         used by CSRRWI/CSRRSI/CSRRCI.
    output wire [11:0] csr_addr,
    output wire [31:0] zimm
);

    // ----------------------------------------------------------------
    // Step 1 : pull out the always-same fields
    // ----------------------------------------------------------------
    assign opcode = instruction[6:0];
    assign rd     = instruction[11:7];
    assign funct3 = instruction[14:12];
    assign rs1    = instruction[19:15];
    assign rs2    = instruction[24:20];
    assign funct7 = instruction[31:25];

    // ----------------------------------------------------------------
    // Step 2 : construct the immediate, format by format
    // ----------------------------------------------------------------
    // We compute each candidate immediate in parallel, then pick the
    // right one with a mux based on the opcode. The synthesizer turns
    // this into a small mux network. Fast and area-efficient.
    // ----------------------------------------------------------------

    wire [31:0] imm_i = {{21{instruction[31]}}, instruction[30:20]};

    wire [31:0] imm_s = {{21{instruction[31]}}, instruction[30:25],
                         instruction[11:7]};

    wire [31:0] imm_b = {{20{instruction[31]}}, instruction[7],
                         instruction[30:25], instruction[11:8], 1'b0};

    wire [31:0] imm_u = {instruction[31:12], 12'b0};

    wire [31:0] imm_j = {{12{instruction[31]}}, instruction[19:12],
                         instruction[20], instruction[30:21], 1'b0};

    // Pick the right immediate based on which opcode family we are in.
    // R-type (and a few others without an immediate) get zero. The
    // consumer should not use it anyway.
    reg [31:0] imm_selected;
    always @(*) begin
        case (opcode)
            `OPCODE_LOAD,
            `OPCODE_ARITH_IMMEDIATE,
            `OPCODE_JUMP_AND_LINK_REG : imm_selected = imm_i;

            `OPCODE_STORE             : imm_selected = imm_s;

            `OPCODE_BRANCH            : imm_selected = imm_b;

            `OPCODE_LOAD_UPPER_IMM,
            `OPCODE_ADD_UPPER_IMM_TO_PC : imm_selected = imm_u;

            `OPCODE_JUMP_AND_LINK     : imm_selected = imm_j;

            default                   : imm_selected = 32'b0;
        endcase
    end

    assign imm = imm_selected;

    // ----------------------------------------------------------------
    // Zicsr helper outputs. Just extra views of the instruction word.
    // Always valid; upstream only uses them when the opcode is SYSTEM.
    // ----------------------------------------------------------------
    assign csr_addr = instruction[31:20];
    assign zimm     = {27'b0, instruction[19:15]};

endmodule

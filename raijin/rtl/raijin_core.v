// ============================================================================
// raijin_core.v: top-level single-cycle RV32I + Zicsr CPU
// ----------------------------------------------------------------------------
// Extensions over the pure-RV32I version:
//
//   * CSR file (csr_file.v)          - M-mode CSRs + trap / MRET bookkeeping
//   * Zicsr instructions             - CSRRW/S/C and immediate variants
//   * Synchronous exception path     - ECALL, EBREAK, illegal SYSTEM
//   * MRET control-flow             . Returns to mepc, restores MIE
//
// Trap / MRET PC-mux priority (highest first):
//      trap_en  -> mtvec_out
//      mret_en  -> mepc_out
//      is_jalr  -> (rs1 + imm) & ~1
//      is_jal
//        or taken branch            -> alu_result
//      default                      -> pc + 4
//
// Side-effect gating: while trapping, reg_write_en and mem_write_en are
// squashed so the faulting instruction does not commit partial state.
// ============================================================================

`include "riscv_defs.vh"
`include "raijin_defs.vh"

module raijin_core #(
    parameter integer IMEM_DEPTH_WORDS = 1024,
    parameter         IMEM_INIT_FILE   = "",
    parameter integer DMEM_DEPTH_WORDS = 1024,
    parameter         DMEM_INIT_FILE   = ""
) (
    input  wire clk,
    input  wire reset
);

    // ====================================================================
    // PC stage
    // ====================================================================
    wire [31:0] pc;
    reg  [31:0] next_pc;

    pc_reg pc_inst (
        .clk     (clk),
        .reset   (reset),
        .next_pc (next_pc),
        .pc      (pc)
    );

    // ====================================================================
    // Instruction fetch
    // ====================================================================
    wire [31:0] instruction;

    imem #(
        .DEPTH_WORDS (IMEM_DEPTH_WORDS),
        .INIT_FILE   (IMEM_INIT_FILE)
    ) imem_inst (
        .addr        (pc),
        .instruction (instruction)
    );

    // ====================================================================
    // Decode
    // ====================================================================
    wire [6:0]  opcode;
    wire [4:0]  rd, rs1, rs2;
    wire [2:0]  funct3;
    wire [6:0]  funct7;
    wire [31:0] imm;
    wire [11:0] csr_addr;
    wire [31:0] zimm;

    decoder decoder_inst (
        .instruction (instruction),
        .opcode      (opcode),
        .rd          (rd),
        .rs1         (rs1),
        .rs2         (rs2),
        .funct3      (funct3),
        .funct7      (funct7),
        .imm         (imm),
        .csr_addr    (csr_addr),
        .zimm        (zimm)
    );

    // ====================================================================
    // Control signals
    // ====================================================================
    wire       reg_write_en_raw;
    wire       mem_read_en;
    wire       mem_write_en_raw;
    wire [1:0] alu_src_a_sel;
    wire       alu_src_b_sel;
    wire [1:0] wb_src_sel;
    wire [3:0] alu_op;
    wire       branch;
    wire       jump;
    wire       csr_access_en;
    wire [1:0] csr_op;
    wire       csr_src_sel;
    wire       is_system_priv;

    control control_inst (
        .opcode         (opcode),
        .funct3         (funct3),
        .funct7         (funct7),
        .reg_write_en   (reg_write_en_raw),
        .mem_read_en    (mem_read_en),
        .mem_write_en   (mem_write_en_raw),
        .alu_src_a_sel  (alu_src_a_sel),
        .alu_src_b_sel  (alu_src_b_sel),
        .wb_src_sel     (wb_src_sel),
        .alu_op         (alu_op),
        .branch         (branch),
        .jump           (jump),
        .csr_access_en  (csr_access_en),
        .csr_op         (csr_op),
        .csr_src_sel    (csr_src_sel),
        .is_system_priv (is_system_priv)
    );

    // ====================================================================
    // SYSTEM disambiguation. Decide which privileged op this is.
    // inst[31:20] == csr_addr already carries the discriminator.
    // ====================================================================
    wire is_ecall        = is_system_priv && (csr_addr == 12'h000);
    wire is_ebreak       = is_system_priv && (csr_addr == 12'h001);
    wire is_mret         = is_system_priv && (csr_addr == 12'h302);
    wire is_illegal_priv = is_system_priv && !(is_ecall || is_ebreak || is_mret);

    // ====================================================================
    // Trap detection + signal generation
    // ====================================================================
    wire trap_en = is_ecall | is_ebreak | is_illegal_priv;

    reg [31:0] trap_cause;
    always @(*) begin
        if      (is_ecall)  trap_cause = `MCAUSE_ECALL_FROM_M;
        else if (is_ebreak) trap_cause = `MCAUSE_BREAKPOINT;
        else                trap_cause = `MCAUSE_ILLEGAL_INSTR;
    end

    wire [31:0] trap_pc   = pc;
    wire [31:0] trap_tval = 32'b0;       // minimal: no instr/address capture

    // ====================================================================
    // Register file
    // ====================================================================
    wire [31:0] rs1_data, rs2_data;
    reg  [31:0] wb_data;

    // Mask register writes during a trap so the faulting instruction
    // does not commit.
    wire reg_write_en = reg_write_en_raw & ~trap_en;

    regfile regfile_inst (
        .clk          (clk),
        .write_enable (reg_write_en),
        .read_addr1   (rs1),
        .read_addr2   (rs2),
        .write_addr   (rd),
        .write_data   (wb_data),
        .read_data1   (rs1_data),
        .read_data2   (rs2_data)
    );

    // ====================================================================
    // ALU input muxes
    // ====================================================================
    reg [31:0] alu_a;
    reg [31:0] alu_b;

    always @(*) begin
        case (alu_src_a_sel)
            `ALU_SRC_A_REG  : alu_a = rs1_data;
            `ALU_SRC_A_PC   : alu_a = pc;
            `ALU_SRC_A_ZERO : alu_a = 32'b0;
            default         : alu_a = rs1_data;
        endcase
    end

    always @(*) begin
        case (alu_src_b_sel)
            `ALU_SRC_B_REG : alu_b = rs2_data;
            `ALU_SRC_B_IMM : alu_b = imm;
            default        : alu_b = rs2_data;
        endcase
    end

    // ====================================================================
    // ALU
    // ====================================================================
    wire [31:0] alu_result;
    wire        alu_zero;

    alu alu_inst (
        .a      (alu_a),
        .b      (alu_b),
        .op     (alu_op),
        .result (alu_result),
        .zero   (alu_zero)
    );

    // ====================================================================
    // Branch comparator
    // ====================================================================
    wire branch_taken;

    branch_unit branch_unit_inst (
        .rs1_data     (rs1_data),
        .rs2_data     (rs2_data),
        .funct3       (funct3),
        .branch_taken (branch_taken)
    );

    // ====================================================================
    // Data memory
    // ====================================================================
    wire [31:0] mem_read_data;
    wire mem_write_en = mem_write_en_raw & ~trap_en;

    dmem #(
        .DEPTH_WORDS (DMEM_DEPTH_WORDS),
        .INIT_FILE   (DMEM_INIT_FILE)
    ) dmem_inst (
        .clk          (clk),
        .addr         (alu_result),
        .write_data   (rs2_data),
        .mem_read_en  (mem_read_en),
        .mem_write_en (mem_write_en),
        .funct3       (funct3),
        .read_data    (mem_read_data)
    );

    // ====================================================================
    // CSR write source mux + "no-write" suppression
    //   CSRRS / CSRRC with rs1==x0 (or CSRRSI/CSRRCI with zimm==0) must
    //   NOT update the CSR (spec 9.1). The rs1 FIELD is the discriminator
    //   for both register and immediate variants since it doubles as zimm.
    // ====================================================================
    wire [31:0] csr_wdata     = csr_src_sel ? zimm : rs1_data;
    wire        csr_src_zero  = (rs1 == 5'd0);
    wire        csr_write_en  = csr_access_en && (
                                    (csr_op == `CSR_OP_WRITE) ? 1'b1
                                                              : ~csr_src_zero );

    wire [31:0] csr_rdata;
    wire [31:0] mtvec_out;
    wire [31:0] mepc_out;

    csr_file csr_file_inst (
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
        .mret_en       (is_mret),
        .mtvec_out     (mtvec_out),
        .mepc_out      (mepc_out)
    );

    // ====================================================================
    // Writeback mux. Extended with WB_SRC_CSR for Zicsr
    // ====================================================================
    always @(*) begin
        case (wb_src_sel)
            `WB_SRC_ALU : wb_data = alu_result;
            `WB_SRC_MEM : wb_data = mem_read_data;
            `WB_SRC_PC4 : wb_data = pc + 32'd4;
            `WB_SRC_CSR : wb_data = csr_rdata;
            default     : wb_data = alu_result;
        endcase
    end

    // ====================================================================
    // Next-PC mux. Trap and MRET take priority over everything else
    // ====================================================================
    wire is_jalr_instr = jump && (opcode == `OPCODE_JUMP_AND_LINK_REG);
    wire is_jal_instr  = jump && (opcode == `OPCODE_JUMP_AND_LINK);
    wire take_branch   = branch && branch_taken;

    always @(*) begin
        if (trap_en)
            next_pc = mtvec_out;
        else if (is_mret)
            next_pc = mepc_out;
        else if (is_jalr_instr)
            next_pc = (rs1_data + imm) & ~32'd1;
        else if (is_jal_instr || take_branch)
            next_pc = alu_result;
        else
            next_pc = pc + 32'd4;
    end

endmodule

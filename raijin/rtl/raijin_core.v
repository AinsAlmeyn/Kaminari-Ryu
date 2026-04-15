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
    wire       is_m_op;

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
        .is_system_priv (is_system_priv),
        .is_m_op        (is_m_op)
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
    // Misaligned data access detection.
    //   funct3[1:0] = 00 -> byte   (always aligned)
    //   funct3[1:0] = 01 -> half   (addr[0] must be 0)
    //   funct3[1:0] = 10 -> word   (addr[1:0] must be 0)
    // ====================================================================
    wire [1:0] mem_addr_low  = alu_result[1:0];
    wire       access_is_word = (funct3[1:0] == 2'b10);
    wire       access_is_half = (funct3[1:0] == 2'b01);

    wire addr_misaligned =
          (access_is_word && (mem_addr_low     != 2'b00))
       || (access_is_half && (mem_addr_low[0]  != 1'b0));

    wire load_misaligned  = mem_read_en      && addr_misaligned;
    wire store_misaligned = mem_write_en_raw && addr_misaligned;

    // ====================================================================
    // Trap detection + signal generation
    // ====================================================================
    wire trap_en = is_ecall | is_ebreak | is_illegal_priv
                 | load_misaligned | store_misaligned;

    reg [31:0] trap_cause;
    always @(*) begin
        // Priority: misalignments before ecall/ebreak/illegal so that a
        // bad address in a SYSTEM-adjacent instruction still reports the
        // correct cause.
        if      (load_misaligned)  trap_cause = `MCAUSE_LOAD_MISALIGNED;
        else if (store_misaligned) trap_cause = `MCAUSE_STORE_MISALIGNED;
        else if (is_ecall)         trap_cause = `MCAUSE_ECALL_FROM_M;
        else if (is_ebreak)        trap_cause = `MCAUSE_BREAKPOINT;
        else                       trap_cause = `MCAUSE_ILLEGAL_INSTR;
    end

    wire [31:0] trap_pc = pc;

    // mtval captures the faulting address on a memory misalignment.
    // For other synchronous exceptions we leave it at zero (WARL-legal).
    reg [31:0] trap_tval;
    always @(*) begin
        if (load_misaligned || store_misaligned)
            trap_tval = alu_result;
        else
            trap_tval = 32'b0;
    end

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
        .reset        (reset),
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
    // M extension execution unit (mul + div). Runs in parallel with the
    // ALU; is_m_op selects its result over the ALU's at writeback time.
    // ====================================================================
    wire [31:0] m_result;

    m_unit m_unit_inst (
        .rs1_data (rs1_data),
        .rs2_data (rs2_data),
        .funct3   (funct3),
        .result   (m_result)
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
    // Data-bus address decode
    //   0x1xxx_xxxx -> UART MMIO
    //   anything else -> DMEM
    // The decode is purely combinational; only the path that wins gets
    // its write_en asserted.
    // ====================================================================
    wire is_uart_addr  = (alu_result[31:28] == 4'h1);
    wire is_dmem_addr  = ~is_uart_addr;

    wire mem_write_en      = mem_write_en_raw & ~trap_en;
    wire dmem_write_en_eff = mem_write_en & is_dmem_addr;
    wire uart_write_en_eff = mem_write_en & is_uart_addr;

    wire [31:0] dmem_read_data;
    wire [31:0] uart_read_data;
    wire [31:0] mem_read_data = is_uart_addr ? uart_read_data : dmem_read_data;

    dmem #(
        .DEPTH_WORDS (DMEM_DEPTH_WORDS),
        .INIT_FILE   (DMEM_INIT_FILE)
    ) dmem_inst (
        .clk          (clk),
        .addr         (alu_result),
        .write_data   (rs2_data),
        .mem_read_en  (mem_read_en & is_dmem_addr),
        .mem_write_en (dmem_write_en_eff),
        .funct3       (funct3),
        .read_data    (dmem_read_data)
    );

    uart_sim uart_inst (
        .clk        (clk),
        .cs         (is_uart_addr),
        .read_en    (mem_read_en & is_uart_addr),
        .write_en   (uart_write_en_eff),
        .addr       (alu_result),
        .write_data (rs2_data),
        .read_data  (uart_read_data)
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
    // Writeback mux. Extended with WB_SRC_CSR for Zicsr.
    // RV32M results override the regular wb_src_sel decode: when an M-op
    // is in flight, m_unit's result wins over whatever the ALU produced.
    // ====================================================================
    always @(*) begin
        if (is_m_op) begin
            wb_data = m_result;
        end else begin
            case (wb_src_sel)
                `WB_SRC_ALU : wb_data = alu_result;
                `WB_SRC_MEM : wb_data = mem_read_data;
                `WB_SRC_PC4 : wb_data = pc + 32'd4;
                `WB_SRC_CSR : wb_data = csr_rdata;
                default     : wb_data = alu_result;
            endcase
        end
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

    // ====================================================================
    // Hardware performance counters. Each one increments by 1 per cycle in
    // which an instruction of the named class commits. They are inspired
    // by the RISC-V hpmcounter*'s but exposed directly via Verilator's
    // public_flat_rd to the host so the dashboard can render an instruction
    // mix breakdown without pulling raw CSR reads.
    // ====================================================================
    reg [63:0] cnt_mul          /* verilator public_flat_rd */;
    reg [63:0] cnt_branch_total /* verilator public_flat_rd */;
    reg [63:0] cnt_branch_taken /* verilator public_flat_rd */;
    reg [63:0] cnt_jump         /* verilator public_flat_rd */;
    reg [63:0] cnt_load         /* verilator public_flat_rd */;
    reg [63:0] cnt_store        /* verilator public_flat_rd */;
    reg [63:0] cnt_trap         /* verilator public_flat_rd */;

    always @(posedge clk) begin
        if (reset) begin
            cnt_mul          <= 64'b0;
            cnt_branch_total <= 64'b0;
            cnt_branch_taken <= 64'b0;
            cnt_jump         <= 64'b0;
            cnt_load         <= 64'b0;
            cnt_store        <= 64'b0;
            cnt_trap         <= 64'b0;
        end else begin
            if (is_m_op)                  cnt_mul          <= cnt_mul          + 64'd1;
            if (branch)                   cnt_branch_total <= cnt_branch_total + 64'd1;
            if (branch && branch_taken)   cnt_branch_taken <= cnt_branch_taken + 64'd1;
            if (jump)                     cnt_jump         <= cnt_jump         + 64'd1;
            if (mem_read_en)              cnt_load         <= cnt_load         + 64'd1;
            if (mem_write_en_raw)         cnt_store        <= cnt_store        + 64'd1;
            if (trap_en)                  cnt_trap         <= cnt_trap         + 64'd1;
        end
    end

endmodule

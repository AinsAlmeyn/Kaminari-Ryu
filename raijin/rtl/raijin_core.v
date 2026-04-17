// ============================================================================
// raijin_core.v: top-level single-cycle RV32I + Zicsr CPU
// ----------------------------------------------------------------------------
// v2 extensions over the baseline RV32IM single-cycle core:
//
//   * CLINT timer peripheral         - 64-bit mtime + mtimecmp, drives MTIP
//   * Machine-timer interrupt path   - priority: interrupt > sync exception
//   * WFI instruction                - implemented as NOP (spec-legal)
//   * mie / mip / misa CSRs          - minimal machine-mode interrupt model
//   * mhpmcounter3..6 CSRs           - software-visible event counters
//   * RO identification CSRs         - mvendorid / marchid / mimpid / mhartid
//
// Trap / MRET PC-mux priority (highest first):
//      trap_en  -> mtvec_out         (sync exception OR interrupt)
//      mret_en  -> mepc_out
//      is_jalr  -> (rs1 + imm) & ~1
//      is_jal
//        or taken branch             -> alu_result
//      default                       -> pc + 4
//
// Side-effect gating: while trapping, reg_write_en and mem_write_en are
// squashed so the faulting / preempted instruction does not commit.
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
    // SYSTEM disambiguation.
    // inst[31:20] (== csr_addr wire) carries the discriminator.
    //   0x000 -> ECALL    0x001 -> EBREAK   0x302 -> MRET   0x105 -> WFI
    // ====================================================================
    wire is_ecall        = is_system_priv && (csr_addr == 12'h000);
    wire is_ebreak       = is_system_priv && (csr_addr == 12'h001);
    wire is_mret         = is_system_priv && (csr_addr == 12'h302);
    wire is_wfi          = is_system_priv && (csr_addr == `PRIV_FIELD_WFI);
    wire is_illegal_priv = is_system_priv && !(is_ecall || is_ebreak || is_mret || is_wfi);

    // ====================================================================
    // Misaligned data access detection.
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
    // Async interrupt arbitration. Two machine-mode lines:
    //   machine-software (msip)  enabled by mie.MSIE, reported in mip.MSIP
    //   machine-timer    (mtip)  enabled by mie.MTIE, reported in mip.MTIP
    // A line fires only when globally enabled (mstatus.MIE) AND individually
    // enabled (mie.*IE) AND the incoming line is asserted. If both fire in
    // the same cycle the RISC-V spec gives machine-software higher priority
    // than machine-timer; we follow that for mcause arbitration below.
    // Interrupts always win over synchronous exceptions.
    // ====================================================================
    wire mtip  /* verilator public_flat_rd */;
    wire msip  /* verilator public_flat_rd */;
    wire mstatus_mie_out;
    wire mie_mtie_out;
    wire mie_msie_out;
    wire take_soft_interrupt  = mstatus_mie_out & mie_msie_out & msip;
    wire take_timer_interrupt = mstatus_mie_out & mie_mtie_out & mtip;
    wire take_interrupt       = take_soft_interrupt | take_timer_interrupt;

    // ====================================================================
    // Synchronous exception detection
    // ====================================================================
    wire sync_exception =
           is_ecall | is_ebreak | is_illegal_priv
         | load_misaligned | store_misaligned;

    wire trap_en = take_interrupt | sync_exception;

    reg [31:0] trap_cause;
    always @(*) begin
        // Interrupts win over synchronous exceptions. Among interrupts,
        // machine-software outranks machine-timer.
        if (take_soft_interrupt)         trap_cause = `MCAUSE_M_SOFT_INTERRUPT;
        else if (take_timer_interrupt)   trap_cause = `MCAUSE_M_TIMER_INTERRUPT;
        else if (load_misaligned)        trap_cause = `MCAUSE_LOAD_MISALIGNED;
        else if (store_misaligned)       trap_cause = `MCAUSE_STORE_MISALIGNED;
        else if (is_ecall)               trap_cause = `MCAUSE_ECALL_FROM_M;
        else if (is_ebreak)              trap_cause = `MCAUSE_BREAKPOINT;
        else                             trap_cause = `MCAUSE_ILLEGAL_INSTR;
    end

    wire [31:0] trap_pc = pc;

    // mtval rules: capture faulting address on memory misalignment, 0 for
    // interrupts and other synchronous causes (WARL-legal).
    reg [31:0] trap_tval;
    always @(*) begin
        if (take_interrupt)                    trap_tval = 32'b0;
        else if (load_misaligned
              || store_misaligned)             trap_tval = alu_result;
        else                                   trap_tval = 32'b0;
    end

    // ====================================================================
    // Register file
    // ====================================================================
    wire [31:0] rs1_data, rs2_data;
    reg  [31:0] wb_data;

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
    // M extension execution unit
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
    //   0x1xxx_xxxx          -> UART MMIO
    //   0x0200_xxxx           -> CLINT (timer)
    //   anything else         -> DMEM
    // ====================================================================
    wire is_uart_addr  = (alu_result[31:28] == 4'h1);
    wire is_clint_addr = (alu_result[31:16] == 16'h0200);
    wire is_dmem_addr  = ~is_uart_addr & ~is_clint_addr;

    wire mem_write_en       = mem_write_en_raw & ~trap_en;
    wire dmem_write_en_eff  = mem_write_en & is_dmem_addr;
    wire uart_write_en_eff  = mem_write_en & is_uart_addr;
    wire clint_write_en_eff = mem_write_en & is_clint_addr;

    wire [31:0] dmem_read_data;
    wire [31:0] uart_read_data;
    wire [31:0] clint_read_data;

    reg [31:0] mem_read_data;
    always @(*) begin
        if      (is_uart_addr)  mem_read_data = uart_read_data;
        else if (is_clint_addr) mem_read_data = clint_read_data;
        else                    mem_read_data = dmem_read_data;
    end

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

    clint clint_inst (
        .clk        (clk),
        .reset      (reset),
        .cs         (is_clint_addr),
        .read_en    (mem_read_en & is_clint_addr),
        .write_en   (clint_write_en_eff),
        .addr       (alu_result),
        .write_data (rs2_data),
        .read_data  (clint_read_data),
        .mtip       (mtip),
        .msip       (msip)
    );

    // ====================================================================
    // CSR write source mux + "no-write" suppression
    // ====================================================================
    wire [31:0] csr_wdata     = csr_src_sel ? zimm : rs1_data;
    wire        csr_src_zero  = (rs1 == 5'd0);
    wire        csr_write_en  = csr_access_en && (
                                    (csr_op == `CSR_OP_WRITE) ? 1'b1
                                                              : ~csr_src_zero );

    wire [31:0] csr_rdata;
    wire [31:0] mtvec_out;
    wire [31:0] mepc_out;

    // Event counters are defined below; forward declare wire views.
    // cnt_trap is kept for backward compatibility and always equals
    // cnt_exception + cnt_interrupt. cnt_wfi counts committed WFI
    // instructions so a host can tell idle-loop time from busy cycles.
    reg [63:0] cnt_mul          /* verilator public_flat_rd */;
    reg [63:0] cnt_branch_total /* verilator public_flat_rd */;
    reg [63:0] cnt_branch_taken /* verilator public_flat_rd */;
    reg [63:0] cnt_jump         /* verilator public_flat_rd */;
    reg [63:0] cnt_load         /* verilator public_flat_rd */;
    reg [63:0] cnt_store        /* verilator public_flat_rd */;
    reg [63:0] cnt_trap         /* verilator public_flat_rd */;
    reg [63:0] cnt_exception    /* verilator public_flat_rd */;
    reg [63:0] cnt_interrupt    /* verilator public_flat_rd */;
    reg [63:0] cnt_wfi          /* verilator public_flat_rd */;
    reg [63:0] cnt_csr_access   /* verilator public_flat_rd */;

    csr_file csr_file_inst (
        .clk               (clk),
        .reset             (reset),
        .csr_access_en     (csr_access_en),
        .csr_addr          (csr_addr),
        .csr_op            (csr_op),
        .csr_wdata         (csr_wdata),
        .csr_write_en      (csr_write_en),
        .csr_rdata         (csr_rdata),
        .trap_en           (trap_en),
        .trap_cause        (trap_cause),
        .trap_pc           (trap_pc),
        .trap_tval         (trap_tval),
        .mret_en           (is_mret),
        .mtvec_out         (mtvec_out),
        .mepc_out          (mepc_out),
        .mtip_in           (mtip),
        .msip_in           (msip),
        .mstatus_mie_out   (mstatus_mie_out),
        .mie_mtie_out      (mie_mtie_out),
        .mie_msie_out      (mie_msie_out),
        .hpm_branch_taken  (cnt_branch_taken),
        .hpm_load          (cnt_load),
        .hpm_store         (cnt_store),
        .hpm_mul           (cnt_mul)
    );

    // ====================================================================
    // Writeback mux.
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
    // Next-PC mux.
    // Trap (interrupt OR exception) and MRET take priority over everything.
    // WFI is treated as NOP: pc advances by 4 if no interrupt is pending,
    // otherwise the interrupt path already redirects via trap_en.
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
    // Hardware performance counters (core-side).
    //   cnt_branch_taken, cnt_load, cnt_store, cnt_mul are also read as
    //   mhpmcounter3..6 via the CSR file.
    // ====================================================================
    always @(posedge clk) begin
        if (reset) begin
            cnt_mul          <= 64'b0;
            cnt_branch_total <= 64'b0;
            cnt_branch_taken <= 64'b0;
            cnt_jump         <= 64'b0;
            cnt_load         <= 64'b0;
            cnt_store        <= 64'b0;
            cnt_trap         <= 64'b0;
            cnt_exception    <= 64'b0;
            cnt_interrupt    <= 64'b0;
            cnt_wfi          <= 64'b0;
            cnt_csr_access   <= 64'b0;
        end else begin
            if (is_m_op && !trap_en)                  cnt_mul          <= cnt_mul          + 64'd1;
            if (branch && !trap_en)                   cnt_branch_total <= cnt_branch_total + 64'd1;
            if (branch && branch_taken && !trap_en)   cnt_branch_taken <= cnt_branch_taken + 64'd1;
            if (jump && !trap_en)                     cnt_jump         <= cnt_jump         + 64'd1;
            if (mem_read_en && !trap_en)              cnt_load         <= cnt_load         + 64'd1;
            if (mem_write_en_raw && !trap_en)         cnt_store        <= cnt_store        + 64'd1;
            if (is_wfi && !trap_en)                   cnt_wfi          <= cnt_wfi          + 64'd1;
            if (csr_access_en && !trap_en)            cnt_csr_access   <= cnt_csr_access   + 64'd1;
            if (trap_en)                              cnt_trap         <= cnt_trap         + 64'd1;
            if (trap_en &&  take_interrupt)           cnt_interrupt    <= cnt_interrupt    + 64'd1;
            if (trap_en && !take_interrupt)           cnt_exception    <= cnt_exception    + 64'd1;
        end
    end

endmodule

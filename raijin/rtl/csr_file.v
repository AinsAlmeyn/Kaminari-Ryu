// ============================================================================
// csr_file.v: M-mode CSR register file + trap entry / MRET logic
// ----------------------------------------------------------------------------
// Owns every software-visible Control and Status Register that Raijin
// implements, plus the bookkeeping that happens on traps (synchronous
// exceptions and the machine-timer interrupt) and on MRET.
//
// v2 additions over the single-cycle baseline:
//   * mie / mip          : only the machine-timer bits (MTIE, MTIP) are live
//   * misa (RO)          : reports RV32IM_X (RV32I, M extension, X non-standard)
//   * mvendorid/marchid/ : all RAZ; exposed for spec-compliant software probes
//     mimpid/mhartid
//   * mhpmcounter3..6    : aliases to the four hardware event counters in
//                          raijin_core.v (branch-taken, load, store, mul)
//   * async interrupt    : machine-timer trap path, priority over sync excs
//
// Minimum CSR set (chosen to run unmodified rv32ui-p-* riscv-tests):
//
//   mstatus   (0x300). MIE[3] and MPIE[7] track state
//   misa      (0x301). Read-only reports RV32IM
//   mie       (0x304). Only bit 7 (MTIE) is writable
//   mtvec     (0x305). Trap-handler base address, direct mode only
//   mepc      (0x341). PC that the handler will MRET into
//   mcause    (0x342). Cause code written on trap entry
//   mscratch  (0x340). Scratch for the handler
//   mtval     (0x343). Faulting-instr / address / 0   (WARL, full R/W)
//   mip       (0x344). Bit 7 (MTIP) reflects the external timer line (RO)
//   mvendorid (0xF11). RAZ
//   marchid   (0xF12). RAZ
//   mimpid    (0xF13). RAZ
//   mhartid   (0xF14). RAZ (single-hart)
//   mhpmcounter3..6    . RO views of core-side event counters
//
// All other standard M-mode CSRs read as zero and ignore writes (WARL/legal).
//
// Read is combinational; writes + trap updates happen on the rising clock
// edge. Priority on the write port: reset > trap entry > MRET > sw write.
// ============================================================================

`include "riscv_defs.vh"
`include "raijin_defs.vh"

module csr_file (
    input  wire        clk,
    input  wire        reset,

    // -------- Software CSR access (from CSRR* instructions) --------------
    input  wire        csr_access_en,
    input  wire [11:0] csr_addr,
    input  wire [1:0]  csr_op,
    input  wire [31:0] csr_wdata,
    input  wire        csr_write_en,
    output wire [31:0] csr_rdata,

    // -------- Trap entry --------------------------------------------------
    // trap_en fires for BOTH synchronous exceptions and the interrupt line;
    // the core collapses them into a single signal after arbitrating the
    // cause. trap_is_interrupt lets us choose mepc = pc (interrupt target
    // re-executes the squashed instruction on MRET) vs the usual sync case.
    input  wire        trap_en,
    input  wire [31:0] trap_cause,
    input  wire [31:0] trap_pc,
    input  wire [31:0] trap_tval,

    // -------- Trap return (MRET) -----------------------------------------
    input  wire        mret_en,

    // -------- Outputs consumed by the PC mux in raijin_core --------------
    output wire [31:0] mtvec_out,
    output wire [31:0] mepc_out,

    // -------- Interrupt inputs / outputs --------------------------------
    input  wire        mtip_in,       // machine-timer pending (CLINT)
    input  wire        msip_in,       // machine-software pending (CLINT)
    output wire        mstatus_mie_out,
    output wire        mie_mtie_out,
    output wire        mie_msie_out,

    // -------- Hardware event counters (core-side, RO in CSR space) ------
    input  wire [63:0] hpm_branch_taken,
    input  wire [63:0] hpm_load,
    input  wire [63:0] hpm_store,
    input  wire [63:0] hpm_mul
);

    // --------------------------------------------------------------------
    // Storage. One flip-flop bank per implemented CSR.
    // mstatus / mie are modeled as individual bits; the full 32-bit word
    // is assembled on read so unused bits are fixed zeros (WARL-legal).
    // --------------------------------------------------------------------
    reg        mstatus_mie   /* verilator public_flat_rd */;
    reg        mstatus_mpie  /* verilator public_flat_rd */;
    reg        mie_mtie      /* verilator public_flat_rd */;
    reg        mie_msie      /* verilator public_flat_rd */;
    reg [31:0] mtvec         /* verilator public_flat_rd */;
    reg [31:0] mepc          /* verilator public_flat_rd */;
    reg [31:0] mcause        /* verilator public_flat_rd */;
    reg [31:0] mscratch      /* verilator public_flat_rd */;
    reg [31:0] mtval         /* verilator public_flat_rd */;

    reg [63:0] mcycle_ctr /* verilator public_flat_rd */;

    // --------------------------------------------------------------------
    // Read-only identification CSRs. Spec permits RAZ for vendor/arch/impl
    // IDs, and allows misa = 0 as a legal "not provided" response. For a
    // more informative probe we return a non-zero misa that advertises
    // RV32I + M. XLEN field (bits 31:30) = 01 for RV32. Extension bits:
    // bit 8 = I, bit 12 = M.
    // --------------------------------------------------------------------
    // bits 31:30 = MXL (01 = 32-bit)
    // bits 29:26 = reserved (0)
    // bits 25:13 = extensions N..Z (all zero)
    // bit  12    = M (set)
    // bits 11:9  = extensions J..L (all zero)
    // bit  8     = I (set)
    // bits 7:0   = extensions A..H (all zero)
    localparam [31:0] MISA_VALUE =
        {2'b01, 4'b0, 13'b0, 1'b1, 3'b0, 1'b1, 8'b0};

    // --------------------------------------------------------------------
    // Read port. Combinational mux over csr_addr.
    // --------------------------------------------------------------------
    wire [31:0] mstatus_word =
        (32'b0 | ({28'b0, mstatus_mie, 3'b0}))     // MIE at bit 3
      | ({24'b0, mstatus_mpie, 7'b0});             // MPIE at bit 7

    wire [31:0] mie_word  = {24'b0, mie_mtie, 3'b0, mie_msie, 3'b0};
    wire [31:0] mip_word  = {24'b0, mtip_in,  3'b0, msip_in,  3'b0};

    reg [31:0] rdata_mux;
    always @(*) begin
        case (csr_addr)
            `CSR_MSTATUS       : rdata_mux = mstatus_word;
            `CSR_MISA          : rdata_mux = MISA_VALUE;
            `CSR_MIE           : rdata_mux = mie_word;
            `CSR_MTVEC         : rdata_mux = mtvec;
            `CSR_MEPC          : rdata_mux = mepc;
            `CSR_MCAUSE        : rdata_mux = mcause;
            `CSR_MSCRATCH      : rdata_mux = mscratch;
            `CSR_MTVAL         : rdata_mux = mtval;
            `CSR_MIP           : rdata_mux = mip_word;
            `CSR_MVENDORID,
            `CSR_MARCHID,
            `CSR_MIMPID,
            `CSR_MHARTID       : rdata_mux = 32'b0;
            `CSR_MCYCLE,
            `CSR_MINSTRET,
            `CSR_CYCLE,
            `CSR_TIME,
            `CSR_INSTRET       : rdata_mux = mcycle_ctr[31:0];
            `CSR_MCYCLEH,
            `CSR_MINSTRETH,
            `CSR_CYCLEH,
            `CSR_TIMEH,
            `CSR_INSTRETH      : rdata_mux = mcycle_ctr[63:32];
            `CSR_MHPMCOUNTER3  : rdata_mux = hpm_branch_taken[31:0];
            `CSR_MHPMCOUNTER3H : rdata_mux = hpm_branch_taken[63:32];
            `CSR_MHPMCOUNTER4  : rdata_mux = hpm_load[31:0];
            `CSR_MHPMCOUNTER4H : rdata_mux = hpm_load[63:32];
            `CSR_MHPMCOUNTER5  : rdata_mux = hpm_store[31:0];
            `CSR_MHPMCOUNTER5H : rdata_mux = hpm_store[63:32];
            `CSR_MHPMCOUNTER6  : rdata_mux = hpm_mul[31:0];
            `CSR_MHPMCOUNTER6H : rdata_mux = hpm_mul[63:32];
            default            : rdata_mux = 32'b0;
        endcase
    end
    assign csr_rdata = rdata_mux;

    // --------------------------------------------------------------------
    // Compute the "next" value that a software write would place in the
    // addressed CSR, regardless of address (we mux by address later).
    // --------------------------------------------------------------------
    wire [31:0] sw_next_value =
        (csr_op == `CSR_OP_WRITE) ? csr_wdata
      : (csr_op == `CSR_OP_SET  ) ? (rdata_mux |  csr_wdata)
      : (csr_op == `CSR_OP_CLEAR) ? (rdata_mux & ~csr_wdata)
      :                              rdata_mux;

    wire sw_commit = csr_access_en & csr_write_en & ~trap_en;

    // --------------------------------------------------------------------
    // Write port. Synchronous. Priority:
    //   reset > trap entry > MRET > software CSR write
    // --------------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mie_mtie     <= 1'b0;
            mie_msie     <= 1'b0;
            mtvec        <= 32'b0;
            mepc         <= 32'b0;
            mcause       <= 32'b0;
            mscratch     <= 32'b0;
            mtval        <= 32'b0;
        end
        else if (trap_en) begin
            mepc         <= trap_pc;
            mcause       <= trap_cause;
            mtval        <= trap_tval;
            mstatus_mpie <= mstatus_mie;
            mstatus_mie  <= 1'b0;
        end
        else if (mret_en) begin
            mstatus_mie  <= mstatus_mpie;
            mstatus_mpie <= 1'b1;
        end
        else if (sw_commit) begin
            case (csr_addr)
                `CSR_MSTATUS : begin
                    mstatus_mie  <= sw_next_value[3];
                    mstatus_mpie <= sw_next_value[7];
                end
                `CSR_MIE      : begin
                    mie_msie <= sw_next_value[3];
                    mie_mtie <= sw_next_value[7];
                end
                `CSR_MTVEC    : mtvec    <= sw_next_value;
                `CSR_MEPC     : mepc     <= sw_next_value;
                `CSR_MCAUSE   : mcause   <= sw_next_value;
                `CSR_MSCRATCH : mscratch <= sw_next_value;
                `CSR_MTVAL    : mtval    <= sw_next_value;
                // mip is read-only for software (MTIP reflects the external
                // line). misa, mvendorid, marchid, mimpid, mhartid and the
                // hpmcounters are RO. Hpmcounters are driven combinationally
                // from raijin_core so software writes are legal to ignore.
                default       : ;
            endcase
        end
    end

    // Free-running 64-bit cycle counter.
    wire sw_cycle_wr_lo = sw_commit & ((csr_addr == `CSR_MCYCLE)   | (csr_addr == `CSR_MINSTRET));
    wire sw_cycle_wr_hi = sw_commit & ((csr_addr == `CSR_MCYCLEH)  | (csr_addr == `CSR_MINSTRETH));
    always @(posedge clk) begin
        if (reset) begin
            mcycle_ctr <= 64'd0;
        end else begin
            if (sw_cycle_wr_lo)       mcycle_ctr[31:0]  <= sw_next_value;
            else                      mcycle_ctr[31:0]  <= mcycle_ctr[31:0] + 32'd1;
            if (sw_cycle_wr_hi)       mcycle_ctr[63:32] <= sw_next_value;
            else if (&mcycle_ctr[31:0] && !sw_cycle_wr_lo)
                                      mcycle_ctr[63:32] <= mcycle_ctr[63:32] + 32'd1;
        end
    end

    // --------------------------------------------------------------------
    // Outputs for PC mux and core-side interrupt arbitration
    // --------------------------------------------------------------------
    assign mtvec_out        = {mtvec[31:2], 2'b00};
    assign mepc_out         = {mepc[31:1],  1'b0};
    assign mstatus_mie_out  = mstatus_mie;
    assign mie_mtie_out     = mie_mtie;
    assign mie_msie_out     = mie_msie;

endmodule

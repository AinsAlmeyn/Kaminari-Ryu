// ============================================================================
// csr_file.v: M-mode CSR register file + trap entry / MRET logic
// ----------------------------------------------------------------------------
// This module owns every software-visible Control and Status Register that
// Raijin currently implements, plus the bookkeeping that happens on a
// synchronous trap (ECALL / EBREAK / illegal instruction) and on MRET.
//
// Minimum CSR set (chosen to run unmodified rv32ui-p-* riscv-tests):
//
//   mstatus   (0x300). Only MIE[3] and MPIE[7] track state; others = 0
//   mtvec     (0x305). Trap-handler base address, direct mode only
//   mepc      (0x341) - PC of the faulting instruction
//   mcause    (0x342). Cause code written on trap entry
//   mscratch  (0x340). Scratch for the handler
//   mtval     (0x343). Faulting-instr / address / 0   (WARL, full R/W)
//
// All other standard M-mode CSRs read as zero and ignore writes (WARL/legal).
// mhartid reads as zero (single-hart core). misa reads as zero (legal).
//
// Read is combinational; writes + trap updates happen on the rising clock
// edge. When a trap fires and a CSR write is also requested (impossible in
// RV32I single-cycle. The SYSTEM opcode is either a privileged op OR a
// Zicsr op, never both) the trap would take priority.
// ============================================================================

`include "riscv_defs.vh"
`include "raijin_defs.vh"

module csr_file (
    input  wire        clk,
    input  wire        reset,

    // -------- Software CSR access (from CSRR* instructions) --------------
    input  wire        csr_access_en,   // high on any Zicsr instruction
    input  wire [11:0] csr_addr,        // inst[31:20]
    input  wire [1:0]  csr_op,          // CSR_OP_WRITE / _SET / _CLEAR
    input  wire [31:0] csr_wdata,       // mux output: rs1_data or zimm
    input  wire        csr_write_en,    // 1 when the write really happens
                                         // (CSRRS/CSRRC with src=0 -> 0)
    output wire [31:0] csr_rdata,       // old value (goes to rd)

    // -------- Trap entry --------------------------------------------------
    input  wire        trap_en,         // 1 when a sync exception fires
    input  wire [31:0] trap_cause,      // cause code (see MCAUSE_* in defs)
    input  wire [31:0] trap_pc,         // PC of the faulting instruction
    input  wire [31:0] trap_tval,       // faulting addr/instr, or 0

    // -------- Trap return (MRET) -----------------------------------------
    input  wire        mret_en,

    // -------- Outputs consumed by the PC mux in raijin_core --------------
    output wire [31:0] mtvec_out,       // target of trap entry
    output wire [31:0] mepc_out         // target of MRET
);

    // --------------------------------------------------------------------
    // Storage. One flip-flop bank per implemented CSR.
    // mstatus is modeled as two independent bits because only those matter
    // here; the rest of the 32-bit mstatus word is assembled on read.
    // --------------------------------------------------------------------
    reg        mstatus_mie;   // bit 3
    reg        mstatus_mpie;  // bit 7
    reg [31:0] mtvec;
    reg [31:0] mepc;
    reg [31:0] mcause;
    reg [31:0] mscratch;
    reg [31:0] mtval;

    // --------------------------------------------------------------------
    // Read port. Combinational mux over csr_addr.
    // Any CSR we don't implement returns zero (WARL legal).
    // --------------------------------------------------------------------
    wire [31:0] mstatus_word =
        (32'b0 | ({28'b0, mstatus_mie, 3'b0}))     // MIE at bit 3
      | ({24'b0, mstatus_mpie, 7'b0});             // MPIE at bit 7

    reg [31:0] rdata_mux;
    always @(*) begin
        case (csr_addr)
            `CSR_MSTATUS  : rdata_mux = mstatus_word;
            `CSR_MTVEC    : rdata_mux = mtvec;
            `CSR_MEPC     : rdata_mux = mepc;
            `CSR_MCAUSE   : rdata_mux = mcause;
            `CSR_MSCRATCH : rdata_mux = mscratch;
            `CSR_MTVAL    : rdata_mux = mtval;
            default       : rdata_mux = 32'b0;     // all others RAZ
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
            mtvec        <= 32'b0;
            mepc         <= 32'b0;
            mcause       <= 32'b0;
            mscratch     <= 32'b0;
            mtval        <= 32'b0;
        end
        else if (trap_en) begin
            // Synchronous exception: capture PC, cause, tval; disable
            // interrupts while saving the previous MIE into MPIE.
            mepc         <= trap_pc;
            mcause       <= trap_cause;
            mtval        <= trap_tval;
            mstatus_mpie <= mstatus_mie;
            mstatus_mie  <= 1'b0;
        end
        else if (mret_en) begin
            // Return from trap: restore MIE from MPIE; MPIE becomes 1.
            mstatus_mie  <= mstatus_mpie;
            mstatus_mpie <= 1'b1;
        end
        else if (sw_commit) begin
            case (csr_addr)
                `CSR_MSTATUS : begin
                    mstatus_mie  <= sw_next_value[3];
                    mstatus_mpie <= sw_next_value[7];
                end
                `CSR_MTVEC    : mtvec    <= sw_next_value;
                `CSR_MEPC     : mepc     <= sw_next_value;
                `CSR_MCAUSE   : mcause   <= sw_next_value;
                `CSR_MSCRATCH : mscratch <= sw_next_value;
                `CSR_MTVAL    : mtval    <= sw_next_value;
                default       : /* writes to unimplemented CSRs are ignored */ ;
            endcase
        end
    end

    // --------------------------------------------------------------------
    // Outputs for PC mux
    // --------------------------------------------------------------------
    assign mtvec_out = {mtvec[31:2], 2'b00};   // spec: low 2 bits reserved
    assign mepc_out  = {mepc[31:1],  1'b0};    // spec: low bit forced to 0

endmodule

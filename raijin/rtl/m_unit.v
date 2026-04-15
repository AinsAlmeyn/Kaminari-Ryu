// ============================================================================
// m_unit.v: RISC-V "M" extension execution unit (multiply + divide)
// ----------------------------------------------------------------------------
// Single-cycle, pure combinational. We rely on Verilog's native *, /, %
// operators; the simulator turns these into the host CPU's machine ops, so
// performance stays high. This is intentionally NOT what we would ship to
// silicon (a real ASIC/FPGA would need a multi-cycle iterative divider, and
// a DSP-block / Booth multiplier), but for a virtual platform it is exact
// and small.
//
// The eight ops, all encoded as R-type with funct7 = 7'b0000001:
//   funct3   mnemonic   semantics
//   ---------------------------------------------------------------------
//   000      MUL        rd = ( rs1 *  rs2)[31:0]
//   001      MULH       rd = ( s_rs1 * s_rs2)[63:32]   signed   x signed
//   010      MULHSU     rd = ( s_rs1 * u_rs2)[63:32]   signed   x unsigned
//   011      MULHU      rd = ( u_rs1 * u_rs2)[63:32]   unsigned x unsigned
//   100      DIV        rd = signed(rs1) / signed(rs2)         (truncate to 0)
//   101      DIVU       rd = unsigned(rs1) / unsigned(rs2)
//   110      REM        rd = signed(rs1) % signed(rs2)         (sign of rs1)
//   111      REMU       rd = unsigned(rs1) % unsigned(rs2)
//
// Spec-mandated edge cases (see RISC-V "M" v2.0, table "Semantics for div"):
//
//                            divide-by-zero    signed overflow (INT_MIN/-1)
//   DIV   (signed)           rd = -1           rd = INT_MIN
//   DIVU  (unsigned)         rd = 2^32 - 1     n/a
//   REM   (signed)           rd = rs1          rd = 0
//   REMU  (unsigned)         rd = rs1          n/a
//
// No exception is raised on any of these. Software is expected to test
// divisor for zero before issuing the instruction if it cares.
// ============================================================================

`include "riscv_defs.vh"

module m_unit (
    input  wire [31:0] rs1_data,
    input  wire [31:0] rs2_data,
    input  wire [2:0]  funct3,

    output reg  [31:0] result
);

    // ---------------------------------------------------------------------
    // Multiplication. Compute all four flavors in parallel, pick by funct3.
    // Sign-extend / zero-extend operands to 33 bits so a single signed
    // 33x33 multiply produces correct upper bits for MULH, MULHU, MULHSU.
    // ---------------------------------------------------------------------
    wire signed [32:0] a_signed_ext   = {rs1_data[31], rs1_data};   // sign-ext
    wire signed [32:0] b_signed_ext   = {rs2_data[31], rs2_data};
    wire signed [32:0] a_unsigned_ext = {1'b0,         rs1_data};   // zero-ext
    wire signed [32:0] b_unsigned_ext = {1'b0,         rs2_data};

    wire signed [65:0] mul_ss = a_signed_ext   * b_signed_ext;
    wire signed [65:0] mul_uu = a_unsigned_ext * b_unsigned_ext;
    wire signed [65:0] mul_su = a_signed_ext   * b_unsigned_ext;

    wire [31:0] mul_low = mul_ss[31:0];          // MUL: low 32 are the same regardless of signedness
    wire [31:0] mulh    = mul_ss[63:32];
    wire [31:0] mulhu   = mul_uu[63:32];
    wire [31:0] mulhsu  = mul_su[63:32];

    // ---------------------------------------------------------------------
    // Division. Spec edge cases dominate the logic; the actual /, %% calls
    // only run when neither special case fires.
    // ---------------------------------------------------------------------
    wire is_div_by_zero = (rs2_data == 32'd0);
    wire is_signed_ovf  = (rs1_data == 32'h8000_0000) && (rs2_data == 32'hFFFF_FFFF);

    wire signed [31:0] rs1_s = rs1_data;
    wire signed [31:0] rs2_s = rs2_data;

    wire [31:0] divu_q = is_div_by_zero ? 32'hFFFF_FFFF
                                        : (rs1_data / rs2_data);

    wire [31:0] div_q  = is_div_by_zero ? 32'hFFFF_FFFF
                       : is_signed_ovf  ? 32'h8000_0000
                                        : $unsigned(rs1_s / rs2_s);

    wire [31:0] remu_r = is_div_by_zero ? rs1_data
                                        : (rs1_data % rs2_data);

    wire [31:0] rem_r  = is_div_by_zero ? rs1_data
                       : is_signed_ovf  ? 32'h0000_0000
                                        : $unsigned(rs1_s % rs2_s);

    // ---------------------------------------------------------------------
    // Output mux on funct3.
    // ---------------------------------------------------------------------
    always @(*) begin
        case (funct3)
            `FUNCT3_MUL    : result = mul_low;
            `FUNCT3_MULH   : result = mulh;
            `FUNCT3_MULHSU : result = mulhsu;
            `FUNCT3_MULHU  : result = mulhu;
            `FUNCT3_DIV    : result = div_q;
            `FUNCT3_DIVU   : result = divu_q;
            `FUNCT3_REM    : result = rem_r;
            `FUNCT3_REMU   : result = remu_r;
            default        : result = 32'd0;
        endcase
    end

endmodule

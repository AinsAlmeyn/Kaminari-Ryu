// ============================================================================
// clint.v: Core Local INTerruptor (machine timer + software interrupt)
// ----------------------------------------------------------------------------
// Memory-mapped peripheral that drives two interrupt lines into csr_file:
//   mtip = machine-timer interrupt pending  (mip.MTIP)
//   msip = machine-software interrupt pending (mip.MSIP)
//
// Layout follows the SiFive CLINT convention so RISC-V embedded software
// (FreeRTOS, Zephyr, RTOS tick handlers, riscv-pk) runs unmodified.
//
//   CLINT_BASE = 0x0200_0000
//
//   0x0200_0000  msip          (RW, 32-bit; only bit 0 is implemented)
//   0x0200_4000  mtimecmp_lo   (RW, 32-bit)
//   0x0200_4004  mtimecmp_hi   (RW, 32-bit)
//   0x0200_BFF8  mtime_lo      (RW, 32-bit) increments 1 per clock
//   0x0200_BFFC  mtime_hi      (RW, 32-bit)
//
// Timer semantics:
//   mtip = (mtime >= mtimecmp)
//   msip = bit 0 of the msip register (pure software-driven pending bit)
//
// In a real SoC `mtime' ticks at a fixed wall-clock rate (e.g. 10 MHz) even
// if the CPU clock is faster. For simulation we tick it once per CPU clock.
// Software compensates by loading larger mtimecmp deltas.
//
// Writes and reads are word-granular. Software should always issue `lw' /
// `sw' to these addresses.
// ============================================================================

module clint (
    input  wire        clk,
    input  wire        reset,

    // Bus interface (driven by raijin_core's address decoder)
    input  wire        cs,
    input  wire        read_en,
    input  wire        write_en,
    input  wire [31:0] addr,
    input  wire [31:0] write_data,
    output reg  [31:0] read_data,

    // Interrupt outputs to csr_file
    output wire        mtip,
    output wire        msip
);

    // -------- register bank ----------------------------------------------
    reg [63:0] mtime;
    reg [63:0] mtimecmp;
    reg        msip_bit;   // only bit 0 is meaningful

    // -------- address decode (word offsets) ------------------------------
    localparam [15:0] OFF_MSIP         = 16'h0000;
    localparam [15:0] OFF_MTIMECMP_LO  = 16'h4000;
    localparam [15:0] OFF_MTIMECMP_HI  = 16'h4004;
    localparam [15:0] OFF_MTIME_LO     = 16'hBFF8;
    localparam [15:0] OFF_MTIME_HI     = 16'hBFFC;

    wire [15:0] off = addr[15:0];

    // -------- read mux ---------------------------------------------------
    always @(*) begin
        case (off)
            OFF_MSIP        : read_data = {31'b0, msip_bit};
            OFF_MTIMECMP_LO : read_data = mtimecmp[31:0];
            OFF_MTIMECMP_HI : read_data = mtimecmp[63:32];
            OFF_MTIME_LO    : read_data = mtime[31:0];
            OFF_MTIME_HI    : read_data = mtime[63:32];
            default         : read_data = 32'b0;
        endcase
    end

    // -------- write port + free-running mtime ----------------------------
    wire sw_wr_msip        = cs & write_en & (off == OFF_MSIP);
    wire sw_wr_mtimecmp_lo = cs & write_en & (off == OFF_MTIMECMP_LO);
    wire sw_wr_mtimecmp_hi = cs & write_en & (off == OFF_MTIMECMP_HI);
    wire sw_wr_mtime_lo    = cs & write_en & (off == OFF_MTIME_LO);
    wire sw_wr_mtime_hi    = cs & write_en & (off == OFF_MTIME_HI);

    always @(posedge clk) begin
        if (reset) begin
            mtime    <= 64'd0;
            mtimecmp <= 64'hFFFFFFFFFFFFFFFF;
            msip_bit <= 1'b0;
        end else begin
            if (sw_wr_msip)        msip_bit        <= write_data[0];
            if (sw_wr_mtimecmp_lo) mtimecmp[31:0]  <= write_data;
            if (sw_wr_mtimecmp_hi) mtimecmp[63:32] <= write_data;

            if (sw_wr_mtime_lo)      mtime[31:0]  <= write_data;
            else                     mtime[31:0]  <= mtime[31:0] + 32'd1;
            if (sw_wr_mtime_hi)      mtime[63:32] <= write_data;
            else if (&mtime[31:0] && !sw_wr_mtime_lo)
                                     mtime[63:32] <= mtime[63:32] + 32'd1;
        end
    end

    assign mtip = (mtime[63:32] >  mtimecmp[63:32])
               || ((mtime[63:32] == mtimecmp[63:32]) && (mtime[31:0] >= mtimecmp[31:0]));
    assign msip = msip_bit;

    wire _unused = &{1'b0, read_en, 1'b0};

endmodule

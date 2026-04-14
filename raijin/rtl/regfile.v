// ============================================================================
// regfile.v: RV32I integer register file
// ----------------------------------------------------------------------------
// 32 general-purpose registers, each 32 bits wide.
//   - 2 asynchronous read ports  (for rs1 and rs2)
//   - 1 synchronous  write port  (for rd, on rising clock edge)
//
// Special rule from the RISC-V spec:
//   x0 is hardwired to zero. Reads always return 0. Writes are silently
//   discarded. This is enforced in hardware below.
// ============================================================================

module regfile (
    input  wire        clk,          // clock. Writes happen on its rising edge
    input  wire        write_enable, // 1 = perform a write this cycle, 0 = no write

    input  wire [4:0]  read_addr1,   // which register to read on port 1 (rs1)
    input  wire [4:0]  read_addr2,   // which register to read on port 2 (rs2)
    input  wire [4:0]  write_addr,   // which register to write           (rd)

    input  wire [31:0] write_data,   // value to write into write_addr

    output wire [31:0] read_data1,   // value of register read_addr1
    output wire [31:0] read_data2    // value of register read_addr2
);

    // ----------------------------------------------------------------
    // Storage: 32 registers × 32 bits each.
    // `reg` here is the Verilog keyword for "stateful storage", not
    // "register" in the architectural sense. Confusing but standard.
    // ----------------------------------------------------------------
    reg [31:0] registers [0:31];

    // ----------------------------------------------------------------
    // Read ports. Combinational (asynchronous).
    // If the requested address is x0, force the output to zero.
    // Otherwise return the stored value.
    // ----------------------------------------------------------------
    assign read_data1 = (read_addr1 == 5'd0) ? 32'd0 : registers[read_addr1];
    assign read_data2 = (read_addr2 == 5'd0) ? 32'd0 : registers[read_addr2];

    // ----------------------------------------------------------------
    // Write port. Synchronous, rising-edge triggered.
    // Writes to x0 are ignored: the spec requires x0 to stay zero.
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        if (write_enable && (write_addr != 5'd0)) begin
            registers[write_addr] <= write_data;
        end
    end

endmodule

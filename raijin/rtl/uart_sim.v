// ============================================================================
// uart_sim.v: a simulation-only UART transmitter.
//
// This module is a thin shim that lets compiled C programs emit characters
// to the Verilog testbench via memory-mapped I/O. It has no real serial
// output, no baud-rate logic, no FIFO. Write any byte to TX_DATA and the
// low 8 bits show up on the simulator's stdout as an ASCII character.
//
// Memory map (byte addresses):
//   0x1000_0000  TX_DATA     W: low byte is emitted to stdout
//                            R: returns 0 (no receive side)
//   0x1000_0004  TX_READY    R: always returns 1 (TX always idle in sim)
//                            W: ignored
//
// Address decoding is done at the core level. This module only sees an
// already-decoded chip-select (cs) plus the low bits of the address.
// ============================================================================

module uart_sim (
    input  wire        clk,
    input  wire        cs,              // 1 when the CPU is hitting our MMIO range
    input  wire        write_en,
    input  wire [31:0] addr,            // full 32-bit address (we only look at low bits)
    input  wire [31:0] write_data,
    output reg  [31:0] read_data
);

    localparam [3:0] REG_TX_DATA  = 4'h0;
    localparam [3:0] REG_TX_READY = 4'h4;

    // ----- Synchronous write side -----
    always @(posedge clk) begin
        if (cs && write_en && addr[3:0] == REG_TX_DATA) begin
            $write("%c", write_data[7:0]);
            $fflush;
        end
    end

    // ----- Combinational read side -----
    always @(*) begin
        case (addr[3:0])
            REG_TX_READY : read_data = 32'h0000_0001;   // always ready
            default      : read_data = 32'h0000_0000;
        endcase
    end

endmodule

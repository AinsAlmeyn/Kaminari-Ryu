// ============================================================================
// uart_sim.v: a simulation-only UART transmitter.
//
// This module is a thin shim that lets compiled C programs emit characters
// to the Verilog testbench via memory-mapped I/O. It has no real serial
// output, no baud-rate logic, no FIFO. Write any byte to TX_DATA and the
// low 8 bits are routed out:
//   - under iverilog: $write("%c", ...) to the simulator's stdout (legacy)
//   - under Verilator: DPI-C raijin_uart_tx(byte) into the host ring buffer
//     so the C# layer can drain it via raijin_uart_read.
//
// Memory map (byte addresses):
//   0x1000_0000  TX_DATA     W: low byte is emitted
//                            R: returns 0 (no receive side here)
//   0x1000_0004  TX_READY    R: always returns 1 (TX always idle in sim)
//                            W: ignored
//   0x1000_0008  RX_DATA     R: returns the latched byte; consuming it
//                               invalidates the latch so the next cycle can
//                               pop the next byte from the host queue
//   0x1000_000C  RX_STATUS   R: bit 0 = 1 when a fresh byte is latched
//
// Address decoding is done at the core level. This module only sees an
// already-decoded chip-select (cs) plus the low bits of the address.
// ============================================================================

`ifdef VERILATOR
import "DPI-C" function void raijin_uart_tx(input byte unsigned c);
import "DPI-C" function int  raijin_uart_rx_avail();
import "DPI-C" function int  raijin_uart_rx_pop();
`endif

module uart_sim (
    input  wire        clk,
    input  wire        cs,              // 1 when the CPU is hitting our MMIO range
    input  wire        read_en,         // CPU asserts a load this cycle
    input  wire        write_en,
    input  wire [31:0] addr,            // full 32-bit address (we only look at low bits)
    input  wire [31:0] write_data,
    output reg  [31:0] read_data
);

    localparam [3:0] REG_TX_DATA   = 4'h0;
    localparam [3:0] REG_TX_READY  = 4'h4;
    localparam [3:0] REG_RX_DATA   = 4'h8;
    localparam [3:0] REG_RX_STATUS = 4'hC;

    // Latched RX byte. We pre-fetch one byte from the host into rx_latch
    // whenever rx_valid is 0; software reads RX_DATA to consume it, which
    // clears rx_valid so the next cycle can pop again.
    reg [7:0] rx_latch;
    reg       rx_valid;

`ifdef VERILATOR
    integer rx_pop_tmp;
    always @(posedge clk) begin
        if (!rx_valid && raijin_uart_rx_avail() != 0) begin
            rx_pop_tmp = raijin_uart_rx_pop();
            rx_latch  <= rx_pop_tmp[7:0];
            rx_valid  <= 1'b1;
        end
        if (cs && read_en && addr[3:0] == REG_RX_DATA) begin
            rx_valid <= 1'b0;   // consumed
        end
    end
`else
    // Under iverilog: no host-side queue, RX is always empty.
    always @(posedge clk) begin
        rx_latch <= 8'h00;
        rx_valid <= 1'b0;
    end
`endif

    // ----- Synchronous write side -----
    always @(posedge clk) begin
        if (cs && write_en && addr[3:0] == REG_TX_DATA) begin
`ifdef VERILATOR
            raijin_uart_tx(write_data[7:0]);
`else
            $write("%c", write_data[7:0]);
            $fflush;
`endif
        end
    end

    // ----- Combinational read side -----
    always @(*) begin
        case (addr[3:0])
            REG_TX_READY  : read_data = 32'h0000_0001;            // TX always ready
            REG_RX_DATA   : read_data = {24'h0, rx_latch};
            REG_RX_STATUS : read_data = {31'h0, rx_valid};
            default       : read_data = 32'h0000_0000;
        endcase
    end

endmodule

// ============================================================================
// imem.v: instruction memory (read-only at runtime)
// ----------------------------------------------------------------------------
// Word-organized: we store one 32-bit instruction per memory word and treat
// the input address as a byte address (the bottom 2 bits are ignored, which
// is fine because RV32I instructions are always 4-byte aligned).
//
// Read is combinational so a single-cycle core can fetch and execute in
// one clock period. There is no write port. The only way to populate the
// memory is via $readmemh during simulation, controlled by INIT_FILE.
// ============================================================================

module imem #(
    parameter integer DEPTH_WORDS = 1024,    // 1024 * 4 B = 4 KB by default
    parameter         INIT_FILE   = ""       // hex file to preload at start
) (
    input  wire [31:0] addr,                 // byte address from PC
    output wire [31:0] instruction
);

    reg [31:0] mem [0:DEPTH_WORDS-1] /* verilator public_flat_rw */;
    integer _i_init;

    initial begin
        // Zero-fill first so locations past the program end read as 0
        // (encoded 0 = addi x0,x0,0 = nop, harmless if ever fetched).
        for (_i_init = 0; _i_init < DEPTH_WORDS; _i_init = _i_init + 1)
            mem[_i_init] = 32'h0;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // addr[31:2] = word index ; addr[1:0] ignored (must be 0 for legal RV32I)
    assign instruction = mem[addr[31:2]];

endmodule

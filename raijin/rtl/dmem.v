// ============================================================================
// dmem.v: data memory with byte/halfword/word access
// ----------------------------------------------------------------------------
// Word-organized internally (one 32-bit slot per memory cell), but exposes
// the byte/halfword/word access modes that RV32I LB/LH/LW/LBU/LHU and
// SB/SH/SW require. The funct3 from the instruction selects the size and
// (for loads) the sign-extension behavior.
//
//   funct3   meaning   ->  load behavior              store behavior
//   ------   -------       --------------             --------------
//   000      byte          sign-extended 8-bit        write 1 byte
//   001      halfword      sign-extended 16-bit       write 2 bytes
//   010      word          full 32 bits               write 4 bytes
//   100      byte unsigned zero-extended 8-bit        n/a
//   101      hword unsigned zero-extended 16-bit      n/a
//
// Read is combinational; write is synchronous on the rising clock edge.
// Misaligned accesses are NOT detected here. The program is trusted to
// keep halfword loads/stores 2-byte aligned and word ones 4-byte aligned.
// ============================================================================

`include "riscv_defs.vh"

module dmem #(
    parameter integer DEPTH_WORDS = 1024,
    parameter         INIT_FILE   = ""
) (
    input  wire        clk,
    input  wire [31:0] addr,
    input  wire [31:0] write_data,
    input  wire        mem_read_en,    // currently informational; reads are always available
    input  wire        mem_write_en,
    input  wire [2:0]  funct3,         // size + sign info for the access
    output reg  [31:0] read_data
);

    reg [31:0] mem [0:DEPTH_WORDS-1];
    integer _i_init;

    wire [29:0] word_index = addr[31:2];
    wire [1:0]  byte_off   = addr[1:0];
    wire [31:0] word       = mem[word_index];

    initial begin
        // Zero-init the entire dmem so uninitialized reads (like a handler
        // incrementing a counter from its first call) see 0 rather than X.
        for (_i_init = 0; _i_init < DEPTH_WORDS; _i_init = _i_init + 1)
            mem[_i_init] = 32'h0;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // ----------------------------------------------------------------
    // READ path. Combinational. We always compute the right value,
    // even when mem_read_en is low; the upstream writeback mux will
    // simply ignore it. (Keeps timing clean.)
    // ----------------------------------------------------------------
    reg [7:0]  byte_value;
    reg [15:0] half_value;

    always @(*) begin
        // Pick the requested byte / halfword from the loaded word.
        case (byte_off)
            2'd0 : byte_value = word[7:0];
            2'd1 : byte_value = word[15:8];
            2'd2 : byte_value = word[23:16];
            2'd3 : byte_value = word[31:24];
        endcase

        case (byte_off[1])
            1'b0 : half_value = word[15:0];
            1'b1 : half_value = word[31:16];
        endcase

        case (funct3)
            `FUNCT3_LOAD_BYTE_SIGNED       : read_data = {{24{byte_value[7]}},  byte_value};
            `FUNCT3_LOAD_BYTE_UNSIGNED     : read_data = {24'b0,                byte_value};
            `FUNCT3_LOAD_HALFWORD_SIGNED   : read_data = {{16{half_value[15]}}, half_value};
            `FUNCT3_LOAD_HALFWORD_UNSIGNED : read_data = {16'b0,                half_value};
            `FUNCT3_LOAD_WORD              : read_data = word;
            default                        : read_data = word;   // safe default
        endcase
    end

    // ----------------------------------------------------------------
    // WRITE path. Synchronous. We construct the new 32-bit word by
    // overlaying the relevant byte(s) of write_data on top of the
    // current word, then commit on the clock edge.
    // ----------------------------------------------------------------
    reg [31:0] new_word;

    always @(*) begin
        new_word = word;   // start from current contents, modify slice
        case (funct3)
            `FUNCT3_STORE_BYTE : begin
                case (byte_off)
                    2'd0 : new_word[7:0]   = write_data[7:0];
                    2'd1 : new_word[15:8]  = write_data[7:0];
                    2'd2 : new_word[23:16] = write_data[7:0];
                    2'd3 : new_word[31:24] = write_data[7:0];
                endcase
            end
            `FUNCT3_STORE_HALFWORD : begin
                case (byte_off[1])
                    1'b0 : new_word[15:0]  = write_data[15:0];
                    1'b1 : new_word[31:16] = write_data[15:0];
                endcase
            end
            `FUNCT3_STORE_WORD : new_word = write_data;
            default            : new_word = word;   // unrecognized: no change
        endcase
    end

    always @(posedge clk) begin
        if (mem_write_en)
            mem[word_index] <= new_word;
    end

endmodule

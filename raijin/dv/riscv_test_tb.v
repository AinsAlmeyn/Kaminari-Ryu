// ============================================================================
// riscv_test_tb.v: generic harness for running a single riscv-tests program.
//
// The test binary is loaded into BOTH imem and dmem at startup so that
// instruction fetches and data loads operate on the same image (a cheap
// substitute for a real unified memory model).
//
// The Python runner compiles iverilog with  `+define+TEST_HEX_FILE="path"`
// and  `+define+TEST_NAME="name"`  to select which test to run. Each test
// is a self-checking program: on completion it writes its result into the
// `tohost` word at byte address 0x1000 (word index 0x400). A value of 1
// means PASS; anything else is FAIL, with the failed subtest number encoded
// as `(tohost >> 1)`.
// ============================================================================

`timescale 1ns / 1ps

`ifndef TEST_HEX_FILE
  `define TEST_HEX_FILE "missing.hex"
`endif
`ifndef TEST_NAME
  `define TEST_NAME "(unnamed)"
`endif

module riscv_test_tb;

    localparam integer DEPTH_WORDS = 65536;                // 256 KB per memory
    localparam integer TOHOST_WORD_INDEX = 32'h400;        // byte addr 0x1000
`ifdef MAX_CYCLES
    localparam integer MAX_CYCLES = `MAX_CYCLES;
`else
    localparam integer MAX_CYCLES = 5_000_000;
`endif

    reg clk;
    reg reset;

    raijin_core #(
        .IMEM_DEPTH_WORDS (DEPTH_WORDS),
        .DMEM_DEPTH_WORDS (DEPTH_WORDS)
    ) dut (
        .clk   (clk),
        .reset (reset)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer cycles;
    reg [31:0] tohost_val;

    initial begin
        // Load the same image into both memories. We do this BEFORE reset
        // so the very first fetch sees the program.
        $readmemh(`TEST_HEX_FILE, dut.imem_inst.mem);
        $readmemh(`TEST_HEX_FILE, dut.dmem_inst.mem);

        reset = 1'b1;
        @(posedge clk); @(posedge clk);
        @(negedge clk); reset = 1'b0;

        cycles = 0;
        tohost_val = 32'b0;

        // Poll the tohost word each cycle until it goes non-zero or we
        // hit the cycle cap.
        while (cycles < MAX_CYCLES) begin
            @(posedge clk);
            cycles = cycles + 1;
            tohost_val = dut.dmem_inst.mem[TOHOST_WORD_INDEX];
            if (tohost_val !== 32'b0) begin
                if (tohost_val === 32'd1) begin
                    $display("TEST %s: PASS  (cycles=%0d)",
                             `TEST_NAME, cycles);
                end else begin
                    $display("TEST %s: FAIL  tohost=0x%08h subtest=%0d (cycles=%0d)",
                             `TEST_NAME, tohost_val, tohost_val >> 1, cycles);
                end
                $finish;
            end
        end

        $display("TEST %s: TIMEOUT after %0d cycles", `TEST_NAME, MAX_CYCLES);
        $finish;
    end

endmodule

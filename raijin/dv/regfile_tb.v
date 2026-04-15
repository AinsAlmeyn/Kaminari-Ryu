// ============================================================================
// regfile_tb.v: testbench for the RV32I register file
// ----------------------------------------------------------------------------
// Simulation-only. Drives stimuli into regfile.v, checks outputs against
// expected values, prints PASS/FAIL for each test case.
// ============================================================================

`timescale 1ns / 1ps

module regfile_tb;

    // -------- Signals driven into the DUT (Device Under Test) ------------
    reg         clk;
    reg         reset;
    reg         write_enable;
    reg  [4:0]  read_addr1;
    reg  [4:0]  read_addr2;
    reg  [4:0]  write_addr;
    reg  [31:0] write_data;
    wire [31:0] read_data1;
    wire [31:0] read_data2;

    // -------- Pass/fail counters ----------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;

    // -------- Instantiate the DUT ---------------------------------------
    regfile dut (
        .clk          (clk),
        .reset        (reset),
        .write_enable (write_enable),
        .read_addr1   (read_addr1),
        .read_addr2   (read_addr2),
        .write_addr   (write_addr),
        .write_data   (write_data),
        .read_data1   (read_data1),
        .read_data2   (read_data2)
    );

    // -------- Clock generator: 10 ns period (100 MHz) -------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------- Helper task: check a value and print PASS/FAIL ------------
    task check;
        input [255:0] label;       // short text label (up to 32 chars)
        input [31:0]  actual;
        input [31:0]  expected;
        begin
            if (actual === expected) begin
                $display("  PASS : %0s   (got 0x%08h)", label, actual);
                pass_count = pass_count + 1;
            end else begin
                $display("  FAIL : %0s   expected 0x%08h, got 0x%08h",
                         label, expected, actual);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // -------- Helper task: synchronous write at next clock edge ---------
    task do_write;
        input [4:0]  addr;
        input [31:0] data;
        begin
            @(negedge clk);          // setup on the falling edge
            write_addr   = addr;
            write_data   = data;
            write_enable = 1;
            @(posedge clk);          // write happens on this rising edge
            @(negedge clk);
            write_enable = 0;
        end
    endtask

    // -------- Main test sequence -----------------------------------------
    initial begin
        // Dump waveform for GTKWave inspection
        $dumpfile("regfile_tb.vcd");
        $dumpvars(0, regfile_tb);

        $display("================================================");
        $display(" regfile_tb : RV32I register file verification");
        $display("================================================");

        // Initialise all inputs
        reset        = 1;
        write_enable = 0;
        read_addr1   = 0;
        read_addr2   = 0;
        write_addr   = 0;
        write_data   = 0;
        #12; reset = 0; #2;

        // ----------------------------------------------------------------
        // Test 1 : write x5 = 0xDEADBEEF, then read it back
        // ----------------------------------------------------------------
        $display("\n[Test 1] basic write/read on x5");
        do_write(5'd5, 32'hDEADBEEF);
        read_addr1 = 5'd5;
        #1;
        check("read x5 after write", read_data1, 32'hDEADBEEF);

        // ----------------------------------------------------------------
        // Test 2 : x0 must always read as 0, even after a "write"
        // ----------------------------------------------------------------
        $display("\n[Test 2] x0 hardwired-zero rule");
        do_write(5'd0, 32'hFFFFFFFF);   // try to corrupt x0
        read_addr1 = 5'd0;
        #1;
        check("read x0 after write attempt", read_data1, 32'h00000000);

        // ----------------------------------------------------------------
        // Test 3 : two independent read ports return different registers
        // ----------------------------------------------------------------
        $display("\n[Test 3] two read ports work independently");
        do_write(5'd10, 32'h11111111);
        do_write(5'd20, 32'h22222222);
        read_addr1 = 5'd10;
        read_addr2 = 5'd20;
        #1;
        check("port1 reads x10", read_data1, 32'h11111111);
        check("port2 reads x20", read_data2, 32'h22222222);

        // ----------------------------------------------------------------
        // Test 4 : write_enable = 0 must NOT write
        // ----------------------------------------------------------------
        $display("\n[Test 4] write_enable=0 blocks writes");
        // First put a known value into x7
        do_write(5'd7, 32'hAAAAAAAA);
        // Now attempt a write with write_enable=0
        @(negedge clk);
        write_addr   = 5'd7;
        write_data   = 32'hBBBBBBBB;
        write_enable = 0;        // disabled
        @(posedge clk);
        @(negedge clk);
        read_addr1 = 5'd7;
        #1;
        check("x7 unchanged when WE=0", read_data1, 32'hAAAAAAAA);

        // ----------------------------------------------------------------
        // Test 5 : same-cycle write + read returns OLD value
        //          (read is async on current registers, write commits at edge)
        // ----------------------------------------------------------------
        $display("\n[Test 5] same-cycle write+read returns old value");
        do_write(5'd15, 32'h12345678);   // initial value
        @(negedge clk);
        // Set up to read x15 and write a new value to x15 in the same cycle
        read_addr1   = 5'd15;
        write_addr   = 5'd15;
        write_data   = 32'h99999999;
        write_enable = 1;
        #1;
        // Before the rising edge, read should still see old value
        check("read sees OLD before edge", read_data1, 32'h12345678);
        @(posedge clk);
        @(negedge clk);
        write_enable = 0;
        #1;
        // After the edge, the new value is committed
        check("read sees NEW after edge", read_data1, 32'h99999999);

        // ----------------------------------------------------------------
        // Test 6 : write to highest register x31
        // ----------------------------------------------------------------
        $display("\n[Test 6] highest register x31");
        do_write(5'd31, 32'hCAFEBABE);
        read_addr1 = 5'd31;
        #1;
        check("x31 read back", read_data1, 32'hCAFEBABE);

        // ----------------------------------------------------------------
        // Summary
        // ----------------------------------------------------------------
        $display("\n================================================");
        $display(" RESULT : %0d passed, %0d failed", pass_count, fail_count);
        $display("================================================");
        if (fail_count == 0)
            $display(" ALL TESTS PASSED");
        else
            $display(" SOME TESTS FAILED");
        $finish;
    end

endmodule

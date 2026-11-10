// tb_addr_filter.sv - self-checking testbench for addr_filter.
// dut_t uses tb_whitelist.mem: entry 0 = AAAA (in use), entry 2 = 1234 but NOT in use, entry 63 = BEEF (in use,
// the last one: tests the full scan). dut_r uses the real whitelist.mem (our two boards 157C and 1764).
// Checks accept / drop, that exactly one done comes per check, and the worst-case time. Ends with TEST PASSED/FAILED.
`timescale 1ns / 1ps
module tb_addr_filter;
    reg clk = 1'b0, rst = 1'b1, check_t = 1'b0, check_r = 1'b0;
    reg [15:0] addr = 16'h0000;
    wire done_t, accept_t, busy_t, done_r, accept_r, busy_r;

    addr_filter #(.ENTRIES(64), .INIT_FILE("tb_whitelist.mem")) dut_t (
        .clk(clk), .rst(rst), .check(check_t), .addr(addr), .done(done_t), .accept(accept_t), .busy(busy_t), .wl_we(1'b0), .wl_idx(6'd0), .wl_wdata(32'd0), .wl_rdata());
    addr_filter #(.ENTRIES(64), .INIT_FILE("whitelist.mem")) dut_r (
        .clk(clk), .rst(rst), .check(check_r), .addr(addr), .done(done_r), .accept(accept_r), .busy(busy_r), .wl_we(1'b0), .wl_idx(6'd0), .wl_wdata(32'd0), .wl_rdata());

    always #4 clk = ~clk;

    integer errors = 0, max_clocks = 0;

    // one lookup: pulse check, wait for done (exactly one), compare accept
    task automatic lookup(input bit real_list, input [15:0] a, input bit want);
        integer clocks = 0, dones = 0;
        bit got = 0;
        @(posedge clk);
        addr <= a;
        if (real_list) check_r <= 1'b1; else check_t <= 1'b1;
        @(posedge clk);
        check_r <= 1'b0; check_t <= 1'b0;
        // the filter may finish, then wait a bit to be sure no second done comes
        repeat (200) begin
            @(posedge clk);
            clocks++;
            if (real_list ? done_r : done_t) begin
                dones++;
                got = real_list ? accept_r : accept_t;
                if (clocks > max_clocks) max_clocks = clocks;
            end
        end
        if (dones != 1 || got != want) begin
            $display("ERROR: %s list, addr %04h: %0d done, accept %0d, expected 1 done, accept %0d",
                     real_list ? "real" : "test", a, dones, got, want);
            errors++;
        end else
            $display("  ok: %s list, addr %04h -> %s", real_list ? "real" : "test", a, want ? "accept" : "drop");
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;

        $display("test 1: the real list (our two boards)");
        lookup(1, 16'h157C, 1);
        lookup(1, 16'h1764, 1);
        lookup(1, 16'h1765, 0);
        lookup(1, 16'h0000, 0);            // empty entries are 0: must NOT match address 0

        $display("test 2: the test list");
        lookup(0, 16'hAAAA, 1);            // first entry
        lookup(0, 16'hBEEF, 1);            // last entry: full scan
        lookup(0, 16'h1234, 0);            // in the list but bit 16 = 0 (not in use)
        lookup(0, 16'h0000, 0);
        lookup(0, 16'hFFFF, 0);

        $display("worst case: %0d clocks to done", max_clocks);
        if (max_clocks > 130) begin
            $display("ERROR: slower than 130 clocks"); errors++;
        end
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule

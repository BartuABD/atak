// tb_debounce.sv - a bouncing button: 3 presses, each with 2 ms of random bounces at the press and at the release.
// Exactly 3 rise pulses must come out (one per press). A 1 ms glitch while released must give none.
// STABLE_CYC is 20 ms like on the board; the 125 MHz clock makes this a ~1.2 s simulation of a few seconds' work.
`timescale 1ns / 1ps
module tb_debounce;
    reg clk = 1'b0, btn = 1'b0;
    always #4 clk = ~clk;
    wire level, rise;
    debounce #(.STABLE_CYC(2_500_000)) dut (.clk(clk), .in(btn), .level(level), .rise(rise));

    integer rises = 0, errors = 0;
    always @(posedge clk) if (rise) rises++;

    task automatic bounce(input bit final_level);
        repeat (12) begin btn = $urandom_range(0, 1); #($urandom_range(20_000, 300_000)); end   // ~2 ms of bounces
        btn = final_level;
    endtask

    initial begin
        #1ms;
        for (int p = 0; p < 3; p++) begin
            bounce(1); #100ms;           // press, hold 100 ms
            bounce(0); #100ms;           // release, wait
        end
        btn = 1'b1; #1ms; btn = 1'b0;    // 1 ms glitch
        #50ms;
        $display("presses 3, rise pulses %0d", rises);
        if (rises != 3) errors++;
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
    end
endmodule

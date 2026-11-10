// debounce.v - a push button as a clean signal: one "rise" pulse per press, no matter how the contacts bounce.
//
// A mechanical button does not switch once: for a few ms at the press AND at the release it jumps 0/1/0/1.
// An edge detector with only a lock-out after the press still sees the bounces of the RELEASE as new presses
// (that is how BTN1 could send the table 2-3 times within 0.6 s). Here the output only follows the input after the
// input has stayed the same for STABLE_CYC clocks (20 ms), so both bounce bursts are swallowed.
`timescale 1ns / 1ps
module debounce #(
    parameter integer STABLE_CYC = 2_500_000      // 20 ms at 125 MHz
) (
    input  wire clk,
    input  wire in,                              // the raw button pin (asynchronous)
    output reg  level = 1'b0,                    // the debounced button state
    output reg  rise  = 1'b0                     // one clock at each press
);
    (* ASYNC_REG = "TRUE" *) reg in_m = 1'b0, in_s = 1'b0;
    always @(posedge clk) begin in_m <= in; in_s <= in_m; end

    reg [$clog2(STABLE_CYC)-1:0] cnt = 0;
    always @(posedge clk) begin
        rise <= 1'b0;
        if (in_s == level)
            cnt <= 0;                            // no change (or a bounce went back): start counting again
        else if (cnt == STABLE_CYC - 1) begin
            level <= in_s;                       // stable long enough: take it
            rise  <= in_s;
            cnt   <= 0;
        end else
            cnt <= cnt + 1'b1;
    end
endmodule

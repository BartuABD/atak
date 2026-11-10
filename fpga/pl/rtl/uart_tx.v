// uart_tx.v - UART transmitter, 8N1, LSB first, idle high (A.T.K. downlink, Zybo PL -> gateway STM32 RX).
//
// Handshake: the sender puts a byte on "data" with "valid" high; the byte is taken in the clock where valid and
// ready are both high. ready is high whenever the transmitter is idle, so a sender that keeps valid high gets its
// bytes out back to back (no idle time between the stop bit and the next start bit).
// One bit = CLKS_PER_BIT clocks: 125 MHz / 115200 = 1085.07 -> 1085 (0.006 % fast).
`timescale 1ns / 1ps
module uart_tx #(
    parameter integer CLK_HZ = 125_000_000,
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       valid,
    output wire       ready,
    output wire       busy,
    output reg        tx = 1'b1                  // to the Pmod pin
);
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD / 2) / BAUD;
    localparam integer CW = $clog2(CLKS_PER_BIT);

    reg [9:0]    shreg   = 10'h3FF;              // {stop, data[7:0], start}, sent LSB first
    reg [3:0]    bits    = 4'd0;                 // bits still to send (0 = idle)
    reg [CW-1:0] clk_cnt = 0;

    assign busy  = (bits != 4'd0);
    assign ready = !busy;

    always @(posedge clk) begin
        if (rst) begin
            tx      <= 1'b1;
            bits    <= 4'd0;
            clk_cnt <= 0;
        end else if (!busy) begin
            tx <= 1'b1;
            if (valid) begin                     // take the byte, start bit goes out now
                shreg   <= {1'b1, data, 1'b0};
                tx      <= 1'b0;
                bits    <= 4'd10;
                clk_cnt <= 0;
            end
        end else if (clk_cnt == CLKS_PER_BIT - 1) begin
            clk_cnt <= 0;
            if (bits == 4'd1) begin              // stop bit done: idle (tx stays 1)
                bits <= 4'd0;
            end else begin
                tx    <= shreg[1];               // next bit
                shreg <= {1'b1, shreg[9:1]};
                bits  <= bits - 1'b1;
            end
        end else
            clk_cnt <= clk_cnt + 1'b1;
    end
endmodule

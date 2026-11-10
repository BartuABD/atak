// uart_rx.v - UART receiver, 8N1, LSB first, idle high (A.T.K. gateway link, Zybo Z7-20 PL).
//
// 16x oversampling: a "tick" comes 16 times per bit. After the falling edge of the start bit it waits 8 ticks
// (the middle of the start bit) and checks that the line is still low; a shorter low pulse is a glitch and is
// ignored. Then it samples every 16 ticks, in the middle of each data bit and of the stop bit.
// Stop bit low = framing_error (no valid); the receiver then waits until the line is high again before it looks
// for the next start bit (so a stuck-low line or a "break" gives one error, not a stream of garbage bytes).
//
// Outputs: data + a 1-clock valid strobe per good byte; framing_error is a 1-clock strobe too.
// The tick counter restarts at every start bit, so the sampling point does not drift from byte to byte.
`timescale 1ns / 1ps
module uart_rx #(
    parameter integer CLK_HZ = 125_000_000,     // Zybo Z7 board oscillator (100_000_000 if FCLK0 is used)
    parameter integer BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst,                      // synchronous, active high
    input  wire       rx,                       // straight from the Pmod pin (asynchronous)
    output reg  [7:0] data = 8'h00,
    output reg        valid = 1'b0,
    output reg        framing_error = 1'b0
);
    // clocks per tick, rounded: 125 MHz / (115200 * 16) = 67.8 -> 68 (0.3 % slow, UART allows ~2 %)
    localparam integer DIV = (CLK_HZ + BAUD * 8) / (BAUD * 16);
    localparam integer DW  = $clog2(DIV);

    localparam [2:0] S_IDLE = 3'd0, S_START = 3'd1, S_DATA = 3'd2, S_STOP = 3'd3, S_WAIT_HIGH = 3'd4;

    // 2-flip-flop synchronizer: rx comes from another clock domain (the STM32), start at 1 = idle
    (* ASYNC_REG = "TRUE" *) reg rx_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rx_sync = 1'b1;
    always @(posedge clk) begin
        rx_meta <= rx;
        rx_sync <= rx_meta;
    end

    reg [2:0]    state   = S_IDLE;
    reg [DW-1:0] div_cnt = 0;
    reg [3:0]    os_cnt  = 4'd0;                // ticks inside the current bit (0..15)
    reg [2:0]    bit_cnt = 3'd0;                // data bit number (0..7)
    reg [7:0]    shreg   = 8'h00;
    wire         tick    = (div_cnt == DIV - 1);

    always @(posedge clk) begin
        valid         <= 1'b0;
        framing_error <= 1'b0;
        if (rst) begin
            state   <= S_IDLE;
            div_cnt <= 0;
            os_cnt  <= 4'd0;
            bit_cnt <= 3'd0;
        end else begin
            // tick generator: stopped in idle, so it starts in phase with the start bit
            if (state == S_IDLE || tick) div_cnt <= 0;
            else                         div_cnt <= div_cnt + 1'b1;

            case (state)
                S_IDLE:
                    if (!rx_sync) begin                 // falling edge: maybe a start bit
                        state  <= S_START;
                        os_cnt <= 4'd0;
                    end
                S_START:
                    if (tick) begin
                        if (os_cnt == 4'd7) begin       // middle of the start bit
                            os_cnt  <= 4'd0;
                            bit_cnt <= 3'd0;
                            state   <= rx_sync ? S_IDLE : S_DATA;   // high again = glitch
                        end else
                            os_cnt <= os_cnt + 1'b1;
                    end
                S_DATA:
                    if (tick) begin
                        if (os_cnt == 4'd15) begin      // middle of a data bit
                            os_cnt <= 4'd0;
                            shreg  <= {rx_sync, shreg[7:1]};        // LSB first
                            if (bit_cnt == 3'd7) state <= S_STOP;
                            else                 bit_cnt <= bit_cnt + 1'b1;
                        end else
                            os_cnt <= os_cnt + 1'b1;
                    end
                S_STOP:
                    if (tick) begin
                        if (os_cnt == 4'd15) begin      // middle of the stop bit
                            os_cnt <= 4'd0;
                            if (rx_sync) begin
                                data  <= shreg;
                                valid <= 1'b1;
                                state <= S_IDLE;
                            end else begin
                                framing_error <= 1'b1;
                                state         <= S_WAIT_HIGH;
                            end
                        end else
                            os_cnt <= os_cnt + 1'b1;
                    end
                S_WAIT_HIGH:
                    if (rx_sync) state <= S_IDLE;
                default:
                    state <= S_IDLE;
            endcase
        end
    end
endmodule

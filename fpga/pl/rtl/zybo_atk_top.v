// zybo_atk_top.v - board top for the Zybo Z7-20: the A.T.K. server (atk_server) on the board pins, status on LEDs.
// No PS / software needed: the PL runs from the 125 MHz board oscillator as soon as the bitstream is loaded.
//
// Pins (zybo_atk.xdc): sysclk 125 MHz, BTN0 = reset, BTN1 = send the downlink table now,
//   Pmod JC pin 1 = UART RX  <- gateway STM32 D1 (PB6, USART1_TX)
//   Pmod JC pin 2 = UART TX  -> gateway STM32 D0 (PB7, USART1_RX)
//   Pmod JC pin 5 = GND      -- gateway GND.   4 LEDs, 4 switches.
//
// SW3 down (normal): every event lights its LED for 0.1 s
//   LD0 accepted frame   LD1 dropped: address not in the list   LD2 dropped: CRC / LEN / timeout   LD3 heartbeat 1 Hz
// SW3 up, SW2 down (uplink counters, lowest 4 bits), chosen by SW1 SW0:
//   00 frames_ok   01 frames_dropped_addr   10 crc_errors   11 framing_errors
// SW3 up, SW2 up (downlink), chosen by SW0:
//   0 downlink frames sent   1 nodes in the location table
`timescale 1ns / 1ps
module zybo_atk_top (
    input  wire       sysclk,
    input  wire       btn0,
    input  wire       btn1,
    input  wire       uart_rx,
    output wire       uart_tx,
    input  wire [3:0] sw,
    output reg  [3:0] led = 4'b0000
);
    localparam integer CLK_HZ = 125_000_000;
    localparam integer FLASH  = CLK_HZ / 10;           // 0.1 s

    // reset from the button, synchronized to the clock
    (* ASYNC_REG = "TRUE" *) reg [1:0] rst_sync = 2'b11;
    always @(posedge sysclk) rst_sync <= {rst_sync[0], btn0};
    wire rst = rst_sync[1];

    // the switches change slowly: synchronize them
    (* ASYNC_REG = "TRUE" *) reg [3:0] sw_m = 4'b0, sw_s = 4'b0;
    always @(posedge sysclk) begin sw_m <= sw; sw_s <= sw_m; end

    // BTN1: exactly one "send now" per press. (2026-10-22: was an edge + 0.2 s lock-out; the bounces of a RELEASE
    // after a press longer than 0.2 s counted as new presses -> the table went out 2-3 times within ~0.6 s.)
    wire send_now;
    debounce #(.STABLE_CYC(CLK_HZ / 50)) u_btn1 (.clk(sysclk), .in(btn1), .level(), .rise(send_now));

    wire        pkt_valid;
    wire [31:0] frames_ok, frames_dropped_addr, crc_errors, framing_errors, length_errors, timeout_errors;
    wire [4:0]  table_count;
    wire [31:0] table_full_drops, frames_sent;

    atk_server #(.CLK_HZ(CLK_HZ), .BAUD(115_200), .WL_FILE("whitelist.mem"), .TABLE_SIZE(16),
                 .PERIOD_CYC(10 * CLK_HZ)) u_server (
        .clk(sysclk), .rst(rst), .rx(uart_rx), .tx(uart_tx), .start(send_now),
        .pkt_valid(pkt_valid), .frames_ok(frames_ok), .frames_dropped_addr(frames_dropped_addr),
        .crc_errors(crc_errors), .framing_errors(framing_errors), .length_errors(length_errors),
        .timeout_errors(timeout_errors), .table_count(table_count), .table_full_drops(table_full_drops),
        .frames_sent(frames_sent), .now_s(), .fresh(), .stale_s(16'd60),
        .tbl_rd_idx(4'd0), .tbl_rd_rec(), .tbl_rd_meta(), .tbl_rd_last(),
        .wl_we(1'b0), .wl_idx(6'd0), .wl_wdata(32'd0), .wl_rdata(),
        .cmd_rd_count(32'd0), .cmd_rd_addr(9'd0), .adm_load(1'b0), .adm_payload(120'h0),
        .secure_tx(1'b0), .secure_only(1'b0), .sec_key(128'h0), .rpl_clear(1'b0), .dl_ctr_load(1'b0), .dl_ctr_val(32'h0));

    // events = a counter changed (one clock after the event)
    reg [31:0] dropped_prev = 0, bad_prev = 0;
    wire [31:0] bad_sum = crc_errors + length_errors + timeout_errors;
    reg  ev_drop = 1'b0, ev_bad = 1'b0;
    always @(posedge sysclk) begin
        dropped_prev <= frames_dropped_addr;
        bad_prev     <= bad_sum;
        ev_drop      <= (frames_dropped_addr != dropped_prev);
        ev_bad       <= (bad_sum != bad_prev);
    end

    // 0.1 s flash per event, and a 1 Hz heartbeat
    reg [23:0] t_ok = 0, t_drop = 0, t_bad = 0;
    reg [26:0] beat = 0;
    always @(posedge sysclk) begin
        t_ok   <= pkt_valid ? FLASH : (t_ok   != 0 ? t_ok   - 1'b1 : 24'd0);
        t_drop <= ev_drop   ? FLASH : (t_drop != 0 ? t_drop - 1'b1 : 24'd0);
        t_bad  <= ev_bad    ? FLASH : (t_bad  != 0 ? t_bad  - 1'b1 : 24'd0);
        beat   <= (beat == CLK_HZ - 1) ? 27'd0 : beat + 1'b1;
    end

    always @(posedge sysclk) begin
        if (sw_s[3] && sw_s[2])
            led <= sw_s[0] ? table_count[3:0] : frames_sent[3:0];
        else if (sw_s[3])
            case (sw_s[1:0])
                2'd0: led <= frames_ok[3:0];
                2'd1: led <= frames_dropped_addr[3:0];
                2'd2: led <= crc_errors[3:0];
                2'd3: led <= framing_errors[3:0];
            endcase
        else
            led <= {beat < CLK_HZ / 2, t_bad != 0, t_drop != 0, t_ok != 0};
    end
endmodule

// atk_rx_top.v - the gateway receiver in the PL (A.T.K., Zybo Z7-20): uart_rx -> secure_rx -> frame_parser -> addr_filter.
//
// v9: secure_rx checks the secure envelope (AES-128-CCM MIC + replay window), unwraps nested relay frames and gives
// frame_parser the old plain frames; plain frames pass only while secure_only = 0 (see secure_rx.v). Its counters:
// sec_ok, plain_ok, plain_drop, mic_fail, replay_drop, relay_dup, e3_drop, srx_overruns (v11: + relay_upg).
//
// A frame from an address in the whitelist comes out as a 1-clock pkt_valid with its fields (held until the next
// accepted frame). Everything else is dropped here and only counted. Later (step 7) pkt_* go into a FIFO that the
// PS reads over AXI; the counters become AXI registers.
//
// Counters (32 bit, wrap around, cleared by rst):
//   frames_ok            accepted frames (good CRC, address in the list)
//   frames_dropped_addr  good frames from an address NOT in the list
//   crc_errors           frames with a wrong CRC
//   framing_errors       bytes with a bad stop bit (UART level)
//   length_errors        sync found but LEN not 14 / 17 / 19 (or wrong type for the LEN)
//   relays_ok            accepted relayed positions (0xE1; also counted in frames_ok)
// A relayed position (0xE1) needs BOTH addresses in the whitelist: the relayer is checked first, then the far node
// (two filter runs, < 3 us); if either is missing the frame counts as frames_dropped_addr.
//   timeout_errors       frames cut in the middle
// Join requests (0xA1, provisioning) with src = 0x0000 come from devices that are not set up yet: they skip the
// whitelist and go to the command FIFO like a command, but at most one per JOIN_GAP_CYC (anti-flood):
//   joins_ok             join requests passed to the FIFO     joins_limited   dropped by the rate limit
// A 0xA1 with another src is checked against the whitelist like any command.
`timescale 1ns / 1ps
module atk_rx_top #(
    parameter integer CLK_HZ      = 125_000_000,
    parameter integer BAUD        = 115_200,
    parameter integer TIMEOUT_CYC = 125_000,     // 1 ms at 125 MHz
    parameter integer ENTRIES     = 64,
    parameter         INIT_FILE   = "whitelist.mem",
    parameter integer JOIN_GAP_CYC = CLK_HZ          // at least this many clocks between two passed join requests
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        rx,                       // Pmod pin from the gateway STM32 (USART TX)

    output reg         pkt_valid = 1'b0,
    output wire [15:0] pkt_addr,
    output wire [7:0]  pkt_seq,
    output wire [31:0] pkt_lat,
    output wire [31:0] pkt_lon,
    output wire [7:0]  pkt_flags,
    output wire [7:0]  pkt_rssi,
    output wire [7:0]  pkt_snr,
    output wire        pkt_relay,                // the accepted position came through a relay
    output wire [15:0] pkt_relayer,
    output wire [7:0]  pkt_relay_rssi,
    output wire [7:0]  pkt_relay_snr,
    output reg  [31:0] relays_ok           = 32'd0,

    output reg  [31:0] frames_ok           = 32'd0,
    output reg  [31:0] frames_dropped_addr = 32'd0,
    output reg  [31:0] crc_errors          = 32'd0,
    output reg  [31:0] framing_errors      = 32'd0,
    output reg  [31:0] length_errors       = 32'd0,
    output reg  [31:0] timeout_errors      = 32'd0,

    // whitelist access for the PS (addr_filter port B); tie wl_we to 0 when not used
    input  wire        wl_we,
    input  wire [$clog2(ENTRIES)-1:0] wl_idx,
    input  wire [31:0] wl_wdata,
    output wire [31:0] wl_rdata,

    // commands (LEN = 17, type 0xC1) whose src is in the whitelist: one clock, cmd_rec = the 15 raw bytes,
    // pkt_rssi / pkt_snr belong to it. Positions and commands share the parser and the filter (one frame at a time).
    output reg          cmd_valid = 1'b0,
    output wire [135:0] cmd_rec,
    output reg  [31:0]  cmds_ok           = 32'd0,
    output reg  [31:0]  cmds_dropped_addr = 32'd0,
    output reg  [31:0]  joins_ok          = 32'd0,
    output reg  [31:0]  joins_limited     = 32'd0,
    // v9 security (tie secure_only / rpl_clear to 0 and sec_key to anything for plain operation)
    input  wire         secure_only,                 // 1: drop plain frames
    input  wire [127:0] sec_key,
    input  wire         rpl_clear,                   // one clock: empty the replay table
    output wire [31:0]  sec_ok, plain_ok, plain_drop, mic_fail, replay_drop, relay_dup, e3_drop, srx_overruns,
    output wire [31:0]  relay_upg,                   // v11: 2nd copies of positions (other path) passed on
    output wire         pkt_upg,                     // v11: the frame is such a 2nd copy (merge into the table)
    output wire [31:0]  pkt_rdev                     // v10: chosen relayer of the frame (0 = none), with pkt_*
);
    wire [7:0] rx_data;
    wire       rx_valid, rx_framing_error;
    wire       frame_ok, cmd_ok, crc_error, length_error, timeout_error;
    wire       f_done, f_accept, f_busy;
    reg        checking_cmd = 1'b0;                  // the frame now in the filter is a command
    reg [1:0]  stage = 2'd0;                         // 1: relayer being checked, 2: far node of a relayed frame
    reg        chk2 = 1'b0;                          // start the second check (far node)
    wire       is_join;
    wire       new_join = cmd_ok && is_join && pkt_addr == 16'h0000;   // from a device that is not set up: no filter
    localparam integer JW = $clog2(JOIN_GAP_CYC + 1);
    reg [JW-1:0] jgap = JOIN_GAP_CYC;                 // clocks since the last passed join (saturates)
    wire       join_pass = new_join && jgap == JOIN_GAP_CYC;

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst(rst), .rx(rx),
        .data(rx_data), .valid(rx_valid), .framing_error(rx_framing_error));

    // secure envelope check: the parser gets the old plain frames (a few us after the frame's last byte)
    wire [7:0] p_data;
    wire       p_valid;
    secure_rx #(.TIMEOUT_CYC(TIMEOUT_CYC)) u_sec (
        .clk(clk), .rst(rst), .in_data(rx_data), .in_valid(rx_valid), .secure_only(secure_only), .key(sec_key),
        .tbl_clear(rpl_clear), .out_data(p_data), .out_valid(p_valid),
        .sec_ok(sec_ok), .plain_ok(plain_ok), .plain_drop(plain_drop), .mic_fail(mic_fail),
        .replay_drop(replay_drop), .relay_dup(relay_dup), .relay_upg(relay_upg), .e3_drop(e3_drop), .overruns(srx_overruns),
        .fwd_rdev(pkt_rdev), .fwd_upg(pkt_upg));

    // the parser holds the fields of the last good frame until the next one (>= 1.5 ms later), so they are still
    // the same when the filter answers (<= 1 us later)
    frame_parser #(.TIMEOUT_CYC(TIMEOUT_CYC)) u_parser (
        .clk(clk), .rst(rst), .rx_data(p_data), .rx_valid(p_valid),
        .frame_ok(frame_ok), .cmd_ok(cmd_ok), .crc_error(crc_error), .length_error(length_error),
        .timeout_error(timeout_error),
        .addr(pkt_addr), .seq(pkt_seq), .lat(pkt_lat), .lon(pkt_lon), .flags(pkt_flags),
        .rssi(pkt_rssi), .snr(pkt_snr), .cmd_rec(cmd_rec), .is_join(is_join),
        .relay(pkt_relay), .relayer(pkt_relayer), .relay_rssi(pkt_relay_rssi), .relay_snr(pkt_relay_snr));

    addr_filter #(.ENTRIES(ENTRIES), .INIT_FILE(INIT_FILE)) u_filter (
        .clk(clk), .rst(rst), .check(frame_ok || (cmd_ok && !new_join) || chk2), .addr((frame_ok && pkt_relay) ? pkt_relayer : pkt_addr),
        .done(f_done), .accept(f_accept), .busy(f_busy),
        .wl_we(wl_we), .wl_idx(wl_idx), .wl_wdata(wl_wdata), .wl_rdata(wl_rdata));

    always @(posedge clk) begin
        chk2 <= 1'b0;
        if (frame_ok) begin checking_cmd <= 1'b0; stage <= pkt_relay ? 2'd1 : 2'd0; end
        if (cmd_ok)   begin checking_cmd <= 1'b1; stage <= 2'd0; end
        if (f_done && stage == 2'd1) begin                   // relayer checked: allowed -> now the far node
            if (f_accept) begin chk2 <= 1'b1; stage <= 2'd2; end
            else          stage <= 2'd0;
        end
        pkt_valid <= f_done && f_accept && !checking_cmd && stage != 2'd1;
        cmd_valid <= (f_done && f_accept && checking_cmd) || join_pass;
        if (rst)                           jgap <= JOIN_GAP_CYC;      // the first join after reset passes
        else if (join_pass)                jgap <= 0;
        else if (jgap != JOIN_GAP_CYC)     jgap <= jgap + 1'b1;
        if (rst) begin
            joins_ok            <= 32'd0;
            joins_limited       <= 32'd0;
            stage               <= 2'd0;
            relays_ok           <= 32'd0;
            cmds_ok             <= 32'd0;
            cmds_dropped_addr   <= 32'd0;
            frames_ok           <= 32'd0;
            frames_dropped_addr <= 32'd0;
            crc_errors          <= 32'd0;
            framing_errors      <= 32'd0;
            length_errors       <= 32'd0;
            timeout_errors      <= 32'd0;
        end else begin
            if (f_done &&  f_accept && !checking_cmd && stage != 2'd1) frames_ok <= frames_ok + 1'b1;
            if (f_done &&  f_accept && !checking_cmd && stage == 2'd2) relays_ok <= relays_ok + 1'b1;
            if (f_done && !f_accept && !checking_cmd) frames_dropped_addr <= frames_dropped_addr + 1'b1;
            if (f_done &&  f_accept &&  checking_cmd) cmds_ok             <= cmds_ok + 1'b1;
            if (f_done && !f_accept &&  checking_cmd) cmds_dropped_addr   <= cmds_dropped_addr + 1'b1;
            if (join_pass)                joins_ok      <= joins_ok + 1'b1;
            if (new_join && !join_pass)   joins_limited <= joins_limited + 1'b1;
            if (crc_error)           crc_errors          <= crc_errors + 1'b1;
            if (rx_framing_error)    framing_errors      <= framing_errors + 1'b1;
            if (length_error)        length_errors       <= length_errors + 1'b1;
            if (timeout_error)       timeout_errors      <= timeout_errors + 1'b1;
        end
    end
endmodule

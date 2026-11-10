// atk_server.v - the whole A.T.K. server in the PL (Zybo Z7-20):
//   uplink:   rx pin -> uart_rx -> frame_parser -> addr_filter (whitelist)      (atk_rx_top)
//             accepted frame -> location_table (last record + RSSI/SNR + time + via per node); a relayed position
//             (0xE1, single-hop mesh) needs relayer AND far node in the whitelist and goes in as the far node
//   commands: 0xC1 / 0xC2 / 0xC5 frames (LEN 17) from whitelisted src -> cmd_fifo for the PS (never into the table);
//             join requests 0xA1 (LEN 19) from src 0x0000 skip the whitelist, max one per second, into the same FIFO
//   downlink: every PERIOD_CYC (or on "start") -> downlink_frame_builder (fresh nodes only) -> uart_tx -> tx pin
//   admin:    the PS loads a 15-byte payload (0xC3 decision) -> admin_tx -> uart_tx (19-byte frame, LEN 0x0F)
//   v9: both go through secure_tx just before uart_tx (secure envelope when secure_tx = 1, unchanged when 0), and
//   the uplink goes through secure_rx inside atk_rx_top. dl_ctr is NOT cleared by rst (a counter must never repeat).
//   v10: flags bit 2 ("via relay") of the stored record is SET when the position came through a relay (E1) and
//   CLEARED when it was heard directly (the gateway did this before v9; the far node reads it in the 0xD1 table to
//   keep its relay request open). The chosen relayer (0x52 relay_dev) is stored per entry (tbl_rd_rdev).
//   TX arbiter: one frame at a time on the tx line (never mixed), at least GAP_CYC of idle line between two frames
//   (100 ms, the gateway's rule). If both wait at the same time the table frame goes first.
//
// The table stores the 12 payload bytes raw. atk_rx_top gives the fields separately; put back in byte order
// {flags, lon, lat, seq, addr} they are exactly the received bytes (all little-endian), byte 0 in bits 7..0.
// now_s counts seconds since reset; a node not heard for stale_s seconds is left out of the downlink.
`timescale 1ns / 1ps
module atk_server #(
    parameter integer CLK_HZ      = 125_000_000,
    parameter integer BAUD        = 115_200,
    parameter integer TIMEOUT_CYC = 125_000,          // uplink: 1 ms without a byte inside a frame = cut frame
    parameter integer WL_ENTRIES  = 64,               // whitelist size
    parameter         WL_FILE     = "whitelist.mem",
    parameter integer TABLE_SIZE  = 16,               // location table (at most 21)
    parameter integer PERIOD_CYC  = 1_250_000_000,    // downlink period: 10 s at 125 MHz
    parameter integer SEC_CYC     = CLK_HZ,           // clocks per "second" of now_s (smaller only in simulation)
    parameter integer GAP_CYC     = CLK_HZ / 10       // idle time on tx between two frames (100 ms)
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        rx,                            // from the gateway STM32 TX (D1)
    output wire        tx,                            // to the gateway STM32 RX (D0)
    input  wire        start,                         // one clock: send the table now
    input  wire [15:0] stale_s,                       // seconds; 0 = never stale (tie to 0 if not used)

    output wire        pkt_valid,                     // an accepted uplink frame (one clock)
    output wire [31:0] frames_ok,
    output wire [31:0] frames_dropped_addr,
    output wire [31:0] crc_errors,
    output wire [31:0] framing_errors,
    output wire [31:0] length_errors,
    output wire [31:0] timeout_errors,
    output wire [31:0] relays_ok,
    output wire [31:0] joins_ok,
    output wire [31:0] joins_limited,
    input  wire        tbl_del,                       // one clock: remove node tbl_del_addr from the table
    input  wire [15:0] tbl_del_addr,
    output wire [31:0] tbl_deletes,
    output wire [$clog2(TABLE_SIZE+1)-1:0] table_count,
    output wire [31:0] table_full_drops,
    output wire [31:0] frames_sent,
    output reg  [31:0] now_s = 32'd0,
    output wire [TABLE_SIZE-1:0] fresh,

    // second read port of the location table, for the PS (atk_axi); outputs arrive one clock after idx.
    input  wire [$clog2(TABLE_SIZE)-1:0] tbl_rd_idx,
    output wire [95:0]                   tbl_rd_rec,
    output wire [15:0]                   tbl_rd_meta,  // {SNR, RSSI}
    output wire [31:0]                   tbl_rd_last,  // now_s when last heard
    output wire [31:0]                   tbl_rd_via,   // {relay_SNR, relay_RSSI, relayer}, 0 = direct
    output wire [31:0]                   tbl_rd_rdev,  // v10: chosen relayer (dev_id), 0 = none
    // whitelist port for the PS; tie wl_we to 0 when not used
    input  wire                          wl_we,
    input  wire [$clog2(WL_ENTRIES)-1:0] wl_idx,
    input  wire [31:0]                   wl_wdata,
    output wire [31:0]                   wl_rdata,

    // 0xC1 commands from whitelisted nodes -> cmd_fifo (64 entries x 32 B) for the PS; tie cmd_rd_count to 0 and
    // leave the outputs open when not used
    input  wire [31:0]  cmd_rd_count,
    output wire [31:0]  cmd_wr_count,
    output wire [31:0]  cmd_overflows,
    output wire [31:0]  cmds_ok,
    output wire [31:0]  cmds_dropped_addr,
    output wire         cmd_pushed,                  // one clock per stored command (interrupt)
    input  wire [8:0]   cmd_rd_addr,                 // word address into the FIFO
    output wire [31:0]  cmd_rd_data,

    // admin frame (0xC3 decision) from the PS; tie adm_load to 0 when not used
    input  wire         adm_load,                    // one clock: send adm_payload (ignored while adm_busy)
    input  wire [119:0] adm_payload,
    output wire         adm_busy,                    // loaded and not yet completely sent
    output wire [31:0]  adm_sent,

    // v9 security; tie the inputs to 0 for plain operation
    input  wire         secure_tx,                   // 1: downlink in the secure envelope
    input  wire         secure_only,                 // 1: uplink plain frames are dropped
    input  wire [127:0] sec_key,
    input  wire         rpl_clear,
    input  wire         dl_ctr_load,                 // one clock: downlink counter = dl_ctr_val
    input  wire [31:0]  dl_ctr_val,
    output wire [31:0]  dl_ctr,
    output wire [31:0]  sec_ok, plain_ok, plain_drop, mic_fail, replay_drop, relay_dup, e3_drop, srx_overruns,
    output wire [31:0]  relay_upg,                    // v11
    output wire [31:0]  sec_sent, plain_sent
);
    // seconds counter
    localparam integer SW = $clog2(SEC_CYC);
    reg [SW-1:0] sec_div = 0;
    always @(posedge clk)
        if (rst) begin
            sec_div <= 0;
            now_s   <= 32'd0;
        end else if (sec_div == SEC_CYC - 1) begin
            sec_div <= 0;
            now_s   <= now_s + 1'b1;
        end else
            sec_div <= sec_div + 1'b1;

    wire [15:0] pkt_addr;
    wire [7:0]  pkt_seq, pkt_flags, pkt_rssi, pkt_snr;
    wire [31:0] pkt_lat, pkt_lon;
    wire        pkt_relay;
    wire [15:0] pkt_relayer;
    wire [7:0]  pkt_relay_rssi, pkt_relay_snr;
    wire [31:0] pkt_rdev;
    wire        pkt_upg;                                // v11: 2nd copy of a position (the table ORs bits 2 / 7)
    // flags as stored: bit 2 = a relayed copy arrived, bit 7 = a direct copy arrived (v11; set by the PL only)
    wire [7:0]  pkt_flags_st = (pkt_flags & 8'h7B) | (pkt_relay ? 8'h04 : 8'h80);
    wire        cmd_valid;
    wire [135:0] cmd_rec;

    atk_rx_top #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .TIMEOUT_CYC(TIMEOUT_CYC), .ENTRIES(WL_ENTRIES), .INIT_FILE(WL_FILE),
                 .JOIN_GAP_CYC(SEC_CYC)) u_rx (
        .clk(clk), .rst(rst), .rx(rx),
        .pkt_valid(pkt_valid), .pkt_addr(pkt_addr), .pkt_seq(pkt_seq), .pkt_lat(pkt_lat), .pkt_lon(pkt_lon),
        .pkt_flags(pkt_flags), .pkt_rssi(pkt_rssi), .pkt_snr(pkt_snr),
        .pkt_relay(pkt_relay), .pkt_relayer(pkt_relayer), .pkt_relay_rssi(pkt_relay_rssi), .pkt_relay_snr(pkt_relay_snr),
        .relays_ok(relays_ok),
        .frames_ok(frames_ok), .frames_dropped_addr(frames_dropped_addr), .crc_errors(crc_errors),
        .framing_errors(framing_errors), .length_errors(length_errors), .timeout_errors(timeout_errors),
        .wl_we(wl_we), .wl_idx(wl_idx), .wl_wdata(wl_wdata), .wl_rdata(wl_rdata),
        .cmd_valid(cmd_valid), .cmd_rec(cmd_rec), .cmds_ok(cmds_ok), .cmds_dropped_addr(cmds_dropped_addr),
        .joins_ok(joins_ok), .joins_limited(joins_limited),
        .secure_only(secure_only), .sec_key(sec_key), .rpl_clear(rpl_clear),
        .sec_ok(sec_ok), .plain_ok(plain_ok), .plain_drop(plain_drop), .mic_fail(mic_fail), .replay_drop(replay_drop),
        .relay_dup(relay_dup), .e3_drop(e3_drop), .srx_overruns(srx_overruns), .relay_upg(relay_upg),
        .pkt_rdev(pkt_rdev), .pkt_upg(pkt_upg));

    cmd_fifo #(.DEPTH(64)) u_cmds (
        .clk(clk), .rst(rst), .push(cmd_valid), .cmd_rec(cmd_rec), .rssi(pkt_rssi), .snr(pkt_snr), .now_s(now_s),
        .rd_count(cmd_rd_count), .wr_count(cmd_wr_count), .overflows(cmd_overflows), .pushed(cmd_pushed),
        .rd_addr(cmd_rd_addr), .rd_data(cmd_rd_data));

    wire [$clog2(TABLE_SIZE)-1:0] rd_idx;
    wire [95:0] rd_rec;

    location_table #(.ENTRIES(TABLE_SIZE)) u_table (
        .clk(clk), .rst(rst), .upd(pkt_valid), .upd_rec({pkt_flags_st, pkt_lon, pkt_lat, pkt_seq, pkt_addr}),
        .upd_meta({pkt_snr, pkt_rssi}), .upd_via(pkt_relay ? {pkt_relay_snr, pkt_relay_rssi, pkt_relayer} : 32'h0),
        .upd_rdev(pkt_rdev), .upd_merge(pkt_upg), .rd2_rdev(tbl_rd_rdev),
        .now_s(now_s), .stale_s(stale_s),
        .rd_idx(rd_idx), .rd_rec(rd_rec), .rd2_idx(tbl_rd_idx), .rd2_rec(tbl_rd_rec),
        .rd2_meta(tbl_rd_meta), .rd2_last(tbl_rd_last), .rd2_via(tbl_rd_via), .fresh(fresh),
        .count(table_count), .full_drops(table_full_drops),
        .del(tbl_del), .del_addr(tbl_del_addr), .deletes(tbl_deletes));

    // ---------------------------------------------------------------- TX: table frames + admin frames
    wire [7:0] dl_data, adm_data;
    wire       dl_valid, adm_valid, tx_ready, uart_busy;
    wire       stx_busy, stx_valid, uart_ready;
    wire [7:0] stx_data;
    wire       dl_busy, dl_req, adm_pending, adm_sending;

    // quiet = nobody is sending and the line has been idle for GAP_CYC; the gap counter restarts on any activity
    localparam integer GW = $clog2(GAP_CYC + 1);
    reg [GW-1:0] gap = GAP_CYC;
    wire active = uart_busy || stx_busy || dl_busy || adm_sending || dl_valid || adm_valid;
    wire quiet  = !active && (gap == GAP_CYC);
    always @(posedge clk)
        if (rst)                gap <= GAP_CYC;
        else if (active)        gap <= 0;
        else if (gap != GAP_CYC) gap <= gap + 1'b1;

    // the table frame starts when quiet (hold = 0); the admin frame only when quiet and no table frame is waiting
    wire adm_go = quiet && adm_pending && !dl_req;

    downlink_frame_builder #(.ENTRIES(TABLE_SIZE), .PERIOD_CYC(PERIOD_CYC)) u_builder (
        .clk(clk), .rst(rst), .start(start), .hold(!quiet), .req(dl_req), .fresh(fresh), .rd_idx(rd_idx), .rd_rec(rd_rec),
        .tx_data(dl_data), .tx_valid(dl_valid), .tx_ready(tx_ready && !adm_sending), .busy(dl_busy),
        .frames_sent(frames_sent));

    admin_tx u_admin (
        .clk(clk), .rst(rst), .load(adm_load), .payload(adm_payload), .pending(adm_pending), .go(adm_go),
        .sending(adm_sending), .busy(adm_busy), .sent(adm_sent),
        .tx_data(adm_data), .tx_valid(adm_valid), .tx_ready(tx_ready && adm_sending));

    // tx_ready = secure_tx takes a byte of the plain frame
    secure_tx u_sectx (
        .clk(clk), .rst(rst), .secure_en(secure_tx), .key(sec_key), .ctr_load(dl_ctr_load), .ctr_val(dl_ctr_val),
        .dl_ctr(dl_ctr), .in_data(adm_sending ? adm_data : dl_data), .in_valid(adm_sending ? adm_valid : dl_valid),
        .in_ready(tx_ready), .out_data(stx_data), .out_valid(stx_valid), .out_ready(uart_ready), .busy(stx_busy),
        .sec_sent(sec_sent), .plain_sent(plain_sent));

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(rst), .data(stx_data), .valid(stx_valid), .ready(uart_ready), .busy(uart_busy), .tx(tx));
endmodule

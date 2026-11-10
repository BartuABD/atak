// atk_axi.v - A.T.A.K. server (atk_server) with an AXI4-Lite register interface, so Linux on the Zynq PS can read
// the location table and the counters. For the Vivado block design: add with "Add Module" (RTL module reference);
// the s_axi_* ports are recognised as one AXI4-Lite slave, connect it to M_AXI_GP0 of the Zynq PS.
//
// Register map (byte offsets, 32-bit registers, all little-endian):
//   0x000 ID            R   0x41544B0C  ("ATK", version 12 = v11 + SECURE_ONLY = 1 after power-up, so no plain
//                           frame is accepted before Linux has loaded the key and the saved mode.
//                           v11 = v10 + "any copy": the two copies of a position
//                           (direct and relayed) are merged per seq: flags bit 2 = a relayed copy arrived, bit 7 = a
//                           direct copy arrived (both set by the PL, also in the 0xD1 downlink), RELAY_UPG 0x0C8.
//                           v10: relay choice, 0x52 envelope with relay_dev, flags bit 2 "via relay" set by the PL,
//                           chosen relayer per table entry at 0x240)
//   0x004 CONTROL       W   bit 0: send the downlink table now   bit 1: soft reset of the server (clears table,
//                           counters and the command FIFO)   - both are one-clock pulses, reading returns 0
//   0x008 TABLE_COUNT   R   number of nodes in the location table (0..16)
//   0x00C FRAMES_OK     R   accepted uplink frames         0x010 DROPPED_ADDR   R  good frames, address not allowed
//   0x014 CRC_ERRORS    R                                  0x018 FRAMING_ERRORS R  UART bytes with a bad stop bit
//   0x01C LENGTH_ERRORS R                                  0x020 TIMEOUT_ERRORS R  frames cut in the middle
//   0x024 FULL_DROPS    R   new nodes ignored, table full  0x028 FRAMES_SENT    R  downlink frames sent
//   0x030 IRQ_STATUS    R/W1C  bit 0: an accepted position arrived, bit 1: a command was stored (write 1 to clear)
//   0x034 IRQ_ENABLE    R/W    bits 1..0: drive irq when the same IRQ_STATUS bit is set
//   0x038 NOW_S         R   seconds since reset (the clock of last-heard / age)
//   0x03C STALE_S       R/W a node not heard for this many seconds is left out of the downlink (default 60, 0 = never)
//   0x040 WL_INDEX      R/W whitelist entry 0..63 that WL_DATA reads / writes
//   0x044 WL_DATA       R/W whitelist entry WL_INDEX: bit 16 = in use, bits 15..0 = node address (write = store)
//   0x048 FRESH_MASK    R   bit i = table entry i is in the downlink (in use and not stale)
//   0x04C CMD_WR_COUNT  R   commands stored so far (only grows); command n is FIFO entry n mod 64
//   0x050 CMD_RD_COUNT  R/W commands the PS has consumed; the FIFO is full when WR - RD = 64
//   0x054 CMD_OVERFLOWS R   commands dropped because the FIFO was full (the NEW one is dropped)
//   0x058 CMDS_OK       R   commands accepted (src in the whitelist)
//   0x05C CMDS_DROPPED  R   commands dropped, src not in the whitelist
//   0x060..0x06C ADMIN_DATA0..3  R/W  the 15-byte admin payload (0xC3 decision), byte 0 in bits 7..0 of DATA0;
//                           bits 31..24 of DATA3 are not sent
//   0x070 ADMIN_CTRL    W   bit 0: send the admin frame [AA 55 0F | 15 B | CRC8] (ignored while busy)
//                       R   bit 0: busy (waiting for the line or going out)
//   0x074 ADMIN_SENT    R   admin frames sent completely
//   0x078 RELAYS_OK     R   accepted relayed positions (0xE1; relayer and far node both in the whitelist)
//   0x07C JOINS_OK      R   join requests (0xA1 from src 0x0000, no whitelist) passed to the command FIFO
//   0x080 JOINS_LIMITED R   join requests dropped because the last one passed less than 1 s ago
//   0x084 TBL_DELETE    W   bits 15..0 = a node address: its entry leaves the location table (kicked / left team);
//                           the last entry moves into its slot.  R: entries deleted so far
//   ---- v9 security (secure_rx / secure_tx). SEC_CTRL, the key and DL_CTR are NOT cleared by the soft reset.
//   0x088 SEC_CTRL      R/W bit 0 SECURE_TX: downlink in the secure envelope   bit 1 SECURE_ONLY: drop plain uplink
//                           bit 2 (W, pulse): empty the replay table.  After power-up / AXI reset: SECURE_TX 0,
//                           SECURE_ONLY 1 (v12; before v12 both were 0 and plain frames passed until atk_sec.sh init).
//                           Plain operation (no key) needs SECURE_ONLY = 0 written (atk_sec.sh init does that).
//                           Migration (agreed with the nodes): SECURE_ONLY=0 -> nodes send secure -> SECURE_TX=1
//                           -> SECURE_ONLY=1.
//   0x08C..0x098 KEY0..3 W  the 128-bit network key, key byte 4i in bits 7..0 of KEYi (= the key file read as
//                           little-endian words). Write-only: reads return 0.
//   0x09C DL_CTR        R/W the next downlink counter. Linux writes saved + 256 at boot BEFORE setting SECURE_TX
//                           and saves it regularly; it must never repeat with the same key.
//   0x0A0 SEC_OK        R   secure uplink frames accepted     0x0A4 PLAIN_OK    R  plain uplink frames passed
//   0x0A8 PLAIN_DROP    R   plain uplink frames dropped (SECURE_ONLY)
//   0x0AC MIC_FAIL      R   MIC wrong (forged / wrong key)    0x0B0 REPLAY_DROP R  counter already used / too old
//   0x0B4 RELAY_DUP     R   relayed copy of a frame already heard   0x0B8 E3_DROP R  our downlink relayed back
//   0x0BC SEC_SENT      R   secure downlink frames            0x0C0 PLAIN_SENT  R  plain downlink frames
//   0x0C4 SRX_OVERRUNS  R   uplink frames lost because the previous one was still being checked (should stay 0)
//   0x0C8 RELAY_UPG     R   v11: 2nd copies of a position on the other path (relayed after direct or direct after
//                           relayed), merged into the table entry (also counted in FRAMES_OK / SEC_OK)
//   The tx line carries one frame at a time with >= 100 ms idle between frames (table frames go first).
//   0x800 + 32*k        R   command FIFO entry k (k = 0..63), 8 words: +0..+12 = the 15 raw cmd_packet_t bytes
//                           (type 0xC1 command, 0xC2 delete request or 0xC5 ACK, src, dst, msg_id, ...; byte 15 = 0), +16 = {SNR i8, RSSI i8},
//                           +20 = NOW_S at arrival, +24 = sequence number (= CMD_WR_COUNT before it), +28 = 0.
//                           A join request 0xA1 has 17 bytes: +0..+15 = bytes 0..15, +28 = byte 16 (battery).
//                           The PS reads entries RD .. WR-1 (mod 64), then writes CMD_RD_COUNT = WR.
//   0x100 + 16*i        R   table entry i (i = 0..15): word 0 = record bytes 0..3, +4 = bytes 4..7, +8 = bytes
//                           8..11, +12 = {age in seconds (max 65535), SNR i8, RSSI i8} (RSSI in bits 7..0).
//                           The 12 bytes are the node's pos_packet_t exactly as received:
//                           addr u16, seq u8, lat i32, lon i32, flags u8 (little-endian, packed).
//   0x200 + 4*i         R   VIA of table entry i (i = 0..15): {relay_SNR i8, relay_RSSI i8, relayer u16}
//                           (relayer in bits 15..0); 0 = the last position was heard directly. For a relayed
//                           node word 3's RSSI / SNR are the relayer -> gateway link.
//   0x240 + 4*i         R   RDEV of table entry i (i = 0..15): the dev_id of the relayer the node CHOSE (relay_dev of
//                           its last 0x52 packet), 0 = none / last packet was 0x51, FFFFFFFF = "anyone".
// Reading word 0 of an entry takes a copy of the whole entry; words 1..3 of the same entry then come from that copy
// (until word 3 has been read), so an entry that is updated between the reads is never mixed. Read word 0 first.
`timescale 1ns / 1ps
module atk_axi #(
    parameter integer CLK_HZ     = 100_000_000,         // the AXI clock (FCLK_CLK0 of the Zynq PS)
    parameter integer BAUD       = 115_200,
    parameter         WL_FILE    = "whitelist.mem",
    parameter integer PERIOD_CYC = 1_000_000_000,       // downlink period in clocks: 10 s at 100 MHz
    parameter integer SEC_CYC    = CLK_HZ,              // clocks per second of NOW_S (smaller only in simulation)
    parameter integer GAP_CYC    = CLK_HZ / 10          // idle time on uart_tx between two frames (100 ms)
) (
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,
    input  wire [11:0] s_axi_awaddr,
    input  wire [2:0]  s_axi_awprot,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready = 1'b0,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready = 1'b0,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid = 1'b0,
    input  wire        s_axi_bready,
    input  wire [11:0] s_axi_araddr,
    input  wire [2:0]  s_axi_arprot,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready = 1'b0,
    output reg  [31:0] s_axi_rdata = 32'h0,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid = 1'b0,
    input  wire        s_axi_rready,

    input  wire        uart_rx,                         // Pmod JC1 <- gateway STM32 D1
    output wire        uart_tx,                         // Pmod JC2 -> gateway STM32 D0
    output wire        irq                              // to IRQ_F2P of the Zynq PS (level, active high)
);
    localparam [31:0] ID = 32'h41544B0C;
    wire clk = s_axi_aclk;

    // ---------------------------------------------------------------- the server
    reg         send_now = 1'b0, soft_rst = 1'b0;
    reg  [15:0] stale_s = 16'd60;                    // STALE_S: a node not heard for this long leaves the downlink
    reg  [5:0]  wl_idx = 6'd0;                       // WL_INDEX
    reg         wl_we = 1'b0;
    reg  [31:0] wl_wdata = 32'h0;
    wire [31:0] wl_rdata, now_s;
    wire [15:0] tbl_meta;
    wire [31:0] tbl_last, tbl_via, tbl_rdev, relays_ok, joins_ok, joins_limited, tbl_deletes;
    reg         tbl_del = 1'b0;
    reg  [15:0] tbl_del_addr = 16'h0;
    wire [15:0] fresh;
    wire        rst = !s_axi_aresetn || soft_rst;
    wire        pkt_valid;
    wire [31:0] frames_ok, dropped_addr, crc_errors, framing_errors, length_errors, timeout_errors;
    wire [31:0] full_drops, frames_sent;
    wire [4:0]  table_count;
    reg  [3:0]  tbl_idx = 4'd0;
    wire [95:0] tbl_rec;
    reg  [31:0] cmd_rd_count = 32'd0;
    wire [31:0] cmd_wr_count, cmd_overflows, cmds_ok, cmds_dropped, cmd_rd_data;
    wire        cmd_pushed;
    reg  [8:0]  cmd_addr = 9'd0;
    reg  [127:0] adm_data = 128'h0;               // ADMIN_DATA0..3
    // v9 security
    reg          sec_tx = 1'b0, sec_only = 1'b1, rpl_clear = 1'b0, ctr_load = 1'b0;   // v12: secure only from power-up
    reg  [127:0] sec_key = 128'h0;                 // KEY0..3: key byte 0 = sec_key[127:120]
    reg  [31:0]  ctr_val = 32'h0;
    wire [31:0]  dl_ctr, sec_ok, plain_ok, plain_drop, mic_fail, replay_drop, relay_dup, e3_drop, srx_overruns,
                 sec_sent, plain_sent, relay_upg;
    function [31:0] bswap(input [31:0] w);         // KEYi bits 7..0 = key byte 4i
        bswap = {w[7:0], w[15:8], w[23:16], w[31:24]};
    endfunction
    reg         adm_load = 1'b0;
    wire        adm_busy;
    wire [31:0] adm_sent;

    atk_server #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .TIMEOUT_CYC(CLK_HZ / 1000), .WL_FILE(WL_FILE), .TABLE_SIZE(16),
                 .PERIOD_CYC(PERIOD_CYC), .SEC_CYC(SEC_CYC), .GAP_CYC(GAP_CYC)) u_server (
        .clk(clk), .rst(rst), .rx(uart_rx), .tx(uart_tx), .start(send_now), .stale_s(stale_s),
        .pkt_valid(pkt_valid), .frames_ok(frames_ok), .frames_dropped_addr(dropped_addr), .crc_errors(crc_errors),
        .framing_errors(framing_errors), .length_errors(length_errors), .timeout_errors(timeout_errors),
        .relays_ok(relays_ok), .joins_ok(joins_ok), .joins_limited(joins_limited),
        .tbl_del(tbl_del), .tbl_del_addr(tbl_del_addr), .tbl_deletes(tbl_deletes),
        .table_count(table_count), .table_full_drops(full_drops), .frames_sent(frames_sent),
        .now_s(now_s), .fresh(fresh),
        .tbl_rd_idx(tbl_idx), .tbl_rd_rec(tbl_rec), .tbl_rd_meta(tbl_meta), .tbl_rd_last(tbl_last), .tbl_rd_via(tbl_via),
        .tbl_rd_rdev(tbl_rdev),
        .wl_we(wl_we), .wl_idx(wl_idx), .wl_wdata(wl_wdata), .wl_rdata(wl_rdata),
        .cmd_rd_count(cmd_rd_count), .cmd_wr_count(cmd_wr_count), .cmd_overflows(cmd_overflows),
        .cmds_ok(cmds_ok), .cmds_dropped_addr(cmds_dropped), .cmd_pushed(cmd_pushed),
        .cmd_rd_addr(cmd_addr), .cmd_rd_data(cmd_rd_data),
        .adm_load(adm_load), .adm_payload(adm_data[119:0]), .adm_busy(adm_busy), .adm_sent(adm_sent),
        .secure_tx(sec_tx), .secure_only(sec_only), .sec_key(sec_key), .rpl_clear(rpl_clear),
        .dl_ctr_load(ctr_load), .dl_ctr_val(ctr_val), .dl_ctr(dl_ctr),
        .sec_ok(sec_ok), .plain_ok(plain_ok), .plain_drop(plain_drop), .mic_fail(mic_fail), .replay_drop(replay_drop),
        .relay_dup(relay_dup), .e3_drop(e3_drop), .srx_overruns(srx_overruns), .relay_upg(relay_upg),
        .sec_sent(sec_sent), .plain_sent(plain_sent));

    // table word 3 of an entry: {age in seconds (saturated at 65535), SNR, RSSI}
    wire [31:0] age_full = now_s - tbl_last;
    wire [31:0] tbl_word3 = {(age_full > 32'd65535) ? 16'hFFFF : age_full[15:0], tbl_meta};

    // ---------------------------------------------------------------- interrupt
    reg [1:0] irq_status = 2'b00, irq_enable = 2'b00;
    assign irq = |(irq_status & irq_enable);

    // ---------------------------------------------------------------- AXI write channel
    assign s_axi_bresp = 2'b00;
    reg [11:0] aw_addr = 12'h0;
    reg        aw_have = 1'b0, w_have = 1'b0;
    reg [31:0] w_data = 32'h0;
    always @(posedge clk) begin
        send_now <= 1'b0;
        soft_rst <= 1'b0;
        wl_we    <= 1'b0;
        adm_load <= 1'b0;
        tbl_del  <= 1'b0;
        rpl_clear <= 1'b0;
        ctr_load <= 1'b0;
        if (pkt_valid)  irq_status[0] <= 1'b1;
        if (cmd_pushed) irq_status[1] <= 1'b1;
        if (!s_axi_aresetn) begin
            s_axi_awready <= 1'b0; s_axi_wready <= 1'b0; s_axi_bvalid <= 1'b0;
            aw_have <= 1'b0; w_have <= 1'b0; irq_status <= 2'b00; irq_enable <= 2'b00;
            stale_s <= 16'd60; wl_idx <= 6'd0; cmd_rd_count <= 32'd0; adm_data <= 128'h0;
            sec_tx <= 1'b0; sec_only <= 1'b1; sec_key <= 128'h0;
        end else begin
            // accept address and data independently, one transaction at a time
            s_axi_awready <= !aw_have && s_axi_awvalid && !s_axi_awready && !s_axi_bvalid;
            s_axi_wready  <= !w_have  && s_axi_wvalid  && !s_axi_wready  && !s_axi_bvalid;
            if (s_axi_awvalid && s_axi_awready) begin aw_addr <= s_axi_awaddr; aw_have <= 1'b1; end
            if (s_axi_wvalid && s_axi_wready)   begin w_data  <= s_axi_wdata;  w_have  <= 1'b1; end
            if (aw_have && w_have && !s_axi_bvalid) begin
                if (aw_addr[11:8] == 4'h0) case (aw_addr[7:2])
                    6'h01: begin                                                        // 0x004
                        send_now <= w_data[0];
                        soft_rst <= w_data[1];
                        if (w_data[1]) cmd_rd_count <= 32'd0;                           // the FIFO restarts too
                    end
                    6'h0C: irq_status <= irq_status & ~w_data[1:0];                     // 0x030, W1C
                    6'h0D: irq_enable <= w_data[1:0];                                   // 0x034
                    6'h0F: stale_s <= w_data[15:0];                                     // 0x03C
                    6'h10: wl_idx <= w_data[5:0];                                       // 0x040
                    6'h11: begin wl_wdata <= w_data; wl_we <= 1'b1; end                 // 0x044
                    6'h14: cmd_rd_count <= w_data;                                      // 0x050
                    6'h18: adm_data[31:0]   <= w_data;                                  // 0x060
                    6'h19: adm_data[63:32]  <= w_data;                                  // 0x064
                    6'h1A: adm_data[95:64]  <= w_data;                                  // 0x068
                    6'h1B: adm_data[127:96] <= w_data;                                  // 0x06C
                    6'h1C: adm_load <= w_data[0];                                       // 0x070
                    6'h21: begin tbl_del <= 1'b1; tbl_del_addr <= w_data[15:0]; end     // 0x084
                    6'h22: begin sec_tx <= w_data[0]; sec_only <= w_data[1]; rpl_clear <= w_data[2]; end // 0x088
                    6'h23: sec_key[127:96] <= bswap(w_data);                            // 0x08C KEY0
                    6'h24: sec_key[95:64]  <= bswap(w_data);                            // 0x090 KEY1
                    6'h25: sec_key[63:32]  <= bswap(w_data);                            // 0x094 KEY2
                    6'h26: sec_key[31:0]   <= bswap(w_data);                            // 0x098 KEY3
                    6'h27: begin ctr_val <= w_data; ctr_load <= 1'b1; end               // 0x09C
                    default: ;
                endcase
                aw_have <= 1'b0; w_have <= 1'b0; s_axi_bvalid <= 1'b1;
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
        end
    end

    // ---------------------------------------------------------------- AXI read channel
    // table reads need 2 clocks (set tbl_idx, then the table's registered output), registers answer the same way
    assign s_axi_rresp = 2'b00;
    reg [11:0] ar_addr = 12'h0;
    reg [1:0]  rd_state = 2'd0;                 // 0 idle, 1 index set, 2 data ready
    reg [127:0] shadow = 128'h0;                // copy of the entry (record + word 3) taken when word 0 is read
    reg [3:0]  shadow_idx = 4'd0;
    reg        shadow_ok = 1'b0;                // the copy is used until word 3 of that entry has been read
    wire       use_shadow = shadow_ok && (shadow_idx == ar_addr[7:4]);
    always @(posedge clk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 1'b0; s_axi_rvalid <= 1'b0; rd_state <= 2'd0;
        end else begin
            s_axi_arready <= 1'b0;
            case (rd_state)
                2'd0:
                    if (s_axi_arvalid && !s_axi_rvalid) begin
                        s_axi_arready <= 1'b1;
                        ar_addr  <= s_axi_araddr;
                        tbl_idx  <= (s_axi_araddr[11:8] == 4'h2) ? s_axi_araddr[5:2] : s_axi_araddr[7:4];
                        cmd_addr <= s_axi_araddr[10:2];
                        rd_state <= 2'd1;
                    end
                2'd1:
                    rd_state <= 2'd2;                       // tbl_rec is valid in the next clock
                2'd2: begin
                    if (ar_addr[11])                        // 0x800..0xFFF: the command FIFO
                        s_axi_rdata <= cmd_rd_data;
                    else if (ar_addr[11:8] == 4'h1) begin   // 0x100..0x1FF: the table
                        case (ar_addr[3:2])
                            2'd0: begin
                                s_axi_rdata <= tbl_rec[31:0];
                                shadow      <= {tbl_word3, tbl_rec};
                                shadow_idx  <= ar_addr[7:4];
                                shadow_ok   <= 1'b1;
                            end
                            2'd1: s_axi_rdata <= use_shadow ? shadow[63:32] : tbl_rec[63:32];
                            2'd2: s_axi_rdata <= use_shadow ? shadow[95:64] : tbl_rec[95:64];
                            2'd3: begin
                                s_axi_rdata <= use_shadow ? shadow[127:96] : tbl_word3;
                                shadow_ok   <= 1'b0;
                            end
                        endcase
                    end else if (ar_addr[11:8] == 4'h2)     // 0x200..0x23F VIA, 0x240..0x27F RDEV (v10), else 0
                        s_axi_rdata <= (ar_addr[7:6] == 2'b00) ? tbl_via : (ar_addr[7:6] == 2'b01) ? tbl_rdev : 32'h0;
                    else if (ar_addr[11:8] != 4'h0)
                        s_axi_rdata <= 32'h0;
                    else case (ar_addr[7:2])
                        6'h00: s_axi_rdata <= ID;
                        6'h02: s_axi_rdata <= {27'h0, table_count};
                        6'h03: s_axi_rdata <= frames_ok;
                        6'h04: s_axi_rdata <= dropped_addr;
                        6'h05: s_axi_rdata <= crc_errors;
                        6'h06: s_axi_rdata <= framing_errors;
                        6'h07: s_axi_rdata <= length_errors;
                        6'h08: s_axi_rdata <= timeout_errors;
                        6'h09: s_axi_rdata <= full_drops;
                        6'h0A: s_axi_rdata <= frames_sent;
                        6'h0C: s_axi_rdata <= {30'h0, irq_status};
                        6'h0D: s_axi_rdata <= {30'h0, irq_enable};
                        6'h0E: s_axi_rdata <= now_s;
                        6'h0F: s_axi_rdata <= {16'h0, stale_s};
                        6'h10: s_axi_rdata <= {26'h0, wl_idx};
                        6'h11: s_axi_rdata <= wl_rdata;
                        6'h12: s_axi_rdata <= {16'h0, fresh};
                        6'h13: s_axi_rdata <= cmd_wr_count;
                        6'h14: s_axi_rdata <= cmd_rd_count;
                        6'h15: s_axi_rdata <= cmd_overflows;
                        6'h16: s_axi_rdata <= cmds_ok;
                        6'h17: s_axi_rdata <= cmds_dropped;
                        6'h18: s_axi_rdata <= adm_data[31:0];
                        6'h19: s_axi_rdata <= adm_data[63:32];
                        6'h1A: s_axi_rdata <= adm_data[95:64];
                        6'h1B: s_axi_rdata <= adm_data[127:96];
                        6'h1C: s_axi_rdata <= {31'h0, adm_busy};
                        6'h1D: s_axi_rdata <= adm_sent;
                        6'h1E: s_axi_rdata <= relays_ok;
                        6'h1F: s_axi_rdata <= joins_ok;
                        6'h20: s_axi_rdata <= joins_limited;
                        6'h21: s_axi_rdata <= tbl_deletes;
                        6'h22: s_axi_rdata <= {30'h0, sec_only, sec_tx};
                        6'h27: s_axi_rdata <= dl_ctr;
                        6'h28: s_axi_rdata <= sec_ok;
                        6'h29: s_axi_rdata <= plain_ok;
                        6'h2A: s_axi_rdata <= plain_drop;
                        6'h2B: s_axi_rdata <= mic_fail;
                        6'h2C: s_axi_rdata <= replay_drop;
                        6'h2D: s_axi_rdata <= relay_dup;
                        6'h2E: s_axi_rdata <= e3_drop;
                        6'h2F: s_axi_rdata <= sec_sent;
                        6'h30: s_axi_rdata <= plain_sent;
                        6'h31: s_axi_rdata <= srx_overruns;
                        6'h32: s_axi_rdata <= relay_upg;
                        default: s_axi_rdata <= 32'h0;
                    endcase
                    s_axi_rvalid <= 1'b1;
                    rd_state     <= 2'd3;
                end
                default:
                    if (s_axi_rvalid && s_axi_rready) begin
                        s_axi_rvalid <= 1'b0;
                        rd_state     <= 2'd0;
                    end
            endcase
        end
    end
endmodule

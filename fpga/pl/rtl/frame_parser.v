// frame_parser.v - finds the gateway frames in the byte stream from uart_rx (A.T.A.K., Zybo Z7-20 PL).
//
// Frames (115200 8N1, from the gateway STM32), dispatched by LEN:
//   position: [0xAA][0x55][LEN=14][pos_packet_t 12 B][RSSI][SNR][CRC8]
//             pos_packet_t (little-endian): [0..1] addr, [2] seq, [3..6] lat, [7..10] lon, [11] flags
//   command:  [0xAA][0x55][LEN=17][cmd_packet_t 15 B][RSSI][SNR][CRC8]
//             cmd_packet_t: [0] type = 0xC1, [1..2] src, [3..4] dst (0xFFFF = all), [5] msg_id, [6] kind,
//             [7..10] lat, [11..14] lon
//             or a delete request: [0] type = 0xC2, [1..2] src (requester), [3..4] dst = 0xFFFE (admin), [5] msg_id,
//             [6] 0, [7..8] target_src, [9] target_msg_id, [10..14] 0   (same 15 bytes, only the type differs)
//             or a node's ACK of an admin command: [0] type = 0xC5, [1..2] src (the node), [3..4] dst = 0xFFFE,
//             [5] ack_seq, [6] kind (1 DELIVERED, 2 SEEN), [7..8] acked_src, [9] acked_msg_id, [10..14] 0
//             or a node leaving its team: [0] type = 0xA4, [1..2] src (the node), [3..4] dst = 0xFFFE, [5] msg_id,
//             [6..9] dev_id, [10..14] 0
//   relayed position (single-hop mesh): [0xAA][0x55][LEN=19][17 B][gw_RSSI][gw_SNR][CRC8]
//             [0] type = 0xE1, [1..2] relayer address, [3] relay_RSSI i8, [4] relay_SNR i8 (relayer <- far node),
//             [5..16] the far node's pos_packet_t unchanged; gw_RSSI / gw_SNR = the link relayer -> gateway
//   join request (provisioning): [0xAA][0x55][LEN=19][17 B][gw_RSSI][gw_SNR][CRC8], same LEN as 0xE1, told apart by
//             [0] type = 0xA1: [1..2] src = 0x0000 (not set up yet), [3..4] dst = 0xFFFE, [5] req_seq, [6..9] dev_id
//             (CRC32 of the STM32 UID), [10] team 1..26, [11] number 0..99, [12..13] PIN, [14] fw major, [15] fw minor,
//             [16] battery % (0xFF = unknown)
//   CRC8: polynomial 0x07, init 0x00, no reflection, no final XOR, over LEN .. SNR (not the sync bytes)
//
// Every frame ends with exactly one 1-clock strobe:
//   frame_ok (a position: addr..snr valid in the same clock, held until the next frame_ok / cmd_ok; for a relayed
//             position addr..flags = the far node, rssi / snr = gw link, relay = 1 + relayer / relay_rssi / relay_snr;
//             for a direct position relay = 0 and relayer / relay_rssi / relay_snr = 0), or
//   cmd_ok   (a command: cmd_rec = the 15 raw bytes, byte 0 in bits 7..0, bytes 15 / 16 = 0; addr = src; rssi / snr
//             valid; join = 0), or the same for a join request (cmd_rec = its 17 raw bytes, join = 1), or
//   crc_error, length_error (LEN not 14 / 17 / 19, a 17-byte frame that is not 0xC1 / 0xC2 / 0xC5, or a 19-byte
//   frame that is not 0xE1 / 0xA1) or timeout_error.
// After any error it hunts for 0xAA 0x55 again.
// Resync: "AA AA 55" is found (the second AA restarts the sync), and a LEN byte that is 0xAA counts as a length
// error but is used as the first sync byte of the next frame.
// Timeout: if a frame stops in the middle (no byte for TIMEOUT_CYC clocks) it is dropped, so a cut frame cannot
// swallow the start of the next one.
`timescale 1ns / 1ps
module frame_parser #(
    parameter integer TIMEOUT_CYC = 125_000    // 1 ms at 125 MHz (one byte takes 87 us at 115200)
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [7:0]   rx_data,
    input  wire         rx_valid,
    output reg          frame_ok      = 1'b0,
    output reg          cmd_ok        = 1'b0,
    output reg          crc_error     = 1'b0,
    output reg          length_error  = 1'b0,
    output reg          timeout_error = 1'b0,
    output reg  [15:0]  addr  = 16'h0000,      // position: node address / command: src
    output reg  [7:0]   seq   = 8'h00,
    output reg  [31:0]  lat   = 32'h0,
    output reg  [31:0]  lon   = 32'h0,
    output reg  [7:0]   flags = 8'h00,
    output reg  [7:0]   rssi  = 8'h00,         // int8, dBm
    output reg  [7:0]   snr   = 8'h00,         // int8, dB
    output reg  [135:0] cmd_rec = 136'h0,      // the command's 15 raw bytes (a join request: 17)
    output reg          is_join = 1'b0,         // the last command was a join request (0xA1)
    output reg          relay      = 1'b0,     // the last position came through a relay (0xE1)
    output reg  [15:0]  relayer    = 16'h0000, // the node that re-broadcast it
    output reg  [7:0]   relay_rssi = 8'h00,    // int8: how strongly the relayer heard the far node
    output reg  [7:0]   relay_snr  = 8'h00
);
    localparam [7:0] SYNC1 = 8'hAA, SYNC2 = 8'h55, POS_LEN = 8'd14, CMD_LEN = 8'd17, REL_LEN = 8'd19,
                     CMD_TYPE = 8'hC1, DEL_TYPE = 8'hC2, ACK_TYPE = 8'hC5, REL_TYPE = 8'hE1,
                     JOIN_TYPE = 8'hA1, LEAVE_TYPE = 8'hA4;
    localparam [2:0] S_SYNC1 = 3'd0, S_SYNC2 = 3'd1, S_LEN = 3'd2, S_BODY = 3'd3, S_CRC = 3'd4;
    localparam integer TW = $clog2(TIMEOUT_CYC + 1);

    // CRC-8, polynomial 0x07: one byte, MSB first
    function [7:0] crc8_byte(input [7:0] crc_in, input [7:0] d);
        integer i;
        reg [7:0] c;
        begin
            c = crc_in ^ d;
            for (i = 0; i < 8; i = i + 1)
                c = c[7] ? ((c << 1) ^ 8'h07) : (c << 1);
            crc8_byte = c;
        end
    endfunction

    reg [2:0]    state = S_SYNC1;
    reg [7:0]    crc   = 8'h00;
    reg [4:0]    idx   = 5'd0;                // byte number inside the LEN bytes (0..18)
    reg [7:0]    flen  = 8'd0;                // LEN of this frame: 14, 17 or 19
    reg [7:0]    body [0:18];
    reg [TW-1:0] idle  = 0;                   // clocks since the last byte
    integer      b;

    always @(posedge clk) begin
        frame_ok      <= 1'b0;
        cmd_ok        <= 1'b0;
        crc_error     <= 1'b0;
        length_error  <= 1'b0;
        timeout_error <= 1'b0;
        if (rst) begin
            state <= S_SYNC1;
            idle  <= 0;
        end else if (rx_valid) begin
            idle <= 0;
            case (state)
                S_SYNC1:
                    if (rx_data == SYNC1) state <= S_SYNC2;
                S_SYNC2:
                    if (rx_data == SYNC2)      state <= S_LEN;
                    else if (rx_data != SYNC1) state <= S_SYNC1;       // "AA AA": stay, the second AA may start it
                S_LEN:
                    if (rx_data == POS_LEN || rx_data == CMD_LEN || rx_data == REL_LEN) begin
                        crc    <= crc8_byte(8'h00, rx_data);
                        idx    <= 5'd0;
                        flen   <= rx_data;
                        state  <= S_BODY;
                    end else begin
                        length_error <= 1'b1;
                        state <= (rx_data == SYNC1) ? S_SYNC2 : S_SYNC1;
                    end
                S_BODY: begin
                    body[idx] <= rx_data;
                    crc       <= crc8_byte(crc, rx_data);
                    if (idx == flen - 1) state <= S_CRC;
                    else                 idx <= idx + 1'b1;
                end
                S_CRC: begin
                    if (rx_data != crc)
                        crc_error <= 1'b1;
                    else if (flen == POS_LEN) begin
                        frame_ok <= 1'b1;
                        addr  <= {body[1], body[0]};
                        seq   <= body[2];
                        lat   <= {body[6], body[5], body[4], body[3]};
                        lon   <= {body[10], body[9], body[8], body[7]};
                        flags <= body[11];
                        rssi  <= body[12];
                        snr   <= body[13];
                        relay <= 1'b0; relayer <= 16'h0000; relay_rssi <= 8'h00; relay_snr <= 8'h00;
                    end else if (flen == REL_LEN) begin
                        if (body[0] == REL_TYPE) begin
                            frame_ok   <= 1'b1;
                            relay      <= 1'b1;
                            relayer    <= {body[2], body[1]};
                            relay_rssi <= body[3];
                            relay_snr  <= body[4];
                            addr  <= {body[6], body[5]};
                            seq   <= body[7];
                            lat   <= {body[11], body[10], body[9], body[8]};
                            lon   <= {body[15], body[14], body[13], body[12]};
                            flags <= body[16];
                            rssi  <= body[17];
                            snr   <= body[18];
                        end else if (body[0] == JOIN_TYPE) begin
                            cmd_ok <= 1'b1;
                            is_join <= 1'b1;
                            addr   <= {body[2], body[1]};
                            for (b = 0; b < 17; b = b + 1) cmd_rec[8 * b +: 8] <= body[b];
                            rssi   <= body[17];
                            snr    <= body[18];
                        end else
                            length_error <= 1'b1;                           // 19 bytes but not 0xE1 / 0xA1
                    end else if (body[0] == CMD_TYPE || body[0] == DEL_TYPE || body[0] == ACK_TYPE || body[0] == LEAVE_TYPE) begin
                        cmd_ok <= 1'b1;
                        is_join <= 1'b0;
                        addr   <= {body[2], body[1]};                       // src: the whitelist key
                        for (b = 0; b < 15; b = b + 1) cmd_rec[8 * b +: 8] <= body[b];
                        cmd_rec[135:120] <= 16'h0000;
                        rssi   <= body[15];
                        snr    <= body[16];
                    end else
                        length_error <= 1'b1;                               // 17 bytes but not 0xC1 / 0xC2 / 0xC5 / 0xA4
                    state <= S_SYNC1;
                end
                default:
                    state <= S_SYNC1;
            endcase
        end else if (state != S_SYNC1) begin
            if (idle == TIMEOUT_CYC - 1) begin
                timeout_error <= 1'b1;
                state <= S_SYNC1;
                idle  <= 0;
            end else
                idle <= idle + 1'b1;
        end
    end
endmodule

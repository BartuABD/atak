// secure_tx.v - wraps every frame the Zybo sends in the secure envelope (A.T.A.K., Zybo Z7-20 PL, v9 security).
//
// Sits between the TX sources (downlink_frame_builder, admin_tx) and uart_tx, with the same valid / ready byte
// handshake on both sides. It takes one plain frame AA 55 LEN [payload LEN bytes] CRC8 and then sends:
//   secure_en = 1:  AA 55 (14+LEN) [tx_repeat] [0x51][FE FF FF FF][counter 4 LE][ciphertext LEN][MIC 4] CRC8
//                   dev_id 0xFFFFFFFE = the Zybo, dir = 0x01 in the nonce, counter = dl_ctr (+1 per frame).
//                   tx_repeat (read only by the gateway, never sent on the air) = 1 for the table (payload byte
//                   0 = 0xD1), 3 for everything else (C1 / C3 / A2 / A3): the gateway sends the same bytes again,
//                   the nodes take the first copy and drop the rest as replays.
//   secure_en = 0:  the frame unchanged (today's plain downlink), for the migration.
// The CRC8 (poly 0x07, init 0) covers LEN .. the last byte before it, the tx_repeat byte included.
// secure_en is taken when a frame has been collected (a frame is never half plain, half secure).
//
// dl_ctr must never repeat with the same key: Linux saves it on the SD card and at boot writes saved + 256 with
// ctr_load before secure_en is set (agreed with Aykut). It counts up by one for every secure frame.
`timescale 1ns / 1ps
module secure_tx (
    input  wire         clk,
    input  wire         rst,
    input  wire         secure_en,
    input  wire [127:0] key,
    input  wire         ctr_load,                      // one clock: dl_ctr = ctr_val
    input  wire [31:0]  ctr_val,
    output reg  [31:0]  dl_ctr = 32'd0,
    // from the TX sources
    input  wire [7:0]   in_data,
    input  wire         in_valid,
    output wire         in_ready,
    // to uart_tx
    output reg  [7:0]   out_data = 8'h00,
    output reg          out_valid = 1'b0,
    input  wire         out_ready,
    output wire         busy,                          // a frame is being collected, encrypted or sent
    output reg  [31:0]  sec_sent   = 32'd0,
    output reg  [31:0]  plain_sent = 32'd0
);
    localparam [7:0] SYNC1 = 8'hAA, SYNC2 = 8'h55, VER = 8'h51, TABLE_TYPE = 8'hD1;

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

    // the payload is collected straight into the CCM buffer at 9.., the envelope header is written in front of it
    reg          c_we = 1'b0, c_start = 1'b0;
    reg  [7:0]   c_wa = 8'h0, c_wd = 8'h0, c_ra = 8'h0, c_plen = 8'h0;
    wire [7:0]   c_rd;
    wire         c_done;
    ccm_core u_ccm (.clk(clk), .rst(rst), .wr_en(c_we), .wr_addr(c_wa), .wr_data(c_wd), .rd_addr(c_ra),
                    .rd_data(c_rd), .start(c_start), .enc(1'b1), .plen(c_plen), .dir(1'b1), .hdr13(1'b0), .key(key),
                    .busy(), .done(c_done), .mic_ok());

    localparam [2:0] S_IN = 3'd0, S_HDR = 3'd1, S_CCM = 3'd2, S_LOAD = 3'd3, S_SEND = 3'd4;
    reg [2:0]  st = S_IN;
    reg [7:0]  ii = 8'h0;                              // byte number of the incoming frame
    reg [7:0]  len = 8'h0, first = 8'h0;
    reg        sec = 1'b0;
    reg [3:0]  h = 4'd0;
    reg [31:0] ctr_used = 32'h0;
    // output: position e_i (0 AA, 1 55, 2 LEN, then [rep] if sec, then e_m data bytes from c_a0, then CRC)
    reg [7:0]  e_i = 8'h0, e_len = 8'h0, e_m = 8'h0, e_a0 = 8'h0, e_c = 8'h0;
    wire [7:0] e_d0  = sec ? 8'd4 : 8'd3;              // position of the first data byte
    wire [7:0] e_end = e_d0 + e_m;                     // position of the CRC

    assign in_ready = (st == S_IN);
    assign busy     = (st != S_IN) || (ii != 8'h0);

    always @(posedge clk) begin
        c_we <= 1'b0; c_start <= 1'b0;
        if (ctr_load) dl_ctr <= ctr_val;
        if (rst) begin
            st <= S_IN; ii <= 8'h0; out_valid <= 1'b0;
        end else case (st)
            S_IN:
                if (in_valid) begin                    // the sources only send whole, well-formed frames
                    if (ii == 8'd2) len <= in_data;
                    if (ii == 8'd3) first <= in_data;
                    if (ii >= 8'd3 && ii < len + 8'd3) begin
                        c_we <= 1'b1; c_wa <= ii + 8'd6; c_wd <= in_data;      // payload byte k -> buffer 9 + k
                    end
                    if (ii >= 8'd3 && ii == len + 8'd3) begin                  // the CRC byte: frame complete
                        ii  <= 8'h0;
                        sec <= secure_en;
                        if (secure_en) begin h <= 4'd0; st <= S_HDR; end
                        else begin
                            e_len <= len; e_m <= len; e_a0 <= 8'd9; e_i <= 8'h0; st <= S_LOAD;
                        end
                    end else
                        ii <= ii + 1'b1;
                end
            S_HDR: begin                               // buffer[0..8] = 51 FE FF FF FF ctr(LE)
                c_we <= 1'b1; c_wa <= {4'h0, h};
                case (h)
                    4'd0: c_wd <= VER;
                    4'd1: c_wd <= 8'hFE;
                    4'd2, 4'd3, 4'd4: c_wd <= 8'hFF;
                    4'd5: c_wd <= dl_ctr[7:0];
                    4'd6: c_wd <= dl_ctr[15:8];
                    4'd7: c_wd <= dl_ctr[23:16];
                    default: c_wd <= dl_ctr[31:24];
                endcase
                if (h == 4'd8) begin
                    ctr_used <= dl_ctr;
                    if (!ctr_load) dl_ctr <= dl_ctr + 1'b1;
                    st <= S_CCM;
                end
                h <= h + 1'b1;
            end
            S_CCM:
                if (!c_start && h == 4'd9) begin       // the last header byte is written: start
                    c_plen <= len; c_start <= 1'b1; h <= 4'd10;
                end else if (c_done) begin
                    e_len <= len + 8'd14; e_m <= len + 8'd13; e_a0 <= 8'd0; e_i <= 8'h0; st <= S_LOAD;
                end
            S_LOAD: begin                              // c_ra is set for this position; c_rd is valid next clock
                st <= S_SEND;
            end
            S_SEND: begin
                if (!out_valid) begin
                    out_valid <= 1'b1;
                    if (e_i == 8'd0)                 out_data <= SYNC1;
                    else if (e_i == 8'd1)            out_data <= SYNC2;
                    else if (e_i == 8'd2)            out_data <= e_len;
                    else if (sec && e_i == 8'd3)     out_data <= (first == TABLE_TYPE) ? 8'd1 : 8'd3;
                    else if (e_i < e_end)            out_data <= c_rd;
                    else                             out_data <= e_c;
                end else if (out_ready) begin          // byte taken
                    out_valid <= 1'b0;
                    e_c <= (e_i == 8'd2) ? crc8_byte(8'h00, out_data) :
                           (e_i > 8'd2)  ? crc8_byte(e_c, out_data) : e_c;
                    if (e_i == e_end) begin
                        st <= S_IN;
                        if (sec) sec_sent <= sec_sent + 1'b1; else plain_sent <= plain_sent + 1'b1;
                    end else begin
                        e_i <= e_i + 1'b1; st <= S_LOAD;
                    end
                end
            end
            default: st <= S_IN;
        endcase
    end

    always @(*) c_ra = e_a0 + (e_i - e_d0);            // the data byte for position e_i
endmodule

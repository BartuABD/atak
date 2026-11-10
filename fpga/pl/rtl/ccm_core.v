// ccm_core.v - AES-128-CCM for the A.T.A.K. secure envelope (Zybo Z7-20 PL, v9 security).
//
// Envelope (agreed with the node firmware), in the 256-byte buffer from address 0:
//   [0] 0x51  [1..4] dev_id u32 LE  [5..8] counter u32 LE  [9 .. 9+N-1] payload  [9+N .. 9+N+3] MIC
// or, with hdr13 = 1 (v10, a relay request naming its relayer):
//   [0] 0x52  [1..4] dev_id  [5..8] counter  [9..12] relay_dev u32 LE  [13 .. 13+N-1] payload  [13+N ..] MIC
//   AAD = buffer[0..12] (13 bytes: AAD block = 00 0D | buffer[0..12] | 00), nonce unchanged.
// CCM parameters (NIST SP 800-38C / RFC 3610): L = 2, tag 4 bytes,
//   nonce (13 B) = buffer[1..8] | dir | 00 00 00 00      (dir 0x00 = sent by a node, 0x01 = sent by the Zybo)
//   AAD          = buffer[0..8] (the header is readable but covered by the MIC)
//   B0 = 49 | nonce | 00 N      A_i = 01 | nonce | 00 i      AAD block = 00 09 | buffer[0..8] | 0 x 5
//
// Use: write the buffer (wr_en / wr_addr / wr_data) while not busy, then start for one clock with enc, plen = N,
// dir and key. When done is high (one clock):
//   enc = 1: the payload in the buffer is now ciphertext and the MIC is written at 9+N .. 9+N+3.
//   enc = 0: the payload in the buffer is now plaintext; mic_ok = 1 if the MIC was right. If mic_ok = 0 the
//            plaintext must not be used (it is not authentic).
// Read the buffer with rd_addr: rd_data is the byte one clock later (only while not busy).
// The key is taken at start. N may be 1 .. 243.
//
// Order: enc = MAC over the plaintext, then CTR (encrypt), then S0 -> MIC. enc = 0 = CTR (decrypt), then MAC over
// the plaintext, then S0 -> compare. Each 16-byte block: 17 clocks to read it, 11 for AES, 16 to write back (CTR).
// A 28-byte packet takes about 250 clocks (2.5 us at 100 MHz); one UART byte takes 87 us.
`timescale 1ns / 1ps
module ccm_core (
    input  wire         clk,
    input  wire         rst,
    input  wire         wr_en,
    input  wire [7:0]   wr_addr,
    input  wire [7:0]   wr_data,
    input  wire [7:0]   rd_addr,
    output reg  [7:0]   rd_data = 8'h00,
    input  wire         start,
    input  wire         enc,
    input  wire [7:0]   plen,
    input  wire         dir,
    input  wire         hdr13,                         // 1: 13-byte header (0x52), 0: 9-byte header (0x51)
    input  wire [127:0] key,
    output reg          busy = 1'b0,
    output reg          done = 1'b0,
    output reg          mic_ok = 1'b0
);
    // ---- packet buffer (simple dual port: one write, one synchronous read)
    reg [7:0] mem [0:255];
    reg       i_we = 1'b0;
    reg [7:0] i_wa = 8'h0, i_wd = 8'h0;
    wire [7:0] i_ra;
    always @(posedge clk) begin
        if (busy ? i_we : wr_en)
            mem[busy ? i_wa : wr_addr] <= busy ? i_wd : wr_data;
        rd_data <= mem[busy ? i_ra : rd_addr];
    end

    // ---- AES
    reg          a_start = 1'b0;
    reg  [127:0] a_din = 128'h0;
    reg  [127:0] k = 128'h0;
    wire         a_done;
    wire [127:0] a_dout;
    aes128_enc u_aes (.clk(clk), .rst(rst), .start(a_start), .key(k), .din(a_din), .busy(), .done(a_done),
                      .dout(a_dout));

    // ---- sequencer
    localparam [2:0] ST_IDLE = 3'd0, ST_GATH = 3'd1, ST_AES = 3'd2, ST_SCAT = 3'd3, ST_TAGW = 3'd4, ST_NEXT = 3'd5;
    localparam [3:0] PH_HDR = 4'd0, PH_START = 4'd1, PH_B0 = 4'd2, PH_AAD = 4'd3, PH_MACG = 4'd4, PH_MACE = 4'd5,
                     PH_CTRG = 4'd6, PH_CTRE = 4'd7, PH_CTRW = 4'd8, PH_S0 = 4'd9, PH_CMP = 4'd10, PH_FIN = 4'd11;
    reg [2:0]   st = ST_IDLE;
    reg [3:0]   ph = PH_HDR;
    reg         m_enc = 1'b0;
    reg [7:0]   n = 8'h0;
    reg [7:0]   d8 = 8'h0;
    reg [3:0]   i = 4'd0;                              // block index 0 .. nblk-1
    reg [103:0] hdr = 104'h0;                          // buffer[0..12] (bytes 9..12 = 0 for a 9-byte header)
    reg         m_h13 = 1'b0;
    reg [127:0] x = 128'h0;                            // CBC-MAC chain
    reg [127:0] s = 128'h0;                            // keystream block
    reg [127:0] blk = 128'h0;                          // gathered block (zero-padded)
    reg [31:0]  t = 32'h0;                             // MAC (first 4 bytes of the last X)
    reg [31:0]  tagv = 32'h0;                          // t ^ S0
    reg [8:0]   g_base = 9'h0, g_lim = 9'h0;           // block start address / first address past the data
    reg [4:0]   cnt = 5'd0;

    wire [8:0]   n15   = {1'b0, n} + 9'd15;            // 9 bits: no overflow for N > 240
    wire [4:0]   nblk  = n15[8:4];                     // N up to 243 -> 16 blocks
    wire [103:0] nonce = {hdr[95:32], d8, 32'h0};
    wire [127:0] b0    = {8'h49, nonce, 8'h00, n};
    wire [127:0] aadb  = m_h13 ? {16'h000D, hdr, 8'h0} : {16'h0009, hdr[103:32], 40'h0};
    wire [8:0]   pl_off   = m_h13 ? 9'd13 : 9'd9;      // first payload byte
    wire [8:0]   blk_base = pl_off + {i, 4'h0};
    wire [8:0]   end_pl   = pl_off + n;
    function [127:0] ctr_blk(input [7:0] idx);
        ctr_blk = {8'h01, nonce, 8'h00, idx};
    endfunction

    // gather: address cnt is read in clock cnt (0..15); its byte arrives in clock cnt + 1
    wire [8:0] g_rd  = g_base + cnt;
    wire [8:0] g_got = g_base + cnt - 1'b1;
    assign i_ra = g_rd[7:0];

    task go_gather(input [8:0] base, input [8:0] lim);
        begin g_base <= base; g_lim <= lim; cnt <= 5'd0; st <= ST_GATH; end
    endtask
    task go_aes(input [127:0] din);
        begin a_din <= din; a_start <= 1'b1; st <= ST_AES; end
    endtask

    always @(posedge clk) begin
        done    <= 1'b0;
        a_start <= 1'b0;
        i_we    <= 1'b0;
        if (rst) begin
            st   <= ST_IDLE;
            busy <= 1'b0;
        end else case (st)
            ST_IDLE:
                if (start) begin
                    m_enc  <= enc;
                    m_h13  <= hdr13;
                    n      <= plen;
                    d8     <= {7'h0, dir};
                    k      <= key;
                    i      <= 4'd0;
                    busy   <= 1'b1;
                    mic_ok <= 1'b0;
                    ph     <= PH_HDR;
                    go_gather(9'd0, hdr13 ? 9'd13 : 9'd9);
                end
            ST_GATH: begin
                if (cnt != 5'd0)
                    blk <= {blk[119:0], (g_got < g_lim) ? rd_data : 8'h00};
                if (cnt == 5'd16) st <= ST_NEXT;
                else              cnt <= cnt + 1'b1;
            end
            ST_AES:
                if (a_done) st <= ST_NEXT;
            ST_SCAT: begin                             // write back blk ^ s, only addresses before g_lim
                i_wa <= g_rd[7:0];
                i_wd <= blk[127:120] ^ s[127:120];
                i_we <= (g_rd < g_lim);
                blk  <= {blk[119:0], 8'h00};
                s    <= {s[119:0], 8'h00};
                if (cnt == 5'd15) st <= ST_NEXT;
                cnt  <= cnt + 1'b1;
            end
            ST_TAGW: begin                             // MIC bytes at 9+N .. 9+N+3
                i_wa    <= end_pl[7:0] + cnt[1:0];
                i_wd    <= tagv[31:24];
                i_we    <= 1'b1;
                tagv    <= {tagv[23:0], 8'h00};
                if (cnt == 5'd3) st <= ST_NEXT;
                cnt     <= cnt + 1'b1;
            end
            ST_NEXT: case (ph)
                PH_HDR: begin
                    hdr <= blk[127:24];                // bytes past the header are 0 (zero padded)
                    ph  <= PH_START;
                end
                PH_START:
                    if (!m_enc && nblk != 0) begin ph <= PH_CTRG; i <= 4'd0; go_gather(pl_off, end_pl); end
                    else                     begin ph <= PH_B0;   go_aes(b0); end
                PH_B0:   begin ph <= PH_AAD; go_aes(a_dout ^ aadb); end
                PH_AAD: begin
                    x <= a_dout;
                    if (nblk != 0) begin ph <= PH_MACG; i <= 4'd0; go_gather(pl_off, end_pl); end
                    else           begin t <= a_dout[127:96]; ph <= PH_S0; go_aes(ctr_blk(8'd0)); end
                end
                PH_MACG: begin ph <= PH_MACE; go_aes(x ^ blk); end
                PH_MACE: begin
                    x <= a_dout;
                    if ({1'b0, i} + 1'b1 < nblk) begin
                        i <= i + 1'b1; ph <= PH_MACG; go_gather(blk_base + 9'd16, end_pl);
                    end else begin
                        t <= a_dout[127:96];
                        if (m_enc) begin ph <= PH_CTRG; i <= 4'd0; go_gather(pl_off, end_pl); end
                        else       begin ph <= PH_S0; go_aes(ctr_blk(8'd0)); end
                    end
                end
                PH_CTRG: begin ph <= PH_CTRE; go_aes(ctr_blk({4'h0, i} + 8'd1)); end
                PH_CTRE: begin
                    s <= a_dout; ph <= PH_CTRW;
                    g_base <= blk_base; g_lim <= end_pl; cnt <= 5'd0; st <= ST_SCAT;
                end
                PH_CTRW:
                    if ({1'b0, i} + 1'b1 < nblk) begin
                        i <= i + 1'b1; ph <= PH_CTRG; go_gather(blk_base + 9'd16, end_pl);
                    end else if (m_enc) begin ph <= PH_S0; go_aes(ctr_blk(8'd0)); end
                    else                begin ph <= PH_B0; go_aes(b0); end   // decrypted: now the MAC
                PH_S0: begin
                    tagv <= t ^ a_dout[127:96];
                    if (m_enc) begin ph <= PH_FIN; cnt <= 5'd0; st <= ST_TAGW; end
                    else       begin ph <= PH_CMP; go_gather(end_pl, end_pl + 9'd4); end
                end
                PH_CMP: begin
                    mic_ok <= (blk[127:96] == tagv);
                    busy <= 1'b0; done <= 1'b1; st <= ST_IDLE;
                end
                default: begin                         // PH_FIN
                    busy <= 1'b0; done <= 1'b1; st <= ST_IDLE;
                end
            endcase
            default: st <= ST_IDLE;
        endcase
    end
endmodule

// secure_rx.v - checks and unwraps the secure envelope in front of frame_parser (A.T.A.K., Zybo Z7-20 PL, v9).
//
// Byte stream in (from uart_rx), byte stream out (to frame_parser). It collects one gateway frame
// AA 55 LEN [LEN bytes] CRC8 and then sends on the OLD PLAIN frame, so frame_parser, the whitelist, the table and
// the command FIFO stay unchanged:
//
//   secure frame (body[0] = 0x51, LEN >= 16, the MIC verifies and the counter is new for that dev_id):
//     body = [secure packet: 0x51, dev_id, counter, ciphertext N, MIC] [gw RSSI] [gw SNR]
//     -> AA 55 (N+2) [plaintext N] [RSSI] [SNR] CRC8              (position 14, command 17, join request 19)
//   nested E1 (inner type 0xE1, N = 30): [E1][relayer 2][relay RSSI][relay SNR][far node's secure packet 25 B]
//     the far node's packet is checked too (MIC + its own counter: if it was already heard directly, its counter
//     is used = a duplicate, dropped) -> the old relay frame AA 55 13 [E1 relayer rssi snr][far pos 12 B] RSSI SNR
//   nested E2 (inner type 0xE2, N = 33): the same with a 28-byte control packet inside
//     -> AA 55 11 [the far node's 15-byte command] RSSI SNR  (src = the far node, as the gateway sent it before)
//   v10: a packet that requests a relay may use version 0x52 = a 13-byte header with relay_dev (the relayer the
//     node chose) in bytes 9..12, inside the AAD. Accepted directly and as the far node's packet in E1 / E2 (the
//     nested sizes grow by 4: E1 N = 34, E2 N = 37). fwd_rdev = relay_dev of the last frame sent on (0 = none /
//     0x51), held until the next one: the table stores it next to the position.
//   v11: a position can arrive twice, directly and inside an E1. The FIRST copy on each path of a node's NEWEST
//     counter is sent on (the second one with fwd_upg = 1 = "merge", relay_upg + 1, also sec_ok): the location table
//     then ORs the copies, so flags bit 2 = a relayed copy arrived and bit 7 = a direct copy arrived for that seq.
//     Further copies stay duplicates (relay_dup / replay_drop, see replay_window.v). Commands are never merged.
//   inner type 0xE3 (N != 12): a relayer repeating our own downlink -> dropped
//   anything else is PLAIN: sent on unchanged when secure_only = 0, dropped when secure_only = 1. A frame with
//   body[0] = 0x51 whose MIC fails counts as mic_fail and is then handled as plain (a plain position can start with
//   0x51 = an address low byte, but it is only 12 bytes).
//   Frames with a bad CRC, a bad LEN or cut off in the middle are sent on as they are, so frame_parser still counts
//   crc / length / timeout errors.
//
// The frame is sent on after the check (about 10 us for a nested frame; one UART byte takes 87 us), one byte per clock.
`timescale 1ns / 1ps
module secure_rx #(
    parameter integer TIMEOUT_CYC = 100_000,           // 1 ms at 100 MHz: a frame that stops in the middle
    parameter integer RPL_ENTRIES = 64
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [7:0]   in_data,
    input  wire         in_valid,
    input  wire         secure_only,
    input  wire [127:0] key,
    input  wire         tbl_clear,                     // empty the replay table
    output reg  [7:0]   out_data  = 8'h00,
    output reg          out_valid = 1'b0,
    output reg  [31:0]  sec_ok      = 32'd0,           // secure frames sent on (nested: counted once)
    output reg  [31:0]  plain_ok    = 32'd0,           // plain frames sent on (secure_only = 0)
    output reg  [31:0]  plain_drop  = 32'd0,           // plain frames dropped (secure_only = 1)
    output reg  [31:0]  mic_fail    = 32'd0,           // MIC wrong (outer or inner)
    output reg  [31:0]  replay_drop = 32'd0,           // counter already used / too old (direct or relayer)
    output reg  [31:0]  relay_dup   = 32'd0,           // relayed copy of a frame already heard (inner counter used)
    output reg  [31:0]  relay_upg   = 32'd0,           // v11: 2nd copies of a position (other path) sent on as merge
    output reg  [31:0]  e3_drop     = 32'd0,           // our own downlink relayed back
    output reg  [31:0]  overruns    = 32'd0,           // a frame ended while the last one was still being handled
    output reg  [31:0]  fwd_rdev    = 32'd0,           // v10: chosen relayer (relay_dev) of the last frame sent on
    output reg          fwd_upg     = 1'b0             // v11: the last frame sent on is a 2nd copy (merge into table)
);
    localparam [7:0] VER2 = 8'h52;
    localparam [7:0] SYNC1 = 8'hAA, SYNC2 = 8'h55, VER = 8'h51;

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

    // ================= receiver: one frame into rb =================
    localparam [2:0] R_SYNC1 = 3'd0, R_SYNC2 = 3'd1, R_LEN = 3'd2, R_BODY = 3'd3, R_CRC = 3'd4;
    localparam integer TW = $clog2(TIMEOUT_CYC + 1);
    reg [7:0]    rb [0:255];
    reg [2:0]    rs = R_SYNC1;
    reg [7:0]    rlen = 8'h0, rcnt = 8'h0, rcrc = 8'h0;
    reg [TW-1:0] ridle = 0;
    reg [31:0]   h_dev = 32'h0, h_ctr = 32'h0;         // body[1..4], body[5..8] (little-endian)
    reg [7:0]    h_first = 8'h0;
    reg [31:0]   h_rdev = 32'h0;                       // body[9..12] (relay_dev of a 0x52 packet)
    reg [15:0]   h_last2 = 16'h0;                      // the last two body bytes (gateway RSSI, SNR)
    // frame ready: kind 1 = full frame (f_crc_ok, f_crc), kind 2 = only the first f_cnt bytes (bad LEN / cut off)
    reg          f_rdy = 1'b0;
    reg [1:0]    f_kind = 2'd0;
    reg [7:0]    f_len = 8'h0, f_cnt = 8'h0, f_crc = 8'h0;
    reg          f_crc_ok = 1'b0;
    reg [31:0]   f_dev = 32'h0, f_ctr = 32'h0;
    reg [7:0]    f_first = 8'h0;
    reg [7:0]    f_rssi = 8'h0, f_snr = 8'h0;
    reg [31:0]   f_rdev = 32'h0;
    reg          p_busy;                               // the processor below is handling a frame

    always @(posedge clk) begin
        f_rdy <= 1'b0;
        if (rst) begin
            rs <= R_SYNC1; ridle <= 0;
        end else if (in_valid) begin
            ridle <= 0;
            case (rs)
                R_SYNC1: if (in_data == SYNC1) rs <= R_SYNC2;
                R_SYNC2: if (in_data == SYNC2) rs <= R_LEN; else if (in_data != SYNC1) rs <= R_SYNC1;
                R_LEN:
                    if (in_data == 8'd14 || (in_data >= 8'd16 && in_data <= 8'd250 && in_data != SYNC1)) begin
                        rlen <= in_data; rcnt <= 8'h0; rcrc <= crc8_byte(8'h00, in_data); rs <= R_BODY;
                    end else begin                     // bad LEN: send AA 55 LEN on, frame_parser counts it
                        f_rdy <= 1'b1; f_kind <= 2'd2; f_len <= in_data; f_cnt <= 8'h0;
                        rs <= (in_data == SYNC1) ? R_SYNC2 : R_SYNC1;
                    end
                R_BODY: begin
                    rb[rcnt] <= in_data;
                    rcrc <= crc8_byte(rcrc, in_data);
                    if (rcnt == 8'd0) h_first <= in_data;
                    if (rcnt >= 8'd1 && rcnt <= 8'd4) h_dev <= {in_data, h_dev[31:8]};
                    if (rcnt >= 8'd5 && rcnt <= 8'd8) h_ctr <= {in_data, h_ctr[31:8]};
                    if (rcnt >= 8'd9 && rcnt <= 8'd12) h_rdev <= {in_data, h_rdev[31:8]};
                    h_last2 <= {h_last2[7:0], in_data};
                    if (rcnt == rlen - 1'b1) rs <= R_CRC;
                    rcnt <= rcnt + 1'b1;
                end
                R_CRC: begin
                    f_rdy <= 1'b1; f_kind <= 2'd1; f_len <= rlen; f_cnt <= rlen;
                    f_crc <= in_data; f_crc_ok <= (in_data == rcrc);
                    f_dev <= h_dev; f_ctr <= h_ctr; f_first <= h_first; f_rdev <= h_rdev;
                    f_rssi <= h_last2[15:8]; f_snr <= h_last2[7:0];
                    rs <= R_SYNC1;
                end
                default: rs <= R_SYNC1;
            endcase
        end else if (rs != R_SYNC1) begin
            if (ridle == TIMEOUT_CYC - 1) begin        // cut off: send what came, frame_parser times out itself
                ridle <= 0;
                rs <= R_SYNC1;
                if (rs == R_BODY || rs == R_CRC) begin
                    f_rdy <= 1'b1; f_kind <= 2'd2; f_len <= rlen; f_cnt <= rcnt;
                end
            end else
                ridle <= ridle + 1'b1;
        end
    end

    reg [7:0] rb_ra = 8'h0, rb_rd = 8'h0;
    always @(posedge clk) rb_rd <= rb[rb_ra];

    // ================= output buffer ob =================
    reg [7:0] ob [0:255];
    reg       ob_we = 1'b0;
    reg [7:0] ob_wa = 8'h0, ob_wd = 8'h0, ob_rd = 8'h0;
    wire [7:0] ob_ra;
    always @(posedge clk) begin
        if (ob_we) ob[ob_wa] <= ob_wd;
        ob_rd <= ob[ob_ra];
    end

    // ================= CCM and replay window =================
    reg          c_we = 1'b0, c_start = 1'b0;
    reg  [7:0]   c_wa = 8'h0, c_wd = 8'h0, c_ra = 8'h0, c_plen = 8'h0;
    reg          c_h13 = 1'b0;
    wire [7:0]   c_rd;
    wire         c_done, c_ok;
    ccm_core u_ccm (.clk(clk), .rst(rst), .wr_en(c_we), .wr_addr(c_wa), .wr_data(c_wd), .rd_addr(c_ra),
                    .rd_data(c_rd), .start(c_start), .enc(1'b0), .plen(c_plen), .dir(1'b0), .hdr13(c_h13), .key(key),
                    .busy(), .done(c_done), .mic_ok(c_ok));

    reg          w_check = 1'b0, w_rel = 1'b0;
    reg  [31:0]  w_dev = 32'h0, w_ctr = 32'h0;
    wire         w_done, w_ok, w_upg;
    replay_window #(.ENTRIES(RPL_ENTRIES)) u_win (.clk(clk), .rst(rst), .clear(tbl_clear), .check(w_check),
                    .dev_id(w_dev), .counter(w_ctr), .relayed(w_rel), .busy(), .done(w_done), .ok(w_ok),
                    .upg(w_upg));

    // ================= processor =================
    localparam [3:0] P_IDLE = 4'd0, P_COPY = 4'd1, P_NEXT = 4'd2, P_CCM = 4'd3, P_WIN = 4'd4, P_TYPE = 4'd5,
                     P_EMIT = 4'd6, P_PUT = 4'd7;
    // what to do after a copy / ccm / window step
    localparam [3:0] A_FWD = 4'd0, A_DEC1 = 4'd1, A_CHK1 = 4'd2, A_TYPE = 4'd3, A_DIRECT = 4'd4, A_NEST = 4'd5,
                     A_DEC2 = 4'd6, A_CHK2 = 4'd7, A_OUT2 = 4'd8, A_GOT1 = 4'd9, A_EMITC = 4'd10, A_PLAIN = 4'd11;
    reg [3:0]  ps = P_IDLE, act = A_FWD;
    initial p_busy = 1'b0;

    // copy engine: n bytes from (rb or ccm) + sa to (ob or ccm) + da; byte j is read in clock j, written in j+1
    reg        cp_src = 1'b0, cp_dst = 1'b0;           // 0 = rb / ob, 1 = ccm
    reg [7:0]  cp_sa = 8'h0, cp_da = 8'h0, cp_n = 8'h0, cp_j = 8'h0;
    wire [7:0] cp_rd = cp_src ? c_rd : rb_rd;

    reg [7:0]  len = 8'h0, n = 8'h0;                   // frame LEN, payload length N
    reg [7:0]  g_rssi = 8'h0, g_snr = 8'h0, ty = 8'h0, ilen = 8'h0;
    reg [31:0] i_dev = 32'h0, i_ctr = 32'h0;           // the far node's header (nested)
    reg [7:0]  i_first = 8'h0;
    reg [31:0] i_rdev = 32'h0;                         // the far node's relay_dev (0x52)
    reg [7:0]  p_off = 8'd9;                           // first payload byte in the CCM buffer: 9 (0x51) / 13 (0x52)
    reg [31:0] p_rdev = 32'h0, rq_rdev = 32'h0;        // relay_dev of the outer packet / of the frame being sent
    reg        rq_upg = 1'b0;                          // the frame being sent is a 2nd copy
    reg [7:0]  fcrc = 8'h0;
    reg        nest_e2 = 1'b0;
    // emitter: AA 55 e_len ob[0 .. e_n-1] and then CRC (e_crc: 0 none, 1 computed, 2 = e_crcv)
    reg [7:0]  e_len = 8'h0, e_n = 8'h0, e_crcv = 8'h0, e_i = 8'h0, e_c = 8'h0;
    reg [1:0]  e_crc = 2'd0;
    reg        e_sub = 1'b0;
    reg [1:0]  put_n = 2'd0;                           // P_PUT: writes RSSI / SNR after ob[e_n-2]
    reg        p_full = 1'b0;                          // the frame came complete (with its CRC byte)
    assign ob_ra = e_i - 8'd3;

    task copy(input s, input [7:0] sa, input d, input [7:0] da, input [7:0] cnt, input [3:0] then);
        begin
            cp_src <= s; cp_sa <= sa; cp_dst <= d; cp_da <= da; cp_n <= cnt; cp_j <= 8'h0;
            act <= then; ps <= P_COPY;
        end
    endtask
    task emit(input [7:0] l, input [7:0] cnt, input [1:0] cm, input [7:0] cv);
        begin
            e_len <= l; e_n <= cnt; e_crc <= cm; e_crcv <= cv; e_i <= 8'h0; e_sub <= 1'b0;
            e_c <= crc8_byte(8'h00, l); ps <= P_EMIT;
        end
    endtask

    always @(*) begin
        rb_ra = cp_sa + cp_j;
        c_ra  = (ps == P_COPY) ? cp_sa + cp_j : p_off;
    end

    always @(posedge clk) begin
        out_valid <= 1'b0;
        c_we <= 1'b0; c_start <= 1'b0; ob_we <= 1'b0; w_check <= 1'b0;
        if (rst) begin
            ps <= P_IDLE; p_busy <= 1'b0;
        end else begin
            if (f_rdy && p_busy) overruns <= overruns + 1'b1;
            case (ps)
                P_IDLE:
                    if (f_rdy) begin
                        p_busy <= 1'b1;
                        len <= f_len; fcrc <= f_crc; p_full <= (f_kind == 2'd1);
                        g_rssi <= f_rssi; g_snr <= f_snr;
                        if (f_kind == 2'd2)                                        // bad LEN / cut off
                            copy(1'b0, 8'h0, 1'b0, 8'h0, f_cnt, A_FWD);
                        else if (!f_crc_ok)                                        // bad CRC
                            copy(1'b0, 8'h0, 1'b0, 8'h0, f_len, A_FWD);
                        else if ((f_first == VER && f_len >= 8'd16) ||
                                 (f_first == VER2 && f_len >= 8'd20)) begin        // looks secure
                            n <= f_len - ((f_first == VER2) ? 8'd19 : 8'd15);
                            c_h13 <= (f_first == VER2);
                            p_off <= (f_first == VER2) ? 8'd13 : 8'd9;
                            p_rdev <= (f_first == VER2) ? f_rdev : 32'h0;
                            w_dev <= f_dev; w_ctr <= f_ctr; w_rel <= 1'b0;
                            copy(1'b0, 8'h0, 1'b1, 8'h0, f_len - 8'd2, A_DEC1);
                        end else begin
                            act <= A_PLAIN; ps <= P_NEXT;
                        end
                        e_n <= f_cnt;                                              // for A_FWD
                    end
                P_COPY: begin
                    if (cp_j != 8'h0) begin
                        if (cp_dst) begin c_we <= 1'b1; c_wa <= cp_da + cp_j - 1'b1; c_wd <= cp_rd; end
                        else        begin ob_we <= 1'b1; ob_wa <= cp_da + cp_j - 1'b1; ob_wd <= cp_rd; end
                        if (cp_src && cp_dst) begin                                // nested: far node's header
                            if (cp_j == 8'd1) i_first <= cp_rd;
                            if (cp_j >= 8'd2 && cp_j <= 8'd5) i_dev <= {cp_rd, i_dev[31:8]};
                            if (cp_j >= 8'd6 && cp_j <= 8'd9) i_ctr <= {cp_rd, i_ctr[31:8]};
                            if (cp_j >= 8'd10 && cp_j <= 8'd13) i_rdev <= {cp_rd, i_rdev[31:8]};
                        end
                    end
                    if (cp_j == cp_n) ps <= P_NEXT;
                    else              cp_j <= cp_j + 1'b1;
                end
                P_CCM: if (c_done) ps <= P_NEXT;
                P_WIN: if (w_done) ps <= P_NEXT;
                P_TYPE: begin ty <= c_rd; act <= A_TYPE; ps <= P_NEXT; end        // c_rd = ccm[p_off]
                P_PUT: begin                                                       // RSSI, SNR after the data
                    ob_we <= 1'b1;
                    ob_wa <= e_n - 8'd2 + put_n;
                    ob_wd <= put_n[0] ? g_snr : g_rssi;
                    if (put_n[0]) begin act <= A_EMITC; ps <= P_NEXT; end
                    put_n <= put_n + 1'b1;
                end
                P_EMIT: begin
                    if (!e_sub)                        // ob_ra = e_i - 3: ob_rd is valid in the next clock
                        e_sub <= 1'b1;
                    else begin
                        e_sub <= 1'b0;
                        out_valid <= 1'b1;
                        e_i <= e_i + 1'b1;
                        if (e_i == 8'd0)      out_data <= SYNC1;
                        else if (e_i == 8'd1) out_data <= SYNC2;
                        else if (e_i == 8'd2) out_data <= e_len;
                        else if (e_i < e_n + 8'd3) begin
                            out_data <= ob_rd; e_c <= crc8_byte(e_c, ob_rd);
                        end else
                            out_data <= (e_crc == 2'd1) ? e_c : e_crcv;
                        if ((e_crc == 2'd0 && e_i == e_n + 8'd2) || (e_crc != 2'd0 && e_i == e_n + 8'd3)) begin
                            ps <= P_IDLE; p_busy <= 1'b0;
                        end
                    end
                end
                P_NEXT: case (act)
                    A_FWD: begin                                                   // send rb as it came
                        emit(len, e_n, p_full ? 2'd2 : 2'd0, fcrc);
                        fwd_rdev <= 32'h0; fwd_upg <= 1'b0;
                    end
                    A_PLAIN:
                        if (secure_only) begin plain_drop <= plain_drop + 1'b1; ps <= P_IDLE; p_busy <= 1'b0; end
                        else begin plain_ok <= plain_ok + 1'b1; e_n <= len; copy(1'b0, 8'h0, 1'b0, 8'h0, len, A_FWD); end
                    A_DEC1: begin
                        c_plen <= n; c_start <= 1'b1; act <= A_CHK1; ps <= P_CCM;
                    end
                    A_CHK1:
                        if (!c_ok) begin
                            mic_fail <= mic_fail + 1'b1;
                            act <= A_PLAIN; ps <= P_NEXT;
                        end else begin
                            w_check <= 1'b1; act <= A_GOT1; ps <= P_WIN;
                        end
                    A_GOT1:                                                        // after the outer replay check
                        if (!w_ok && !(w_upg && n == 8'd12)) begin                 // (v11: direct 2nd copy of a position)
                            replay_drop <= replay_drop + 1'b1; ps <= P_IDLE; p_busy <= 1'b0;
                        end
                        else ps <= P_TYPE;                                         // c_ra = p_off -> c_rd = type
                    A_TYPE:
                        if (n != 8'd12 && ty == 8'hE3) begin
                            e3_drop <= e3_drop + 1'b1; ps <= P_IDLE; p_busy <= 1'b0;
                        end else if ((ty == 8'hE1 && (n == 8'd30 || n == 8'd34)) ||
                                     (ty == 8'hE2 && (n == 8'd33 || n == 8'd37))) begin  // far packet 0x51 / 0x52
                            nest_e2 <= (ty == 8'hE2);
                            ilen <= n - 8'd5;                                      // the far node's secure packet
                            copy(1'b1, p_off, 1'b0, 8'd0, 8'd5, A_NEST);           // ob[0..4] = E1 relayer rssi snr
                        end else begin
                            e_n <= n + 8'd2;
                            rq_rdev <= p_rdev;
                            rq_upg <= !w_ok;
                            if (!w_ok) relay_upg <= relay_upg + 1'b1;              // v11: merge (direct copy)
                            copy(1'b1, p_off, 1'b0, 8'd0, n, A_DIRECT);
                        end
                    A_DIRECT: begin put_n <= 2'd0; ps <= P_PUT; sec_ok <= sec_ok + 1'b1; end
                    A_NEST:   copy(1'b1, p_off + 8'd5, 1'b1, 8'd0, ilen, A_DEC2);  // ccm[0..] = far packet
                    A_DEC2:                                                        // far packet: 0x51 25 / 0x52 29 B
                        if (!((i_first == VER && ilen == 8'd25) || (i_first == VER && ilen == 8'd28) ||
                              (i_first == VER2 && ilen == 8'd29) || (i_first == VER2 && ilen == 8'd32))) begin
                            mic_fail <= mic_fail + 1'b1; ps <= P_IDLE; p_busy <= 1'b0;
                        end else begin
                            c_h13 <= (i_first == VER2);
                            p_off <= (i_first == VER2) ? 8'd13 : 8'd9;             // the far packet's payload
                            c_plen <= ilen - ((i_first == VER2) ? 8'd17 : 8'd13);
                            c_start <= 1'b1; act <= A_CHK2; ps <= P_CCM;
                        end
                    A_CHK2:
                        if (!c_ok) begin mic_fail <= mic_fail + 1'b1; ps <= P_IDLE; p_busy <= 1'b0; end
                        else begin
                            w_dev <= i_dev; w_ctr <= i_ctr; w_rel <= 1'b1;                 // inside a relayed frame
                            w_check <= 1'b1; act <= A_OUT2; ps <= P_WIN;
                        end
                    A_OUT2:
                        if (!w_ok && !(w_upg && !nest_e2)) begin
                            relay_dup <= relay_dup + 1'b1; ps <= P_IDLE; p_busy <= 1'b0;
                        end else if (nest_e2) begin                                    // the far node's command
                            e_n <= c_plen + 8'd2;
                            rq_rdev <= c_h13 ? i_rdev : 32'h0;
                            rq_upg <= 1'b0;
                            copy(1'b1, p_off, 1'b0, 8'd0, c_plen, A_DIRECT);
                        end else begin                                             // after E1 relayer rssi snr
                            if (!w_ok) relay_upg <= relay_upg + 1'b1;              // v11: merge (relayed copy)
                            e_n <= 8'd5 + c_plen + 8'd2;
                            rq_rdev <= c_h13 ? i_rdev : 32'h0;
                            rq_upg <= !w_ok;
                            copy(1'b1, p_off, 1'b0, 8'd5, c_plen, A_DIRECT);
                        end
                    A_EMITC: begin emit(e_n, e_n, 2'd1, 8'h00); fwd_rdev <= rq_rdev; fwd_upg <= rq_upg; end
                    default: begin ps <= P_IDLE; p_busy <= 1'b0; end
                endcase
                default: begin ps <= P_IDLE; p_busy <= 1'b0; end
            endcase
        end
    end
endmodule

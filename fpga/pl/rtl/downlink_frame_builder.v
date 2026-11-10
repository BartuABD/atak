// downlink_frame_builder.v - every PERIOD_CYC clocks sends the location table to the gateway STM32 (A.T.K. downlink).
//
// UART frame (bytes back to back into uart_tx):
//   [AA][55][LEN][D1][N][record (12 B)] ... [record][CRC8]      LEN = 2 + 12 * N
//   CRC8: polynomial 0x07, init 0x00, no reflection, no final XOR, over LEN .. last record (not the sync bytes)
// The LoRa payload the nodes receive is [D1][N][records]. Records are sent exactly as stored (raw uplink bytes).
//
// Only FRESH entries are sent (fresh[i] = 1: entry i is in use and was heard recently, see location_table).
// A stale node stays in the table (Linux can still read it) but is left out of the broadcast; N counts only the
// fresh ones. N = 0: nothing is sent.
// The fresh mask is taken once at the start of a frame. Each record is read whole into rec_buf before its first
// byte goes out, so a table update during the frame never mixes two versions of one record.
// "start" (one clock) sends a frame now; it is ignored while a frame is going out.
// "hold" (from the TX arbiter in atk_server): a period tick or start that comes while hold = 1 is remembered and the
// frame starts as soon as hold = 0. "req" = a frame is waiting to start (or starts in this clock). Tie hold to 0
// when the builder owns uart_tx alone.
`timescale 1ns / 1ps
module downlink_frame_builder #(
    parameter integer ENTRIES    = 16,
    parameter integer PERIOD_CYC = 1_250_000_000      // 10 s at 125 MHz
) (
    input  wire                         clk,
    input  wire                         rst,
    input  wire                         start,
    input  wire                         hold,
    output wire                         req,
    // location table read port (rd_rec arrives one clock after rd_idx)
    input  wire [ENTRIES-1:0]           fresh,
    output reg  [$clog2(ENTRIES)-1:0]   rd_idx = 0,
    input  wire [95:0]                  rd_rec,
    // to uart_tx
    output reg  [7:0]                   tx_data = 8'h00,
    output reg                          tx_valid = 1'b0,
    input  wire                         tx_ready,
    // status
    output wire                         busy,
    output reg  [31:0]                  frames_sent = 32'd0
);
    localparam integer NW = $clog2(ENTRIES + 1);
    localparam integer IW = $clog2(ENTRIES);
    localparam integer PW = $clog2(PERIOD_CYC);
    localparam [2:0] S_IDLE = 3'd0, S_HEAD = 3'd1, S_FIND = 3'd2, S_FETCH1 = 3'd3, S_FETCH2 = 3'd4, S_REC = 3'd5,
                     S_CRC = 3'd6;

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

    function [NW-1:0] popcount(input [ENTRIES-1:0] v);
        integer i;
        begin
            popcount = 0;
            for (i = 0; i < ENTRIES; i = i + 1) popcount = popcount + v[i];
        end
    endfunction

    // period timer
    reg [PW-1:0] timer = 0;
    wire tick = (timer == PERIOD_CYC - 1);
    always @(posedge clk)
        if (rst || tick) timer <= 0;
        else             timer <= timer + 1'b1;

    wire [NW-1:0] n_fresh = popcount(fresh);

    reg [2:0]         state = S_IDLE;
    reg [NW-1:0]      n     = 0;              // records in this frame
    reg [NW-1:0]      sent  = 0;              // records already sent
    reg [ENTRIES-1:0] mask  = 0;              // fresh entries, taken at the start of the frame
    reg [IW-1:0]      cur   = 0;              // table index being looked at / sent
    reg [3:0]         byte_i = 4'd0;
    reg [95:0]        rec_buf = 96'h0;
    reg [7:0]         crc = 8'h00;
    wire              accepted = tx_valid && tx_ready;     // uart_tx takes tx_data in this clock

    reg               want  = 1'b0;           // a tick / start came while hold was 1
    assign busy = (state != S_IDLE);
    assign req  = (state == S_IDLE) && (want || tick || start);

    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            tx_valid <= 1'b0;
            want     <= 1'b0;
        end else case (state)
            S_IDLE:
                if (req && hold)
                    want <= 1'b1;
                else if (req) begin
                    want <= 1'b0;
                    if (n_fresh != 0) begin
                        n        <= n_fresh;
                        mask     <= fresh;
                        sent     <= 0;
                        cur      <= 0;
                        crc      <= 8'h00;
                        byte_i   <= 4'd0;
                        tx_data  <= 8'hAA;
                        tx_valid <= 1'b1;
                        state    <= S_HEAD;
                    end
                end
            S_HEAD:                                       // AA 55 LEN D1 N
                if (accepted) begin
                    if (byte_i >= 4'd2) crc <= crc8_byte(crc, tx_data);     // LEN, D1, N are in the CRC
                    byte_i <= byte_i + 1'b1;
                    case (byte_i)
                        4'd0: tx_data <= 8'h55;
                        4'd1: tx_data <= 8'd2 + 8'd12 * n;                   // LEN (n <= 21 -> fits a byte)
                        4'd2: tx_data <= 8'hD1;
                        4'd3: tx_data <= n;
                        default: begin                    // N went out: look for the first fresh entry
                            tx_valid <= 1'b0;
                            state    <= S_FIND;
                        end
                    endcase
                end
            S_FIND:                                       // skip stale / unused entries (one per clock)
                if (mask[cur]) begin
                    rd_idx <= cur;
                    state  <= S_FETCH1;
                end else
                    cur <= cur + 1'b1;
            S_FETCH1:                                     // the table reads rd_idx in this clock
                state <= S_FETCH2;
            S_FETCH2: begin                               // rd_rec is valid now
                rec_buf  <= rd_rec;
                tx_data  <= rd_rec[7:0];
                tx_valid <= 1'b1;
                byte_i   <= 4'd0;
                state    <= S_REC;
            end
            S_REC:
                if (accepted) begin
                    crc <= crc8_byte(crc, tx_data);
                    if (byte_i == 4'd11) begin
                        if (sent == n - 1) begin          // last byte of the last record: the CRC is next
                            tx_data <= crc8_byte(crc, tx_data);
                            state   <= S_CRC;
                        end else begin
                            tx_valid <= 1'b0;
                            sent     <= sent + 1'b1;
                            cur      <= cur + 1'b1;
                            state    <= S_FIND;
                        end
                    end else begin
                        byte_i  <= byte_i + 1'b1;
                        tx_data <= rec_buf[8 * (byte_i + 1) +: 8];
                    end
                end
            S_CRC:
                if (accepted) begin
                    tx_valid    <= 1'b0;
                    frames_sent <= frames_sent + 1'b1;
                    state       <= S_IDLE;
                end
            default:
                state <= S_IDLE;
        endcase
    end
endmodule

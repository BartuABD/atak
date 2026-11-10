// admin_tx.v - sends one admin frame (Zybo -> gateway), A.T.A.K.:
//   [AA][55][LEN=0x0F][15 B payload][CRC8]      19 bytes; CRC8 (poly 0x07, init 0) over LEN .. last payload byte
// Used for the 0xC3 ADMIN DECISION packet; the PL does not look inside the payload (the PS fills all 15 bytes).
//
// The PS writes the payload, then pulses "load": the frame is pending until the TX arbiter (atk_server) gives the
// line with "go" (one clock); it is then sent byte by byte into uart_tx. "load" while a frame is pending or going
// out is ignored (the PS waits for busy = 0 first). sent counts the frames that went out completely.
`timescale 1ns / 1ps
module admin_tx (
    input  wire         clk,
    input  wire         rst,
    input  wire         load,
    input  wire [119:0] payload,                    // byte 0 in bits 7..0
    output reg          pending = 1'b0,             // loaded, waiting for go
    input  wire         go,
    output wire         sending,
    output wire         busy,                       // pending or sending
    output reg  [31:0]  sent = 32'd0,
    // to uart_tx
    output reg  [7:0]   tx_data = 8'h00,
    output reg          tx_valid = 1'b0,
    input  wire         tx_ready
);
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

    reg [119:0] frame_buf = 120'h0;                 // payload; shifted out from bits 7..0
    reg [119:0] next_buf  = 120'h0;                 // copy taken at load
    reg [4:0]   i   = 5'd0;                         // byte now on tx_data: 0 AA, 1 55, 2 LEN, 3..17 payload, 18 CRC
    reg [7:0]   crc = 8'h00;
    reg         active = 1'b0;
    wire        accepted = tx_valid && tx_ready;

    assign sending = active;
    assign busy    = pending || active;

    always @(posedge clk) begin
        if (rst) begin
            pending  <= 1'b0;
            active   <= 1'b0;
            tx_valid <= 1'b0;
            sent     <= 32'd0;
        end else if (!active) begin
            if (load && !pending) begin
                next_buf <= payload;
                pending  <= 1'b1;
            end else if (go && pending) begin
                pending   <= 1'b0;
                active    <= 1'b1;
                frame_buf <= next_buf;
                crc       <= 8'h00;
                i         <= 5'd0;
                tx_data   <= 8'hAA;
                tx_valid  <= 1'b1;
            end
        end else if (accepted) begin
            if (i >= 5'd2) crc <= crc8_byte(crc, tx_data);              // LEN and the payload are in the CRC
            i <= i + 1'b1;
            if (i == 5'd0)
                tx_data <= 8'h55;
            else if (i == 5'd1)
                tx_data <= 8'h0F;
            else if (i <= 5'd16) begin                                    // next payload byte
                tx_data   <= frame_buf[7:0];
                frame_buf <= frame_buf >> 8;
            end else if (i == 5'd17)
                tx_data <= crc8_byte(crc, tx_data);                       // CRC including the last payload byte
            else begin                                                    // the CRC went out
                tx_valid <= 1'b0;
                active   <= 1'b0;
                sent     <= sent + 1'b1;
            end
        end
    end
endmodule

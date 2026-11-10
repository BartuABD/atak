// cmd_fifo.v - ring buffer of accepted 0xC1 commands for the PS (A.T.A.K. PL server), in one block RAM.
//
// Entry k (k = 0 .. DEPTH-1) is 8 words of 32 bits (32 bytes), word address 8*k + w:
//   w0..w3  the raw bytes 0..15 (byte 0 = type in bits 7..0 of w0); a 15-byte command has byte 15 = 0,
//           a 17-byte join request (0xA1) has its byte 15 here and byte 16 in w7
//   w4      {16'h0, SNR i8, RSSI i8}
//   w5      now_s when the command arrived (seconds since power-on)
//   w6      sequence number = the value of wr_count before this entry (0, 1, 2, ...)
//   w7      {24'h0, byte 16} (0 for a 15-byte command)
// wr_count counts every stored command (it only grows; entry of command n is n mod DEPTH). The PS writes rd_count =
// how many commands it has consumed. If wr_count - rd_count == DEPTH the buffer is full: a NEW command is dropped and
// overflows + 1 (the PS has not lost anything it had not yet read).
// Read port for the PS: rd_addr (word address) -> rd_data one clock later.
// A command is written in 8 clocks; commands arrive >= 1.7 ms apart (21 bytes at 115200), so they never overlap.
`timescale 1ns / 1ps
module cmd_fifo #(
    parameter integer DEPTH = 64                    // entries (power of 2)
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         push,                       // one clock: store this command
    input  wire [135:0] cmd_rec,
    input  wire [7:0]   rssi,
    input  wire [7:0]   snr,
    input  wire [31:0]  now_s,
    input  wire [31:0]  rd_count,                   // from the PS
    output reg  [31:0]  wr_count  = 32'd0,
    output reg  [31:0]  overflows = 32'd0,
    output wire         pushed,                     // one clock when an entry has been completely written
    input  wire [$clog2(DEPTH*8)-1:0] rd_addr,
    output reg  [31:0]  rd_data = 32'h0
);
    localparam integer AW = $clog2(DEPTH * 8);
    localparam integer EW = $clog2(DEPTH);

    (* ram_style = "block" *) reg [31:0] mem [0:DEPTH*8-1];

    reg [255:0] entry = 256'h0;                     // the 8 words being written
    reg [2:0]   w = 3'd0;
    reg         writing = 1'b0, done = 1'b0;
    reg [EW-1:0] slot = 0;

    wire full = (wr_count - rd_count) >= DEPTH;

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst) begin
            wr_count  <= 32'd0;
            overflows <= 32'd0;
            writing   <= 1'b0;
        end else if (writing) begin
            mem[{slot, w}] <= entry[32 * w +: 32];
            if (w == 3'd7) begin
                writing  <= 1'b0;
                wr_count <= wr_count + 1'b1;
                done     <= 1'b1;
            end
            w <= w + 1'b1;
        end else if (push) begin
            if (full)
                overflows <= overflows + 1'b1;
            else begin
                entry   <= {24'h0, cmd_rec[135:128], wr_count, now_s, 16'h0, snr, rssi, cmd_rec[127:0]};
                slot    <= wr_count[EW-1:0];
                w       <= 3'd0;
                writing <= 1'b1;
            end
        end
    end
    assign pushed = done;

    always @(posedge clk) rd_data <= mem[rd_addr];
endmodule

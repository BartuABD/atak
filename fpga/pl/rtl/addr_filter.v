// addr_filter.v - whitelist of node addresses in a block RAM (A.T.K., Zybo Z7-20 PL).
//
// One 32-bit word per entry: bit 16 = entry in use, bits 15..0 = node address. Unused words are 0, so address
// 0x0000 is only accepted if an entry really holds it with bit 16 set.
// 32-bit words so the same RAM can later get a second port for an AXI BRAM Controller (Linux edits the list).
//
// Use: a 1-clock "check" with addr -> some clocks later a 1-clock "done" with "accept" (1 = in the list).
// Linear scan, 2 clocks per entry: 64 entries = at most 130 clocks (1 us at 125 MHz); frames come every ~1.5 ms.
// A "check" while busy is ignored (the parser cannot give two frames that close together).
`timescale 1ns / 1ps
module addr_filter #(
    parameter integer ENTRIES   = 64,
    parameter         INIT_FILE = "whitelist.mem"   // 64 lines of 8 hex digits, e.g. 0001157C
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        check,
    input  wire [15:0] addr,
    output reg         done   = 1'b0,
    output reg         accept = 1'b0,
    output wire        busy,
    // second port (the PS, over AXI): read / change one entry at run time; wl_rdata = mem[wl_idx] one clock later.
    // Tie wl_we to 0 when not used.
    input  wire                        wl_we,
    input  wire [$clog2(ENTRIES)-1:0]  wl_idx,
    input  wire [31:0]                 wl_wdata,
    output reg  [31:0]                 wl_rdata = 32'h0
);
    localparam integer AW = $clog2(ENTRIES);
    localparam [1:0] S_IDLE = 2'd0, S_READ = 2'd1, S_CMP = 2'd2;

    (* ram_style = "block" *) reg [31:0] mem [0:ENTRIES-1];
    initial $readmemh(INIT_FILE, mem);

    reg [1:0]    state = S_IDLE;
    reg [AW-1:0] idx   = 0;
    reg [15:0]   key   = 16'h0000;
    reg [31:0]   word  = 32'h0;

    always @(posedge clk) word <= mem[idx];        // synchronous read = block RAM (port A: the scan)

    always @(posedge clk) begin                    // port B: the PS (true dual-port block RAM)
        if (wl_we) mem[wl_idx] <= wl_wdata;
        wl_rdata <= mem[wl_idx];
    end

    assign busy = (state != S_IDLE);

    always @(posedge clk) begin
        done   <= 1'b0;
        if (rst) begin
            state <= S_IDLE;
            idx   <= 0;
        end else case (state)
            S_IDLE:
                if (check) begin
                    key   <= addr;
                    idx   <= 0;
                    state <= S_READ;
                end
            S_READ:                                 // mem[idx] arrives in word at the end of this clock
                state <= S_CMP;
            S_CMP:
                if (word[16] && word[15:0] == key) begin
                    done   <= 1'b1;
                    accept <= 1'b1;
                    state  <= S_IDLE;
                end else if (idx == ENTRIES - 1) begin
                    done   <= 1'b1;
                    accept <= 1'b0;
                    state  <= S_IDLE;
                end else begin
                    idx   <= idx + 1'b1;
                    state <= S_READ;
                end
            default:
                state <= S_IDLE;
        endcase
    end
endmodule

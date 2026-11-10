// location_table.v - "who is where": the last position record of every node that sent an ACCEPTED frame
// (A.T.K. server in the Zybo PL). Read by the downlink frame builder and, through the second port, by the PS.
//
// Entry = the 12 payload bytes exactly as received (pos_packet_t, little-endian), byte 0 in rec[7:0]:
//   [0..1] addr, [2] seq, [3..6] lat, [7..10] lon, [11] flags.  The key is addr = {byte 1, byte 0}.
// Per entry the table also keeps meta = {SNR, RSSI} of the last frame, last_seen = now_s when it was heard and
// via = {relay_SNR, relay_RSSI, relayer} of the last frame (0 = heard directly; every update overwrites it), and
// (v10) rdev = the relayer the node CHOSE (relay_dev of its 0x52 packet, 0 = none), also overwritten every update.
// On "upd" (one clock, from an accepted frame; the table has changed 3 clocks later; next upd >= 3 clocks later):
//   addr already in the table -> that entry is overwritten, or with upd_merge = 1 (v11: the 2nd copy of the same
//                                packet on the other path, direct / relayed) MERGED: flags bits 2 and 7 are ORed
//                                with the stored ones, and meta / via / rdev come from the relayed copy (a direct
//                                2nd copy keeps the stored relay info)
//   new addr and a free entry  -> added at the end (entries 0 .. count-1 are always the used ones)
//   new addr and the table full -> ignored, full_drops + 1
// fresh[i] = 1: entry i is in use and was heard less than stale_s seconds ago (stale_s = 0: never stale).
// Stale entries stay in the table; the downlink builder leaves them out. A stale node that is heard again becomes
// fresh again (same slot).
// On "del" (one clock, from the PS: a node was kicked / left its team) the entry with address del_addr is removed:
// the last entry moves into its slot and count - 1 (entries 0 .. count-1 stay the used ones), deletes + 1. It waits
// while an update is in progress (done 2..5 clocks after del). An address that is not in the table changes nothing.
// The addresses are kept in registers so all of them are compared in ONE clock; the records sit in a small RAM.
// Read ports: rd_idx -> rd_rec, rd2_idx -> rd2_rec / rd2_meta / rd2_last, all one clock later.
`timescale 1ns / 1ps
module location_table #(
    parameter integer ENTRIES = 16                // at most 21 (2 + 12 * 21 = 254 bytes, LoRa max 255)
) (
    input  wire                           clk,
    input  wire                           rst,
    input  wire                           upd,
    input  wire [95:0]                    upd_rec,
    input  wire [15:0]                    upd_meta,     // {SNR, RSSI} of this frame
    input  wire [31:0]                    upd_via,      // {relay_SNR, relay_RSSI, relayer}, 0 = direct
    input  wire [31:0]                    upd_rdev,     // chosen relayer (dev_id), 0 = none
    input  wire                           upd_merge,    // v11: 2nd copy of the stored packet (see above)
    input  wire [31:0]                    now_s,        // seconds counter
    input  wire [15:0]                    stale_s,      // 0 = never stale
    input  wire [$clog2(ENTRIES)-1:0]     rd_idx,
    output reg  [95:0]                    rd_rec = 96'h0,
    input  wire [$clog2(ENTRIES)-1:0]     rd2_idx,      // second read port (the PS, over AXI); same timing
    output reg  [95:0]                    rd2_rec = 96'h0,
    output reg  [15:0]                    rd2_meta = 16'h0,
    output reg  [31:0]                    rd2_last = 32'h0,
    output reg  [31:0]                    rd2_via = 32'h0,
    output reg  [31:0]                    rd2_rdev = 32'h0,
    output reg  [ENTRIES-1:0]             fresh = 0,
    output reg  [$clog2(ENTRIES+1)-1:0]   count = 0,
    output reg  [31:0]                    full_drops = 32'd0,
    input  wire                           del,          // one clock: remove the node del_addr
    input  wire [15:0]                    del_addr,
    output reg  [31:0]                    deletes = 32'd0
);
    localparam integer IW = $clog2(ENTRIES);

    reg [15:0] addrs [0:ENTRIES-1];
    reg [95:0] recs  [0:ENTRIES-1];
    reg [15:0] metas [0:ENTRIES-1];
    reg [31:0] lasts [0:ENTRIES-1];
    reg [31:0] vias  [0:ENTRIES-1];
    reg [31:0] rdevs [0:ENTRIES-1];
    integer k;
    initial for (k = 0; k < ENTRIES; k = k + 1) begin
        addrs[k] = 16'h0; recs[k] = 96'h0; metas[k] = 16'h0; lasts[k] = 32'h0; vias[k] = 32'h0; rdevs[k] = 32'h0;
    end

    // which used entry has this address (all compared at once)
    wire [15:0] key = upd_rec[15:0];
    reg          hit;
    reg [IW-1:0] hit_idx;
    always @* begin
        hit     = 1'b0;
        hit_idx = 0;
        for (k = 0; k < ENTRIES; k = k + 1)
            if (!hit && k < count && addrs[k] == key) begin
                hit     = 1'b1;
                hit_idx = k[IW-1:0];
            end
    end

    // three clocks per update: clock 1 registers the search result, clock 2 reads the stored entry (for a merge),
    // clock 3 writes. (Search and write in one clock missed 125 MHz by 0.4 ns; updates come >= 1.5 ms apart, so the
    // extra clocks cost nothing.)
    reg          upd_d = 1'b0, hit_d = 1'b0, mrg_d = 1'b0;
    reg [IW-1:0] hit_idx_d = 0;
    reg [95:0]   rec_d = 96'h0;
    reg [15:0]   meta_d = 16'h0;
    reg [31:0]   via_d = 32'h0, rdev_d = 32'h0;
    always @(posedge clk) begin
        via_d     <= upd_via;
        rdev_d    <= upd_rdev;
        upd_d     <= upd && !rst;
        hit_d     <= hit;
        hit_idx_d <= hit_idx;
        rec_d     <= upd_rec;
        meta_d    <= upd_meta;
        mrg_d     <= upd_merge;
    end
    reg          upd_e = 1'b0, hit_e = 1'b0, mrg_e = 1'b0;
    reg [IW-1:0] hit_idx_e = 0;
    reg [95:0]   rec_e = 96'h0;
    reg [15:0]   meta_e = 16'h0, o_meta = 16'h0;
    reg [31:0]   via_e = 32'h0, rdev_e = 32'h0, o_via = 32'h0;
    reg [7:0]    o_flags = 8'h0;
    always @(posedge clk) begin
        upd_e     <= upd_d && !rst;
        hit_e     <= hit_d;
        hit_idx_e <= hit_idx_d;
        rec_e     <= rec_d;
        meta_e    <= meta_d;
        via_e     <= via_d;
        rdev_e    <= rdev_d;
        mrg_e     <= mrg_d && hit_d;
        o_flags   <= recs[hit_idx_d][95:88];
        o_meta    <= metas[hit_idx_d];
        o_via     <= vias[hit_idx_d];
    end
    // what is written: a merge ORs flags bits 2 / 7; a relayed 2nd copy brings its meta / via, a direct one keeps them
    wire        w_relayed = via_e != 32'h0;
    wire [95:0] w_rec  = mrg_e ? {rec_e[95:88] | (o_flags & 8'h84), rec_e[87:0]} : rec_e;
    wire [15:0] w_meta = (mrg_e && !w_relayed) ? o_meta : meta_e;
    wire [31:0] w_via  = (mrg_e && !w_relayed) ? o_via  : via_e;

    // delete: the entry with del_key (all compared at once), done when no update is in progress
    reg          del_pend = 1'b0;
    reg [15:0]   del_key = 16'h0;
    reg          dhit;
    reg [IW-1:0] dhit_idx;
    always @* begin
        dhit     = 1'b0;
        dhit_idx = 0;
        for (k = 0; k < ENTRIES; k = k + 1)
            if (!dhit && k < count && addrs[k] == del_key) begin
                dhit     = 1'b1;
                dhit_idx = k[IW-1:0];
            end
    end
    wire [IW-1:0] last   = count[IW-1:0] - 1'b1;        // the last used entry (count >= 1 when dhit)
    // pipelined (one clock in one go missed 100 MHz by 0.9 ns): every clock the search result and the last entry are
    // registered; the move uses them one clock later, only if the table did not change in that clock (no write at
    // upd_d one clock ago, none now) and the key was already set one clock ago
    reg          dhit_r = 1'b0, del_seen = 1'b0, upd_ee = 1'b0;
    reg [IW-1:0] dhit_idx_r = 0;
    reg [15:0]   mv_addr = 16'h0, mv_meta = 16'h0;
    reg [95:0]   mv_rec = 96'h0;
    reg [31:0]   mv_last = 32'h0, mv_via = 32'h0, mv_rdev = 32'h0;
    always @(posedge clk) begin
        dhit_r     <= dhit;
        dhit_idx_r <= dhit_idx;
        mv_addr    <= addrs[last];
        mv_rec     <= recs[last];
        mv_meta    <= metas[last];
        mv_last    <= lasts[last];
        mv_via     <= vias[last];
        mv_rdev    <= rdevs[last];
        upd_ee     <= upd_e;
        del_seen   <= del_pend && !del;
    end
    wire          del_go = del_pend && del_seen && !upd && !upd_d && !upd_e && !upd_ee;

    wire [IW-1:0] wr_idx = hit_e ? hit_idx_e : count[IW-1:0];
    wire          wr_ok  = upd_e && (hit_e || count < ENTRIES);

    always @(posedge clk) begin
        rd_rec   <= recs[rd_idx];
        rd2_rec  <= recs[rd2_idx];
        rd2_meta <= metas[rd2_idx];
        rd2_last <= lasts[rd2_idx];
        rd2_via  <= vias[rd2_idx];
        rd2_rdev <= rdevs[rd2_idx];
        if (rst) begin
            count      <= 0;
            full_drops <= 32'd0;
            deletes    <= 32'd0;
            del_pend   <= 1'b0;
        end else begin
            if (del) begin
                del_pend <= 1'b1;
                del_key  <= del_addr;
            end else if (del_go) begin
                del_pend <= 1'b0;
                if (dhit_r) begin                    // the last entry fills the gap
                    addrs[dhit_idx_r] <= mv_addr;
                    recs[dhit_idx_r]  <= mv_rec;
                    metas[dhit_idx_r] <= mv_meta;
                    lasts[dhit_idx_r] <= mv_last;
                    vias[dhit_idx_r]  <= mv_via;
                    rdevs[dhit_idx_r] <= mv_rdev;
                    count   <= count - 1'b1;
                    deletes <= deletes + 1'b1;
                end
            end
            if (wr_ok) begin
                recs[wr_idx]  <= w_rec;
                metas[wr_idx] <= w_meta;
                lasts[wr_idx] <= now_s;
                vias[wr_idx]  <= w_via;
                rdevs[wr_idx] <= rdev_e;
                if (!hit_e) begin
                    addrs[wr_idx] <= rec_e[15:0];
                    count <= count + 1'b1;
                end
            end else if (upd_e)
                full_drops <= full_drops + 1'b1;
        end
    end

    // fresh mask, registered (one clock behind; the builder takes it once per frame)
    always @(posedge clk)
        for (k = 0; k < ENTRIES; k = k + 1)
            fresh[k] <= !rst && (k < count) && (stale_s == 0 || (now_s - lasts[k]) < stale_s);
endmodule

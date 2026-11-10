// replay_window.v - replay protection for the secure envelope (A.T.A.K., Zybo Z7-20 PL, v9 security).
//
// One entry per sender (dev_id): the highest counter accepted so far ("last") and a 32-bit bitmap of the counters
// last, last-1, .. last-31 that were already accepted (bit 0 = last). A frame is accepted if its counter is new:
//   counter > last                 -> accepted, the window slides up (last = counter)
//   last-31 <= counter <= last     -> accepted only if its bit is not set yet (a late frame, e.g. through a relay)
//   counter < last-31              -> dropped (too old)
//   an unknown dev_id              -> accepted, gets an entry (a free one, else the next one round-robin)
// Same 32-frame window as the node firmware (agreed with Aykut). Call it only AFTER the MIC was checked, so a
// forged frame can never change the table.
//
// v11: each entry also remembers on which PATHS its newest counter arrived: ldir (a direct copy) and lrel (a copy
// inside a relayed frame). A check whose counter is exactly that newest counter, on a path not seen yet, gives
// ok = 0 and upg = 1, and marks that path. secure_rx then passes this copy on as a "merge", so the location table
// ends up with flags bit 2 (a relayed copy arrived) AND bit 7 (a direct copy arrived) for that seq. A second copy on
// the same path or an older counter stays a plain duplicate (upg = 0). Late (older) counters do not touch ldir / lrel.
//
// check (one clock, while not busy) with dev_id / counter -> done one clock high with ok. The table is searched one
// entry every 2 clocks (at most 2 * ENTRIES + 4 clocks; frames come at most every few ms). clear empties the table.
`timescale 1ns / 1ps
module replay_window #(
    parameter integer ENTRIES = 64
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        clear,
    input  wire        check,
    input  wire [31:0] dev_id,
    input  wire [31:0] counter,
    input  wire        relayed,                        // v11: this copy came inside a relayed frame (else direct)
    output reg         busy = 1'b0,
    output reg         done = 1'b0,
    output reg         ok   = 1'b0,
    output reg         upg  = 1'b0                     // v11: newest counter, first copy on this path (see above)
);
    localparam integer IW = $clog2(ENTRIES);
    reg [31:0]        devs  [0:ENTRIES-1];
    reg [31:0]        lasts [0:ENTRIES-1];
    reg [31:0]        bms   [0:ENTRIES-1];
    reg [ENTRIES-1:0] vld = {ENTRIES{1'b0}};
    reg [ENTRIES-1:0] lrel = {ENTRIES{1'b0}};          // the newest counter came through a relay
    reg [ENTRIES-1:0] ldir = {ENTRIES{1'b0}};          // the newest counter came directly
    integer k;
    initial for (k = 0; k < ENTRIES; k = k + 1) begin devs[k] = 32'h0; lasts[k] = 32'h0; bms[k] = 32'h0; end

    reg [31:0]   q_dev = 32'h0, q_ctr = 32'h0;
    reg [IW-1:0] idx = 0, free_idx = 0, rr = 0;
    reg          free_found = 1'b0;
    // pipelined (timing): each step is registered. Per entry: S_RD reads it, S_CMP compares the dev_id; a hit
    // then goes S_CALC (subtractions) -> S_APPLY (shift + write). At most 2 * ENTRIES + 4 clocks.
    localparam [2:0] S_IDLE = 3'd0, S_RD = 3'd1, S_CMP = 3'd2, S_CALC = 3'd3, S_APPLY = 3'd4;
    reg [2:0]    st = S_IDLE;
    reg [31:0]   r_dev = 32'h0, r_last = 32'h0, r_bm = 32'h0;
    reg          r_vld = 1'b0, r_lrel = 1'b0, r_ldir = 1'b0, q_rel = 1'b0;
    reg          c_up = 1'b0, c_far = 1'b0;            // counter above last / more than 31 away
    reg [4:0]    c_d = 5'd0;                           // the distance when it is less than 32

    always @(posedge clk) begin
        done <= 1'b0;
        if (rst || clear) begin
            vld  <= {ENTRIES{1'b0}};
            busy <= 1'b0;
            rr   <= 0;
            st   <= S_IDLE;
        end else case (st)
            S_IDLE:
                if (check) begin
                    q_dev <= dev_id; q_ctr <= counter; q_rel <= relayed; upg <= 1'b0;
                    idx <= 0; free_found <= 1'b0;
                    busy <= 1'b1; st <= S_RD;
                end
            S_RD: begin
                r_dev <= devs[idx]; r_vld <= vld[idx]; r_last <= lasts[idx]; r_bm <= bms[idx]; r_lrel <= lrel[idx]; r_ldir <= ldir[idx];
                st <= S_CMP;
            end
            S_CMP:
                if (r_vld && r_dev == q_dev)           // known sender
                    st <= S_CALC;
                else begin
                    if (!r_vld && !free_found) begin free_idx <= idx; free_found <= 1'b1; end
                    if (idx == ENTRIES - 1) begin      // not in the table: new sender
                        if (!free_found && r_vld) begin
                            devs[rr] <= q_dev; lasts[rr] <= q_ctr; bms[rr] <= 32'h1; lrel[rr] <= q_rel; ldir[rr] <= !q_rel;
                            rr <= rr + 1'b1;
                        end else begin
                            devs[free_found ? free_idx : idx]  <= q_dev;
                            lasts[free_found ? free_idx : idx] <= q_ctr;
                            bms[free_found ? free_idx : idx]   <= 32'h1;
                            vld[free_found ? free_idx : idx]   <= 1'b1;
                            lrel[free_found ? free_idx : idx]  <= q_rel;
                            ldir[free_found ? free_idx : idx]  <= !q_rel;
                        end
                        ok <= 1'b1; done <= 1'b1; busy <= 1'b0; st <= S_IDLE;
                    end else begin
                        idx <= idx + 1'b1; st <= S_RD;
                    end
                end
            S_CALC: begin
                c_up  <= q_ctr > r_last;
                c_far <= (q_ctr > r_last) ? (q_ctr - r_last >= 32) : (r_last - q_ctr >= 32);
                c_d   <= (q_ctr > r_last) ? q_ctr[4:0] - r_last[4:0] : r_last[4:0] - q_ctr[4:0];
                st    <= S_APPLY;
            end
            S_APPLY: begin
                if (c_up) begin                        // newer: the window slides up
                    lasts[idx] <= q_ctr;
                    bms[idx]   <= c_far ? 32'h1 : ((r_bm << c_d) | 32'h1);
                    lrel[idx]  <= q_rel;
                    ldir[idx]  <= !q_rel;
                    ok <= 1'b1;
                end else if (!c_far && !r_bm[c_d]) begin   // late but inside the window and not seen yet
                    bms[idx] <= r_bm | (32'h1 << c_d);
                    ok <= 1'b1;
                end else begin
                    ok <= 1'b0;                        // replay or too old
                    if (!c_far && c_d == 5'd0) begin   // = the newest counter: first copy on this path?
                        if (q_rel && !r_lrel)  begin upg <= 1'b1; lrel[idx] <= 1'b1; end
                        if (!q_rel && !r_ldir) begin upg <= 1'b1; ldir[idx] <= 1'b1; end
                    end
                end
                done <= 1'b1; busy <= 1'b0; st <= S_IDLE;
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule

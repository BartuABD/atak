// tb_location_table.sv - self-checking testbench for location_table (16 entries).
// A model in the testbench (an associative array addr -> record, plus the order of first appearance) is updated the
// same way; after every test all used entries are read back through the read port and compared with the model.
// Tests: 1 two real nodes (A = 157C, B = 1764), 2 A again with a newer record (overwrite, count stays 2),
//        3 fill the table to 16, 4 a 17th address (ignored, full_drops = 1), 5 update an existing node while full.
`timescale 1ns / 1ps
module tb_location_table;
    localparam integer N = 16;
    reg clk = 1'b0, rst = 1'b1, upd = 1'b0;
    reg [95:0] upd_rec = 96'h0;
    reg [3:0]  rd_idx = 4'd0;
    wire [95:0] rd_rec;
    wire [4:0]  count;
    wire [31:0] full_drops;

    location_table #(.ENTRIES(N)) dut (
        .clk(clk), .rst(rst), .upd(upd), .upd_rec(upd_rec), .upd_meta(16'h0), .upd_via(32'h0), .upd_rdev(32'h0), .upd_merge(1'b0), .now_s(32'd0),
        .stale_s(16'd0),
        .rd_idx(rd_idx), .rd_rec(rd_rec), .rd2_idx(4'd0), .rd2_rec(), .rd2_meta(), .rd2_last(), .fresh(),
        .count(count), .full_drops(full_drops));

    always #4 clk = ~clk;

    // raw 12 bytes -> 96-bit record, byte 0 in bits 7..0
    function automatic [95:0] rec_of(input byte unsigned b[12]);
        for (int i = 0; i < 12; i++) rec_of[8 * i +: 8] = b[i];
    endfunction
    function automatic [95:0] make_rec(input [15:0] a, input [7:0] s, input [31:0] la, input [31:0] lo, input [7:0] f);
        make_rec = {f, lo, la, s, a};            // little-endian: addr in bytes 0..1, seq 2, lat 3..6, lon 7..10, flags 11
    endfunction

    // the model
    bit [95:0]  model_rec[bit [15:0]];
    bit [15:0]  model_order[$];
    integer     model_drops = 0, errors = 0;

    task automatic update(input [95:0] r);
        @(posedge clk);
        upd_rec <= r; upd <= 1'b1;
        @(posedge clk);
        upd <= 1'b0;
        repeat (2) @(posedge clk);               // the table has changed 2 clocks after upd
        if (model_rec.exists(r[15:0]))      model_rec[r[15:0]] = r;
        else if (model_order.size() < N) begin model_rec[r[15:0]] = r; model_order.push_back(r[15:0]); end
        else                                model_drops++;
    endtask

    task automatic check(input string name);
        automatic integer errors_before = errors;
        @(posedge clk);
        if (count != model_order.size() || full_drops != model_drops) begin
            $display("ERROR %s: count %0d full_drops %0d, expected %0d %0d", name, count, full_drops,
                     model_order.size(), model_drops); errors++;
        end
        foreach (model_order[i]) begin
            rd_idx <= i[3:0];
            @(posedge clk); @(posedge clk);      // rd_rec one clock after rd_idx
            if (rd_rec !== model_rec[model_order[i]]) begin
                $display("ERROR %s: entry %0d = %h, expected %h", name, i, rd_rec, model_rec[model_order[i]]); errors++;
            end
        end
        if (errors == errors_before) $display("  ok: %s (count %0d, full_drops %0d)", name, count, full_drops);
    endtask

    reg [95:0] A9, A13, B13;
    initial begin
        A9  = rec_of('{8'h7C, 8'h15, 8'h09, 8'h6A, 8'h8E, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00});
        A13 = rec_of('{8'h7C, 8'h15, 8'h0D, 8'hD2, 8'h8F, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00});
        B13 = rec_of('{8'h64, 8'h17, 8'h0D, 8'h72, 8'h86, 8'h71, 8'h18, 8'hBC, 8'hC9, 8'h45, 8'h11, 8'h00});
        if (A13 !== make_rec(16'h157C, 8'd13, 32'd410095570, 32'd289786100, 8'h00)) begin
            $display("ERROR: record packing in the testbench"); errors++;
        end
        repeat (3) @(posedge clk);
        rst = 1'b0;

        $display("test 1: A (157C seq 9) and B (1764 seq 13) -> added");
        update(A9); update(B13);
        check("two nodes");

        $display("test 2: A again with seq 13 -> entry 0 overwritten");
        update(A13);
        check("overwrite");
        if (count != 2) begin $display("ERROR: count changed on overwrite"); errors++; end

        $display("test 3: 14 more nodes -> table full (16)");
        for (int i = 0; i < 14; i++) update(make_rec(16'h2000 + i, 8'd1, 32'd400000000 + i, 32'd290000000, 8'h00));
        check("full");

        $display("test 4: a 17th address -> ignored");
        update(make_rec(16'h3000, 8'd1, 32'd1, 32'd2, 8'h00));
        check("17th ignored");

        $display("test 5: B updated while full -> works");
        update(make_rec(16'h1764, 8'd14, 32'd410093200, 32'd289786300, 8'h01));
        check("update when full");

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule

// tb_atak_multinode.sv - the friend's 3-node test (virtual nodes 157C, 157D, 157E), both phases at once:
//   dut_p1: whitelist = 157C only           -> 157D / 157E dropped, table 1 entry, downlink N = 1 (18 B)
//   dut_p2: whitelist = 157C, 157D, 157E    -> table 3 entries, downlink N = 3 (42 B) = the friend's golden frame
// Both get the same uplink stream. Round 1: C, D, E (seq 0, the friend's frames). Round 2: E, C, D with seq 1:
// the table must keep the order C, D, E (overwrite in place, no duplicates).
// Also checks that every downlink frame comes exactly one period after the previous one (the "3 frames in 0.6 s"
// report). Faster baud (781250) and a 4.8 ms period keep it short; frame bytes do not depend on them.
`timescale 1ns / 1ps
module tb_atak_multinode;
    localparam integer CLK_HZ = 125_000_000, BAUD = 781_250, PERIOD = 600_000;
    localparam real    BIT_NS = 1.0e9 / BAUD;

    reg clk = 1'b0, rst = 1'b1, rx = 1'b1;
    always #4 clk = ~clk;

    wire        tx1, tx2, pv1, pv2;
    wire [31:0] ok1, ok2, drop1, drop2, sent1, sent2, full1, full2;
    wire [4:0]  cnt1, cnt2;

    atk_server #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .TIMEOUT_CYC(20_000), .WL_FILE("wl_phase1.mem"), .PERIOD_CYC(PERIOD), .GAP_CYC(20_000)) dut_p1 (
        .clk(clk), .rst(rst), .rx(rx), .tx(tx1), .start(1'b0), .stale_s(16'd0), .now_s(), .fresh(), .tbl_rd_idx(4'd0), .tbl_rd_rec(), .tbl_rd_meta(), .tbl_rd_last(),
        .wl_we(1'b0), .wl_idx(6'd0), .wl_wdata(32'd0), .wl_rdata(), .pkt_valid(pv1), .frames_ok(ok1),
        .frames_dropped_addr(drop1), .crc_errors(), .framing_errors(), .length_errors(), .timeout_errors(),
        .table_count(cnt1), .table_full_drops(full1), .frames_sent(sent1), .adm_load(1'b0), .adm_payload(120'h0),
        .secure_tx(1'b0), .secure_only(1'b0), .sec_key(128'h0), .rpl_clear(1'b0), .dl_ctr_load(1'b0), .dl_ctr_val(32'h0));
    atk_server #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .TIMEOUT_CYC(20_000), .WL_FILE("wl_phase2.mem"), .PERIOD_CYC(PERIOD), .GAP_CYC(20_000)) dut_p2 (
        .clk(clk), .rst(rst), .rx(rx), .tx(tx2), .start(1'b0), .stale_s(16'd0), .now_s(), .fresh(), .tbl_rd_idx(4'd0), .tbl_rd_rec(), .tbl_rd_meta(), .tbl_rd_last(),
        .wl_we(1'b0), .wl_idx(6'd0), .wl_wdata(32'd0), .wl_rdata(), .pkt_valid(pv2), .frames_ok(ok2),
        .frames_dropped_addr(drop2), .crc_errors(), .framing_errors(), .length_errors(), .timeout_errors(),
        .table_count(cnt2), .table_full_drops(full2), .frames_sent(sent2), .adm_load(1'b0), .adm_payload(120'h0),
        .secure_tx(1'b0), .secure_only(1'b0), .sec_key(128'h0), .rpl_clear(1'b0), .dl_ctr_load(1'b0), .dl_ctr_val(32'h0));

    // ---- downlink receivers
    wire [7:0] d1, d2;
    wire v1, v2;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_dl1 (.clk(clk), .rst(rst), .rx(tx1), .data(d1), .valid(v1), .framing_error());
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_dl2 (.clk(clk), .rst(rst), .rx(tx2), .data(d2), .valid(v2), .framing_error());
    byte unsigned got1[$], got2[$];
    always @(posedge clk) begin
        if (v1) got1.push_back(d1);
        if (v2) got2.push_back(d2);
    end

    // ---- every downlink frame must start exactly PERIOD clocks after the previous one
    integer errors = 0;
    longint last_start = -1, cyc = 0;
    always @(posedge clk) begin
        cyc++;
        if (dut_p2.u_builder.state == 0 && dut_p2.u_builder.tx_valid == 0 && dut_p2.u_builder.tick && cnt2 != 0) begin
            if (last_start >= 0 && cyc - last_start != PERIOD) begin
                $display("ERROR: downlink %0d clocks after the previous one (period %0d)", cyc - last_start, PERIOD);
                errors++;
            end
            last_start = cyc;
        end
    end

    // ---- uplink
    function automatic byte unsigned crc8(input byte unsigned d[$]);
        byte unsigned c = 0;
        foreach (d[i]) begin
            c ^= d[i];
            repeat (8) c = c[7] ? byte'((c << 1) ^ 8'h07) : byte'(c << 1);
        end
        return c;
    endfunction
    task automatic send_frame(input byte unsigned f[$]);
        foreach (f[k]) begin
            rx = 1'b0; #(BIT_NS);
            for (int i = 0; i < 8; i++) begin rx = f[k][i]; #(BIT_NS); end
            rx = 1'b1; #(BIT_NS);
        end
        #(3 * BIT_NS);
    endtask
    // uplink frame from a 12-byte record (rssi -13, snr 12)
    function automatic void uplink(output byte unsigned f[$], input byte unsigned rec[$]);
        byte unsigned body[$];
        body = {8'h0E, rec, 8'hF3, 8'h0C};
        f = {8'hAA, 8'h55, body, crc8(body)};
    endfunction
    // downlink frame from records
    function automatic void downlink(output byte unsigned f[$], input byte unsigned recs[$], input integer n);
        byte unsigned body[$];
        body = {8'(2 + 12 * n), 8'hD1, 8'(n), recs};
        f = {8'hAA, 8'h55, body, crc8(body)};
    endfunction

    // v11: the PL sets flags bit 7 ("a direct copy arrived") in every record heard directly (bit 2 clear), so a
    // downlink frame AA 55 LEN D1 N recs CRC from the golden list gets bit 7 in those records and a new CRC
    function automatic void v11_dl(input byte unsigned fi[$], output byte unsigned fo[$]);
        byte unsigned body[$];
        fo = fi;
        if (fo.size() >= 6 && fo[3] == 8'hD1) begin
            for (int i = 0; i < fo[4]; i++)
                if (!(fo[5 + 12 * i + 11] & 8'h04)) fo[5 + 12 * i + 11] = fo[5 + 12 * i + 11] | 8'h80;
            body = fo[2:fo.size() - 2];
            fo[fo.size() - 1] = crc8(body);
        end
    endfunction

    task automatic expect_both(input string name, input byte unsigned w1_0[$], input byte unsigned w2_0[$]);
        automatic integer s1 = sent1, s2 = sent2;
        byte unsigned w1[$], w2[$];
        v11_dl(w1_0, w1); v11_dl(w2_0, w2);
        got1.delete(); got2.delete();
        wait (sent1 == s1 + 1 && sent2 == s2 + 1);
        wait (!dut_p1.stx_busy && !dut_p1.uart_busy && !dut_p2.stx_busy && !dut_p2.uart_busy);   // v9: secure_tx
        repeat (2000) @(posedge clk);
        if (got1 != w1) begin
            $write("ERROR %s phase 1: got", name); foreach (got1[i]) $write(" %02h", got1[i]); $display(""); errors++;
        end else begin
            $write("  ok: %s phase 1 (%0d B):", name, got1.size()); foreach (got1[i]) $write(" %02h", got1[i]); $display("");
        end
        if (got2 != w2) begin
            $write("ERROR %s phase 2: got", name); foreach (got2[i]) $write(" %02h", got2[i]); $display(""); errors++;
        end else begin
            $write("  ok: %s phase 2 (%0d B):", name, got2.size()); foreach (got2[i]) $write(" %02h", got2[i]); $display("");
        end
    endtask

    byte unsigned rC[$], rD[$], rE[$], rC1[$], rD1[$], rE1[$], f[$], g42[$], w1[$], w2[$], m[$];
    initial begin
        rC = {8'h7C, 8'h15, 8'h00, 8'h40, 8'h8B, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00};
        rD = {8'h7D, 8'h15, 8'h00, 8'h40, 8'h8B, 8'h71, 8'h18, 8'hD4, 8'hF7, 8'h45, 8'h11, 8'h00};
        rE = {8'h7E, 8'h15, 8'h00, 8'h40, 8'h8B, 8'h71, 8'h18, 8'hB4, 8'h26, 8'h46, 8'h11, 8'h00};
        rC1 = rC; rC1[2] = 8'd1;  rD1 = rD; rD1[2] = 8'd1;  rE1 = rE; rE1[2] = 8'd1;
        // the friend's golden frames
        g42 = {8'hAA, 8'h55, 8'h26, 8'hD1, 8'h03, rC, rD, rE, 8'hDC};
        downlink(m, {rC, rD, rE}, 3);
        if (m != g42) begin $display("ERROR: the testbench model does not give the golden 42-byte frame"); errors++; end
        uplink(f, rC);
        m = {8'hAA, 8'h55, 8'h0E, 8'h7C, 8'h15, 8'h00, 8'h40, 8'h8B, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00, 8'hF3, 8'h0C, 8'hDA};
        if (f != m) begin
            $display("ERROR: the testbench uplink model does not give the golden 157C frame"); errors++;
        end

        repeat (5) @(posedge clk);
        rst = 1'b0;

        $display("round 1: uplink 157C, 157D, 157E (seq 0)");
        uplink(f, rC); send_frame(f);
        uplink(f, rD); send_frame(f);
        uplink(f, rE); send_frame(f);
        $display("  phase 1: accepted %0d, dropped %0d, table %0d   phase 2: accepted %0d, dropped %0d, table %0d",
                 ok1, drop1, cnt1, ok2, drop2, cnt2);
        if (ok1 != 1 || drop1 != 2 || cnt1 != 1 || ok2 != 3 || drop2 != 0 || cnt2 != 3) begin
            $display("ERROR: expected phase 1: 1 / 2 / 1, phase 2: 3 / 0 / 3"); errors++;
        end
        downlink(w1, rC, 1);
        expect_both("tick 1", w1, g42);

        $display("round 2: uplink 157E, 157C, 157D (seq 1, other order)");
        uplink(f, rE1); send_frame(f);
        uplink(f, rC1); send_frame(f);
        uplink(f, rD1); send_frame(f);
        if (cnt2 != 3) begin $display("ERROR: phase 2 table has %0d entries (duplicates?)", cnt2); errors++; end
        downlink(w1, rC1, 1);
        downlink(w2, {rC1, rD1, rE1}, 3);
        expect_both("tick 2", w1, w2);

        $display("tick 3: no new uplink, same table");
        expect_both("tick 3", w1, w2);

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule

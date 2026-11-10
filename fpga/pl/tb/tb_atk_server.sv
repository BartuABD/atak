// tb_atk_server.sv - end-to-end test of the whole server: real uplink frames go in on rx (UART model), the downlink
// frames that come out on tx are received by a uart_rx and compared byte for byte.
// Faster baud (781250 = 160 clocks per bit) and a 4.8 ms period keep it short; frame bytes do not depend on them.
// Uplink sent before the first tick: A (157C seq 9), B (1764 seq 13), an unknown node 157D, A again (seq 13).
// Expected: nothing on tx before the first tick; then at EVERY tick friend's golden frame 2 (A seq 13, B seq 13).
`timescale 1ns / 1ps
module tb_atk_server;
    localparam integer CLK_HZ = 125_000_000, BAUD = 781_250, PERIOD = 600_000;
    localparam real    BIT_NS = 1.0e9 / BAUD;

    reg clk = 1'b0, rst = 1'b1, rx = 1'b1;
    always #4 clk = ~clk;

    wire tx, pkt_valid;
    wire [31:0] frames_ok, frames_dropped_addr, crc_errors, framing_errors, length_errors, timeout_errors;
    wire [4:0]  table_count;
    wire [31:0] table_full_drops, frames_sent;

    atk_server #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .TIMEOUT_CYC(20_000), .WL_FILE("wl_server.mem"),
                 .TABLE_SIZE(16), .PERIOD_CYC(PERIOD), .GAP_CYC(20_000)) dut (
        .clk(clk), .rst(rst), .rx(rx), .tx(tx), .start(1'b0), .stale_s(16'd0), .now_s(), .fresh(),
        .tbl_rd_idx(4'd0), .tbl_rd_rec(), .tbl_rd_meta(), .tbl_rd_last(), .wl_we(1'b0), .wl_idx(6'd0), .wl_wdata(32'd0), .wl_rdata(),
        .pkt_valid(pkt_valid), .frames_ok(frames_ok), .frames_dropped_addr(frames_dropped_addr),
        .crc_errors(crc_errors), .framing_errors(framing_errors), .length_errors(length_errors),
        .timeout_errors(timeout_errors), .table_count(table_count), .table_full_drops(table_full_drops),
        .frames_sent(frames_sent), .adm_load(1'b0), .adm_payload(120'h0),
        .secure_tx(1'b0), .secure_only(1'b0), .sec_key(128'h0), .rpl_clear(1'b0), .dl_ctr_load(1'b0), .dl_ctr_val(32'h0));

    // ---- downlink receiver
    wire [7:0] dl_data;
    wire dl_valid, dl_ferr;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_dl (
        .clk(clk), .rst(rst), .rx(tx), .data(dl_data), .valid(dl_valid), .framing_error(dl_ferr));
    byte unsigned got[$];
    integer errors = 0;
    always @(posedge clk) begin
        if (dl_valid) got.push_back(dl_data);
        if (dl_ferr) begin $display("ERROR %0t: downlink framing error", $time); errors++; end
    end

    // ---- uplink transmitter
    task automatic send_byte(input byte unsigned b);
        rx = 1'b0; #(BIT_NS);
        for (int i = 0; i < 8; i++) begin rx = b[i]; #(BIT_NS); end
        rx = 1'b1; #(BIT_NS);
    endtask
    task automatic send_frame(input byte unsigned f[$]);
        foreach (f[i]) send_byte(f[i]);
        #(3 * BIT_NS);
    endtask

    function automatic byte unsigned crc8(input byte unsigned d[$]);
        byte unsigned c = 0;
        foreach (d[k]) begin c ^= d[k]; repeat (8) c = c[7] ? byte'((c << 1) ^ 8'h07) : byte'(c << 1); end
        return c;
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

    task automatic expect_frame(input string name, input byte unsigned want0[$]);
        automatic integer sent0 = frames_sent;
        byte unsigned want[$];
        v11_dl(want0, want);
        got.delete();
        wait (frames_sent == sent0 + 1);
        wait (!dut.stx_busy && !dut.uart_busy);     // v9: the frame leaves secure_tx after the builder is done
        repeat (2000) @(posedge clk);
        if (got != want) begin
            $display("ERROR %s:", name);
            $write("  got  (%0d B):", got.size());  foreach (got[i])  $write(" %02h", got[i]);  $display("");
            $write("  want (%0d B):", want.size()); foreach (want[i]) $write(" %02h", want[i]); $display("");
            errors++;
        end else begin
            $write("  ok: %s (%0d B):", name, got.size()); foreach (got[i]) $write(" %02h", got[i]); $display("");
        end
    endtask

    byte unsigned upA9[$], upA13[$], upB13[$], upX[$], g2[$];
    initial begin
        upA9  = {8'hAA, 8'h55, 8'h0E, 8'h7C, 8'h15, 8'h09, 8'h6A, 8'h8E, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00, 8'hF3, 8'h0C, 8'h81};
        upA13 = {8'hAA, 8'h55, 8'h0E, 8'h7C, 8'h15, 8'h0D, 8'hD2, 8'h8F, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00, 8'hF5, 8'h0E, 8'hA1};
        upB13 = {8'hAA, 8'h55, 8'h0E, 8'h64, 8'h17, 8'h0D, 8'h72, 8'h86, 8'h71, 8'h18, 8'hBC, 8'hC9, 8'h45, 8'h11, 8'h00, 8'hF1, 8'h0C, 8'h70};
        // 157D (not in the whitelist), CRC computed for it: must never reach the table
        upX   = {8'hAA, 8'h55, 8'h0E, 8'h7D, 8'h15, 8'h0D, 8'hD2, 8'h8F, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00, 8'hF5, 8'h0E, 8'h00};
        begin   // its CRC
            automatic byte unsigned c = 0;
            for (int i = 2; i < 17; i++) begin c ^= upX[i]; repeat (8) c = c[7] ? byte'((c << 1) ^ 8'h07) : byte'(c << 1); end
            upX[17] = c;
        end
        g2 = {8'hAA, 8'h55, 8'h1A, 8'hD1, 8'h02, 8'h7C, 8'h15, 8'h0D, 8'hD2, 8'h8F, 8'h71, 8'h18, 8'hF4, 8'hC8,
              8'h45, 8'h11, 8'h00, 8'h64, 8'h17, 8'h0D, 8'h72, 8'h86, 8'h71, 8'h18, 8'hBC, 8'hC9, 8'h45, 8'h11,
              8'h00, 8'h18};

        repeat (5) @(posedge clk);
        rst = 1'b0;

        $display("uplink: A seq 9, B seq 13, unknown 157D, A seq 13 (all before the first tick)");
        send_frame(upA9); send_frame(upB13); send_frame(upX); send_frame(upA13);
        if (got.size() != 0) begin $display("ERROR: downlink bytes before the first tick"); errors++; end
        $display("  table: %0d entries, frames_ok %0d, dropped (address) %0d", table_count, frames_ok, frames_dropped_addr);
        if (table_count != 2 || frames_ok != 3 || frames_dropped_addr != 1) begin
            $display("ERROR: expected 2 entries, 3 accepted, 1 dropped"); errors++;
        end

        $display("tick 1: downlink must be golden frame 2");
        expect_frame("tick 1", g2);
        $display("tick 2: the same table again");
        expect_frame("tick 2", g2);

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule

// tb_atk_axi.sv - self-checking test of the AXI4-Lite wrapper: an AXI master model (like the Zynq PS) reads the
// registers while real uplink frames come in on uart_rx. Uses tb/wl_phase2.mem (157C, 157D, 157E allowed).
// Checks: ID; the three nodes in TABLE_COUNT, FRAMES_OK and the raw table bytes; an unknown node only counted;
// overwrite keeps the slot; IRQ_STATUS set / cleared (W1C) and the irq pin with IRQ_ENABLE; CONTROL bit 0 sends the
// downlink frame now = the friend's golden 42-byte frame; CONTROL bit 1 (soft reset) empties the table.
// Clock 100 MHz like FCLK_CLK0; faster baud (781250 = 128 clocks per bit) keeps the simulation short.
`timescale 1ns / 1ps
module tb_atk_axi;
    localparam integer CLK_HZ = 100_000_000, BAUD = 781_250;
    localparam real    BIT_NS = 1.0e9 / BAUD;
    localparam integer GAP = 20_000;                   // idle clocks between tx frames (100 ms on the board)

    reg clk = 1'b0, aresetn = 1'b0, rx = 1'b1;
    always #5 clk = ~clk;

    reg  [11:0] awaddr = 0, araddr = 0;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    reg  [31:0] wdata = 0;
    wire        awready, wready, bvalid, arready, rvalid, tx, irq;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    atk_axi #(.CLK_HZ(CLK_HZ), .BAUD(BAUD), .WL_FILE("wl_phase2.mem"), .PERIOD_CYC(500_000_000),
             .SEC_CYC(100_000), .GAP_CYC(GAP)) dut (                    // one "second" = 1 ms, so the stale test is short
        .s_axi_aclk(clk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .uart_rx(rx), .uart_tx(tx), .irq(irq));

    // ---- AXI master model (address and data offered together, like the PS does)
    task automatic axi_write(input [11:0] a, input [31:0] d);
        @(posedge clk); awaddr <= a; awvalid <= 1; wdata <= d; wvalid <= 1; bready <= 1;
        fork
            begin do @(posedge clk); while (!awready); awvalid <= 0; end
            begin do @(posedge clk); while (!wready);  wvalid  <= 0; end
        join
        do @(posedge clk); while (!bvalid);
        bready <= 0;
    endtask
    task automatic axi_read(input [11:0] a, output [31:0] d);
        @(posedge clk); araddr <= a; arvalid <= 1; rready <= 1;
        do @(posedge clk); while (!arready);
        arvalid <= 0;
        do @(posedge clk); while (!rvalid);
        d = rdata;
        rready <= 0;
    endtask

    // ---- uplink UART model + frame builder
    function automatic byte unsigned crc8(input byte unsigned d[$]);
        byte unsigned c = 0;
        foreach (d[i]) begin c ^= d[i]; repeat (8) c = c[7] ? byte'((c << 1) ^ 8'h07) : byte'(c << 1); end
        return c;
    endfunction
    task automatic send_uplink(input byte unsigned rec[$]);
        byte unsigned body[$], f[$];
        body = {8'h0E, rec, 8'hF3, 8'h0C};
        f = {8'hAA, 8'h55, body, crc8(body)};
        foreach (f[k]) begin
            rx = 1'b0; #(BIT_NS);
            for (int i = 0; i < 8; i++) begin rx = f[k][i]; #(BIT_NS); end
            rx = 1'b1; #(BIT_NS);
        end
        #(3 * BIT_NS);
    endtask

    integer errors = 0;
    // command frame: AA 55 11 | 15 B cmd_packet_t | RSSI | SNR | CRC8
    function automatic void make_cmd(output byte unsigned c[$], input [15:0] src, input [15:0] dst, input [7:0] id,
                                     input [7:0] kind, input [31:0] la, input [31:0] lo);
        c = {8'hC1, src[7:0], src[15:8], dst[7:0], dst[15:8], id, kind, la[7:0], la[15:8], la[23:16], la[31:24],
             lo[7:0], lo[15:8], lo[23:16], lo[31:24]};
    endfunction
    task automatic send_frame_raw(input byte unsigned body[$]);       // body = LEN .. SNR
        byte unsigned f[$];
        f = {8'hAA, 8'h55, body, crc8(body)};
        foreach (f[k]) begin
            rx = 1'b0; #(BIT_NS);
            for (int i = 0; i < 8; i++) begin rx = f[k][i]; #(BIT_NS); end
            rx = 1'b1; #(BIT_NS);
        end
        #(3 * BIT_NS);
    endtask
    task automatic send_cmd(input byte unsigned c[$], input byte unsigned rssi_v = 8'hEA, input byte unsigned snr_v = 8'h0B);
        send_frame_raw({8'h11, c, rssi_v, snr_v});
    endtask
    // FIFO entry k must hold command c (+ RSSI/SNR, sequence number)
    task automatic expect_cmd_entry(input integer k, input byte unsigned c[$], input [31:0] seq_want);
        reg [31:0] w[8];
        bit [127:0] want;
        want = 0;
        foreach (c[b]) want[8 * b +: 8] = c[b];
        for (int j = 0; j < 8; j++) axi_read(12'h800 + 32 * k + 4 * j, w[j]);
        if ({w[3], w[2], w[1], w[0]} !== want || w[4][15:0] !== 16'h0BEA || w[6] !== seq_want) begin
            $display("ERROR cmd entry %0d: %h %h %h %h rssi/snr %h seq %0d", k, w[3], w[2], w[1], w[0], w[4], w[6]); errors++;
        end else
            $display("  ok: cmd entry %0d = src %04h dst %04h msg %0d kind %0d, RSSI -22 SNR 11, t=%0d s, seq %0d",
                     k, {w[0][23:16], w[0][15:8]}, {w[1][7:0], w[0][31:24]}, w[1][15:8], w[1][23:16], w[5], w[6]);
    endtask

    // ---- downlink receiver
    wire [7:0] dl_data; wire dl_valid;
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_dl (.clk(clk), .rst(!aresetn), .rx(tx), .data(dl_data), .valid(dl_valid), .framing_error());
    byte unsigned got[$];
    longint got_t[$];                                   // clock count when each byte arrived
    longint clk_n = 0;
    always @(posedge clk) clk_n++;
    always @(posedge clk) if (dl_valid) begin got.push_back(dl_data); got_t.push_back(clk_n); end

    // got = two frames of n1 and n2 bytes, each starting AA 55 with LEN = its size - 4, the admin one equal to adm,
    // and at least GAP clocks between the last byte of the first and the first byte of the second
    task automatic check_two(input byte unsigned adm[$], input integer n1, input integer n2, input string what);
        byte unsigned f1[$], f2[$];
        longint idle;
        bit adm_bad;
        f1 = got[0:n1 - 1]; f2 = got[n1:n1 + n2 - 1];
        if (n1 == 19) adm_bad = (f1 != adm); else adm_bad = (f2 != adm);
        idle = got_t[n1] - got_t[n1 - 1] - 10 * 128;                  // minus one byte time (10 bits x 128 clocks)
        if (got.size() != n1 + n2 || f1[0] != 8'hAA || f1[1] != 8'h55 || f1[2] != n1 - 4 || f2[0] != 8'hAA ||
            f2[1] != 8'h55 || f2[2] != n2 - 4 || adm_bad || idle < GAP) begin
            $display("ERROR %s: %0d bytes, idle %0d clocks", what, got.size(), idle); errors++;
            $write("  got:"); foreach (got[i]) $write(" %02h", got[i]); $display("");
        end else
            $display("  ok: %s, not mixed, idle line between them %0d clocks (>= %0d)", what, idle, GAP);
    endtask

    task automatic expect_reg(input string name, input [11:0] a, input [31:0] want);
        reg [31:0] v;
        axi_read(a, v);
        if (v !== want) begin $display("ERROR %s (0x%03h) = 0x%08h, expected 0x%08h", name, a, v, want); errors++; end
        else $display("  ok: %-14s 0x%03h = 0x%08h", name, a, v);
    endtask
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
    // the 12 raw bytes of table entry i must equal rec (v11: + flags bit 7 when bit 2 is clear = heard directly)
    task automatic expect_entry(input integer i, input byte unsigned rec[$]);
        reg [31:0] w0, w1, w2;
        bit [95:0] want;
        foreach (rec[b]) want[8 * b +: 8] = rec[b];
        if (!want[90]) want[95] = 1'b1;
        axi_read(12'h100 + 16 * i, w0); axi_read(12'h104 + 16 * i, w1); axi_read(12'h108 + 16 * i, w2);
        if ({w2, w1, w0} !== want) begin $display("ERROR entry %0d = %h, expected %h", i, {w2, w1, w0}, want); errors++; end
        else $display("  ok: entry %0d = addr %04h seq %0d", i, w0[15:0], w0[23:16]);
    endtask

    byte unsigned rC[$], rD[$], rE[$], rX[$], rC1[$], g42[$];
    reg [31:0] v;
    initial begin
        rC = {8'h7C, 8'h15, 8'h00, 8'h40, 8'h8B, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00};
        rD = {8'h7D, 8'h15, 8'h00, 8'h40, 8'h8B, 8'h71, 8'h18, 8'hD4, 8'hF7, 8'h45, 8'h11, 8'h00};
        rE = {8'h7E, 8'h15, 8'h00, 8'h40, 8'h8B, 8'h71, 8'h18, 8'hB4, 8'h26, 8'h46, 8'h11, 8'h00};
        rX = rC; rX[0] = 8'h99;                          // node 1599: not in the whitelist
        rC1 = rC; rC1[2] = 8'd7;                         // 157C again, seq 7
        g42 = {8'hAA, 8'h55, 8'h26, 8'hD1, 8'h03, rC, rD, rE, 8'hDC};

        repeat (10) @(posedge clk);
        aresetn = 1'b1;
        repeat (10) @(posedge clk);

        $display("test 1: ID and empty table");
        expect_reg("ID", 9'h000, 32'h41544B0C);
        // v12: SECURE_ONLY is 1 after reset (the drop itself is tested in the security tests); plain mode for the tests
        expect_reg("SEC_CTRL after reset = SECURE_ONLY (v12)", 9'h088, 32'h2);
        axi_write(9'h088, 32'h0);
        expect_reg("SEC_CTRL = plain", 9'h088, 32'h0);
        expect_reg("TABLE_COUNT", 9'h008, 0);

        $display("test 2: three allowed nodes + one unknown node");
        axi_write(9'h034, 1);                            // IRQ_ENABLE
        send_uplink(rC); send_uplink(rD); send_uplink(rE); send_uplink(rX);
        expect_reg("TABLE_COUNT", 9'h008, 3);
        expect_reg("FRAMES_OK", 9'h00C, 3);
        expect_reg("DROPPED_ADDR", 9'h010, 1);
        expect_reg("CRC_ERRORS", 9'h014, 0);
        expect_entry(0, rC); expect_entry(1, rD); expect_entry(2, rE);
        expect_reg("unused entry 3", 9'h130, 0);

        $display("test 3: interrupt");
        expect_reg("IRQ_STATUS", 9'h030, 1);
        if (irq !== 1'b1) begin $display("ERROR: irq pin not high"); errors++; end else $display("  ok: irq pin high");
        axi_write(9'h030, 1);                            // clear (W1C)
        expect_reg("IRQ_STATUS", 9'h030, 0);
        if (irq !== 1'b0) begin $display("ERROR: irq pin still high"); errors++; end else $display("  ok: irq pin low");

        $display("test 4: CONTROL bit 0 = send the downlink table now");
        got.delete();
        axi_write(9'h004, 32'h1);
        wait (got.size() == 42);
        repeat (2000) @(posedge clk);
        begin
            byte unsigned g42v[$];
            v11_dl(g42, g42v);
            if (got != g42v) begin
                $write("ERROR downlink:"); foreach (got[i]) $write(" %02h", got[i]); $display(""); errors++;
            end else $display("  ok: downlink = golden 42-byte frame (N=3) with v11 bit 7 in the 3 direct records");
        end
        expect_reg("FRAMES_SENT", 9'h028, 1);

        $display("test 5: 157C again (seq 7) -> same slot, still 3 nodes");
        send_uplink(rC1);
        expect_reg("TABLE_COUNT", 9'h008, 3);
        expect_entry(0, rC1);

        $display("test 6: CONTROL bit 1 = soft reset");
        axi_write(9'h004, 32'h2);
        repeat (5) @(posedge clk);
        expect_reg("TABLE_COUNT", 9'h008, 0);
        expect_reg("FRAMES_OK", 9'h00C, 0);

        $display("test 7: whitelist from the PS: read back, add node 1599, RSSI/SNR in word 3");
        expect_reg("WL[0]", 9'h044, 32'h0001157C);         // WL_INDEX is 0 after reset
        axi_write(9'h040, 2); expect_reg("WL[2]", 9'h044, 32'h0001157E);
        axi_write(9'h040, 3); expect_reg("WL[3] empty", 9'h044, 32'h0);
        axi_write(9'h044, 32'h00011599);                   // allow node 1599
        expect_reg("WL[3] new", 9'h044, 32'h00011599);
        send_uplink(rX);
        expect_reg("TABLE_COUNT", 9'h008, 1);
        expect_entry(0, rX);
        axi_read(9'h10C, v);
        if (v[15:0] !== 16'h0CF3) begin $display("ERROR: word 3 RSSI/SNR = %04h, expected 0CF3", v[15:0]); errors++; end
        else $display("  ok: entry 0 word 3: RSSI -13 dBm, SNR 12 dB, age %0d s", v[31:16]);

        $display("test 8: remove 157E from the whitelist -> its frames are dropped");
        axi_write(9'h040, 2); axi_write(9'h044, 32'h0);
        axi_read(9'h010, v);
        send_uplink(rE);
        expect_reg("DROPPED_ADDR", 9'h010, v + 1);
        expect_reg("TABLE_COUNT", 9'h008, 1);

        $display("test 9: stale nodes leave the downlink, stay in the table");
        send_uplink(rC);                                   // table: 0 = 1599, 1 = 157C
        expect_reg("FRESH_MASK", 9'h048, 32'h3);
        axi_write(9'h03C, 3);                              // STALE_S = 3 s
        repeat (400_000) @(posedge clk);                   // 4 "seconds"
        expect_reg("FRESH_MASK both stale", 9'h048, 32'h0);
        axi_read(9'h10C, v);
        if (v[31:16] < 4) begin $display("ERROR: age %0d, expected >= 4", v[31:16]); errors++; end
        else $display("  ok: entry 0 age %0d s", v[31:16]);
        send_uplink(rC);                                   // 157C heard again
        expect_reg("FRESH_MASK", 9'h048, 32'h2);
        expect_reg("TABLE_COUNT still 2", 9'h008, 2);
        got.delete();
        axi_write(9'h004, 32'h1);
        begin
            byte unsigned body[$], want[$];
            body = {8'h0E, 8'hD1, 8'h01, rC};
            want = {8'hAA, 8'h55, body, crc8(body)};
            v11_dl(want, want);
            wait (got.size() == 18);
            repeat (2000) @(posedge clk);
            if (got != want) begin $write("ERROR downlink:"); foreach (got[i]) $write(" %02h", got[i]); $display(""); errors++; end
            else $display("  ok: downlink has only the fresh node (N=1, 157C)");
        end

        $display("test 10: commands (LEN 17, 0xC1) -> FIFO; unknown src dropped; not-C1 rejected");
        begin
            byte unsigned c1[$], c2[$], cx[$], bad[$];
            reg [31:0] lenerr0;
            make_cmd(c1, 16'h157C, 16'hFFFF, 8'd1, 8'd2, 32'd409850000, 32'd288540000);   // hazard, to all
            make_cmd(c2, 16'h157D, 16'h157C, 8'd9, 8'd4, 32'd409860000, 32'd288550000);   // "come here" to 157C
            make_cmd(cx, 16'h2222, 16'hFFFF, 8'd1, 8'd1, 32'd1, 32'd2);                   // src not allowed
            bad = c1; bad[0] = 8'hC4;
            axi_write(9'h030, 3);                          // clear IRQ_STATUS
            axi_write(9'h034, 3);                          // enable both interrupt sources
            axi_read(9'h01C, lenerr0);
            send_cmd(c1);
            expect_reg("CMD_WR_COUNT", 9'h04C, 1);
            expect_reg("IRQ_STATUS (cmd)", 9'h030, 2);
            expect_cmd_entry(0, c1, 0);
            send_uplink(rC);                               // a position in between: the table keeps working
            send_cmd(c2);
            send_cmd(cx);
            send_frame_raw({8'h11, bad, 8'hEA, 8'h0B});    // 17 bytes, but type C4
            expect_reg("CMD_WR_COUNT", 9'h04C, 2);
            expect_cmd_entry(1, c2, 1);
            expect_reg("CMDS_OK", 9'h058, 2);
            expect_reg("CMDS_DROPPED (src)", 9'h05C, 1);
            expect_reg("LENGTH_ERRORS +1", 9'h01C, lenerr0 + 1);
            expect_reg("TABLE_COUNT still 2", 9'h008, 2);

            $display("test 11: FIFO full -> the NEW command is dropped and counted; RD frees space");
            for (int i = 0; i < 64; i++) begin
                c2[5] = 8'(100 + i);
                send_cmd(c2);
            end
            expect_reg("CMD_WR_COUNT = 64 (full)", 9'h04C, 64);
            expect_reg("CMD_OVERFLOWS = 2", 9'h054, 2);
            axi_write(9'h050, 64);                         // the PS has consumed all 64
            c2[5] = 8'd250;
            send_cmd(c2);
            expect_reg("CMD_WR_COUNT", 9'h04C, 65);
            expect_cmd_entry(0, c2, 64);                   // command 64 is in slot 0 again

            $display("test 12: the gateway's example frame, byte for byte (21 bytes, its own CRC 0x86)");
            begin
                byte unsigned gw[$] = {8'hAA, 8'h55, 8'h11, 8'hC1, 8'h7C, 8'h15, 8'hFF, 8'hFF, 8'h07, 8'h04, 8'h38, 8'hB5,
                                       8'h6D, 8'h18, 8'h58, 8'hBE, 8'h32, 8'h11, 8'hC4, 8'h09, 8'h86};
                reg [31:0] w[8];
                foreach (gw[k]) begin
                    rx = 1'b0; #(BIT_NS);
                    for (int i = 0; i < 8; i++) begin rx = gw[k][i]; #(BIT_NS); end
                    rx = 1'b1; #(BIT_NS);
                end
                #(3 * BIT_NS);
                expect_reg("CMD_WR_COUNT", 9'h04C, 66);
                for (int j = 0; j < 8; j++) axi_read(12'h800 + 32 * 1 + 4 * j, w[j]);
                if (w[0] !== 32'hFF157CC1 || w[1] !== 32'h380407FF || w[2] !== 32'h58186DB5 || w[3] !== 32'h001132BE ||
                    w[4] !== 32'h000009C4 || w[6] !== 32'd65) begin
                    $display("ERROR gateway frame entry: %h %h %h %h meta %h seq %0d", w[0], w[1], w[2], w[3], w[4], w[6]);
                    errors++;
                end else
                    $display("  ok: src 157C dst FFFF msg 7 kind 4 (come here), lat %0d lon %0d, RSSI %0d SNR %0d, seq 65",
                             $signed({w[2][23:0], w[1][31:24]}), $signed({w[3][23:0], w[2][31:24]}),
                             $signed(w[4][7:0]), $signed(w[4][15:8]));
            end

            $display("test 13: 0xC2 delete request -> same FIFO (type byte C2); unknown requester dropped");
            begin
                byte unsigned d1[$], dx[$];
                reg [31:0] ok0, drop0, w0, w1, w2;
                // [C2][src 157D][dst FFFE][msg_id 41][0][target_src 157C][target_msg_id 216][0 x5]
                d1 = {8'hC2, 8'h7D, 8'h15, 8'hFE, 8'hFF, 8'd41, 8'h00, 8'h7C, 8'h15, 8'd216, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
                dx = d1; dx[1] = 8'h22; dx[2] = 8'h22;                  // requester 2222: not allowed
                axi_read(9'h058, ok0); axi_read(9'h05C, drop0);
                send_cmd(d1);
                send_cmd(dx);
                expect_reg("CMD_WR_COUNT", 9'h04C, 67);
                expect_reg("CMDS_OK +1", 9'h058, ok0 + 1);
                expect_reg("CMDS_DROPPED +1", 9'h05C, drop0 + 1);
                expect_cmd_entry(2, d1, 66);                                 // command 66 -> slot 2
            end

            $display("test 14: admin frame 0xC3 = [AA 55 0F | 15 B | CRC8]; a second send while busy is ignored");
            begin
                byte unsigned pay[$], want[$], body[$];
                // [C3][src FFFE][dst 157D][msg_id 5][decision 1][target 157C][target_msg 216][request_msg 41][0 x4]
                pay  = {8'hC3, 8'hFE, 8'hFF, 8'h7D, 8'h15, 8'd5, 8'd1, 8'h7C, 8'h15, 8'd216, 8'd41, 8'h00, 8'h00, 8'h00, 8'h00};
                body = {8'h0F, pay};
                want = {8'hAA, 8'h55, body, crc8(body)};
                axi_write(9'h03C, 0);                                         // STALE_S = 0: nodes never stale (test 15)
                axi_write(9'h060, {pay[3], pay[2], pay[1], pay[0]});
                axi_write(9'h064, {pay[7], pay[6], pay[5], pay[4]});
                axi_write(9'h068, {pay[11], pay[10], pay[9], pay[8]});
                axi_write(9'h06C, {8'hEE, pay[14], pay[13], pay[12]});        // bits 31..24 are not sent
                expect_reg("ADMIN_DATA1", 9'h064, {pay[7], pay[6], pay[5], pay[4]});
                repeat (GAP + 10) @(posedge clk);
                got.delete(); got_t.delete();
                axi_write(9'h070, 1);
                expect_reg("ADMIN_CTRL busy", 9'h070, 1);
                axi_write(9'h070, 1);                                         // ignored: still busy
                wait (got.size() == 19);
                repeat (GAP * 2) @(posedge clk);
                if (got != want) begin $write("ERROR admin frame:"); foreach (got[i]) $write(" %02h", got[i]); $display(""); errors++; end
                else begin $write("  ok: admin frame (19 B):"); foreach (got[i]) $write(" %02h", got[i]); $display(""); end
                expect_reg("ADMIN_SENT = 1", 9'h074, 1);
                expect_reg("ADMIN_CTRL idle", 9'h070, 0);
                if (got.size() != 19) begin $display("ERROR: %0d bytes, the second send was not ignored", got.size()); errors++; end

                $display("test 15: arbitration - frames never mixed, >= GAP idle between them (both orders)");
                // a) admin first, the table send comes while the admin frame is going out
                got.delete(); got_t.delete();
                axi_write(9'h070, 1);
                repeat (2000) @(posedge clk);                                 // admin frame is on the line now
                axi_write(9'h004, 1);                                         // table now
                wait (got.size() == 19 + 30);                                 // table: 2 nodes = 5 + 24 + 1 = 30 B
                repeat (2000) @(posedge clk);
                check_two(want, 19, 30, "admin then table");
                // b) table first, the admin send comes while the table frame is going out
                got.delete(); got_t.delete();
                repeat (GAP) @(posedge clk);
                axi_write(9'h004, 1);
                repeat (2000) @(posedge clk);
                axi_write(9'h070, 1);
                wait (got.size() == 30 + 19);
                repeat (2000) @(posedge clk);
                check_two(want, 30, 19, "table then admin");
                expect_reg("ADMIN_SENT = 3", 9'h074, 3);
            end

            $display("test 16: 0xC5 ACKs (gateway golden frames, byte for byte) -> FIFO; ACK from unknown node dropped");
            begin
                // node 157C acknowledges admin msg_id 0x22: DELIVERED (ack_seq 0) and SEEN (ack_seq 1), RSSI -55, SNR 12
                byte unsigned dlv[$] = {8'hAA, 8'h55, 8'h11, 8'hC5, 8'h7C, 8'h15, 8'hFE, 8'hFF, 8'h00, 8'h01, 8'hFE, 8'hFF,
                                        8'h22, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hC9, 8'h0C, 8'hB6};
                byte unsigned sen[$] = {8'hAA, 8'h55, 8'h11, 8'hC5, 8'h7C, 8'h15, 8'hFE, 8'hFF, 8'h01, 8'h02, 8'hFE, 8'hFF,
                                        8'h22, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hC9, 8'h0C, 8'hCA};
                byte unsigned ax[$];
                reg [31:0] wr0, ok0, drop0, crc0, w[8];
                axi_read(9'h04C, wr0); axi_read(9'h058, ok0); axi_read(9'h05C, drop0); axi_read(9'h014, crc0);
                foreach (dlv[k]) begin
                    rx = 1'b0; #(BIT_NS);
                    for (int i = 0; i < 8; i++) begin rx = dlv[k][i]; #(BIT_NS); end
                    rx = 1'b1; #(BIT_NS);
                end
                foreach (sen[k]) begin
                    rx = 1'b0; #(BIT_NS);
                    for (int i = 0; i < 8; i++) begin rx = sen[k][i]; #(BIT_NS); end
                    rx = 1'b1; #(BIT_NS);
                end
                ax = {8'hC5, 8'h22, 8'h22, 8'hFE, 8'hFF, 8'h00, 8'h01, 8'hFE, 8'hFF, 8'h22, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
                send_cmd(ax);                                                 // src 2222: not in the whitelist
                #(3 * BIT_NS);
                expect_reg("CMD_WR_COUNT +2", 9'h04C, wr0 + 2);
                expect_reg("CMDS_OK +2", 9'h058, ok0 + 2);
                expect_reg("CMDS_DROPPED +1", 9'h05C, drop0 + 1);
                expect_reg("CRC_ERRORS unchanged", 9'h014, crc0);
                for (int j = 0; j < 8; j++) axi_read(12'h800 + 32 * (wr0 % 64) + 4 * j, w[j]);
                if (w[0] !== 32'hFE157CC5 || w[1] !== 32'hFE0100FF || w[2] !== 32'h000022FF || w[3] !== 32'h00000000 ||
                    w[4][15:0] !== 16'h0CC9 || w[6] !== wr0) begin
                    $display("ERROR DELIVERED entry: %h %h %h %h meta %h seq %0d", w[0], w[1], w[2], w[3], w[4], w[6]); errors++;
                end else
                    $display("  ok: C5 src 157C ack_seq 0 kind 1 DELIVERED for FFFE#0x22, RSSI %0d SNR %0d",
                             $signed(w[4][7:0]), $signed(w[4][15:8]));
                for (int j = 0; j < 8; j++) axi_read(12'h800 + 32 * ((wr0 + 1) % 64) + 4 * j, w[j]);
                if (w[0] !== 32'hFE157CC5 || w[1] !== 32'hFE0201FF || w[2] !== 32'h000022FF || w[6] !== wr0 + 1) begin
                    $display("ERROR SEEN entry: %h %h %h %h seq %0d", w[0], w[1], w[2], w[3], w[6]); errors++;
                end else
                    $display("  ok: C5 src 157C ack_seq 1 kind 2 SEEN for FFFE#0x22");
            end

            $display("test 17: relayed position 0xE1 (gateway golden frame) -> table + VIA; both addresses checked");
            begin
                // far node 0F53 seq 5 flags 06 (bit2 = via relay, set by the gateway), relayed by 157C (relay RSSI -49 SNR 13), gateway RSSI -46 SNR 12
                byte unsigned rel[$] = {8'hAA, 8'h55, 8'h13, 8'hE1, 8'h7C, 8'h15, 8'hCF, 8'h0D, 8'h53, 8'h0F, 8'h05,
                                        8'hF6, 8'hA6, 8'h6D, 8'h18, 8'h00, 8'hBC, 8'h32, 8'h11, 8'h06, 8'hD2, 8'h0C, 8'h85};
                byte unsigned inner[$] = {8'h53, 8'h0F, 8'h05, 8'hF6, 8'hA6, 8'h6D, 8'h18, 8'h00, 8'hBC, 8'h32, 8'h11, 8'h06};
                byte unsigned b[$];
                reg [31:0] ok0, drop0, len0, n, w0, w3, via;
                integer e;
                axi_write(9'h040, 10); axi_write(9'h044, 32'h00010F53);           // allow 0F53 (157C is allowed)
                axi_read(9'h00C, ok0); axi_read(9'h010, drop0); axi_read(9'h01C, len0);
                foreach (rel[k]) begin
                    rx = 1'b0; #(BIT_NS);
                    for (int i = 0; i < 8; i++) begin rx = rel[k][i]; #(BIT_NS); end
                    rx = 1'b1; #(BIT_NS);
                end
                #(3 * BIT_NS);
                expect_reg("FRAMES_OK +1", 9'h00C, ok0 + 1);
                expect_reg("RELAYS_OK = 1", 9'h078, 1);
                axi_read(9'h008, n);
                e = -1;
                for (int i = 0; i < n; i++) begin
                    axi_read(12'h100 + 16 * i, w0);
                    if (w0[15:0] == 16'h0F53) e = i;
                end
                if (e < 0) begin $display("ERROR 0F53 not in the table"); errors++; end
                else begin
                    expect_entry(e, inner);
                    axi_read(12'h100 + 16 * e + 12, w3);
                    axi_read(12'h200 + 4 * e, via);
                    if (w3[15:0] !== 16'h0CD2 || via !== 32'h0DCF157C) begin
                        $display("ERROR relay meta: word3 %h via %h", w3, via); errors++;
                    end else
                        $display("  ok: 0F53 in entry %0d via %04h, relay RSSI %0d SNR %0d, gw RSSI %0d SNR %0d", e,
                                 via[15:0], $signed(via[23:16]), $signed(via[31:24]), $signed(w3[7:0]), $signed(w3[15:8]));
                end
                // the 0xD1 downlink carries the far node's 12 bytes unchanged (flags 0x06 incl. bit2)
                begin
                    int hit = 0;
                    got.delete(); got_t.delete();
                    axi_write(9'h004, 1);
                    wait (got.size() >= 3);
                    wait (got.size() >= got[2] + 4);                          // whole frame: LEN + 4 bytes
                    for (int s = 0; s + 12 <= got.size(); s++) begin
                        int m = 1;
                        for (int j = 0; j < 12; j++) if (got[s + j] != inner[j]) m = 0;
                        if (m) hit = 1;
                    end
                    if (!hit) begin $display("ERROR 0F53 record (flags 06) not found unchanged in the downlink (%0d bytes)", got.size()); errors++; end
                    else $display("  ok: downlink (%0d bytes) has the 0F53 record unchanged, flags 0x06", got.size());
                end
                // relayer not allowed (2222) / far node not allowed (3333): both dropped, the table keeps 0F53 via 157C
                b = {8'h13, 8'hE1, 8'h22, 8'h22, 8'hCF, 8'h0D, inner, 8'hD2, 8'h0C};
                b[8] = 8'h06;                                                        // seq 6
                send_frame_raw(b);
                b = {8'h13, 8'hE1, 8'h7C, 8'h15, 8'hCF, 8'h0D, inner, 8'hD2, 8'h0C};
                b[6] = 8'h33; b[7] = 8'h33;                                          // far node 3333
                send_frame_raw(b);
                b = {8'h13, 8'hE2, 8'h7C, 8'h15, 8'hCF, 8'h0D, inner, 8'hD2, 8'h0C}; // LEN 19 but type E2
                send_frame_raw(b);
                expect_reg("FRAMES_OK unchanged", 9'h00C, ok0 + 1);
                expect_reg("DROPPED_ADDR +2", 9'h010, drop0 + 2);
                expect_reg("LENGTH_ERRORS +1", 9'h01C, len0 + 1);
                expect_reg("RELAYS_OK still 1", 9'h078, 1);
                if (e >= 0) expect_reg("VIA unchanged", 12'h200 + 4 * e, 32'h0DCF157C);
                // 0F53 heard directly again -> VIA cleared
                b = inner; b[2] = 8'h07; b[11] = 8'h00;                             // seq 7, flags 0
                send_uplink(b);
                if (e >= 0) begin
                    expect_reg("VIA cleared (direct)", 12'h200 + 4 * e, 32'h0);
                    expect_entry(e, b);
                end
                expect_reg("VIA above entry 15 = 0", 12'h23C + 4, 32'h0);
            end

            $display("test 18: join 0xA1 (golden frame) -> FIFO without whitelist, 1/s limit; A2 out; DELIVERED from 8102");
            begin
                // dev_id 9B9D0B15 wants ALPHA-2, PIN 1234, fw 1.14, battery unknown, req_seq 0, gw RSSI -52 SNR 11
                byte unsigned a1[$] = {8'hAA, 8'h55, 8'h13, 8'hA1, 8'h00, 8'h00, 8'hFE, 8'hFF, 8'h00, 8'h15, 8'h0B, 8'h9D,
                                       8'h9B, 8'h01, 8'h02, 8'hD2, 8'h04, 8'h01, 8'h0E, 8'hFF, 8'hCC, 8'h0B, 8'hFE};
                // Zybo answer: msg_id 0x30, accepted, address 8102, ALPHA-2
                byte unsigned a2[$] = {8'hAA, 8'h55, 8'h0F, 8'hA2, 8'hFE, 8'hFF, 8'hFF, 8'hFF, 8'h30, 8'h15, 8'h0B, 8'h9D,
                                       8'h9B, 8'h02, 8'h81, 8'h01, 8'h02, 8'h00, 8'hCD};
                // DELIVERED for that A2 from the new address 8102
                byte unsigned dv[$] = {8'hAA, 8'h55, 8'h11, 8'hC5, 8'h02, 8'h81, 8'hFE, 8'hFF, 8'h00, 8'h01, 8'hFE, 8'hFF,
                                       8'h30, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hCC, 8'h0B, 8'hB5};
                byte unsigned b[$], pay[$];
                reg [31:0] wr0, ok0, drop0, len0, w[8];
                int hit;
                axi_read(9'h04C, wr0); axi_read(9'h058, ok0); axi_read(9'h05C, drop0); axi_read(9'h01C, len0);
                expect_reg("JOINS_OK = 0", 9'h07C, 0);
                // the same A1 twice back to back (like the gateway's repeats): the 2nd one comes < 1 s later
                repeat (2) foreach (a1[k]) begin
                    rx = 1'b0; #(BIT_NS);
                    for (int i = 0; i < 8; i++) begin rx = a1[k][i]; #(BIT_NS); end
                    rx = 1'b1; #(BIT_NS);
                end
                #(3 * BIT_NS);
                expect_reg("JOINS_OK = 1", 9'h07C, 1);
                expect_reg("JOINS_LIMITED = 1", 9'h080, 1);
                expect_reg("CMD_WR_COUNT +1", 9'h04C, wr0 + 1);
                expect_reg("CMDS_OK unchanged", 9'h058, ok0);
                expect_reg("CMDS_DROPPED unchanged", 9'h05C, drop0);
                expect_reg("LENGTH_ERRORS unchanged", 9'h01C, len0);
                for (int j = 0; j < 8; j++) axi_read(12'h800 + 32 * (wr0 % 64) + 4 * j, w[j]);
                if (w[0] !== 32'hFE0000A1 || w[1] !== 32'h0B1500FF || w[2] !== 32'h02019B9D || w[3] !== 32'h0E0104D2 ||
                    w[4] !== 32'h00000BCC || w[6] !== wr0 || w[7] !== 32'h000000FF) begin
                    $display("ERROR A1 entry: %h %h %h %h meta %h seq %0d w7 %h", w[0], w[1], w[2], w[3], w[4], w[6], w[7]); errors++;
                end else
                    $display("  ok: A1 entry = dev_id %h team %0d number %0d PIN %0d fw %0d.%0d battery %h, RSSI %0d SNR %0d",
                             {w[2][15:0], w[1][31:16]}, w[2][23:16], w[2][31:24], w[3][15:0], w[3][23:16], w[3][31:24],
                             w[7][7:0], $signed(w[4][7:0]), $signed(w[4][15:8]));
                // 1 s later (SEC_CYC clocks) the next one passes again
                repeat (100_000) @(posedge clk);
                b = a1[2:a1.size() - 2]; b[6] = 8'h01;                          // req_seq 1
                send_frame_raw(b);
                expect_reg("JOINS_OK = 2 (after 1 s)", 9'h07C, 2);
                expect_reg("CMD_WR_COUNT +2", 9'h04C, wr0 + 2);
                // an A1 from a set-up address (157C) goes through the whitelist; from an unknown one (2222) it is dropped
                b = a1[2:a1.size() - 2]; b[2] = 8'h7C; b[3] = 8'h15;
                send_frame_raw(b);
                b[2] = 8'h22; b[3] = 8'h22;
                send_frame_raw(b);
                expect_reg("JOINS_OK still 2", 9'h07C, 2);
                expect_reg("CMDS_OK +1 (157C)", 9'h058, ok0 + 1);
                expect_reg("CMDS_DROPPED +1 (2222)", 9'h05C, drop0 + 1);
                // the A2 answer goes out exactly as the firmware golden frame
                pay = a2[3:17];
                axi_write(9'h060, {pay[3], pay[2], pay[1], pay[0]});
                axi_write(9'h064, {pay[7], pay[6], pay[5], pay[4]});
                axi_write(9'h068, {pay[11], pay[10], pay[9], pay[8]});
                axi_write(9'h06C, {8'h00, pay[14], pay[13], pay[12]});
                repeat (GAP + 10) @(posedge clk);
                got.delete(); got_t.delete();
                axi_write(9'h070, 1);
                wait (got.size() >= 19);
                repeat (GAP) @(posedge clk);
                hit = 0;
                for (int s = 0; s + 19 <= got.size(); s++) begin
                    int m = 1;
                    for (int j = 0; j < 19; j++) if (got[s + j] != a2[j]) m = 0;
                    if (m) hit = 1;
                end
                if (!hit) begin $write("ERROR A2 frame not sent as golden:"); foreach (got[i]) $write(" %02h", got[i]); $display(""); errors++; end
                else begin $write("  ok: A2 out:"); foreach (a2[i]) $write(" %02h", a2[i]); $display(""); end
                // DELIVERED from 8102 before it is in the whitelist: dropped; after the GUI added it: stored
                axi_read(9'h04C, wr0); axi_read(9'h05C, drop0);
                foreach (dv[k]) begin
                    rx = 1'b0; #(BIT_NS);
                    for (int i = 0; i < 8; i++) begin rx = dv[k][i]; #(BIT_NS); end
                    rx = 1'b1; #(BIT_NS);
                end
                #(3 * BIT_NS);
                expect_reg("DELIVERED 8102 not allowed yet", 9'h05C, drop0 + 1);
                axi_write(9'h040, 11); axi_write(9'h044, 32'h00018102);            // the GUI adds 8102
                foreach (dv[k]) begin
                    rx = 1'b0; #(BIT_NS);
                    for (int i = 0; i < 8; i++) begin rx = dv[k][i]; #(BIT_NS); end
                    rx = 1'b1; #(BIT_NS);
                end
                #(3 * BIT_NS);
                expect_reg("CMD_WR_COUNT +1", 9'h04C, wr0 + 1);
                for (int j = 0; j < 8; j++) axi_read(12'h800 + 32 * (wr0 % 64) + 4 * j, w[j]);
                if (w[0] !== 32'hFE8102C5 || w[1] !== 32'hFE0100FF || w[2] !== 32'h000030FF || w[3] !== 32'h0 ||
                    w[4][15:0] !== 16'h0BCC || w[7] !== 32'h0) begin
                    $display("ERROR DELIVERED 8102 entry: %h %h %h %h meta %h w7 %h", w[0], w[1], w[2], w[3], w[4], w[7]); errors++;
                end else
                    $display("  ok: C5 DELIVERED from 8102 for FFFE#0x30 stored, bytes 15/16 = 0");
            end

            $display("test 19: 0xA4 LEAVE -> FIFO; TBL_DELETE removes a node (last entry fills the gap)");
            begin
                byte unsigned lv[$], r8102[$];
                reg [31:0] wr0, ok0, n0, n1, w[8], a[16], r[16][3], v;
                int found;
                // 8102 (ALPHA-2) leaves: [A4][src 8102][dst FFFE][msg_id 5][dev_id 9B9D0B15][0 x5]
                lv = {8'hA4, 8'h02, 8'h81, 8'hFE, 8'hFF, 8'h05, 8'h15, 8'h0B, 8'h9D, 8'h9B, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00};
                axi_read(9'h04C, wr0); axi_read(9'h058, ok0);
                send_cmd(lv);
                expect_reg("CMDS_OK +1 (A4)", 9'h058, ok0 + 1);
                for (int j = 0; j < 8; j++) axi_read(12'h800 + 32 * (wr0 % 64) + 4 * j, w[j]);
                if (w[0] !== 32'hFE8102A4 || w[1] !== 32'h0B1505FF || w[2] !== 32'h00009B9D) begin
                    $display("ERROR A4 entry: %h %h %h", w[0], w[1], w[2]); errors++;
                end else $display("  ok: A4 LEAVE from 8102, dev_id 9B9D0B15 in the FIFO");
                // 8102 also has a position in the table
                r8102 = {8'h02, 8'h81, 8'h01, 8'h40, 8'h8B, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00};
                send_uplink(r8102);
                axi_read(9'h008, n0);
                for (int i = 0; i < n0; i++) for (int j = 0; j < 3; j++) axi_read(12'h100 + 16 * i + 4 * j, r[i][j]);
                $display("  table before: %0d nodes, entry 0 = %04h, last = %04h", n0, r[0][0][15:0], r[n0 - 1][0][15:0]);
                // delete entry 0's node: the last one moves into slot 0
                axi_write(9'h084, r[0][0][15:0]);
                repeat (10) @(posedge clk);
                expect_reg("TABLE_COUNT -1", 9'h008, n0 - 1);
                expect_reg("TBL_DELETE count = 1", 9'h084, 1);
                axi_read(12'h100, v);
                if (v !== r[n0 - 1][0]) begin $display("ERROR slot 0 = %h, expected the old last %h", v, r[n0 - 1][0]); errors++; end
                else begin
                    axi_read(12'h104, w[1]); axi_read(12'h108, w[2]);
                    if (w[1] !== r[n0 - 1][1] || w[2] !== r[n0 - 1][2]) begin $display("ERROR slot 0 record mixed"); errors++; end
                    else $display("  ok: slot 0 now holds the old last entry %04h (whole record)", v[15:0]);
                end
                // an address that is not there: nothing changes
                axi_write(9'h084, 32'h4444);
                repeat (10) @(posedge clk);
                expect_reg("TABLE_COUNT same (4444 unknown)", 9'h008, n0 - 1);
                expect_reg("TBL_DELETE still 1", 9'h084, 1);
                // the kicked / leaving node: 8102
                axi_write(9'h084, 32'h8102);
                repeat (10) @(posedge clk);
                axi_read(9'h008, n1);
                found = 0;
                for (int i = 0; i < n1; i++) begin axi_read(12'h100 + 16 * i, v); if (v[15:0] == 16'h8102) found = 1; end
                if (n1 !== n0 - 2 || found) begin $display("ERROR 8102 delete: count %0d found %0d", n1, found); errors++; end
                else $display("  ok: 8102 removed, %0d nodes left", n1);
                expect_reg("TBL_DELETE = 2", 9'h084, 2);
                // the deleted node's frames are still accepted if it is in the whitelist: it comes back (new slot)
                send_uplink(r8102);
                expect_reg("8102 back (still whitelisted)", 9'h008, n1 + 1);
            end

            $display("test 20: kick / leave golden frames (ALPHA-1 = 8101); delete right after a table update");
            begin
                byte unsigned a4[$] = {8'hAA, 8'h55, 8'h11, 8'hA4, 8'h01, 8'h81, 8'hFE, 8'hFF, 8'h05, 8'h15, 8'h0B, 8'h9D,
                                       8'h9B, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hCC, 8'h0B, 8'h7B};
                byte unsigned kick[$] = {8'hAA, 8'h55, 8'h0F, 8'hA3, 8'hFE, 8'hFF, 8'h01, 8'h81, 8'h31, 8'h15, 8'h0B, 8'h9D,
                                         8'h9B, 8'h01, 8'h00, 8'h00, 8'h00, 8'h00, 8'hBB};
                byte unsigned dv[$] = {8'hAA, 8'h55, 8'h11, 8'hC5, 8'h01, 8'h81, 8'hFE, 8'hFF, 8'h00, 8'h01, 8'hFE, 8'hFF,
                                       8'h31, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'hCC, 8'h0B, 8'hA0};
                byte unsigned conf[$] = {8'hAA, 8'h55, 8'h0F, 8'hA3, 8'hFE, 8'hFF, 8'h01, 8'h81, 8'h32, 8'h15, 8'h0B, 8'h9D,
                                         8'h9B, 8'h02, 8'h00, 8'h00, 8'h00, 8'h00, 8'hA5};
                byte unsigned frm[$], pay[$], rx_[$], ry_[$];
                reg [31:0] wr0, w[8], n, v;
                int hit, cx, cy, bad;
                axi_write(9'h040, 12); axi_write(9'h044, 32'h00018101);            // ALPHA-1 is a member
                // A4 golden -> FIFO, then C5 golden -> FIFO (FIFO emptied first: earlier tests filled it)
                axi_read(9'h04C, wr0);
                axi_write(9'h050, wr0);
                for (int f = 0; f < 2; f++) begin
                    if (f) frm = dv; else frm = a4;
                    foreach (frm[k]) begin
                        rx = 1'b0; #(BIT_NS);
                        for (int i = 0; i < 8; i++) begin rx = frm[k][i]; #(BIT_NS); end
                        rx = 1'b1; #(BIT_NS);
                    end
                end
                #(3 * BIT_NS);
                expect_reg("CMD_WR_COUNT +2", 9'h04C, wr0 + 2);
                for (int j = 0; j < 3; j++) axi_read(12'h800 + 32 * (wr0 % 64) + 4 * j, w[j]);
                if (w[0] !== 32'hFE8101A4 || w[1] !== 32'h0B1505FF || w[2] !== 32'h00009B9D) begin
                    $display("ERROR A4 golden entry: %h %h %h", w[0], w[1], w[2]); errors++;
                end else $display("  ok: A4 golden: LEAVE from 8101 msg 5 dev 9B9D0B15");
                for (int j = 0; j < 3; j++) axi_read(12'h800 + 32 * ((wr0 + 1) % 64) + 4 * j, w[j]);
                if (w[0] !== 32'hFE8101C5 || w[1] !== 32'hFE0100FF || w[2] !== 32'h000031FF) begin
                    $display("ERROR C5 golden entry: %h %h %h", w[0], w[1], w[2]); errors++;
                end else $display("  ok: C5 golden: DELIVERED from 8101 for FFFE#0x31");
                // both A3 frames go out exactly as the golden frames
                for (int f = 0; f < 2; f++) begin
                    if (f) frm = conf; else frm = kick;
                    pay = frm[3:17];
                    axi_write(9'h060, {pay[3], pay[2], pay[1], pay[0]});
                    axi_write(9'h064, {pay[7], pay[6], pay[5], pay[4]});
                    axi_write(9'h068, {pay[11], pay[10], pay[9], pay[8]});
                    axi_write(9'h06C, {8'h00, pay[14], pay[13], pay[12]});
                    repeat (GAP + 10) @(posedge clk);
                    got.delete(); got_t.delete();
                    axi_write(9'h070, 1);
                    wait (got.size() >= 19);
                    repeat (GAP) @(posedge clk);
                    hit = 0;
                    for (int s = 0; s + 19 <= got.size(); s++) begin
                        int m = 1;
                        for (int j = 0; j < 19; j++) if (got[s + j] != frm[j]) m = 0;
                        if (m) hit = 1;
                    end
                    if (!hit) begin $write("ERROR A3 not golden:"); foreach (got[i]) $write(" %02h", got[i]); $display(""); errors++; end
                    else $display("  ok: A3 %s out byte for byte (CRC %02h)", f ? "leave confirmed" : "KICK", frm[18]);
                end
                // delete Y written 0..6 clocks after X's table update: X updated, Y gone, nothing mixed or doubled
                axi_write(9'h040, 13); axi_write(9'h044, 32'h00011A01);
                axi_write(9'h040, 14); axi_write(9'h044, 32'h00011B02);
                rx_ = {8'h01, 8'h1A, 8'h00, 8'h11, 8'h22, 8'h33, 8'h18, 8'h44, 8'h55, 8'h66, 8'h11, 8'h00};
                ry_ = {8'h02, 8'h1B, 8'h00, 8'hAA, 8'hBB, 8'hCC, 8'h18, 8'hDD, 8'hEE, 8'hFF, 8'h11, 8'h00};
                send_uplink(rx_);
                bad = 0;
                for (int off = 0; off <= 6; off++) begin
                    send_uplink(ry_);                                              // Y (back) in the table
                    rx_[2] = off + 1;                                              // X: new seq each round
                    fork
                        send_uplink(rx_);
                        begin
                            @(posedge dut.u_server.pkt_valid);
                            repeat (off) @(posedge clk);
                            axi_write(9'h084, 32'h1B02);
                        end
                    join
                    repeat (20) @(posedge clk);
                    axi_read(9'h008, n);
                    cx = 0; cy = 0;
                    for (int i = 0; i < n; i++) begin
                        axi_read(12'h100 + 16 * i, v);
                        if (v[15:0] == 16'h1A01) begin cx++; if (v[23:16] != off + 1) bad++; end
                        if (v[15:0] == 16'h1B02) cy++;
                    end
                    if (cx != 1 || cy != 0) bad++;
                end
                if (bad) begin $display("ERROR delete next to an update: %0d bad rounds", bad); errors++; end
                else $display("  ok: delete 0..6 clocks after an update: X updated once, Y removed, every time");
            end
        end

        $display("test 21: v9 security with the node firmware V1.16.0 golden frames (test key 00 01 .. 0F)");
        begin
                byte unsigned g_a1[$] = {8'hAA, 8'h55, 8'h20, 8'h51, 8'hA3, 8'h60, 8'h17, 8'hAD, 8'h01, 8'h00, 8'h00, 8'h00, 8'h52, 8'h87, 8'h55, 8'h15, 8'h2A, 8'h63, 8'h7C, 8'h05, 8'h8C, 8'h3A, 8'h48, 8'h93, 8'hE1, 8'hE0, 8'h67, 8'hD2, 8'h65, 8'h7D, 8'hF9, 8'hF1, 8'h3C, 8'hC4, 8'h08, 8'hAA};
                byte unsigned g_c5[$] = {8'hAA, 8'h55, 8'h1E, 8'h51, 8'hA3, 8'h60, 8'h17, 8'hAD, 8'h02, 8'h00, 8'h00, 8'h00, 8'h30, 8'hE9, 8'h5E, 8'h02, 8'hBF, 8'h01, 8'h14, 8'h6F, 8'h5B, 8'h0D, 8'hE9, 8'h45, 8'h2F, 8'h6E, 8'hBA, 8'hD4, 8'h15, 8'h9E, 8'h52, 8'hC4, 8'h08, 8'h84};
                byte unsigned g_pos[$] = {8'hAA, 8'h55, 8'h1B, 8'h51, 8'hA3, 8'h60, 8'h17, 8'hAD, 8'h05, 8'h00, 8'h00, 8'h00, 8'hAD, 8'hA3, 8'hF2, 8'hAC, 8'h03, 8'h22, 8'h79, 8'hB2, 8'h7B, 8'hB0, 8'h34, 8'h9F, 8'h45, 8'h21, 8'hF7, 8'hA2, 8'hC4, 8'h08, 8'hEE};
                byte unsigned g_c1[$] = {8'hAA, 8'h55, 8'h1E, 8'h51, 8'hA3, 8'h60, 8'h17, 8'hAD, 8'h06, 8'h00, 8'h00, 8'h00, 8'h0D, 8'h99, 8'hA9, 8'hC2, 8'h32, 8'hA8, 8'h27, 8'h5E, 8'hF4, 8'hDC, 8'hA0, 8'hB7, 8'hC3, 8'h78, 8'h00, 8'h75, 8'hFB, 8'h4A, 8'h35, 8'hC4, 8'h08, 8'h4D};
                byte unsigned g_e1[$] = {8'hAA, 8'h55, 8'h2D, 8'h51, 8'h50, 8'h40, 8'h4C, 8'hD7, 8'hB3, 8'h16, 8'h00, 8'h00, 8'h27, 8'h54, 8'hC8, 8'h3A, 8'hA6, 8'h32, 8'h43, 8'h36, 8'h5D, 8'h22, 8'h22, 8'h95, 8'h99, 8'hC1, 8'hA1, 8'h30, 8'h7B, 8'h2D, 8'hFE, 8'h80, 8'h89, 8'h0C, 8'h79, 8'h82, 8'hE4, 8'h4C, 8'h85, 8'h42, 8'h33, 8'hA3, 8'h39, 8'h25, 8'h7F, 8'hCF, 8'hC4, 8'h08, 8'h53};
                byte unsigned g_e2[$] = {8'hAA, 8'h55, 8'h30, 8'h51, 8'h50, 8'h40, 8'h4C, 8'hD7, 8'hB4, 8'h16, 8'h00, 8'h00, 8'h32, 8'h5A, 8'hBD, 8'h22, 8'h3F, 8'h43, 8'hF1, 8'hF9, 8'h97, 8'h8F, 8'h07, 8'hDD, 8'hD6, 8'hF3, 8'hE4, 8'h2A, 8'hB8, 8'h08, 8'h25, 8'h33, 8'h06, 8'h43, 8'hB4, 8'hD5, 8'h9F, 8'h43, 8'h00, 8'h23, 8'h76, 8'hDB, 8'h5E, 8'h14, 8'h54, 8'hA7, 8'h48, 8'hB4, 8'h11, 8'hC4, 8'h08, 8'h9C};
                byte unsigned g_a2[$] = {8'hAA, 8'h55, 8'h1D, 8'h03, 8'h51, 8'hFE, 8'hFF, 8'hFF, 8'hFF, 8'hF4, 8'h01, 8'h00, 8'h00, 8'hCC, 8'hB0, 8'hB2, 8'hBF, 8'h87, 8'h5E, 8'h74, 8'h57, 8'h5B, 8'hF0, 8'h13, 8'h93, 8'h1D, 8'h9B, 8'hF6, 8'h39, 8'h86, 8'h9B, 8'hE2, 8'h68};
                byte unsigned g_tbl[$] = {8'hAA, 8'h55, 8'h28, 8'h01, 8'h51, 8'hFE, 8'hFF, 8'hFF, 8'hFF, 8'h64, 8'h00, 8'h00, 8'h00, 8'h88, 8'h45, 8'h8D, 8'hA1, 8'h94, 8'h93, 8'h64, 8'h33, 8'h1A, 8'hF8, 8'hFC, 8'hF2, 8'hFE, 8'hA4, 8'h20, 8'hD8, 8'hCE, 8'hC9, 8'h3B, 8'hAC, 8'hC7, 8'h92, 8'h4A, 8'h95, 8'hDE, 8'hE8, 8'hFB, 8'h5B, 8'hE9, 8'h66, 8'h0F};
                reg [31:0] wr0, sec0, mic0, pdrop0, rpl0, sent0, w[8], v, n;
                byte unsigned frm[$];
                int hit, fpos, ffar;
                // key (KEYi = key bytes 4i..4i+3 as a little-endian word), SECURE_ONLY = 1, empty the replay table
                axi_write(9'h08C, 32'h03020100); axi_write(9'h090, 32'h07060504);
                axi_write(9'h094, 32'h0B0A0908); axi_write(9'h098, 32'h0F0E0D0C);
                axi_write(9'h088, 32'h6);
                expect_reg("SEC_CTRL = SECURE_ONLY", 9'h088, 32'h2);
                expect_reg("KEY0 is write-only", 9'h08C, 32'h0);
                axi_write(9'h040, 20); axi_write(9'h044, 32'h00018102);           // ALPHA-2 (the joined node)
                axi_write(9'h040, 21); axi_write(9'h044, 32'h00011764);           // the relayer
                axi_write(9'h040, 22); axi_write(9'h044, 32'h00018203);           // the far node
                axi_read(9'h04C, wr0); axi_write(9'h050, wr0);                    // FIFO empty
                axi_read(9'h0A0, sec0); axi_read(9'h0AC, mic0); axi_read(9'h0A8, pdrop0); axi_read(9'h0B0, rpl0);
                for (int f = 0; f < 6; f++) begin                                // A1, C5, position, C1, E1, E2
                    case (f)
                        0: frm = g_a1;  1: frm = g_c5;  2: frm = g_pos;
                        3: frm = g_c1;  4: frm = g_e1;  default: frm = g_e2;
                    endcase
                    foreach (frm[k]) begin
                        rx = 1'b0; #(BIT_NS);
                        for (int i = 0; i < 8; i++) begin rx = frm[k][i]; #(BIT_NS); end
                        rx = 1'b1; #(BIT_NS);
                    end
                    #(20 * BIT_NS);
                end
                expect_reg("SEC_OK +6", 9'h0A0, sec0 + 6);
                expect_reg("MIC_FAIL unchanged", 9'h0AC, mic0);
                expect_reg("CMD_WR_COUNT +4 (A1, C5, C1, relayed C5)", 9'h04C, wr0 + 4);
                for (int e = 0; e < 4; e++) begin
                    for (int j = 0; j < 5; j++) axi_read(12'h800 + 32 * ((wr0 + e) % 64) + 4 * j, w[j]);
                    v = (e == 0) ? 32'hFE0000A1 : (e == 1) ? 32'hFE8102C5 : (e == 2) ? 32'hFF8102C1 : 32'hFE8203C5;
                    if (w[0] !== v || w[4][15:0] !== 16'h08C4) begin
                        $display("ERROR golden FIFO entry %0d: %h (want %h), rssi/snr %h", e, w[0], v, w[4]); errors++;
                    end
                end
                if (w[0] === 32'hFE8203C5) $display("  ok: FIFO = A1 join (dev AD1760A3), C5 from 8102, C1 from 8102, C5 from far node 8203 via E2");
                axi_read(9'h008, n);
                fpos = 0; ffar = 0;
                for (int i = 0; i < n; i++) begin
                    axi_read(12'h100 + 16 * i, v);
                    // v10: flags (byte 11 = word 2 bits 31..24) bit 2 "via relay" set by the PL for the relayed far
                    // node (sent 03 -> stored 07), cleared for the direct one (00); RDEV 0 (0x51 packets)
                    if (v === 32'h90008102) begin
                        axi_read(12'h200 + 4 * i, w[0]); axi_read(12'h108 + 16 * i, w[1]); axi_read(12'h240 + 4 * i, w[2]);
                        fpos = (w[0] === 32'h0) && (w[1][31:24] === 8'h80) && (w[2] === 32'h0);   // v11: bit 7 direct
                    end
                    if (v === 32'h11058203) begin
                        axi_read(12'h200 + 4 * i, w[0]); axi_read(12'h108 + 16 * i, w[1]); axi_read(12'h240 + 4 * i, w[2]);
                        ffar = (w[0] === 32'h0AB01764) && (w[1][31:24] === 8'h07) && (w[2] === 32'h0);
                    end
                end
                if (!fpos || !ffar) begin $display("ERROR golden table: position %0d, relayed far node %0d", fpos, ffar); errors++; end
                else $display("  ok: table: ALPHA-2 (8102) direct (flags 00 -> 80), 8203 via 1764 (relay -80 dBm / 10 dB, flags 03 -> 07 via relay)");
                // the same position again = replay; a plain frame = dropped (SECURE_ONLY)
                frm = g_pos;
                foreach (frm[k]) begin
                    rx = 1'b0; #(BIT_NS);
                    for (int i = 0; i < 8; i++) begin rx = frm[k][i]; #(BIT_NS); end
                    rx = 1'b1; #(BIT_NS);
                end
                #(20 * BIT_NS);
                expect_reg("REPLAY_DROP +1 (position sent again)", 9'h0B0, rpl0 + 1);
                send_uplink({8'h7C, 8'h15, 8'h44, 8'h00, 8'h00, 8'h00, 8'h18, 8'h00, 8'h00, 8'h00, 8'h11, 8'h00});
                #(20 * BIT_NS);
                expect_reg("PLAIN_DROP +1 (plain position, SECURE_ONLY)", 9'h0A8, pdrop0 + 1);
                // downlink: DL_CTR = 500, SECURE_TX = 1, the A2 of golden frame 7 -> exactly the golden UART frame
                axi_read(9'h0BC, sent0);
                axi_write(9'h09C, 500);
                expect_reg("DL_CTR loaded", 9'h09C, 500);
                axi_write(9'h088, 32'h3);
                axi_write(9'h060, 32'hFFFFFEA2); axi_write(9'h064, 32'h60A330FF);
                axi_write(9'h068, 32'h8102AD17); axi_write(9'h06C, 32'h00000201);
                repeat (GAP + 10) @(posedge clk);
                got.delete(); got_t.delete();
                axi_write(9'h070, 1);
                wait (got.size() >= 33);
                repeat (GAP) @(posedge clk);
                hit = (got.size() == 33);
                for (int j = 0; j < 33 && hit; j++) if (got[j] != g_a2[j]) hit = 0;
                if (!hit) begin $write("ERROR A2 not golden:"); foreach (got[i]) $write(" %02h", got[i]); $display(""); errors++; end
                else $display("  ok: secure A2 (ctr 500, tx_repeat 3) out byte for byte = golden frame 7 (CRC 68)");
                expect_reg("DL_CTR now 501", 9'h09C, 501);
                expect_reg("SEC_SENT +1", 9'h0BC, sent0 + 1);
                axi_write(9'h088, 32'h0);                                         // back to plain
        end

        $display("test 22: v10 0x52 relay request naming its relayer (direct): bit 2 cleared, RDEV stored");
        begin
            // ALPHA-2 (dev AD1760A3, ctr 50) sends a 0x52 position, relay_dev D74C4050, flags 06 (relay request +
            // a wrong "via relay" bit): stored with flags 02 (heard directly) and RDEV D74C4050
            byte unsigned g52[$] = {8'hAA, 8'h55, 8'h1F, 8'h52, 8'hA3, 8'h60, 8'h17, 8'hAD, 8'h32, 8'h00, 8'h00, 8'h00,
                8'h50, 8'h40, 8'h4C, 8'hD7, 8'h53, 8'h60, 8'h01, 8'h8E, 8'hDC, 8'hEE, 8'h90, 8'hBA, 8'h34, 8'h63, 8'h76,
                8'hE8, 8'h31, 8'hA7, 8'hE7, 8'h64, 8'hC4, 8'h08, 8'h24};
            reg [31:0] n, v, sec0, w1, w2;
            int ok;
            axi_write(9'h088, 32'h2);                                             // SECURE_ONLY (key still loaded)
            axi_read(9'h0A0, sec0);
            foreach (g52[k]) begin
                rx = 1'b0; #(BIT_NS);
                for (int i = 0; i < 8; i++) begin rx = g52[k][i]; #(BIT_NS); end
                rx = 1'b1; #(BIT_NS);
            end
            #(20 * BIT_NS);
            expect_reg("SEC_OK +1 (0x52)", 9'h0A0, sec0 + 1);
            axi_read(9'h008, n);
            ok = 0;
            for (int i = 0; i < n; i++) begin
                axi_read(12'h100 + 16 * i, v);
                if (v[15:0] == 16'h8102 && v[23:16] == 8'h77) begin
                    axi_read(12'h108 + 16 * i, w1); axi_read(12'h240 + 4 * i, w2);
                    ok = (w1[31:24] === 8'h82) && (w2 === 32'hD74C4050);
                    if (!ok) $display("ERROR 0x52 entry: flags %02h (want 82), RDEV %h (want D74C4050)", w1[31:24], w2);
                end
            end
            if (!ok) errors++;
            else $display("  ok: 0x52 from ALPHA-2: flags 06 -> 82 (direct: bit 2 cleared, bit 7 set), RDEV = D74C4050 (chosen relayer)");
            axi_write(9'h088, 32'h0);
        end

        $display("test 23: firmware V1.17 golden frames (0x52 relay selection) through the registers");
        begin
            byte unsigned f1[$] = {8'hAA, 8'h55, 8'h1F, 8'h52, 8'h55, 8'hBA, 8'hC8, 8'hA3, 8'h05, 8'h00, 8'h00, 8'h00, 8'h01, 8'h00, 8'h00, 8'hA0, 8'h33, 8'h2B, 8'hF5, 8'h23, 8'h54, 8'hFD, 8'hB4, 8'h65, 8'hF3, 8'h74, 8'hF4, 8'hB6, 8'h64, 8'hD4, 8'h02, 8'h46, 8'hA6, 8'hFB, 8'h48};
            byte unsigned f2[$] = {8'hAA, 8'h55, 8'h1F, 8'h52, 8'h55, 8'hBA, 8'hC8, 8'hA3, 8'h13, 8'h00, 8'h00, 8'h00, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'h72, 8'h42, 8'h43, 8'hBD, 8'hA3, 8'h9C, 8'hDF, 8'h73, 8'h04, 8'h3A, 8'h2B, 8'h68, 8'hB7, 8'h0D, 8'hD8, 8'hA6, 8'hFB, 8'hF3};
            byte unsigned f3[$] = {8'hAA, 8'h55, 8'h31, 8'h51, 8'h50, 8'h40, 8'h4C, 8'hD7, 8'h05, 8'h00, 8'h00, 8'h00, 8'h25, 8'h97, 8'h0E, 8'hBC, 8'h5B, 8'h84, 8'hC9, 8'hF6, 8'h56, 8'hFB, 8'h13, 8'h2C, 8'hE4, 8'hF5, 8'hFF, 8'hCD, 8'hF1, 8'hBF, 8'hD6, 8'hF8, 8'h03, 8'hAD, 8'h6B, 8'h3F, 8'hF9, 8'h66, 8'hAF, 8'hDC, 8'h42, 8'hBA, 8'h03, 8'hE3, 8'hEF, 8'h8F, 8'hF7, 8'h73, 8'hEA, 8'hB2, 8'hA6, 8'hFB, 8'h00};
            byte unsigned f4[$] = {8'hAA, 8'h55, 8'h34, 8'h51, 8'h50, 8'h40, 8'h4C, 8'hD7, 8'h06, 8'h00, 8'h00, 8'h00, 8'h64, 8'hA3, 8'h9F, 8'h6F, 8'h00, 8'h40, 8'hCC, 8'h55, 8'h33, 8'h87, 8'h4D, 8'h36, 8'h91, 8'h69, 8'hC0, 8'h4B, 8'h0F, 8'hEC, 8'h71, 8'h19, 8'h7D, 8'h69, 8'h00, 8'h78, 8'h34, 8'hE5, 8'h49, 8'h16, 8'hF0, 8'hB9, 8'hE1, 8'h00, 8'h44, 8'hAD, 8'h28, 8'h57, 8'h4C, 8'h57, 8'h5C, 8'h7B, 8'h9F, 8'hA6, 8'hFB, 8'h37};
            byte unsigned fx[$] = {8'hAA, 8'h55, 8'h1F, 8'h52, 8'h44, 8'h33, 8'h22, 8'h11, 8'h34, 8'h00, 8'h00, 8'h00, 8'hFF, 8'hFF, 8'hFF, 8'hFF, 8'h9A, 8'h00, 8'h84, 8'h0B, 8'hB0, 8'hAE, 8'hA6, 8'hE0, 8'hA8, 8'hAC, 8'h0E, 8'hF7, 8'h79, 8'h00, 8'hB7, 8'hC5, 8'hA6, 8'hFB, 8'h1E};
            byte unsigned frm[$];
            reg [31:0] wr0, n, v, w2, rv, vi;
            int i0, i8;
            // find the table entries of 0F53 and 8203 (index or -1)
            axi_write(9'h040, 23); axi_write(9'h044, 32'h00010F53);             // 0F53 allowed
            axi_write(9'h088, 32'h6);                                             // SECURE_ONLY, empty replay table
            axi_read(9'h04C, wr0); axi_write(9'h050, wr0);
            for (int f = 0; f < 5; f++) begin
                case (f) 0: frm = f1; 1: frm = f3; 2: frm = f4; 3: frm = fx; default: frm = f2; endcase
                foreach (frm[k]) begin
                    rx = 1'b0; #(BIT_NS);
                    for (int i = 0; i < 8; i++) begin rx = frm[k][i]; #(BIT_NS); end
                    rx = 1'b1; #(BIT_NS);
                end
                #(20 * BIT_NS);
                axi_read(9'h008, n);
                i0 = -1; i8 = -1;
                for (int i = 0; i < n; i++) begin
                    axi_read(12'h100 + 16 * i, v);
                    if (v[15:0] == 16'h0F53) i0 = i;
                    if (v[15:0] == 16'h8203) i8 = i;
                end
                case (f)
                    0: begin                                          // 0F53 direct, chose A0000001
                        axi_read(12'h108 + 16 * i0, w2); axi_read(12'h240 + 4 * i0, rv);
                        if (i0 < 0 || w2[31:24] !== 8'h82 || rv !== 32'hA0000001) begin
                            $display("ERROR golden 1: idx %0d flags %02h RDEV %h", i0, w2[31:24], rv); errors++;
                        end else $display("  ok: golden 1: 0F53 direct, flags 82 (bit 7 direct), chose A0000001");
                    end
                    1: begin                                          // 8203 via 1764, chose the relayer D74C4050
                        axi_read(12'h108 + 16 * i8, w2); axi_read(12'h240 + 4 * i8, rv); axi_read(12'h200 + 4 * i8, vi);
                        if (i8 < 0 || w2[31:24] !== 8'h07 || rv !== 32'hD74C4050 || vi !== 32'hFDAB1764) begin
                            $display("ERROR golden 3: idx %0d flags %02h RDEV %h VIA %h", i8, w2[31:24], rv, vi); errors++;
                        end else $display("  ok: golden 3: 8203 via 1764 (-85 dBm / -3 dB), flags 03 -> 07, chose D74C4050 = the relayer");
                    end
                    2: begin                                          // the relayed C5 in the command FIFO
                        axi_read(12'h800 + 32 * (wr0 % 64), v);
                        if (v !== 32'hFE8203C5) begin $display("ERROR golden 4: FIFO %h", v); errors++; end
                        else $display("  ok: golden 4: C5 from 8203 via E2 in the FIFO");
                    end
                    3: begin                                          // 8203 now heard directly: bit 2 cleared, via 0
                        axi_read(12'h108 + 16 * i8, w2); axi_read(12'h240 + 4 * i8, rv); axi_read(12'h200 + 4 * i8, vi);
                        if (w2[31:24] !== 8'h83 || rv !== 32'hFFFFFFFF || vi !== 32'h0) begin
                            $display("ERROR golden x: flags %02h RDEV %h VIA %h", w2[31:24], rv, vi); errors++;
                        end else $display("  ok: golden x: 8203 direct now, flags 83 (bit 2 cleared, bit 7 set), VIA 0, RDEV FFFFFFFF (anyone)");
                    end
                    default: begin                                    // 0F53 now "anyone"
                        axi_read(12'h240 + 4 * i0, rv);
                        if (rv !== 32'hFFFFFFFF) begin $display("ERROR golden 2: RDEV %h", rv); errors++; end
                        else $display("  ok: golden 2: 0F53 RDEV FFFFFFFF (no usable neighbour)");
                    end
                endcase
            end
            expect_reg("MIC_FAIL unchanged by the golden frames", 9'h0AC, 32'h0);
            axi_write(9'h088, 32'h0);
        end

        $display("test 24: v11 'any copy': 8203 heard directly, then the same packet relayed by 1764 -> bits 2 + 7 set");
        begin
            byte unsigned ua[$] = {8'hAA, 8'h55, 8'h1B, 8'h51, 8'h0D, 8'hF0, 8'hAD, 8'h0B, 8'h0A, 8'h00, 8'h00, 8'h00, 8'hBB, 8'h26, 8'hE8, 8'h00, 8'hBE, 8'h74, 8'hBC, 8'h79, 8'h2B, 8'hEB, 8'h88, 8'h66, 8'h09, 8'hB1, 8'h7D, 8'h4A, 8'hC4, 8'h08, 8'hA9};
            byte unsigned ub[$] = {8'hAA, 8'h55, 8'h2D, 8'h51, 8'h1E, 8'hF1, 8'hAD, 8'h0B, 8'h0A, 8'h00, 8'h00, 8'h00, 8'h42, 8'h62, 8'h7C, 8'hEC, 8'hED, 8'h5C, 8'h6E, 8'h4F, 8'hC7, 8'h9E, 8'h55, 8'h24, 8'hE6, 8'h13, 8'h0E, 8'h9C, 8'h07, 8'h86, 8'hB2, 8'h59, 8'h67, 8'h54, 8'hF7, 8'hBB, 8'hC7, 8'h40, 8'hAC, 8'hF4, 8'hF7, 8'h50, 8'hBE, 8'h8B, 8'hF3, 8'h31, 8'hC4, 8'h08, 8'h4E};
            byte unsigned uc[$] = {8'hAA, 8'h55, 8'h2D, 8'h51, 8'h1E, 8'hF1, 8'hAD, 8'h0B, 8'h0B, 8'h00, 8'h00, 8'h00, 8'hC9, 8'hFD, 8'hAC, 8'h8D, 8'hB6, 8'h11, 8'h52, 8'hD2, 8'h17, 8'hCE, 8'hEB, 8'h94, 8'hD1, 8'hEA, 8'hC4, 8'h0A, 8'hEC, 8'hB9, 8'hF2, 8'hC4, 8'hD7, 8'h39, 8'hFF, 8'hDC, 8'hFA, 8'h27, 8'h61, 8'hE9, 8'h59, 8'h6B, 8'hB0, 8'h81, 8'hF1, 8'h5F, 8'hC4, 8'h08, 8'h11};
            byte unsigned ud[$] = {8'hAA, 8'h55, 8'h2D, 8'h51, 8'h1E, 8'hF1, 8'hAD, 8'h0B, 8'h0C, 8'h00, 8'h00, 8'h00, 8'h80, 8'h7C, 8'hA4, 8'h87, 8'h17, 8'hA0, 8'hAF, 8'h3C, 8'hD9, 8'h1F, 8'hAF, 8'hFA, 8'h13, 8'hEF, 8'h12, 8'h57, 8'hAB, 8'h81, 8'h2F, 8'h15, 8'hCA, 8'hC2, 8'hE1, 8'hE1, 8'h7F, 8'h16, 8'h06, 8'h07, 8'h89, 8'h30, 8'h3F, 8'h59, 8'hB8, 8'hC2, 8'hC4, 8'h08, 8'h68};
            byte unsigned ue[$] = {8'hAA, 8'h55, 8'h1B, 8'h51, 8'h0D, 8'hF0, 8'hAD, 8'h0B, 8'h0B, 8'h00, 8'h00, 8'h00, 8'h67, 8'hED, 8'h56, 8'h4A, 8'h28, 8'h02, 8'hA9, 8'h50, 8'h33, 8'h63, 8'h8D, 8'hD9, 8'h10, 8'h97, 8'h29, 8'hA3, 8'hD0, 8'h02, 8'h7E};
            byte unsigned frm[$];
            reg [31:0] n, v, w2, vi, up0, dup0, ok0, w3;
            int i8;
            axi_write(9'h088, 32'h2);                                             // SECURE_ONLY
            axi_read(9'h0C8, up0); axi_read(9'h0B4, dup0); axi_read(9'h00C, ok0);
            for (int f = 0; f < 5; f++) begin
                case (f) 0: frm = ua; 1: frm = ub; 2: frm = uc; 3: frm = ud; default: frm = ue; endcase
                foreach (frm[k]) begin
                    rx = 1'b0; #(BIT_NS);
                    for (int i = 0; i < 8; i++) begin rx = frm[k][i]; #(BIT_NS); end
                    rx = 1'b1; #(BIT_NS);
                end
                #(20 * BIT_NS);
                axi_read(9'h008, n);
                i8 = -1;
                for (int i = 0; i < n; i++) begin axi_read(12'h100 + 16 * i, v); if (v[15:0] == 16'h8203) i8 = i; end
                axi_read(12'h100 + 16 * i8, v); axi_read(12'h108 + 16 * i8, w2); axi_read(12'h200 + 4 * i8, vi);
                axi_read(12'h10C + 16 * i8, w3);
                case (f)
                    0: if (i8 < 0 || v[23:16] !== 8'h31 || w2[31:24] !== 8'h83 || vi !== 32'h0) begin
                           $display("ERROR v11 direct: idx %0d seq %02h flags %02h VIA %h", i8, v[23:16], w2[31:24], vi); errors++;
                       end else $display("  ok: 8203 seq 31 heard directly: flags 03 -> 83 (bit 7 direct), VIA 0");
                    1: if (v[23:16] !== 8'h31 || w2[31:24] !== 8'h87 || vi !== 32'h05B01764) begin
                           $display("ERROR v11 upgrade: seq %02h flags %02h VIA %h", v[23:16], w2[31:24], vi); errors++;
                       end else $display("  ok: relayed copy of seq 31 merged: flags 87 (bit 2 relayed + bit 7 direct), VIA 05B01764 (1764, -80 dBm / 5 dB)");
                    2: if (w2[31:24] !== 8'h87 || vi !== 32'h05B01764) begin
                           $display("ERROR v11 3rd copy: flags %02h VIA %h", w2[31:24], vi); errors++;
                       end else $display("  ok: a further relayed copy is a duplicate, entry unchanged");
                    3: if (v[23:16] !== 8'h32 || w2[31:24] !== 8'h07 || vi !== 32'h05B01764 || w3[15:0] !== 16'h08C4) begin
                           $display("ERROR v11 relayed first: seq %02h flags %02h VIA %h meta %h", v[23:16], w2[31:24], vi, w3[15:0]); errors++;
                       end else $display("  ok: next packet (seq 32) relayed first: flags 07, VIA 05B01764, gateway -60 dBm / 8 dB");
                    default: if (v[23:16] !== 8'h32 || w2[31:24] !== 8'h87 || vi !== 32'h05B01764 || w3[15:0] !== 16'h08C4) begin
                           $display("ERROR v11 direct 2nd: seq %02h flags %02h VIA %h meta %h", v[23:16], w2[31:24], vi, w3[15:0]); errors++;
                       end else $display("  ok: its direct copy merged: flags 87, relay info kept (VIA 05B01764, -60 dBm / 8 dB, not the direct -48 / 2)");
                endcase
            end
            expect_reg("RELAY_UPG +2", 9'h0C8, up0 + 2);
            expect_reg("RELAY_DUP +1 (3rd copy)", 9'h0B4, dup0 + 1);
            expect_reg("FRAMES_OK +4 (2 packets x 2 paths)", 9'h00C, ok0 + 4);
            axi_write(9'h088, 32'h0);
        end

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule

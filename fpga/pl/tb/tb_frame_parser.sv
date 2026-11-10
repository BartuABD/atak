// tb_frame_parser.sv - self-checking testbench for frame_parser (bytes are fed directly, no UART: that is step 4).
// The testbench builds frames itself (its own CRC-8 model, first checked against the standard check value and the
// example frame), counts every strobe the parser gives and compares it with what each test expects.
// Ends with "TEST PASSED" or "TEST FAILED".
`timescale 1ns / 1ps
module tb_frame_parser;
    localparam integer TIMEOUT_CYC = 2000;     // short, so the timeout test is fast

    reg clk = 1'b0, rst = 1'b1, rx_valid = 1'b0;
    reg [7:0] rx_data = 8'h00;
    wire frame_ok, crc_error, length_error, timeout_error;
    wire [15:0] addr;
    wire [7:0]  seq, flags, rssi, snr;
    wire [31:0] lat, lon;

    frame_parser #(.TIMEOUT_CYC(TIMEOUT_CYC)) dut (
        .clk(clk), .rst(rst), .rx_data(rx_data), .rx_valid(rx_valid),
        .frame_ok(frame_ok), .crc_error(crc_error), .length_error(length_error), .timeout_error(timeout_error),
        .addr(addr), .seq(seq), .lat(lat), .lon(lon), .flags(flags), .rssi(rssi), .snr(snr));

    always #4 clk = ~clk;                      // 125 MHz

    // ---- reference CRC-8 (polynomial 0x07, init 0, no reflection, no final XOR)
    function automatic byte unsigned crc8(input byte unsigned d[]);
        byte unsigned c = 0;
        foreach (d[i]) begin
            c ^= d[i];
            repeat (8) c = c[7] ? byte'((c << 1) ^ 8'h07) : byte'(c << 1);
        end
        return c;
    endfunction

    // ---- one frame: payload fields -> 18 bytes
    function automatic void make_frame(output byte unsigned f[], input [15:0] a, input [7:0] s, input [31:0] la,
                                       input [31:0] lo, input [7:0] fl, input [7:0] rs, input [7:0] sn);
        byte unsigned body[] = '{8'h0E, a[7:0], a[15:8], s, la[7:0], la[15:8], la[23:16], la[31:24],
                                 lo[7:0], lo[15:8], lo[23:16], lo[31:24], fl, rs, sn};
        f = new[18];
        f[0] = 8'hAA; f[1] = 8'h55;
        foreach (body[i]) f[2 + i] = body[i];
        f[17] = crc8(body);
    endfunction

    // ---- byte feeder: one valid clock per byte, then a gap (the real UART gap is ~10850 clocks)
    task automatic put(input byte unsigned b);
        @(posedge clk); rx_data <= b; rx_valid <= 1'b1;
        @(posedge clk); rx_valid <= 1'b0;
        repeat (20) @(posedge clk);
    endtask
    task automatic put_all(input byte unsigned f[]);
        foreach (f[i]) put(f[i]);
    endtask

    // ---- counting + field check
    integer n_ok = 0, n_crc = 0, n_len = 0, n_to = 0, errors = 0;
    reg [15:0] exp_addr; reg [7:0] exp_seq, exp_flags, exp_rssi, exp_snr; reg [31:0] exp_lat, exp_lon;
    always @(posedge clk) begin
        if (frame_ok) begin
            n_ok++;
            if ({addr, seq, lat, lon, flags, rssi, snr} !== {exp_addr, exp_seq, exp_lat, exp_lon, exp_flags, exp_rssi, exp_snr}) begin
                $display("ERROR %0t: fields addr %04h seq %0d lat %0d lon %0d flags %02h rssi %0d snr %0d", $time,
                         addr, seq, $signed(lat), $signed(lon), flags, $signed(rssi), $signed(snr));
                errors++;
            end
        end
        n_crc += crc_error; n_len += length_error; n_to += timeout_error;
    end

    task automatic expect_counts(input string name, input integer ok, crc, len, to);
        repeat (50) @(posedge clk);
        if (n_ok != ok || n_crc != crc || n_len != len || n_to != to) begin
            $display("ERROR %s: ok %0d crc %0d len %0d timeout %0d, expected %0d %0d %0d %0d", name,
                     n_ok, n_crc, n_len, n_to, ok, crc, len, to);
            errors++;
        end else
            $display("  ok: %s", name);
        n_ok = 0; n_crc = 0; n_len = 0; n_to = 0;
    endtask

    byte unsigned ex[], f[], bad[];
    initial begin
        // the reference model itself
        if (crc8('{"1", "2", "3", "4", "5", "6", "7", "8", "9"}) != 8'hF4) begin
            $display("ERROR: CRC model check value"); errors++;
        end
        ex = '{8'hAA, 8'h55, 8'h0E, 8'h64, 8'h17, 8'h0D, 8'h72, 8'h86, 8'h71,
               8'h18, 8'hBC, 8'hC9, 8'h45, 8'h11, 8'h00, 8'hF1, 8'h0C, 8'h70};
        make_frame(f, 16'h1764, 8'd13, 32'd410093170, 32'd289786300, 8'h00, 8'hF1, 8'h0C);
        if (f != ex) begin $display("ERROR: make_frame does not rebuild the example frame"); errors++; end

        exp_addr = 16'h1764; exp_seq = 8'd13; exp_lat = 32'd410093170; exp_lon = 32'd289786300;
        exp_flags = 8'h00; exp_rssi = 8'hF1; exp_snr = 8'h0C;

        repeat (5) @(posedge clk);
        rst = 1'b0;

        $display("test 1: the example frame");
        put_all(ex);
        expect_counts("example frame -> frame_ok, addr 0x1764", 1, 0, 0, 0);

        $display("test 2: garbage before the frame (00 AA 13 AA AA 55 AA ...)");
        put_all('{8'h00, 8'hAA, 8'h13});
        put_all('{8'hAA, 8'hAA, 8'h55, 8'hAA});          // AA 55 then LEN = AA: length error, AA starts again
        put_all(ex[1:17]);                               // ... 55 0E payload: the frame continues from the AA
        expect_counts("garbage, false sync, then a frame", 1, 0, 1, 0);

        $display("test 3: CRC byte wrong, then a good frame");
        bad = ex; bad[17] ^= 8'h01;
        put_all(bad); put_all(ex);
        expect_counts("bad CRC dropped, next frame ok", 1, 1, 0, 0);

        $display("test 4: one payload bit flipped");
        bad = ex; bad[9] ^= 8'h10;
        put_all(bad);
        expect_counts("corrupted payload -> crc_error", 0, 1, 0, 0);

        $display("test 5: LEN = 15");
        bad = ex; bad[2] = 8'h0F;
        put_all(bad[0:5]); put_all(ex);
        expect_counts("wrong LEN -> length_error, then frame ok", 1, 0, 1, 0);

        $display("test 6: frame cut after 8 bytes, pause, then a good frame");
        put_all(ex[0:7]);
        repeat (TIMEOUT_CYC + 10) @(posedge clk);
        put_all(ex);
        expect_counts("cut frame -> timeout_error, then frame ok", 1, 0, 0, 1);

        $display("test 7: other fields (negative lat/lon, flags, rssi/snr)");
        exp_addr = 16'hABCD; exp_seq = 8'd255; exp_lat = -32'sd338688000; exp_lon = -32'sd583816000;
        exp_flags = 8'h01; exp_rssi = 8'h88; exp_snr = 8'hF6;
        make_frame(f, exp_addr, exp_seq, exp_lat, exp_lon, exp_flags, exp_rssi, exp_snr);
        put_all(f); put_all(f);
        expect_counts("two frames back to back", 2, 0, 0, 0);

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule

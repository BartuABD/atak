// tb_atk_rx_top.sv - end-to-end testbench: whole frames go through a behavioral UART transmitter (115200 8N1) into
// atk_rx_top with the real whitelist.mem (157C and 1764 in the list). Checks every accepted packet's fields and
// all six counters at the end. Ends with TEST PASSED / TEST FAILED.
`timescale 1ns / 1ps
module tb_atk_rx_top;
    localparam real BIT_NS = 1.0e9 / 115_200;

    reg clk = 1'b0, rst = 1'b1, rx = 1'b1;
    wire pkt_valid;
    wire [15:0] pkt_addr;
    wire [7:0]  pkt_seq, pkt_flags, pkt_rssi, pkt_snr;
    wire [31:0] pkt_lat, pkt_lon;
    wire [31:0] frames_ok, frames_dropped_addr, crc_errors, framing_errors, length_errors, timeout_errors;

    atk_rx_top #(.INIT_FILE("wl_server.mem")) dut (
        .clk(clk), .rst(rst), .rx(rx),
        .pkt_valid(pkt_valid), .pkt_addr(pkt_addr), .pkt_seq(pkt_seq), .pkt_lat(pkt_lat), .pkt_lon(pkt_lon),
        .pkt_flags(pkt_flags), .pkt_rssi(pkt_rssi), .pkt_snr(pkt_snr),
        .frames_ok(frames_ok), .frames_dropped_addr(frames_dropped_addr), .crc_errors(crc_errors),
        .framing_errors(framing_errors), .length_errors(length_errors), .timeout_errors(timeout_errors),
        .wl_we(1'b0), .wl_idx(6'd0), .wl_wdata(32'd0), .wl_rdata(),
        .secure_only(1'b0), .sec_key(128'h0), .rpl_clear(1'b0));

    always #4 clk = ~clk;                      // 125 MHz

    // ---- UART transmitter model
    task automatic send_byte(input byte unsigned b, input bit stop_ok = 1'b1);
        rx = 1'b0; #(BIT_NS);
        for (int i = 0; i < 8; i++) begin rx = b[i]; #(BIT_NS); end
        rx = stop_ok; #(BIT_NS);
        rx = 1'b1;
    endtask
    task automatic send_frame(input byte unsigned f[]);
        foreach (f[i]) send_byte(f[i]);
        #(3 * BIT_NS);
    endtask

    // ---- frame builder with its own CRC-8 (polynomial 0x07, init 0)
    function automatic byte unsigned crc8(input byte unsigned d[]);
        byte unsigned c = 0;
        foreach (d[i]) begin
            c ^= d[i];
            repeat (8) c = c[7] ? byte'((c << 1) ^ 8'h07) : byte'(c << 1);
        end
        return c;
    endfunction
    function automatic void make_frame(output byte unsigned f[], input [15:0] a, input [7:0] s, input [31:0] la,
                                       input [31:0] lo, input [7:0] fl, input [7:0] rs, input [7:0] sn);
        byte unsigned body[] = '{8'h0E, a[7:0], a[15:8], s, la[7:0], la[15:8], la[23:16], la[31:24],
                                 lo[7:0], lo[15:8], lo[23:16], lo[31:24], fl, rs, sn};
        f = new[18];
        f[0] = 8'hAA; f[1] = 8'h55;
        foreach (body[i]) f[2 + i] = body[i];
        f[17] = crc8(body);
    endfunction

    // ---- expected accepted packets, checked as they come out
    typedef struct { bit [15:0] a; bit [7:0] s; bit [31:0] la, lo; bit [7:0] fl, rs, sn; } pkt_t;
    pkt_t want[$];
    integer errors = 0;
    always @(posedge clk) if (pkt_valid) begin
        if (want.size() == 0) begin
            $display("ERROR %0t: packet from %04h was accepted but should not be", $time, pkt_addr); errors++;
        end else begin
            automatic pkt_t w = want.pop_front();
            if ({pkt_addr, pkt_seq, pkt_lat, pkt_lon, pkt_flags, pkt_rssi, pkt_snr} !== {w.a, w.s, w.la, w.lo, w.fl, w.rs, w.sn}) begin
                $display("ERROR %0t: accepted packet fields differ (addr %04h seq %0d)", $time, pkt_addr, pkt_seq); errors++;
            end else
                $display("  accepted: addr %04h seq %0d lat %0d lon %0d rssi %0d snr %0d", pkt_addr, pkt_seq,
                         $signed(pkt_lat), $signed(pkt_lon), $signed(pkt_rssi), $signed(pkt_snr));
        end
    end

    task automatic good(input [15:0] a, input [7:0] s, input bit in_list);
        byte unsigned f[];
        pkt_t p = '{a, s, 32'd410093170 + s, 32'd289786300, 8'h00, 8'hF1, 8'h0C};
        make_frame(f, p.a, p.s, p.la, p.lo, p.fl, p.rs, p.sn);
        if (in_list) want.push_back(p);
        send_frame(f);
    endtask

    task automatic check_counter(input string name, input [31:0] got, input [31:0] exp);
        if (got !== exp) begin $display("ERROR: %s = %0d, expected %0d", name, got, exp); errors++; end
        else              $display("  %-20s %0d", name, got);
    endtask

    byte unsigned ex[], f[];
    initial begin
        ex = '{8'hAA, 8'h55, 8'h0E, 8'h64, 8'h17, 8'h0D, 8'h72, 8'h86, 8'h71,
               8'h18, 8'hBC, 8'hC9, 8'h45, 8'h11, 8'h00, 8'hF1, 8'h0C, 8'h70};
        repeat (10) @(posedge clk);
        rst = 1'b0;
        #(2 * BIT_NS);

        $display("test 1: the example frame (addr 1764, in the list) -> accepted");
        want.push_back('{16'h1764, 8'd13, 32'd410093170, 32'd289786300, 8'h00, 8'hF1, 8'h0C});
        send_frame(ex);

        $display("test 2: same frame from 1234 (not in the list) -> dropped");
        good(16'h1234, 8'd13, 0);

        $display("test 3: example frame with a wrong CRC -> dropped, crc_errors");
        f = ex; f[17] ^= 8'hFF;
        send_frame(f);

        $display("test 4: frames from 157C and 1764 -> accepted");
        good(16'h157C, 8'd1, 1);
        good(16'h1764, 8'd14, 1);

        $display("test 5: a byte with a bad stop bit -> framing_errors");
        send_byte(8'h42, 1'b0);
        #(2 * BIT_NS);

        $display("test 6: LEN = 0x20 -> length_errors; a frame cut after 6 bytes -> timeout_errors");
        f = ex; f[2] = 8'h20;
        foreach (f[i]) if (i < 4) send_byte(f[i]);
        foreach (ex[i]) if (i < 6) send_byte(ex[i]);
        #(1.5ms);

        $display("test 7: one more good frame after all that -> accepted");
        good(16'h157C, 8'd2, 1);

        // golden vectors: real frames captured from the gateway STM32 (node 157C), sent byte for byte
        $display("test 8: three real frames from the gateway (157C) -> accepted, decoded");
        want.push_back('{16'h157C, 8'd9,  32'd410095210, 32'd289786100, 8'h00, 8'hF3, 8'h0C});
        send_frame('{8'hAA, 8'h55, 8'h0E, 8'h7C, 8'h15, 8'h09, 8'h6A, 8'h8E, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00, 8'hF3, 8'h0C, 8'h81});
        want.push_back('{16'h157C, 8'd10, 32'd410095300, 32'd289786100, 8'h00, 8'hF5, 8'h0D});
        send_frame('{8'hAA, 8'h55, 8'h0E, 8'h7C, 8'h15, 8'h0A, 8'hC4, 8'h8E, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00, 8'hF5, 8'h0D, 8'hE1});
        want.push_back('{16'h157C, 8'd13, 32'd410095570, 32'd289786100, 8'h00, 8'hF5, 8'h0E});
        send_frame('{8'hAA, 8'h55, 8'h0E, 8'h7C, 8'h15, 8'h0D, 8'hD2, 8'h8F, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00, 8'hF5, 8'h0E, 8'hA1});

        $display("test 9: the first real frame, but from 157D (not in the list) -> dropped");
        make_frame(f, 16'h157D, 8'd9, 32'd410095210, 32'd289786100, 8'h00, 8'hF3, 8'h0C);
        send_frame(f);

        #(10 * BIT_NS);
        if (want.size() != 0) begin $display("ERROR: %0d packets were never accepted", want.size()); errors++; end
        $display("counters:");
        check_counter("frames_ok",           frames_ok,           7);
        check_counter("frames_dropped_addr", frames_dropped_addr, 2);
        check_counter("crc_errors",          crc_errors,          1);
        check_counter("framing_errors",      framing_errors,      1);
        check_counter("length_errors",       length_errors,       1);
        check_counter("timeout_errors",      timeout_errors,      1);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule

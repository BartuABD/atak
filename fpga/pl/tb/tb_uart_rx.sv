// tb_uart_rx.sv - self-checking testbench for uart_rx (125 MHz, 115200 baud).
// A behavioral UART transmitter drives rx; every byte it sends with a good stop bit is put in a queue, and every
// valid byte from the receiver must match the front of that queue. Ends with "TEST PASSED" or "TEST FAILED".
// Tests: 1 all 256 byte values back to back, 2 sender 2 % fast and 2 % slow, 3 a short low glitch (ignored),
//        4 a bad stop bit (framing_error, then the next byte is fine), 5 the example frame of the gateway link.
`timescale 1ns / 1ps
module tb_uart_rx;
    localparam integer CLK_HZ = 125_000_000;
    localparam integer BAUD   = 115_200;
    localparam real    CLK_NS = 1.0e9 / CLK_HZ;
    localparam real    BIT_NS = 1.0e9 / BAUD;          // 8680.6 ns

    reg  clk = 1'b0, rst = 1'b1, rx = 1'b1;
    wire [7:0] data;
    wire valid, framing_error;

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (
        .clk(clk), .rst(rst), .rx(rx), .data(data), .valid(valid), .framing_error(framing_error));

    always #(CLK_NS / 2) clk = ~clk;

    byte unsigned expected[$];
    integer errors = 0, received = 0, framing_seen = 0, framing_expected = 0;

    // ---- behavioral transmitter: start bit, 8 data bits LSB first, stop bit
    task automatic send_byte(input byte unsigned b, input bit stop_ok = 1'b1, input real scale = 1.0);
        real bit_ns;
        bit_ns = BIT_NS * scale;
        if (stop_ok) expected.push_back(b);
        else         framing_expected++;
        rx = 1'b0;                      #(bit_ns);
        for (int i = 0; i < 8; i++) begin
            rx = b[i];                  #(bit_ns);
        end
        rx = stop_ok;                   #(bit_ns);
        rx = 1'b1;                                   // back to idle (a bad stop bit ends here)
    endtask

    // ---- checker
    always @(posedge clk) begin
        if (valid) begin
            received++;
            if (expected.size() == 0) begin
                $display("ERROR %0t: unexpected byte 0x%02h", $time, data);
                errors++;
            end else begin
                automatic byte unsigned e = expected.pop_front();
                if (data !== e) begin
                    $display("ERROR %0t: got 0x%02h, expected 0x%02h", $time, data, e);
                    errors++;
                end
            end
        end
        if (framing_error) framing_seen++;
    end

    byte unsigned frame[] = '{8'hAA, 8'h55, 8'h0E, 8'h64, 8'h17, 8'h0D, 8'h72, 8'h86, 8'h71,
                              8'h18, 8'hBC, 8'hC9, 8'h45, 8'h11, 8'h00, 8'hF1, 8'h0C, 8'h70};

    initial begin
        repeat (10) @(posedge clk);
        rst = 1'b0;
        #(BIT_NS);

        $display("test 1: all 256 byte values, back to back");
        for (int v = 0; v < 256; v++) send_byte(v[7:0]);
        #(2 * BIT_NS);

        $display("test 2: sender 2 %% fast, then 2 %% slow");
        foreach (frame[i]) send_byte(frame[i], 1'b1, 0.98);
        foreach (frame[i]) send_byte(frame[i], 1'b1, 1.02);
        #(2 * BIT_NS);

        $display("test 3: 2 us low glitch (shorter than half a bit) must be ignored");
        rx = 1'b0; #2000; rx = 1'b1;
        #(3 * BIT_NS);

        $display("test 4: bad stop bit -> framing_error, then a good byte");
        send_byte(8'h3C, 1'b0);
        #(2 * BIT_NS);
        send_byte(8'hA5);
        #(2 * BIT_NS);

        $display("test 5: example gateway frame (18 bytes)");
        foreach (frame[i]) send_byte(frame[i]);
        #(3 * BIT_NS);

        if (expected.size() != 0) begin
            $display("ERROR: %0d bytes sent but never received", expected.size());
            errors++;
        end
        if (framing_seen != framing_expected) begin
            $display("ERROR: framing_error seen %0d times, expected %0d", framing_seen, framing_expected);
            errors++;
        end
        $display("received %0d bytes, framing errors %0d", received, framing_seen);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule

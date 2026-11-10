// tb_uart_tx.sv - self-checking testbench for uart_tx: its tx pin is looped into uart_rx (already tested), every byte
// taken by the handshake must come out of uart_rx, in order, with no framing error.
// Tests: 1 all 256 values back to back (valid kept high) + the time they take, 2 random gaps between bytes,
//        3 the line stays high (idle) when nothing is sent. Ends with TEST PASSED / TEST FAILED.
`timescale 1ns / 1ps
module tb_uart_tx;
    localparam integer CLK_HZ = 125_000_000, BAUD = 115_200;
    localparam integer CLKS_PER_BIT = (CLK_HZ + BAUD / 2) / BAUD;     // 1085

    reg clk = 1'b0, rst = 1'b1, valid = 1'b0;
    reg [7:0] data = 8'h00;
    wire ready, busy, tx;
    wire [7:0] rx_data;
    wire rx_valid, rx_ferr;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) dut (
        .clk(clk), .rst(rst), .data(data), .valid(valid), .ready(ready), .busy(busy), .tx(tx));
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst(rst), .rx(tx), .data(rx_data), .valid(rx_valid), .framing_error(rx_ferr));

    always #4 clk = ~clk;

    byte unsigned expected[$];
    integer errors = 0, received = 0;

    always @(posedge clk) begin
        if (valid && ready) expected.push_back(data);            // the byte the transmitter takes now
        if (rx_valid) begin
            received++;
            if (expected.size() == 0) begin
                $display("ERROR %0t: unexpected byte 0x%02h", $time, rx_data); errors++;
            end else begin
                automatic byte unsigned e = expected.pop_front();
                if (rx_data !== e) begin
                    $display("ERROR %0t: got 0x%02h, expected 0x%02h", $time, rx_data, e); errors++;
                end
            end
        end
        if (rx_ferr) begin $display("ERROR %0t: framing error", $time); errors++; end
    end

    // send one byte with the valid / ready handshake
    task automatic send(input byte unsigned b);
        data  <= b;
        valid <= 1'b1;
        @(posedge clk);
        while (!ready) @(posedge clk);
        valid <= 1'b0;
    endtask

    longint t0, cycles;
    initial begin
        repeat (5) @(posedge clk);
        if (tx !== 1'b1) begin $display("ERROR: tx not idle high during reset"); errors++; end
        rst = 1'b0;
        repeat (5) @(posedge clk);

        $display("test 1: all 256 values back to back");
        t0 = $time;
        for (int v = 0; v < 256; v++) begin
            data  <= v[7:0];
            valid <= 1'b1;
            @(posedge clk);
            while (!ready) @(posedge clk);
        end
        valid <= 1'b0;
        @(posedge clk);
        while (busy) @(posedge clk);
        cycles = ($time - t0) / 8;
        $display("  256 bytes in %0d clocks = %0d per byte (ideal %0d)", cycles, cycles / 256, 10 * CLKS_PER_BIT);
        if (cycles / 256 < 10 * CLKS_PER_BIT || cycles / 256 > 10 * CLKS_PER_BIT + 2) begin
            $display("ERROR: bytes are not back to back"); errors++;
        end
        repeat (2 * CLKS_PER_BIT) @(posedge clk);

        $display("test 2: 40 random bytes with random gaps");
        for (int i = 0; i < 40; i++) begin
            send($urandom_range(0, 255));
            repeat ($urandom_range(0, 3 * CLKS_PER_BIT)) @(posedge clk);
        end
        while (busy) @(posedge clk);
        repeat (2 * CLKS_PER_BIT) @(posedge clk);

        $display("test 3: idle line stays high");
        for (int i = 0; i < 5 * CLKS_PER_BIT; i++) begin
            @(posedge clk);
            if (tx !== 1'b1) begin $display("ERROR: tx low while idle"); errors++; break; end
        end

        if (expected.size() != 0) begin $display("ERROR: %0d bytes never received", expected.size()); errors++; end
        $display("received %0d bytes", received);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule

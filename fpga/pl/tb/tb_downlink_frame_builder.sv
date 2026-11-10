// tb_downlink_frame_builder.sv - self-checking testbench for downlink_frame_builder.
// The builder drives the real uart_tx, whose pin is looped into uart_rx; the bytes that come out of uart_rx must
// equal the expected frames byte for byte. The location table is a simple model here (array + count, read one
// clock after rd_idx, like location_table).
// A faster baud rate (781250, exactly 160 clocks per bit) and a 3.2 ms period keep the simulation short; the
// frame bytes do not depend on the baud rate.
// Tests: 1 empty table -> nothing sent, 2 only A -> golden frame 1 (18 B), 3 A and B -> golden frame 2 (30 B),
//        4 full table (16 records, 194 B) against a frame built by the testbench's own model.
`timescale 1ns / 1ps
module tb_downlink_frame_builder;
    localparam integer CLK_HZ = 125_000_000, BAUD = 781_250, PERIOD = 400_000, N = 16;

    reg clk = 1'b0, rst = 1'b1;
    always #4 clk = ~clk;

    // ---- table model
    reg [95:0] table_rec [0:N-1];
    reg [4:0]  count = 5'd0;
    wire [3:0] rd_idx;
    reg  [95:0] rd_rec = 96'h0;
    always @(posedge clk) rd_rec <= table_rec[rd_idx];

    wire [7:0] tx_data;
    wire tx_valid, tx_ready, tx_busy, tx, busy;
    wire [31:0] frames_sent;
    wire [7:0] rx_data;
    wire rx_valid, rx_ferr;

    downlink_frame_builder #(.ENTRIES(N), .PERIOD_CYC(PERIOD)) dut (
        .clk(clk), .rst(rst), .start(1'b0), .fresh(16'((1 << count) - 1)), .rd_idx(rd_idx), .rd_rec(rd_rec),
        .tx_data(tx_data), .tx_valid(tx_valid), .tx_ready(tx_ready), .busy(busy), .frames_sent(frames_sent),
        .hold(1'b0), .req());
    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_tx (
        .clk(clk), .rst(rst), .data(tx_data), .valid(tx_valid), .ready(tx_ready), .busy(tx_busy), .tx(tx));
    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_rx (
        .clk(clk), .rst(rst), .rx(tx), .data(rx_data), .valid(rx_valid), .framing_error(rx_ferr));

    // ---- reference: CRC-8 and the frame for a list of records
    function automatic byte unsigned crc8(input byte unsigned d[$]);
        byte unsigned c = 0;
        foreach (d[i]) begin
            c ^= d[i];
            repeat (8) c = c[7] ? byte'((c << 1) ^ 8'h07) : byte'(c << 1);
        end
        return c;
    endfunction
    function automatic void model_frame(output byte unsigned f[$], input integer n);
        byte unsigned body[$];
        body.push_back(2 + 12 * n);
        body.push_back(8'hD1);
        body.push_back(n);
        for (int r = 0; r < n; r++) for (int b = 0; b < 12; b++) body.push_back(table_rec[r][8 * b +: 8]);
        f = {8'hAA, 8'h55, body, crc8(body)};
    endfunction
    function automatic [95:0] rec_of(input byte unsigned b[12]);
        for (int i = 0; i < 12; i++) rec_of[8 * i +: 8] = b[i];
    endfunction

    // ---- received bytes
    byte unsigned got[$];
    integer errors = 0;
    always @(posedge clk) begin
        if (rx_valid) got.push_back(rx_data);
        if (rx_ferr) begin $display("ERROR %0t: framing error", $time); errors++; end
    end

    task automatic expect_frame(input string name, input byte unsigned want[$]);
        automatic integer sent0 = frames_sent;
        got.delete();
        wait (frames_sent == sent0 + 1);
        repeat (2000) @(posedge clk);                 // the last byte through uart_rx
        if (got != want) begin
            $display("ERROR %s:", name);
            $write("  got  (%0d B):", got.size());  foreach (got[i])  $write(" %02h", got[i]);  $write("\n");
            $write("  want (%0d B):", want.size()); foreach (want[i]) $write(" %02h", want[i]); $write("\n");
            errors++;
        end else begin
            $write("  ok: %s (%0d B):", name, got.size());
            foreach (got[i]) if (i < 32) $write(" %02h", got[i]);
            if (got.size() > 32) $display(" ...");
            else                 $display("");
        end
    endtask

    byte unsigned g1[$], g2[$], m[$];
    initial begin
        g1 = {8'hAA, 8'h55, 8'h0E, 8'hD1, 8'h01, 8'h7C, 8'h15, 8'h0D, 8'hD2, 8'h8F, 8'h71, 8'h18, 8'hF4, 8'hC8,
              8'h45, 8'h11, 8'h00, 8'h67};
        g2 = {8'hAA, 8'h55, 8'h1A, 8'hD1, 8'h02, 8'h7C, 8'h15, 8'h0D, 8'hD2, 8'h8F, 8'h71, 8'h18, 8'hF4, 8'hC8,
              8'h45, 8'h11, 8'h00, 8'h64, 8'h17, 8'h0D, 8'h72, 8'h86, 8'h71, 8'h18, 8'hBC, 8'hC9, 8'h45, 8'h11,
              8'h00, 8'h18};
        for (int i = 0; i < N; i++) table_rec[i] = 96'h0;
        table_rec[0] = rec_of('{8'h7C, 8'h15, 8'h0D, 8'hD2, 8'h8F, 8'h71, 8'h18, 8'hF4, 8'hC8, 8'h45, 8'h11, 8'h00});
        table_rec[1] = rec_of('{8'h64, 8'h17, 8'h0D, 8'h72, 8'h86, 8'h71, 8'h18, 8'hBC, 8'hC9, 8'h45, 8'h11, 8'h00});
        model_frame(m, 2);
        if (m != g2) begin $display("ERROR: the testbench model does not give golden frame 2"); errors++; end

        repeat (5) @(posedge clk);
        rst = 1'b0;

        $display("test 1: empty table, two periods -> nothing sent");
        repeat (2 * PERIOD + 100) @(posedge clk);
        if (got.size() != 0 || frames_sent != 0) begin
            $display("ERROR: %0d bytes / %0d frames sent with an empty table", got.size(), frames_sent); errors++;
        end else $display("  ok: nothing sent");

        $display("test 2: only A in the table");
        count = 5'd1;
        expect_frame("golden frame 1", g1);

        $display("test 3: A and B");
        count = 5'd2;
        expect_frame("golden frame 2", g2);

        $display("test 4: full table, 16 records");
        for (int i = 2; i < N; i++)
            table_rec[i] = {8'h00, 32'd290000000 + i, 32'd410000000 - i, 8'(i), 16'h2000 + 16'(i)};
        count = 5'd16;
        model_frame(m, 16);
        expect_frame("16 records", m);

        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED: %0d errors", errors);
        $finish;
    end
endmodule

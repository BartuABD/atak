// tb_secure_tx.sv - checks secure_tx with frames made by gen_stx.py (Python cryptography AESCCM, dir = 1,
// dev_id FFFFFFFE): table (tx_repeat 1), C3 / A2 (tx_repeat 3), a full 16-node table, secure_en = 0 (frame
// unchanged), the counter going on after a plain period, and ctr_load (boot restore). The output side stalls
// out_ready in a pseudo-random pattern like a slow UART; the input side sends with gaps.
`timescale 1ns / 1ps
module tb_secure_tx;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         secure_en = 0, ctr_load = 0, in_valid = 0, out_ready = 0;
    reg  [31:0] ctr_val = 0;
    reg  [7:0]  in_data = 0;
    wire        in_ready, out_valid, busy;
    wire [7:0]  out_data;
    wire [31:0] dl_ctr, sec_sent, plain_sent;

    secure_tx dut (.clk(clk), .rst(rst), .secure_en(secure_en), .key(128'h000102030405060708090a0b0c0d0e0f),
                   .ctr_load(ctr_load), .ctr_val(ctr_val), .dl_ctr(dl_ctr), .in_data(in_data), .in_valid(in_valid),
                   .in_ready(in_ready), .out_data(out_data), .out_valid(out_valid), .out_ready(out_ready),
                   .busy(busy), .sec_sent(sec_sent), .plain_sent(plain_sent));

`include "stx_vectors.svh"

    reg [7:0] got [0:511];
    integer ngot = 0;
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge clk) begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        out_ready <= lfsr[0] & lfsr[3];                 // ready about 1/4 of the clocks
        if (out_valid && out_ready) begin got[ngot] = out_data; ngot = ngot + 1; end
    end

    integer t, j, errors = 0, bad;
    initial begin
        repeat (3) @(posedge clk);
        rst <= 0;
        for (t = 0; t < NT; t = t + 1) begin
            @(posedge clk);
            secure_en <= TEN[t];
            if (TLD[t]) begin ctr_val <= TCV[t]; ctr_load <= 1; @(posedge clk); ctr_load <= 0; end
            ngot = 0;
            for (j = 0; j < TIN[t]; j = j + 1) begin
                @(posedge clk); in_data <= TI[t][j]; in_valid <= 1;
                @(posedge clk); while (!in_ready) @(posedge clk);
                in_valid <= 0;
                if (j % 5 == 0) repeat (3) @(posedge clk);
            end
            @(posedge clk);
            while (busy) @(posedge clk);
            repeat (5) @(posedge clk);
            bad = (ngot != TON[t]);
            for (j = 0; j < TON[t] && j < ngot; j = j + 1) if (got[j] !== TO[t][j]) bad = 1;
            if (bad) begin
                errors = errors + 1;
                $write("FAIL %0s: got %0d bytes:", TNAME[t], ngot);
                for (j = 0; j < ngot && j < 40; j = j + 1) $write(" %02x", got[j]);
                $write("\n     expected %0d bytes:", TON[t]);
                for (j = 0; j < TON[t] && j < 40; j = j + 1) $write(" %02x", TO[t][j]);
                $write("\n");
            end else
                $display("ok   %0s (%0d bytes)", TNAME[t], ngot);
        end
        $display("sec_sent %0d plain_sent %0d dl_ctr %h", sec_sent, plain_sent, dl_ctr);
        if (sec_sent !== 8 || plain_sent !== 2 || dl_ctr !== 32'd101) begin
            $display("FAIL counters"); errors = errors + 1;
        end
        if (errors == 0) $display("ALL TESTS PASSED (%0d frames + counters)", NT);
        else             $display("%0d ERRORS", errors);
        $finish;
    end
endmodule

// tb_ccm_core.sv - checks ccm_core against the Python cryptography AESCCM reference (ccm_vectors.svh, made by
// gen_ccm.py): case 0 is the test vector confirmed by the node firmware (MIC b6 2d 73 27), the others have random
// keys / dev_ids / counters, both directions, N = 1 .. 207 (one to 13 blocks, exact multiples of 16 included).
// For every case: decrypt (plaintext + mic_ok = 1), decrypt with one flipped bit in the header, payload and MIC
// (mic_ok = 0 each), and encrypt (ciphertext + MIC equal to the reference). v10: also 0x52 (13-byte header, CH = 13).
`timescale 1ns / 1ps
module tb_ccm_core;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;                               // 100 MHz

    reg         wr_en = 0, start = 0, enc = 0, dir = 0, hdr13 = 0;
    reg  [7:0]  wr_addr = 0, wr_data = 0, rd_addr = 0, plen = 0;
    reg  [127:0] key = 0;
    wire [7:0]  rd_data;
    wire        busy, done, mic_ok;

    ccm_core dut (.clk(clk), .rst(rst), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .rd_addr(rd_addr),
                  .rd_data(rd_data), .start(start), .enc(enc), .plen(plen), .dir(dir), .hdr13(hdr13), .key(key), .busy(busy),
                  .done(done), .mic_ok(mic_ok));

`include "ccm_vectors.svh"

    integer c, j, errors = 0, clocks, maxclk = 0;
    reg [7:0] got [0:255];

    task load(input integer cs, input integer from_cipher, input integer flip_at);   // flip_at < 0: no flip
        integer len;
        begin
            len = CH[cs] + CN[cs] + (from_cipher ? 4 : 0);
            for (j = 0; j < len; j = j + 1) begin
                @(posedge clk);
                wr_en <= 1; wr_addr <= j;
                wr_data <= (from_cipher ? CS[cs][j] : CP[cs][j]) ^ ((j == flip_at) ? 8'h04 : 8'h00);
            end
            @(posedge clk); wr_en <= 0;
        end
    endtask

    task run(input integer cs, input integer e);
        begin
            @(posedge clk);
            start <= 1; enc <= e; plen <= CN[cs]; dir <= CD[cs]; key <= CK[cs]; hdr13 <= (CH[cs] == 13);
            @(posedge clk);
            start <= 0; key <= 0;
            clocks = 1;
            while (!done) begin @(posedge clk); clocks = clocks + 1; end
            if (clocks > maxclk) maxclk = clocks;
        end
    endtask

    task readback(input integer len);
        begin
            for (j = 0; j <= len; j = j + 1) begin
                @(posedge clk);
                rd_addr <= j;
                if (j > 0) #1 got[j - 1] = rd_data;
            end
        end
    endtask

    integer bad;
    initial begin
        repeat (3) @(posedge clk);
        rst <= 0;
        for (c = 0; c < NC; c = c + 1) begin
            // decrypt + verify
            load(c, 1, -1);
            run(c, 0);
            readback(CH[c] + CN[c]);
            bad = 0;
            for (j = 0; j < CH[c] + CN[c]; j = j + 1) if (got[j] !== CP[c][j]) bad = bad + 1;
            if (!mic_ok || bad) begin
                $display("FAIL case %0d N=%0d decrypt: mic_ok=%0d, %0d wrong bytes", c, CN[c], mic_ok, bad);
                errors = errors + 1;
            end
            // tampered: one bit in the header, the payload, the MIC
            load(c, 1, 3);           run(c, 0); if (mic_ok) begin $display("FAIL case %0d: bad header accepted", c);  errors = errors + 1; end
            load(c, 1, CH[c] + CN[c]/2); run(c, 0); if (mic_ok) begin $display("FAIL case %0d: bad payload accepted", c); errors = errors + 1; end
            load(c, 1, CH[c] + CN[c]+1); run(c, 0); if (mic_ok) begin $display("FAIL case %0d: bad MIC accepted", c);     errors = errors + 1; end
            // encrypt
            load(c, 0, -1);
            run(c, 1);
            readback(CH[c] + 4 + CN[c]);
            bad = 0;
            for (j = 0; j < CH[c] + 4 + CN[c]; j = j + 1) if (got[j] !== CS[c][j]) bad = bad + 1;
            if (bad) begin
                $display("FAIL case %0d N=%0d encrypt: %0d wrong bytes", c, CN[c], bad);
                errors = errors + 1;
            end else
                $display("ok   case %0d N=%-3d dir=%0d hdr %0d  MIC %02x%02x%02x%02x  (%0d clocks)", c, CN[c], CD[c], CH[c],
                         got[CH[c]+CN[c]], got[CH[c]+1+CN[c]], got[CH[c]+2+CN[c]], got[CH[c]+3+CN[c]], clocks);
        end
        if (errors == 0) $display("ALL TESTS PASSED (%0d cases x decrypt / 3 tampered / encrypt), longest %0d clocks", NC, maxclk);
        else             $display("%0d ERRORS", errors);
        $finish;
    end
endmodule

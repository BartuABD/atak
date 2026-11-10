// tb_aes128_enc.sv - checks aes128_enc against FIPS-197 (appendix B and C.1) and 6 random vectors made with the
// Python cryptography library (AES-128 ECB). Also checks the latency (11 clocks), busy, and back-to-back starts.
`timescale 1ns / 1ps
module tb_aes128_enc;
    reg clk = 0, rst = 1, start = 0;
    reg  [127:0] key = 0, din = 0;
    wire busy, done;
    wire [127:0] dout;
    always #4 clk = ~clk;                               // 125 MHz

    aes128_enc dut (.clk(clk), .rst(rst), .start(start), .key(key), .din(din), .busy(busy), .done(done), .dout(dout));

    localparam N = 8;
    reg [127:0] K [0:N-1], P [0:N-1], C [0:N-1];
    initial begin
        K[0] = 128'h000102030405060708090a0b0c0d0e0f; P[0] = 128'h00112233445566778899aabbccddeeff; C[0] = 128'h69c4e0d86a7b0430d8cdb78070b4c55a;
        K[1] = 128'h2b7e151628aed2a6abf7158809cf4f3c; P[1] = 128'h3243f6a8885a308d313198a2e0370734; C[1] = 128'h3925841d02dc09fbdc118597196a0b32;
        K[2] = 128'h45474ec889ac29af53d7a705a9a6ec00; P[2] = 128'hcd08737cb3609a19da96103f09c03a8f; C[2] = 128'h26a24a246be4bbc3afe188397427f068;
        K[3] = 128'hcea0b0fe3d49bd1b331df0f594a6a9aa; P[3] = 128'hc64efe53a856d17fa5c6dd2a975e7d39; C[3] = 128'h4cbed3e90be5e066887aea9f0273ea49;
        K[4] = 128'h63da604072e89aec5d9ac575e4e73065; P[4] = 128'h37284f36130a3c2b77b299507c46eaae; C[4] = 128'h64daa130977c400dbff3b605df3c3bd5;
        K[5] = 128'hfc4da64dcca2641a16f534c3d4d96789; P[5] = 128'h0979a3acb41a0d22aba946dc786549c4; C[5] = 128'he8602f92d069c6c8fc04bd38194c4a7f;
        K[6] = 128'h7d787f08e9496883dc639a1b56d6220e; P[6] = 128'h51cd79ef684360cf2bf2154c7c4161f3; C[6] = 128'hfd77b966ba043f31426872ab82796038;
        K[7] = 128'hbfa8d2d1c1b198da069b48994592793a; P[7] = 128'hb3e65536a13fd2ae3b88a6fca327c79e; C[7] = 128'hf639ab7d15bbd5d4574885915b9c9abe;
    end

    integer i, errors = 0, lat;
    initial begin
        repeat (3) @(posedge clk);
        rst <= 0;
        @(posedge clk);
        for (i = 0; i < N; i = i + 1) begin
            key <= K[i]; din <= P[i]; start <= 1;
            @(posedge clk);
            start <= 0; key <= 0; din <= 0;             // inputs only matter in the start clock
            lat = 1;
            #1 if (!busy) begin $display("FAIL vec %0d: busy not set after start", i); errors = errors + 1; end
            while (!done) begin @(posedge clk); #1; lat = lat + 1; end
            if (lat != 11) begin $display("FAIL vec %0d: latency %0d clocks (expected 11)", i, lat); errors = errors + 1; end
            if (dout !== C[i]) begin
                $display("FAIL vec %0d: got %h expected %h", i, dout, C[i]); errors = errors + 1;
            end else
                $display("ok   vec %0d: %h", i, dout);
            if (i % 2 == 0) @(posedge clk);             // odd vectors start in the clock right after done
        end
        // a start while busy must be ignored
        key <= K[0]; din <= P[0]; start <= 1; @(posedge clk);
        key <= K[1]; din <= P[1];             @(posedge clk);
        start <= 0;
        while (!done) @(posedge clk);
        #1 if (dout !== C[0]) begin $display("FAIL: start while busy changed the result"); errors = errors + 1; end
        else $display("ok   start while busy ignored");
        if (errors == 0) $display("ALL TESTS PASSED (%0d vectors)", N);
        else             $display("%0d ERRORS", errors);
        $finish;
    end
endmodule

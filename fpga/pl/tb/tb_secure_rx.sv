// tb_secure_rx.sv - checks secure_rx with gateway frames made by gen_srx.py (Python cryptography AESCCM):
// secure position / C1 / A1 -> old plain frames, replay and window (late frame accepted once, too old dropped),
// nested E1 / E2 (inner packet checked, duplicate through a 2nd relayer dropped), E3 dropped, bad MIC / wrong key,
// plain frames with secure_only 0 / 1, bad CRC / bad LEN / cut-off frames sent on unchanged.
// v11: the first copy of a position on the OTHER path (direct after relayed, or relayed after direct) is sent on once
// with fwd_upg = 1 (relay_upg); a 2nd copy on the same path, an older counter and an E2 copy of a command stay
// duplicates.
// Every test: the bytes that come out must be exactly the expected frame (or nothing), then the counters are checked.
`timescale 1ns / 1ps
module tb_secure_rx;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;                               // 100 MHz

    reg  [7:0]  in_data = 0;
    reg         in_valid = 0, secure_only = 1;
    wire [7:0]  out_data;
    wire        out_valid;
    wire [31:0] sec_ok, plain_ok, plain_drop, mic_fail, replay_drop, relay_dup, relay_upg, e3_drop, overruns, fwd_rdev;
    wire        fwd_upg;

    secure_rx #(.TIMEOUT_CYC(500)) dut (
        .clk(clk), .rst(rst), .in_data(in_data), .in_valid(in_valid), .secure_only(secure_only),
        .key(128'h000102030405060708090a0b0c0d0e0f), .tbl_clear(1'b0), .out_data(out_data), .out_valid(out_valid),
        .sec_ok(sec_ok), .plain_ok(plain_ok), .plain_drop(plain_drop), .mic_fail(mic_fail),
        .replay_drop(replay_drop), .relay_dup(relay_dup), .relay_upg(relay_upg), .e3_drop(e3_drop), .overruns(overruns), .fwd_rdev(fwd_rdev), .fwd_upg(fwd_upg));

`include "srx_vectors.svh"

    reg [7:0] got [0:255];
    integer ngot = 0;
    always @(posedge clk) if (out_valid) begin got[ngot] = out_data; ngot = ngot + 1; end

    integer t, j, errors = 0, bad;
    initial begin
        repeat (3) @(posedge clk);
        rst <= 0;
        repeat (3) @(posedge clk);
        for (t = 0; t < NT; t = t + 1) begin
            secure_only <= TSO[t];
            ngot = 0;
            for (j = 0; j < TIN[t]; j = j + 1) begin    // one byte every 10 clocks
                @(posedge clk); in_data <= TI[t][j]; in_valid <= 1;
                @(posedge clk); in_valid <= 0;
                repeat (8) @(posedge clk);
            end
            repeat (TCUT[t] ? 1500 : 3000) @(posedge clk);
            bad = (ngot != TON[t]) || (TRC[t] && fwd_rdev !== TRD[t]) || (TUC[t] && fwd_upg !== TUP[t]);
            for (j = 0; j < TON[t] && j < ngot; j = j + 1) if (got[j] !== TO[t][j]) bad = 1;
            if (bad) begin
                errors = errors + 1;
                $write("FAIL %0s: relay_dev %h (want %h) upg %b, got %0d bytes:", TNAME[t], fwd_rdev, TRD[t], fwd_upg, ngot);
                for (j = 0; j < ngot; j = j + 1) $write(" %02x", got[j]);
                $write("\n     expected %0d bytes:", TON[t]);
                for (j = 0; j < TON[t]; j = j + 1) $write(" %02x", TO[t][j]);
                $write("\n");
            end else
                $display("ok   %0s (%0d bytes out)%0s%0s", TNAME[t], ngot, TRC[t] ? $sformatf("  relay_dev %h", fwd_rdev) : "",
                         TUC[t] ? $sformatf("  merge %b", fwd_upg) : "");
        end
        $display("counters: sec_ok %0d plain_ok %0d plain_drop %0d mic_fail %0d replay_drop %0d relay_dup %0d relay_upg %0d e3_drop %0d overruns %0d",
                 sec_ok, plain_ok, plain_drop, mic_fail, replay_drop, relay_dup, relay_upg, e3_drop, overruns);
        // expected from the test list: sec_ok 9 (E3 is not counted), plain_ok 2 (+ bad MIC sent as plain = 3), plain_drop 1 (+ wrong
        // key and bad MIC with secure_only = 1 count as mic_fail, then dropped as plain: plain_drop 3), mic_fail 3,
        // replay_drop 4 (same frame, ctr 5 again, ctr 60, far node direct), relay_dup 1, e3_drop 1, overruns 0
        // v10 tests add: sec_ok + 5 (0x52 direct, E1, 0x51, E2, FFFFFFFF), mic_fail + 1 and plain_drop + 1 (tampered)
        // + firmware V1.17 golden frames: sec_ok + 5
        // + v11: the old "far node heard directly" replay is now a merge (sec_ok + 1, its new "direct again" = replay);
        // v11 tests: sec_ok + 9 (3 merges among them), replay_drop + 1 (3rd copy), relay_dup + 3; relay_upg 4 in all
        if (sec_ok !== 29 || plain_ok !== 3 || plain_drop !== 4 || mic_fail !== 4 || replay_drop !== 5 ||
            relay_dup !== 4 || relay_upg !== 4 || e3_drop !== 1 || overruns !== 0) begin
            $display("FAIL counters"); errors = errors + 1;
        end
        if (errors == 0) $display("ALL TESTS PASSED (%0d frames + counters)", NT);
        else             $display("%0d ERRORS", errors);
        $finish;
    end
endmodule

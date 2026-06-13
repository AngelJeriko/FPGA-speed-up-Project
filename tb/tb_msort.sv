// tb_msort.sv
// Self-checking testbench for msort_merge_sorter.
// Reads golden vectors (tb/vectors/msort_vectors.hex, produced by
// host/merge_sorter/gen_rtl_vectors.py from a real bwa-mem2 run): per record,
// n INPUT keys (load order) and n EXPECTED keys (ks_introsort order). For each
// record it loads the inputs, runs the DUT, and asserts the unloaded key
// sequence matches EXPECTED bit-for-bit.
// Runs under Icarus Verilog and Verilator (--binary).

`timescale 1ns/1ps
`include "msort_pkg.sv"

module tb_msort
    import msort_pkg::*;
();
    // ---- Clock / reset ----
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;  // 100 MHz

    // ---- DUT I/O ----
    logic  in_valid, in_last, in_ready;
    key_t  in_key;
    logic  start;
    logic  out_valid, out_last, out_ready;
    idx_t  out_idx;
    key_t  out_key;
    logic  busy, done;

    msort_merge_sorter dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_key(in_key), .in_last(in_last), .in_ready(in_ready),
        .start(start),
        .out_valid(out_valid), .out_idx(out_idx), .out_key(out_key),
        .out_last(out_last), .out_ready(out_ready),
        .busy(busy), .done(done)
    );

    // ---- Vector storage ----
    integer fd, code, num_recs, r, n, idx;
    key_t   in_keys  [0:N_MAX-1];
    key_t   exp_keys [0:N_MAX-1];
    key_t   got_keys [0:N_MAX-1];
    integer got_cnt;
    integer pass_cnt, fail_cnt, total_elems;
    integer first_fail_rec;
    string  vecpath;

    // collect unloaded keys
    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            got_keys[got_cnt] = out_key;
            // index consistency: the unloaded original index must point at the
            // input whose key equals the unloaded key
            if (in_keys[out_idx] !== out_key)
                $display("  [warn] rec %0d: out_idx=%0d key mismatch", r, out_idx);
            got_cnt = got_cnt + 1;
        end
    end

    initial begin
        if (!$value$plusargs("VEC=%s", vecpath)) vecpath = "tb/vectors/msort_vectors.hex";
        fd = $fopen(vecpath, "r");
        if (fd == 0) begin $display("FATAL: cannot open %s", vecpath); $fatal; end

        in_valid = 0; in_last = 0; in_key = '0; start = 0; out_ready = 1;
        pass_cnt = 0; fail_cnt = 0; total_elems = 0; first_fail_rec = -1;

        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        code = $fscanf(fd, "%d", num_recs);
        $display("=== tb_msort: %0d records from %s ===", num_recs, vecpath);

        for (r = 0; r < num_recs; r = r + 1) begin
            code = $fscanf(fd, "%d", n);
            for (idx = 0; idx < n; idx = idx + 1) code = $fscanf(fd, "%h", in_keys[idx]);
            for (idx = 0; idx < n; idx = idx + 1) code = $fscanf(fd, "%h", exp_keys[idx]);

            // ---- LOAD: one key per cycle ----
            got_cnt = 0;
            @(negedge clk);
            for (idx = 0; idx < n; idx = idx + 1) begin
                in_valid = 1;
                in_key   = in_keys[idx];
                in_last  = (idx == n - 1);
                @(negedge clk);
            end
            in_valid = 0; in_last = 0;

            // ---- wait for sort + unload to finish ----
            wait (done == 1'b1);
            @(posedge clk);

            // ---- check ----
            if (got_cnt != n) begin
                if (first_fail_rec < 0) first_fail_rec = r;
                fail_cnt = fail_cnt + 1;
                $display("  FAIL rec %0d: got %0d elems, expected %0d", r, got_cnt, n);
            end else begin
                automatic logic ok = 1'b1;
                for (idx = 0; idx < n; idx = idx + 1)
                    if (got_keys[idx] !== exp_keys[idx]) ok = 1'b0;
                if (ok) pass_cnt = pass_cnt + 1;
                else begin
                    if (first_fail_rec < 0) first_fail_rec = r;
                    fail_cnt = fail_cnt + 1;
                    $display("  FAIL rec %0d (n=%0d): order mismatch", r, n);
                end
            end
            total_elems = total_elems + n;
            // small gap before next record
            @(posedge clk);
        end

        $fclose(fd);
        $display("=== results ===");
        $display("records   : %0d", num_recs);
        $display("PASSED    : %0d", pass_cnt);
        $display("FAILED    : %0d", fail_cnt);
        $display("elements  : %0d", total_elems);
        if (fail_cnt == 0) $display("RESULT    : ALL PASS");
        else               $display("RESULT    : FAIL (first failing record %0d)", first_fail_rec);
        $finish;
    end

    // safety timeout
    initial begin
        #500_000_000;  // 500 ms sim time
        $display("RESULT    : TIMEOUT");
        $finish;
    end

endmodule

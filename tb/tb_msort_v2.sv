// tb_msort_v2.sv
// End-to-end self-checking testbench for msort_v2_top (the full v2 engine):
// raw pre-dedup INPUT -> re-sort -> dedup -> score-sort -> identical-removal ->
// final OUTPUT, compared to the captured real bwa-mem2 output. Tie-free arrays
// only (the hardware-handled set); fallback must stay low on them.
// Vectors: tb/vectors/msort_v2_vectors.hex (gen_v2_top_vectors.py).

`timescale 1ns/1ps
`include "msort_v2_pkg.sv"

module tb_msort_v2
    import msort_v2_pkg::*;
();
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic in_valid, in_last, in_ready;
    rec_t in_rec;
    logic out_valid, out_last, out_ready;
    rec_t out_rec;
    logic fallback, busy, done;

    msort_v2_top dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_rec(in_rec), .in_last(in_last), .in_ready(in_ready),
        .out_valid(out_valid), .out_rec(out_rec), .out_last(out_last), .out_ready(out_ready),
        .fallback(fallback), .busy(busy), .done(done)
    );

    integer fd, code, num_recs, r, n, m, idx;
    rec_t   in_a [0:N_MAX-1];
    rec_t   exp_a[0:N_MAX-1];
    rec_t   got_a[0:N_MAX-1];
    integer got_cnt, pass_cnt, fail_cnt, first_fail;
    integer has_tie, tie_pass, tie_fail;
    integer ovf_n, ovf_pass, rec_pass;
    rec_t   mk;
    string  vecpath;

    // optional output-backpressure stress: +BP makes out_ready stall ~1/8 cycles
    logic       bp_en;
    logic [2:0] bpc = 0;
    always @(posedge clk) bpc <= bpc + 1;
    assign out_ready = bp_en ? (bpc != 3'd0) : 1'b1;

    function rec_t read_rec(integer f);
        rec_t rc; integer c;
        logic [63:0] rb, re; logic [31:0] qb, qe, rid, score;
        c = $fscanf(f, "%h %h %h %h %h %h", rb, re, qb, qe, rid, score);
        rc.rb=rb; rc.re=re; rc.qb=qb; rc.qe=qe; rc.rid=rid; rc.score=score;
        return rc;
    endfunction
    function bit rec_eq(rec_t a, rec_t b);
        return a.rb==b.rb && a.re==b.re && a.qb==b.qb && a.qe==b.qe
            && a.rid==b.rid && a.score==b.score;
    endfunction

    always @(posedge clk)
        if (out_valid && out_ready) begin got_a[got_cnt] = out_rec; got_cnt = got_cnt + 1; end

    initial begin
        if (!$value$plusargs("VEC=%s", vecpath)) vecpath = "tb/vectors/msort_v2_vectors.hex";
        fd = $fopen(vecpath, "r");
        if (fd == 0) begin $display("FATAL: cannot open %s", vecpath); $fatal; end
        in_valid=0; in_last=0;
        bp_en = $test$plusargs("BP");
        pass_cnt=0; fail_cnt=0; first_fail=-1; tie_pass=0; tie_fail=0;
        repeat (4) @(posedge clk);
        rst_n = 1; @(posedge clk);

        code = $fscanf(fd, "%d", num_recs);
        $display("=== tb_msort_v2: %0d records from %s ===", num_recs, vecpath);

        for (r = 0; r < num_recs; r = r + 1) begin
            code = $fscanf(fd, "%d %d %d", n, m, has_tie);
            for (idx=0; idx<n; idx=idx+1) in_a[idx]  = read_rec(fd);
            for (idx=0; idx<m; idx=idx+1) exp_a[idx] = read_rec(fd);

            got_cnt = 0;
            @(negedge clk);
            for (idx=0; idx<n; idx=idx+1) begin
                in_valid=1; in_rec=in_a[idx]; in_last=(idx==n-1); @(negedge clk);
            end
            in_valid=0; in_last=0;

            wait (done == 1'b1);
            @(posedge clk);

            if (has_tie) begin
                // tie array: must raise fallback (host redoes in SW); output is don't-care
                if (fallback) tie_pass = tie_pass + 1;
                else begin
                    tie_fail = tie_fail + 1;
                    $display("  TIE-FAIL rec %0d (n=%0d): fallback NOT raised on a tie array", r, n);
                end
            end else begin
                automatic bit ok = (got_cnt == m) && !fallback;
                if (ok) for (idx=0; idx<m; idx=idx+1)
                    if (!rec_eq(got_a[idx], exp_a[idx])) ok = 0;
                if (ok) pass_cnt = pass_cnt + 1;
                else begin
                    fail_cnt = fail_cnt + 1;
                    if (first_fail < 0) begin
                        first_fail = r;
                        $display("  FAIL rec %0d: n=%0d got=%0d exp=%0d fallback=%0b", r, n, got_cnt, m, fallback);
                    end
                end
            end
            @(posedge clk);
        end
        $fclose(fd);

        // ---- directed oversize test: n > N_MAX must raise fallback and emit nothing ----
        // `re` is strictly increasing, so the equal-re tie path cannot be what raises it.
        ovf_pass = 0;
        ovf_n    = N_MAX + 5;
        got_cnt  = 0;
        @(negedge clk);
        for (idx = 0; idx < ovf_n; idx = idx + 1) begin
            mk = '0;
            mk.rb = 64'(idx) * 64'd100;  mk.re = 64'(idx) * 64'd100 + 64'd50;
            mk.qb = 32'd0;  mk.qe = 32'd50;  mk.rid = 32'd1;  mk.score = 32'd60;
            in_valid = 1; in_rec = mk; in_last = (idx == ovf_n - 1); @(negedge clk);
        end
        in_valid = 0; in_last = 0;
        wait (done == 1'b1);
        @(posedge clk);
        if (fallback && got_cnt == 0) begin
            ovf_pass = 1;
            $display("  OVF-TEST PASS: n=%0d > N_MAX=%0d -> fallback=1, beats=0", ovf_n, N_MAX);
        end else
            $display("  OVF-TEST FAIL: n=%0d -> fallback=%0b beats=%0d (expected 1, 0)",
                     ovf_n, fallback, got_cnt);

        // ---- recovery: a normal array right after an overflow must still be correct ----
        // (two records, different rid -> dedup skips the pair; expect both out, no fallback)
        rec_pass = 0;
        got_cnt  = 0;
        @(negedge clk);
        for (idx = 0; idx < 2; idx = idx + 1) begin
            mk = '0;
            mk.rb = 64'(idx) * 64'd1000;  mk.re = 64'(idx) * 64'd1000 + 64'd50;
            mk.qb = 32'd0;  mk.qe = 32'd50;  mk.rid = 32'(idx);  mk.score = 32'd70 - 32'(idx);
            in_valid = 1; in_rec = mk; in_last = (idx == 1); @(negedge clk);
        end
        in_valid = 0; in_last = 0;
        wait (done == 1'b1);
        @(posedge clk);
        if (!fallback && got_cnt == 2) begin
            rec_pass = 1;
            $display("  RECOVERY PASS: clean array after overflow -> fallback=0, beats=2");
        end else
            $display("  RECOVERY FAIL: fallback=%0b beats=%0d (expected 0, 2)", fallback, got_cnt);

        $display("=== results ===  records=%0d  tie-free PASS=%0d FAIL=%0d  |  tie(fallback) PASS=%0d FAIL=%0d  |  ovf=%0d recovery=%0d",
                 num_recs, pass_cnt, fail_cnt, tie_pass, tie_fail, ovf_pass, rec_pass);
        if (fail_cnt || tie_fail || !ovf_pass || !rec_pass)
             $display("RESULT: FAIL (first tie-free fail %0d)", first_fail);
        else $display("RESULT: ALL PASS");
        $finish;
    end

    initial begin #(64'd80_000_000_000); $display("RESULT: TIMEOUT"); $finish; end  // watchdog (full-coverage)
endmodule

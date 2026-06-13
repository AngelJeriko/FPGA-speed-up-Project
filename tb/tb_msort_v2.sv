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
    string  vecpath;

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
        in_valid=0; in_last=0; out_ready=1;
        pass_cnt=0; fail_cnt=0; first_fail=-1;
        repeat (4) @(posedge clk);
        rst_n = 1; @(posedge clk);

        code = $fscanf(fd, "%d", num_recs);
        $display("=== tb_msort_v2: %0d records from %s ===", num_recs, vecpath);

        for (r = 0; r < num_recs; r = r + 1) begin
            code = $fscanf(fd, "%d %d", n, m);
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

            begin
                automatic bit ok = (got_cnt == m) && !fallback;
                if (ok) for (idx=0; idx<m; idx=idx+1)
                    if (!rec_eq(got_a[idx], exp_a[idx])) ok = 0;
                if (ok) pass_cnt = pass_cnt + 1;
                else begin
                    fail_cnt = fail_cnt + 1;
                    if (first_fail < 0) begin
                        first_fail = r;
                        $display("  FAIL rec %0d: n=%0d got=%0d exp=%0d fallback=%0b", r, n, got_cnt, m, fallback);
                        for (idx=0; idx<m && idx<4; idx=idx+1)
                            $display("    exp[%0d] re=%0d rb=%0d score=%0d  got re=%0d rb=%0d score=%0d",
                                idx, exp_a[idx].re, exp_a[idx].rb, exp_a[idx].score,
                                got_a[idx].re, got_a[idx].rb, got_a[idx].score);
                    end
                end
            end
            @(posedge clk);
        end
        $fclose(fd);
        $display("=== results ===  records=%0d  PASS=%0d  FAIL=%0d", num_recs, pass_cnt, fail_cnt);
        if (fail_cnt) $display("RESULT: FAIL (first failing record %0d)", first_fail);
        else          $display("RESULT: ALL PASS");
        $finish;
    end

    initial begin #4_000_000_000; $display("RESULT: TIMEOUT"); $finish; end
endmodule

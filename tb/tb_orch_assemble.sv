// tb_orch_assemble.sv — self-checking TB for orch_assemble. Reads the decimal
// vector file from gen_asm_vectors (+VEC=path), drives every alnreg through the
// combinational DUT, and checks rb/re/qb/qe/score/truesc/w field-for-field.
`timescale 1ns/1ps

module tb_orch_assemble;
    // DUT I/O
    logic               need_left, need_right;
    logic signed [31:0] l_query, a, w, pen5, pen3, qbeg, len, rid;
    logic signed [63:0] rbeg;
    logic signed [31:0] l_score,l_qle,l_tle,l_gscore,l_gtle,l_w;
    logic signed [31:0] r_score,r_qle,r_tle,r_gscore,r_gtle,r_w;
    logic signed [63:0] rb, re;
    logic signed [31:0] qb, qe, score, truesc, w_out, rid_out;

    orch_assemble dut(.*);

    // expected
    longint exp_rb, exp_re;
    int exp_qb, exp_qe, exp_score, exp_truesc, exp_wout;

    integer fd, cnt, got, i;
    integer nl, nr, t_lq, t_a, t_w, t_p5, t_p3, t_qb, t_len, t_rid;
    longint t_rbeg, t_rmax0;
    integer ls,lq,lt,lg,lgt,lw, rs,rq,rt,rg,rgt,rw;
    string path;
    integer fails;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path = "host/extend_orchestrator/vectors/asm_vectors.txt";
        fd = $fopen(path, "r");
        if (fd == 0) begin $display("FATAL: cannot open %s", path); $finish; end
        got = $fscanf(fd, "%d", cnt);
        fails = 0;
        for (i = 0; i < cnt; i = i + 1) begin
            got = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                nl, nr, t_lq, t_a, t_w, t_p5, t_p3, t_rbeg, t_rmax0,
                t_qb, t_len, t_rid,
                ls, lq, lt, lg, lgt, lw,  rs, rq, rt, rg, rgt, rw,
                exp_rb, exp_re, exp_qb, exp_qe, exp_score, exp_truesc, exp_wout);
            // drive
            need_left=nl[0]; need_right=nr[0];
            l_query=t_lq; a=t_a; w=t_w; pen5=t_p5; pen3=t_p3;
            rbeg=t_rbeg; qbeg=t_qb; len=t_len; rid=t_rid;
            l_score=ls; l_qle=lq; l_tle=lt; l_gscore=lg; l_gtle=lgt; l_w=lw;
            r_score=rs; r_qle=rq; r_tle=rt; r_gscore=rg; r_gtle=rgt; r_w=rw;
            #1;
            if (rb!==exp_rb || re!==exp_re || qb!==exp_qb || qe!==exp_qe ||
                score!==exp_score || truesc!==exp_truesc || w_out!==exp_wout) begin
                fails = fails + 1;
                if (fails <= 8)
                    $display("MISMATCH[%0d] got rb=%0d re=%0d qb=%0d qe=%0d sc=%0d ts=%0d w=%0d | exp rb=%0d re=%0d qb=%0d qe=%0d sc=%0d ts=%0d w=%0d",
                        i, rb, re, qb, qe, score, truesc, w_out,
                        exp_rb, exp_re, exp_qb, exp_qe, exp_score, exp_truesc, exp_wout);
            end
        end
        $fclose(fd);
        $display("orch_assemble: %0d vectors, %0d failures -> %s", cnt, fails,
                 (fails==0) ? "ALL PASS" : "FAIL");
        $finish;
    end
endmodule

// tb_orch_window.sv — self-checking TB for orch_window. For each seed: drive
// params, and as the (win,addr) stream is emitted, compare each element on the fly
// against the expected source-address sequence (Lq,Lr,Rq,Rr) built from the golden
// descriptors. Inline compare (no queues) keeps it fast over ~100M+ addresses.
`timescale 1ns/1ps

module tb_orch_window;
    logic               clk = 0, rst_n = 0;
    logic               start;
    logic signed [63:0] rbeg, rmax0, rmax1;
    logic signed [31:0] qbeg, len, l_query;
    logic               out_valid, out_wlast, need_left, need_right, done;
    logic        [1:0]  out_win;
    logic signed [31:0] out_addr;

    orch_window dut(.*);
    always #5 clk = ~clk;

    integer fd, cnt, got, i, fails, guard;
    longint t_rbeg, t_rmax0, t_rmax1;
    integer t_qbeg, t_len, t_lq, t_nl, t_nr;
    integer seg_start[4], seg_len[4];
    integer sg, si, ngot, total_exp, ok, exp_w, exp_a, dir;
    string  path;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path = "host/extend_orchestrator/vectors/window_vectors.txt";
        fd = $fopen(path, "r");
        if (fd == 0) begin $display("FATAL: cannot open %s", path); $finish; end
        start=0;
        repeat (3) @(posedge clk); rst_n=1; @(posedge clk);

        got = $fscanf(fd, "%d", cnt);
        fails = 0;
        for (i = 0; i < cnt; i = i + 1) begin
            got = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                t_rbeg, t_qbeg, t_len, t_rmax0, t_rmax1, t_lq,
                t_nl, seg_start[0], seg_len[0], seg_start[1], seg_len[1],
                t_nr, seg_start[2], seg_len[2], seg_start[3], seg_len[3]);
            total_exp = seg_len[0]+seg_len[1]+seg_len[2]+seg_len[3];

            rbeg=t_rbeg; qbeg=t_qbeg; len=t_len; rmax0=t_rmax0; rmax1=t_rmax1; l_query=t_lq;
            start=1; @(posedge clk); #1; start=0;

            // walk to first non-empty segment
            sg=0; si=0; ngot=0; ok=1;
            while (sg<4 && seg_len[sg]==0) sg=sg+1;
            guard=0;
            do begin
                if (out_valid) begin
                    ngot = ngot + 1;
                    if (sg >= 4) ok = 0;
                    else begin
                        dir   = (sg < 2) ? -1 : 1;       // Lq,Lr reversed; Rq,Rr forward
                        exp_w = sg;
                        exp_a = seg_start[sg] + dir*si;
                        if (out_win !== exp_w[1:0] || out_addr !== exp_a) ok = 0;
                        si = si + 1;
                        if (si >= seg_len[sg]) begin
                            sg = sg + 1; si = 0;
                            while (sg<4 && seg_len[sg]==0) sg=sg+1;
                        end
                    end
                end
                @(posedge clk); #1; guard = guard + 1;
            end while (!done && guard < 8000);

            if (!ok || ngot != total_exp || need_left !== t_nl[0] || need_right !== t_nr[0]) begin
                fails = fails + 1;
                if (fails <= 8) $display("MISMATCH[%0d] ok=%0d ngot=%0d exp=%0d nl=%0b/%0d nr=%0b/%0d",
                    i, ok, ngot, total_exp, need_left, t_nl, need_right, t_nr);
            end
        end
        $fclose(fd);
        $display("orch_window: %0d seeds, %0d failures -> %s", cnt, fails,
                 (fails==0) ? "ALL PASS" : "FAIL");
        $finish;
    end
endmodule

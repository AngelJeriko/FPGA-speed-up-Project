// tb_matesw_dedup.sv — self-checking TB for matesw_dedup (mem_sort_dedup_patch on the
// mate-rescue ma list). Loads n_in records, runs the engine, checks n_out and every
// survivor (rb/re/qb/qe/rid/score/cov) bit-exact vs gen_dedup_vectors (= orch.h::mr_dedup).
`timescale 1ns/1ps

module tb_matesw_dedup ();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic        ld_en; logic [15:0] ld_idx;
    logic signed [63:0] ld_rb, ld_re; logic signed [31:0] ld_qb, ld_qe, ld_rid, ld_score, ld_cov;
    logic        start; logic [15:0] n_in;
    logic        busy, done, overflow, tie; logic [15:0] n_out;
    logic [15:0] rd_idx;
    logic signed [63:0] o_rb, o_re; logic signed [31:0] o_qb, o_qe, o_rid, o_score, o_cov;

    matesw_dedup #(.MA_MAX(64)) dut(.clk,.rst_n,.ld_en,.ld_idx,
        .ld_rb,.ld_re,.ld_qb,.ld_qe,.ld_rid,.ld_score,.ld_cov,
        .start,.n_in,.busy,.done,.overflow,.tie,.n_out,
        .rd_idx,.o_rb,.o_re,.o_qb,.o_qe,.o_rid,.o_score,.o_cov);

    integer fd,got,cnt,ci,k,fails,guard,en,eo,e_fb;
    integer i_rb[0:63],i_re[0:63],i_qb[0:63],i_qe[0:63],i_rid[0:63],i_sc[0:63],i_cov[0:63];
    integer e_rb[0:63],e_re[0:63],e_qb[0:63],e_qe[0:63],e_rid[0:63],e_sc[0:63],e_cov[0:63];
    string path;

    task automatic ldrec(input int idx, input int rrb,input int rre,input int rqb,
                         input int rqe,input int rrid,input int rsc,input int rcov);
        @(posedge clk); ld_en<=1; ld_idx<=idx[15:0];
        ld_rb<=rrb; ld_re<=rre; ld_qb<=rqb; ld_qe<=rqe; ld_rid<=rrid; ld_score<=rsc; ld_cov<=rcov;
        @(posedge clk); ld_en<=0;
    endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/mate_rescue/vectors/dedup_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_en=0; start=0; rd_idx=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d",en);
            for (k=0;k<en;k=k+1)
                got=$fscanf(fd,"%d %d %d %d %d %d %d",
                    i_rb[k],i_re[k],i_qb[k],i_qe[k],i_rid[k],i_sc[k],i_cov[k]);
            got=$fscanf(fd,"%d %d",eo,e_fb);
            for (k=0;k<eo;k=k+1)
                got=$fscanf(fd,"%d %d %d %d %d %d %d",
                    e_rb[k],e_re[k],e_qb[k],e_qe[k],e_rid[k],e_sc[k],e_cov[k]);

            for (k=0;k<en;k=k+1) ldrec(k,i_rb[k],i_re[k],i_qb[k],i_qe[k],i_rid[k],i_sc[k],i_cov[k]);
            n_in<=en[15:0];
            @(posedge clk); start<=1; @(posedge clk); start<=0;
            guard=0; while (!done && guard<2000000) begin @(posedge clk); guard=guard+1; end

            if (tie !== e_fb[0]) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] tie %0b/%0b (n_in=%0d)", ci, tie, e_fb[0], en);
            end
            if (n_out !== eo[15:0]) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] n_out %0d/%0d (n_in=%0d)", ci, n_out, eo, en);
            end else begin
                for (k=0;k<eo;k=k+1) begin
                    rd_idx<=k[15:0]; @(posedge clk); #1;
                    if (o_rb!==e_rb[k] || o_re!==e_re[k] || o_qb!==e_qb[k] || o_qe!==e_qe[k] ||
                        o_rid!==e_rid[k] || o_score!==e_sc[k] || o_cov!==e_cov[k]) begin
                        fails=fails+1;
                        if (fails<=12)
                            $display("MISMATCH[%0d] surv %0d: rb %0d/%0d re %0d/%0d qb %0d/%0d qe %0d/%0d sc %0d/%0d cov %0d/%0d",
                                ci,k,o_rb,e_rb[k],o_re,e_re[k],o_qb,e_qb[k],o_qe,e_qe[k],o_score,e_sc[k],o_cov,e_cov[k]);
                    end
                end
            end
        end
        $fclose(fd);
        $display("tb_matesw_dedup: %0d cases, %0d failures -> %s",
                 cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #400000000; $display("[FATAL] timeout"); $finish; end
endmodule

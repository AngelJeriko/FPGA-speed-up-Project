// tb_orch_purge.sv — self-checking TB for orch_purge. For each read vector
// (host/extend_orchestrator/vectors/purge_vectors.txt) it loads the pre-purge av,
// the per-chain table and all seeds, runs the purge, and checks every alnreg's
// post-purge qb/qe against extend_only+purge (integer model).
`timescale 1ns/1ps

module tb_orch_purge;
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic        av_ld_en; logic [15:0] av_ld_idx;
    logic signed [63:0] av_ld_rb, av_ld_re;
    logic signed [31:0] av_ld_qb, av_ld_qe, av_ld_w, av_ld_sl0;
    logic        sd_ld_en; logic [15:0] sd_ld_idx;
    logic signed [63:0] sd_ld_rbeg; logic signed [31:0] sd_ld_qbeg, sd_ld_len, sd_ld_score;
    logic        ch_ld_en; logic [15:0] ch_ld_idx, ch_ld_sbase, ch_ld_n, ch_ld_abase;
    logic        start, busy, done;
    logic [15:0] nav, nchain, rd_idx;
    logic signed [31:0] a,o_del,e_del,o_ins,e_ins,wcfg,l_query, rd_qb, rd_qe;

    orch_purge dut(.clk,.rst_n,
        .av_ld_en,.av_ld_idx,.av_ld_rb,.av_ld_re,.av_ld_qb,.av_ld_qe,.av_ld_w,.av_ld_sl0,
        .sd_ld_en,.sd_ld_idx,.sd_ld_rbeg,.sd_ld_qbeg,.sd_ld_len,.sd_ld_score,
        .ch_ld_en,.ch_ld_idx,.ch_ld_sbase,.ch_ld_n,.ch_ld_abase,
        .start,.nav,.nchain,.a,.o_del,.e_del,.o_ins,.e_ins,.wcfg(wcfg),.l_query,
        .busy,.done,.rd_idx,.rd_qb,.rd_qe);

    integer fd,got,nreads,ri,i,b,fails,t_nav,t_nch,guard;
    integer t_a,t_od,t_ed,t_oi,t_ei,t_w,t_lq;
    longint a_rb,a_re,s_rb; integer a_qb,a_qe,a_w,a_sl0,s_qb,s_ln,s_sc,c_sb,c_n,c_ab;
    integer e_qb[0:1023], e_qe[0:1023];
    string path;

    task automatic avld(input int idx, input longint rb_, input longint re_,
                        input int qb_, input int qe_, input int w_, input int sl0_);
        @(posedge clk); av_ld_en<=1; av_ld_idx<=idx[15:0];
        av_ld_rb<=rb_; av_ld_re<=re_; av_ld_qb<=qb_; av_ld_qe<=qe_; av_ld_w<=w_; av_ld_sl0<=sl0_;
        @(posedge clk); av_ld_en<=0;
    endtask
    task automatic sdld(input int idx, input longint rb_, input int qb_, input int ln_, input int sc_);
        @(posedge clk); sd_ld_en<=1; sd_ld_idx<=idx[15:0];
        sd_ld_rbeg<=rb_; sd_ld_qbeg<=qb_; sd_ld_len<=ln_; sd_ld_score<=sc_;
        @(posedge clk); sd_ld_en<=0;
    endtask
    task automatic chld(input int idx, input int sb_, input int n_, input int ab_);
        @(posedge clk); ch_ld_en<=1; ch_ld_idx<=idx[15:0];
        ch_ld_sbase<=sb_[15:0]; ch_ld_n<=n_[15:0]; ch_ld_abase<=ab_[15:0];
        @(posedge clk); ch_ld_en<=0;
    endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/extend_orchestrator/vectors/purge_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        av_ld_en=0; sd_ld_en=0; ch_ld_en=0; start=0; rd_idx=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",nreads); fails=0;
        for (ri=0; ri<nreads; ri=ri+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",
                t_nav,t_nch,t_a,t_od,t_ed,t_oi,t_ei,t_w,t_lq);
            for (i=0;i<t_nav;i=i+1) begin
                got=$fscanf(fd,"%d %d %d %d %d %d", a_rb,a_re,a_qb,a_qe,a_w,a_sl0);
                avld(i,a_rb,a_re,a_qb,a_qe,a_w,a_sl0);
            end
            for (i=0;i<t_nch;i=i+1) begin
                got=$fscanf(fd,"%d %d %d", c_sb,c_n,c_ab);
                chld(i,c_sb,c_n,c_ab);
            end
            for (i=0;i<t_nav;i=i+1) begin
                got=$fscanf(fd,"%d %d %d %d", s_rb,s_qb,s_ln,s_sc);
                sdld(i,s_rb,s_qb,s_ln,s_sc);
            end
            for (i=0;i<t_nav;i=i+1) got=$fscanf(fd,"%d %d", e_qb[i], e_qe[i]);

            nav<=t_nav[15:0]; nchain<=t_nch[15:0];
            a<=t_a; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei; wcfg<=t_w; l_query<=t_lq;
            @(posedge clk); start<=1; @(posedge clk); start<=0;
            guard=0; while (!done && guard<20000000) begin @(posedge clk); guard=guard+1; end

            for (i=0;i<t_nav;i=i+1) begin
                rd_idx<=i[15:0]; @(posedge clk); #1;
                if (rd_qb!==e_qb[i] || rd_qe!==e_qe[i]) begin
                    fails=fails+1;
                    if (fails<=12)
                        $display("MISMATCH read=%0d av=%0d  qb %0d/%0d qe %0d/%0d",
                            ri, i, rd_qb, e_qb[i], rd_qe, e_qe[i]);
                end
            end
        end
        $fclose(fd);
        $display("tb_orch_purge: %0d reads, %0d failures -> %s",
                 nreads, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #8000000000; $display("[FATAL] timeout"); $finish; end
endmodule

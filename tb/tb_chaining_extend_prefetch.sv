// tb_chaining_extend_top.sv — END-TO-END self-checking TB for the full chaining->extension
// pipeline (chaining_top -> chain2aln_setup -> accel_top). Feeds each read's raw seed stream +
// query, serves per-chain reference windows from the SAME synthetic genome g(pos)=pos&3 the
// golden used, captures the AXI-Stream alnregs, and checks fallback + the sorted record list
// bit-exact vs gen_chaining_extend_vectors. fb reads (chaining dup-pos/combsort OR accel
// equal-re tie / n>1024) expect fallback and skip the output check.
//
// The two STAGE-SPECIFIC fallback bits are checked INDEPENDENTLY (fb_chain vs fb_sort), not just
// their OR: the host redoes only the failed stage, so attributing a fallback to the wrong stage
// would silently corrupt the read.
`timescale 1ns/1ps
`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module tb_chaining_extend_prefetch
    import bsw_pkg::*;
    import msort_v2_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic signed [31:0] w, max_chain_gap, min_seed_len, max_chain_extend;
    logic signed [31:0] a, o_del, e_del, o_ins, e_ins, zdrop, pen5, pen3, l_query;
    logic signed [63:0] l_pac;
    logic        ld_en; logic [15:0] ld_idx;
    logic signed [63:0] ld_rbeg; logic signed [31:0] ld_qbeg, ld_len, ld_score, ld_rid, ld_isalt;
    logic        q_ld_en; logic [15:0] q_ld_addr; base_t q_ld_data;
    logic        start; logic [15:0] n_in;
    logic        busy, done, fallback, fb_chain, fb_sort;
    logic        ref_req; logic signed [63:0] ref_rbeg; logic [15:0] ref_len;
    logic        ref_in_en; logic [15:0] ref_in_addr; base_t ref_in_data; logic ref_in_done;
    logic        ctab_we; logic [15:0] ctab_idx; logic signed [63:0] ctab_offset, ctab_len; logic [15:0] ctab_n;
    logic        m_tvalid, m_tlast, m_tready; rec_t m_tdata;

    chaining_extend_prefetch_top #(.NCHAIN(64), .NSEED(64), .NQ(512), .NS(64)) dut(.clk,.rst_n,
        .w,.max_chain_gap,.min_seed_len,.max_chain_extend,
        .a,.o_del,.e_del,.o_ins,.e_ins,.zdrop,.pen5,.pen3,.l_query,.l_pac,
        .ld_en,.ld_idx,.ld_rbeg,.ld_qbeg,.ld_len,.ld_score,.ld_rid,.ld_isalt,
        .q_ld_en,.q_ld_addr,.q_ld_data,
        .start,.n_in,.busy,.done,.fallback,.fb_chain,.fb_sort,
        .ref_req,.ref_rbeg,.ref_len,.ref_in_en,.ref_in_addr,.ref_in_data,.ref_in_done,
        .ctab_we,.ctab_idx,.ctab_offset,.ctab_len,.ctab_n,
        .m_axis_tvalid(m_tvalid),.m_axis_tdata(m_tdata),.m_axis_tlast(m_tlast),.m_axis_tready(m_tready));

    assign m_tready = 1'b1;

    // ---- concurrent reference server: stream g(pos)=pos&3 on every ref_req ----
    integer ri; longint rbase;
    initial begin
        ref_in_en=0; ref_in_addr=0; ref_in_data=0; ref_in_done=0;
        forever begin
            @(posedge clk);
            if (ref_req) begin
                rbase = ref_rbeg;
                for (ri=0; ri<ref_len; ri=ri+1) begin
                    @(posedge clk); ref_in_en<=1; ref_in_addr<=ri[15:0]; ref_in_data<=base_t'((rbase+ri) & 3);
                end
                @(posedge clk); ref_in_en<=0; ref_in_done<=1;
                @(posedge clk); ref_in_done<=0;
                wait(!ref_req);
            end
        end
    end

    integer fd,got,cnt,ci,k,fails,guard,ngot;
    integer t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_gap,t_msl,t_mce,t_ns,e_nout;
    integer e_fbc, e_fbs, e_fb;
    longint t_lpac, srb[0:63]; integer sqb[0:63],sln[0:63],ssc[0:63],srid[0:63],sal[0:63];
    integer qv[0:511];
    longint g_rb[0:1199],g_re[0:1199],e_rb[0:1199],e_re[0:1199];
    integer g_qb[0:1199],g_qe[0:1199],g_rid[0:1199],g_sc[0:1199];
    integer e_qb[0:1199],e_qe[0:1199],e_rid[0:1199],e_sc[0:1199];
    string path;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/extend_orchestrator/vectors/chainingext_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_en=0; q_ld_en=0; start=0; ctab_we=0; ctab_n=16'd1;
        repeat(6) @(posedge clk); rst_n=1; @(posedge clk);

        // Single all-encompassing contig [0, l_pac) — the synthetic vectors use l_pac=1<<34 and
        // position-random rid, so a per-contig table can't reproduce them; one contig makes the
        // clamp a PROVABLE no-op on beg/end (goldens unchanged), while still exercising the clamp
        // datapath in-context. The clamp is proven bit-exact standalone in tb_bns_clamp_top.
        @(posedge clk); ctab_we<=1; ctab_idx<=16'd0; ctab_offset<=64'sd0; ctab_len<=(64'sd1<<<34);
        @(posedge clk); ctab_we<=0;

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_gap,t_msl,t_mce,t_lpac,t_ns);
            for (k=0;k<t_ns;k=k+1) got=$fscanf(fd,"%d %d %d %d %d %d", srb[k],sqb[k],sln[k],ssc[k],srid[k],sal[k]);
            for (k=0;k<t_lq;k=k+1) got=$fscanf(fd,"%d", qv[k]);
            got=$fscanf(fd,"%d %d %d", e_fbc, e_fbs, e_nout);
            e_fb = (e_fbc || e_fbs) ? 1 : 0;
            for (k=0;k<e_nout;k=k+1) got=$fscanf(fd,"%d %d %d %d %d %d", e_rb[k],e_re[k],e_qb[k],e_qe[k],e_rid[k],e_sc[k]);

            // load raw seeds
            for (k=0;k<t_ns;k=k+1) begin
                @(posedge clk); ld_en<=1; ld_idx<=k[15:0];
                ld_rbeg<=srb[k]; ld_qbeg<=sqb[k]; ld_len<=sln[k]; ld_score<=ssc[k]; ld_rid<=srid[k]; ld_isalt<=sal[k];
            end
            @(posedge clk); ld_en<=0;
            // load query
            for (k=0;k<t_lq;k=k+1) begin
                @(posedge clk); q_ld_en<=1; q_ld_addr<=k[15:0]; q_ld_data<=base_t'(qv[k]);
            end
            @(posedge clk); q_ld_en<=0;
            // config + run
            w<=t_w; max_chain_gap<=t_gap; min_seed_len<=t_msl; max_chain_extend<=t_mce;
            a<=t_a; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei; zdrop<=t_zd; pen5<=t_p5; pen3<=t_p3;
            l_query<=t_lq; l_pac<=t_lpac; n_in<=t_ns[15:0];
            @(posedge clk); start<=1; @(posedge clk); start<=0;

            // run + capture AXI output
            ngot=0; guard=0;
            while (!done && guard<8000000) begin
                @(posedge clk);
                if (m_tvalid && m_tready) begin
                    g_rb[ngot]=m_tdata.rb; g_re[ngot]=m_tdata.re; g_qb[ngot]=m_tdata.qb;
                    g_qe[ngot]=m_tdata.qe; g_rid[ngot]=m_tdata.rid; g_sc[ngot]=m_tdata.score; ngot=ngot+1;
                end
                guard=guard+1;
            end

            // stage-specific: each bit must match on its own, not merely their OR
            if (fb_chain !== e_fbc[0] || fb_sort !== e_fbs[0] || fallback !== e_fb[0]) begin
                fails=fails+1;
                if (fails<=15) $display("MISMATCH[%0d] fb_chain %0b/%0b fb_sort %0b/%0b fallback %0b/%0b (ns=%0d)",
                    ci, fb_chain, e_fbc[0], fb_sort, e_fbs[0], fallback, e_fb[0], t_ns);
            end else if (e_fb == 0) begin
                if (ngot !== e_nout) begin
                    fails=fails+1;
                    if (fails<=15) $display("MISMATCH[%0d] nout %0d/%0d (ns=%0d)", ci, ngot, e_nout, t_ns);
                end else begin
                    for (k=0;k<e_nout;k=k+1)
                        if (g_rb[k]!==e_rb[k] || g_re[k]!==e_re[k] || g_qb[k]!==e_qb[k] ||
                            g_qe[k]!==e_qe[k] || g_rid[k]!==e_rid[k] || g_sc[k]!==e_sc[k]) begin
                            fails=fails+1;
                            if (fails<=15) $display("MISMATCH[%0d] rec %0d: rb %0d/%0d re %0d/%0d qb %0d/%0d qe %0d/%0d rid %0d/%0d sc %0d/%0d",
                                ci,k,g_rb[k],e_rb[k],g_re[k],e_re[k],g_qb[k],e_qb[k],g_qe[k],e_qe[k],g_rid[k],e_rid[k],g_sc[k],e_sc[k]);
                        end
                end
            end
        end
        $fclose(fd);
        $display("tb_chaining_extend_prefetch: %0d cases, %0d failures -> %s", cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #(64'd8000000000); $display("[FATAL] timeout"); $finish; end
endmodule

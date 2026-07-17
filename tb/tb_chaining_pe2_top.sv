// tb_chaining_pe2_top.sv — FULL closed-loop check of THE JOIN (chaining_pe2_top): drives RAW
// SEEDS for read i (run_is_cand=1 -> chaining -> extension -> sort -> candidate source) then raw
// seeds for read !i (run_is_cand=0 -> entry ma), serving each on-chip rmax's reference window
// from the SAME synthetic genome g(pos)=pos&3 the golden used; then loads the mate seq +
// selection params, pulses sel_start, services each cand_req with that candidate's host-fed
// windows, and checks the FINAL rescued ma bit-exact vs gen_chaining_pe2_vectors
// (= chaining -> extend -> sort pipeline ∘ pe.h::matesw_pe_select).
//
// This is the first test of chaining -> extension -> sort -> mate-rescue as ONE block: the two
// integration trees previously met only at accel_top, never containing each other.
//
// Pairs are emitted only when both reads are non-fallback in BOTH stages, so fb_chain and
// fb_sort must stay low here; the fallback paths themselves are covered by
// tb_chaining_extend_top (stage-specific, 2000 cases incl. 451 chaining + 86 sort fallbacks).
`timescale 1ns/1ps
`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module tb_chaining_pe2_top
    import bsw_pkg::*;
    import msort_v2_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    // chaining+extend side
    logic run_is_cand, start;
    logic [15:0] n_in;
    logic signed [31:0] wcfg, max_chain_gap, max_chain_extend;
    logic signed [31:0] l_query,a,o_del,e_del,o_ins,e_ins,zdrop,pen5,pen3;
    logic        ld_en; logic [15:0] ld_idx;
    logic signed [63:0] ld_rbeg; logic signed [31:0] ld_qbeg, ld_len, ld_score, ld_rid, ld_isalt;
    logic q_ld_en; logic [15:0] q_ld_addr; base_t q_ld_data;
    logic        ref_req; logic signed [63:0] ref_rbeg; logic [15:0] ref_len;
    logic        ref_in_en; logic [15:0] ref_in_addr; base_t ref_in_data; logic ref_in_done;
    logic ce_busy, ce_done, fb_chain, fb_sort; logic [15:0] n_src_o, n_ma_init_o;
    // rescue side
    logic ld_ms_en; logic [15:0] ld_ms_addr; base_t ld_ms_data;
    logic ld_ref_en; logic [1:0] ld_ref_win; logic [15:0] ld_ref_addr; base_t ld_ref_data;
    logic sel_start;
    logic signed [31:0] l_ms,min_seed_len,a_sc,mo_del,me_del,mo_ins,me_ins,pen_unpaired,max_matesw;
    logic signed [63:0] l_pac;
    logic [3:0] win_used,pes_failed;
    logic signed [63:0] win_rb[4],win_re[4],pes_low[4],pes_high[4];
    logic signed [31:0] win_rid[4];
    logic cand_req; logic [15:0] cur_cand; logic cand_wins_ready;
    logic [15:0] src_rd_idx;
    logic signed [63:0] src_o_rb; logic signed [31:0] src_o_rid,src_o_alt,src_o_sc;
    logic rescue_busy,sel_done,tie,overflow; logic [15:0] n_ma, rd_idx;
    logic signed [63:0] o_rb,o_re; logic signed [31:0] o_qb,o_qe,o_rid,o_score,o_cov;

    chaining_pe2_top #(.MA_MAX(256), .NSRC(64), .NCHAIN(64), .NSEED(64), .NQ(512), .NS(64)) dut(.clk,.rst_n,
        .run_is_cand,.start,.n_in,
        .wcfg,.max_chain_gap,.max_chain_extend,
        .l_query,.a,.o_del,.e_del,.o_ins,.e_ins,.zdrop,.pen5,.pen3,
        .ld_en,.ld_idx,.ld_rbeg,.ld_qbeg,.ld_len,.ld_score,.ld_rid,.ld_isalt,
        .q_ld_en,.q_ld_addr,.q_ld_data,
        .ref_req,.ref_rbeg,.ref_len,.ref_in_en,.ref_in_addr,.ref_in_data,.ref_in_done,
        .ce_busy,.ce_done,.fb_chain,.fb_sort,.n_src_o,.n_ma_init_o,
        .ld_ms_en,.ld_ms_addr,.ld_ms_data,.ld_ref_en,.ld_ref_win,.ld_ref_addr,.ld_ref_data,
        .sel_start,.l_ms,.min_seed_len,.a_sc,.mo_del,.me_del,.mo_ins,.me_ins,.l_pac,
        .pen_unpaired,.max_matesw,
        .win_used,.win_rb,.win_re,.win_rid,.pes_low,.pes_high,.pes_failed,
        .cand_req,.cur_cand,.cand_wins_ready,
        .src_rd_idx,.src_o_rb,.src_o_rid,.src_o_alt,.src_o_sc,
        .rescue_busy,.sel_done,.tie,.overflow,.n_ma,.rd_idx,.o_rb,.o_re,.o_qb,.o_qe,.o_rid,.o_score,.o_cov);

    // ---- concurrent reference server: stream g(pos)=pos&3 on every ref_req ----
    // The rmax windows are computed ON CHIP, so unlike the accel-driven tbs the host cannot
    // pre-load them: it must answer each deferred-fetch request as it arrives.
    integer gi; longint gbase;
    initial begin
        ref_in_en=0; ref_in_addr=0; ref_in_data=0; ref_in_done=0;
        forever begin
            @(posedge clk);
            if (ref_req) begin
                gbase = ref_rbeg;
                for (gi=0; gi<ref_len; gi=gi+1) begin
                    @(posedge clk); ref_in_en<=1; ref_in_addr<=gi[15:0]; ref_in_data<=base_t'((gbase+gi) & 3);
                end
                @(posedge clk); ref_in_en<=0; ref_in_done<=1;
                @(posedge clk); ref_in_done<=0;
                wait(!ref_req);
            end
        end
    end

    integer fd,got,cnt,ci,k,r,c,fails,guard,nsrc,nfin,rl,e_fb;
    integer t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_gap,t_msl,t_mce,t_ns,t_nout;
    integer t_lms,t_rmsl,t_asc,t_mod,t_med,t_moi,t_mei,t_pen,t_maxm;
    longint t_lpac;
    longint sd_rb[0:63]; integer sd_qb[0:63],sd_ln[0:63],sd_sc[0:63],sd_rid[0:63],sd_alt[0:63];
    integer pf[0:3]; longint pl[0:3],ph[0:3];
    integer qbytes[0:511], msb[0:511];
    // per-candidate windows
    integer w_used[0:63][0:3]; longint w_rb[0:63][0:3], w_re[0:63][0:3]; integer w_rid[0:63][0:3], w_rl[0:63][0:3];
    integer refs[0:63][0:3][0:255];
    longint e_rb[0:511],e_re[0:511]; integer e_qb[0:511],e_qe[0:511],e_rid[0:511],e_sc[0:511],e_cov[0:511];
    string path;

    // drive one chaining->extend run from RAW SEEDS (parse the block from fd); return nout
    task automatic drive_run(input bit iscand, output integer nout_o);
        integer i;
        got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
            t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_gap,t_msl,t_mce,t_lpac,t_ns);
        for (i=0;i<t_ns;i=i+1) got=$fscanf(fd,"%d %d %d %d %d %d",
            sd_rb[i],sd_qb[i],sd_ln[i],sd_sc[i],sd_rid[i],sd_alt[i]);
        for (i=0;i<t_lq;i=i+1) got=$fscanf(fd,"%d",qbytes[i]);
        got=$fscanf(fd,"%d",t_nout);

        // load raw seeds
        for (i=0;i<t_ns;i=i+1) begin
            @(posedge clk); ld_en<=1; ld_idx<=i[15:0];
            ld_rbeg<=sd_rb[i]; ld_qbeg<=sd_qb[i]; ld_len<=sd_ln[i]; ld_score<=sd_sc[i];
            ld_rid<=sd_rid[i]; ld_isalt<=sd_alt[i];
        end
        @(posedge clk); ld_en<=0;
        // load query
        for (i=0;i<t_lq;i=i+1) begin
            @(posedge clk); q_ld_en<=1; q_ld_addr<=i[15:0]; q_ld_data<=base_t'(qbytes[i]);
        end
        @(posedge clk); q_ld_en<=0;
        // config + run. min_seed_len/l_pac are shared with the rescue (one opt field in bwa).
        run_is_cand<=iscand;
        wcfg<=t_w; max_chain_gap<=t_gap; min_seed_len<=t_msl; max_chain_extend<=t_mce;
        a<=t_a; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei; zdrop<=t_zd; pen5<=t_p5; pen3<=t_p3;
        l_query<=t_lq; l_pac<=t_lpac; n_in<=t_ns[15:0];
        @(posedge clk); start<=1; @(posedge clk); start<=0;
        nout_o = t_nout;
        guard=0; while (!ce_done && guard<20000000) begin @(posedge clk); guard=guard+1; end
    endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/mate_rescue/vectors/chaining_pe2_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        start=0; ld_en=0; q_ld_en=0; run_is_cand=0;
        ld_ms_en=0; ld_ref_en=0; sel_start=0; cand_wins_ready=0; rd_idx=0; src_rd_idx=0;
        for (k=0;k<4;k=k+1) begin win_used[k]=0; pes_failed[k]=0; win_rb[k]=0; win_re[k]=0; win_rid[k]=0; pes_low[k]=0; pes_high[k]=0; end
        repeat(6) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            // ---- run i: raw seeds -> chaining -> extend -> sort -> candidate source ----
            drive_run(1'b1, nsrc);
            if (fb_chain!==1'b0 || fb_sort!==1'b0 || n_src_o != nsrc[15:0]) begin
                fails=fails+1; if (fails<=12) $display("MISMATCH[%0d] cand-run fb_chain=%0b fb_sort=%0b n_src=%0d/%0d",
                    ci, fb_chain, fb_sort, n_src_o, nsrc);
            end
            // ---- run !i: raw seeds -> chaining -> extend -> sort -> entry ma ----
            drive_run(1'b0, nfin);   // reuse nfin temporarily for n_ma_init
            if (fb_chain!==1'b0 || fb_sort!==1'b0 || n_ma_init_o != nfin[15:0]) begin
                fails=fails+1; if (fails<=12) $display("MISMATCH[%0d] ma-run fb_chain=%0b fb_sort=%0b n_ma_init=%0d/%0d",
                    ci, fb_chain, fb_sort, n_ma_init_o, nfin);
            end

            // ---- rescue params ----
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d",
                t_lms,t_rmsl,t_asc,t_mod,t_med,t_moi,t_mei,t_pen,t_maxm);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",pf[r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",pl[r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",ph[r]);
            for (k=0;k<t_lms;k=k+1) got=$fscanf(fd,"%d",msb[k]);
            // windows for nsrc source candidates
            for (c=0;c<nsrc;c=c+1) begin
                for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",w_used[c][r]);
                for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",w_rb[c][r]);
                for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",w_re[c][r]);
                for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",w_rid[c][r]);
                for (r=0;r<4;r=r+1) begin
                    got=$fscanf(fd,"%d",rl); w_rl[c][r]=rl;
                    for (k=0;k<rl;k=k+1) got=$fscanf(fd,"%d",refs[c][r][k]);
                end
            end
            got=$fscanf(fd,"%d %d",nfin,e_fb);
            for (k=0;k<nfin;k=k+1) got=$fscanf(fd,"%d %d %d %d %d %d %d",
                e_rb[k],e_re[k],e_qb[k],e_qe[k],e_rid[k],e_sc[k],e_cov[k]);

            // ---- drive rescue (min_seed_len/l_pac already driven by drive_run; same values) ----
            l_ms<=t_lms; min_seed_len<=t_rmsl; a_sc<=t_asc;
            mo_del<=t_mod; me_del<=t_med; mo_ins<=t_moi; me_ins<=t_mei;
            pen_unpaired<=t_pen; max_matesw<=t_maxm;
            for (r=0;r<4;r=r+1) begin pes_failed[r]<=pf[r][0]; pes_low[r]<=pl[r]; pes_high[r]<=ph[r]; end
            for (k=0;k<t_lms;k=k+1) begin @(posedge clk); ld_ms_en<=1; ld_ms_addr<=k[15:0]; ld_ms_data<=base_t'(msb[k]); end
            @(posedge clk); ld_ms_en<=0;
            @(posedge clk); sel_start<=1; @(posedge clk); sel_start<=0;

            // ---- service candidate-window requests until sel_done ----
            guard=0;
            while (!sel_done && guard<8000000) begin
                @(posedge clk); guard=guard+1;
                if (cand_req && !sel_done) begin
                    c = cur_cand;
                    for (r=0;r<4;r=r+1) begin
                        rl = w_rl[c][r];
                        for (k=0;k<rl;k=k+1) begin @(posedge clk); ld_ref_en<=1; ld_ref_win<=r[1:0]; ld_ref_addr<=k[15:0]; ld_ref_data<=base_t'(refs[c][r][k]); end
                        @(posedge clk); ld_ref_en<=0;
                    end
                    for (r=0;r<4;r=r+1) begin win_used[r]<=w_used[c][r][0]; win_rb[r]<=w_rb[c][r]; win_re[r]<=w_re[c][r]; win_rid[r]<=w_rid[c][r]; end
                    @(posedge clk); cand_wins_ready<=1; @(posedge clk); cand_wins_ready<=0;
                end
            end

            // ---- check final ma ----
            if (tie !== e_fb[0]) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] tie %0b/%0b", ci, tie, e_fb[0]);
            end
            if (overflow !== 1'b0) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] unexpected rescue overflow (n_ma_init=%0d)", ci, n_ma_init_o);
            end
            if (n_ma !== nfin[15:0]) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] final n_ma %0d/%0d (nsrc=%0d pen=%0d maxm=%0d)", ci, n_ma, nfin, nsrc, t_pen, t_maxm);
            end else begin
                for (k=0;k<nfin;k=k+1) begin
                    rd_idx<=k[15:0]; @(posedge clk); #1;
                    if (o_rb!==e_rb[k]||o_re!==e_re[k]||o_qb!==e_qb[k]||o_qe!==e_qe[k]||
                        o_rid!==e_rid[k]||o_score!==e_sc[k]||o_cov!==e_cov[k]) begin
                        fails=fails+1;
                        if (fails<=12) $display("MISMATCH[%0d] ma[%0d] qb %0d/%0d qe %0d/%0d sc %0d/%0d cov %0d/%0d rbOK=%0b reOK=%0b",
                            ci,k,o_qb,e_qb[k],o_qe,e_qe[k],o_score,e_sc[k],o_cov,e_cov[k],(o_rb===e_rb[k]),(o_re===e_re[k]));
                    end
                end
            end
        end
        $fclose(fd);
        $display("tb_chaining_pe2_top: %0d cases, %0d failures -> %s", cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #(64'd400000000000); $display("[FATAL] timeout"); $finish; end
endmodule

// tb_matesw_pe_sel_top.sv — self-checking TB for matesw_pe_sel_top (on-chip candidate
// SELECTION + rescue loop). Loads the score-sorted candidate SOURCE, the entry ma, the
// shared mate seq, and the selection params; pulses sel_start; then acts as the host —
// servicing each cand_req by loading that candidate's host-fed ref windows + meta and
// pulsing cand_wins_ready. Finally checks the threaded ma list bit-exact vs
// gen_pesel_vectors (= matesw_pe_select). The DUT computes K (the selected prefix) and
// drives the candidates itself; the tb never decides which/how many fire.
`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_matesw_pe_sel_top
    import bsw_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    // source + params
    logic src_ld_en; logic [15:0] src_ld_idx;
    logic signed [63:0] src_ld_rb; logic signed [31:0] src_ld_rid, src_ld_alt, src_ld_score;
    logic [15:0] n_src; logic signed [31:0] pen_unpaired, max_matesw;
    // pass-through loads
    logic ld_ms_en; logic [15:0] ld_ms_addr; base_t ld_ms_data;
    logic ld_ref_en; logic [1:0] ld_ref_win; logic [15:0] ld_ref_addr; base_t ld_ref_data;
    logic ld_ma_en; logic [15:0] ld_ma_idx;
    logic signed [63:0] ld_ma_rb, ld_ma_re; logic signed [31:0] ld_ma_qb,ld_ma_qe,ld_ma_rid,ld_ma_score,ld_ma_cov;
    logic [15:0] n_ma_init;
    // scalars
    logic sel_start; logic signed [31:0] l_ms,min_seed_len,a,o_del,e_del,o_ins,e_ins;
    logic signed [63:0] l_pac;
    // per-candidate windows (driven on cand_req)
    logic [3:0] win_used, pes_failed;
    logic signed [63:0] win_rb[4], win_re[4], pes_low[4], pes_high[4];
    logic signed [31:0] win_rid[4];
    // handshake + result
    logic cand_req; logic [15:0] cur_cand; logic cand_wins_ready;
    logic busy, done, tie, overflow; logic [15:0] n_ma, rd_idx;
    logic signed [63:0] o_rb,o_re; logic signed [31:0] o_qb,o_qe,o_rid,o_score,o_cov;
    // debug source readback (unused here; exercised by tb_accel_pe2_top)
    logic [15:0] src_rd_idx = '0;
    logic signed [63:0] src_o_rb; logic signed [31:0] src_o_rid, src_o_alt, src_o_sc;

    matesw_pe_sel_top #(.MA_MAX(256), .NSRC(64)) dut(.clk,.rst_n,
        .src_ld_en,.src_ld_idx,.src_ld_rb,.src_ld_rid,.src_ld_alt,.src_ld_score,
        .n_src,.pen_unpaired,.max_matesw,
        .ld_ms_en,.ld_ms_addr,.ld_ms_data,.ld_ref_en,.ld_ref_win,.ld_ref_addr,.ld_ref_data,
        .ld_ma_en,.ld_ma_idx,.ld_ma_rb,.ld_ma_re,.ld_ma_qb,.ld_ma_qe,.ld_ma_rid,.ld_ma_score,.ld_ma_cov,
        .n_ma_init,.sel_start,.l_ms,.min_seed_len,.a,.o_del,.e_del,.o_ins,.e_ins,.l_pac,
        .win_used,.win_rb,.win_re,.win_rid,.pes_low,.pes_high,.pes_failed,
        .cand_req,.cur_cand,.cand_wins_ready,
        .src_rd_idx,.src_o_rb,.src_o_rid,.src_o_alt,.src_o_sc,
        .busy,.done,.tie,.overflow,.n_ma,.rd_idx,.o_rb,.o_re,.o_qb,.o_qe,.o_rid,.o_score,.o_cov);

    integer fd,got,cnt,ci,k,r,c,fails,guard,nsrc,ninit,nfin,rl,e_fb;
    integer t_lms,t_lpac,t_msl,t_a,t_od,t_ed,t_oi,t_ei,t_pen,t_maxm;
    integer pf[0:3],pl[0:3],ph[0:3];
    integer i_rb[0:63],i_re[0:63],i_qb[0:63],i_qe[0:63],i_rid[0:63],i_sc[0:63],i_cov[0:63];
    integer e_rb[0:63],e_re[0:63],e_qb[0:63],e_qe[0:63],e_rid[0:63],e_sc[0:63],e_cov[0:63];
    integer s_rb_[0:63],s_rid_[0:63],s_alt_[0:63],s_sc_[0:63];
    // per-candidate stored windows
    integer w_used[0:63][0:3],w_rb[0:63][0:3],w_re[0:63][0:3],w_rid[0:63][0:3],w_rl[0:63][0:3];
    integer refs[0:63][0:3][0:255];
    integer msb[0:255];

    string path;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/mate_rescue/vectors/pesel_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        src_ld_en=0; ld_ms_en=0; ld_ref_en=0; ld_ma_en=0; sel_start=0; cand_wins_ready=0; rd_idx=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",
                t_lms,t_lpac,t_msl,t_a,t_od,t_ed,t_oi,t_ei,t_pen,t_maxm);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",pf[r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",pl[r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",ph[r]);
            got=$fscanf(fd,"%d",ninit);
            for (k=0;k<ninit;k=k+1) got=$fscanf(fd,"%d %d %d %d %d %d %d",
                i_rb[k],i_re[k],i_qb[k],i_qe[k],i_rid[k],i_sc[k],i_cov[k]);
            for (k=0;k<t_lms;k=k+1) got=$fscanf(fd,"%d",msb[k]);
            got=$fscanf(fd,"%d",nsrc);
            for (c=0;c<nsrc;c=c+1) got=$fscanf(fd,"%d %d %d %d",s_rb_[c],s_rid_[c],s_alt_[c],s_sc_[c]);
            // all candidates' windows (served on demand below)
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

            // ---- drive: constants ----
            l_ms<=t_lms; l_pac<=t_lpac; min_seed_len<=t_msl; a<=t_a;
            o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei;
            pen_unpaired<=t_pen; max_matesw<=t_maxm; n_src<=nsrc[15:0];
            for (r=0;r<4;r=r+1) begin pes_failed[r]<=pf[r][0]; pes_low[r]<=pl[r]; pes_high[r]<=ph[r]; end

            // load shared mate seq
            for (k=0;k<t_lms;k=k+1) begin @(posedge clk); ld_ms_en<=1; ld_ms_addr<=k[15:0]; ld_ms_data<=base_t'(msb[k]); end
            @(posedge clk); ld_ms_en<=0;
            // load entry ma
            for (k=0;k<ninit;k=k+1) begin @(posedge clk); ld_ma_en<=1; ld_ma_idx<=k[15:0];
                ld_ma_rb<=i_rb[k]; ld_ma_re<=i_re[k]; ld_ma_qb<=i_qb[k]; ld_ma_qe<=i_qe[k];
                ld_ma_rid<=i_rid[k]; ld_ma_score<=i_sc[k]; ld_ma_cov<=i_cov[k]; end
            @(posedge clk); ld_ma_en<=0;
            // load source buffer
            for (c=0;c<nsrc;c=c+1) begin @(posedge clk); src_ld_en<=1; src_ld_idx<=c[15:0];
                src_ld_rb<=s_rb_[c]; src_ld_rid<=s_rid_[c]; src_ld_alt<=s_alt_[c]; src_ld_score<=s_sc_[c]; end
            @(posedge clk); src_ld_en<=0;
            n_ma_init<=ninit[15:0];
            @(posedge clk); sel_start<=1; @(posedge clk); sel_start<=0;

            // ---- service candidate-window requests until done ----
            guard=0;
            while (!done && guard<8000000) begin
                @(posedge clk); guard=guard+1;
                if (cand_req && !done) begin
                    c = cur_cand;            // candidate the DUT wants windows for
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
                if (fails<=15) $display("MISMATCH[%0d] tie %0b/%0b (nsrc=%0d)", ci, tie, e_fb[0], nsrc);
            end
            if (n_ma !== nfin[15:0]) begin
                fails=fails+1;
                if (fails<=15) $display("MISMATCH[%0d] n_ma %0d/%0d (ninit=%0d nsrc=%0d pen=%0d maxm=%0d)",
                    ci, n_ma, nfin, ninit, nsrc, t_pen, t_maxm);
            end else begin
                for (k=0;k<nfin;k=k+1) begin
                    rd_idx<=k[15:0]; @(posedge clk); #1;
                    if (o_rb!==e_rb[k] || o_re!==e_re[k] || o_qb!==e_qb[k] || o_qe!==e_qe[k] ||
                        o_rid!==e_rid[k] || o_score!==e_sc[k] || o_cov!==e_cov[k]) begin
                        fails=fails+1;
                        if (fails<=15)
                            $display("MISMATCH[%0d] surv %0d: rb %0d/%0d re %0d/%0d qb %0d/%0d qe %0d/%0d sc %0d/%0d cov %0d/%0d",
                                ci,k,o_rb,e_rb[k],o_re,e_re[k],o_qb,e_qb[k],o_qe,e_qe[k],o_score,e_sc[k],o_cov,e_cov[k]);
                    end
                end
            end
        end
        $fclose(fd);
        $display("tb_matesw_pe_sel_top: %0d cases, %0d failures -> %s", cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #(64'd6000000000); $display("[FATAL] timeout"); $finish; end
endmodule

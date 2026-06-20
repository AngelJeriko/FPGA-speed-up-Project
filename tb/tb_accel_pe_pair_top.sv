// tb_accel_pe_pair_top.sv — BOTH-DIRECTIONS closed-loop check of the sequencer. Per pair:
//   Dir 0: drive accel read0 (cand) + read1 (ma), rescue (mate=read1) -> a[1]'; snapshot to buffer A.
//   Dir 1: drive accel read1 (cand) + read0 (ma), rescue (mate=read0) -> a[0]' (inner live).
// Then read BOTH from the sequencer — a[1]' via res_from_a=1 (buffer), a[0]' via res_from_a=0
// (inner) — and check bit-exact vs gen_pe2pair_vectors. Verifies the both-directions
// semantics AND that the result-A snapshot survives direction 1 reusing the inner regfile.
`timescale 1ns/1ps
`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module tb_accel_pe_pair_top
    import bsw_pkg::*;
    import msort_v2_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic run_is_cand, read_start, read_finish, ch_ready, ch_go;
    logic signed [31:0] l_query,a,o_del,e_del,o_ins,e_ins,zdrop,wcfg,pen5,pen3;
    logic q_ld_en,r_ld_en,s_ld_en; logic [15:0] q_ld_addr,r_ld_addr;
    base_t q_ld_data,r_ld_data;
    logic [7:0] s_ld_idx,ch_n; logic signed [63:0] s_ld_rbeg,ch_rmax0,ch_rmax1;
    logic signed [31:0] s_ld_qbeg,s_ld_len,s_ld_score,ch_rid;
    logic accel_busy, accel_done, accel_fallback; logic [15:0] n_src_o, n_ma_init_o;
    logic ld_ms_en; logic [15:0] ld_ms_addr; base_t ld_ms_data;
    logic ld_ref_en; logic [1:0] ld_ref_win; logic [15:0] ld_ref_addr; base_t ld_ref_data;
    logic sel_start;
    logic signed [31:0] l_ms,min_seed_len,a_sc,mo_del,me_del,mo_ins,me_ins,pen_unpaired,max_matesw;
    logic signed [63:0] l_pac;
    logic [3:0] win_used,pes_failed;
    logic signed [63:0] win_rb[4],win_re[4],pes_low[4],pes_high[4];
    logic signed [31:0] win_rid[4];
    logic cand_req; logic [15:0] cur_cand; logic cand_wins_ready;
    logic rescue_busy,sel_done,tie;
    logic snap_a_start, snap_busy, snap_done, res_from_a;
    logic [15:0] rd_idx, n_ma;
    logic signed [63:0] o_rb,o_re; logic signed [31:0] o_qb,o_qe,o_rid,o_score,o_cov;

    accel_pe_pair_top #(.MA_MAX(64), .NSRC(64)) dut(.clk,.rst_n,
        .run_is_cand,.read_start,.l_query,.a,.o_del,.e_del,.o_ins,.e_ins,.zdrop,.wcfg(wcfg),.pen5,.pen3,
        .q_ld_en,.q_ld_addr,.q_ld_data,.r_ld_en,.r_ld_addr,.r_ld_data,
        .s_ld_en,.s_ld_idx,.s_ld_rbeg,.s_ld_qbeg,.s_ld_len,.s_ld_score,
        .ch_go,.ch_n,.ch_rid,.ch_rmax0,.ch_rmax1,.ch_ready,.read_finish,
        .accel_busy,.accel_done,.accel_fallback,.n_src_o,.n_ma_init_o,
        .ld_ms_en,.ld_ms_addr,.ld_ms_data,.ld_ref_en,.ld_ref_win,.ld_ref_addr,.ld_ref_data,
        .sel_start,.l_ms,.min_seed_len,.a_sc,.mo_del,.me_del,.mo_ins,.me_ins,.l_pac,
        .pen_unpaired,.max_matesw,
        .win_used,.win_rb,.win_re,.win_rid,.pes_low,.pes_high,.pes_failed,
        .cand_req,.cur_cand,.cand_wins_ready,.rescue_busy,.sel_done,.tie,
        .snap_a_start,.snap_busy,.snap_done,.res_from_a,
        .rd_idx,.n_ma,.o_rb,.o_re,.o_qb,.o_qe,.o_rid,.o_score,.o_cov);

    integer fd,got,cnt,ci,k,r,c,fails,guard,nsrc,nma,nexp,rl;
    integer t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_nch,t_nav,t_fb,t_nout;
    integer t_lms,t_msl,t_asc,t_mod,t_med,t_moi,t_mei,t_pen,t_maxm;
    longint t_lpac;
    integer c_rid,c_n,reflen; longint c_rmax0,c_rmax1;
    longint sd_rb; integer sd_qb,sd_ln,sd_sc;
    longint or_rb,or_re; integer or_qb,or_qe,or_rid,or_sc;
    integer pf[0:3]; longint pl[0:3],ph[0:3];
    integer qbytes[0:255], rbytes[0:1023], msb[0:255];
    integer w_used[0:63][0:3]; longint w_rb[0:63][0:3], w_re[0:63][0:3]; integer w_rid[0:63][0:3], w_rl[0:63][0:3];
    integer refs[0:63][0:3][0:255];
    // expected results (dir0 -> a1'; dir1 -> a0')
    longint e0_rb[0:63],e0_re[0:63],e1_rb[0:63],e1_re[0:63];
    integer e0_qb[0:63],e0_qe[0:63],e0_rid[0:63],e0_sc[0:63],e0_cov[0:63], n_e0;
    integer e1_qb[0:63],e1_qe[0:63],e1_rid[0:63],e1_sc[0:63],e1_cov[0:63], n_e1;
    string path;

    task automatic qld(input int addr,input int dat);
        @(posedge clk); q_ld_en<=1; q_ld_addr<=addr[15:0]; q_ld_data<=base_t'(dat); @(posedge clk); q_ld_en<=0;
    endtask
    task automatic rld(input int addr,input int dat);
        @(posedge clk); r_ld_en<=1; r_ld_addr<=addr[15:0]; r_ld_data<=base_t'(dat); @(posedge clk); r_ld_en<=0;
    endtask
    task automatic sld(input int idx,input longint rb_,input int qb_,input int ln_,input int sc_);
        @(posedge clk); s_ld_en<=1; s_ld_idx<=idx[7:0]; s_ld_rbeg<=rb_; s_ld_qbeg<=qb_; s_ld_len<=ln_; s_ld_score<=sc_;
        @(posedge clk); s_ld_en<=0;
    endtask

    task automatic drive_accel(input bit iscand, output integer nout_o);
        integer cj,i;
        got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d",
            t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_nch,t_nav);
        for (i=0;i<t_lq;i=i+1) got=$fscanf(fd,"%d",qbytes[i]);
        run_is_cand<=iscand;
        l_query<=t_lq; a<=t_a; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei;
        zdrop<=t_zd; wcfg<=t_w; pen5<=t_p5; pen3<=t_p3;
        @(posedge clk); read_start<=1; @(posedge clk); read_start<=0;
        wait(ch_ready);
        for (i=0;i<t_lq;i=i+1) qld(i,qbytes[i]);
        for (cj=0; cj<t_nch; cj=cj+1) begin
            got=$fscanf(fd,"%d %d %d %d %d", c_rid,c_rmax0,c_rmax1,c_n,reflen);
            wait(ch_ready);
            for (i=0;i<c_n;i=i+1) begin got=$fscanf(fd,"%d %d %d %d", sd_rb,sd_qb,sd_ln,sd_sc); sld(i,sd_rb,sd_qb,sd_ln,sd_sc); end
            for (i=0;i<reflen;i=i+1) got=$fscanf(fd,"%d",rbytes[i]);
            for (i=0;i<reflen;i=i+1) rld(i,rbytes[i]);
            @(posedge clk); ch_n<=c_n[7:0]; ch_rid<=c_rid; ch_rmax0<=c_rmax0; ch_rmax1<=c_rmax1;
            ch_go<=1; @(posedge clk); ch_go<=0; @(posedge clk); wait(ch_ready);
        end
        got=$fscanf(fd,"%d %d", t_fb, t_nout);
        for (i=0;i<t_nout;i=i+1) got=$fscanf(fd,"%d %d %d %d %d %d", or_rb,or_re,or_qb,or_qe,or_rid,or_sc);
        nout_o = t_nout;
        wait(ch_ready); @(posedge clk); read_finish<=1; @(posedge clk); read_finish<=0;
        guard=0; while (!accel_done && guard<20000000) begin @(posedge clk); guard=guard+1; end
    endtask

    // process one direction: 2 accel runs + rescue; store expected into dir-`which` arrays
    task automatic run_direction(input int which);
        integer i;
        drive_accel(1'b1, nsrc);
        if (accel_fallback!==1'b0 || n_src_o != nsrc[15:0]) begin fails=fails+1;
            if (fails<=12) $display("MISMATCH[%0d.%0d] cand n_src=%0d/%0d fb=%0b", ci, which, n_src_o, nsrc, accel_fallback); end
        drive_accel(1'b0, nma);
        if (accel_fallback!==1'b0 || n_ma_init_o != nma[15:0]) begin fails=fails+1;
            if (fails<=12) $display("MISMATCH[%0d.%0d] ma n_ma_init=%0d/%0d fb=%0b", ci, which, n_ma_init_o, nma, accel_fallback); end
        got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d",
            t_lms,t_lpac,t_msl,t_asc,t_mod,t_med,t_moi,t_mei,t_pen,t_maxm);
        for (i=0;i<4;i=i+1) got=$fscanf(fd,"%d",pf[i]);
        for (i=0;i<4;i=i+1) got=$fscanf(fd,"%d",pl[i]);
        for (i=0;i<4;i=i+1) got=$fscanf(fd,"%d",ph[i]);
        for (k=0;k<t_lms;k=k+1) got=$fscanf(fd,"%d",msb[k]);
        for (c=0;c<nsrc;c=c+1) begin
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",w_used[c][r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",w_rb[c][r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",w_re[c][r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",w_rid[c][r]);
            for (r=0;r<4;r=r+1) begin got=$fscanf(fd,"%d",rl); w_rl[c][r]=rl;
                for (k=0;k<rl;k=k+1) got=$fscanf(fd,"%d",refs[c][r][k]); end
        end
        got=$fscanf(fd,"%d",nexp);
        for (k=0;k<nexp;k=k+1) begin
            if (which==0) got=$fscanf(fd,"%d %d %d %d %d %d %d", e0_rb[k],e0_re[k],e0_qb[k],e0_qe[k],e0_rid[k],e0_sc[k],e0_cov[k]);
            else          got=$fscanf(fd,"%d %d %d %d %d %d %d", e1_rb[k],e1_re[k],e1_qb[k],e1_qe[k],e1_rid[k],e1_sc[k],e1_cov[k]);
        end
        if (which==0) n_e0=nexp; else n_e1=nexp;

        // drive rescue
        l_ms<=t_lms; l_pac<=t_lpac; min_seed_len<=t_msl; a_sc<=t_asc;
        mo_del<=t_mod; me_del<=t_med; mo_ins<=t_moi; me_ins<=t_mei; pen_unpaired<=t_pen; max_matesw<=t_maxm;
        for (r=0;r<4;r=r+1) begin pes_failed[r]<=pf[r][0]; pes_low[r]<=pl[r]; pes_high[r]<=ph[r]; end
        for (k=0;k<t_lms;k=k+1) begin @(posedge clk); ld_ms_en<=1; ld_ms_addr<=k[15:0]; ld_ms_data<=base_t'(msb[k]); end
        @(posedge clk); ld_ms_en<=0;
        @(posedge clk); sel_start<=1; @(posedge clk); sel_start<=0;
        guard=0;
        while (!sel_done && guard<8000000) begin
            @(posedge clk); guard=guard+1;
            if (cand_req && !sel_done) begin
                c = cur_cand;
                for (r=0;r<4;r=r+1) begin rl=w_rl[c][r];
                    for (k=0;k<rl;k=k+1) begin @(posedge clk); ld_ref_en<=1; ld_ref_win<=r[1:0]; ld_ref_addr<=k[15:0]; ld_ref_data<=base_t'(refs[c][r][k]); end
                    @(posedge clk); ld_ref_en<=0; end
                for (r=0;r<4;r=r+1) begin win_used[r]<=w_used[c][r][0]; win_rb[r]<=w_rb[c][r]; win_re[r]<=w_re[c][r]; win_rid[r]<=w_rid[c][r]; end
                @(posedge clk); cand_wins_ready<=1; @(posedge clk); cand_wins_ready<=0;
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/mate_rescue/vectors/pe2pair_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        read_start=0; read_finish=0; ch_go=0; q_ld_en=0; r_ld_en=0; s_ld_en=0; run_is_cand=0;
        ld_ms_en=0; ld_ref_en=0; sel_start=0; cand_wins_ready=0; rd_idx=0;
        snap_a_start=0; res_from_a=0;
        for (k=0;k<4;k=k+1) begin win_used[k]=0; pes_failed[k]=0; win_rb[k]=0; win_re[k]=0; win_rid[k]=0; pes_low[k]=0; pes_high[k]=0; end
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            // direction 0 -> a[1]', then snapshot to buffer A
            run_direction(0);
            @(posedge clk); snap_a_start<=1; @(posedge clk); snap_a_start<=0;
            guard=0; while (snap_busy && guard<200000) begin @(posedge clk); guard=guard+1; end
            // direction 1 -> a[0]' (inner live)
            run_direction(1);

            // check a[1]' (buffer A) and a[0]' (inner live)
            res_from_a<=1; @(posedge clk); #1;
            if (n_ma !== n_e0[15:0]) begin fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] a1' n_ma %0d/%0d", ci, n_ma, n_e0); end
            else for (k=0;k<n_e0;k=k+1) begin
                rd_idx<=k[15:0]; @(posedge clk); #1;
                if (o_rb!==e0_rb[k]||o_re!==e0_re[k]||o_qb!==e0_qb[k]||o_qe!==e0_qe[k]||o_rid!==e0_rid[k]||o_score!==e0_sc[k]||o_cov!==e0_cov[k]) begin
                    fails=fails+1; if (fails<=12) $display("MISMATCH[%0d] a1'[%0d] qb %0d/%0d sc %0d/%0d rbOK=%0b", ci,k,o_qb,e0_qb[k],o_score,e0_sc[k],(o_rb===e0_rb[k])); end
            end
            res_from_a<=0; @(posedge clk); #1;
            if (n_ma !== n_e1[15:0]) begin fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] a0' n_ma %0d/%0d", ci, n_ma, n_e1); end
            else for (k=0;k<n_e1;k=k+1) begin
                rd_idx<=k[15:0]; @(posedge clk); #1;
                if (o_rb!==e1_rb[k]||o_re!==e1_re[k]||o_qb!==e1_qb[k]||o_qe!==e1_qe[k]||o_rid!==e1_rid[k]||o_score!==e1_sc[k]||o_cov!==e1_cov[k]) begin
                    fails=fails+1; if (fails<=12) $display("MISMATCH[%0d] a0'[%0d] qb %0d/%0d sc %0d/%0d rbOK=%0b", ci,k,o_qb,e1_qb[k],o_score,e1_sc[k],(o_rb===e1_rb[k])); end
            end
        end
        $fclose(fd);
        $display("tb_accel_pe_pair_top: %0d pairs, %0d failures -> %s", cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #80000000000; $display("[FATAL] timeout"); $finish; end
endmodule

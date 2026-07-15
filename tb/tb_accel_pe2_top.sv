// tb_accel_pe2_top.sv — verifies the TWO-TARGET capture routing in accel_pe2_top: the
// new logic in the fold. Reusing the accel vectors, it drives accel_top per read with
// run_is_cand alternating: on a source-run (even reads) it checks the candidate SOURCE
// buffer == accel's sorted output a[R] (rb/rid/score; alt must be 0); on a ma-run (odd
// reads) it checks the rescue ma regfile == a[R] (rb/re/qb/qe/rid/score; cov must be 0).
// It does NOT pulse sel_start — the selection + rescue datapath is covered bit-exact by
// tb_matesw_pe_sel_top; this isolates the capture FSM (cf. tb_accel_pe_top for the
// single-run handoff). Fallback reads must raise accel_fallback and are not compared.
`timescale 1ns/1ps
`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module tb_accel_pe2_top
    import bsw_pkg::*;
    import msort_v2_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    // accel-side
    logic run_is_cand, read_start, read_finish, ch_ready, ch_go;
    logic signed [31:0] l_query,a,o_del,e_del,o_ins,e_ins,zdrop,wcfg,pen5,pen3;
    logic q_ld_en,r_ld_en,s_ld_en; logic [15:0] q_ld_addr,r_ld_addr;
    base_t q_ld_data,r_ld_data;
    logic [7:0] s_ld_idx,ch_n; logic signed [63:0] s_ld_rbeg,ch_rmax0,ch_rmax1;
    logic signed [31:0] s_ld_qbeg,s_ld_len,s_ld_score,ch_rid;
    logic accel_busy, accel_done, accel_fallback; logic [15:0] n_src_o, n_ma_init_o;
    // rescue-side (tied off — only the capture routing is exercised here)
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

    accel_pe2_top #(.MA_MAX(256), .NSRC(64)) dut(.clk,.rst_n,
        .run_is_cand,.read_start,.l_query,.a,.o_del,.e_del,.o_ins,.e_ins,.zdrop,.wcfg(wcfg),.pen5,.pen3,
        .q_ld_en,.q_ld_addr,.q_ld_data,.r_ld_en,.r_ld_addr,.r_ld_data,
        .s_ld_en,.s_ld_idx,.s_ld_rbeg,.s_ld_qbeg,.s_ld_len,.s_ld_score,
        .ch_go,.ch_n,.ch_rid,.ch_rmax0,.ch_rmax1,.ch_ready,.read_finish,
        .accel_busy,.accel_done,.accel_fallback,.n_src_o,.n_ma_init_o,
        .ld_ms_en,.ld_ms_addr,.ld_ms_data,.ld_ref_en,.ld_ref_win,.ld_ref_addr,.ld_ref_data,
        .sel_start,.l_ms,.min_seed_len,.a_sc,.mo_del,.me_del,.mo_ins,.me_ins,.l_pac,
        .pen_unpaired,.max_matesw,
        .win_used,.win_rb,.win_re,.win_rid,.pes_low,.pes_high,.pes_failed,
        .cand_req,.cur_cand,.cand_wins_ready,
        .src_rd_idx,.src_o_rb,.src_o_rid,.src_o_alt,.src_o_sc,
        .rescue_busy,.sel_done,.tie,.overflow,.n_ma,.rd_idx,.o_rb,.o_re,.o_qb,.o_qe,.o_rid,.o_score,.o_cov);

    integer fd,got,nreads,ri,cj,i,b,fails,guard,seen,iscand;
    integer t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_nch,t_nav,t_fb,t_nout;
    integer c_rid,c_n,reflen; longint c_rmax0,c_rmax1;
    longint sd_rb; integer sd_qb,sd_ln,sd_sc;
    integer qbytes[0:255], rbytes[0:1023];
    longint e_rb[0:1023],e_re[0:1023]; integer e_qb[0:1023],e_qe[0:1023],e_rid[0:1023],e_sc[0:1023];
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

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/extend_orchestrator/vectors/accel_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        read_start=0; read_finish=0; ch_go=0; q_ld_en=0; r_ld_en=0; s_ld_en=0; run_is_cand=0;
        ld_ms_en=0; ld_ref_en=0; sel_start=0; cand_wins_ready=0; rd_idx=0; src_rd_idx=0;
        l_ms=0; min_seed_len=0; a_sc=0; mo_del=0; me_del=0; mo_ins=0; me_ins=0; l_pac=0;
        pen_unpaired=0; max_matesw=0;
        for (i=0;i<4;i=i+1) begin win_used[i]=0; pes_failed[i]=0; win_rb[i]=0; win_re[i]=0; win_rid[i]=0; pes_low[i]=0; pes_high[i]=0; end
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",nreads); fails=0;
        for (ri=0; ri<nreads; ri=ri+1) begin
            iscand = (ri % 2 == 0) ? 1 : 0;     // alternate: even=source run, odd=ma run
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d",
                t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_nch,t_nav);
            for (b=0;b<t_lq;b=b+1) got=$fscanf(fd,"%d",qbytes[b]);

            run_is_cand<=iscand[0];
            l_query<=t_lq; a<=t_a; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei;
            zdrop<=t_zd; wcfg<=t_w; pen5<=t_p5; pen3<=t_p3;
            @(posedge clk); read_start<=1; @(posedge clk); read_start<=0;
            wait(ch_ready);
            for (b=0;b<t_lq;b=b+1) qld(b,qbytes[b]);

            for (cj=0; cj<t_nch; cj=cj+1) begin
                got=$fscanf(fd,"%d %d %d %d %d", c_rid,c_rmax0,c_rmax1,c_n,reflen);
                wait(ch_ready);
                for (i=0;i<c_n;i=i+1) begin
                    got=$fscanf(fd,"%d %d %d %d", sd_rb,sd_qb,sd_ln,sd_sc);
                    sld(i,sd_rb,sd_qb,sd_ln,sd_sc);
                end
                for (b=0;b<reflen;b=b+1) got=$fscanf(fd,"%d",rbytes[b]);
                for (b=0;b<reflen;b=b+1) rld(b,rbytes[b]);
                @(posedge clk); ch_n<=c_n[7:0]; ch_rid<=c_rid; ch_rmax0<=c_rmax0; ch_rmax1<=c_rmax1;
                ch_go<=1; @(posedge clk); ch_go<=0; @(posedge clk); wait(ch_ready);
            end

            got=$fscanf(fd,"%d %d", t_fb, t_nout);
            for (i=0;i<t_nout;i=i+1)
                got=$fscanf(fd,"%d %d %d %d %d %d", e_rb[i],e_re[i],e_qb[i],e_qe[i],e_rid[i],e_sc[i]);

            // finish -> accel runs; wait for this run's capture-complete pulse
            wait(ch_ready); @(posedge clk); read_finish<=1; @(posedge clk); read_finish<=0;
            seen=0; guard=0;
            while (!seen && guard<20000000) begin @(posedge clk); guard=guard+1; if (accel_done) seen=1; end

            if (t_fb) begin
                if (accel_fallback !== 1'b1) begin
                    fails=fails+1;
                    if (fails<=12) $display("MISMATCH read=%0d (%s) expected accel_fallback", ri, iscand?"cand":"ma");
                end
            end else if (iscand) begin
                // source-run: n_src_o and source buffer == a[R] (rb/rid/score; alt==0)
                if (accel_fallback !== 1'b0 || n_src_o != t_nout) begin
                    fails=fails+1;
                    if (fails<=12) $display("MISMATCH read=%0d cand fb=%0b n_src=%0d/%0d", ri, accel_fallback, n_src_o, t_nout);
                end else begin
                    for (i=0;i<t_nout;i=i+1) begin
                        src_rd_idx<=i[15:0]; @(posedge clk); #1;
                        if (src_o_rb!==e_rb[i] || src_o_rid!==e_rid[i] || src_o_sc!==e_sc[i] || src_o_alt!==32'sd0) begin
                            fails=fails+1;
                            if (fails<=12) $display("MISMATCH read=%0d cand src[%0d] rbOK=%0b rid %0d/%0d sc %0d/%0d alt=%0d",
                                ri,i,(src_o_rb===e_rb[i]),src_o_rid,e_rid[i],src_o_sc,e_sc[i],src_o_alt);
                        end
                    end
                end
            end else begin
                // ma-run: n_ma_init_o and ma regfile == a[R] (full record; cov==0)
                if (accel_fallback !== 1'b0 || n_ma_init_o != t_nout) begin
                    fails=fails+1;
                    if (fails<=12) $display("MISMATCH read=%0d ma fb=%0b n_ma_init=%0d/%0d", ri, accel_fallback, n_ma_init_o, t_nout);
                end else begin
                    for (i=0;i<t_nout;i=i+1) begin
                        rd_idx<=i[15:0]; @(posedge clk); #1;
                        if (o_rb!==e_rb[i]||o_re!==e_re[i]||o_qb!==e_qb[i]||o_qe!==e_qe[i]||
                            o_rid!==e_rid[i]||o_score!==e_sc[i]||o_cov!==32'sd0) begin
                            fails=fails+1;
                            if (fails<=12) $display("MISMATCH read=%0d ma[%0d] qb %0d/%0d qe %0d/%0d sc %0d/%0d cov=%0d rbOK=%0b reOK=%0b",
                                ri,i,o_qb,e_qb[i],o_qe,e_qe[i],o_score,e_sc[i],o_cov,(o_rb===e_rb[i]),(o_re===e_re[i]));
                        end
                    end
                end
            end
        end
        $fclose(fd);
        $display("tb_accel_pe2_top: %0d reads, %0d failures -> %s", nreads, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #(64'd20000000000); $display("[FATAL] timeout"); $finish; end
endmodule

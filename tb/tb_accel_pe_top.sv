// tb_accel_pe_top.sv — verifies the accel->mate-rescue ON-CHIP HANDOFF in
// accel_pe_top: drives accel_top for a read (reusing the accel vectors), then after
// the capture completes (ma_ready) reads matesw_pe_top's ma register file back and
// checks it equals accel's sorted/deduped output a[R]. This validates the new
// capture FSM (the only new logic in the fold); the rescue datapath itself is
// covered by tb_matesw_pe_top, and accel by tb_accel_top. Fallback reads (no on-chip
// output) are expected to raise accel_fallback and are not compared.
`timescale 1ns/1ps
`include "bsw_pkg.sv"
`include "msort_v2_pkg.sv"

module tb_accel_pe_top
    import bsw_pkg::*;
    import msort_v2_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    // accel-side
    logic read_start, read_finish, ch_ready, ch_go;
    logic signed [31:0] l_query,a,o_del,e_del,o_ins,e_ins,zdrop,wcfg,pen5,pen3;
    logic q_ld_en,r_ld_en,s_ld_en; logic [15:0] q_ld_addr,r_ld_addr;
    base_t q_ld_data,r_ld_data;
    logic [7:0] s_ld_idx,ch_n; logic signed [63:0] s_ld_rbeg,ch_rmax0,ch_rmax1;
    logic signed [31:0] s_ld_qbeg,s_ld_len,s_ld_score,ch_rid;
    logic accel_fallback, accel_busy, ma_ready;
    // rescue-side (tied off — only the capture handoff is exercised here)
    logic ld_ms_en; logic [15:0] ld_ms_addr; base_t ld_ms_data;
    logic ld_ref_en; logic [1:0] ld_ref_win; logic [15:0] ld_ref_addr; base_t ld_ref_data;
    logic cand_start;
    logic signed [31:0] l_ms,min_seed_len,a_sc,mo_del,me_del,mo_ins,me_ins,a_rid,a_is_alt;
    logic signed [63:0] a_rb,l_pac;
    logic [3:0] win_used,pes_failed;
    logic signed [63:0] win_rb[4],win_re[4],pes_low[4],pes_high[4];
    logic signed [31:0] win_rid[4];
    logic rescue_busy,cand_done,tie; logic [15:0] n_ma, rd_idx;
    logic signed [63:0] o_rb,o_re; logic signed [31:0] o_qb,o_qe,o_rid,o_score,o_cov;

    accel_pe_top #(.MA_MAX(64)) dut(.clk,.rst_n,
        .read_start,.l_query,.a,.o_del,.e_del,.o_ins,.e_ins,.zdrop,.wcfg(wcfg),.pen5,.pen3,
        .q_ld_en,.q_ld_addr,.q_ld_data,.r_ld_en,.r_ld_addr,.r_ld_data,
        .s_ld_en,.s_ld_idx,.s_ld_rbeg,.s_ld_qbeg,.s_ld_len,.s_ld_score,
        .ch_go,.ch_n,.ch_rid,.ch_rmax0,.ch_rmax1,.ch_ready,.read_finish,
        .accel_fallback,.accel_busy,.ma_ready,
        .ld_ms_en,.ld_ms_addr,.ld_ms_data,.ld_ref_en,.ld_ref_win,.ld_ref_addr,.ld_ref_data,
        .cand_start,.l_ms,.min_seed_len,.a_sc,.mo_del,.me_del,.mo_ins,.me_ins,
        .a_rb,.l_pac,.a_rid,.a_is_alt,.win_used,.win_rb,.win_re,.win_rid,.pes_low,.pes_high,.pes_failed,
        .rescue_busy,.cand_done,.tie,.n_ma,.rd_idx,.o_rb,.o_re,.o_qb,.o_qe,.o_rid,.o_score,.o_cov);

    integer fd,got,nreads,ri,cj,i,b,fails,guard,seen;
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
        read_start=0; read_finish=0; ch_go=0; q_ld_en=0; r_ld_en=0; s_ld_en=0;
        ld_ms_en=0; ld_ref_en=0; cand_start=0; rd_idx=0;
        for (i=0;i<4;i=i+1) begin win_used[i]=0; pes_failed[i]=0; win_rb[i]=0; win_re[i]=0; win_rid[i]=0; pes_low[i]=0; pes_high[i]=0; end
        l_ms=0; min_seed_len=0; a_sc=0; mo_del=0; me_del=0; mo_ins=0; me_ins=0; a_rb=0; l_pac=0; a_rid=0; a_is_alt=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",nreads); fails=0;
        for (ri=0; ri<nreads; ri=ri+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d",
                t_lq,t_a,t_od,t_ed,t_oi,t_ei,t_zd,t_w,t_p5,t_p3,t_nch,t_nav);
            for (b=0;b<t_lq;b=b+1) got=$fscanf(fd,"%d",qbytes[b]);

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

            // finish -> accel runs; wait for the capture-complete pulse (ma_ready)
            wait(ch_ready); @(posedge clk); read_finish<=1; @(posedge clk); read_finish<=0;
            seen=0; guard=0;
            while (!seen && guard<20000000) begin @(posedge clk); guard=guard+1; if (ma_ready) seen=1; end
            repeat(4) @(posedge clk);    // let pe_top.init propagate (n_r/ma update after init)

            if (t_fb) begin
                if (accel_fallback !== 1'b1) begin
                    fails=fails+1;
                    if (fails<=12) $display("MISMATCH read=%0d expected accel_fallback", ri);
                end
            end else begin
                if (accel_fallback !== 1'b0 || n_ma != t_nout) begin
                    fails=fails+1;
                    if (fails<=12) $display("MISMATCH read=%0d fb=%0b n_ma=%0d/%0d", ri, accel_fallback, n_ma, t_nout);
                end else begin
                    for (i=0;i<t_nout;i=i+1) begin
                        rd_idx<=i[15:0]; @(posedge clk); #1;
                        if (o_rb!==e_rb[i]||o_re!==e_re[i]||o_qb!==e_qb[i]||
                            o_qe!==e_qe[i]||o_rid!==e_rid[i]||o_score!==e_sc[i]) begin
                            fails=fails+1;
                            if (fails<=12) $display("MISMATCH read=%0d ma[%0d] qb %0d/%0d qe %0d/%0d sc %0d/%0d rbOK=%0b reOK=%0b",
                                ri,i,o_qb,e_qb[i],o_qe,e_qe[i],o_score,e_sc[i],(o_rb===e_rb[i]),(o_re===e_re[i]));
                        end
                    end
                end
            end
        end
        $fclose(fd);
        $display("tb_accel_pe_top: %0d reads, %0d failures -> %s", nreads, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #20000000000; $display("[FATAL] timeout"); $finish; end
endmodule

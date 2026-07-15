// tb_matesw_orch_top.sv — self-checking TB for matesw_orch_top (one mem_matesw call
// in hardware). Loads ms, the 4 host-fed ref windows, and the entry ma list; drives
// the pe-stats / window metadata; runs; then checks n_out and every survivor alnreg
// bit-exact vs gen_orchrtl_vectors (= orch.h::matesw_orchestrate).
`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_matesw_orch_top
    import bsw_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic ld_ms_en; logic [15:0] ld_ms_addr; base_t ld_ms_data;
    logic ld_ref_en; logic [1:0] ld_ref_win; logic [15:0] ld_ref_addr; base_t ld_ref_data;
    logic ld_ma_en; logic [15:0] ld_ma_idx;
    logic signed [63:0] ld_ma_rb, ld_ma_re; logic signed [31:0] ld_ma_qb,ld_ma_qe,ld_ma_rid,ld_ma_score,ld_ma_cov;
    logic start; logic signed [31:0] l_ms,min_seed_len,a,o_del,e_del,o_ins,e_ins,a_rid,a_is_alt;
    logic signed [63:0] a_rb, l_pac;
    logic [15:0] n_ma_in;
    logic [3:0] win_used, pes_failed;
    logic signed [63:0] win_rb[4], win_re[4], pes_low[4], pes_high[4];
    logic signed [31:0] win_rid[4];
    logic busy, done, overflow, tie; logic [15:0] n_out, rd_idx;
    logic signed [63:0] o_rb,o_re; logic signed [31:0] o_qb,o_qe,o_rid,o_score,o_cov;

    matesw_orch_top #(.MA_MAX(256)) dut(.clk,.rst_n,
        .ld_ms_en,.ld_ms_addr,.ld_ms_data,.ld_ref_en,.ld_ref_win,.ld_ref_addr,.ld_ref_data,
        .ld_ma_en,.ld_ma_idx,.ld_ma_rb,.ld_ma_re,.ld_ma_qb,.ld_ma_qe,.ld_ma_rid,.ld_ma_score,.ld_ma_cov,
        .start,.l_ms,.min_seed_len,.a,.o_del,.e_del,.o_ins,.e_ins,.a_rb,.l_pac,.a_rid,.a_is_alt,
        .n_ma_in,.win_used,.win_rb,.win_re,.win_rid,.pes_low,.pes_high,.pes_failed,
        .busy,.done,.overflow,.tie,.n_out,.rd_idx,.o_rb,.o_re,.o_qb,.o_qe,.o_rid,.o_score,.o_cov);

    integer fd,got,cnt,ci,k,r,fails,guard,nin,nout,rl,e_fb;
    integer t_lms,t_lpac,t_arb,t_arid,t_aalt,t_msl,t_a,t_od,t_ed,t_oi,t_ei;
    integer pf[0:3],pl[0:3],ph[0:3],wu[0:3],wrb[0:3],wre[0:3],wrid[0:3];
    integer i_rb[0:63],i_re[0:63],i_qb[0:63],i_qe[0:63],i_rid[0:63],i_sc[0:63],i_cov[0:63];
    integer e_rb[0:63],e_re[0:63],e_qb[0:63],e_qe[0:63],e_rid[0:63],e_sc[0:63],e_cov[0:63];
    integer msb[0:255], rfb[0:1199];
    string path;

    task automatic pls(); @(posedge clk); endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/mate_rescue/vectors/orchrtl_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_ms_en=0; ld_ref_en=0; ld_ma_en=0; start=0; rd_idx=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d",
                t_lms,t_lpac,t_arb,t_arid,t_aalt,t_msl,t_a,t_od,t_ed,t_oi,t_ei);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",pf[r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",pl[r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",ph[r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",wu[r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",wrb[r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",wre[r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",wrid[r]);
            got=$fscanf(fd,"%d",nin);
            for (k=0;k<nin;k=k+1) got=$fscanf(fd,"%d %d %d %d %d %d %d",
                i_rb[k],i_re[k],i_qb[k],i_qe[k],i_rid[k],i_sc[k],i_cov[k]);
            for (k=0;k<t_lms;k=k+1) got=$fscanf(fd,"%d",msb[k]);

            // load ms
            for (k=0;k<t_lms;k=k+1) begin
                @(posedge clk); ld_ms_en<=1; ld_ms_addr<=k[15:0]; ld_ms_data<=base_t'(msb[k]);
            end
            @(posedge clk); ld_ms_en<=0;
            // load refs
            for (r=0;r<4;r=r+1) begin
                got=$fscanf(fd,"%d",rl);
                for (k=0;k<rl;k=k+1) got=$fscanf(fd,"%d",rfb[k]);
                for (k=0;k<rl;k=k+1) begin
                    @(posedge clk); ld_ref_en<=1; ld_ref_win<=r[1:0]; ld_ref_addr<=k[15:0]; ld_ref_data<=base_t'(rfb[k]);
                end
                @(posedge clk); ld_ref_en<=0;
            end
            // load ma
            for (k=0;k<nin;k=k+1) begin
                @(posedge clk); ld_ma_en<=1; ld_ma_idx<=k[15:0];
                ld_ma_rb<=i_rb[k]; ld_ma_re<=i_re[k]; ld_ma_qb<=i_qb[k]; ld_ma_qe<=i_qe[k];
                ld_ma_rid<=i_rid[k]; ld_ma_score<=i_sc[k]; ld_ma_cov<=i_cov[k];
            end
            @(posedge clk); ld_ma_en<=0;

            // drive request
            l_ms<=t_lms; l_pac<=t_lpac; a_rb<=t_arb; a_rid<=t_arid; a_is_alt<=t_aalt;
            min_seed_len<=t_msl; a<=t_a; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei;
            n_ma_in<=nin[15:0];
            for (r=0;r<4;r=r+1) begin
                win_used[r]<=wu[r][0]; pes_failed[r]<=pf[r][0];
                win_rb[r]<=wrb[r]; win_re[r]<=wre[r]; win_rid[r]<=wrid[r];
                pes_low[r]<=pl[r]; pes_high[r]<=ph[r];
            end
            @(posedge clk); start<=1; @(posedge clk); start<=0;
            guard=0; while (!done && guard<4000000) begin @(posedge clk); guard=guard+1; end

            // expected out
            got=$fscanf(fd,"%d %d",nout,e_fb);
            for (k=0;k<nout;k=k+1) got=$fscanf(fd,"%d %d %d %d %d %d %d",
                e_rb[k],e_re[k],e_qb[k],e_qe[k],e_rid[k],e_sc[k],e_cov[k]);

            if (tie !== e_fb[0]) begin
                fails=fails+1;
                if (fails<=15) $display("MISMATCH[%0d] tie %0b/%0b (n_in=%0d)", ci, tie, e_fb[0], nin);
            end
            if (n_out !== nout[15:0]) begin
                fails=fails+1;
                if (fails<=2) begin
                    $display("MISMATCH[%0d] n_out %0d/%0d (n_in=%0d)", ci, n_out, nout, nin);
                    for (k=0;k<n_out;k=k+1) begin rd_idx<=k[15:0]; @(posedge clk); #1;
                        $display("   RTL surv %0d: rb %0d re %0d qb %0d qe %0d rid %0d sc %0d cov %0d",
                            k,o_rb,o_re,o_qb,o_qe,o_rid,o_score,o_cov); end
                    for (k=0;k<nout;k=k+1)
                        $display("   EXP surv %0d: rb %0d re %0d qb %0d qe %0d rid %0d sc %0d cov %0d",
                            k,e_rb[k],e_re[k],e_qb[k],e_qe[k],e_rid[k],e_sc[k],e_cov[k]);
                end
            end else begin
                for (k=0;k<nout;k=k+1) begin
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
        $display("tb_matesw_orch_top: %0d cases, %0d failures -> %s",
                 cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #2000000000; $display("[FATAL] timeout"); $finish; end
endmodule

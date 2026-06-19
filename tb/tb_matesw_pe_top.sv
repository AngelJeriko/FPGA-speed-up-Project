// tb_matesw_pe_top.sv — self-checking TB for matesw_pe_top (the paired-end candidate
// loop). Loads the entry ma + the shared mate seq, then for each candidate loads its
// host-fed ref windows + drives its scalars and pulses cand_start; finally checks the
// threaded ma list bit-exact vs gen_petop_vectors (= matesw_orchestrate looped).
`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_matesw_pe_top
    import bsw_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic ld_ms_en; logic [15:0] ld_ms_addr; base_t ld_ms_data;
    logic ld_ref_en; logic [1:0] ld_ref_win; logic [15:0] ld_ref_addr; base_t ld_ref_data;
    logic ld_ma_en; logic [15:0] ld_ma_idx;
    logic signed [63:0] ld_ma_rb, ld_ma_re; logic signed [31:0] ld_ma_qb,ld_ma_qe,ld_ma_rid,ld_ma_score,ld_ma_cov;
    logic init; logic [15:0] n_ma_init;
    logic cand_start; logic signed [31:0] l_ms,min_seed_len,a,o_del,e_del,o_ins,e_ins,a_rid,a_is_alt;
    logic signed [63:0] a_rb, l_pac;
    logic [3:0] win_used, pes_failed;
    logic signed [63:0] win_rb[4], win_re[4], pes_low[4], pes_high[4];
    logic signed [31:0] win_rid[4];
    logic busy, cand_done; logic [15:0] n_ma, rd_idx;
    logic signed [63:0] o_rb,o_re; logic signed [31:0] o_qb,o_qe,o_rid,o_score,o_cov;

    matesw_pe_top #(.MA_MAX(64)) dut(.clk,.rst_n,
        .ld_ms_en,.ld_ms_addr,.ld_ms_data,.ld_ref_en,.ld_ref_win,.ld_ref_addr,.ld_ref_data,
        .ld_ma_en,.ld_ma_idx,.ld_ma_rb,.ld_ma_re,.ld_ma_qb,.ld_ma_qe,.ld_ma_rid,.ld_ma_score,.ld_ma_cov,
        .init,.n_ma_init,.cand_start,.l_ms,.min_seed_len,.a,.o_del,.e_del,.o_ins,.e_ins,
        .a_rb,.l_pac,.a_rid,.a_is_alt,.win_used,.win_rb,.win_re,.win_rid,.pes_low,.pes_high,.pes_failed,
        .busy,.cand_done,.n_ma,.rd_idx,.o_rb,.o_re,.o_qb,.o_qe,.o_rid,.o_score,.o_cov);

    integer fd,got,cnt,ci,k,r,c,fails,guard,ncand,ninit,nfin,rl;
    integer t_lms,t_lpac,t_msl,t_a,t_od,t_ed,t_oi,t_ei;
    integer pf[0:3],pl[0:3],ph[0:3];
    integer c_arb,c_arid,c_aalt,wu[0:3],wrb[0:3],wre[0:3],wrid[0:3];
    integer i_rb[0:63],i_re[0:63],i_qb[0:63],i_qe[0:63],i_rid[0:63],i_sc[0:63],i_cov[0:63];
    integer e_rb[0:63],e_re[0:63],e_qb[0:63],e_qe[0:63],e_rid[0:63],e_sc[0:63],e_cov[0:63];
    integer msb[0:255], rfb[0:1199];
    string path;

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/mate_rescue/vectors/petop_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_ms_en=0; ld_ref_en=0; ld_ma_en=0; init=0; cand_start=0; rd_idx=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d",t_lms,t_lpac,t_msl,t_a,t_od,t_ed,t_oi,t_ei);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",pf[r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",pl[r]);
            for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",ph[r]);
            got=$fscanf(fd,"%d",ninit);
            for (k=0;k<ninit;k=k+1) got=$fscanf(fd,"%d %d %d %d %d %d %d",
                i_rb[k],i_re[k],i_qb[k],i_qe[k],i_rid[k],i_sc[k],i_cov[k]);
            for (k=0;k<t_lms;k=k+1) got=$fscanf(fd,"%d",msb[k]);

            // constants for this case
            l_ms<=t_lms; l_pac<=t_lpac; min_seed_len<=t_msl; a<=t_a;
            o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei;
            for (r=0;r<4;r=r+1) begin pes_failed[r]<=pf[r][0]; pes_low[r]<=pl[r]; pes_high[r]<=ph[r]; end

            // load shared mate seq
            for (k=0;k<t_lms;k=k+1) begin @(posedge clk); ld_ms_en<=1; ld_ms_addr<=k[15:0]; ld_ms_data<=base_t'(msb[k]); end
            @(posedge clk); ld_ms_en<=0;
            // load entry ma + init
            for (k=0;k<ninit;k=k+1) begin @(posedge clk); ld_ma_en<=1; ld_ma_idx<=k[15:0];
                ld_ma_rb<=i_rb[k]; ld_ma_re<=i_re[k]; ld_ma_qb<=i_qb[k]; ld_ma_qe<=i_qe[k];
                ld_ma_rid<=i_rid[k]; ld_ma_score<=i_sc[k]; ld_ma_cov<=i_cov[k]; end
            @(posedge clk); ld_ma_en<=0;
            @(posedge clk); init<=1; n_ma_init<=ninit[15:0]; @(posedge clk); init<=0;

            got=$fscanf(fd,"%d",ncand);
            for (c=0;c<ncand;c=c+1) begin
                got=$fscanf(fd,"%d %d %d",c_arb,c_arid,c_aalt);
                for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",wu[r]);
                for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",wrb[r]);
                for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",wre[r]);
                for (r=0;r<4;r=r+1) got=$fscanf(fd,"%d",wrid[r]);
                // load this candidate's ref windows
                for (r=0;r<4;r=r+1) begin
                    got=$fscanf(fd,"%d",rl);
                    for (k=0;k<rl;k=k+1) got=$fscanf(fd,"%d",rfb[k]);
                    for (k=0;k<rl;k=k+1) begin @(posedge clk); ld_ref_en<=1; ld_ref_win<=r[1:0]; ld_ref_addr<=k[15:0]; ld_ref_data<=base_t'(rfb[k]); end
                    @(posedge clk); ld_ref_en<=0;
                end
                // drive candidate scalars + run
                a_rb<=c_arb; a_rid<=c_arid; a_is_alt<=c_aalt;
                for (r=0;r<4;r=r+1) begin win_used[r]<=wu[r][0]; win_rb[r]<=wrb[r]; win_re[r]<=wre[r]; win_rid[r]<=wrid[r]; end
                @(posedge clk); cand_start<=1; @(posedge clk); cand_start<=0;
                guard=0; while (!cand_done && guard<4000000) begin @(posedge clk); guard=guard+1; end
            end

            got=$fscanf(fd,"%d",nfin);
            for (k=0;k<nfin;k=k+1) got=$fscanf(fd,"%d %d %d %d %d %d %d",
                e_rb[k],e_re[k],e_qb[k],e_qe[k],e_rid[k],e_sc[k],e_cov[k]);

            if (n_ma !== nfin[15:0]) begin
                fails=fails+1;
                if (fails<=15) $display("MISMATCH[%0d] n_ma %0d/%0d (ninit=%0d ncand=%0d)", ci, n_ma, nfin, ninit, ncand);
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
        $display("tb_matesw_pe_top: %0d cases, %0d failures -> %s", cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #3000000000; $display("[FATAL] timeout"); $finish; end
endmodule

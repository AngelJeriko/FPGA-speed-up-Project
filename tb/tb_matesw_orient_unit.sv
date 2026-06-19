// tb_matesw_orient_unit.sv — self-checking TB for matesw_orient_unit (matesw_top +
// the mem_matesw kswr->alnreg transform, one orientation). Loads the oriented query
// + reference window, runs the unit, and checks `rescue` and (when a rescue is
// produced) the alnreg b fields bit-exact vs gen_orient_vectors (= hw_align2 +
// orch.h transform). Coordinates are kept small by the generator so 32-bit reads
// suffice; the unit's 64-bit b_rb/b_re compare by value.
`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_matesw_orient_unit
    import bsw_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic        ld_en, ld_sel; logic [15:0] ld_addr; base_t ld_data;
    logic        start, is_rev, busy, done_o, rescue;
    logic signed [31:0] l_ms, tlen, o_del, e_del, o_ins, e_ins, a, min_seed_len;
    logic signed [31:0] a_rid, a_is_alt;
    logic signed [63:0] rb, l_pac;
    logic signed [63:0] b_rb, b_re;
    logic signed [31:0] b_qb, b_qe, b_score, b_seedcov, b_rid, b_is_alt;

    matesw_orient_unit dut(.clk,.rst_n,.ld_en,.ld_sel,.ld_addr,.ld_data,
        .start,.l_ms,.tlen,.o_del,.e_del,.o_ins,.e_ins,.a,.min_seed_len,.is_rev,
        .rb,.l_pac,.a_rid,.a_is_alt,
        .busy,.done_o,.rescue,.b_rb,.b_re,.b_qb,.b_qe,.b_score,.b_seedcov,.b_rid,.b_is_alt);

    integer fd,got,cnt,ci,k,fails,guard;
    integer t_lms,t_tlen,t_od,t_ed,t_oi,t_ei,t_a,t_msl,t_isrev,t_rb,t_lpac,t_arid,t_aalt;
    integer e_res,e_rb,e_re,e_qb,e_qe,e_sc,e_cov,e_rid,e_alt;
    integer qb_[0:255], tb_[0:511];
    string path;

    task automatic mem(input bit sel, input int addr, input int dat);
        @(posedge clk); ld_en<=1; ld_sel<=sel; ld_addr<=addr[15:0]; ld_data<=base_t'(dat);
        @(posedge clk); ld_en<=0;
    endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/mate_rescue/vectors/orient_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_en=0; start=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                t_lms,t_tlen,t_od,t_ed,t_oi,t_ei,t_a,t_msl,t_isrev,t_rb,t_lpac,t_arid,t_aalt,
                e_res,e_rb,e_re,e_qb,e_qe,e_sc,e_cov,e_rid,e_alt);
            for (k=0;k<t_lms;k=k+1)  got=$fscanf(fd,"%d",qb_[k]);
            for (k=0;k<t_tlen;k=k+1) got=$fscanf(fd,"%d",tb_[k]);
            for (k=0;k<t_lms;k=k+1)  mem(1'b0,k,qb_[k]);
            for (k=0;k<t_tlen;k=k+1) mem(1'b1,k,tb_[k]);

            l_ms<=t_lms; tlen<=t_tlen; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei;
            a<=t_a; min_seed_len<=t_msl; is_rev<=t_isrev[0];
            rb<=t_rb; l_pac<=t_lpac; a_rid<=t_arid; a_is_alt<=t_aalt;
            @(posedge clk); start<=1; @(posedge clk); start<=0;
            guard=0; while (!done_o && guard<2000000) begin @(posedge clk); guard=guard+1; end

            if (rescue !== e_res[0]) begin
                fails=fails+1;
                if (fails<=12) $display("MISMATCH[%0d] rescue %0d/%0d (lms=%0d tlen=%0d isrev=%0d)",
                    ci, rescue, e_res, t_lms, t_tlen, t_isrev);
            end else if (e_res) begin
                if (b_rb!==e_rb || b_re!==e_re || b_qb!==e_qb || b_qe!==e_qe ||
                    b_score!==e_sc || b_seedcov!==e_cov || b_rid!==e_rid || b_is_alt!==e_alt) begin
                    fails=fails+1;
                    if (fails<=12)
                        $display("MISMATCH[%0d] rb %0d/%0d re %0d/%0d qb %0d/%0d qe %0d/%0d sc %0d/%0d cov %0d/%0d",
                            ci, b_rb,e_rb, b_re,e_re, b_qb,e_qb, b_qe,e_qe, b_score,e_sc, b_seedcov,e_cov);
                end
            end
        end
        $fclose(fd);
        $display("tb_matesw_orient_unit: %0d cases, %0d failures -> %s",
                 cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #300000000; $display("[FATAL] timeout"); $finish; end
endmodule

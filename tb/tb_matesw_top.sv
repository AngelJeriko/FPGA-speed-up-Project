// tb_matesw_top.sv — self-checking TB for matesw_top (the mate-rescue engine).
// Loads query + reference window, runs the 2-pass local SW, checks {score,te,qe,
// tb,qb} bit-exact vs hw_align2 (== upstream ksw_align2).
`timescale 1ns/1ps
`include "bsw_pkg.sv"

module tb_matesw_top
    import bsw_pkg::*;
();
    logic clk=0, rst_n=0; always #5 clk=~clk;

    logic        ld_en, ld_sel; logic [15:0] ld_addr; base_t ld_data;
    logic        start, xstart, xsubo, busy, done;
    logic signed [31:0] qlen, tlen, o_del, e_del, o_ins, e_ins, subo;
    logic signed [31:0] o_score, o_te, o_qe, o_tb, o_qb;

    matesw_top dut(.clk,.rst_n,.ld_en,.ld_sel,.ld_addr,.ld_data,
        .start,.qlen,.tlen,.o_del,.e_del,.o_ins,.e_ins,.subo,.xstart,.xsubo,
        .busy,.done,.o_score,.o_te,.o_qe,.o_tb,.o_qb);

    integer fd,got,cnt,ci,b,fails,guard;
    integer t_q,t_t,t_od,t_ed,t_oi,t_ei,t_subo,t_xs,t_xu,e_sc,e_te,e_qe,e_tb,e_qb;
    integer qb_[0:255], tb_[0:511];
    string path;

    task automatic mem(input bit sel, input int addr, input int dat);
        @(posedge clk); ld_en<=1; ld_sel<=sel; ld_addr<=addr[15:0]; ld_data<=base_t'(dat);
        @(posedge clk); ld_en<=0;
    endtask

    initial begin
        if (!$value$plusargs("VEC=%s", path)) path="host/mate_rescue/vectors/matesw_vectors.txt";
        fd=$fopen(path,"r"); if (fd==0) begin $display("FATAL: cannot open %s",path); $finish; end
        ld_en=0; start=0;
        repeat(4) @(posedge clk); rst_n=1; @(posedge clk);

        got=$fscanf(fd,"%d",cnt); fails=0;
        for (ci=0; ci<cnt; ci=ci+1) begin
            got=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d %d %d %d",
                t_q,t_t,t_od,t_ed,t_oi,t_ei,t_subo,t_xs,t_xu,e_sc,e_te,e_qe,e_tb,e_qb);
            for (b=0;b<t_q;b=b+1) got=$fscanf(fd,"%d",qb_[b]);
            for (b=0;b<t_t;b=b+1) got=$fscanf(fd,"%d",tb_[b]);
            for (b=0;b<t_q;b=b+1) mem(1'b0,b,qb_[b]);
            for (b=0;b<t_t;b=b+1) mem(1'b1,b,tb_[b]);

            qlen<=t_q; tlen<=t_t; o_del<=t_od; e_del<=t_ed; o_ins<=t_oi; e_ins<=t_ei;
            subo<=t_subo; xstart<=t_xs[0]; xsubo<=t_xu[0];
            @(posedge clk); start<=1; @(posedge clk); start<=0;
            guard=0; while (!done && guard<2000000) begin @(posedge clk); guard=guard+1; end

            if (o_score!==e_sc || o_te!==e_te || o_qe!==e_qe || o_tb!==e_tb || o_qb!==e_qb) begin
                fails=fails+1;
                if (fails<=12)
                    $display("MISMATCH[%0d] qlen=%0d tlen=%0d | score %0d/%0d te %0d/%0d qe %0d/%0d tb %0d/%0d qb %0d/%0d",
                        ci,t_q,t_t,o_score,e_sc,o_te,e_te,o_qe,e_qe,o_tb,e_tb,o_qb,e_qb);
            end
        end
        $fclose(fd);
        $display("tb_matesw_top: %0d cases, %0d failures -> %s",
                 cnt, fails, (fails==0)?"ALL PASS":"FAIL");
        $finish;
    end
    initial begin #200000000; $display("[FATAL] timeout"); $finish; end
endmodule
